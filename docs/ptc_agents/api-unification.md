# API Unification Plan

**Status:** Planned
**Scope:** `PtcRunner.Lisp` and `PtcRunner.SubAgent` APIs

This document outlines planned changes to unify the APIs between the existing `PtcRunner.Lisp` module and the planned `PtcRunner.SubAgent` module.

## Goals

1. **Consistent return types** - Both APIs return the same struct
2. **Shared conventions** - Memory naming, tool format, error structure
3. **Forward compatibility** - Lisp API accepts SubAgent-style tool definitions
4. **Feature parity** - Output validation available in both APIs

---

## 1. Shared `PtcRunner.Step` Struct

### Current State

**Lisp** returns a 4-tuple:
```elixir
{:ok, result, memory_delta, new_memory} | {:error, {type, message}}
```

**SubAgent** (planned) returns a struct:
```elixir
{:ok, %Step{return: data, ...}} | {:error, %Step{fail: error, ...}}
```

### Planned Change

Introduce a shared `PtcRunner.Step` struct that both APIs return:

```elixir
defmodule PtcRunner.Step do
  @moduledoc """
  Result of executing a PTC program or SubAgent mission.

  Returned by both `PtcRunner.Lisp.run/2` and `PtcRunner.SubAgent.delegate/2`.
  """

  defstruct [
    :return,        # The computed result value
    :memory,        # Final memory state
    :memory_delta,  # Keys that changed (Lisp only)
    :fail,          # Error info if failed
    :signature,     # Contract used (SubAgent only)
    :usage,         # Execution metrics
    :trace          # Execution trace (SubAgent only)
  ]

  @type t :: %__MODULE__{
    return: term() | nil,
    memory: map(),
    memory_delta: map() | nil,
    fail: fail() | nil,
    signature: String.t() | nil,
    usage: usage(),
    trace: list() | nil
  }

  @type fail :: %{
    reason: atom(),
    message: String.t(),
    op: String.t() | nil,
    details: map() | nil
  }

  @type usage :: %{
    duration_ms: non_neg_integer(),
    memory_bytes: non_neg_integer(),
    input_tokens: non_neg_integer() | nil,
    output_tokens: non_neg_integer() | nil,
    total_tokens: non_neg_integer() | nil,
    requests: non_neg_integer() | nil
  }
end
```

### Migration

**Before:**
```elixir
{:ok, result, delta, memory} = PtcRunner.Lisp.run(source, opts)
IO.puts(result)
```

**After:**
```elixir
{:ok, step} = PtcRunner.Lisp.run(source, opts)
IO.puts(step.return)
IO.inspect(step.memory_delta)
IO.inspect(step.usage.duration_ms)
```

### Benefits

- Pattern match on struct fields instead of tuple positions
- Easy to add fields without breaking existing code
- Metrics (duration, memory) now exposed
- Consistent error handling between APIs

---

## 2. Standardize Memory Naming

### Current State

| API | Lisp prefix | Option key | Struct field |
|-----|-------------|------------|--------------|
| Lisp | `memory/` | `:memory` | N/A (tuple) |
| SubAgent (tutorial) | `mem/` | N/A | `:mem` |

### Decision

**Standardize on `memory/` prefix and `:memory` field.**

Rationale:
- Already established in Lisp
- More explicit than abbreviated `mem/`
- Consistent with `ctx/` (not `c/`)

### Planned Change

Update SubAgent tutorial/spec to use:
- `memory/key` prefix in PTC-Lisp (not `mem/`)
- `:memory` field in Step struct (not `:mem`)
- `memory/put` and `memory/get` functions (not `mem/put`)

---

## 3. Unified Tool Registration Format

### Current State

**Lisp** accepts only simple functions:
```elixir
tools = %{
  "get-user" => fn args -> MyApp.get_user(args["id"]) end
}
```

**SubAgent** (planned) accepts multiple formats:
```elixir
tools = %{
  "get-user" => &MyApp.get_user/1,                    # Auto-extract @spec
  "search" => {&MyApp.search/2, "(q :string) -> ..."}, # Explicit spec
  "classify" => %{prompt: "...", signature: "..."}     # LLMTool
}
```

### Planned Change

Lisp accepts the same formats (excluding LLMTool):

```elixir
# All valid for PtcRunner.Lisp.run/2:
tools = %{
  # Simple function (existing, still works)
  "get-time" => fn _args -> DateTime.utc_now() end,

  # Function reference (auto-extract @spec if available)
  "get-user" => &MyApp.get_user/1,

  # Function with explicit signature (for validation)
  "search" => {&MyApp.search/2, "(query :string, limit :int) -> [{id :int}]"},

  # Skip validation explicitly
  "dynamic" => {&MyApp.dynamic/1, :skip}
}
```

### Internal Normalization

All formats normalize to a `PtcRunner.Tool` struct:

```elixir
defmodule PtcRunner.Tool do
  defstruct [:name, :function, :signature, :type]

  @type t :: %__MODULE__{
    name: String.t(),
    function: (map() -> term()),
    signature: String.t() | nil,
    type: :native | :llm | :subagent
  }
end
```

For Lisp, only `:native` type is supported. SubAgent extends this with `:llm` and `:subagent` types.

### Benefits

- Forward-compatible: upgrade tools to have specs without changing call sites
- Shared validation logic between APIs
- Tool definitions are portable between Lisp and SubAgent

---

## 4. Expose Usage Metrics

### Current State

Lisp sandbox returns metrics but `run/2` discards them:
```elixir
# Sandbox returns:
{:ok, value, %{duration_ms: 42, memory_bytes: 1024}, memory}

# run/2 returns (metrics lost):
{:ok, value, delta, memory}
```

### Planned Change

Include metrics in Step struct:

```elixir
%PtcRunner.Step{
  return: value,
  memory: memory,
  usage: %{
    duration_ms: 42,
    memory_bytes: 1024,
    # SubAgent adds these:
    input_tokens: nil,
    output_tokens: nil,
    requests: nil
  }
}
```

---

## 5. Consistent Error Structure

### Current State

**Lisp:**
```elixir
{:error, {:timeout, 1000}}
{:error, {:parse_error, "unexpected token"}}
```

**SubAgent (planned):**
```elixir
{:error, %Step{fail: %{reason: :not_found, message: "User 123 does not exist"}}}
```

### Planned Change

Both APIs return `{:error, %Step{}}` with populated `fail` field:

```elixir
# Lisp timeout:
{:error, %PtcRunner.Step{
  fail: %{reason: :timeout, message: "execution exceeded 1000ms limit"},
  usage: %{duration_ms: 1000, ...}
}}

# Lisp parse error:
{:error, %PtcRunner.Step{
  fail: %{reason: :parse_error, message: "unexpected token at line 3"},
  usage: nil
}}

# SubAgent mission failure:
{:error, %PtcRunner.Step{
  fail: %{reason: :not_found, message: "User 123 does not exist"},
  trace: [...],
  usage: %{...}
}}
```

### Error Reasons

| Reason | Source | Description |
|--------|--------|-------------|
| `:parse_error` | Lisp | Invalid PTC-Lisp syntax |
| `:analysis_error` | Lisp | Semantic error (undefined variable, etc.) |
| `:eval_error` | Lisp | Runtime error (division by zero, etc.) |
| `:timeout` | Both | Execution exceeded time limit |
| `:memory_exceeded` | Both | Process exceeded heap limit |
| `:validation_error` | Both | Input or output doesn't match signature |
| `:tool_error` | SubAgent | Tool raised an exception |
| `:tool_not_found` | SubAgent | Calling non-existent tool |
| `:reserved_tool_name` | SubAgent | Attempted to register `return` or `fail` |
| `:max_turns_exceeded` | SubAgent | Turn limit reached without termination |
| `:max_depth_exceeded` | SubAgent | Nested agent depth limit exceeded |
| `:turn_budget_exhausted` | SubAgent | Total turn budget exhausted across mission tree |
| `:mission_timeout` | SubAgent | Total mission duration exceeded |
| `:llm_error` | SubAgent | LLM callback failed after all retries |
| `:model_not_found` | SubAgent | LLM registry lookup failed for atom reference |
| `:chained_failure` | SubAgent | Attempted to chain onto a failed step |
| `:template_error` | SubAgent | Template placeholder missing from context |
| Custom atoms | SubAgent | From `(call "fail" {:reason :custom ...})` |

> **Note:** The `:signature_mismatch` alias was removed in favor of the canonical `:validation_error`.

---

## 6. Optional Signature Validation for Lisp

### Current State

SubAgent validates inputs and return data against signature:
```elixir
PtcRunner.SubAgent.delegate(prompt,
  signature: "(user_id :int) -> {name :string, price :float}",
  ...
)
```

Lisp has no equivalent.

### Planned Change

Add optional `:signature` option to validate context inputs and result output:

```elixir
{:ok, step} = PtcRunner.Lisp.run(
  "(call \"get-user-orders\" {:id ctx/user_id :limit ctx/limit})",
  context: %{user_id: 123, limit: 10},
  tools: order_tools,
  signature: "(user_id :int, limit :int) -> {name :string, orders [:map]}"
)

step.return  #=> %{name: "Alice", orders: [%{...}, ...]}
```

This validates both:
- **Inputs**: context contains `user_id` (int) and `limit` (int)
- **Outputs**: result is a map with `name` (string) and `orders` (list of maps)

If validation fails:
```elixir
# Input validation failure:
{:error, %PtcRunner.Step{
  fail: %{
    reason: :validation_error,
    message: "user_id: expected int, got string \"abc\""
  }
}}

# Output validation failure:
{:error, %PtcRunner.Step{
  fail: %{
    reason: :validation_error,
    message: "orders[0].id: expected int, got nil"
  }
}}
```

### Signature Syntax

PtcRunner uses a **hybrid schema system** based on Malli. See [malli-schema.md](malli-schema.md) for the full specification.

**Shorthand Syntax (recommended):**

```
Primitives:
  :string :int :float :bool :keyword :any

Lists (homogeneous collections):
  [:int]                          ; list of integers
  [:string]                       ; list of strings
  [{:id :int :name :string}]      ; list of maps

Maps (typed fields):
  {:id :int :name :string}        ; map with required fields
  :map                            ; any map (untyped)

Optional Fields (use ? suffix):
  {:id :int :email :string?}      ; email is optional (nil allowed)
  {:count :int :items [:string]?} ; items list is optional

Nested Structures:
  {:user {:id :int :profile {:bio :string}}}
```

**Important:** The `[:type]` syntax always means "list of type". For optional fields, use the `?` suffix on the type name.

**Malli Data (advanced):**

For schemas that shorthand can't express, use Malli vectors directly:

```elixir
# Enum types
signature: [:=> [:cat :int] [:map [:status [:enum "pending" "active"]]]]

# Union types
signature: [:=> [:cat :string] [:or :int :nil]]

# Constrained values
signature: [:=> [:cat] [:map [:score [:and :int [:> 0]]]]]
```

The shorthand is transpiled to Malli data internally. Both formats use the same validation engine shared between Lisp and SubAgent.

### Validation Options

Control validation behavior via `:signature_validation` option:

```elixir
PtcRunner.Lisp.run(source,
  signature: "(id :int) -> {result :map}",
  signature_validation: :enabled  # default
)
```

| Option | Behavior |
|--------|----------|
| `:enabled` | Validate inputs and outputs, fail on errors (default) |
| `:warn_only` | Validate, log warnings but continue execution |
| `:disabled` | Skip all validation |
| `:strict` | Like `:enabled`, plus: fail if any tool lacks a spec, or if context is missing required signature keys |

**Strictness for extra fields:**
- `:enabled` mode allows extra fields in return data (lenient)
- `:strict` mode rejects extra fields not in signature

### Implementation

1. Parse signature string into schema AST (shared with SubAgent)
2. Before evaluation, validate context against input schema
3. After evaluation, validate result against output schema
4. Return validation error if mismatch

Validation logic is shared between Lisp and SubAgent.

---

## 7. Context Option Naming

### Current State

Lisp uses `:context` option:
```elixir
PtcRunner.Lisp.run(source, context: %{user_id: 123})
```

SubAgent tutorial uses `:context` as well (good).

### Decision

Keep `:context` for both APIs. No change needed.

Access in PTC-Lisp via `ctx/` prefix:
```clojure
(call "get-user" {:id ctx/user_id})
```

---

## Summary: Breaking Changes

| Change | Lisp Impact | Migration |
|--------|-------------|-----------|
| Return type → Step struct | **Breaking** | Destructure step instead of tuple |
| Error type → Step struct | **Breaking** | Access `step.fail` instead of tuple |
| Memory prefix standardization | None (already `memory/`) | N/A |
| Tool format expansion | Non-breaking | Existing functions still work |
| Expose usage metrics | Non-breaking | New field available |
| Optional `:signature` validation | Non-breaking | Opt-in feature |

---

## Implementation Order

1. **Create `PtcRunner.Step` struct** - Foundation for other changes
2. **Create `PtcRunner.Tool` struct** - Normalize tool definitions
3. **Update `PtcRunner.Lisp.run/2`** - Return Step, expose metrics
4. **Add signature parser** - Shared validation logic
5. **Add `:signature` option to Lisp** - Input/output validation
6. **Implement SubAgent** - Uses same Step and Tool structs

---

## Decisions Made

1. **No backward compatibility wrapper** - Breaking changes are acceptable per version 0.x policy.

2. **Use `:signature` for both APIs** - Lisp programs have inputs via `:context`, so full signature `"(inputs) -> outputs"` makes sense. Validates both context inputs and result outputs.

3. **Tool validation in both APIs** - When tool specs are provided, validate inputs/outputs in both Lisp and SubAgent. Same validation options available: `:enabled`, `:warn_only`, `:disabled`, `:strict`.

4. **Optional field syntax (`?` suffix)** - The `[:type]` syntax is reserved for lists. Optional fields use `:type?` suffix to avoid ambiguity. See [specification.md](specification.md#dd-1-optional-field-syntax--suffix) for rationale.

5. **Removed `:signature_mismatch` alias** - Single canonical error reason `:validation_error` for all type mismatches. Reduces confusion.

6. **Added `total_tokens` to usage** - Convenience field computed as `input_tokens + output_tokens`. Matches common LLM API patterns.

7. **Malli-based schema system** - Use Malli-subset as internal schema representation. Shorthand strings are transpiled to Malli data. See [malli-schema.md](malli-schema.md) for details.

---

## Related Documents

- [malli-schema.md](malli-schema.md) - Malli-lite schema system specification
- [specification.md](specification.md) - Full SubAgent API specification
- [tutorial.md](tutorial.md) - SubAgent usage examples
- [spike-summary.md](spike-summary.md) - Spike validation results
