# M0: Failure Boundary Mining for Abstraction Discovery

Status: IN PROGRESS
Branch: gstack
Design doc: `~/.gstack/projects/andreasronge-ptc_runner/andreasronge-gstack-design-20260329-161827.md`
Related: `meta-learner-coevolution.md`, `hyperagent-evolution.md`

## Goal

Build and validate the first meta-learner cycle: a hand-written M0 that watches agent
execution traces, identifies recurring failure patterns at the success/failure boundary,
and invents reusable PTC-Lisp prelude functions that eliminate entire classes of failures.

This is the proof-of-mechanism for the larger meta-learner coevolution system. If M0
can produce even one non-trivial prelude function that measurably helps agents, the
core idea is validated.

## Why M0, Not the Full System

The full coevolution system (A/T/C/M with competition-based evaluation) has too many
moving parts to validate at once. M0 isolates the single most important question:
**can a program discover useful abstractions by observing other programs fail?**

M0 is hand-written PTC-Lisp, not evolved. Its tools become the API contract for all
future M variants. If M0's tools are wrong, we find out before building the evolution
infrastructure.

## Architecture

```
Elixir Orchestrator (fixed infrastructure)
  │
  ├── Step 1: Collect traces ──────── PTC-Lisp sandbox
  ├── Step 2: Cluster failures ────── PTC-Lisp sandbox
  ├── Step 3: Find near-miss runs ─── PTC-Lisp sandbox
  ├── Step 4: Mine the gap ────────── PTC-Lisp sandbox
  ├── Step 5: Propose prelude fn ──── PTC-Lisp sandbox (calls LLM)
  ├── Step 6: Validate ────────────── PTC-Lisp sandbox (reruns problems)
  └── Step 7: Accept/reject ───────── Elixir (scoring + decision)
```

Each step is a separate sandboxed PTC-Lisp invocation (1s timeout, 10MB memory).
The Elixir orchestrator sequences steps and passes data between them. The PTC-Lisp
code for each step is the evolvable part. The orchestrator is fixed.

## M0 Cycle (One Iteration)

1. **Collect traces** — gather execution traces from recent SubAgent runs including
   success/failure status, tool calls, intermediate values, error types.

2. **Cluster failures** — group failed runs by trace signature:
   `{error_type, [tool_names_called], exit_status}`. Runs with identical signatures
   likely share a root cause. Use TurnAnalysis diagnostics (`budget_exhausted?`,
   `parse_failure_rate`, `first_turn_valid?`) as additional clustering features.

3. **Find near-miss runs** — failed runs that almost succeeded: parsed and executed
   (not syntax errors), at least one tool call succeeded, error is in logic not
   structure. Filter: `parse_failure_rate = 0` and `first_turn_valid? = true`.

4. **Mine the gap** — compare near-miss runs with successful runs solving similar
   problems. What capability is present in successes but absent in near-misses?

5. **Propose prelude function** — call LLM with failure cluster, near-miss examples,
   successful examples, and gap analysis. Ask for one candidate prelude function.
   Log token cost.

6. **Validate** — add candidate to prelude, rerun only affected problems, measure:
   - `solve_delta`: newly solved problems
   - `tokens_used`: M0's LLM token cost this cycle
   - `prelude_size_penalty`: character count of new function

7. **Accept/reject** — score > 0 means accept:
   ```
   score = solve_delta - (0.1 * tokens_used / 1000) - (0.05 * char_count / 100)
   ```

## M0 Tool Interface

Seven PTC-Lisp tools exposed to M0's sandboxed steps:

| Tool | Signature | Description |
|------|-----------|-------------|
| `list-runs` | `() -> [{run_id, problem_id, success, error_type, tokens_used}]` | Recent run metadata |
| `get-trace` | `(run_id :string) -> trace_map` | Full execution trace for a run |
| `get-program` | `(run_id :string) -> :string` | PTC-Lisp source for a run |
| `get-prelude` | `() -> :string` | Current prelude functions |
| `add-prelude` | `(source :string) -> :boolean` | Add candidate function (temporary) |
| `run-problem` | `(problem_id :string) -> {solved :bool, output :any, tokens_used :int}` | Rerun a problem with current prelude |
| `llm-propose` | `(prompt :string) -> {response :string, tokens_used :int}` | Call LLM, returns response + cost |

## Trace Schema (v0)

```elixir
%{
  run_id: "run-20260329-001",
  problem_id: "problem-007",
  success: false,
  error_type: :runtime_error,        # :runtime_error | :parse_error | :timeout | :memory | nil
  exit_status: :failed,              # :solved | :failed | :crashed
  tool_calls: [
    %{name: "search", args: %{q: "..."}, result: %{...}, duration_ms: 42},
    %{name: "extract", args: %{...}, result: nil, error: "key not found"}
  ],
  program_source: "(let [results ...])",
  output: {:error, "key not found"},
  expected_output: [1, 2, 3],
  tokens_used: 847,
  turn_analysis: %{
    budget_exhausted?: false,
    parse_failure_rate: 0.0,
    first_turn_valid?: true
  }
}
```

## Existing Infrastructure

What already exists (and the gaps):

| Component | Status | Location | Gap for M0 |
|-----------|--------|----------|------------|
| Tracer | Done | `lib/ptc_runner/tracer.ex` | No run_id session grouping |
| TraceLog | Done | `lib/ptc_runner/trace_log.ex` | No cross-run correlation |
| TraceLog.Analyzer | Done | `lib/ptc_runner/trace_log/analyzer.ex` | No failure clustering |
| TurnAnalysis | Done | `lib/ptc_runner/metrics/turn_analysis.ex` | Has all needed metrics |
| User Namespace (prelude) | Done | `lib/ptc_runner/sub_agent/namespace/user.ex` | Resets each run, no persistence |
| Test suite | Done | `demo/lib/ptc_demo/test_runner/test_case.ex` | **55 tests** (25 M0-clustered) |
| Sandbox | Done | `lib/ptc_runner/sandbox.ex` | Ready, 1s/10MB limits |
| M0 tools | Not started | — | 7 tools to implement |
| M0 orchestrator | Not started | — | Elixir module to sequence steps |
| M0 step functions | Not started | — | PTC-Lisp programs |
| Prelude persistence | Not started | — | Save/load across runs |

## Validation Test Cases (M0-Specific)

25 tests in 5 capability clusters, designed so failures cluster by capability gap:

| Cluster | Capability | Tests | IDs |
|---------|-----------|-------|-----|
| A | String extraction (parse, substring, composite keys) | 5 | 31-35 |
| B | Date arithmetic (range filter, period comparison, temporal join) | 5 | 36-40 |
| C | Nested aggregation (group+count, two-level grouping, ranked groups) | 5 | 41-45 |
| D | Set operations (membership, difference, intersection) | 5 | 46-50 |
| E | Conditional logic (tier classification, compound predicates, weighted scoring) | 5 | 51-55 |

Run with: `PtcDemo.LispTestRunner.run_all(filter: :m0)`

## Implementation Plan

### Step 1: Generate validation problems ✅

Added 25 M0-clustered test cases to `demo/lib/ptc_demo/test_runner/test_case.ex`.
Total suite: 55 tests. Added `:m0` filter and `{:gte_length, n}` constraint.

### Step 2: Design and implement M0 tool interface

Define PTC-Lisp tool signatures for `list-runs`, `get-trace`, `get-program`,
`get-prelude`, `add-prelude`, `run-problem`, `llm-propose`. These become the API
contract for all future M variants.

Implementation location: `lib/ptc_runner/meta/m0_tools.ex`

Depends on: trace storage extensions (step 3), but tool signatures can be designed
independently. Consider implementing tools and storage in parallel.

### Step 3: Extend trace storage

Bridge the gap between existing Tracer/TraceLog and M0's needs:
- Add `run_id` session grouping (link multiple traces to one experiment)
- Store `expected_output` alongside actual output
- Add `error_type` classification to trace entries
- Implement prelude persistence (save/load between runs)

Implementation location: extend existing modules, add `lib/ptc_runner/meta/run_store.ex`

### Step 4: Hand-write M0 step functions in PTC-Lisp

Write the PTC-Lisp programs for each M0 cycle step:
- Failure clustering by trace signature
- Near-miss detection
- Gap mining (compare near-miss vs success)
- LLM prompt construction for prelude proposals

Location: `priv/m0/` or inline in the orchestrator

### Step 5: Build M0 orchestrator

Elixir module that sequences the M0 cycle:
- Runs each step as a sandboxed PTC-Lisp execution
- Passes data between steps
- Implements accept/reject scoring
- Logs decisions and results

Implementation location: `lib/ptc_runner/meta/m0_orchestrator.ex`

### Step 6: Run 5-10 cycles and evaluate

- Run M0 against the 55-test suite
- Does it produce any accepted prelude functions?
- Is the scoring function reasonable (not too permissive, not too strict)?
- Do failure clusters correspond to real capability gaps?
- Does near-miss detection find useful programs?

### Step 7: Evaluate self-applicability

Can M0 use its own discovered prelude functions in subsequent cycles? If M0
discovers a `classify-failures` helper, can future cycles use it?

## Scoring Function

```
score = solve_delta - (lambda_llm * tokens_used / 1000) - (lambda_size * char_count / 100)
```

Starting values (fixed for all M0 cycles):
- `lambda_llm = 0.1` — 1000 tokens costs 0.1 solve-equivalents
- `lambda_size = 0.05` — 100 chars of prelude costs 0.05 solve-equivalents

Only revisit after the initial 5-10 cycle experiment.

## Failure Handling

- **LLM timeout/error**: skip cycle, log failure, continue to next
- **Malformed traces**: skip unparseable runs; abort cycle if >50% unparseable
- **Validation hits sandbox limits**: reject with reason `sandbox_limit_exceeded`
- **No failure clusters**: log "no actionable clusters," wait for more runs

## Success Criteria

1. M0 produces at least one accepted prelude function (solve_delta > 0 after costs)
2. The function is non-trivial — encodes a pattern discovered from trace analysis
3. The feedback loop completes end-to-end (trace → cluster → mine → propose → validate → accept/reject)
4. The mechanism is domain-blind — M0's logic doesn't reference specific problem domains

## Open Questions

1. **Near-miss threshold** — binary success/failure is too coarse. Need graded similarity
   between outputs and expected outputs. Defer until M0 reveals whether this matters.

2. **LLM selection** — use cheap model (haiku) for M0's LLM calls during experimentation,
   or strong model (sonnet/opus)? Start cheap, validate winners with stronger models.

3. **When does M0 become M1?** — after M0 produces 3-5 accepted abstractions and the
   pattern is clear enough to parameterize.

## Path to Full System

M0 validates the core mechanism. If it works, the path forward:

```
M0 (hand-written, current)
  → M1 (parameterized M0, evolvable parameters)
    → Full coevolution (A/T/C/M with competition)
      → Self-improving M (M uses own prelude, distills away LLM calls)
```

Each step requires the previous to work. Don't build ahead.
