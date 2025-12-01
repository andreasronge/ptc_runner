# PtcRunner

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
  "op": "pipe",
  "steps": [
    {"op": "call", "tool": "get_expenses"},
    {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
    {"op": "sum", "field": "amount"}
  ]
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
| **Collections** | `pipe`, `filter`, `reject`, `map`, `select`, `first`, `last`, `count` |
| **Aggregation** | `sum`, `avg`, `min`, `max` |
| **Access** | `get` (nested paths) |
| **Comparison** | `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `contains` |
| **Logic** | `and`, `or`, `not`, `if` |
| **Tools** | `call` |
| **Combine** | `merge`, `concat` |

## Status

In development. See the [Architecture](docs/architecture.md) document for full DSL specification and implementation roadmap.

## Documentation

- **[Architecture](docs/architecture.md)** - System design, DSL specification, API reference
- **[Research Notes](docs/research.md)** - Background research on PTC approaches

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
{:ok, result, _metrics} = PtcRunner.run(~s({"op": "literal", "value": 42}))
# result = 42

# With context data
{:ok, result, _metrics} = PtcRunner.run(
  ~s({"op": "pipe", "steps": [
    {"op": "load", "name": "numbers"},
    {"op": "sum", "field": "value"}
  ]}),
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
{:ok, users, _} = PtcRunner.run(~s({"op": "call", "tool": "get_users"}), tools: tools)

# Turn 2: Use previous result
{:ok, count, _} = PtcRunner.run(
  ~s({"op": "pipe", "steps": [
    {"op": "load", "name": "previous_users"},
    {"op": "count"}
  ]}),
  context: %{"previous_users" => users}
)
```

## Integration with LLMs

PtcRunner is execution-only—compose it with your LLM client (e.g., [ReqLLM](https://hexdocs.pm/req_llm)):

```elixir
# 1. LLM generates program
{:ok, response} = ReqLLM.generate_text("openrouter:anthropic/claude-3-sonnet", prompt)
program = extract_json(response)

# 2. PtcRunner executes it
case PtcRunner.run(program, tools: tools) do
  {:ok, result, _} -> {:ok, result}
  {:error, error} -> retry_with_feedback(prompt, error)
end
```

See `test/e2e/` for complete integration examples.

## License

MIT
# Test change
