# Getting Started with SubAgents

This guide walks you through your first SubAgent - from a minimal example to understanding the core execution model.

## Prerequisites

- Elixir 1.15+
- An LLM provider (OpenRouter, Anthropic, OpenAI, etc.)

## The Simplest SubAgent

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "How many r's are in raspberry?",
  llm: my_llm
)

step.return  #=> 3
```

That's it. No tools, no signature, no validation - just a prompt and an LLM.

### Why This Matters

The SubAgent doesn't answer directly - it writes a *program* that computes the answer:

```clojure
(count (filter #(= % "r") (seq "raspberry")))
```

This is the core insight of PTC (Programmatic Tool Calling): instead of asking the LLM to *be* the computer, ask it to *program* the computer. The LLM reasons and generates code; the actual computation runs in a sandboxed interpreter where results are deterministic.

### With Context

Pass data to the prompt using `{{placeholders}}`:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Summarize in one sentence: {{text}}",
  context: %{text: "Long article about climate change..."},
  llm: my_llm
)

step.return  #=> "Climate change poses significant global challenges..."
```

### With Type Validation

Add a signature to validate the output structure:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Rate this review sentiment",
  context: %{review: "Great product, love it!"},
  signature: "{sentiment :string, score :float}",
  llm: my_llm
)

step.return["sentiment"]  #=> "positive"
step.return["score"]      #=> 0.95
```

### Text Mode (Simpler Alternative)

For tasks that don't need PTC-Lisp, use `output: :text`. The behavior auto-detects based on whether tools are provided and the return type:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Extract the person's name and age from: {{text}}",
  context: %{text: "John is 25 years old"},
  output: :text,
  signature: "(text :string) -> {name :string, age :int}",
  llm: my_llm
)

step.return["name"]  #=> "John"
step.return["age"]   #=> 25
```

With a complex return type and no tools, the LLM returns structured JSON directly. With no signature or a `:string` return type, it returns raw text. Use it when you need structured output but not computation.

Text mode supports full Mustache templating including sections for lists:

```elixir
# Iterate over list data with {{#section}}...{{/section}}
SubAgent.new(
  prompt: "Summarize these items: {{#items}}{{name}}, {{/items}}",
  output: :text,
  signature: "(items [{name :string}]) -> {summary :string}"
)
```

**Constraints:** Signature is optional. Tools are optional. Compression and firewall fields are not supported.

See [Text Mode Guide](subagent-text-mode.md) for Mustache syntax, validation rules, tool calling, and examples.

### Text Mode with Tools (For Smaller LLMs)

For smaller or faster LLMs that can use native tool calling but can't generate PTC-Lisp, use `output: :text` with tools:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "What is 17 + 25? Use the add tool.",
  output: :text,
  signature: "() -> {result :int}",
  tools: %{
    "add" => {fn args -> args["a"] + args["b"] end,
              signature: "(a :int, b :int) -> :int",
              description: "Add two numbers"}
  },
  llm: my_llm
)

step.return["result"]  #=> 42
```

Text mode auto-detects tool calling when tools are provided. It converts tool signatures to JSON Schema and uses the LLM provider's native tool calling API. The LLM calls tools, ptc_runner executes them, and the loop continues until the LLM returns a final answer. If a complex return type is specified, the answer is validated as JSON against the signature. If no signature or `:string` return type, the raw text answer is returned.

**Constraints:** No memory persistence between turns.

See [Text Mode Guide](subagent-text-mode.md) for multi-tool scenarios, limits, and error handling.

## Adding Tools

Tools let the agent call functions to gather information:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "What is the most expensive product?",
  signature: "{name :string, price :float}",
  tools: %{"list_products" => &MyApp.Products.list/0},
  llm: my_llm
)

step.return["name"]   #=> "Widget Pro"
step.return["price"]  #=> 299.99
```

With tools, the SubAgent enters an **agentic loop** - it calls tools and reasons until it has enough information to return.

## Execution Behavior

| Mode | Condition | Behavior |
|------|-----------|----------|
| Single-shot | `max_turns: 1` and no tools | One LLM call, expression returned directly |
| Loop (PTC-Lisp) | Tools or `max_turns > 1` | Multiple turns until `(return ...)` or `(fail ...)` |
| Loop (Text) | `output: :text` with tools | LLM calls tools via native API, returns final text or JSON |

In **single-shot mode**, the LLM's expression is evaluated and returned directly. In **PTC-Lisp loop mode**, the agent must explicitly call `return` or `fail` to complete. In **text mode with tools**, the loop ends when the LLM returns content without tool calls.

> **Common Pitfall:** If your agent produces correct results but keeps looping until
> `max_turns_exceeded`, it's likely in loop mode without calling `return`. Either set
> `max_turns: 1` for single-shot execution, or ensure your prompt guides the LLM to
> use `(return {:value ...})` when done.

## Validation Retries with retry_turns

By default, if return value validation fails, the agent stops with an error. To enable automatic recovery, use the `retry_turns` option to give agents a limited budget for retrying after validation failures:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Extract and return user data",
  signature: "{name :string, age :int}",
  retry_turns: 3,  # Budget for 3 retry attempts if validation fails
  llm: my_llm
)
```

When validation fails and retries are available:
1. The agent enters **retry mode** with the original error message and guidance
2. The LLM sees feedback like "Retry 1 of 3" to understand how many attempts remain
3. The agent must call `(return new_value)` to complete
4. If validation passes, the loop continues normally
5. If retries are exhausted, the agent returns an error

The `retry_turns` option uses a **unified budget model** alongside `max_turns`:
- **Work turns** (`max_turns`): Used for normal execution with tools available
- **Retry turns** (`retry_turns`): Used only after validation failures, with no tools

This separation lets agents safely explore solutions during work turns, then recover from validation errors during retry turns without consuming the main work budget.

> **Note:** Single-shot agents with `retry_turns > 0` use compression to collapse previous failed attempts, preventing context window inflation during retries. For multi-turn agents with signatures, use signatures to enable validation in your return statement.

## Debugging Execution

To see what the agent is doing, use `PtcRunner.SubAgent.Debug.print_trace/2`:

```elixir
{:ok, step} = SubAgent.run(prompt, llm: my_llm)
PtcRunner.SubAgent.Debug.print_trace(step)
```

For more detail, include raw LLM output (reasoning) or the actual messages sent:

```elixir
# Include LLM reasoning/commentary
PtcRunner.SubAgent.Debug.print_trace(step, raw: true)

# Show full messages sent to LLM
PtcRunner.SubAgent.Debug.print_trace(step, messages: true)
```

This is essential for identifying why a model might be failing or ignoring tool instructions.

> **More options:** See [Observability](subagent-observability.md) for compression, telemetry, and production tips.

## Signatures (Optional)

Signatures define a contract for inputs and outputs:

```elixir
# Output only
signature: "{name :string, price :float}"

# With inputs (for reusable agents)
signature: "(query :string) -> [{id :int, title :string}]"
```

When provided, signatures:
- Validate return data (agent retries on mismatch)
- Document expected shape to the LLM
- Give your Elixir code predictable types

See [Signature Syntax](../signature-syntax.md) for full syntax.

## Providing an LLM

SubAgent is provider-agnostic. You supply a callback function:

```elixir
llm = fn %{system: system, messages: messages} ->
  # Call your LLM provider here
  {:ok, response_text}
  # Or include token counts for usage stats:
  # {:ok, %{content: response_text, tokens: %{input: 100, output: 50}}}
end

PtcRunner.SubAgent.run(prompt, llm: llm, signature: "...")
```

The callback receives:

| Key | Type | Description |
|-----|------|-------------|
| `system` | `String.t()` | System prompt with instructions |
| `messages` | `[map()]` | Conversation history |
| `turn` | `integer()` | Current turn number |
| `tool_names` | `[String.t()]` | Available tool names |
| `llm_opts` | `map()` | Custom options passed through |

### Using Atoms with a Registry

For convenience, use atoms like `:sonnet` by providing an `llm_registry` map. The registry is inherited by child SubAgents. See `PtcRunner.SubAgent.run/2` for registry options and app-level defaults.

### Example with ReqLLM

```elixir
defmodule MyApp.LLM do
  @timeout 30_000

  def callback(model \\ "openrouter:anthropic/claude-haiku-4.5") do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case ReqLLM.generate_text(model, full_messages, receive_timeout: @timeout) do
        {:ok, %ReqLLM.Response{} = r} ->
          usage = ReqLLM.Response.usage(r)
          {:ok, %{
            content: ReqLLM.Response.text(r),
            tokens: %{input: usage[:input_tokens] || 0, output: usage[:output_tokens] || 0}
          }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end

# Usage
llm = MyApp.LLM.callback()
PtcRunner.SubAgent.run(prompt, llm: llm, signature: "...")
```

> **Note:** The callback must include the `system` prompt in the messages sent to the LLM.
> The SubAgent's system prompt contains critical PTC-Lisp instructions that guide the LLM
> to output valid programs.

## Defining Tools

Tools are functions the SubAgent can call. Provide them as a map:

```elixir
tools = %{
  "list_products" => &MyApp.Products.list/0,
  "get_product" => &MyApp.Products.get/1,
  "search" => fn %{query: q, limit: l} -> MyApp.search(q, l) end
}
```

### Auto-Extraction from @spec and @doc

Tool signatures and descriptions are auto-extracted when available:

```elixir
# In your module
@doc "Search for items matching the query string"
@spec search(String.t(), integer()) :: [map()]
def search(query, limit), do: ...

# Auto-extracted:
#   signature: "(query :string, limit :int) -> [:map]"
#   description: "Search for items matching the query string"
tools = %{"search" => &MyApp.search/2}
```

### Explicit Signatures

For functions without specs, provide a signature explicitly:

```elixir
tools = %{
  "search" => {&MyApp.search/2, "(query :string, limit :int) -> [{id :int}]"}
}
```

For production tools, add descriptions and explicit signatures using keyword list format:

```elixir
tools = %{
  "search" => {&MyApp.search/2,
    signature: "(query :string, limit :int?) -> [{id :int, title :string}]",
    description: "Search for items matching query. Returns up to limit results (default 10)."
  }
}
```

### Result Caching

For tools with stable, pure outputs (same inputs always produce the same result),
enable `cache: true` to avoid redundant calls across turns:

```elixir
tools = %{
  "get-config" => {&MyApp.get_config/1,
    signature: "(key :string) -> :any",
    cache: true
  }
}
```

Cached results persist across turns within a single `SubAgent.run/2` call. Only
successful results are cached — errors are never stored. Do not use on tools that
read mutable state modifiable by other tools in the session.

See `PtcRunner.Tool` for all supported tool formats.

## Builtin LLM Queries

Enable `llm_query: true` to let the agent make ad-hoc LLM calls from PTC-Lisp without defining separate tools:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Classify each item by urgency",
  signature: "(items [:map]) -> {urgent [:map]}",
  llm_query: true,
  llm: my_llm,
  context: %{items: items}
)
```

The agent can call `tool/llm-query` with a prompt and optional signature for classification, judgment, or extraction tasks. See [Composition Patterns](subagent-patterns.md#builtin-ad-hoc-llm-queries-llm_query) for details.

### Recursive Agents (`:self` Tools)

Use `:self` to let an agent call itself recursively. Parent-defined closures (`defn`) are automatically inherited by child invocations:

```elixir
agent = SubAgent.new(
  prompt: "Analyze {{chunk}}",
  signature: "(chunk :string) -> {findings [:string]}",
  tools: %{"worker" => :self},
  max_depth: 3
)
```

See [Composition Patterns — Recursive Agents](subagent-patterns.md#recursive-agents-with-self-and-function-inheritance) and [RLM Patterns](subagent-rlm-patterns.md) for details.

## Builtin Tools

Use `builtin_tools` to enable utility tool families without defining them yourself:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Find lines mentioning 'error' in the log",
  builtin_tools: [:grep],
  llm: my_llm,
  context: %{log: log_text}
)
```

The `:grep` family adds `tool/grep` and `tool/grep-n` (line-numbered variant). Multiple families can be combined: `builtin_tools: [:grep]`. User-defined tools with the same name take precedence.

**Text mode note:** In text mode (`output: :text`), tool names with hyphens are automatically sanitized to underscores for the LLM provider API (e.g., `grep-n` becomes `grep_n`). The mapping is handled transparently.

## Agent as Data

For reusable agents, create the struct separately:

```elixir
# Define once
product_finder = PtcRunner.SubAgent.new(
  prompt: "Find the most expensive product",
  signature: "{name :string, price :float}",
  tools: product_tools,
  max_turns: 5
)

# Execute with runtime params
{:ok, step} = PtcRunner.SubAgent.run(product_finder, llm: my_llm)
```

This separation enables testing, composition, and reuse.

SubAgents also support fields for documentation (`description`, `field_descriptions`, `context_descriptions`), output formatting (`format_options`, `float_precision`), and memory limits (`memory_limit`, `memory_strategy`). See `PtcRunner.SubAgent.new/1` for all options.

## The Firewall Convention

Fields prefixed with `_` are **firewalled** - available to your Elixir code and the agent's programs, but hidden from LLM prompt history:

```elixir
signature: "{summary :string, count :int, _email_ids [:int]}"
```

This keeps parent agent context lean while preserving full data access. See [Core Concepts](subagent-concepts.md) for details.

## State Persistence

Use `def` to store values that persist across turns within a single `run`:

```clojure
(def cache result)   ; store
cache                ; access as plain symbol
```

Use `defn` to define reusable functions:

```clojure
(defn expensive? [item] (> (:price item) 1000))
(filter expensive? data/items)
```

State is scoped per-agent and hidden from prompts. See [Core Concepts](subagent-concepts.md) for details.

## See Also

- [Text Mode Guide](subagent-text-mode.md) - Text mode, Mustache templates, tool calling, and structured output
- [Core Concepts](subagent-concepts.md) - Context, memory, and the firewall convention
- [Observability](subagent-observability.md) - Telemetry, debug mode, and tracing
- [Patterns](subagent-patterns.md) - Chaining, orchestration, and composition
- [Signature Syntax](../signature-syntax.md) - Full signature syntax reference
- [Advanced Topics](subagent-advanced.md) - ReAct patterns and the compile pattern
- `PtcRunner.SubAgent` - API reference
