# PTC-Lisp LLM Guide

This document provides a compact language reference for LLMs generating PTC-Lisp programs, plus execution API documentation.

For the complete language specification, see [ptc-lisp-specification.md](ptc-lisp-specification.md).

---

## Running PTC-Lisp Programs

### API Overview

```elixir
# Run a PTC-Lisp program
{:ok, result, memory_delta, new_memory} = PtcRunner.Lisp.run(source, opts)

# Run with context and tools
{:ok, result, memory_delta, new_memory} = PtcRunner.Lisp.run(source,
  context: %{input: data, user_id: "user-123"},
  memory: %{cached_users: previous_users},
  tools: %{
    "get-users" => &MyApp.get_users/1,
    "get-orders" => &MyApp.get_orders/1
  },
  timeout: 5000,
  max_heap: 1_250_000
)

# Handle errors with LLM-friendly messages
case PtcRunner.Lisp.run(source, opts) do
  {:ok, result, memory_delta, new_memory} ->
    handle_success(result, memory_delta, new_memory)
  {:error, error} ->
    # Format error for LLM feedback
    PtcRunner.Json.format_error(error)
end
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:context` | map | `%{}` | Request context, accessible via `ctx/` |
| `:memory` | map | `%{}` | Persistent memory, accessible via `memory/` |
| `:tools` | map | `%{}` | Tool functions (arity 1, receives args map) |
| `:timeout` | integer | 5000 | Execution timeout in milliseconds |
| `:max_heap` | integer | 1_250_000 | Max heap size in words (~10MB) |

### Return Values

**Success (core API):**
```elixir
{:ok, result, memory_delta, new_memory}
```

| Field | Description |
|-------|-------------|
| `result` | The value returned to caller (extracted from `:result` key if present) |
| `memory_delta` | Map of keys that changed this turn |
| `new_memory` | Complete memory state after merge |

**Success (with metrics wrapper):**
```elixir
# Optional wrapper for agentic loops
{:ok, result, %{
  memory_delta: %{...},
  new_memory: %{...},
  duration_ms: 42,
  memory_bytes: 1024
}}
```

**Errors:**
```elixir
{:error, {:parse_error, "unexpected token at line 3"}}
{:error, {:validation_error, "unknown function: foo"}}
{:error, {:type_error, "expected number, got string"}}
{:error, {:execution_error, "tool 'get-users' failed: connection refused"}}
{:error, {:timeout, 5000}}
{:error, {:memory_exceeded, 10_000_000}}
```

### Memory Result Contract

The program's return value determines how memory is updated:

```elixir
# Program returns: 42 (non-map)
# → Memory unchanged, result = 42

# Program returns: %{users: [...], count: 5}
# → Memory merged with %{users: [...], count: 5}, result = same map

# Program returns: %{result: "done", users: [...]}
# → Memory merged with %{users: [...]}, result = "done"
```

### Registering Tools

Tools are single-arity functions that receive an arguments map:

```elixir
tools = %{
  "get-users" => fn args ->
    # args is a map, e.g., %{"department" => "engineering"}
    MyApp.Users.list(args)
  end,

  "search" => fn %{"query" => query, "limit" => limit} ->
    MyApp.Search.run(query, limit: limit)
  end
}
```

### Agentic Loop Example

```elixir
defmodule MyAgent do
  def run_loop(initial_memory, max_turns) do
    run_turn(initial_memory, 1, max_turns)
  end

  defp run_turn(memory, turn, max_turns) when turn > max_turns do
    {:ok, memory}
  end

  defp run_turn(memory, turn, max_turns) do
    # 1. Get program from LLM
    program = generate_program_from_llm(memory, turn)

    # 2. Execute program
    case PtcRunner.Lisp.run(program,
           memory: memory,
           context: %{turn: turn},
           tools: my_tools()
         ) do
      {:ok, result, _memory_delta, new_memory} ->
        # 3. Memory is already updated based on result contract

        if done?(result) do
          {:ok, new_memory}
        else
          run_turn(new_memory, turn + 1, max_turns)
        end

      {:error, error} ->
        # 4. Feed error back to LLM for retry
        error_msg = PtcRunner.Json.format_error(error)
        retry_with_error(memory, turn, max_turns, error_msg)
    end
  end

  defp apply_result_contract(memory, result) when not is_map(result), do: memory
  defp apply_result_contract(memory, result) do
    Map.merge(memory, Map.delete(result, :result))
  end
end
```

---

## PTC-Lisp Quick Reference (for LLM prompts)

The following section can be included in LLM system prompts to enable code generation.

**API Access:** Use `PtcRunner.Lisp.Schema.to_prompt()` to get this reference programmatically. This API is the single source of truth - do not copy/paste this section manually.

```elixir
# Get the LLM prompt reference
prompt = PtcRunner.Lisp.Schema.to_prompt()

# Use in your system prompt
system_prompt = """
You are a data analyst. Query data using PTC-Lisp programs.

Available datasets: ctx/users, ctx/orders

#{PtcRunner.Lisp.Schema.to_prompt()}
"""
```

<!-- PTC_PROMPT_START -->

### Language Overview

**PTC-Lisp** is a minimal Clojure subset for data transformation. Programs are **single expressions**.

### Data Types
```clojure
nil true false        ; nil and booleans
42 3.14               ; numbers
"hello"               ; strings
:keyword              ; keywords (NO namespaced keywords like :foo/bar)
[1 2 3]               ; vectors (NO lists '(1 2 3))
#{1 2 3}              ; sets (unordered, unique values)
{:a 1 :b 2}           ; maps
```

### Accessing Data
```clojure
ctx/input             ; read from request context
memory/results        ; read from persistent memory
; NOTE: ctx and memory are NOT accessible as whole maps, only via namespace prefix
```

### Special Forms
```clojure
(let [x 1, y 2] body)              ; local bindings
(let [{:keys [a b]} m] body)       ; map destructuring
(if cond then else)                ; conditional (else is REQUIRED)
(when cond body)                   ; single-branch returns nil if false
(cond c1 r1 c2 r2 :else default)   ; multi-way conditional
(fn [x] body)                      ; anonymous function with simple param
(fn [[a b]] body)                  ; vector destructuring in params
(fn [{:keys [x]}] body)            ; map destructuring in params
(< a b)                            ; comparisons are 2-arity ONLY, NOT (<= a b c)
```

### Threading (chained transformations)
```clojure
(->> coll (filter pred) (map f) (take 5))   ; thread-last
(-> m (assoc :a 1) (dissoc :b))             ; thread-first
```

### Predicate Builders
```clojure
(where :field = value)             ; MUST include operator
(where :field > 10)                ; operators: = not= > < >= <= includes in
(where [:nested :path] = value)    ; nested field access
(where :field)                     ; truthy check (not nil, not false)
(where :status in ["a" "b"])       ; membership test
```

**Prefer truthy checks for boolean flags:**
```clojure
; GOOD - concise, handles messy data (1, "yes", etc.)
(filter (where :active) users)
(filter (where :verified) accounts)

; AVOID - only needed when distinguishing true from other truthy values
(filter (where :active = true) users)
```

**Combining predicates — use `all-of`/`any-of`/`none-of`, NOT `and`/`or`:**
```clojure
; WRONG - and/or return values, not combined predicates
(filter (and (where :a = 1) (where :b = 2)) coll)   ; BUG!

; CORRECT - predicate combinators
(filter (all-of (where :a = 1) (where :b = 2)) coll)
(filter (any-of (where :x = 1) (where :y = 1)) coll)
(filter (none-of (where :deleted)) coll)
```

### Core Functions
```clojure
; Filtering
(filter pred coll)  (remove pred coll)  (find pred coll)

; Transforming
(map f coll)  (mapv f coll)  (pluck :key coll)
; map over a map: each entry is passed as [key value] vector
; Example: (map (fn [[key value]] {:cat key :avg (avg-by :amount value)}) grouped)

; Ordering
(sort-by :key coll)  (sort-by :key > coll)  ; > for descending

; Subsetting
(first coll)  (last coll)  (take n coll)  (drop n coll)  (nth coll i)

; Aggregation
(count coll)  (sum-by :key coll)  (avg-by :key coll)
(min-by :key coll)  (max-by :key coll)
(group-by :key coll)  ; returns {key => [items...]}, NOT counts!
; To count per group: (update-vals (group-by :key coll) count) - do NOT use ->>

; Maps
(get m :key)  (get-in m [:a :b])  (assoc m :k v)  (merge m1 m2)
(select-keys m [:a :b])  (keys m)  (vals m)
(:key m)  (:key m default)  ; keyword as function
(update-vals m f)  ; apply f to each value in map
(update-vals {:a 1 :b 2} inc)                        ; => {:a 2 :b 3}
(update-vals (group-by :region sales) count)         ; count per group
; IMPORTANT (update-vals m f) - map first, use -> not ->>
(-> (group-by :type records) (update-vals (fn [items] (sum-by :value items))))

; Sets
(set? x)               ; is x a set?
(set [1 2 2])          ; convert to set: #{1 2}
(contains? #{1 2} 1)   ; membership: true
(count #{1 2 3})       ; count: 3
(empty? #{})           ; empty check: true

; Note: map, filter, remove work on sets but return vectors
(map inc #{1 2})       ; returns vector: [2 3]
(filter odd? #{1 2 3}) ; returns vector: [1 3]
```

### Tool Calls
```clojure
(call "tool-name")                 ; no arguments
(call "tool-name" {:arg1 value})   ; with arguments map
; tool name MUST be a string literal
; WRONG: (call tool-name {...})    ; symbol not allowed
; WRONG: (call :tool-name {...})   ; keyword not allowed
```

### Memory: Persisting Data Between Turns

Use memory to store intermediate results and reference them in later programs.

**Reading from memory:**
```clojure
memory/results           ; access stored value by key
```

**Writing to memory:** Return a map to persist keys:

| Return | Effect |
|--------|--------|
| Non-map (number, vector, etc.) | No memory update, value returned |
| Map without `:result` | Merge into memory, map returned |
| Map with `:result` | Merge rest into memory, `:result` value returned |

**Multi-turn example:**
```clojure
; Turn 1: Store expensive computation
{:unique-users (->> ctx/events (pluck :user_id) (distinct))}

; Turn 2: Reference stored result
{:active-count (count memory/unique-users)
 :total-count (count ctx/sessions)
 :result (count memory/unique-users)}
```

**Other patterns:**
```clojure
; Pure query - no memory change
(->> ctx/items (filter (where :active)) (count))

; Store tool result for later use
{:cached-users (call "get-users" {})}
```

### Common Mistakes

| Wrong | Right |
|-------|-------|
| `(where :status "active")` | `(where :status = "active")` |
| `(where :active true)` | `(where :active)` (preferred) or `(where :active = true)` |
| `(and (where :a = 1) (where :b = 2))` | `(all-of (where :a = 1) (where :b = 2))` |
| `(<= 100 x 500)` | `(and (>= x 100) (<= x 500))` |
| `(ctx :input)` | `ctx/input` |
| `(call :get-users {})` | `(call "get-users" {})` |
| `(if cond then)` | `(if cond then nil)` or `(when cond then)` |
| `'(1 2 3)` | `[1 2 3]` |
| `:foo/bar` | `:foo-bar` (no namespaced keywords) |

**Key constraints:**
- `where` predicates MUST have an operator (except for truthy check)
- Comparisons are strictly 2-arity: use `(and (>= x 100) (<= x 500))` NOT `(<= 100 x 500)`

<!-- PTC_PROMPT_END -->

---

## Using the LLM Prompt

Use the official API to get the quick reference for your LLM prompts:

```elixir
# Recommended: Use the API (single source of truth)
prompt = PtcRunner.Lisp.Schema.to_prompt()

# Example system prompt for an LLM agent
system_prompt = """
You are an assistant that writes PTC-Lisp programs.

#{PtcRunner.Lisp.Schema.to_prompt()}
"""
```

The `PtcRunner.Lisp.Schema.to_prompt/0` function extracts the content between the `PTC_PROMPT_START` and `PTC_PROMPT_END` markers in this document at compile time, ensuring a single source of truth.
