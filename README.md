# PtcRunner

<!-- PM Status Badge: Updated by PM workflow -->
![PM Status](https://img.shields.io/badge/PM-active-green)

A BEAM-native Elixir library for Programmatic Tool Calling (PTC). Execute LLM-generated programs that orchestrate tools and transform data safely inside sandboxed processes.

## What is PTC?

Programmatic Tool Calling is an execution model where an LLM writes small programs to process data, rather than making individual tool calls. Instead of returning large datasets to the model (which bloats context), the model generates a program that:

1. Calls tools to fetch data
2. Filters, transforms, and aggregates the results
3. Returns only the final answer

This results in **85-98% token savings** for data-heavy workflows.

## Why PtcRunner?

Existing PTC implementations rely on Python sandboxes. PtcRunner provides a BEAM-native alternative:

- **Safe**: JSON DSL with fixed operations—no arbitrary code execution
- **Fast**: Runs in isolated BEAM processes with resource limits
- **Simple**: No external dependencies (Python, containers, etc.)
- **LLM-friendly**: JSON format that models generate reliably

## Quick Example

```elixir
# Define your tools
tools = %{
  "get_expenses" => fn _args ->
    [
      %{"category" => "travel", "amount" => 500},
      %{"category" => "food", "amount" => 50},
      %{"category" => "travel", "amount" => 200}
    ]
  end
}

# LLM generates this JSON program
program = ~s({
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "call", "tool": "get_expenses"},
      {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
      {"op": "sum", "field": "amount"}
    ]
  }
})

# Execute safely with resource limits
{:ok, result, metrics} = PtcRunner.run(program, tools: tools)
# result = 700
# metrics = %{duration_ms: 2, memory_bytes: 1024}
```

## Features

- **JSON DSL** with operations for filtering, mapping, aggregation, and control flow
- **Variable bindings** to store and reference results across operations
- **Tool registry** for user-defined functions
- **Resource limits**: configurable timeout (default 1s) and memory (default 10MB)
- **Execution metrics**: duration and memory usage for every call
- **Structured errors** optimized for LLM retry loops

## DSL Operations

| Category | Operations |
|----------|------------|
| **Data** | `literal`, `var`, `load`, `let` |
| **Collections** | `pipe`, `filter`, `reject`, `map`, `select`, `first`, `last`, `count`, `nth` |
| **Aggregation** | `sum`, `avg`, `min`, `max` |
| **Access** | `get` (nested paths) |
| **Comparison** | `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `contains` |
| **Logic** | `and`, `or`, `not`, `if` |
| **Tools** | `call` |
| **Combine** | `merge`, `concat`, `zip` |

## Status

See the [Architecture](docs/architecture.md) document for full DSL specification.

## Documentation

- **[Architecture](docs/architecture.md)** - System design, DSL specification, API reference
- **[Research Notes](docs/research.md)** - Background research on PTC approaches
- **[Demo App](demo/)** - Interactive CLI chat showing PTC with ReqLLM integration

## Installation

```elixir
def deps do
  [
    {:ptc_runner, "~> 0.1.0"}
  ]
end
```

## Usage

### Basic Execution

```elixir
# Simple program
{:ok, result, _metrics} = PtcRunner.run(~s({"program": {"op": "literal", "value": 42}}))
# result = 42

# With context data
{:ok, result, _metrics} = PtcRunner.run(
  ~s({"program": {"op": "pipe", "steps": [
    {"op": "load", "name": "numbers"},
    {"op": "sum", "field": "value"}
  ]}}),
  context: %{"numbers" => [%{"value" => 1}, %{"value" => 2}, %{"value" => 3}]}
)
# result = 6
```

### With Tools

```elixir
tools = %{
  "get_users" => fn _args -> [%{"name" => "Alice"}, %{"name" => "Bob"}] end,
  "search" => fn %{"query" => q} -> MyApp.search(q) end
}

{:ok, result, _metrics} = PtcRunner.run(program, tools: tools)
```

### Resource Limits

```elixir
# Custom limits
{:ok, result, metrics} = PtcRunner.run(program,
  timeout: 5000,       # 5 seconds
  max_heap: 5_000_000  # ~40MB
)

# Handle resource errors
case PtcRunner.run(program) do
  {:ok, result, metrics} -> handle_success(result)
  {:error, {:timeout, ms}} -> handle_timeout(ms)
  {:error, {:memory_exceeded, bytes}} -> handle_oom(bytes)
  {:error, {:execution_error, msg}} -> handle_error(msg)
end
```

### Multi-turn Conversations

Store results from previous turns and reference them:

```elixir
# Turn 1: Fetch data
{:ok, users, _} = PtcRunner.run(~s({"program": {"op": "call", "tool": "get_users"}}), tools: tools)

# Turn 2: Use previous result
{:ok, count, _} = PtcRunner.run(
  ~s({"program": {"op": "pipe", "steps": [
    {"op": "load", "name": "previous_users"},
    {"op": "count"}
  ]}}),
  context: %{"previous_users" => users}
)
```

### Dynamic Context Refs

When integrating PtcRunner as a tool in an LLM agent, consider automatically storing large tool results as **context refs** instead of returning them directly to the LLM. This keeps large datasets in BEAM memory while giving the LLM a handle to query them:

```elixir
def handle_tool_result(state, tool_name, result) do
  if large_result?(result) do
    # Store data, give LLM a reference
    ref = "#{tool_name}_#{System.unique_integer([:positive])}"
    state = %{state | context: Map.put(state.context, ref, result)}

    # Return summary to LLM (not the full data)
    summary = %{ref: ref, count: length(result), fields: Map.keys(hd(result))}
    {state, {:context_ref, summary}}
  else
    {state, {:inline, result}}
  end
end
```

The LLM can then query the ref via PtcRunner: `{"op": "load", "name": "get_orders_42"}`. See the [demo app](demo/) for a working example with static datasets.

## Integration with LLMs

PtcRunner is execution-only—compose it with your LLM client (e.g., [ReqLLM](https://hexdocs.pm/req_llm)):

### Text Mode (Recommended)

Use `PtcRunner.Schema.to_prompt/0` for a compact operation description (~300 tokens):

```elixir
# Build system prompt with operation descriptions
system_prompt = """
Generate PTC programs to answer questions about data.
Respond with ONLY valid JSON.

#{PtcRunner.Schema.to_prompt()}
"""

# LLM generates program as text
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4.5",
  [%{role: :system, content: system_prompt}, %{role: :user, content: question}])
program = extract_json(response)

# Execute with retry on validation errors
case PtcRunner.run(program, tools: tools) do
  {:ok, result, _} -> {:ok, result}
  {:error, error} -> retry_with_feedback(prompt, error)
end
```

### Structured Output Mode

Use `PtcRunner.Schema.to_llm_schema/0` for guaranteed valid JSON (~10k tokens):

```elixir
# Get the LLM-optimized schema (includes usage hints in descriptions)
schema = PtcRunner.Schema.to_llm_schema()

# LLM generates valid program directly - no JSON parsing needed
program = ReqLLM.generate_object!(
  "openrouter:anthropic/claude-haiku-4.5",
  "Filter products where price > 100, then count them",
  schema
)

# Execute the program
{:ok, result, _metrics} = PtcRunner.run(Jason.encode!(program),
  context: %{"input" => products}
)
```

#### Model Compatibility

The LLM schema uses nested `anyOf` structures to define valid operations. Not all models handle complex structured output schemas equally well:

- **Recommended**: Claude Haiku 4.5, Claude Sonnet 4+ - reliably follow nested schema constraints
- **May have issues**: Some models may not enforce required fields in deeply nested `anyOf` schemas

The schema includes operation descriptions with examples (e.g., `{op:'gt', field:'price', value:10}`) to guide models. See `PtcRunner.Schema.operations/0` for all available operations.

See `test/ptc_runner/e2e_test.exs` for complete integration examples.

## Development

This library was primarily developed by Claude (Anthropic) via GitHub Actions workflows, with human oversight and direction. See the commit history for details.

## License

MIT
