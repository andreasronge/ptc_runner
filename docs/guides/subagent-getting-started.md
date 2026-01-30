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

### JSON Mode (Simpler Alternative)

For classification, extraction, and reasoning tasks that don't need tools, use `output: :json`:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Extract the person's name and age from: {{text}}",
  context: %{text: "John is 25 years old"},
  output: :json,
  signature: "(text :string) -> {name :string, age :int}",
  llm: my_llm
)

step.return["name"]  #=> "John"
step.return["age"]   #=> 25
```

JSON mode skips PTC-Lisp entirely - the LLM returns structured JSON directly, validated against your signature. Use it when you need structured output but not computation or tool calls.

JSON mode supports full Mustache templating including sections for lists:

```elixir
# Iterate over list data with {{#section}}...{{/section}}
SubAgent.new(
  prompt: "Summarize these items: {{#items}}{{name}}, {{/items}}",
  output: :json,
  signature: "(items [{name :string}]) -> {summary :string}"
)
```

**Constraints:** JSON mode requires a signature with all parameters used in the prompt, cannot use tools, and doesn't support compression or firewall fields.

See [JSON Mode Guide](subagent-json-mode.md) for Mustache syntax, validation rules, and examples.

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
| Loop | Otherwise | Multiple turns until `(return ...)` or `(fail ...)` |

In **single-shot mode**, the LLM's expression is evaluated and returned directly. In **loop mode**, the agent must explicitly call `return` or `fail` to complete.

> **Common Pitfall:** If your agent produces correct results but keeps looping until
> `max_turns_exceeded`, it's likely in loop mode without calling `return`. Either set
> `max_turns: 1` for single-shot execution, or ensure your prompt guides the LLM to
> use `(return {:value ...})` when done.

## Validation Retries with return_retries

By default, if return value validation fails, the agent stops with an error. To enable automatic recovery, use the `return_retries` option to give agents a limited budget for retrying after validation failures:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Extract and return user data",
  signature: "{name :string, age :int}",
  return_retries: 3,  # Budget for 3 retry attempts if validation fails
  llm: my_llm
)
```

When validation fails and retries are available:
1. The agent enters **retry mode** with the original error message and guidance
2. The LLM sees feedback like "Retry 1 of 3" to understand how many attempts remain
3. The agent must call `(return new_value)` to complete
4. If validation passes, the loop continues normally
5. If retries are exhausted, the agent returns an error

The `return_retries` option uses a **unified budget model** alongside `max_turns`:
- **Work turns** (`max_turns`): Used for normal execution with tools available
- **Retry turns** (`return_retries`): Used only after validation failures, with no tools

This separation lets agents safely explore solutions during work turns, then recover from validation errors during retry turns without consuming the main work budget.

> **Note:** Single-shot agents with `return_retries > 0` use compression to collapse previous failed attempts, preventing context window inflation during retries. For multi-turn agents with signatures, use signatures to enable validation in your return statement.

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

- [JSON Mode Guide](subagent-json-mode.md) - Mustache templates, validation, and structured output
- [Core Concepts](subagent-concepts.md) - Context, memory, and the firewall convention
- [Observability](subagent-observability.md) - Telemetry, debug mode, and tracing
- [Patterns](subagent-patterns.md) - Chaining, orchestration, and composition
- [Signature Syntax](../signature-syntax.md) - Full signature syntax reference
- [Advanced Topics](subagent-advanced.md) - ReAct patterns and the compile pattern
- `PtcRunner.SubAgent` - API reference
