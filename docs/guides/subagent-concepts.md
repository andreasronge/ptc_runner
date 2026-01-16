# Core Concepts

This guide covers the foundational concepts for library users: context management, the firewall convention, and how agents complete their work.

## How SubAgents Work

When you call `SubAgent.run/2`, the library:

1. Sends your prompt and context to the LLM
2. The LLM generates a PTC-Lisp program (a Clojure subset)
3. The program executes in a sandboxed environment
4. Results are validated against your signature
5. On success, `{:ok, step}` returns with `step.return` containing the result

You don't write PTC-Lisp - the LLM does. You configure the agent with Elixir.

**Alternative: JSON Mode.** For simple classification and extraction tasks, use `output: :json` to skip PTC-Lisp entirely. The LLM returns structured JSON directly. See [Getting Started](subagent-getting-started.md#json-mode-simpler-alternative).

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

Fields prefixed with `_` are **firewalled** - available to your Elixir code but hidden from LLM prompts:

```elixir
signature: "{summary :string, count :int, _email_ids [:int]}"
```

Visibility rules:

| Location | Normal Fields | Firewalled (`_`) |
|----------|---------------|------------------|
| LLM prompt history | Visible | Hidden |
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

# Step 2: Chain to next agent
{:ok, step2} = PtcRunner.SubAgent.run(
  "Draft replies for these {{count}} urgent emails",
  context: step1,  # Auto-chains return data
  tools: drafting_tools,
  llm: llm
)
```

In Step 2, the LLM knows there are 3 emails (public) but cannot see the actual IDs (firewalled). The generated program can still access them if needed.

## Context

Values passed to `context:` become available to the LLM's generated programs:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Get details for order {{order_id}}",
  context: %{order_id: "ORD-123", customer_tier: "gold"},
  tools: order_tools,
  llm: llm
)
```

### Template Expansion

The `{{placeholder}}` syntax in prompts expands from context:

```elixir
prompt: "Find emails for {{user.name}} about {{topic}}"
context: %{user: %{name: "Alice"}, topic: "billing"}
# Expands to: "Find emails for Alice about billing"
```

### Chaining Context

When passing a previous `Step` to `context:`, the return data is automatically extracted:

```elixir
# These are equivalent:
run(prompt, context: step1.return)
run(prompt, context: step1)  # Auto-extraction
```

## How Agents Complete

Agents complete their work in one of two ways:

### Single-turn (Expression Result)

For simple tasks with `max_turns: 1`, the LLM's expression result is returned directly:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Classify this text: {{text}}",
  signature: "{category :string, confidence :float}",
  context: %{text: "..."},
  max_turns: 1,
  llm: llm
)

step.return  #=> %{category: "positive", confidence: 0.95}
```

### Multi-turn (Explicit Return)

For agentic tasks with tools, the LLM must explicitly signal completion. It does this by calling `return` or `fail` in its generated program:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Find the report with highest anomaly score",
  signature: "{report_id :int, reasoning :string}",
  tools: report_tools,
  max_turns: 5,
  llm: llm
)
```

The agent loops until the LLM's program calls `return` with valid data, or `fail` to abort.

## Error Handling

SubAgents handle errors at three levels:

### 1. Turn Errors (Recoverable)

Syntax errors, tool failures, and validation errors are fed back to the LLM. It sees the error and can adapt in the next turn.

### 2. Mission Failures (Explicit)

When the LLM determines it cannot complete the task, it calls `fail`. Your code receives:

```elixir
{:error, step} = SubAgent.run(...)
step.fail  #=> %{reason: :not_found, message: "User does not exist"}
```

### 3. System Crashes

Programming bugs in your tool functions follow "let it crash" - they're returned as internal errors for investigation.

## Multi-turn State

In multi-turn agents, the LLM can store values that persist across turns. This happens automatically - values defined in one turn are available in subsequent turns.

From your perspective as a library user:
- **You see** the final result in `step.return`
- **You see** execution history in `step.turns`
- **You don't need** to manage intermediate state

The LLM handles state internally to cache tool results, track progress, and avoid redundant work.

## Defaults

| Option | Default | Description |
|--------|---------|-------------|
| `max_turns` | `5` | Maximum LLM turns before timeout |
| `timeout` | `5000` | Per-turn sandbox timeout (ms) |
| `mission_timeout` | `60000` | Total mission timeout (ms) |
| `float_precision` | `2` | Decimal places for floats in results |
| `compression` | `false` | Enable message history compression |

## See Also

- [Getting Started](subagent-getting-started.md) - Build your first SubAgent
- [Observability](subagent-observability.md) - Debug mode, compression, and tracing
- [Patterns](subagent-patterns.md) - Chaining, orchestration, and composition
- [Signature Syntax](../signature-syntax.md) - Full signature syntax reference
- [Advanced Topics](subagent-advanced.md) - Prompt structure and internals
- `PtcRunner.SubAgent` - API reference
