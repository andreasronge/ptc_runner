# Getting Started with SubAgents

This guide walks you through your first SubAgent - from a minimal example to understanding the core execution model.

> **Note:** This API is not yet implemented. These docs exist to validate the design before committing to implementation.

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

| `max_turns` | `tools` | Behavior |
|-------------|---------|----------|
| `1` | none | Single-turn: one LLM call, expression returned directly |
| `1` | provided | Single-turn with tools: one turn to use them |
| `>1` | provided | Agentic loop: multiple turns until `return`/`fail` |
| `>1` | none | **Error**: multi-turn requires tools |

With `max_turns: 1` and no tools, the LLM evaluates and returns directly. With tools or `max_turns > 1`, the agent must explicitly call `return` to complete.

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

See [Signatures Guide](signatures.md) for full syntax.

## Providing an LLM

SubAgent is provider-agnostic. You supply a callback function:

```elixir
llm = fn %{system: system, messages: messages} ->
  # Call your LLM provider here
  {:ok, response_text}
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

### Example with ReqLLM

```elixir
defmodule MyApp.LLM do
  def callback(model \\ "anthropic/claude-sonnet") do
    fn %{system: system, messages: messages} = params ->
      opts = Map.get(params, :llm_opts, %{})

      case ReqLLM.chat(:openrouter,
             model: model,
             system: system,
             messages: messages,
             temperature: opts[:temperature] || 0.7) do
        {:ok, %{choices: [%{message: %{content: text}} | _]}} ->
          {:ok, text}
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

## Defining Tools

Tools are functions the SubAgent can call. Provide them as a map:

```elixir
tools = %{
  "list_products" => &MyApp.Products.list/0,
  "get_product" => &MyApp.Products.get/1,
  "search" => fn %{query: q, limit: l} -> MyApp.search(q, l) end
}
```

Tool signatures are auto-extracted from `@spec` when available:

```elixir
# In your module
@spec search(String.t(), integer()) :: [map()]
def search(query, limit), do: ...

# Auto-extracted as: search(query :string, limit :int) -> [:map]
tools = %{"search" => &MyApp.search/2}
```

For functions without specs, provide one explicitly:

```elixir
tools = %{
  "search" => {
    &MyApp.search/2,
    "(query :string, limit :int) -> [{id :int, title :string}]"
  }
}
```

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

## The Firewall Convention

Fields prefixed with `_` are **firewalled** - available to your Elixir code and the agent's programs, but hidden from LLM prompt history:

```elixir
signature: "{summary :string, count :int, _email_ids [:int]}"
```

This keeps parent agent context lean while preserving full data access. See [Core Concepts](core-concepts.md) for details.

## Memory

Each agent has private memory persisting across turns within a single `run`:

```clojure
(memory/put :cache result)   ; store
(memory/get :cache)          ; retrieve
memory/cache                 ; shorthand
```

Memory is scoped per-agent and hidden from prompts. See [Core Concepts](core-concepts.md) for details.

## What's Next

- [Core Concepts](core-concepts.md) - Context, memory, and the firewall convention
- [Patterns](patterns.md) - Chaining, orchestration, and composition
- [Signatures](signatures.md) - Full signature syntax reference
