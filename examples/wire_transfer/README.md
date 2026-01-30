# Wire Transfer with Manager Approval

A conceptual example demonstrating the v0.7 Journaled Task System (Navigator pattern) with idempotent execution, async waiting, and human-in-the-loop approval — without any suspension primitives.

## Scenario

> "Transfer $5,000 to Bob's account."

This requires three steps:
1. **Prepare** the wire transfer (side effect: reserves funds)
2. **Wait** for manager approval (async: human decision)
3. **Execute** the transfer (side effect: moves money)

The Navigator handles crashes, restarts, and multi-day waits by re-navigating from journal state.

## The Workflow

### Turn 1: Prepare and Request Approval

The agent runs for the first time with an empty journal.

**LLM generates:**
```clojure
(do
  (task "prepare_wire_bob_5000"
    (tool/prepare_wire {:to "bob" :amount 5000}))

  (task "request_approval_bob_5000"
    (tool/request_approval {:type :wire :amount 5000 :to "bob"}))

  (return {:status :waiting :msg "Pending manager approval"}))
```

**Elixir app code:**
```elixir
{:ok, step} = SubAgent.run(agent, context: %{user_id: 1})
# step.result => %{status: :waiting, msg: "Pending manager approval"}
# step.journal => %{
#   "prepare_wire_bob_5000" => "hold_abc",
#   "request_approval_bob_5000" => %{request_id: "req_789"}
# }
MyRepo.save_journal(workflow_id, step.journal)
```

The app sees `:waiting` and renders an "Approve / Reject" button in the Phoenix UI.

### Between Turns: The App Writes the Decision

When the manager clicks "Approve", the **application code** (not the LLM, not a tool) writes the decision directly into the journal:

```elixir
journal = MyRepo.get_journal(workflow_id)
journal = Map.put(journal, "manager_decision_bob_5000", :approved)
MyRepo.save_journal(workflow_id, journal)
```

This is the key insight: **the journal is just a map, and anyone can write to it between runs.**

### Turn 2: Re-invoke and Execute

The app re-runs the agent with the updated journal.

```elixir
journal = MyRepo.get_journal(workflow_id)
{:ok, step} = SubAgent.run(agent, context: %{user_id: 1, journal: journal})
```

**Mission Log injected into the LLM's prompt:**
```text
## Mission Log (Completed Tasks)
- [x] prepare_wire_bob_5000: "hold_abc"
- [x] request_approval_bob_5000: {request_id: "req_789"}
- [x] manager_decision_bob_5000: :approved
```

**LLM generates:**
```clojure
(do
  ;; These return cached results instantly — no side effects
  (task "prepare_wire_bob_5000"
    (tool/prepare_wire {:to "bob" :amount 5000}))

  (task "request_approval_bob_5000"
    (tool/request_approval {:type :wire :amount 5000 :to "bob"}))

  ;; Decision is in the journal — no need to wait
  (let [decision (task "manager_decision_bob_5000" nil)]
    (if (= decision :approved)
      (task "execute_wire_bob_5000"
        (tool/execute_wire {:hold_id "hold_abc" :to "bob" :amount 5000}))
      (task "cancel_wire_bob_5000"
        (tool/cancel_hold {:hold_id "hold_abc"})))))
```

The transfer executes. If the process crashes and re-runs, `"execute_wire_bob_5000"` is already in the journal — money moves exactly once.

## What This Proves

| Property | How |
|----------|-----|
| **Idempotency** | `prepare_wire_bob_5000` runs once; re-invocations return the cached hold ID |
| **Async waiting** | No `(checkpoint)` or `SubAgent.resume/3` — the agent returns `{:status :waiting}` and the app re-invokes later |
| **Human-in-the-loop** | The app writes the manager's decision to the journal; the LLM reads it from the Mission Log |
| **Data propagation** | The LLM uses `"hold_abc"` from the Mission Log to call `execute_wire` |
| **Branching** | The LLM checks the decision and takes a different path if rejected |
| **Semantic IDs** | Task IDs encode intent + data (`"prepare_wire_bob_5000"`) preventing stale cache |

## Key Design Points

- **No suspension primitives.** "Waiting" is just a missing fact in the journal.
- **The app owns the journal.** Any code can write to it between agent runs — Phoenix controllers, Oban workers, webhook handlers.
- **The LLM re-plans every turn.** If the manager rejects, the LLM writes cancellation code. No plan-reality drift.
- **Crash-safe at every step.** Each `(task ...)` is atomic. Re-run from any point and the journal prevents duplicate side effects.
- **Task IDs are a shared contract.** The naming convention (e.g., `"manager_decision_bob_5000"`) must be agreed between the system prompt and the application code. The prompt tells the LLM: *"When checking for external decisions, use the task ID `manager_decision_RECIPIENT_AMOUNT`."* The app writes to that same key. Without this contract, the LLM might look up `"approval_status"` while the app wrote to `"manager_decision_bob_5000"`, and the pattern silently breaks.

## Running the Example

Start IEx:

```bash
cd examples/wire_transfer
mix deps.get
iex -S mix
```

### Initiate the transfer

```elixir
# Turn 1: Agent prepares wire and requests approval
{:ok, step} = WireTransfer.run(%{}, "bob", 5000)
step.return
# => %{status: :waiting, msg: "Pending manager approval"}

step.journal
# => %{
#   "prepare_wire_bob_5000" => "hold_bob_5000",
#   "request_approval_bob_5000" => %{"request_id" => "req_bob_5000"}
# }
```

### Simulate manager approval

The app (not the LLM) writes the decision into the journal:

```elixir
journal = Map.put(step.journal, "manager_decision_bob_5000", :approved)
```

### Re-invoke with the updated journal

```elixir
# Turn 2: Agent sees approval, executes wire
{:ok, step} = WireTransfer.run(journal, "bob", 5000)
step.return
# => %{status: :completed, wire_id: "wire_bob_5000"}
```

### Simulate a crash and re-run

```elixir
# Re-running with the same journal is safe — all tasks are cached
{:ok, step} = WireTransfer.run(step.journal, "bob", 5000)
step.return
# => %{status: :completed, wire_id: "wire_bob_5000"}
# No side effects re-executed. Money moved exactly once.
```

### Simulate rejection

```elixir
# Alternative: manager rejects
{:ok, step} = WireTransfer.run(%{}, "bob", 5000)
journal = Map.put(step.journal, "manager_decision_bob_5000", :rejected)

{:ok, step} = WireTransfer.run(journal, "bob", 5000)
step.return
# => %{status: :cancelled, msg: "Hold released"}
```

## See Also

- [v0.7 Plan: Journaled Task System](../../docs/plans/v0.7-journaled-tasks.md)
- [ROADMAP.md](../../ROADMAP.md) — v0.7 section
