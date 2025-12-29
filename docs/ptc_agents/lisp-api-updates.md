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
7. [Language Extensions](#language-extensions)
8. [Migration Guide](#migration-guide)

---

## Summary

| Change | Impact | Description |
|--------|--------|-------------|
| Return `Step` struct | **Breaking** | Replace 4-tuple with struct |
| Error `Step` struct | **Breaking** | Replace 2-tuple with struct |
| Tool format expansion | Non-breaking | Accept function refs and signatures |
| Optional `:signature` | Non-breaking | Opt-in input/output validation |
| Expose metrics | Non-breaking | New `usage` field in Step |
| Language extensions | Non-breaking | New functions: `seq`, `#()`, string ops, `conj` |

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

## Language Extensions

New functions and syntax to align with LLM expectations and common Clojure patterns.

### Summary

| Category | Functions | Rationale |
|----------|-----------|-----------|
| Sequence | `seq` | Convert strings/collections to sequences |
| Syntax | `#()` | Anonymous function shorthand (LLMs generate this) |
| String | `str`, `subs`, `join`, `split`, `trim`, etc. | Basic string manipulation |
| Collection | `conj` | Add elements to collections |
| Parsing | `parse-long`, `parse-double` | Type coercion from strings |

---

### `seq` — Sequence Conversion

Convert strings and collections to sequences.

```clojure
(seq "hello")           ; => ["h" "e" "l" "l" "o"]
(seq [1 2 3])           ; => [1 2 3]
(seq #{:a :b})          ; => [:a :b] (order not guaranteed)
(seq {:a 1 :b 2})       ; => [[:a 1] [:b 2]]
(seq [])                ; => nil
(seq "")                ; => nil
(seq nil)               ; => nil
```

**Semantics:**
- Strings return list of single-character strings (graphemes)
- Empty collections and empty strings return `nil`
- `nil` returns `nil`
- Maps return list of `[key value]` pairs

**Use case:** Character iteration, emptiness checks via `(if (seq coll) ...)`.

---

### `#()` — Anonymous Function Shorthand

Clojure's compact syntax for anonymous functions.

```clojure
#(+ % 1)                ; => (fn [p1] (+ p1 1))
#(+ %1 %2)              ; => (fn [p1 p2] (+ p1 p2))
#(* % %)                ; => (fn [p1] (* p1 p1))
```

**Placeholder symbols:**

| Symbol | Meaning |
|--------|---------|
| `%` | First argument (same as `%1`) |
| `%1` | First argument |
| `%2` | Second argument |
| `%3` | Third argument |
| ... | Up to `%9` |

**Examples:**

```clojure
(filter #(> % 10) [5 15 8 20])           ; => [15 20]
(map #(str "id-" %) [1 2 3])             ; => ["id-1" "id-2" "id-3"]
(reduce #(+ %1 %2) 0 [1 2 3])            ; => 6
(count (filter #(= % "r") (seq "raspberry")))  ; => 3
```

**Implementation notes:**
- Parser recognizes `#(` as distinct from `#{` (set literal)
- `%` symbols are only valid inside `#()` body
- Desugars to `fn` at analysis time
- Max arity determined by highest `%n` in body

---

### String Functions

Basic string operations. Previously excluded ("use tools"), now included due to LLM demand.

#### `str` — String Concatenation

```clojure
(str)                   ; => ""
(str "hello")           ; => "hello"
(str "a" "b" "c")       ; => "abc"
(str "count: " 42)      ; => "count: 42"
(str nil)               ; => ""
(str "x" nil "y")       ; => "xy"
```

**Semantics:**
- Variadic: accepts 0 or more arguments
- Converts all arguments to strings
- `nil` converts to empty string (not `"nil"`)
- Numbers, keywords, booleans converted to their string representation

#### `subs` — Substring

```clojure
(subs "hello" 1)        ; => "ello"
(subs "hello" 1 3)      ; => "el"
(subs "hello" 0 0)      ; => ""
```

**Semantics:**
- `(subs s start)` — from start to end
- `(subs s start end)` — from start to end (exclusive)
- Zero-indexed
- Out of bounds returns truncated result (no error)

#### `join` — Join Collection

```clojure
(join ["a" "b" "c"])           ; => "abc"
(join ", " ["a" "b" "c"])      ; => "a, b, c"
(join "-" [1 2 3])             ; => "1-2-3"
(join ", " [])                 ; => ""
```

**Semantics:**
- `(join coll)` — concatenate without separator
- `(join sep coll)` — concatenate with separator
- Elements converted to strings

#### `split` — Split String

```clojure
(split "a,b,c" ",")            ; => ["a" "b" "c"]
(split "hello" "")             ; => ["h" "e" "l" "l" "o"]
(split "a,,b" ",")             ; => ["a" "" "b"]
```

**Semantics:**
- Simple string delimiter (no regex)
- Empty delimiter splits into characters
- Empty segments preserved

#### `trim` — Trim Whitespace

```clojure
(trim "  hello  ")      ; => "hello"
(trim "\n\t text \r\n") ; => "text"
(trim "no-space")       ; => "no-space"
```

#### `upper-case` / `lower-case` — Case Conversion

```clojure
(upper-case "Hello")    ; => "HELLO"
(lower-case "Hello")    ; => "hello"
```

#### `starts-with?` / `ends-with?` — Prefix/Suffix Check

```clojure
(starts-with? "hello" "he")    ; => true
(starts-with? "hello" "lo")    ; => false
(ends-with? "hello" "lo")      ; => true
(ends-with? "hello" "he")      ; => false
```

#### `includes?` — Substring Check

```clojure
(includes? "hello world" "wor")  ; => true
(includes? "hello" "xyz")        ; => false
```

**Note:** This is also available via `(where :field includes value)` in predicates.

#### `replace` — String Replace

```clojure
(replace "hello" "l" "L")        ; => "heLLo" (all occurrences)
(replace "aaa" "a" "b")          ; => "bbb"
```

**Semantics:**
- Replaces all occurrences (not just first)
- Simple string matching (no regex)

---

### `conj` — Add to Collection

Add elements to collections.

```clojure
(conj [1 2] 3)          ; => [1 2 3]
(conj [1 2] 3 4)        ; => [1 2 3 4]
(conj #{1 2} 3)         ; => #{1 2 3}
(conj {:a 1} [:b 2])    ; => {:a 1 :b 2}
(conj nil 1)            ; => [1]
```

**Semantics:**
- Vectors: adds to end
- Sets: adds element
- Maps: adds `[key value]` pair
- `nil`: creates new vector

---

### `parse-long` / `parse-double` — String to Number

Parse strings to numbers (Clojure 1.11+ functions).

```clojure
(parse-long "42")       ; => 42
(parse-long "-17")      ; => -17
(parse-long "abc")      ; => nil
(parse-long nil)        ; => nil
(parse-long "3.14")     ; => nil (not an integer)

(parse-double "3.14")   ; => 3.14
(parse-double "-0.5")   ; => -0.5
(parse-double "42")     ; => 42.0
(parse-double "abc")    ; => nil
```

**Semantics:**
- Returns `nil` on parse failure (not an error)
- `parse-long` requires integer format
- `parse-double` accepts integer or float format
- Leading/trailing whitespace NOT trimmed (returns `nil`)

---

### Implementation Order

1. **`seq`** — Runtime function only
2. **`#()` syntax** — Parser + analyzer changes
3. **String functions** — Runtime functions
4. **`conj`** — Runtime function
5. **`parse-long`, `parse-double`** — Runtime functions

### Complexity Estimates

| Function | Parser | Analyzer | Runtime | Est. Time |
|----------|--------|----------|---------|-----------|
| `seq` | - | - | ✓ | 30 min |
| `#()` | ✓ | ✓ | - | 2-4 hours |
| `str` | - | - | ✓ | 20 min |
| `subs` | - | - | ✓ | 15 min |
| `join` | - | - | ✓ | 15 min |
| `split` | - | - | ✓ | 15 min |
| `trim` | - | - | ✓ | 10 min |
| `upper/lower-case` | - | - | ✓ | 10 min |
| `starts/ends-with?` | - | - | ✓ | 10 min |
| `includes?` | - | - | ✓ | 10 min |
| `replace` | - | - | ✓ | 15 min |
| `conj` | - | - | ✓ | 20 min |
| `parse-long/double` | - | - | ✓ | 20 min |

**Total: ~5-7 hours**

---

### Spec Updates Required

After implementation, update `docs/ptc-lisp-specification.md`:

1. **Section 3.4** — Remove "strings are opaque" language
2. **Section 8** — Add new String Functions subsection
3. **Section 13.3** — Remove string functions from "excluded" list
4. **Add `seq`** to Section 8.1 (Collection Operations)
5. **Add `conj`** to Section 8.1
6. **Add `#()`** to Section 13.2 as now supported

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

### Phase 1: API Changes

1. **Create `PtcRunner.Step` struct** - Foundation
2. **Create `PtcRunner.Tool` struct** - Normalize tool definitions
3. **Update `PtcRunner.Lisp.run/2`** - Return Step, expose metrics
4. **Add signature parser** - Shared with SubAgent
5. **Add `:signature` option** - Input/output validation

### Phase 2: Language Extensions

6. **Add `seq`** - Runtime function
7. **Add `#()` syntax** - Parser and analyzer
8. **Add string functions** - `str`, `subs`, `join`, `split`, `trim`, `upper/lower-case`, `starts/ends-with?`, `includes?`, `replace`
9. **Add `conj`** - Runtime function
10. **Add `parse-long`, `parse-double`** - Runtime functions
11. **Update `ptc-lisp-specification.md`** - Document new functions

---

## Decisions

1. **No backward compatibility wrapper** - Breaking changes acceptable per 0.x policy.

2. **Signature validates both inputs and outputs** - Lisp programs have inputs via `:context`, so full signature makes sense.

3. **Same validation engine** - Shared between Lisp and SubAgent.

4. **Memory naming unchanged** - Already uses `memory/` prefix and `:memory` option.

---

## Related Documents

- [step.md](step.md) - Step struct specification
- [specification.md](specification.md) - SubAgent API
- [signature-syntax.md](signature-syntax.md) - Signature syntax specification
