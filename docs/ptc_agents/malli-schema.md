# Malli-lite Schema System

**Status:** Planned
**Scope:** `PtcRunner.SubAgent` signature validation

This document specifies the schema validation system for PtcRunner SubAgents, based on a subset of [Malli](https://github.com/metosin/malli) (the dominant Clojure data validation library).

## Overview

PtcRunner uses a **hybrid approach** for type signatures:

1. **Shorthand Syntax** (API layer) - Compact, LLM-friendly string format
2. **Malli-subset Data** (Internal layer) - Clojure-style schema vectors

The shorthand is transpiled to Malli data at registration time. Advanced users can provide Malli schemas directly.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Schema Flow                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Developer writes:                                               │
│    signature: "(query :string, limit :int) -> {count :int}"     │
│                           │                                      │
│                           ▼                                      │
│  Parser transpiles to Malli-subset:                             │
│    %{                                                           │
│      params: [:cat [:string] [:int]],                           │
│      returns: [:map [:count :int]]                              │
│    }                                                            │
│                           │                                      │
│                           ▼                                      │
│  Validator uses Malli data for:                                 │
│    - Input validation (tool calls)                              │
│    - Output validation (return data)                            │
│    - Schema generation (LLM prompts)                            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Design Rationale

### Why Malli?

| Consideration | Decision |
|---------------|----------|
| **Ecosystem fit** | PTC-Lisp is Clojure-like; Malli is the dominant Clojure validation library |
| **Schema-as-data** | Malli schemas are vectors/maps - native PTC-Lisp data structures |
| **Expressiveness** | Supports enums, unions, refinements that shorthand can't express cleanly |
| **Runtime manipulation** | Agents can programmatically construct schemas |
| **LLM training data** | Malli syntax is well-represented in Clojure training corpora |

### Why Keep Shorthand?

| Consideration | Decision |
|---------------|----------|
| **Token efficiency** | `{count :int}` vs `[:map [:count :int]]` - 50% fewer tokens |
| **Readability** | Arrow syntax `->` is intuitive for function signatures |
| **90% use case** | Most signatures are simple maps/lists; shorthand covers these well |
| **Lower barrier** | Developers don't need to learn Malli for basic usage |

### The Hybrid Approach

```elixir
# Option 1: Shorthand (recommended for most cases)
signature: "(query :string) -> {count :int, items [{id :int}]}"

# Option 2: Raw Malli (for advanced schemas)
signature: [:=> [:cat :string] [:map
  [:count :int]
  [:items [:vector [:map [:id :int]]]]
]]

# Option 3: Malli with features shorthand can't express
signature: [:=> [:cat :string] [:map
  [:status [:enum "pending" "active" "closed"]]
  [:score [:and :int [:> 0] [:< 100]]]
]]
```

---

## Supported Malli Subset

PtcRunner implements a pragmatic subset of Malli focused on JSON-compatible data validation.

### Primitive Types

| Malli Type | Description | Example Values |
|------------|-------------|----------------|
| `:string` | UTF-8 string | `"hello"`, `""` |
| `:int` | Integer | `42`, `-1`, `0` |
| `:double` | Floating point | `3.14`, `-0.5` |
| `:boolean` | Boolean | `true`, `false` |
| `:keyword` | Keyword/atom | `:pending`, `:active` |
| `:any` | Any value | Matches everything |
| `:nil` | Nil/null | `nil` only |

### Collection Types

| Malli Type | Description | Example |
|------------|-------------|---------|
| `[:vector <type>]` | Homogeneous list | `[:vector :int]` |
| `[:sequential <type>]` | Any sequence | `[:sequential :string]` |
| `[:set <type>]` | Unique values | `[:set :keyword]` |
| `[:map <entries>]` | Typed map (standardizes on keywords) | `[:map [:id :int]]` |
| `[:map-of <k> <v>]` | Dynamic keys | `[:map-of :string :int]` |
| `[:tuple <types>]` | Fixed-size heterogeneous list | `[:tuple :string :int]` |

### Map Entry Options

```clojure
;; Required field (default)
[:map [:id :int]]

;; Optional & Nullable field (shorthand :type?)
;; Note: In PtcRunner, optionality and nullability are treated as one for LLM simplicity.
[:map [:email {:optional true} [:maybe :string]]]

;; Field with default (provided if key is missing or nil)
[:map [:count {:default 0} :int]]
```

### Map Key Standardization

Internally, Malli schemas standardize on **keywords** for map keys. However, the validator is designed to be lenient:
- **Input data** can use string keys (e.g., from JSON), which are validated against keyword specs.
- **PTC-Lisp** access remains consistent whether the underlying data had string or keyword keys.

### Composite Types

| Malli Type | Description | Example |
|------------|-------------|---------|
| `[:enum <vals>]` | Enumerated values | `[:enum "low" "medium" "high"]` |
| `[:or <types>]` | Union type | `[:or :string :int]` |
| `[:and <types>]` | Intersection | `[:and :int [:> 0]]` |
| `[:maybe <type>]` | Nullable | `[:maybe :string]` |
| `[:cat <types>]` | Positional tuple | `[:cat :string :int]` |

### Function Signatures

```clojure
;; Function: string -> int
[:=> [:cat :string] :int]

;; Function: (string, int) -> map
[:=> [:cat :string :int] [:map [:result :boolean]]]

;; Zero-argument function
[:=> [:cat] [:map [:timestamp :string]]]
```

### Refinement Predicates

| Predicate | Description | Example |
|-----------|-------------|---------|
| `[:> n]` | Greater than | `[:and :int [:> 0]]` |
| `[:< n]` | Less than | `[:and :int [:< 100]]` |
| `[:>= n]` | Greater or equal | `[:and :int [:>= 1]]` |
| `[:<= n]` | Less or equal | `[:and :int [:<= 10]]` |
| `[:re <pattern>]` | Regex match | `[:and :string [:re "^[A-Z]"]]` |

---

## Not Supported (v1)

The following Malli features are **not** implemented in v1:

| Feature | Reason |
|---------|--------|
| Recursive schemas | Complexity; rare in tool signatures |
| Schema references (`[:ref]`) | Requires registry management |
| Multi-schemas | Out of scope |
| Coercion transformers | Use explicit type conversion in PTC-Lisp |
| Custom validators | Use refinement predicates instead |
| Generator/sampling | Not needed for validation |

---

## Shorthand to Malli Transpilation

The shorthand parser converts string signatures to Malli data.

### Syntax Reference

```
Shorthand                          Malli Equivalent
─────────────────────────────────────────────────────────────────
:string                            :string
:int                               :int
:float                             :double
:bool                              :boolean
:keyword                           :keyword
:any                               :any

[:int]                             [:vector :int]
[:string]                          [:vector :string]
[{:id :int}]                       [:vector [:map [:id :int]]]

{:id :int :name :string}           [:map [:id :int] [:name :string]]
:map                               [:map-of :keyword :any]

:string?                           [:maybe :string]
{:id :int :email :string?}         [:map [:id :int]
                                         [:email {:optional true} [:maybe :string]]]

(a :int, b :string) -> :bool       [:=> [:cat :int :string] :boolean]
() -> {:count :int}                [:=> [:cat] [:map [:count :int]]]
```

### Examples

```elixir
# Simple function signature
"(query :string) -> {count :int}"
# =>
[:=> [:cat :string] [:map [:count :int]]]

# Multiple parameters with nested return
"(user_id :int, limit :int) -> {items [{:id :int :name :string}]}"
# =>
[:=>
  [:cat :int :int]
  [:map [:items [:vector [:map [:id :int] [:name :string]]]]]]

# Optional return field
"() -> {data :map, error :string?}"
# =>
[:=>
  [:cat]
  [:map [:data [:map-of :keyword :any]]
        [:error {:optional true} :string]]]
```

---

## API Usage

### Using Shorthand (Recommended)

```elixir
# In delegate/2
{:ok, step} = PtcRunner.SubAgent.delegate(
  "Find customers matching criteria",
  signature: "(query :string, limit :int) -> {count :int, _ids [:int]}",
  llm: llm,
  tools: tools
)

# In as_tool/1
email_tool = PtcRunner.SubAgent.as_tool(
  prompt: "Find emails matching: {{query}}",
  signature: "(query :string) -> {count :int, _email_ids [:int]}",
  llm: llm,
  tools: email_tools
)

# Shorthand without inputs (return-only)
signature: "{summary :string, count :int}"
# Equivalent to:
signature: "() -> {summary :string, count :int}"
```

### Using Malli Directly

```elixir
# For schemas shorthand can't express
{:ok, step} = PtcRunner.SubAgent.delegate(
  "Classify the priority",
  signature: [:=>
    [:cat :string]
    [:map
      [:priority [:enum "low" "medium" "high" "critical"]]
      [:confidence [:and :double [:>= 0.0] [:<= 1.0]]]
    ]
  ],
  llm: llm,
  tools: tools
)

# Union types
signature: [:=> [:cat :string] [:or :int :nil]]

# Constrained integers
signature: [:=> [:cat] [:map [:page [:and :int [:> 0]]]]]
```

### Programmatic Schema Construction

In PTC-Lisp, agents can construct schemas dynamically:

```clojure
;; Build schema from context
(let [fields ctx/required_fields
      schema [:map (mapv (fn [f] [f :string]) fields)]]
  (call "validate" {:schema schema :data ctx/input}))
```

---

## Validation Behavior

### Input Validation

When a tool is called, inputs are validated against the signature's parameter types:

```elixir
# Signature: "(id :int, name :string) -> :bool"
# Tool call: (call "check" {:id "42" :name "Alice"})

# Behavior:
# 1. Coerce "42" -> 42 (string to int, with warning)
# 2. Validate "Alice" is string ✓
# 3. Proceed with call
```

### Output Validation

When `return` is called, data is validated against the signature's return type:

```elixir
# Signature: "() -> {:count :int :items [:string]}"
# Return call: (call "return" {:count 5 :items ["a" "b"]})

# Behavior:
# 1. Validate count is int ✓
# 2. Validate items is vector of strings ✓
# 3. Mission succeeds

# If validation fails:
# Return call: (call "return" {:count "five" :items ["a" "b"]})
# Error fed back to LLM: "count: expected int, got string \"five\""
# LLM can self-correct
```

### Validation Modes

```elixir
PtcRunner.SubAgent.delegate(prompt,
  signature: sig,
  signature_validation: :enabled  # default
)
```

| Mode | Behavior |
|------|----------|
| `:enabled` | Validate, fail on errors, allow extra fields (default) |
| `:warn_only` | Validate, log warnings, continue execution |
| `:disabled` | Skip all validation |
| `:strict` | Validate, fail on errors, reject extra fields |

### Coercion Rules

Lenient coercion for inputs (LLMs sometimes quote numbers):

| From | To | Example |
|------|----|---------|
| `"42"` | `:int` | `42` (with warning) |
| `"3.14"` | `:double` | `3.14` (with warning) |
| `"true"` | `:boolean` | `true` (with warning) |
| `42` | `:double` | `42.0` (silent) |

Output validation is **strict** - no coercion applied.

---

## Error Messages

Validation errors include paths for precise debugging:

```
Tool validation errors:
- results[0].customer.id: expected int, got string "abc"
- results[2].amount: expected double, got nil
- status: expected one of ["pending", "active"], got "unknown"

Tool validation warnings:
- limit: coerced string "10" to int
```

Errors are fed back to the LLM for self-correction. This does **not** consume the retry budget (see [specification.md](specification.md#llm-retry-scope)).

---

## Schema Generation for Prompts

Tool schemas are rendered in the LLM prompt using a human-readable format:

```
## Tools you can call

search(query :string, limit :int) -> [{id :int, title :string}]
  Search for items matching query.

classify(text :string) -> {category :enum["spam" "ham"], confidence :float}
  Classify text into categories.

get_user(id :int) -> {name :string, email :string?}
  Fetch user by ID. Email may be null.
```

For complex Malli schemas that can't be rendered as shorthand, a structured format is used:

```
validate(data :map, schema :malli-schema) -> {valid :bool, errors [:string]}
  Validate data against a Malli schema.
  Schema format: [:map [:field :type] ...]
```

---

## Implementation Modules

```
lib/ptc_runner/sub_agent/
├── schema.ex              # Core Malli-subset validator
├── schema/
│   ├── parser.ex          # Shorthand -> Malli transpiler
│   ├── validator.ex       # Validation logic
│   ├── coercion.ex        # Type coercion rules
│   ├── renderer.ex        # Schema -> prompt string
│   └── errors.ex          # Path-based error formatting
└── signature.ex           # Public API (parse, validate, render)
```

### Core Functions

```elixir
defmodule PtcRunner.SubAgent.Schema do
  @moduledoc """
  Malli-subset schema validation for SubAgent signatures.
  """

  @doc """
  Parse a signature (shorthand string or Malli data) into internal format.
  """
  @spec parse(String.t() | list()) :: {:ok, schema()} | {:error, term()}
  def parse(signature)

  @doc """
  Validate data against a schema.
  """
  @spec validate(schema(), term()) :: :ok | {:error, [validation_error()]}
  def validate(schema, data)

  @doc """
  Validate with coercion, returning coerced value.
  """
  @spec validate_and_coerce(schema(), term()) ::
    {:ok, term()} | {:error, [validation_error()]}
  def validate_and_coerce(schema, data)

  @doc """
  Render schema as human-readable string for prompts.
  """
  @spec render(schema()) :: String.t()
  def render(schema)
end
```

---

## Migration from Current Syntax

The current shorthand syntax is **unchanged** for basic types. The main additions are:

1. **Malli data as alternative input** - Power users can bypass shorthand
2. **New types via Malli** - Enums, unions, refinements
3. **Internal representation change** - Transparent to users

### No Breaking Changes

Existing signatures continue to work:

```elixir
# These all work identically before and after
signature: "(id :int) -> {name :string}"
signature: "() -> {count :int, items [:map]}"
signature: "{summary :string}"  # Shorthand for () -> {...}
```

---

## Related Documents

- [specification.md](specification.md) - Full SubAgent API specification
- [step.md](step.md) - Shared Step struct specification
- [lisp-api-updates.md](lisp-api-updates.md) - Changes to Lisp API
- [tutorial.md](tutorial.md) - SubAgent usage examples

---

## Future Considerations

### Recursive Schemas (v2+)

For tree structures, recursive schemas may be needed:

```clojure
;; Not supported in v1
[:schema {:registry {::node [:map
                              [:value :any]
                              [:children [:vector [:ref ::node]]]]}}
  ::node]
```

### Schema Inference

Automatically infer schemas from example data:

```elixir
# Future API
schema = PtcRunner.Schema.infer([
  %{id: 1, name: "Alice"},
  %{id: 2, name: "Bob"}
])
# => [:vector [:map [:id :int] [:name :string]]]
```

### Custom Validators

User-defined validation functions:

```elixir
# Future API
PtcRunner.Schema.register(:email, fn value ->
  String.match?(value, ~r/@/)
end)

signature: "() -> {contact :email}"
```
