# Signature Syntax

Signatures define the contract between agents and tools - what inputs they accept and what outputs they produce.

## Overview

```elixir
signature: "(query :string, limit :int) -> {count :int, items [{id :int}]}"
```

Signatures are:
- **Token-efficient** - Compact syntax optimized for LLM prompts
- **Human-readable** - Intuitive arrow notation for function contracts
- **Validated at runtime** - Inputs and outputs are checked against the signature

---

## Basic Structure

```
(inputs) -> output
```

Or for output-only signatures (common for top-level agents):

```
output
```

These are equivalent:
```elixir
signature: "() -> {name :string, price :float}"
signature: "{name :string, price :float}"
```

---

## Primitive Types

| Type | Description | Example Values |
|------|-------------|----------------|
| `:string` | UTF-8 string | `"hello"`, `""` |
| `:int` | Integer | `42`, `-1`, `0` |
| `:float` | Floating point | `3.14`, `-0.5` |
| `:bool` | Boolean | `true`, `false` |
| `:keyword` | Keyword/atom | `:pending`, `:active` |
| `:any` | Any value | Matches everything |

### Invalid Type Names (Common Mistakes)

These guessed type names **do not exist**:

| Guessed | What to Use Instead |
|---------|---------------------|
| `:list` | `[:type]` - e.g., `[:int]`, `[:string]`, `[:any]` |
| `:array` | `[:type]` - same as above |
| `:tuple` | No direct equivalent - use `{field :type}` maps with named fields |
| `:object` | `{field :type}` or `:map` |

> **Note:** PTC-Lisp signatures don't have true tuples (ordered, position-based). Use maps with named fields instead, which provide better self-documentation and validation.

Example fix:
```elixir
# WRONG - :list is not a valid type
signature: "(items :list) -> :bool"

# CORRECT - use [:type] syntax
signature: "(items [:any]) -> :bool"
signature: "(items [:string]) -> :bool"
```

---

## Collection Types

### Lists

```
[:int]                         ; List of integers
[:string]                      ; List of strings
[:map]                         ; List of maps
[{id :int, name :string}]      ; List of typed maps
```

### Maps with Typed Fields

```
{id :int, name :string}
{customer {id :int, name :string}}    ; Nested
:map                                   ; Any map (dynamic keys)
```

---

## Optional Fields

Use `?` suffix for optional (nullable) fields:

```
{id :int, email :string?}
```

The field can be `nil` or omitted entirely.

---

## Named Parameters

Input parameters have names that become available in the signature:

```elixir
signature: "(user {id :int, name :string}, limit :int) -> [{order_id :int}]"
```

Multiple parameters are comma-separated. The names `user` and `limit`:
- Document what each parameter represents
- Are validated against template placeholders in prompts
- Appear in tool schemas shown to LLMs

---

## Naming Convention: Underscores in Signatures

**Signatures use underscores** (Elixir/JSON convention):

```elixir
signature: "(user_id :int) -> {order_count :int, is_active :bool}"
```

**PTC-Lisp code uses hyphens** (Clojure convention):

```clojure
(return {:order-count 5 :is-active true})
```

At the tool boundary, `KeyNormalizer` automatically converts hyphens to underscores:

| PTC-Lisp (LLM writes) | Elixir receives | Signature field |
|-----------------------|-----------------|-----------------|
| `:order-count` | `"order_count"` | `order_count` |
| `:is-active` | `"is_active"` | `is_active` |
| `:user-id` | `"user_id"` | `user_id` |

This allows LLMs to write idiomatic Clojure-style code while Elixir tools receive idiomatic underscore-style keys.

**Why this matters:**
- LLMs trained on Clojure naturally produce hyphenated keywords
- Elixir/JSON conventions use underscores
- Signatures define the Elixir-side contract, so they use underscores
- The conversion is automatic and transparent

---

## Firewalled Fields

Prefix with `_` to hide from LLM prompts:

```elixir
signature: "{summary :string, count :int, _email_ids [:int]}"
```

Firewalled fields:
- **Available** in Lisp context (`data/_email_ids`)
- **Available** to Elixir code (`step.return["_email_ids"]`)
- **Hidden** from LLM prompt text (shown as `<Firewalled>`)
- **Hidden** from parent LLM when agent is used as tool

This protects LLM context windows while preserving data flow.

---

## Examples

### Simple Output

```elixir
signature: "{answer :int}"
# LLM must return: {:answer 42}
```

### Multiple Fields

```elixir
signature: "{name :string, price :float, in_stock :bool}"
# LLM must return: {:name "Widget" :price 99.99 :in_stock true}
```

### List Output

```elixir
signature: "[{id :int, title :string}]"
# LLM must return: [{:id 1 :title "First"} {:id 2 :title "Second"}]
```

### With Inputs

```elixir
signature: "(user_id :int) -> {name :string, orders [:map]}"
# Called as: (tool/agent {:user_id 123})
# Returns: {:name "Alice" :orders [...]}
```

### Complex Nested

```elixir
signature: """
(query :string, options {limit :int?, sort :string?}) ->
{results [{id :int, score :float, metadata :map}], total :int}
"""
```

### Firewalled Data

```elixir
signature: "{summary :string, _raw_data [:map]}"
# Parent sees: {summary :string}
# Elixir gets: %{summary: "...", _raw_data: [...]}
```

---

## Validation Behavior

### Input Validation

When a tool is called, inputs are validated against signature parameters:

```elixir
# Signature: (id :int, name :string) -> :bool
# Tool call: (tool/check {:id "42" :name "Alice"})

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

## String Keys at Tool Boundary

**Important:** When tools receive arguments from LLM-generated code, all map keys are **strings**, not atoms. This matches JSON conventions and prevents atom memory leaks.

```elixir
# WRONG - pattern matching on atom keys will NOT work
def search(%{query: query, limit: limit}) do
  # ...
end

# CORRECT - use string keys
def search(%{"query" => query, "limit" => limit}) do
  # ...
end
```

### Why String Keys?

1. **JSON compatibility** - JSON only has string keys; atom keys don't survive serialization
2. **Memory safety** - LLM-generated atoms could exhaust the atom table
3. **Consistency** - Same convention as Phoenix params from HTTP requests

### Nested Maps

String keys apply **recursively** to all nested maps:

```elixir
# Given signature: (user {profile {name :string}}) -> :bool

# Tool receives this structure:
%{
  "user" => %{
    "profile" => %{
      "name" => "Alice"
    }
  }
}

# NOT this:
%{user: %{profile: %{name: "Alice"}}}  # WRONG - atoms
```

### Key Normalization

Hyphens in keys are automatically converted to underscores at the boundary:

```elixir
# LLM sends: {:user-name "Alice" :created-at "2024-01-01"}
# Tool receives: %{"user_name" => "Alice", "created_at" => "2024-01-01"}
```

This allows idiomatic Lisp (kebab-case) while providing idiomatic Elixir (snake_case).

---

## Type Mapping from @spec

When auto-extracting from Elixir specs:

| Elixir Type | Maps To |
|-------------|---------|
| `String.t()` | `:string` |
| `integer()` | `:int` |
| `float()` | `:float` |
| `boolean()` | `:bool` |
| `atom()` | `:keyword` |
| `map()` | `:map` |
| `list(t)` | `[:t]` |
| `%{key: type}` | `{:key :type}` |

Types that require explicit signatures:
- `pid()`, `reference()` - No JSON equivalent
- Complex unions - `{:ok, t} | {:error, term}`
- Custom `@type` definitions

---

## Template Placeholders

Every `{{placeholder}}` in a prompt must match a signature input:

```elixir
prompt: "Find emails for {{user.name}} about {{topic}}"
signature: "(user {name :string}, topic :string) -> {count :int}"
```

Validation happens at registration time, not runtime.

| Placeholder | Valid? | Notes |
|-------------|--------|-------|
| `{{name}}` | Yes | Simple variable |
| `{{user.name}}` | Yes | Nested access |
| `{{user.address.city}}` | Yes | Deep nesting allowed |
| `{{user-name}}` | Yes | Hyphens allowed in names |
| `{{user_name}}` | Yes | Underscores allowed |
| `{{123}}` | No | Names must start with letter |
| `{{}}` | No | Empty placeholder invalid |
| `{{ name }}` | Yes | Whitespace trimmed |

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

## Edge Cases

### Valid Edge Cases

| Signature | Valid? | Meaning |
|-----------|--------|---------|
| `":any"` | Yes | Any output, no validation |
| `"() -> :any"` | Yes | Same as above |
| `"{}"` | Yes | Empty map (must be a map, but no required fields) |
| `"[]"` | No | Invalid - list of what? Use `[:any]` |
| `"[:any]"` | Yes | List of anything |
| `"[{}]"` | Yes | List of empty maps |
| `""` | No | Invalid - empty string is not a valid signature |

### Nesting Depth

There is no hard limit on nesting depth, but deeply nested types should be avoided for readability:

```
# Valid but not recommended
{user {profile {settings {theme {colors {primary :string}}}}}}

# Prefer flatter structures or use :map for deep nesting
{user {profile :map}}
```

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

## See Also

- [Core Concepts](guides/subagent-concepts.md) - How signatures interact with context
- [Getting Started](guides/subagent-getting-started.md) - Using signatures in your first agent
- [Patterns](guides/subagent-patterns.md) - Chaining agents using signatures
- `PtcRunner.SubAgent` - API reference
