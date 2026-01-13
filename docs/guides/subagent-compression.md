# Message Compression

This guide explains message compression: what problem it solves, how to enable it, and how to implement custom strategies.

## The Problem

In multi-turn execution, the LLM generates programs that build on previous turns:

```
Turn 1: (def x 1) (println x)
Turn 2: (def x 1) (def y 2) (println (+ x y))     # repeats turn 1
Turn 3: (def x 1) (def y 2) (def z 3) ...         # repeats turn 1+2
```

Without compression, the message history accumulates full programs from every turn. The LLM sees all previous versions of its evolving program. This:

- **Wastes tokens** - Repeated code inflates context size
- **Confuses the model** - Multiple versions of the same definitions
- **Reduces cache hits** - Dynamic history defeats prompt caching

## The Solution

Compression transforms the turn history into a compact format. Instead of showing previous programs, it shows:

- What was defined (symbols available)
- What actions were taken (tool calls)
- What was observed (println output)
- Whether execution succeeded or failed

The LLM doesn't need to see its previous code - it needs the **results** of its previous code.

## Enabling Compression

```elixir
# Enable with default strategy
SubAgent.run(prompt, llm: llm, compression: true)

# Explicit strategy
alias PtcRunner.SubAgent.Compression.SingleUserCoalesced
SubAgent.run(prompt, llm: llm, compression: SingleUserCoalesced)

# With options
SubAgent.run(prompt, llm: llm, compression: {SingleUserCoalesced, println_limit: 10})
```

## SingleUserCoalesced Strategy

The default strategy coalesces all turn history into a **single USER message**. This prevents the LLM from mimicking summary formats (which could happen if summaries appeared in ASSISTANT messages).

### Message Structure

```
[SYSTEM]  Static: language reference, return/fail usage, output format
[USER]    Dynamic: mission + namespaces + execution history + turns left
```

### What the LLM Sees

```clojure
Find well-reviewed products in stock

;; === tool/ ===
(tool/search-reviews query)      ; query:string -> string

;; === data/ ===
data/products                    ; list[7], sample: {:name "Laptop", :price 1200}

;; === user/ (your prelude) ===
electronics                      ; = list[4], sample: {:name "Laptop"}

;; Tool calls made:
;   search-reviews("Electronics")

;; Output:
Found 5 matching products

Turns left: 4
```

### Namespace Model

| Namespace | Content | Changes? |
|-----------|---------|----------|
| `tool/` | Available tools with signatures | No (stable) |
| `data/` | Input context data | No (stable) |
| `user/` | Accumulated definitions (prelude) | Yes (grows) |

The `tool/` and `data/` sections are stable across turns, enabling prompt caching. Only `user/` changes as definitions accumulate.

### Error Handling

Errors use conditional collapsing:

| Current turn | Error display |
|--------------|---------------|
| Succeeds | All previous errors collapsed (clean view) |
| Fails | Most recent error shown (helps recovery) |

Once the LLM recovers from an error, old mistakes become noise and are hidden.

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `println_limit` | 15 | Most recent println calls shown |
| `tool_call_limit` | 20 | Most recent tool calls shown |

```elixir
SubAgent.run(prompt,
  llm: llm,
  compression: {SingleUserCoalesced, println_limit: 10, tool_call_limit: 15}
)
```

Older entries are dropped (FIFO) but preserved in `step.turns` for debugging.

## Debugging Compression

To see what the LLM receives:

```elixir
{:ok, step} = SubAgent.run(prompt, llm: llm, compression: true)

# Show compressed view
SubAgent.Debug.print_trace(step, view: :compressed)

# Compare with full turn history
SubAgent.Debug.print_trace(step)
```

Full history is always preserved in `step.turns` regardless of compression.

### Compression Statistics

Use `usage: true` to see compression metrics:

```elixir
SubAgent.Debug.print_trace(step, usage: true)
```

This displays a compression section showing what was dropped:

```
+- Compression -------------------------------------------+
|   Strategy:     single-user-coalesced
|   Turns:        9 compressed
|   Tool calls:   20/25 shown (5 dropped)
|   Printlns:     15/18 shown (3 dropped)
|   Errors:       2 turn(s) collapsed
+---------------------------------------------------------+
```

The stats are also available programmatically in `step.usage.compression`:

```elixir
step.usage.compression
# => %{
#   enabled: true,
#   strategy: "single-user-coalesced",
#   turns_compressed: 9,
#   tool_calls_total: 25,
#   tool_calls_shown: 20,
#   tool_calls_dropped: 5,
#   printlns_total: 18,
#   printlns_shown: 15,
#   printlns_dropped: 3,
#   error_turns_collapsed: 2
# }
```

| Metric | Description |
|--------|-------------|
| `turns_compressed` | Number of turns coalesced into single message |
| `tool_calls_dropped` | Tool calls exceeding `tool_call_limit` |
| `printlns_dropped` | Println output exceeding `println_limit` |
| `error_turns_collapsed` | Failed turns hidden from LLM (all if recovered, all but last if still failing) |

## When to Use Compression

**Enable compression when:**
- Multi-turn agents with many turns (5+)
- Agents that make many tool calls
- Context size is a concern (cost, latency)
- LLM seems confused by seeing old program versions

**Skip compression when:**
- Single-turn agents (`max_turns: 1`) — compression is automatically skipped even if enabled
- Simple agents with few turns
- Debugging (easier to see full history)

## Implementing Custom Strategies

For advanced use cases, you can implement the `Compression` behaviour:

```elixir
defmodule MyApp.CustomCompression do
  @behaviour PtcRunner.SubAgent.Compression

  @impl true
  def name, do: "custom"

  @impl true
  def to_messages(turns, memory, opts) do
    # turns: list of %Turn{} structs (immutable history)
    # memory: accumulated user definitions
    # opts: keyword list with :prompt, :system_prompt, :tools, :data, etc.

    system_prompt = Keyword.get(opts, :system_prompt, "")
    mission = Keyword.get(opts, :prompt, "")

    # Build your message array
    [
      %{role: :system, content: system_prompt},
      %{role: :user, content: build_user_content(mission, turns, memory, opts)}
    ]
  end

  defp build_user_content(mission, turns, memory, opts) do
    # Your compression logic here
    # ...
  end
end
```

### Available Data in `opts`

| Key | Type | Description |
|-----|------|-------------|
| `:prompt` | string | The mission/prompt text |
| `:system_prompt` | string | Static system prompt |
| `:tools` | map | Tool name → Tool struct |
| `:data` | map | Input context data |
| `:turns_left` | integer | Remaining turns |
| `:println_limit` | integer | Max println entries |
| `:tool_call_limit` | integer | Max tool call entries |
| `:signature` | string | Output signature (if any) |

### Turn Struct Fields

Each `%Turn{}` provides:

| Field | Type | Description |
|-------|------|-------------|
| `number` | integer | Turn index (1-based) |
| `program` | string | Extracted PTC-Lisp code |
| `result` | term | Execution result |
| `prints` | list | Output from println calls |
| `tool_calls` | list | Tools invoked with args/results |
| `memory` | map | State snapshot after turn |
| `success?` | boolean | Whether turn succeeded |

### Using Your Strategy

```elixir
SubAgent.run(prompt,
  llm: llm,
  compression: MyApp.CustomCompression
)

# Or with options
SubAgent.run(prompt,
  llm: llm,
  compression: {MyApp.CustomCompression, my_option: "value"}
)
```

## See Also

- [Observability](subagent-observability.md) - Debug mode and tracing
- [Advanced Topics](subagent-advanced.md) - Prompt structure details
- `PtcRunner.SubAgent.Compression` - Behaviour documentation
- `PtcRunner.SubAgent.Compression.SingleUserCoalesced` - Default implementation
