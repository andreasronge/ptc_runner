# Iterative Retrieval: Design Document

## Problem Statement

PageIndex has three retrieval modes, each with significant limitations:

### Agent Mode (~80k tokens, 30% accuracy)

A single SubAgent with a `fetch_section` tool sees all available sections, fetches content iteratively, and produces a free-text answer. Problems:

- **Muddy responsibilities**: one agent must fetch, extract, reason, and synthesize
- **High token cost**: raw PDF content accumulates in the conversation context across 8-10 turns
- **No structured intermediate data**: the synthesis happens on raw text, making it hard to verify what data was actually found

### Planner Mode (~11k tokens, 27-44% accuracy)

A MetaPlanner decomposes the question into a task DAG (fetch tasks → compute tasks → synthesis), then PlanExecutor runs it. Problems:

- **Brittle upfront planning**: the planner predicts which sections to fetch before seeing any data, often getting it wrong
- **Quality gate is harmful**: an LLM pre-flight check rejects valid data because it can't confirm specific numbers exist in raw table-format text. This caused 14 of 22 errors in benchmarks (see bench_results.md)
- **Type validation failures**: strict signature matching rejects integers where floats are expected
- **No adaptation**: when a fetch doesn't contain expected data, the replan mechanism generates a new full plan rather than making a targeted adjustment

### Root Cause

Both modes conflate data retrieval with reasoning. The agent stuffs raw text into its context; the planner tries to predict what raw text it needs upfront. Neither mode has a clean separation between "find the data" and "answer the question."

## Proposed Solution: Iterative Extraction Loop

Two agents in a loop, one shopping list item at a time.

### Architecture

```
Loop state:
  - findings: [%{label, value, unit, page, section}]   # grows each iteration
  - failed_searches: [%{item, reason, sections_tried}]  # grows on extraction failure

┌──────────────────────────────────────────────────────┐
│                   Loop (max N iterations)             │
│                                                      │
│  ┌─────────────┐       ┌──────────────────────┐     │
│  │  Extraction  │──────→│  Synthesis/Evaluator │     │
│  │    Agent     │       │       Agent          │     │
│  └─────────────┘       └──────────────────────┘     │
│    ↑ has fetch tool       │                          │
│    ↑ sees: shopping       │  returns either:         │
│    ↑ item + question      │  - {status: "answer"}    │
│    ↑ + section index      │  - {status: "needs"}     │
│    ↑                      │  - {status: "fail"}      │
│    ↑                      ↓                          │
│    ↑              findings + failed_searches          │
│    ↑                      │                          │
│    └──────────────────────┘                          │
│          (next shopping item)                        │
└──────────────────────────────────────────────────────┘
```

### Flow

**Iteration 1:**
1. Initial shopping item derived from the question (e.g., "segment revenue breakdown")
2. Extraction agent fetches relevant sections, returns structured findings with provenance
3. Synthesis agent receives: question + all accumulated findings + failed searches
4. Synthesis agent either returns the answer or returns the one thing it still needs

**Iteration 2+ (if needed):**
1. Shopping item = what the synthesis agent said it needs
2. Extraction agent fetches with this focused lens, returns findings
3. Findings list grows (append, never overwrite)
4. Synthesis agent re-evaluates with fuller picture

**Termination:**
- Synthesis agent returns an answer → done
- Synthesis agent returns `{status: "fail"}` → done with error
- Max iterations reached → synthesis agent may still answer with available data or fail

### Design Principles

**Shopping item is a lens, not a contract.** The extraction agent is guided by the shopping item but returns anything relevant it finds. If it's looking for "segment revenue" and notices organic growth rates in the same section, it returns both.

**Sufficiency is decided by the synthesis agent, not a gate.** No upfront prediction of what data is needed. The agent that has the question AND the data decides whether it can answer. This eliminates false-negative quality gates.

**Structured findings with provenance.** The extraction agent returns a list of findings, each tagged with page number, section, and context. The synthesis agent never sees raw PDF text — only structured data. Every value in the final answer is traceable to a specific page and section.

**Fail with reason as first-class data.** The extraction agent uses `(fail "reason")` when a section contains nothing relevant. That failure — including the reason and which sections were tried — flows into the loop state and is visible to the synthesis agent. This prevents loop stagnation (the synthesis agent knows what was already tried and failed) and enables targeted next requests.

**One item at a time.** The synthesis agent requests exactly one thing per iteration, not a list. This keeps each extraction focused and allows the loop to adapt at every step.

**Clean context per extraction.** Each extraction agent invocation starts fresh — no conversation history from previous iterations. This prevents context bloat from accumulated raw text. Only the structured findings survive between iterations.

**No forced answers.** On the final iteration, the synthesis agent is NOT forced to answer. It may return `{status: "fail", reason: "..."}` if the data is genuinely insufficient. A confident "I can't answer" is more valuable than a hallucination. The caller decides how to handle this.

## Data Model

### Finding

Each extracted data point is a self-contained finding with full provenance:

```json
{
  "label": "consumer_segment_revenue_2022",
  "value": 5298,
  "unit": "millions_usd",
  "page": 35,
  "section": "Performance by Business Segment",
  "context": "Consumer segment net sales for fiscal year 2022"
}
```

The `value` field can be a number or a string (for text-based findings like "3M describes its capital allocation strategy as efficiency-focused").

A findings list from one extraction call might contain 3-8 findings — the shopping item target plus anything else relevant the agent noticed.

### Failed Search

When an extraction agent fails, the failure is recorded with full context:

```json
{
  "item": "M&A impact per segment",
  "reason": "No per-segment M&A breakdown found. Acquisitions note only contains aggregate acquisition costs.",
  "sections_tried": ["notes_to_consol_note_3_acquisitions", "management_s_di_performance_by_business_segmen"]
}
```

This prevents loop stagnation — the synthesis agent sees what was already tried and can either request something different or conclude the data isn't in the document.

### Loop State

```elixir
%{
  findings: [finding()],           # all findings from all iterations
  failed_searches: [failed()],     # all extraction failures
  iteration: integer(),            # current iteration number
  max_iterations: integer()        # limit (default: 4)
}
```

## Agents

### Extraction Agent

- **Type**: Multi-turn SubAgent with `fetch_section` tool
- **Input**: shopping item (string), question (string), available sections summary
- **Output**: list of findings with provenance
- **Turns**: 2-4 (may fetch multiple sections per shopping item)
- **Context**: Fresh each iteration — no history from previous iterations
- **Behavior**:
  - Reads section summaries to identify promising sections for the shopping item
  - Fetches 1-3 sections
  - Extracts structured findings (numbers, dates, text) with page/section tags
  - Returns what it found — both the targeted shopping item data and anything else relevant
  - Uses `(fail "reason")` if no relevant data found in any fetched section, including which sections were tried

Signature:
```
(shopping_item :string, question :string) -> {
  findings [{label :string, value :any, unit :string?, page :int,
             section :string, context :string?}],
  sections_searched [:string]
}
```

### Synthesis/Evaluator Agent

- **Type**: Single-turn SubAgent, no tools
- **Input**: question (string), accumulated findings (list), failed searches (list)
- **Output**: answer, next shopping item, or failure
- **Context**: Sees only structured findings and failed searches — never raw PDF text
- **Behavior**:
  - Examines the question and all findings collected so far
  - Considers failed searches to avoid requesting the same data again
  - If it can answer: returns answer with confidence and cited sources (page numbers from findings)
  - If it cannot answer: returns the one thing it still needs, phrased to avoid repeating failed searches
  - If data is genuinely insufficient: returns failure with explanation

Signature:
```
(question :string, findings [:map], failed_searches [:map]) -> {
  status :string,
  answer :string?,
  sources [:string]?,
  confidence :string?,
  needs :string?,
  reason :string?
}
```

Where `status` is one of:
- `"answer"` — question answered, `answer` + `sources` + `confidence` populated
- `"needs"` — more data required, `needs` + `reason` populated
- `"fail"` — cannot answer with available data, `reason` populated

## Implementation Plan

### Phase 1: Core Loop

1. **Create `PageIndex.IterativeRetriever`** module with `retrieve/3`
   - Same interface as existing retrievers: `retrieve(tree, query, opts)`
   - Returns `{:ok, %{answer: ..., sources: ..., iterations: N, findings_count: N}}` or `{:error, reason}`

2. **Implement extraction agent**
   - Reuse `fetch_section` tool from PlannerRetriever (with fuzzy matching)
   - SubAgent with findings-list return signature
   - Max 4 turns per extraction call
   - Prompt emphasizes: extract structured data with page numbers, return anything relevant

3. **Implement synthesis/evaluator agent**
   - Single-turn SubAgent with `output: :json`
   - Receives accumulated findings + failed searches
   - Returns structured response with status field
   - Prompt emphasizes: cite page numbers from findings, don't guess missing data

4. **Implement loop logic**
   - Initial shopping item: the question itself (let the extraction agent decide what to look for first)
   - Append findings between iterations (never overwrite)
   - Record failed extractions with reason and sections tried
   - Max 4 iterations (configurable)
   - Wrap in `TraceLog.with_trace` for observability

### Phase 2: Integration with bench.exs

5. **Add `--modes iterative` to bench.exs**
   - Run alongside agent and planner for comparison
   - Track: iterations used, findings count, failed searches

6. **Benchmark and compare**
   - Expect: token cost between agent (80k) and planner (11k), ~15-25k
   - Expect: accuracy higher than both due to adaptive retrieval + structured data
   - Expect: reliability close to 100% (no quality gate rejections, no brittle plans)

### Phase 3: Refinements (based on benchmark results)

7. **Tune iteration count and turn limits**
8. **Consider parallel first iteration** — if the question clearly needs data from multiple disparate sections (e.g., income statement AND cash flow), the first extraction could target both. Only add if benchmarks show iteration count is a bottleneck.
9. **Consider extraction caching** — if the same section is fetched across iterations, reuse findings from the previous extraction rather than re-fetching and re-extracting.

## Implementation Notes

### The Math Problem

The planner mode used dedicated `calculator` / `computation_engine` agents with PTC-Lisp for arithmetic. In this design, the synthesis agent is tool-free and must perform calculations internally (e.g., CAPEX/revenue ratio).

LLMs handle arithmetic reliably when the numbers are clearly labeled — which the structured findings list ensures. For Phase 1, keep synthesis tool-free. If benchmarks reveal math errors, add a single `calculate` tool to the synthesis agent. The loop logic doesn't change.

### Initial Shopping Item

The initial shopping item is the question itself (no extra LLM turn to "plan"). The extraction agent has 2-4 turns, so it can assess the question's breadth and decide to fetch the 2 most likely sections (e.g., Income Statement and Segment Note) in its first two tool calls. This avoids an upfront planning step that adds latency and tokens for little benefit.

### Reasoning Around Missing Data

When prompting the synthesis agent, instruct it: if a needed finding appears in `failed_searches`, either conclude the data isn't available OR try to find an alternative data path. For example, if "Operating Margin" isn't directly stated, request "Operating Income" and "Revenue" separately to compute it. This encourages the agent to adapt rather than stall.

### Specific `needs` Requests

The synthesis agent should be as specific as possible in its `needs` + `reason` fields. Instead of `"needs": "segment margin"`, prefer `"needs": "Consumer segment operating margin or operating income for 2022", "reason": "I have Consumer revenue ($5,298M) but need margin or cost data to assess profitability drag"`. This gives the extraction agent a precise lens and avoids wasted fetches.

### Convergence Signal

A specific `reason` also serves as a convergence signal. If the synthesis agent's `needs` requests become increasingly narrow and specific across iterations, the loop is converging. If they stay vague or repeat, something is wrong — the max iteration limit handles this gracefully.

## Success Criteria

- **Reliability**: >90% of runs produce an answer (vs 63% current combined)
- **Accuracy**: >50% correct by LLM-as-judge (vs 30% current best)
- **Token cost**: <25k tokens per run (vs 80k agent, 11k planner)
- **Simplicity**: fewer moving parts than PlanExecutor (no task DAGs, no quality gates, no replan machinery)
- **Provenance**: every number in the answer traceable to a page number

## Key Differences from Existing Approaches

| Aspect | Agent | Planner | Iterative |
|--------|-------|---------|-----------|
| Planning | None | Full DAG upfront | One item at a time |
| Fetching | Adaptive | Predicted upfront | Adaptive + focused |
| Data format | Raw text in context | Raw text to agents | Structured findings with provenance |
| Sufficiency check | None | LLM quality gate | Synthesis agent |
| Failure handling | Max turns | Replan cascade | Fail reasons as first-class data |
| Adaptation | Implicit (LLM memory) | Replan (expensive) | Each iteration informed by failures |
| Context management | Grows each turn | Per-task | Clean slate per extraction |
| Token cost | ~80k | ~11k | ~15-25k (estimated) |
| Data provenance | None | None | Page + section on every finding |
