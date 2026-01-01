# Signature Syntax Specification

**Status:** Planned
**Scope:** `PtcRunner.SubAgent` signature validation

This document specifies the signature string syntax for PtcRunner SubAgents.

---

## Overview

Signatures define the **contract** between agents and tools:
- **Input parameters** - What the caller must provide
- **Output type** - What the callee will return

```elixir
signature: "(query :string, limit :int) -> {count :int, items [{id :int}]}"
```

Signatures are:
- **Token-efficient** - Compact syntax optimized for LLM prompts
- **Human-readable** - Intuitive arrow notation for function contracts
- **Validated at runtime** - Inputs and outputs are checked against the signature

---

## Full Signature Format

```
(inputs) -> output
```

**Examples:**

```
() -> {count :int}                           # no inputs
(query :string) -> [{id :int}]               # one input
(user {:id :int}, limit :int) -> :any        # nested input
```

**Shorthand:** Omit `() ->` when there are no inputs:

```elixir
signature: "{count :int}"  # equivalent to "() -> {count :int}"
```

---

## Type Reference

### Primitive Types

| Type | Description | Example Values |
|------|-------------|----------------|
| `:string` | UTF-8 string | `"hello"`, `""` |
| `:int` | Integer | `42`, `-1`, `0` |
| `:float` | Floating point | `3.14`, `-0.5` |
| `:bool` | Boolean | `true`, `false` |
| `:keyword` | Keyword/atom | `:pending`, `:active` |
| `:any` | Any value | Matches everything |

### Collection Types

| Syntax | Description | Example |
|--------|-------------|---------|
| `[:type]` | List of type | `[:int]`, `[:string]` |
| `[{...}]` | List of maps | `[{id :int, name :string}]` |
| `{...}` | Map with typed fields | `{id :int, name :string}` |
| `:map` | Any map | Dynamic keys |

### Optional Fields

Use `?` suffix for optional (nullable) fields:

```
{id :int, email :string?}   # email is optional (may be nil)
```

### Nested Structures

Maps can be arbitrarily nested:

```
{user {id :int, profile {bio :string, avatar :string?}}}
```

---

## Syntax Summary

```
Primitives:
  :string :int :float :bool :keyword :any

Lists:
  [:int]                          # list of integers
  [:string]                       # list of strings
  [{id :int, name :string}]       # list of maps

Maps:
  {id :int, name :string}         # map with required fields
  :map                            # any map (dynamic keys)

Optional (? suffix):
  {id :int, email :string?}       # email is optional

Nested:
  {user {id :int, address {city :string, zip :string}}}

Full signature:
  (param1 :type, param2 :type) -> output_type

Shorthand (no inputs):
  {count :int}                    # same as () -> {count :int}
```

---

## Named Parameters

Input parameters have names that become available in the signature:

```elixir
signature: "(user {:id :int, :name :string}, limit :int) -> [{order_id :int}]"
```

The names `user` and `limit`:
- Document what each parameter represents
- Are validated against template placeholders in prompts
- Appear in tool schemas shown to LLMs

---

## Firewall Convention

Fields prefixed with `_` are **firewalled**:

```elixir
signature: "() -> {summary :string, count :int, _email_ids [:int]}"
```

Firewalled fields:
- **Available** in Lisp context (`ctx/_email_ids`)
- **Available** to Elixir code (`step.return._email_ids`)
- **Hidden** from LLM prompt text (shown as `<Firewalled>`)
- **Hidden** from parent LLM when agent is used as tool

This protects LLM context windows while preserving data flow.

---

## Validation Behavior

### Input Validation

When a tool is called, inputs are validated against signature parameters:

```elixir
# Signature: (id :int, name :string) -> :bool
# Tool call: (call "check" {:id "42" :name "Alice"})

# Behavior:
# 1. Coerce "42" -> 42 (string to int, with warning)
# 2. Validate "Alice" is string
# 3. Proceed with call
```

### Output Validation

When `return` is called, data is validated against the return type:

```elixir
# Signature: () -> {count :int, items [:string]}
# Return: (return {:count 5 :items ["a" "b"]})

# Behavior:
# 1. Validate count is int
# 2. Validate items is list of strings
# 3. Mission succeeds

# If validation fails, error is fed back to LLM for self-correction
```

### Coercion Rules

Lenient coercion for inputs (LLMs sometimes quote numbers):

| From | To | Behavior |
|------|----|----------|
| `"42"` | `:int` | `42` (with warning) |
| `"3.14"` | `:float` | `3.14` (with warning) |
| `"true"` | `:bool` | `true` (with warning) |
| `42` | `:float` | `42.0` (silent) |

Output validation is **strict** - no coercion applied.

### Validation Modes

```elixir
SubAgent.run(agent, signature_validation: :enabled, llm: llm)
```

| Mode | Behavior |
|------|----------|
| `:enabled` | Validate, fail on errors, allow extra fields (default) |
| `:warn_only` | Validate, log warnings, continue |
| `:disabled` | Skip all validation |
| `:strict` | Validate, fail on errors, reject extra fields |

---

## Error Messages

Validation errors include paths for precise debugging:

```
Tool validation errors:
- results[0].customer.id: expected int, got string "abc"
- results[2].amount: expected float, got nil

Tool validation warnings:
- limit: coerced string "10" to int
```

Errors are fed back to the LLM for self-correction.

---

## Schema Generation for Prompts

Tool schemas are rendered in the LLM prompt using signature syntax:

```
## Tools you can call

search(query :string, limit :int) -> [{id :int, title :string}]
  Search for items matching query.

get_user(id :int) -> {name :string, email :string?}
  Fetch user by ID. Email may be null.
```

---

## Implementation Modules

```
lib/ptc_runner/
├── sub_agent/
│   ├── signature.ex          # Signature parsing and validation
│   ├── signature/
│   │   ├── parser.ex         # String -> AST
│   │   ├── validator.ex      # Validation logic
│   │   ├── coercion.ex       # Type coercion rules
│   │   ├── renderer.ex       # Signature -> prompt string
│   │   └── errors.ex         # Path-based error formatting
```

### Core Functions

```elixir
defmodule PtcRunner.SubAgent.Signature do
  @moduledoc """
  Signature parsing and validation for SubAgents.
  """

  @doc """
  Parse a signature string into internal format.
  """
  @spec parse(String.t()) :: {:ok, signature()} | {:error, term()}
  def parse(signature)

  @doc """
  Validate data against a signature.
  """
  @spec validate(signature(), term()) :: :ok | {:error, [validation_error()]}
  def validate(schema, data)

  @doc """
  Validate with coercion, returning coerced value.
  """
  @spec validate_and_coerce(signature(), term()) ::
    {:ok, term()} | {:error, [validation_error()]}
  def validate_and_coerce(schema, data)

  @doc """
  Render signature as string for prompts.
  """
  @spec render(signature()) :: String.t()
  def render(schema)
end
```

---

## Edge Cases

### Valid Edge Cases

| Signature | Valid? | Meaning |
|-----------|--------|---------|
| `":any"` | ✓ | Any output, no validation |
| `"() -> :any"` | ✓ | Same as above |
| `"{}"` | ✓ | Empty map (must be a map, but no required fields) |
| `"[]"` | ✗ | Invalid - list of what? Use `[:any]` |
| `"[:any]"` | ✓ | List of anything |
| `"[{}]"` | ✓ | List of empty maps |
| `""` | ✗ | Invalid - empty string is not a valid signature |

### Nesting Depth

There is no hard limit on nesting depth, but deeply nested types should be avoided for readability:

```
# Valid but not recommended
{user {profile {settings {theme {colors {primary :string}}}}}}

# Prefer flatter structures or use :map for deep nesting
{user {profile :map}}
```

### Placeholder Syntax

| Placeholder | Valid? | Notes |
|-------------|--------|-------|
| `{{name}}` | ✓ | Simple variable |
| `{{user.name}}` | ✓ | Nested access |
| `{{user.address.city}}` | ✓ | Deep nesting allowed |
| `{{user-name}}` | ✓ | Hyphens allowed in names |
| `{{user_name}}` | ✓ | Underscores allowed |
| `{{123}}` | ✗ | Names must start with letter |
| `{{}}` | ✗ | Empty placeholder invalid |
| `{{ name }}` | ✓ | Whitespace trimmed |
| `\{\{name\}\}` | N/A | No escape syntax - use different delimiter if needed |

### Type Coercion in Nested Structures

Coercion applies recursively to nested types:

```elixir
# Signature: [{id :int, name :string}]
# Input: [%{"id" => "42", "name" => "Alice"}]
# Result: [%{id: 42, name: "Alice"}] (with coercion warning for id)
```

---

## Future Considerations

### Enums (v2+)

If enum types are needed, extend the shorthand syntax:

```
(status :enum[pending active closed]) -> {ok :bool}
```

### Union Types (v2+)

If union types are needed:

```
(value :string|:int) -> {result :any}
```

### Refinements (v2+)

If value constraints are needed:

```
(page :int[>0], limit :int[1..100]) -> [{id :int}]
```

These extensions should be added only when genuine use cases emerge.

---

## Related Documents

- [specification.md](specification.md) - SubAgent API reference
- [guides/](guides/) - Usage guides and patterns
- [step.md](step.md) - Step struct specification
- [type-coercion-matrix.md](type-coercion-matrix.md) - Type mapping and coercion rules
