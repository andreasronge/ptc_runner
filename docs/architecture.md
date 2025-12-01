# PtcRunner Architecture

## Overview

PtcRunner is a BEAM-native library for executing Programmatic Tool Calling (PTC) programs. It provides a safe, controlled environment for running LLM-generated data transformation and tool orchestration code.

```
┌─────────────────────────────────────────────────────────────────┐
│                         PtcRunner                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────┐    ┌──────────┐    ┌─────────────┐               │
│  │  Parser  │───▶│Validator │───▶│ Interpreter │               │
│  │  (JSON)  │    │ (Schema) │    │  (Evaluator)│               │
│  └──────────┘    └──────────┘    └──────┬──────┘               │
│                                         │                        │
│                                         ▼                        │
│                              ┌──────────────────┐               │
│                              │  Tool Registry   │               │
│                              │  (User-defined)  │               │
│                              └──────────────────┘               │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Sandbox Process                        │   │
│  │  • max_heap_size: 10MB (configurable)                    │   │
│  │  • timeout: 1s (configurable)                            │   │
│  │  • isolated evaluation                                   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Design Principles

1. **Safety First**: Programs run in isolated processes with resource limits
2. **Simplicity**: JSON DSL is easy for LLMs to generate and humans to debug
3. **Composability**: Operations chain via `pipe`, results can be stored and referenced
4. **Extensibility**: Users register their own tools as simple functions
5. **Execution Only**: No LLM integration—compose with ReqLLM or other clients externally

## Module Structure

```
lib/
├── ptc_runner.ex                 # Public API: run/2, run!/2
├── ptc_runner/
│   ├── parser.ex                 # JSON parsing
│   ├── validator.ex              # Schema validation
│   ├── interpreter.ex            # AST evaluation
│   ├── operations.ex             # Built-in operations
│   ├── sandbox.ex                # Process isolation + resource limits
│   ├── context.ex                # Variable bindings and tool results
│   └── tools.ex                  # Tool registry
```

## DSL Specification

### Format

The DSL uses JSON for maximum LLM compatibility. Programs are composed of operations that transform data.

### Variable Bindings

Programs can store intermediate results and reference them later. This enables:
- Storing tool call results for later use
- Combining data from multiple tool calls
- Building complex pipelines across conversation turns

```json
{
  "op": "let",
  "name": "expenses",
  "value": {"op": "call", "tool": "get_expenses"},
  "in": {
    "op": "pipe",
    "steps": [
      {"op": "var", "name": "expenses"},
      {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
      {"op": "sum", "field": "amount"}
    ]
  }
}
```

### Context

The execution context contains:
- **Variables**: Named bindings from `let` expressions or passed in
- **Tools**: Registered tool functions
- **Results**: Previous tool call results (for multi-turn conversations)

```elixir
# Running with pre-bound context (e.g., from previous conversation turns)
PtcRunner.run(program,
  context: %{
    "previous_expenses" => [...],  # Result from earlier tool call
    "user_preferences" => %{...}
  },
  tools: %{
    "get_expenses" => &MyApp.get_expenses/1
  }
)
```

### Operations

#### Data Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `literal` | Literal value | `{"op": "literal", "value": 42}` |
| `var` | Reference a variable | `{"op": "var", "name": "expenses"}` |
| `load` | Load from context | `{"op": "load", "name": "data"}` |
| `let` | Bind a value to a name | `{"op": "let", "name": "x", "value": ..., "in": ...}` |

#### Collection Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `pipe` | Chain operations | `{"op": "pipe", "steps": [...]}` |
| `filter` | Keep matching items | `{"op": "filter", "where": {...}}` |
| `reject` | Remove matching items | `{"op": "reject", "where": {...}}` |
| `map` | Transform each item | `{"op": "map", "expr": {...}}` |
| `select` | Pick specific fields | `{"op": "select", "fields": ["id", "name"]}` |
| `first` | Get first item | `{"op": "first"}` |
| `last` | Get last item | `{"op": "last"}` |
| `nth` | Get nth item (0-indexed) | `{"op": "nth", "index": 2}` |
| `count` | Count items | `{"op": "count"}` |

#### Aggregation Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `sum` | Sum a field | `{"op": "sum", "field": "amount"}` |
| `avg` | Average a field | `{"op": "avg", "field": "amount"}` |
| `min` | Minimum value | `{"op": "min", "field": "amount"}` |
| `max` | Maximum value | `{"op": "max", "field": "amount"}` |

#### Access Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `get` | Get nested field | `{"op": "get", "path": ["user", "profile", "email"]}` |
| `get` | Get with default | `{"op": "get", "path": ["x"], "default": 0}` |

#### Comparison Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `eq` | Equals | `{"op": "eq", "field": "status", "value": "active"}` |
| `neq` | Not equals | `{"op": "neq", "field": "status", "value": "deleted"}` |
| `gt` | Greater than | `{"op": "gt", "field": "age", "value": 18}` |
| `gte` | Greater than or equal | `{"op": "gte", "field": "score", "value": 100}` |
| `lt` | Less than | `{"op": "lt", "field": "price", "value": 50}` |
| `lte` | Less than or equal | `{"op": "lte", "field": "quantity", "value": 10}` |
| `contains` | String/list contains | `{"op": "contains", "field": "tags", "value": "urgent"}` |

#### Logic Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `and` | Logical AND | `{"op": "and", "conditions": [...]}` |
| `or` | Logical OR | `{"op": "or", "conditions": [...]}` |
| `not` | Logical NOT | `{"op": "not", "condition": {...}}` |
| `if` | Conditional | `{"op": "if", "condition": ..., "then": ..., "else": ...}` |

#### Tool Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `call` | Call a registered tool | `{"op": "call", "tool": "get_users", "args": {...}}` |

#### Combine Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `merge` | Merge objects | `{"op": "merge", "objects": [{"op": "var", "name": "a"}, {"op": "var", "name": "b"}]}` |
| `concat` | Concatenate lists | `{"op": "concat", "lists": [...]}` |
| `zip` | Zip lists together | `{"op": "zip", "lists": [...]}` |

## Example Programs

### Example 1: Filter and Sum Expenses

```json
{
  "op": "pipe",
  "steps": [
    {"op": "load", "name": "expenses"},
    {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
    {"op": "sum", "field": "amount"}
  ]
}
```

### Example 2: Query Voice Call Transcripts

```json
{
  "op": "pipe",
  "steps": [
    {"op": "call", "tool": "get_voice_calls"},
    {"op": "filter", "where": {"op": "eq", "field": "status", "value": "completed"}},
    {"op": "filter", "where": {"op": "gt", "field": "duration_ms", "value": 60000}},
    {"op": "select", "fields": ["id", "transcript", "duration_ms"]}
  ]
}
```

### Example 3: Combine Data from Multiple Sources

```json
{
  "op": "let",
  "name": "users",
  "value": {"op": "call", "tool": "get_users"},
  "in": {
    "op": "let",
    "name": "orders",
    "value": {"op": "call", "tool": "get_orders"},
    "in": {
      "op": "pipe",
      "steps": [
        {"op": "var", "name": "orders"},
        {"op": "filter", "where": {"op": "gt", "field": "total", "value": 100}},
        {"op": "map", "expr": {
          "op": "merge",
          "objects": [
            {"op": "get", "path": []},
            {"op": "pipe", "steps": [
              {"op": "var", "name": "users"},
              {"op": "filter", "where": {"op": "eq", "field": "id", "value": {"op": "get", "path": ["user_id"]}}},
              {"op": "first"},
              {"op": "select", "fields": ["name", "email"]}
            ]}
          ]
        }}
      ]
    }
  }
}
```

### Example 4: Conditional Logic

```json
{
  "op": "pipe",
  "steps": [
    {"op": "load", "name": "invoice"},
    {"op": "let", "name": "total", "value": {"op": "get", "path": ["total"]}, "in": {
      "op": "if",
      "condition": {"op": "gt", "field": "total", "value": 1000},
      "then": {"op": "literal", "value": "high_value"},
      "else": {
        "op": "if",
        "condition": {"op": "gt", "field": "total", "value": 100},
        "then": {"op": "literal", "value": "medium_value"},
        "else": {"op": "literal", "value": "low_value"}
      }
    }}
  ]
}
```

### Example 5: Using Previous Conversation Results

When running in a multi-turn conversation, previous results can be passed via context:

```elixir
# Turn 1: Get expenses
{:ok, expenses, _metrics} = PtcRunner.run(
  ~s({"op": "call", "tool": "get_expenses"}),
  tools: tools
)

# Turn 2: Use previous result
{:ok, total, _metrics} = PtcRunner.run(
  ~s({
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "previous_expenses"},
      {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
      {"op": "sum", "field": "amount"}
    ]
  }),
  context: %{"previous_expenses" => expenses},
  tools: tools
)
```

## Public API

### `PtcRunner.run/2`

Execute a PTC program with options.

```elixir
@spec run(String.t() | map(), keyword()) ::
  {:ok, any(), metrics()} | {:error, error()}

@type metrics :: %{
  duration_ms: non_neg_integer(),
  memory_bytes: non_neg_integer()
}

@type error ::
  {:parse_error, String.t()} |
  {:validation_error, String.t()} |
  {:execution_error, String.t()} |
  {:timeout, non_neg_integer()} |
  {:memory_exceeded, non_neg_integer()}
```

**Options:**
- `:context` - Map of pre-bound variables (default: `%{}`)
- `:tools` - Map of tool name to function (default: `%{}`)
- `:timeout` - Execution timeout in ms (default: `1000`)
- `:max_heap` - Max heap size in words (default: `1_250_000` ≈ 10MB)

**Example:**
```elixir
{:ok, result, metrics} = PtcRunner.run(
  program_json,
  context: %{"data" => [1, 2, 3]},
  tools: %{"fetch" => &MyApp.fetch/1},
  timeout: 5000
)

IO.inspect(metrics)
# %{duration_ms: 42, memory_bytes: 102400}
```

### `PtcRunner.run!/2`

Same as `run/2` but raises on error.

```elixir
result = PtcRunner.run!(program_json, opts)
```

## Tool Registration

Tools are simple functions that receive arguments and return results.

```elixir
# Define tools as a map of name => function
tools = %{
  "get_expenses" => fn _args ->
    # Return data directly
    [
      %{"id" => 1, "category" => "travel", "amount" => 500},
      %{"id" => 2, "category" => "food", "amount" => 50}
    ]
  end,

  "get_user" => fn %{"id" => id} ->
    # Tools receive args as a map
    MyApp.Users.get(id)
  end,

  "search" => fn %{"query" => query, "limit" => limit} ->
    MyApp.Search.run(query, limit: limit)
  end
}

# Use with run/2
PtcRunner.run(program, tools: tools)
```

**Tool Function Contract:**
- Receives: `map()` of arguments (may be empty `%{}`)
- Returns: Any Elixir term (maps, lists, primitives)
- Should not raise (return `{:error, reason}` for errors)

## Resource Limits

### Default Limits

| Resource | Default | Notes |
|----------|---------|-------|
| Timeout | 1,000 ms | Execution time limit |
| Max Heap | ~10 MB | Memory limit (1,250,000 words) |

### Configuring Limits

```elixir
# Per-call configuration
PtcRunner.run(program,
  timeout: 5000,      # 5 seconds
  max_heap: 5_000_000 # ~40MB
)

# Application-level defaults (in config.exs)
config :ptc_runner,
  default_timeout: 2000,
  default_max_heap: 2_500_000
```

### Execution Metrics

Every successful execution returns metrics:

```elixir
{:ok, result, metrics} = PtcRunner.run(program)

metrics
# %{
#   duration_ms: 42,        # Actual execution time
#   memory_bytes: 102400    # Peak memory usage
# }
```

### Error Handling

Resource limit errors include the limit that was exceeded:

```elixir
case PtcRunner.run(program, timeout: 100) do
  {:ok, result, metrics} ->
    handle_success(result)

  {:error, {:timeout, 100}} ->
    Logger.warning("Program exceeded 100ms timeout")

  {:error, {:memory_exceeded, bytes}} ->
    Logger.warning("Program exceeded memory limit: #{bytes} bytes")

  {:error, {:parse_error, msg}} ->
    Logger.error("Invalid JSON: #{msg}")

  {:error, {:validation_error, msg}} ->
    Logger.error("Invalid program: #{msg}")

  {:error, {:execution_error, msg}} ->
    Logger.error("Runtime error: #{msg}")
end
```

## Sandbox Implementation

Programs execute in isolated BEAM processes with resource limits:

```elixir
defmodule PtcRunner.Sandbox do
  @default_timeout 1_000
  @default_max_heap 1_250_000  # ~10MB (1 word = 8 bytes on 64-bit)

  def execute(ast, context, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_heap = Keyword.get(opts, :max_heap, @default_max_heap)

    parent = self()

    {pid, ref} = Process.spawn(fn ->
      result = Interpreter.eval(ast, context)
      memory = Process.info(self(), :memory) |> elem(1)
      send(parent, {:result, result, memory})
    end, [
      :monitor,
      {:max_heap_size, max_heap},
      {:priority, :low}
    ])

    start_time = System.monotonic_time(:millisecond)

    receive do
      {:result, result, memory} ->
        duration = System.monotonic_time(:millisecond) - start_time
        {:ok, result, %{duration_ms: duration, memory_bytes: memory}}

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error, {:memory_exceeded, max_heap * 8}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:execution_error, inspect(reason)}}
    after
      timeout ->
        Process.exit(pid, :kill)
        {:error, {:timeout, timeout}}
    end
  end
end
```

## Error Messages for LLM Consumption

Errors are structured for easy LLM retry loops:

```elixir
# Parse error
{:error, {:parse_error, "Unexpected token at position 42: expected '\"' but found '}"}}

# Validation error
{:error, {:validation_error, "Unknown operation 'filer'. Did you mean 'filter'?"}}

# Execution error
{:error, {:execution_error, "Cannot access field 'name' on nil. Path: users[0].profile.name"}}

# Timeout
{:error, {:timeout, 1000}}  # Program took longer than 1000ms

# Memory exceeded
{:error, {:memory_exceeded, 10485760}}  # Exceeded ~10MB limit
```

## Integration with LLMs

PtcRunner does not include LLM integration—compose it with your LLM client:

```elixir
defmodule MyApp.PTCAgent do
  @system_prompt """
  You are a data processing assistant. Generate JSON programs using this DSL:

  Operations: pipe, filter, map, sum, count, call, let, var, if
  Comparisons: eq, neq, gt, gte, lt, lte, contains
  Logic: and, or, not

  Example:
  {"op": "pipe", "steps": [
    {"op": "call", "tool": "get_data"},
    {"op": "filter", "where": {"op": "gt", "field": "value", "value": 100}},
    {"op": "sum", "field": "amount"}
  ]}

  Available tools: #{inspect(@tools)}
  """

  def run(user_request, context \\ %{}) do
    # 1. Generate program via LLM
    {:ok, response} = ReqLLM.generate_text(
      "openrouter:anthropic/claude-3-sonnet",
      user_request,
      system: @system_prompt
    )

    program = extract_json(response)

    # 2. Execute program
    case PtcRunner.run(program, context: context, tools: @tools) do
      {:ok, result, _metrics} ->
        {:ok, result}

      {:error, error} ->
        # 3. Optionally retry with error feedback
        retry_with_error(user_request, program, error)
    end
  end
end
```

See `test/e2e/llm_integration_test.exs` for complete examples.

## Implementation Phases

### Phase 1: Core Interpreter
- JSON parsing with Jason
- Basic operations: `literal`, `load`, `var`, `pipe`
- Collection operations: `filter`, `map`, `select`
- Aggregations: `sum`, `count`
- Sandbox with timeout and heap limits
- Execution metrics

### Phase 2: Query Operations
- Nested path access: `get`
- Comparisons: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `contains`
- More aggregations: `avg`, `min`, `max`
- Collection: `first`, `last`, `nth`, `reject`

### Phase 3: Logic & Variables
- Logic: `and`, `or`, `not`, `if`
- Variables: `let` bindings
- Combine: `merge`, `concat`

### Phase 4: Tool Integration
- Tool registry and `call` operation
- Integration tests with mock tools
- E2E test with LLM (ReqLLM + OpenRouter)

### Phase 5: Polish
- Error messages optimized for LLM consumption
- Validation with helpful suggestions
- Documentation and examples
- Hex package preparation

## Dependencies

Required:
- `jason` - JSON parsing

Optional (for E2E tests):
- `req_llm` - LLM integration examples

## References

- [Anthropic PTC Blog Post](https://www.anthropic.com/research/ptc)
- [Open-PTC-Agent (Python)](https://github.com/Chen-zexi/open-ptc-agent)
- [ReqLLM Documentation](https://hexdocs.pm/req_llm)
