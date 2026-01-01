# Signature Syntax

Signatures define the contract between agents - what inputs they accept and what outputs they produce. This guide covers the full syntax.

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

## Primitive Types

| Type | Description | Examples |
|------|-------------|----------|
| `:string` | Text | `"hello"` |
| `:int` | Integer | `42`, `-1` |
| `:float` | Decimal number | `3.14`, `-0.5` |
| `:bool` | Boolean | `true`, `false` |
| `:keyword` | Atom/keyword | `:active`, `:pending` |
| `:any` | Any type | No validation |
| `:map` | Any map | `%{...}` |

## Collections

### Lists

```
[:int]                    ; List of integers
[:string]                 ; List of strings
[:map]                    ; List of maps
[{:id :int :name :string}] ; List of typed maps
```

### Maps with Typed Fields

```
{:id :int :name :string}
{:customer {:id :int :name :string}}  ; Nested
```

## Optional Fields

Use `?` suffix for optional (nullable) fields:

```
{:id :int :email :string?}
```

The field can be `nil` or omitted entirely.

## Input Parameters

Named parameters with types:

```
(query :string, limit :int) -> [:map]
(user {name :string, email :string}) -> {id :int}
```

Multiple parameters are comma-separated.

## Firewalled Fields

Prefix with `_` to hide from LLM prompts:

```
{summary :string, count :int, _email_ids [:int]}
```

Firewalled fields are:
- ✓ Available in Lisp context (`ctx/_email_ids`)
- ✓ Available in Elixir (`step.return._email_ids`)
- ✗ Hidden in LLM conversation history
- ✗ Omitted from parent agent's view of tool schema

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
# Called as: (call "agent" {:user_id 123})
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

## Validation Behavior

### On `return`

When the agent calls `(return data)`:

1. Data is validated against the output signature
2. If invalid, error message is sent to LLM for retry
3. If valid, loop ends successfully

### On Tool Calls

When calling tools with signatures:

1. **Input validation** - Args checked before calling tool
2. **Coercion** - `"42"` coerced to `42` with warning
3. **Output validation** - Result checked after tool returns

### Error Messages

Validation errors show full paths:

```
Tool validation errors:
- results[0].customer.id: expected integer, got string "abc"
- results[2].amount: expected float, got nil
```

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

## Template Placeholders

Every `{{placeholder}}` in a prompt must match a signature input:

```elixir
prompt: "Find emails for {{user.name}} about {{topic}}"
signature: "(user {name :string}, topic :string) -> {count :int}"
```

Validation happens at registration time, not runtime.

## Further Reading

- [Core Concepts](core-concepts.md) - How signatures interact with context
- [Getting Started](getting-started.md) - Using signatures in your first agent
- [Patterns](patterns.md) - Chaining agents using signatures
- [Signatures Reference](../signature-syntax.md) - Full syntax specification
- [Specification](../specification.md) - SubAgent API reference
