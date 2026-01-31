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
{:ok, step} = SubAgent.run(agent, llm: llm, context: %{journal: saved_journal})
# "fetch-data" returns cached result — no duplicate API call
```

The app owns persistence. Save `step.journal` to your database between runs; pass it back on re-invocation.

## How It Works

1. The agent receives a journal (possibly empty) via the `journal:` option
2. The engine injects a **Mission Log** into the system prompt showing completed tasks
3. The LLM sees what's done and generates code for remaining work
4. `(task "id" expr)` checks the journal: cache hit skips `expr`, cache miss evaluates and records
5. The updated journal is returned in `step.journal`

## The Re-run Pattern

A typical workflow has three phases: initial run, external event, and re-invocation.

### Phase 1: Initial Run

```elixir
agent = SubAgent.new(
  prompt: "Process order {{order_id}}: charge card, then ship item",
  signature: "(order_id :int) -> {status :keyword}",
  tools: %{"charge_card" => &Billing.charge/1, "ship_item" => &Shipping.ship/1},
  max_turns: 5
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

## Failure Semantics

- If `expr` succeeds, the result is committed to the journal
- If `expr` calls `(fail ...)` or crashes, the result is **not** committed and the failure propagates
- Re-running after a failure safely retries the failed task

This makes each `(task ...)` an atomic checkpoint.

## Progressive Enhancement

`(task)` works without a journal — it executes `expr` normally without caching. A trace warning is emitted so you know idempotency is inactive. This lets you adopt the pattern incrementally.

## See Also

- [Composition Patterns](subagent-patterns.md) — Chaining, parallel execution, orchestration
- [Wire Transfer Example](../../examples/wire_transfer/README.md) — Full human-in-the-loop workflow
- [PTC-Lisp Specification](../ptc-lisp-specification.md) — Section 5.13: `task` reference
- `PtcRunner.SubAgent.run/2` — API reference
