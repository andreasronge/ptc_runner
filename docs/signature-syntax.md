# Signature reference

> **Audience:** application and PTC-Lisp authors declaring compact input and
> output contracts for components and model-visible tools.

Signatures tell a model what a function accepts and returns, and let PtcRunner
validate both sides of the call. They are compact enough to include in model
context while remaining readable in application source.

## Shape

An input-and-output signature uses an arrow:

```text
(query :string, limit :int) -> {count :int, items [{id :int}]}
```

Output-only signatures omit the empty input list:

```text
{name :string, price :float}
```

This is equivalent to:

```text
() -> {name :string, price :float}
```

## Primitive types

| Type | Accepts |
| --- | --- |
| `:string` | UTF-8 strings |
| `:int` | integers |
| `:float` | finite floating-point values and integers |
| `:bool` | `true` or `false` |
| `:keyword` | PTC-Lisp keywords |
| `:datetime` | a runtime datetime value supplied by the runtime or host |
| `:map` | a map with unrestricted string-like keys and values |
| `:any` | any public PTC-Lisp value |

There are no `:list`, `:array`, `:tuple`, or `:object` primitive names. Use a
collection or typed map instead.

## Collections and maps

A vector containing one type describes a list:

```text
[:int]
[:string]
[{id :int, name :string}]
```

A map describes required named fields:

```text
{id :int, name :string}
{customer {id :int, name :string}}
```

Use `:map` only when the keys cannot be declared in advance. Typed maps give
models better guidance and produce more precise validation feedback.

## Optional values

Append `?` to allow `nil`. For a typed map field, the suffix also permits the
field to be absent:

```text
{id :int, email :string?}
(cursor :string?) -> {items [:any], next_cursor :string?}
```

## Named parameters

Inputs are comma-separated named parameters:

```text
(user {id :int, name :string}, limit :int) -> [{order_id :int}]
```

Names document the call, appear in model-visible schemas, and can be referenced
by prompt templates. A duplicate or malformed name is rejected when the
component contract is compiled.

## Field naming

Signatures use underscore-separated public field names because tool arguments
and results cross a JSON-shaped boundary:

```text
(user_id :int) -> {order_count :int, is_active :bool}
```

PTC-Lisp code may use idiomatic hyphenated keywords:

```clojure
(return {:order-count 5 :is-active true})
```

At the public boundary, `:order-count` corresponds to `"order_count"`.
Normalization applies recursively to typed tool arguments and results. Prefer
one spelling within a map; do not rely on collisions between already-normalized
keys.

## Validation

Inputs are validated before the function or capability runs. Outputs are
validated before the value crosses its declared boundary. A failure returns a
bounded structured evaluation error that identifies the contract path without
calling the rejected capability again.

Validation is strict except for these admitted representations:

- an integer satisfies `:float` without changing its value;
- JSON-shaped string keys may match declared public fields;
- missing or `nil` values satisfy an optional type.

A numeric string does not satisfy `:int` or `:float`. A timestamp without an
offset does not satisfy `:datetime`, and neither does an ISO 8601 string: the
value must already be the runtime's datetime value. Signature maps validate
their declared fields and allow additional fields. A closed map created from a
JSON Schema with `additionalProperties: false` rejects unknown fields instead.

## Tool contracts

Model-visible functions should use named inputs and bounded outputs:

```text
(path :string, cursor :string?) -> {
  items [:string],
  next_cursor :string?,
  snapshot_hash :string
}
```

The corresponding PTC-Lisp wrapper can call a granted capability and return
only the declared shape:

```clojure
(defn read-page
  {:signature "(path :string, cursor :string?) -> :any"}
  [path cursor]
  (tool/workspace.read
    (if cursor {"path" path "cursor" cursor} {"path" path})))
```

A signature documents and validates a capability; it does not grant one. The
operator must still install the tool and the application must select it for the
mission.

## Prompt schemas

PtcRunner projects signatures into the model-visible tool schema. The schema
contains the parameter names, nested collection and map shapes, required and
optional fields, and descriptions supplied by the component. Runtime validation
remains authoritative even when a provider performs its own structured-output
validation.

Keep contracts small enough that a model can act on the feedback:

- page large collections instead of returning an unbounded list;
- use explicit nested fields instead of `:any` where the shape is stable;
- describe units and bounds in the function documentation; and
- return an opaque cursor rather than exposing provider state.

## Grammar summary

```text
signature     = output | "(" [parameters] ")" "->" output
parameters    = parameter {"," parameter}
parameter     = name type
type          = primitive ["?"] | list ["?"] | map ["?"]
primitive     = ":string" | ":int" | ":float" | ":bool"
              | ":keyword" | ":datetime" | ":map" | ":any"
list          = "[" type "]"
map           = "{" [field {"," field}] "}"
field         = name type
```

Nesting is bounded by the signature parser and the runtime's public-value
limits. Empty typed maps and lists are valid. Future-looking enum, union, or
refinement syntax is not part of the current grammar.

See [Components and preludes](reference/component-contracts.md) for where
contracts live, the [PTC-Lisp specification](ptc-lisp-specification.md) for
public component semantics, and the [function reference](function-reference.md)
for the shipped callable surface.
