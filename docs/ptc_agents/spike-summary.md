# SubAgent Architecture: Spike Summary

> **Historical Document**: This document captures the original spike validation work. The API has evolved significantly since then. **Note:** `SubAgent.delegate/2` is now `SubAgent.run/2`, and `as_tool/1` is now `as_tool/2`. For current API design, see:
> - [guides/](guides/) - Usage guides and patterns
> - [specification.md](specification.md) - Formal API reference
> - [step.md](step.md) - Shared Step struct specification
> - [lisp-api-updates.md](lisp-api-updates.md) - Changes to Lisp API
> - [signature-syntax.md](signature-syntax.md) - Signature syntax reference
>
> The learnings below remain valid, but specific API details (function names, struct fields, options) may differ from the current plan.

---

This document summarizes the validation work done on the SubAgent and Planning Agent architecture, what has been proven, and areas for future investigation.

---

## Spike Objectives

The spike aimed to validate four high-leverage areas before committing to full implementation:

1.  **The `delegate` tool** - Can a Main Agent successfully call a SubAgent and use its result?
2.  **Ref extraction** - Can we deterministically extract values (IDs, counts) from results for chaining?
3.  **Multi-turn agentic loop** - Can SubAgents execute multiple programs before completing a task?
4.  **Formal planning** - Can an LLM generate structured, dependency-aware plans as data?

---

## What Was Built

### 1. RefExtractor Module

Deterministic data extraction from SubAgent results using Access paths.

```elixir
# Extract nested values without LLM interpretation
refs = %{
  customer_id: [Access.at(0), :id],
  total: fn result -> Enum.sum(result, & &1.amount) end
}
```

**Key properties:**
- Supports both path-based (`[Access.at(0), :id]`) and function-based extraction
- Fails explicitly when paths don't match result shape (no silent `nil`)
- Keeps parent context clean - only extracted refs are passed, not full data blobs

### 2. Reusable AgenticLoop

Extracted the multi-turn execution logic into a dedicated module.

```
Turn 1: LLM generates program → execute → get result
    ↓
Turn 2: LLM sees result, generates next program → execute
    ↓
Turn 3: LLM responds without program → done
```

**Capabilities:**
- Used by both main LispAgent and SubAgent delegations
- Handles errors and timeouts gracefully
- Configurable `max_turns` to prevent infinite loops
- 30s default timeout for complex reasoning chains

### 3. SubAgent Delegation

Two complementary APIs:

| Function | Purpose |
|----------|---------|
| `SubAgent.delegate/2` | Core delegation - run a task with isolated tools and context |
| `SubAgent.as_tool/1` | Wrap a SubAgent as a PTC-Lisp tool for seamless orchestration |

The `as_tool/1` wrapper makes delegation transparent to the LLM - it calls SubAgents like any other tool.

### 4. Recursive Observability

Hierarchical tracing that solves the "recursive black box" problem:

- **Breadcrumbs**: Every turn in the AgenticLoop is recorded
- **Tool call interception**: Individual tool calls logged with arguments and results
- **Trace nesting**: SubAgent traces embedded in parent traces - unfold to see internal reasoning

```elixir
# Parent trace shows:
%{
  turn: 1,
  program: "(call \"customer-finder\" ...)",
  sub_trace: %{
    turns: [...],      # SubAgent's internal turns
    tool_calls: [...]  # Every tool the SubAgent called
  }
}
```

### 5. Usage Accounting

Token usage bubbles up through the agent hierarchy:

- Input, output, and reasoning tokens collected per agent
- Aggregated into parent's total usage
- "Mission cost" visible for complex chained tasks

### 6. Structured Error Propagation

Errors return structured fault maps, not strings:

```elixir
%{
  reason: :tool_not_found,
  tokens_consumed: %{input: 450, output: 120},
  partial_trace: [...],  # What was tried before failure
  step: :find_customer
}
```

This gives parent agents (and developers) actionable information for recovery or debugging.

### 7. Planner Agent

Validated that LLMs can generate structured plans as data (not prose):

```elixir
# Planner tools
planning_tools = %{
  "create_plan" => {fn steps -> steps end,
    "(steps [{:id :keyword :task :string :tools [:keyword] :needs [:keyword]}]) -> :plan"}
}

# LLM generates plan-as-data via tool call
{:ok, result} = PtcDemo.SubAgent.delegate(
  "Process urgent emails and draft replies",
  tools: planning_tools,
  context: %{available_tools: [:email_tools, :draft_tools]}
)
```

**Key behaviors observed:**
- LLM used `create_plan` tool to submit structured PTC-Map (not text description)
- Correctly identified step dependencies (`:needs` references previous step outputs)
- Proactively defined output shapes (e.g., `{:urgent_emails "list of IDs"}`)
- After planning, attempted immediate execution (interceptable for deterministic executor)

**Model note:** Gemini 2.5 Flash handled complex nested Lisp maps cleanly. Smaller models may struggle with structural complexity - model selection matters for planning tasks.

---

## What Was Proven

### The "Context Firewall" Works

The canonical test case: **"Find the top customer by revenue, then get all their orders."**

| Step | What Happened |
|------|---------------|
| 1 | Parent delegated "find customer" to SubAgent A |
| 2 | SubAgent A searched customers, found ID `501`, returned summary |
| 3 | Parent received only summary + ref (`customer_id: 501`) |
| 4 | Parent passed ID to SubAgent B for order lookup |
| 5 | SubAgent B returned orders for customer 501 |

**Result**: Parent context never saw the raw customer search data - only the extracted ID and summary. The context firewall held.

### Multi-Turn Chains Are Stable

SubAgents successfully execute multiple programs before returning. Error recovery works - when a program fails, the error is fed back and the LLM can retry with different approaches.

### Delegation Feels Native

With `as_tool/1`, the LLM treats SubAgents as regular tools. No special prompting or awareness of delegation mechanics required.

### Tracing Enables Debugging

The nested trace structure allows reconstructing the full execution path:
- Parent called SubAgent A (2 turns, 3 tool calls)
- SubAgent A returned, parent extracted ref
- Parent called SubAgent B (1 turn, 1 tool call)
- Total mission: 4 LLM calls, 4 tool executions, X tokens

### LLMs Generate Valid Plans

The planning spike validated that LLMs can produce structured, dependency-aware plans:

| Capability | Result |
|------------|--------|
| Structured output | Used `create_plan` tool, not prose |
| Dependency awareness | Correctly set `:needs` for step ordering |
| Output contracts | Defined extraction shapes proactively |
| Tool scoping | Referenced correct tool sets per step |

**Test scenario:** "Process urgent emails" → LLM generated 3-step plan:
1. Find urgent email IDs (`:email_tools`)
2. Read email bodies (`:needs [:urgent_emails]`, `:email_tools`)
3. Draft replies (`:needs [:email_bodies]`, `:draft_tools`)

This proves both **ad-hoc chaining** (dynamic SubAgent calls) and **formal planning** (structured multi-step orchestration) are viable patterns.

### 3. Hybrid Planning (Plan -> Adapt -> Execute) [VALIDATED]

The "Hybrid" pattern treats planning as a first-class cognitive step within the `AgenticLoop`. The model first generates a plan as text, then uses that plan as guidance for its tool executions.

**Findings from Spike:**
*   **Superior Coordination**: Hybrid agents generate much more sophisticated programs than pure ad-hoc agents. They are more likely to use `mapv` and `filter` to process items in batch.
*   **Reduced Turn Count**: By batching operations (e.g., Reading & Drafting for 10 emails in one program), turn counts were reduced by 50-70% for multi-item tasks.
*   **Confidence**: The planning phase remarkably reduces "stuttering" (asking redundant questions).
*   **Language Evolution**: To support the high-quality programs generated by the Hybrid pattern, PTC-Lisp was hardened with `do`, `if-let`, `memory/put`, and multi-arity `map`.

---

## Answered Questions

### Formal Planning Layer ✅

**Original question**: Is formal planning needed, or does ad-hoc chaining cover most use cases?

**Answer**: Both patterns are valid and now proven:

| Pattern | Use Case | Validated |
|---------|----------|-----------|
| Ad-hoc chaining | Dynamic, exploratory workflows | ✅ Customer → Orders |
| Formal planning | Predictable, multi-step orchestration | ✅ Email processing |

The LLM successfully generates plan-as-data with dependencies. A deterministic executor can then run steps with parallelism, retries, and checkpointing - or the LLM can execute immediately for simpler cases.

**Recommendation**: Use ad-hoc chaining for exploratory tasks, formal planning for production workflows requiring reliability guarantees.

---

### Ref-Driven Self-Correction [PROPOSED]

A critical improvement identified during the spike is moving from passive extraction to **active contract enforcement**.

**The Pattern**:
If a required reference (e.g., `:email_id`) extracts to `nil` or fails validation, the system does not return immediately. Instead:
1.  An error message is generated: *"Required ref 'email_id' was nil. Result was: [...]. Please include the missing field."*
2.  This error is fed back to the `AgenticLoop`.
3.  The SubAgent gets a limited number of **Ref Retries** (default: 1) to self-correct its output.

**Benefit**: This prevents "Silent Failures" where a mission fails 3 steps later because of a missing ID. It enforces a strict interface between agents without requiring complex parent-level retry logic.

---

## Open Questions

### Concurrent SubAgents

The tutorial shows parallel execution via `Task.async_stream`:

```elixir
tasks
|> Task.async_stream(fn {name, task, tools} ->
  PtcDemo.SubAgent.delegate(task, tools: tools)
end, max_concurrency: 3)
```

**Not yet validated**:
- Does trace nesting work correctly with concurrent sub-agents?
- Does usage accounting aggregate properly?
- Race conditions in shared state?

### Persistence

The tutorial mentions future persistence options:
- File-based (`Plan.load/save`)
- GitHub Issues (collaborative, auditable)

**Question**: Is in-memory tracing sufficient, or do long-running workflows need checkpointing?

### PTC-Lisp Language Extensions

The tutorial shows `defn` for reusable functions:

```clojure
(defn top-products [n]
  (-> (call "get_products") (sort-by :revenue :desc) (take n)))
```

**Current status**: Not implemented. The spike validated that pre-defined Elixir functions as tools work well.

**Question**: Does homoiconic plan execution (executor written in PTC-Lisp) add value, or is Elixir orchestration sufficient?

## State Management & Isolation

A key architectural pivot was the introduction of `memory/put` and `memory/get`. We have adopted a **Scoped Scratchpad** model rather than a Shared Blackboard.

### The Scoped Model (Private Scratchpad) [DECISION]
*   **Isolation**: Every agent/sub-agent has its own private memory map.
*   **Predictability**: When an agent uses `(memory/get :x)`, you are guaranteed it was set by that specific agent's logic.
*   **Composability**: Agents are "pure" in their boundary interaction—they only communicate via explicit parameters and results. This prevents "state leak" between sub-agents.
*   **Parallelism**: Since memory is not shared, sub-agents can be run concurrently without race conditions or naming collisions.

### Handling Shared State (Opt-in)
If shared state is required (e.g., an expensive API cache), it should be implemented as an **explicit tool** rather than a shared memory layer. This keeps the dependency visible in the agent's "instruction manual" and preserves the integrity of the execution trace.

---

## Conclusion: Orchestration Guidelines

### LLM-Generated Complexity

Bug fixes for `if-let` and nested bindings suggest LLMs generate more sophisticated Lisp than expected.

**Watch for**:
- Additional language constructs needed (see [#310](https://github.com/andreasronge/ptc_runner/issues/310) for `if-let`)
- Edge cases in the interpreter
- Whether to constrain or expand the language surface

### Timeout Configuration

Default increased to 30s for complex chains.

**Consider**:
- Per-delegation timeout configuration
- Progress signals for long-running sub-agents
- Graceful degradation vs hard timeout

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      Two Orchestration Patterns                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Pattern A: Ad-hoc Chaining          Pattern B: Formal Planning │
│  ─────────────────────────           ───────────────────────── │
│                                                                  │
│  Main Agent                          Planner Agent               │
│      │                                   │                       │
│      ├── delegate("find customer")       ├── create_plan(steps) │
│      │       └── SubAgent A              │                       │
│      │              └── returns ID       ▼                       │
│      │                              Deterministic Executor       │
│      ├── delegate("get orders", id)      │                       │
│      │       └── SubAgent B              ├── step 1 → SubAgent  │
│      │              └── returns orders   ├── step 2 → SubAgent  │
│      │                                   └── step 3 → SubAgent  │
│      ▼                                   │                       │
│  Result + refs                       Plan + history + refs       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        Shared Infrastructure                     │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ AgenticLoop │  │ RefExtractor│  │   Tracer    │              │
│  │ (multi-turn)│  │ (paths/fns) │  │ (nested)    │              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
│                                                                  │
│  ┌─────────────────────────────────────────────────┐            │
│  │              SubAgent.as_tool/1                  │            │
│  │  Wraps any SubAgent as a callable tool           │            │
│  └─────────────────────────────────────────────────┘            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Next Steps (Suggested)

1. **Build deterministic executor** - Take plan-as-data from Planner Agent, execute steps with parallelism/retries

2. **Validate concurrency** - Run the parallel SubAgent example and verify tracing/accounting

3. **Build real workflow** - Email processing end-to-end using the planning pattern

4. **Document failure modes** - Catalog common errors and recovery strategies

5. **Add `if-let` support** - See [#310](https://github.com/andreasronge/ptc_runner/issues/310)

---

## Files Changed

| Module | Purpose |
|--------|---------|
| `PtcDemo.RefExtractor` | Deterministic value extraction from results |
| `PtcDemo.AgenticLoop` | Reusable multi-turn execution logic |
| `PtcDemo.SubAgent` | `delegate/2` and `as_tool/1` APIs |
| `PtcDemo.LispAgent` | Updated to use shared AgenticLoop |
| `PtcRunner.Interpreter` | Bug fixes for `if-let`, nested bindings |

---

## Verification & Observed Issues

While the core patterns were validated, the following issues were identified during testing. These serve as a roadmap for hardening the library implementation:

| Issue | Description | Status |
| :--- | :--- | :--- |
| **Numeric Safety** | `100 + id` crashes when `id` is nil (Missing nil-safe arithmetic). | 📌 Backlog |
| **Missing `conj`** | LLM tried `(conj acc item)` which failed. Needed for state updates. | 📌 Backlog |
| **Missing `str`** | LLM tried `(str "..." id)` for string concatenation. | 📌 Backlog |
| **Missing `parse-long`** | Clojure 1.11+ `(parse-long "42")` → 42 (nil if unparseable). Needed for type coercion. | 📌 Backlog |
| **Missing `parse-double`** | Clojure 1.11+ `(parse-double "3.14")` → 3.14 (nil if unparseable). Needed for type coercion. | 📌 Backlog |
| **Data Path Confusion** | LLM used `[:result :id]` instead of `[:result 0 :id]` for list-wrapped results. | 📌 Backlog |
| **Comparator Mismatch** | LLM used `(sort-by :total >)`, but `>` is not a valid function name in the env. | 📌 Backlog |
| **Tool Availability** | Planner test sometimes lacks email tools in the execution phase if not explicitly listed. | 📌 Backlog |

## Key LLM Behavior Observations

1.  **Sophistication**: Gemini 2.5 Flash naturally generates complex Clojure-like programs using `mapv`, `filter`, `where`, `reduce`, and nested `let` bindings.
2.  **Structural Integrity**: Plans are generated with correct dependency graphs and tool-scoping. The LLM respects the "refs" system for passing data.
3.  **Self-Correction**: Faced with errors, the LLM attempts to add guards (using `when`, `if`, or `map?`) to prevent failure in the next turn.
4.  **Arity Matching**: The LLM is highly sensitive to function arity. It correctly used multi-arity `map` once it was available.

---

## Summary

The spike validated the **primitives + patterns** architecture:

| Primitive | Purpose | Status |
|-----------|---------|--------|
| `run/2` | Run task in isolation | ✅ Core API |
| `as_tool/2` | Wrap SubAgent as tool | ✅ Core API |
| `RefExtractor` | Deterministic value extraction | ✅ Core API |
| `Loop` | Multi-turn execution | ✅ Core API |
| `memory/*` | Per-agent state | ✅ Core API |

**Design philosophy**: The library provides primitives, not patterns. Orchestration patterns (Hybrid, PlanExecutor, spawn_agent) are examples built from primitives—users compose their own patterns as needed.

The framework is production-ready with:
- **Composable primitives**: Small set of building blocks for any orchestration pattern
- **Recursive observability**: Nested traces show exactly what each agent did
- **Full usage accounting**: Token costs bubble up through the hierarchy
- **Robust error propagation**: Structured faults with partial traces
- **Proven data flow isolation**: Context firewall keeps parent agents lean

The remaining open questions center on infrastructure (concurrency, persistence) and language extensions (`if-let`, `defn`) - the core architecture is validated.
