# Getting Started with SubAgents

This guide walks you through your first SubAgent - from a minimal example to understanding the core execution model.

## Prerequisites

- Elixir 1.14+
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

step.return.sentiment  #=> "positive"
step.return.score      #=> 0.95
```

## Adding Tools

Tools let the agent call functions to gather information:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "What is the most expensive product?",
  signature: "{name :string, price :float}",
  tools: %{"list_products" => &MyApp.Products.list/0},
  llm: my_llm
)

step.return.name   #=> "Widget Pro"
step.return.price  #=> 299.99
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

For convenience, you can use atoms like `:haiku` or `:sonnet` by providing an `llm_registry`:

```elixir
# Define your callbacks
defmodule MyApp.LLM do
  def haiku(input), do: call_anthropic("claude-3-haiku-20240307", input)
  def sonnet(input), do: call_anthropic("claude-3-5-sonnet-20241022", input)
end

# Create registry
registry = %{
  haiku: &MyApp.LLM.haiku/1,
  sonnet: &MyApp.LLM.sonnet/1
}

# Use atoms - resolved via registry
PtcRunner.SubAgent.run(prompt,
  llm: :sonnet,
  llm_registry: registry,
  signature: "..."
)
```

The registry is inherited by child SubAgents, so you only pass it once at the top level. See `PtcRunner.SubAgent.run/2` for more details.

### App-Level Default Registry

For applications that want to avoid passing the registry on every call:

```elixir
# In your application.ex start/2
def start(_type, _args) do
  Application.put_env(:ptc_runner, :default_llm_registry, MyApp.llm_registry())
  # ... rest of supervision tree
end

# Now llm_registry is optional - falls back to default
PtcRunner.SubAgent.run(prompt, llm: :sonnet, signature: "...")
```

This is useful for production apps but not available in Livebook (use explicit registry there).

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

### Adding Descriptions

Descriptions help the LLM understand when and how to use each tool. Use keyword list format:

```elixir
tools = %{
  "search" => {&MyApp.search/2,
    signature: "(query :string, limit :int?) -> [{id :int, title :string}]",
    description: "Search for items matching query. Returns up to limit results (default 10)."
  },

  "get_user" => {&MyApp.get_user/1,
    signature: "(id :int) -> {name :string, email :string?}",
    description: "Fetch user by ID. Returns nil if not found."
  }
}
```

### Tool Format Summary

| Format | When to Use |
|--------|-------------|
| `&Mod.fun/n` | Functions with @spec and @doc |
| `{fun, "signature"}` | Explicit signature, no description needed |
| `{fun, signature: "...", description: "..."}` | Production tools with full documentation |
| `fn args -> ... end` | Quick inline functions |

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

### Additional Struct Fields

SubAgents support additional optional fields for documentation and output control:

```elixir
PtcRunner.SubAgent.new(
  prompt: "Find products matching {{query}}",
  signature: "(query :string) -> [{name :string, price :float}]",
  tools: product_tools,

  # Human-readable description for external documentation
  description: "Searches the product catalog and returns matching items",

  # Descriptions for individual signature fields
  field_descriptions: %{
    query: "Search term to match against product names",
    name: "Product name",
    price: "Price in USD"
  },

  # Descriptions for context variables (shown in Data Inventory)
  context_descriptions: %{
    user_id: "ID of the customer performing the search",
    region: "ISO region code (e.g. US, UK)"
  },

  # Output formatting options (shown with defaults)
  format_options: [
    feedback_limit: 10,        # max collection items in turn feedback
    feedback_max_chars: 512,   # max chars in turn feedback
    history_max_bytes: 512,    # truncation limit for *1/*2/*3 history
    result_limit: 50,          # inspect :limit for final result
    result_max_chars: 500,     # final string truncation
    max_print_length: 2000     # max chars per println call
  ],

  # Float precision for output formatting (default: 2)
  float_precision: 2
)
```

These fields are used by the v2 namespace model for enhanced documentation flow and output control. See `PtcRunner.SubAgent` for full details.

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

- [Core Concepts](subagent-concepts.md) - Context, memory, and the firewall convention
- [Observability](subagent-observability.md) - Telemetry, debug mode, and tracing
- [Patterns](subagent-patterns.md) - Chaining, orchestration, and composition
- [Signature Syntax](../signature-syntax.md) - Full signature syntax reference
- [Advanced Topics](subagent-advanced.md) - ReAct patterns and the compile pattern
- `PtcRunner.SubAgent` - API reference
