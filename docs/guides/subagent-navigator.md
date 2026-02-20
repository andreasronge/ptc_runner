# Navigator Pattern: Journaled Tasks

Use the Navigator pattern to build crash-safe, resumable workflows. Instead of keeping an agent process alive, re-invoke the agent with a journal that records what's already done.

## Prerequisites

- Familiarity with [SubAgent basics](subagent-getting-started.md)
- Multi-turn execution (see [Advanced Topics](subagent-advanced.md))

## Core Idea

The Navigator is a stateless agent that "re-navigates" its mission by checking a journal. Each `(task "id" expr)` call either returns a cached result (if already done) or executes and records the result.

```elixir
# Turn 1: empty journal
{:ok, step} = SubAgent.run(agent, llm: llm, context: %{}, journal: %{})
# step.journal => %{"fetch-data" => [1, 2, 3]}

# Turn 2: re-invoke with saved journal
{:ok, step} = SubAgent.run(agent, llm: llm, journal: saved_journal)
# "fetch-data" returns cached result — no duplicate API call
```

The app owns persistence. Save `step.journal` to your database between runs; pass it back on re-invocation.

## How It Works

1. The agent is created with `journaling: true` — this includes `task`/`step-done`/`task-reset` documentation in the LLM's system prompt
2. The agent receives a journal (possibly empty) via the `journal:` runtime option
3. The engine injects a **Mission Log** into the system prompt showing completed tasks
4. The LLM sees what's done and generates code for remaining work
5. `(task "id" expr)` checks the journal: cache hit skips `expr`, cache miss evaluates and records
6. The updated journal is returned in `step.journal`

## The Re-run Pattern

A typical workflow has three phases: initial run, external event, and re-invocation.

### Phase 1: Initial Run

```elixir
agent = SubAgent.new(
  prompt: "Process order {{order_id}}: charge card, then ship item",
  signature: "(order_id :int) -> {status :keyword}",
  tools: %{"charge_card" => &Billing.charge/1, "ship_item" => &Shipping.ship/1},
  max_turns: 5,
  journaling: true
)

{:ok, step} = SubAgent.run(agent, llm: llm, context: %{order_id: 42}, journal: %{})
# step.journal => %{"charge_order_42" => "tx_abc"}
# step.return => %{status: :waiting}

MyRepo.save_journal(order_id, step.journal)
```

The LLM generates:

```clojure
(do
  (task "charge_order_42" (tool/charge_card {:order_id 42}))
  (return {:status :waiting}))
```

### Phase 2: External Event

Something happens outside the agent — a webhook, a human approval, a timer:

```elixir
journal = MyRepo.get_journal(order_id)
journal = Map.put(journal, "payment_confirmed_42", true)
MyRepo.save_journal(order_id, journal)
```

The journal is a plain map. Any code can write to it between runs.

### Phase 3: Re-invocation

```elixir
journal = MyRepo.get_journal(order_id)
{:ok, step} = SubAgent.run(agent, llm: llm, context: %{order_id: 42}, journal: journal)
# step.return => %{status: :shipped}
```

The LLM sees the Mission Log:

```text
## Mission Log (Completed Tasks)
- [done] charge_order_42: "tx_abc"
- [done] payment_confirmed_42: true
```

It generates code that skips completed work and continues:

```clojure
(do
  (task "charge_order_42" (tool/charge_card {:order_id 42}))       ;; cached
  (task "payment_confirmed_42" nil)                                 ;; cached
  (task "ship_order_42" (tool/ship_item {:tx_id "tx_abc"}))        ;; executes
  (return {:status :shipped}))
```

## Semantic Task IDs

Task IDs are the contract between the LLM and your application. Follow these guidelines:

### Encode Intent and Data

IDs should describe *what* was done and *to what*, preventing stale cache hits if the agent re-plans.

| Bad | Good | Why |
|-----|------|-----|
| `"step_1"` | `"charge_order_42"` | Positional IDs break when the plan changes |
| `"fetch"` | `"fetch_users_active"` | Ambiguous IDs cause wrong cache hits |
| `"task_a"` | `"send_email_alice_welcome"` | Semantic IDs are self-documenting |

### One ID Per Side-Effect

Each task should wrap exactly one side-effect. Avoid nesting tasks or combining multiple side-effects under one ID:

```clojure
;; Good: one task per side-effect
(do
  (task "charge_order_42" (tool/charge_card {:order_id 42}))
  (task "ship_order_42" (tool/ship_item {:order_id 42})))

;; Bad: nested tasks
(task "process_order"
  (do (task "charge" (tool/charge_card {:order_id 42}))
      (task "ship" (tool/ship_item {:order_id 42}))))
```

### Naming Convention for External Decisions

When the application writes decisions into the journal between runs, use a shared naming convention:

```elixir
# In your system prompt: "Use task ID manager_decision_RECIPIENT_AMOUNT
#   for approval lookups"
# In your app code:
journal = Map.put(journal, "manager_decision_bob_5000", :approved)
```

The prompt tells the LLM the naming pattern; the app writes to the same key. Without this contract, the LLM might look up `"approval_status"` while the app wrote to `"manager_decision_bob_5000"`.

## Semantic Progress with Plans

For multi-step workflows, define a `plan:` to get automatic progress tracking. The LLM reports completion via `(step-done "id" "summary")` and sees a progress checklist in feedback messages.

```elixir
agent = SubAgent.new(
  prompt: "Process order {{order_id}}",
  plan: ["Charge card", "Ship item", "Send confirmation"],
  tools: %{"charge_card" => &Billing.charge/1, "ship_item" => &Shipping.ship/1},
  max_turns: 10,
  journaling: true
)
```

The plan accepts a string list (auto-numbered IDs "1", "2", ...) or explicit `{id, description}` tuples:

```elixir
plan: [{"charge", "Charge card"}, {"ship", "Ship item"}]
```

The LLM marks steps complete with summaries:

```clojure
(do
  (task "charge_order_42" (tool/charge_card {:order_id 42}))
  (step-done "charge" (str "Charged " tx_id))
  (task "ship_order_42" (tool/ship_item {:order_id 42}))
  (step-done "ship" "Shipped via FedEx"))
```

Progress appears as a markdown checklist in feedback messages:

```markdown
## Progress
- [x] Charge card — Charged tx_abc
- [x] Ship item — Shipped via FedEx
- [ ] Send confirmation
```

### Clearing Cached Tasks

Use `(task-reset "id")` to clear a cached task result from the journal, forcing re-execution on the next `(task "id" expr)` call:

```clojure
(task-reset "fetch-users")  ;; clears journal entry
(task "fetch-users" (tool/get-users {}))  ;; re-executes
```

`task-reset` only affects the journal (task cache). Step summaries from `step-done` are independent.

### Deferred Visibility

`step-done` summaries use **deferred visibility**: they appear in the progress checklist on the *next* turn, not the current one. If the current turn errors, its summaries are discarded entirely. This prevents the LLM from seeing "checked off" steps in the same turn it marks them, encouraging it to verify results before reporting completion.

Journal entries from `(task ...)` are committed immediately — even if a later expression in the same turn fails, the task cache is preserved. This makes tasks reliable checkpoints while keeping semantic progress honest.

### Limitations

`step-done` and `task-reset` must be called at top level in sequential `do` blocks. They do not work inside `pmap`, `pcalls`, or `map` closures due to process isolation. Call `step-done` after parallel work completes.

See [PTC-Lisp Specification](../ptc-lisp-specification.md) — sections 5.14 and 5.15 for full reference.

## Failure Semantics

- If `expr` succeeds, the result is committed to the journal
- If `expr` calls `(fail ...)` or crashes, the result is **not** committed and the failure propagates
- Re-running after a failure safely retries the failed task

This makes each `(task ...)` an atomic checkpoint.

## Progressive Enhancement

`(task)` works without a journal — it executes `expr` normally without caching. A trace warning is emitted so you know idempotency is inactive. This lets you adopt the pattern incrementally.

## Planning Design Space

PtcRunner's planning sits at a specific point in the broader agentic AI landscape. Understanding the alternatives helps choose the right approach for your use case.

### Plan Creation

| Approach | Description | PtcRunner |
|----------|-------------|-----------|
| LLM-generated | A planner agent produces the steps | Supported — run a planner SubAgent, pass result to `plan:` |
| Developer-specified | Hard-coded step list | Supported — pass a literal list to `plan:` |
| Emergent (no plan) | Agent decides dynamically each turn | Default when `plan:` is omitted (ReAct-style) |

### Plan Mutability

The `plan:` field is immutable once the agent starts. The LLM adapts by doing out-of-plan work (extra `step-done` calls appear under "Out-of-Plan Steps"). For full re-planning, run a new SubAgent with an updated plan.

This is a deliberate tradeoff: immutable plans are predictable and auditable. Dynamic re-planning (as in LangGraph or smolagents) is more adaptive but harder to reason about.

### Progress Visibility

Most frameworks inject the full plan into the system prompt. PtcRunner renders a progress checklist in **user feedback messages** instead. This keeps the system prompt cacheable and avoids context pollution as the plan grows.

| Framework | Plan visibility |
|-----------|----------------|
| CrewAI | Full plan injected into task context |
| LangGraph | Executor receives current step + query |
| PtcRunner | Checklist in feedback messages (cacheable) |

### Caching vs Reporting

PtcRunner separates two concerns that most frameworks conflate:

- **`task`** — idempotent caching. Prevents re-execution on retry or re-invocation. Raw tool results.
- **`step-done`** — semantic progress. Human-readable summary for the checklist. No caching effect.

Use both together: `task` for reliability, `step-done` for visibility.

### Checkpoint Recovery

The journal acts as an external checkpoint store. Save `step.journal` between runs; pass it back on re-invocation. The agent skips completed `task` calls and continues from where it left off.

This differs from in-process checkpointing (LangGraph's state snapshots) — PtcRunner agents are stateless, and the application owns persistence.

### Choosing a Planning Style

| Scenario | Recommendation |
|----------|----------------|
| Well-defined multi-step workflow | Use `plan:` with explicit step IDs |
| Exploratory or open-ended task | Omit `plan:`, let the agent decide (ReAct) |
| Two-phase: plan then execute | Run a planner SubAgent first, feed `plan.return.steps` to executor |
| Long-running with retries | Use `plan:` + journal persistence for checkpoint recovery |

## See Also

- [Meta Planner](subagent-meta-planner.md) — Autonomous planning with self-correction
- [Composition Patterns](subagent-patterns.md) — Chaining, parallel execution, orchestration
- [Wire Transfer Example](../../examples/wire_transfer/README.md) — Full human-in-the-loop workflow
- [PTC-Lisp Specification](../ptc-lisp-specification.md) — Sections 5.13–5.15: `task`, `step-done`, `task-reset`
- `PtcRunner.SubAgent.run/2` — API reference
