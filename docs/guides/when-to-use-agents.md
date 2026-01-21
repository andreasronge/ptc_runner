# When to Use Agentic Workflows

This guide explains when LLM-driven orchestration adds value over pure Elixir code, and introduces the task system for reliable execution of side effects.
Notice, the task API will be available in 0.6.0 see ROADMAP.md

## The Core Question

If tools contain the business logic, why not write everything in Elixir? What does the LLM actually contribute?

The answer lies in understanding *what* each layer does best:

| Layer | Responsibility | Strength |
|-------|---------------|----------|
| **LLM Orchestration** | Decides *what* to do | Understanding, judgment, adaptation |
| **Elixir Tools** | Executes *how* to do it | Correctness, reliability, performance |

## When Pure Elixir is Better

Write deterministic Elixir when:

```elixir
# Just write this - no LLM needed
def process_expense(expense) do
  with {:ok, expense} <- validate(expense),
       {:ok, expense} <- check_budget(expense),
       {:ok, _} <- notify_manager(expense) do
    {:ok, approve(expense)}
  end
end
```

**Use Elixir when:**
- Steps are **known at compile time**
- Logic is **deterministic** (if X then Y)
- Inputs are **structured** (not natural language)
- Correctness is **critical** (payments, authentication)
- Volume is **high** (cost/latency matters)

## When LLM Orchestration Adds Value

### 1. Natural Language Understanding

```
User: "Cancel my subscription but keep my data for 30 days"
```

An LLM interprets intent and maps to concrete actions:

```clojure
(do
  (task "cancel" (tool/cancel_subscription user_id))
  (task "retention" (tool/set_data_retention user_id 30)))
```

Writing this in Elixir requires anticipating every possible phrasing. The LLM handles the infinite variety of human expression.

### 2. Dynamic Routing Based on Content

```
User: "Handle this customer complaint"
Complaint: "I was charged twice and the product arrived broken"
```

The LLM reads the complaint and decides the workflow:

```clojure
(do
  (task "refund" (tool/process_refund order_id))      ; Understands "charged twice"
  (task "replace" (tool/ship_replacement order_id))   ; Understands "broken"
  (task "respond" (tool/send_apology customer_id)))
```

The **what to do** emerges from understanding unstructured text - something Elixir pattern matching cannot easily express.

### 3. Search → Reason → Act Loops

```
User: "Find our security policy about remote access and summarize the key requirements"
```

The path isn't known upfront:

```clojure
;; Turn 1: Search
(let [results (tool/search {:query "remote access security"})]
  (store :search_results results))

;; Turn 2: Evaluate results, maybe refine
(let [docs (tool/fetch_all (:ids data/search_results))]
  (if (empty? (filter #(contains? % "VPN") docs))
    (tool/search {:query "VPN requirements"})  ; Refine search
    (store :docs docs)))

;; Turn 3: Synthesize answer
(return {:summary "..." :key_requirements [...]})
```

The agent adapts based on what it discovers. A static Elixir workflow would need to anticipate all possible search outcomes.

### 4. Judgment Calls on Unstructured Data

Some decisions require understanding context, tone, or nuance:

```elixir
# Hard to express in Elixir:
def should_escalate?(ticket) do
  # Is the customer frustrated?
  # Is this a recurring issue?
  # Does the tone suggest urgency?
  ???
end
```

An LLM can make this judgment:

```clojure
(let [ticket data/current_ticket
      sentiment (tool/analyze_sentiment (:body ticket))
      history (tool/get_customer_history (:customer_id ticket))]
  (if (or (= sentiment :angry)
          (> (count (:recent_tickets history)) 3))
    (task "escalate" (tool/escalate_to_human ticket))
    (task "respond" (tool/auto_respond ticket))))
```

### 5. Adaptive Multi-Step Workflows

```
User: "Book me a flight to NYC for under $500, and a hotel near Times Square"
```

The workflow adapts to availability and constraints:

```clojure
(let [flights (tool/search_flights {:to "NYC" :max_price 500})]
  (if (empty? flights)
    (do
      (tool/ask_user "No flights under $500. Increase to $600?")
      ;; ... continue based on response
    )
    (let [flight (task "book_flight" (tool/book (first flights)))
          hotels (tool/search_hotels {:near "Times Square"
                                      :dates (:dates flight)})]
      (task "book_hotel" (tool/book (best_value hotels))))))
```

## The Boundary Visualized

```
┌─────────────────────────────────────────────────────┐
│  User: "Process this expense report reasonably"     │
└───────────────────────┬─────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────┐
│  LLM Orchestration                                  │
│  • Understands "reasonably"                         │
│  • Decides workflow based on expense type           │
│    - Standard expense? → auto-approve               │
│    - Large amount? → needs review                   │
│    - Missing receipt? → request it                  │
└───────────────────────┬─────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────┐
│  Elixir Tools (execute decisions correctly)         │
│  • validate_expense/1  - enforces policy rules      │
│  • approve_expense/1   - updates database           │
│  • request_receipt/1   - sends email notification   │
└─────────────────────────────────────────────────────┘
```

## Why Tasks Matter

When agents execute side effects (sending emails, making API calls, updating databases), we need guarantees:

1. **Exactly-once execution** - Don't send the same email twice
2. **Resumability** - If the agent crashes mid-workflow, resume where we left off
3. **Visibility** - Know what's been done and what's pending

### The Problem Without Tasks

```clojure
;; Dangerous: If agent retries, emails send multiple times
(do
  (tool/send_email "alice@co" "Meeting confirmed")
  (tool/send_email "bob@co" "Meeting confirmed"))
```

### The Solution: Task Wrapping

```clojure
;; Safe: Each task runs exactly once, results are cached
(do
  (task "notify_alice" (tool/send_email "alice@co" "Meeting confirmed"))
  (task "notify_bob" (tool/send_email "bob@co" "Meeting confirmed")))
```

Tasks provide:

| Benefit | Description |
|---------|-------------|
| **Idempotency** | Same task ID always returns cached result |
| **Progress tracking** | See which tasks are pending/completed |
| **Resume support** | Restart workflow without re-executing completed tasks |
| **Audit trail** | Know exactly what side effects occurred |

### What the LLM Sees

Each turn, the LLM sees task progress:

```
## Task Progress
✓ notify_alice: completed - {message_id: "msg_123"}
✓ notify_bob: completed - {message_id: "msg_456"}
○ schedule_followup: pending
```

This helps the agent understand what's done and what remains.

## Design Principle: Tools for Logic, Tasks for Orchestration

The LLM should orchestrate, not implement business logic:

```elixir
# Developer defines tools with business logic
tools: [
  %{name: "validate_expense",
    handler: &MyPolicy.validate/1,
    description: "Validates expense against company policy"},
  %{name: "approve_expense",
    handler: &MyWorkflow.approve/1}
]
```

The LLM's job is to wire data to tools and handle results:

```clojure
(let [expense (first data/pending)
      result (task "validate" (tool/validate_expense expense))]
  (if (:valid result)
    (task "approve" (tool/approve_expense expense))
    (fail (:errors result))))
```

**Key insight:** The policy logic ("expenses over $1000 need approval") lives in your Elixir code where it's testable and auditable. The LLM decides *when* to validate and *what* to do with results.

## Decision Framework

Ask these questions to decide between pure Elixir and agentic orchestration:

| Question | If Yes → | If No → |
|----------|----------|---------|
| Does input require natural language understanding? | Agent | Elixir |
| Are the steps known at compile time? | Elixir | Agent |
| Does the workflow adapt based on intermediate results? | Agent | Elixir |
| Is correctness more important than flexibility? | Elixir | Agent |
| Does the decision require judgment or context? | Agent | Elixir |

## Summary

**Use LLM orchestration when:**
- The "what to do" requires understanding language
- Decisions depend on judgment, not just rules
- The workflow adapts to discoveries
- Handling the infinite variety of human requests

**Use Elixir tools for:**
- The "how to do it" where correctness matters
- Business logic that must be testable and auditable
- Deterministic operations with known steps
- Performance-critical or high-volume operations

**Use tasks when:**
- Executing side effects (API calls, emails, database writes)
- You need exactly-once guarantees
- Workflows might be interrupted and resumed
- You need visibility into what's been completed

## See Also

- [Getting Started](subagent-getting-started.md) - Build your first SubAgent
- [Core Concepts](subagent-concepts.md) - Context, firewall, and completion
- [Patterns](subagent-patterns.md) - Common orchestration patterns
