# PtcRunner.Lisp API Updates

> **Status:** Planned
> **Scope:** Breaking changes to `PtcRunner.Lisp` for SubAgent compatibility

This document specifies planned changes to the existing `PtcRunner.Lisp` API.

---

## Table of Contents

1. [Summary](#summary)
2. [Return Type Change](#return-type-change)
3. [Error Type Change](#error-type-change)
4. [Tool Registration](#tool-registration)
5. [Signature Validation](#signature-validation)
6. [Usage Metrics](#usage-metrics)
7. [Migration Guide](#migration-guide)

---

## Summary

| Change | Impact | Description |
|--------|--------|-------------|
| Return `Step` struct | **Breaking** | Replace 4-tuple with struct |
| Error `Step` struct | **Breaking** | Replace 2-tuple with struct |
| Tool format expansion | Non-breaking | Accept function refs and signatures |
| Optional `:signature` | Non-breaking | Opt-in input/output validation |
| Expose metrics | Non-breaking | New `usage` field in Step |

---

## Return Type Change

### Current

```elixir
{:ok, result, memory_delta, new_memory} = PtcRunner.Lisp.run(source, opts)
```

### Planned

```elixir
{:ok, %PtcRunner.Step{}} = PtcRunner.Lisp.run(source, opts)
```

See [step.md](step.md) for full struct specification.

### Rationale

- Pattern match on named fields instead of tuple positions
- Easy to add fields without breaking code
- Consistent with SubAgent API
- Metrics now accessible

---

## Error Type Change

### Current

```elixir
{:error, {:timeout, 1000}}
{:error, {:parse_error, "unexpected token"}}
```

### Planned

```elixir
{:error, %PtcRunner.Step{
  fail: %{reason: :timeout, message: "execution exceeded 1000ms limit"},
  usage: %{duration_ms: 1000, ...}
}}

{:error, %PtcRunner.Step{
  fail: %{reason: :parse_error, message: "unexpected token at line 3"},
  usage: nil
}}
```

### Error Reasons

Lisp-specific error reasons:

| Reason | Description |
|--------|-------------|
| `:parse_error` | Invalid PTC-Lisp syntax |
| `:analysis_error` | Semantic error (undefined variable, etc.) |
| `:eval_error` | Runtime error (division by zero, etc.) |
| `:timeout` | Execution exceeded time limit |
| `:memory_exceeded` | Process exceeded heap limit |
| `:validation_error` | Input or output doesn't match signature |

---

## Tool Registration

### Current

Only simple functions:

```elixir
tools = %{
  "get-user" => fn args -> MyApp.get_user(args["id"]) end
}
```

### Planned

Multiple formats (excluding LLMTool):

```elixir
tools = %{
  # Simple function (existing, still works)
  "get-time" => fn _args -> DateTime.utc_now() end,

  # Function reference (auto-extract @spec/@doc if available)
  "get-user" => &MyApp.get_user/1,

  # Function with explicit signature (for validation)
  "search" => {&MyApp.search/2, "(query :string, limit :int) -> [{id :int}]"},

  # Function with signature and description (keyword list)
  "analyze" => {&MyApp.analyze/1,
    signature: "(data :map) -> {score :float}",
    description: "Analyze data and return anomaly score"
  },

  # Skip validation explicitly
  "dynamic" => {&MyApp.dynamic/1, :skip}
}
```

### Format Summary

| Format | When to Use |
|--------|-------------|
| `fun` | Quick prototyping, relies on @spec/@doc extraction |
| `{fun, "sig"}` | Common case, validation needed, no description |
| `{fun, signature: "...", description: "..."}` | Production tools with LLM-visible docs |
| `{fun, :skip}` | Dynamic tools, skip validation |

### Internal Normalization

All formats normalize to `PtcRunner.Tool`:

```elixir
defmodule PtcRunner.Tool do
  defstruct [:name, :function, :signature, :description, :type]

  @type t :: %__MODULE__{
    name: String.t(),
    function: (map() -> term()),
    signature: String.t() | nil,
    description: String.t() | nil,
    type: :native | :llm | :subagent
  }
end
```

For Lisp, only `:native` type is supported.

### Description Extraction

When a bare function reference is provided (e.g., `&MyApp.search/2`), the system attempts to extract documentation:

1. **@doc** - Extracts the function's `@doc` attribute as description
2. **@spec** - Converts `@spec` to PTC signature format (best effort)

```elixir
# In your module
@doc "Search for items matching query"
@spec search(String.t(), integer()) :: [map()]
def search(query, limit), do: ...

# Auto-extracted:
# signature: "(query :string, limit :int) -> [:map]"
# description: "Search for items matching query"
tools = %{"search" => &MyApp.search/2}
```

**Limitations:**
- Requires docs to be compiled (not available in releases without `--docs`)
- Only works for named functions (not anonymous)
- @spec conversion is best-effort; explicit signatures are more precise

---

## Signature Validation

### New Option

Add optional `:signature` to validate context inputs and result output:

```elixir
{:ok, step} = PtcRunner.Lisp.run(
  "(call \"get-orders\" {:id ctx/user_id :limit ctx/limit})",
  context: %{user_id: 123, limit: 10},
  tools: order_tools,
  signature: "(user_id :int, limit :int) -> {orders [:map]}"
)
```

### Validation Behavior

**Input validation** (before execution):
- Context must contain signature's input parameters
- Types must match

**Output validation** (after execution):
- Result must match signature's output type

### Validation Errors

```elixir
# Input validation failure
{:error, %PtcRunner.Step{
  fail: %{
    reason: :validation_error,
    message: "user_id: expected int, got string \"abc\""
  }
}}

# Output validation failure
{:error, %PtcRunner.Step{
  fail: %{
    reason: :validation_error,
    message: "orders[0].id: expected int, got nil"
  }
}}
```

### Validation Modes

```elixir
PtcRunner.Lisp.run(source,
  signature: "(id :int) -> {result :map}",
  signature_validation: :enabled  # default
)
```

| Mode | Behavior |
|------|----------|
| `:enabled` | Validate inputs/outputs, fail on errors (default) |
| `:warn_only` | Validate, log warnings, continue |
| `:disabled` | Skip validation |
| `:strict` | Reject extra fields, require tool specs |

### Signature Syntax

Same syntax as SubAgent. See [signature-syntax.md](signature-syntax.md).

**Shorthand:**
```
:string :int :float :bool :keyword :any
[:int]                          ; list
{:id :int :name :string}        ; map
{:id :int :email :string?}      ; optional field
```

**Full format:**
```
(inputs) -> outputs
```

---

## Usage Metrics

### Current

Metrics are computed but discarded:

```elixir
# Sandbox returns metrics internally but run/2 drops them
{:ok, value, delta, memory}
```

### Planned

Metrics included in Step:

```elixir
%PtcRunner.Step{
  return: value,
  memory: memory,
  memory_delta: delta,
  usage: %{
    duration_ms: 42,
    memory_bytes: 1024
  }
}
```

---

## Migration Guide

### Basic Usage

**Before:**
```elixir
case PtcRunner.Lisp.run(source, context: ctx, tools: tools) do
  {:ok, result, _delta, memory} ->
    IO.puts("Result: #{inspect(result)}")
    {:ok, result, memory}

  {:error, {type, message}} ->
    IO.puts("Error: #{type} - #{message}")
    {:error, message}
end
```

**After:**
```elixir
case PtcRunner.Lisp.run(source, context: ctx, tools: tools) do
  {:ok, step} ->
    IO.puts("Result: #{inspect(step.return)}")
    IO.puts("Took #{step.usage.duration_ms}ms")
    {:ok, step.return, step.memory}

  {:error, step} ->
    IO.puts("Error: #{step.fail.reason} - #{step.fail.message}")
    {:error, step.fail.message}
end
```

### Accessing Memory Delta

**Before:**
```elixir
{:ok, _result, delta, _memory} = PtcRunner.Lisp.run(source, opts)
changed_keys = Map.keys(delta)
```

**After:**
```elixir
{:ok, step} = PtcRunner.Lisp.run(source, opts)
changed_keys = Map.keys(step.memory_delta)
```

### Error Handling

**Before:**
```elixir
case PtcRunner.Lisp.run(source, opts) do
  {:error, {:timeout, ms}} -> handle_timeout(ms)
  {:error, {:parse_error, msg}} -> handle_parse_error(msg)
  {:error, {type, msg}} -> handle_other(type, msg)
end
```

**After:**
```elixir
case PtcRunner.Lisp.run(source, opts) do
  {:error, %{fail: %{reason: :timeout}} = step} ->
    handle_timeout(step.usage.duration_ms)

  {:error, %{fail: %{reason: :parse_error, message: msg}}} ->
    handle_parse_error(msg)

  {:error, step} ->
    handle_other(step.fail.reason, step.fail.message)
end
```

### Adding Validation

**New feature (opt-in):**
```elixir
{:ok, step} = PtcRunner.Lisp.run(
  "(call \"process\" {:items ctx/items})",
  context: %{items: [1, 2, 3]},
  tools: %{"process" => &MyApp.process/1},
  signature: "(items [:int]) -> {count :int, total :int}"
)

# step.return is guaranteed to have count and total as integers
```

---

## Implementation Order

1. **Create `PtcRunner.Step` struct** - Foundation
2. **Create `PtcRunner.Tool` struct** - Normalize tool definitions
3. **Update `PtcRunner.Lisp.run/2`** - Return Step, expose metrics
4. **Add signature parser** - Shared with SubAgent
5. **Add `:signature` option** - Input/output validation

---

## Decisions

1. **No backward compatibility wrapper** - Breaking changes acceptable per 0.x policy.

2. **Signature validates both inputs and outputs** - Lisp programs have inputs via `:context`, so full signature makes sense.

3. **Same validation engine** - Shared between Lisp and SubAgent.

4. **Memory naming unchanged** - Already uses `memory/` prefix and `:memory` option.

---

## Related Documents

- [specification.md](specification.md) - SubAgent API reference
- [guides/](guides/) - Usage guides and patterns
- [step.md](step.md) - Step struct specification
- [signature-syntax.md](signature-syntax.md) - Signature syntax reference
