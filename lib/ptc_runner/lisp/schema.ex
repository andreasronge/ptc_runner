defmodule PtcRunner.Lisp.Schema do
  @moduledoc """
  Schema and prompt generation for PTC-Lisp.

  Provides the language reference prompt for LLM code generation.
  This module is the **single source of truth** for the PTC-Lisp LLM prompt.
  """

  @doc """
  Returns the PTC-Lisp language reference prompt for LLM code generation.

  This is the **single source of truth** for the PTC-Lisp language reference.
  All documentation and tools should use this API rather than duplicating the content.

  The prompt contains:
  - Data types (nil, booleans, numbers, strings, keywords, vectors, maps)
  - Accessing data (ctx/, memory/)
  - Special forms (let, if, when, cond, fn)
  - Threading macros (->, ->>)
  - Predicate builders (where, all-of, any-of, none-of)
  - Core functions (filter, map, sort-by, count, sum-by, etc.)
  - Tool calls
  - Memory result contract
  - Common mistakes to avoid

  ## Example

      iex> prompt = PtcRunner.Lisp.Schema.to_prompt()
      iex> String.contains?(prompt, "PTC-Lisp")
      true

  ## Usage in LLM System Prompt

      system_prompt = \"\"\"
      You are a data analyst. Query data using PTC-Lisp programs.

      Available datasets: ctx/users, ctx/orders

      \#{PtcRunner.Lisp.Schema.to_prompt()}
      \"\"\"
  """
  @spec to_prompt() :: String.t()
  def to_prompt do
    """
    ### Language Overview

    **PTC-Lisp** is a minimal Clojure subset for data transformation. Programs are **single expressions**.

    ### Data Types
    ```clojure
    nil true false        ; nil and booleans
    42 3.14               ; numbers
    "hello"               ; strings
    :keyword              ; keywords (NO namespaced keywords like :foo/bar)
    [1 2 3]               ; vectors (NO lists '(1 2 3))
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
    (let [{:keys [a b]} m] body)       ; map destructuring (ONLY in let, NOT in fn params)
    (if cond then else)                ; conditional (else is REQUIRED)
    (when cond body)                   ; single-branch returns nil if false
    (cond c1 r1 c2 r2 :else default)   ; multi-way conditional
    (fn [x] body)                      ; anonymous function (simple params only, no destructuring)
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
    ; Example: (map (fn [entry] {:cat (first entry) :avg (avg-by :amount (last entry))}) grouped)

    ; Ordering
    (sort-by :key coll)  (sort-by :key > coll)  ; > for descending

    ; Subsetting
    (first coll)  (last coll)  (take n coll)  (drop n coll)  (nth coll i)

    ; Aggregation
    (count coll)  (sum-by :key coll)  (avg-by :key coll)
    (min-by :key coll)  (max-by :key coll)  (group-by :key coll)

    ; Maps
    (get m :key)  (get-in m [:a :b])  (assoc m :k v)  (merge m1 m2)
    (select-keys m [:a :b])  (keys m)  (vals m)
    (:key m)  (:key m default)  ; keyword as function
    ```

    ### Tool Calls
    ```clojure
    (call "tool-name")                 ; no arguments
    (call "tool-name" {:arg1 value})   ; with arguments map
    ; tool name MUST be a string literal
    ; WRONG: (call tool-name {...})    ; symbol not allowed
    ; WRONG: (call :tool-name {...})   ; keyword not allowed
    ```

    ### Memory Result Contract

    The return value determines memory behavior:

    | Return | Effect |
    |--------|--------|
    | Non-map (number, vector, etc.) | No memory update, value returned |
    | Map without `:result` | Merge into memory, map returned |
    | Map with `:result` | Merge rest into memory, `:result` value returned |

    ```clojure
    ; Pure query - no memory change
    (->> ctx/items (filter (where :active)) (count))

    ; Update memory only
    {:cached-users (call "get-users" {})}

    ; Update memory AND return different value
    {:cached-users users
     :result (pluck :email users)}
    ```

    ### Common Mistakes

    | Wrong | Right |
    |-------|-------|
    | `(where :status "active")` | `(where :status = "active")` |
    | `(where :active true)` | `(where :active)` (preferred) or `(where :active = true)` |
    | `(and (where :a = 1) (where :b = 2))` | `(all-of (where :a = 1) (where :b = 2))` |
    | `(fn [{:keys [a b]}] ...)` | `(fn [m] (let [{:keys [a b]} m] ...))` |
    | `(<= 100 x 500)` | `(and (>= x 100) (<= x 500))` |
    | `(ctx :input)` | `ctx/input` |
    | `(call :get-users {})` | `(call "get-users" {})` |
    | `(if cond then)` | `(if cond then nil)` or `(when cond then)` |
    | `'(1 2 3)` | `[1 2 3]` |
    | `:foo/bar` | `:foo-bar` (no namespaced keywords) |

    **Key constraints:**
    - `where` predicates MUST have an operator (except for truthy check)
    - Destructuring is ONLY allowed in `let`, NOT in `fn` params
    - Comparisons are strictly 2-arity: use `(and (>= x 100) (<= x 500))` NOT `(<= 100 x 500)`
    """
    |> String.trim()
  end
end
