# Signature Syntax (PTC-Lisp format)

Signatures define the machine-readable contract for agent outputs.

## Syntax Rules

- **Primitives**: `:string`, `:int`, `:float`, `:bool`, `:any`, `:map` (untyped map)
- **Collections**:
  - Lists: `[:type]` (e.g., `[:string]` is a list of strings)
  - Maps (Structured): `{field_name :type, other_field :type}`
- **Optional Fields**: Append `?` to the type (e.g., `:string?` means the field can be null/nil)
- **Complex Types**: `(params) -> output` (e.g., `(user_id :int) -> {name :string}`)
  - *Note: For task signatures, you usually just provide the output part (the map or list).*

## Examples

| Requirement | Signature |
|-------------|-----------|
| A list of stock objects | `[{symbol :string, price :float}]` |
| A flat search result | `{query :string, results [:string]}` |
| A simple success/fail object | `{success :bool, message :string?}` |
| A nested document | `{id :int, meta {author :string, tags [:string]}}` |

## When to use signatures

1. **Synthesis Gates**: ALWAYS. It ensures the gate produces a valid object for downstream tasks.
2. **Critical Tasks**: When you need to ensure the LLM returns exactly the right keys and types.
3. **Text Mode**: If a task has no tools, the signature forces the LLM to skip Lisp code generation and return JSON directly.
