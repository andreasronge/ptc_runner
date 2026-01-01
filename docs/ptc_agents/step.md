# PtcRunner.Step Specification

> **Status:** Planned
> **Scope:** Shared result struct for `PtcRunner.Lisp` and `PtcRunner.SubAgent`

This document specifies the `PtcRunner.Step` struct returned by both APIs.

---

## Overview

`Step` is the unified result type for all PTC executions. It captures:
- **Success data** (`return`) or **failure info** (`fail`)
- **Execution metrics** (`usage`)
- **State changes** (`memory`, `memory_delta`)
- **Debug info** (`trace`, `signature`)

---

## Struct Definition

```elixir
defmodule PtcRunner.Step do
  @moduledoc """
  Result of executing a PTC program or SubAgent mission.

  Returned by both `PtcRunner.Lisp.run/2` and `PtcRunner.SubAgent.run/2`.
  """

  defstruct [
    :return,
    :fail,
    :memory,
    :memory_delta,
    :signature,
    :usage,
    :trace,
    :trace_id,
    :parent_trace_id
  ]

  @type t :: %__MODULE__{
    return: term() | nil,
    fail: fail() | nil,
    memory: map(),
    memory_delta: map() | nil,
    signature: String.t() | nil,
    usage: usage() | nil,
    trace: [trace_entry()] | nil,
    trace_id: String.t() | nil,
    parent_trace_id: String.t() | nil
  }
end
```

---

## Fields

### `return`

The computed result value on success.

- **Type:** `term() | nil`
- **Set when:** Mission/program completed successfully
- **Nil when:** Execution failed (check `fail` field)

```elixir
{:ok, step} = SubAgent.run("Find top customer", ...)
step.return  #=> %{name: "Acme Corp", revenue: 1_200_000}
```

### `fail`

Error information on failure.

- **Type:** `fail() | nil`
- **Set when:** Execution failed
- **Nil when:** Execution succeeded

```elixir
@type fail :: %{
  required(:reason) => atom(),
  required(:message) => String.t(),
  optional(:op) => String.t(),
  optional(:details) => map()
}
```

| Field | Type | Description |
|-------|------|-------------|
| `reason` | `atom()` | Machine-readable error code (e.g., `:timeout`, `:validation_error`) |
| `message` | `String.t()` | Human-readable description |
| `op` | `String.t()` | Operation/tool that failed (optional) |
| `details` | `map()` | Additional context (optional) |

```elixir
{:error, step} = SubAgent.run("Invalid mission", ...)
step.fail  #=> %{reason: :validation_error, message: "count: expected int, got string"}
```

### `memory`

Final memory state after execution.

- **Type:** `map()`
- **Always set:** Contains accumulated memory from all operations
- **Access in PTC-Lisp:** `memory/key` prefix

```elixir
step.memory  #=> %{processed_ids: [1, 2, 3], cache: %{...}}
```

### `memory_delta`

Keys that changed during execution (Lisp only).

- **Type:** `map() | nil`
- **Set when:** Lisp execution modifies memory
- **Nil when:** SubAgent execution (use `trace` instead)

```elixir
step.memory_delta  #=> %{processed_ids: [1, 2, 3]}  # Only changed keys
```

### `signature`

The contract used for validation.

- **Type:** `String.t() | nil`
- **Set when:** Signature was provided to `run/2`
- **Used for:** Type propagation when chaining steps

```elixir
step.signature  #=> "() -> {count :int, _email_ids [:int]}"
```

### `usage`

Execution metrics.

- **Type:** `usage() | nil`
- **Set when:** Execution completed (success or failure after running)
- **Nil when:** Early validation failure (before execution)

```elixir
@type usage :: %{
  required(:duration_ms) => non_neg_integer(),
  required(:memory_bytes) => non_neg_integer(),
  optional(:turns) => pos_integer(),
  optional(:input_tokens) => non_neg_integer(),
  optional(:output_tokens) => non_neg_integer(),
  optional(:total_tokens) => non_neg_integer(),
  optional(:llm_requests) => non_neg_integer()
}
```

| Field | Source | Description |
|-------|--------|-------------|
| `duration_ms` | Both | Total execution time |
| `memory_bytes` | Both | Peak memory usage |
| `turns` | SubAgent | Number of LLM turns used |
| `input_tokens` | SubAgent | Total input tokens (if LLM reports) |
| `output_tokens` | SubAgent | Total output tokens (if LLM reports) |
| `total_tokens` | SubAgent | `input_tokens + output_tokens` |
| `llm_requests` | SubAgent | Number of LLM API calls |

### `trace`

Execution trace for debugging (SubAgent only).

- **Type:** `[trace_entry()] | nil`
- **Set when:** SubAgent execution
- **Nil when:** Lisp execution

```elixir
@type trace_entry :: %{
  turn: pos_integer(),
  program: String.t(),
  result: term(),
  tool_calls: [tool_call()]
}

@type tool_call :: %{
  name: String.t(),
  args: map(),
  result: term(),
  error: String.t() | nil,        # Error message if tool failed
  timestamp: DateTime.t(),         # When tool was called
  duration_ms: non_neg_integer()   # How long tool took
}
```

> **Note:** See [parallel-trace-design.md](parallel-trace-design.md) for enhanced trace structures used in parallel execution scenarios.

```elixir
step.trace
#=> [
#=>   %{turn: 1, program: "(call \"search\" {:q \"urgent\"})", result: [...], tool_calls: [...]},
#=>   %{turn: 2, program: "(call \"return\" {:count 5})", result: %{count: 5}, tool_calls: []}
#=> ]
```

### `trace_id`

Unique identifier for this execution (for tracing correlation).

- **Type:** `String.t() | nil`
- **Set when:** SubAgent execution (32-character hex string)
- **Nil when:** Lisp execution
- **Used for:** Correlating traces in parallel and nested agent executions

```elixir
step.trace_id  #=> "a1b2c3d4e5f6..."
```

### `parent_trace_id`

ID of parent trace for nested agent calls.

- **Type:** `String.t() | nil`
- **Set when:** This agent was spawned by another agent
- **Nil when:** Root-level execution (no parent)
- **Used for:** Linking child executions to their parent

```elixir
# Root agent
root_step.trace_id         #=> "abc123..."
root_step.parent_trace_id  #=> nil

# Nested agent spawned by root
nested_step.trace_id         #=> "def456..."
nested_step.parent_trace_id  #=> "abc123..."  # Links to parent
```

See `PtcRunner.Tracer` for trace generation and management.

---

## Error Reasons

Complete list of error reasons in `step.fail.reason`:

| Reason | Source | Description |
|--------|--------|-------------|
| `:invalid_config` | SubAgent | Invalid combination of `max_turns` and `tools` |
| `:parse_error` | Lisp | Invalid PTC-Lisp syntax |
| `:analysis_error` | Lisp | Semantic error (undefined variable, etc.) |
| `:eval_error` | Lisp | Runtime error (division by zero, etc.) |
| `:timeout` | Both | Execution exceeded time limit |
| `:memory_exceeded` | Both | Process exceeded heap limit |
| `:validation_error` | Both | Input or output doesn't match signature |
| `:tool_error` | SubAgent | Tool raised an exception |
| `:tool_not_found` | SubAgent | Called non-existent tool |
| `:reserved_tool_name` | SubAgent | Attempted to register `return` or `fail` |
| `:max_turns_exceeded` | SubAgent | Turn limit reached without termination |
| `:max_depth_exceeded` | SubAgent | Nested agent depth limit exceeded |
| `:turn_budget_exhausted` | SubAgent | Total turn budget exhausted |
| `:mission_timeout` | SubAgent | Total mission duration exceeded |
| `:llm_error` | SubAgent | LLM callback failed after retries |
| `:llm_required` | SubAgent | LLM option is required for agent execution |
| `:no_code_found` | SubAgent | No PTC-Lisp code found in LLM response |
| `:llm_not_found` | SubAgent | LLM atom not in registry |
| `:llm_registry_required` | SubAgent | Atom LLM used without registry |
| `:invalid_llm` | SubAgent | Registry value not a function |
| `:chained_failure` | SubAgent | Chained onto a failed step |
| `:template_error` | SubAgent | Template placeholder missing |
| Custom atoms | SubAgent | From `(fail {:reason :custom ...})` |

---

## Usage Patterns

### Success Check

```elixir
case SubAgent.run(prompt, opts) do
  {:ok, step} ->
    IO.puts("Result: #{inspect(step.return)}")
    IO.puts("Took #{step.usage.duration_ms}ms")

  {:error, step} ->
    IO.puts("Failed: #{step.fail.reason} - #{step.fail.message}")
end
```

### Chaining Steps

Pass a successful step's return and signature to the next step:

```elixir
{:ok, step1} = SubAgent.run("Find emails",
  signature: "() -> {count :int, _ids [:int]}",
  ...
)

# Option 1: Explicit
{:ok, step2} = SubAgent.run("Process emails",
  context: step1.return,
  context_signature: step1.signature,
  ...
)

# Option 2: Auto-extraction (SubAgent only)
{:ok, step2} = SubAgent.run("Process emails",
  context: step1,  # Extracts return and signature automatically
  ...
)
```

### Accessing Firewalled Data

Fields prefixed with `_` are hidden from LLM history but available in `return`:

```elixir
{:ok, step} = SubAgent.run("Find emails",
  signature: "() -> {count :int, _email_ids [:int]}",
  ...
)

step.return.count      #=> 5 (visible to LLM)
step.return._email_ids #=> [101, 102, 103, 104, 105] (hidden from LLM)
```

---

## Related Documents

- [specification.md](specification.md) - SubAgent API reference
- [guides/](guides/) - Usage guides and patterns
- [signature-syntax.md](signature-syntax.md) - Signature syntax reference
- [lisp-api-updates.md](lisp-api-updates.md) - Breaking changes to existing Lisp API
- [parallel-trace-design.md](parallel-trace-design.md) - Trace aggregation for concurrent execution
