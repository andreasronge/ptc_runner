# Type Coercion Matrix

> **Status:** Planned
> **Scope:** Type mapping and coercion rules for `PtcRunner.SubAgent`

This document specifies how Elixir types map to Signature types and the coercion rules applied during validation.

---

## Overview

The SubAgent type system bridges two worlds:
- **Elixir types** - Rich type system with `@spec` annotations
- **Signature types** - JSON-compatible types for LLM communication

The coercion matrix ensures:
1. **Lenient input validation** - Accept LLM quirks (e.g., quoted numbers)
2. **Strict output validation** - Enforce tool contracts
3. **Graceful degradation** - Fall back to `:any` for unsupported types

---

## Elixir to Signature Type Mapping

### Primitive Types

| Elixir Type | Signature Type | JSON Example | Notes |
|-------------|----------------|--------------|-------|
| `String.t()` | `:string` | `"hello"` | UTF-8 strings |
| `binary()` | `:string` | `"hello"` | Same as String.t() |
| `integer()` | `:int` | `42`, `-1` | Whole numbers |
| `non_neg_integer()` | `:int` | `0`, `42` | Validation can enforce >= 0 |
| `pos_integer()` | `:int` | `1`, `42` | Validation can enforce > 0 |
| `float()` | `:float` | `3.14`, `-0.5` | Decimal numbers |
| `number()` | `:float` | `42`, `3.14` | Accepts int or float |
| `boolean()` | `:bool` | `true`, `false` | Boolean values |
| `atom()` | `:keyword` | `:pending` | Atoms as keywords |
| `any()` | `:any` | Any value | Matches everything |
| `term()` | `:any` | Any value | Same as any() |

### Collection Types

| Elixir Type | Signature Type | JSON Example | Notes |
|-------------|----------------|--------------|-------|
| `list(t)` | `[:t]` | `[1, 2, 3]` | Homogeneous lists |
| `[t]` | `[:t]` | `[1, 2, 3]` | List syntax variant |
| `map()` | `:map` | `{}` | Untyped dictionary |
| `%{key: type}` | `{:key :type}` | `{key: 1}` | Typed map |
| `%{optional(atom()) => t}` | `:map` | `{...}` | Dynamic keys |
| `keyword()` | `:map` | `{key: 1}` | Converted to map |
| `keyword(t)` | `{:key :t}` | `{key: 1}` | Typed keyword list |

### Special Types - Recommended Handling

| Elixir Type | Signature Type | JSON Representation | Rationale |
|-------------|----------------|---------------------|-----------|
| `DateTime.t()` | `:string` | `"2025-12-29T10:30:00Z"` | ISO 8601 format, LLM-friendly |
| `Date.t()` | `:string` | `"2025-12-29"` | ISO 8601 date only |
| `Time.t()` | `:string` | `"10:30:00"` | ISO 8601 time only |
| `NaiveDateTime.t()` | `:string` | `"2025-12-29T10:30:00"` | ISO 8601 without timezone |
| `timeout()` | `:int` | `5000`, `-1` | Milliseconds, -1 for infinity |
| `module()` | `:keyword` | `:MyModule` | Module names as atoms |

### Result/Union Types

| Elixir Type | Signature Type | JSON Example | Rationale |
|-------------|----------------|--------------|-----------|
| `{:ok, t} \| {:error, e}` | `{result :t, error :e?}` | `{result: data, error: null}` | Explicit success/error fields |
| `t \| nil` | `:t?` | `value` or `null` | Optional via `?` suffix |

### Unsupported Types (Require Override)

| Elixir Type | Reason | Recommendation |
|-------------|--------|----------------|
| `pid()` | Non-serializable | Use string identifier |
| `reference()` | Non-serializable | Use string identifier |
| `port()` | Non-serializable | Avoid in tool signatures |
| `fun()` | Non-serializable | Not applicable |
| `MapSet.t()` | Not JSON primitive | Convert to list `[:t]` |
| `tuple()` | Not JSON primitive | Convert to list or map |
| Opaque `t()` | Cannot introspect | Require explicit signature |

---

## Input Coercion Rules

LLMs sometimes produce slightly malformed data. Input coercion handles common cases:

### Coercion Table

| From Type | To Type | Behavior | Warning Generated |
|-----------|---------|----------|-------------------|
| `"42"` | `:int` | `42` | Yes: "coerced string to integer" |
| `"3.14"` | `:float` | `3.14` | Yes: "coerced string to float" |
| `"-5"` | `:int` | `-5` | Yes: "coerced string to integer" |
| `"true"` | `:bool` | `true` | Yes: "coerced string to boolean" |
| `"false"` | `:bool` | `false` | Yes: "coerced string to boolean" |
| `42` | `:float` | `42.0` | No (silent widening) |
| `42.0` | `:int` | Error | No (precision loss not allowed) |
| `"hello"` | `:int` | Error | No (cannot coerce) |
| `:atom` | `:string` | `"atom"` | Yes: "coerced keyword to string" |
| `"atom"` | `:keyword` | `:atom` | Yes: "coerced string to keyword" |

### Coercion Modes

| Mode | Input Coercion | Output Validation | Use Case |
|------|----------------|-------------------|----------|
| `:enabled` (default) | Apply with warnings | Strict | Production |
| `:warn_only` | Apply with warnings | Log warnings only | Development |
| `:strict` | No coercion | Strict, reject extra fields | Testing |
| `:disabled` | Skip | Skip | Debugging |

---

## Output Validation Rules

Output validation is **strict** - tool implementations must return correct types.

### Validation Behavior

| Scenario | Result | Behavior |
|----------|--------|----------|
| Value matches type | `:ok` | Proceed |
| Wrong primitive type | `:error` | Error with path |
| Missing required field | `:error` | Error with field name |
| Extra field (`:enabled` mode) | `:ok` | Allowed, ignored |
| Extra field (`:strict` mode) | `:error` | Rejected |
| `nil` for required field | `:error` | Error: "expected X, got nil" |
| `nil` for optional field | `:ok` | Allowed |

### Error Format

Validation errors include paths for precise debugging:

```
Tool validation errors:
- results[0].customer.id: expected int, got string "abc"
- results[2].amount: expected float, got nil
- metadata.timestamp: expected string, got int 1703849400

Tool validation warnings:
- limit: coerced string "10" to int
- user_id: coerced string "42" to int
```

---

## Type Extraction from @spec

### Extraction Pipeline

```
@spec function(params) :: return_type
                ↓
1. Code.Typespec.fetch_specs/1 - Get raw typespec
                ↓
2. Expand custom @type definitions (up to depth 3)
                ↓
3. Map Elixir types to Signature types
                ↓
4. Handle unsupported types (fallback to :any or error)
                ↓
"(param1 :type, param2 :type) -> output_type"
```

### Multiple @spec Clauses

When a function has multiple `@spec` clauses:

```elixir
@spec search(String.t()) :: [map()]
@spec search(String.t(), integer()) :: [map()]
def search(query, limit \\ 10), do: ...
```

**Resolution strategy:**
1. Use the highest arity clause (most general)
2. Allow explicit override via `{&fun/arity, "signature"}`
3. In `:strict` mode, require explicit signature for ambiguous cases

### Custom @type Expansion

```elixir
@type user :: %{id: integer(), name: String.t()}

@spec get_user(integer()) :: {:ok, user()} | {:error, :not_found}
```

**Expansion result:**
```
(id :int) -> {result {id :int, name :string}, error :keyword?}
```

**Expansion limits:**
- Maximum recursion depth: 3
- Opaque types: Fall back to `:any` with warning
- Self-referential types: Fall back to `:any`

---

## Implementation Reference

### Type Extractor Module

```elixir
defmodule PtcRunner.SubAgent.TypeExtractor do
  @moduledoc """
  Extract signature types from Elixir @spec definitions.
  """

  @doc """
  Extract signature from a function reference.

  ## Examples

      iex> TypeExtractor.extract(&MyApp.search/2)
      {:ok, "(query :string, limit :int) -> [:map]"}

      iex> TypeExtractor.extract(&MyApp.complex/1)
      {:error, :unsupported_type, "pid()"}
  """
  @spec extract(function()) :: {:ok, String.t()} | {:error, atom(), term()}
  def extract(fun)
end
```

### Type Coercion Module

```elixir
defmodule PtcRunner.SubAgent.TypeCoercion do
  @moduledoc """
  Coerce values to expected types with warning generation.
  """

  @doc """
  Coerce a value to the expected type.

  ## Examples

      iex> TypeCoercion.coerce("42", :int)
      {:ok, 42, ["coerced string \"42\" to integer"]}

      iex> TypeCoercion.coerce("hello", :int)
      {:error, "cannot coerce string \"hello\" to integer"}
  """
  @spec coerce(term(), atom()) :: {:ok, term(), [String.t()]} | {:error, String.t()}
  def coerce(value, type)
end
```

### Signature Validator Module

```elixir
defmodule PtcRunner.SubAgent.SignatureValidator do
  @moduledoc """
  Validate data against signature type specifications.
  """

  @doc """
  Validate input with coercion.

  Returns coerced value and any warnings generated.
  """
  @spec validate_input(term(), signature(), keyword()) ::
    {:ok, term(), [String.t()]} | {:error, [validation_error()]}
  def validate_input(value, signature, opts \\ [])

  @doc """
  Validate output strictly (no coercion).
  """
  @spec validate_output(term(), signature(), keyword()) ::
    :ok | {:error, [validation_error()]}
  def validate_output(value, signature, opts \\ [])
end
```

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────────────────────┐
│              ELIXIR → SIGNATURE TYPE MAPPING                    │
├─────────────────────────────────────────────────────────────────┤
│ PRIMITIVES                                                      │
│   String.t()           → :string                                │
│   integer()            → :int                                   │
│   float()              → :float                                 │
│   boolean()            → :bool                                  │
│   atom()               → :keyword                               │
│   any()                → :any                                   │
│                                                                 │
│ COLLECTIONS                                                     │
│   list(t)              → [:t]                                   │
│   map()                → :map                                   │
│   %{key: type}         → {:key :type}                           │
│                                                                 │
│ SPECIAL TYPES                                                   │
│   DateTime.t()         → :string (ISO 8601)                     │
│   timeout()            → :int (ms, -1 = infinity)               │
│   {:ok, t} | {:err, e} → {result :t, error :e?}                 │
│                                                                 │
│ INPUT COERCION (with warnings)                                  │
│   "42"  → :int         ✓ coerced                                │
│   "3.14" → :float      ✓ coerced                                │
│   "true" → :bool       ✓ coerced                                │
│   42 → :float          ✓ silent                                 │
│   42.0 → :int          ✗ error                                  │
│                                                                 │
│ OUTPUT VALIDATION                                               │
│   Strict - no coercion, exact type match required               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Related Documents

- [signature-syntax.md](signature-syntax.md) - Signature string syntax
- [specification.md](specification.md) - SubAgent API specification
- [tutorial.md](tutorial.md) - Usage examples
