# Core Concepts

This guide covers the foundational concepts of SubAgents: context management, the firewall convention, memory, and error handling.

## The Context Firewall

SubAgents solve a fundamental problem: LLMs need information to make decisions, but context windows are expensive and limited. The **Context Firewall** lets agents work with large datasets while keeping the parent context lean.

```
┌─────────────┐                      ┌─────────────┐
│ Main Agent  │ ── "Find urgent  ──► │  SubAgent   │
│ (strategic) │     emails"          │ (isolated)  │
│             │                      │             │
│  Context:   │      CONTRACT:       │  Has tools: │
│  ~100 tokens│   {summary, _ids}    │  - list     │
│             │                      │  - search   │
│             │ ◄── validated ─────  │             │
│             │     data only        │  Processes  │
│             │                      │  50KB data  │
└─────────────┘                      └─────────────┘
```

The parent only sees what the signature exposes. Heavy data stays inside the SubAgent.

## The Firewall Convention (`_` prefix)

Fields prefixed with `_` are **firewalled**:

```elixir
signature: "{summary :string, count :int, _email_ids [:int]}"
```

Visibility rules:

| Location | Normal Fields | Firewalled (`_`) |
|----------|---------------|------------------|
| Lisp context (`ctx/`) | Full value | Full value |
| LLM prompt history | Visible | Hidden (`<Firewalled>`) |
| Parent LLM schema | Visible | Omitted |
| Elixir `step.return` | Included | Included |

The firewall protects LLM context windows, not your Elixir code. Your application always has full access.

### Example: Email Processing

```elixir
# Step 1: Find emails (returns firewalled IDs)
{:ok, step1} = PtcRunner.SubAgent.run(
  "Find all urgent emails",
  signature: "{summary :string, count :int, _email_ids [:int]}",
  tools: email_tools,
  llm: llm
)

step1.return.summary     #=> "Found 3 urgent emails"
step1.return.count       #=> 3
step1.return._email_ids  #=> [101, 102, 103]  # Available to Elixir!

# Step 2: Process those emails
# The _email_ids are available in ctx/ even though the LLM can't "see" them
{:ok, step2} = PtcRunner.SubAgent.run(
  "Draft replies for these {{count}} urgent emails",
  context: step1,  # Auto-chains return + signature
  tools: drafting_tools,
  llm: llm
)
```

In Step 2, the LLM:
- **Knows** there are 3 emails (public data)
- **Cannot see** the actual IDs in its prompt
- **Can use** `ctx/_email_ids` in its generated programs

## Context (`ctx/`)

Values passed to `context:` are available via the `ctx/` prefix in PTC-Lisp:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Get details for order {{order_id}}",
  context: %{order_id: "ORD-123", customer_tier: "gold"},
  tools: order_tools,
  llm: llm
)
```

The LLM can reference these in its programs:

```clojure
(call "get_order" {:id ctx/order_id})
(if (= ctx/customer_tier "gold")
  (call "apply_discount" {:rate 0.1})
  nil)
```

### Template Expansion

The `{{placeholder}}` syntax in prompts expands from context:

```elixir
prompt: "Find emails for {{user.name}} about {{topic}}"
context: %{user: %{name: "Alice"}, topic: "billing"}
# Expands to: "Find emails for Alice about billing"
```

Every placeholder must have a matching context key or signature parameter.

### Chaining Context

When passing a previous `Step` to `context:`, both the return data and signature are extracted:

```elixir
# These are equivalent:
run(prompt, context: step1.return, context_signature: step1.signature)
run(prompt, context: step1)  # Auto-extraction
```

## Memory (`memory/`)

Each agent has private memory persisting across turns within a single `run`:

```clojure
;; Store intermediate results
(memory/put :processed_ids [1 2 3])

;; Retrieve later
(memory/get :processed_ids)

;; Shorthand access
memory/processed_ids
```

Memory is:
- **Scoped per-agent** - SubAgents don't share memory with parents or siblings
- **Turn-persistent** - Survives across turns within one `run` call
- **Hidden from prompts** - Not shown in LLM conversation history

Use memory for:
- Caching expensive computations
- Tracking state across turns
- Storing data too large for context

## Error Handling

SubAgents handle errors at three levels:

### 1. Turn Errors (Recoverable)

Syntax errors, tool failures, and validation errors are fed back to the LLM. It sees the error and can adapt:

```clojure
;; Check if previous turn failed
(if ctx/fail
  (call "cleanup" {:failed_op (:op ctx/fail)})
  (call "proceed" ctx/items))
```

The `ctx/fail` structure:

```elixir
%{
  reason: :parse_error | :tool_error | :validation_error,
  message: "Human-readable description",
  op: "tool_name",      # If tool-related
  details: %{}          # Additional context
}
```

### 2. Mission Failures (Explicit)

When the agent determines it cannot complete the mission, it calls `fail`:

```clojure
(let [user (call "get_user" {:id 123})]
  (if (nil? user)
    (fail {:reason :not_found
           :message "User 123 does not exist"})
    (call "process" user)))
```

Result: `{:error, step}` where `step.fail` contains the error.

### 3. System Crashes

Programming bugs in your tool functions follow "let it crash" - they're returned as internal errors for developer investigation.

## Built-in Special Forms

Every SubAgent has two built-in special forms for termination:

### `return` - Mission Success

```clojure
(return {:name "Widget" :price 99.99})
```

- Validates data against the signature
- If invalid, the LLM sees the error and can retry
- On success, the loop ends and `run/2` returns `{:ok, step}`

### `fail` - Mission Failure

```clojure
(fail {:reason :not_found :message "No matching items"})
```

- Terminates the loop immediately
- `run/2` returns `{:error, step}` with `step.fail` populated

## Execution Behavior

SubAgent behavior is determined explicitly by `max_turns` and `tools`:

### Single-turn Execution

For classification or mapping tasks with one LLM call:

```elixir
# max_turns: 1, no tools
{:ok, step} = PtcRunner.SubAgent.run(
  "Classify this text: {{text}}",
  signature: "{category :string, confidence :float}",
  context: %{text: "..."},
  max_turns: 1,
  llm: llm
)
```

The LLM provides a single expression; no `return` call needed.

### Agentic Loop

For multi-turn investigation with tools:

```elixir
# max_turns > 1, with tools
{:ok, step} = PtcRunner.SubAgent.run(
  "Find the report with highest anomaly score",
  signature: "{report_id :int, reasoning :string}",
  tools: report_tools,
  max_turns: 5,
  llm: llm
)
```

Full agentic loop requiring explicit `return` or `fail`.

**Note:** `max_turns > 1` without tools enables multi-turn exploration where map results merge into memory for iterative analysis.

## Defaults

| Option | Default | Description |
|--------|---------|-------------|
| `max_turns` | `5` | Maximum LLM turns before timeout |
| `timeout` | `5000` | Per-turn timeout (ms) |
| `mission_timeout` | `60000` | Total mission timeout (ms) |
| `prompt_limit` | `%{list: 5, string: 1000}` | Truncation limits for prompts |

## See Also

- [Getting Started](subagent-getting-started.md) - Build your first SubAgent
- [Patterns](subagent-patterns.md) - Chaining, orchestration, and composition
- [Signature Syntax](../signature-syntax.md) - Full signature syntax reference
- [Advanced Topics](subagent-advanced.md) - Observability and the compile pattern
- `PtcRunner.SubAgent` - API reference
