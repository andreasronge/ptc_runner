# PTC-Lisp v2: Clojure-Idiomatic Namespace Model

**Status:** Proposal
**Author:** Discussion between Andreas & Claude
**Date:** 2025-01-04

---

## 1. Overview

This proposal redesigns PTC-Lisp's state management to be more Clojure-idiomatic, replacing the custom `memory/` namespace with standard Clojure forms (`def`, `defn`) while retaining the `ctx/` namespace for input data and tools.

### Motivation

The current `memory/key` syntax and implicit map-based storage, while functional, deviate from idiomatic Clojure patterns. This creates friction for developers familiar with Clojure and makes the REPL-like multi-turn experience less natural.

### Goals

1. **Clojure-idiomatic** — Use standard Clojure forms where possible
2. **REPL-like experience** — Multi-turn feels like a Clojure REPL session
3. **Clear semantics** — Explicit state management, no "magic"

### Non-Goals

- Full Clojure namespace system (require, refer, etc.)
- Atom semantics with STM guarantees
- Multiple user namespaces

---

## 2. Namespace Model

### 2.1 Two-Namespace Design

| Namespace | Provider | Mutability | Access Pattern |
|-----------|----------|------------|----------------|
| `ctx` | System | Read-only | `ctx/key`, `(ctx/tool args)` |
| User (implicit) | LLM | Read-write via `def`/`defn` | Direct symbols |

```
┌─────────────────────────────────────────────────────────┐
│                    PTC-Lisp Session                     │
├─────────────────────────────────────────────────────────┤
│  ctx namespace (system-provided, immutable)             │
│  ┌─────────────────────────────────────────────────┐   │
│  │ ;; Data                                          │   │
│  │ ctx/expenses    → [{:id 1 :amount 500} ...]     │   │
│  │ ctx/users       → [{:id 1 :name "Alice"} ...]   │   │
│  │                                                  │   │
│  │ ;; Tools (functions)                             │   │
│  │ (ctx/search query) → {:results [...] :cursor x} │   │
│  │ (ctx/fetch-user id) → {:id x :name "..."}       │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  user namespace (LLM workspace, persists across turns)  │
│  ┌─────────────────────────────────────────────────┐   │
│  │ (def results [...])     → results               │   │
│  │ (defn helper [x] ...)   → helper                │   │
│  │ (def count 42)          → count                 │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  REPL history (automatic, read-only)                    │
│  ┌─────────────────────────────────────────────────┐   │
│  │ *1 → most recent turn result                    │   │
│  │ *2 → two turns ago                              │   │
│  │ *3 → three turns ago                            │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 2.2 The `ctx` Namespace

The `ctx` namespace contains all input data and tools, presented to the LLM as a Clojure namespace declaration:

```clojure
(ns ctx)
;;; Data
;; expenses - vector of expense claim maps {:id :amount :category :user-id}
;; users - vector of user maps {:id :name :department}

;;; Tools
;; (search query) - search documents, returns {:results [...] :cursor "..."}
;; (fetch-user id) - fetch user by id, returns {:id :name :email}
```

**Access patterns:**

```clojure
;; Data access (namespace-qualified symbols)
ctx/expenses              ; → [{:id 1 :amount 500} ...]
ctx/users                 ; → [{:id 1 :name "Alice"} ...]

;; Tool invocation (namespace-qualified function call)
(ctx/search {:query "budget"})           ; → {:results [...] :cursor "abc"}
(ctx/fetch-user 123)                     ; → {:id 123 :name "Bob"}

;; Nested access
(:amount (first ctx/expenses))           ; → 500
(->> ctx/expenses (filter #(> (:amount %) 1000)))
```

**Key properties:**
- Read-only: LLM cannot modify `ctx/` bindings
- Immutable within session: same values across all turns
- Tools are functions: `(ctx/tool-name args)` not `(call "tool-name" args)`

### 2.3 The User Namespace

The user namespace is the LLM's workspace for defining values and functions that persist across turns.

```clojure
;; Define a value (persists across turns)
(def high-value-threshold 5000)

;; Define a function (persists across turns)
(defn suspicious? [expense]
  (> (:amount expense) high-value-threshold))

;; Use them
(filter suspicious? ctx/expenses)
```

**Key properties:**
- Mutable via `def`/`defn`: redefinition overwrites previous value
- Persists across turns: values survive turn boundaries
- No prefix needed: just use the symbol name directly
- Implicit namespace: no `(ns user)` declaration needed

### 2.4 REPL History (`*1`, `*2`, `*3`)

Unchanged from current implementation. Provides quick access to recent turn results:

```clojure
*1    ; result from previous turn (most recent)
*2    ; result from 2 turns ago
*3    ; result from 3 turns ago
```

**Properties:**
- Read-only, automatic
- Truncated to ~1KB per entry (configurable via `format_options`)
- Returns `nil` if turn doesn't exist
- Useful for quick inspection; use `def` for reliable persistence

**Important: Truncation behavior**

| What | Truncated? | Default | Purpose |
|------|------------|---------|---------|
| Turn feedback (user message) | Yes | 20 items, 2KB | LLM sees preview, not full data |
| `*1`/`*2`/`*3` (programmatic) | Yes | 1KB | Prevent memory bloat |
| `def` bindings | No | Full data | Explicit storage for processing |

The LLM sees a *preview* of the result. If it needs to *process* large data, it must explicitly store it:

```clojure
;; Turn 1: Store explicitly if you need to process later
(def results (ctx/search {:query "budget"}))

;; Turn 2: Use the stored value (full data)
(filter #(> (:amount %) 1000) results)

;; NOT: (filter ... *1) — *1 may be truncated!
```

The design forces explicit state management via `def` rather than relying on implicit history.

---

## 3. New Forms

### 3.1 `def` — Define a Value

Binds a name to a value in the user namespace. Persists across turns.

**Syntax:**
```clojure
(def name value)
(def name docstring value)  ; optional docstring (ignored but allowed)
```

**Examples:**
```clojure
;; Simple binding
(def threshold 5000)

;; Bind result of computation
(def high-expenses
  (filter #(> (:amount %) 5000) ctx/expenses))

;; Bind tool result
(def search-results
  (ctx/search {:query "Q4 budget"}))

;; Redefinition (overwrites)
(def results [1 2 3])       ; results = [1 2 3]
(def results (conj results 4))  ; results = [1 2 3 4]
```

**Semantics:**
- Returns the var (`#'name`), not the value (like Clojure)
- Creates or overwrites the binding
- Value is evaluated before binding
- Binding persists until session ends or redefined

**Differences from Clojure:**
- No `^:dynamic`, `^:private`, or other metadata
- No destructuring in def (use `let` then `def`)
- Docstrings allowed but ignored (for Clojure compatibility)

### 3.2 `defn` — Define a Function

Sugar for defining a named function. Equivalent to `(def name (fn ...))`.

**Syntax:**
```clojure
(defn name [params] body)
(defn name docstring [params] body)  ; optional docstring
```

**Examples:**
```clojure
;; Simple function
(defn double [x] (* x 2))

;; Multi-expression body (implicit do)
(defn process [item]
  (let [cleaned (dissoc item :internal)]
    (assoc cleaned :processed true)))

;; Using defined function
(map double [1 2 3])  ; → [2 4 6]

;; Function using ctx
(defn enrich-expense [expense]
  (let [user (ctx/fetch-user (:user-id expense))]
    (assoc expense :user-name (:name user))))
```

**Semantics:**
- Equivalent to `(def name (fn [params] body))`
- Function persists across turns
- Can reference other user-defined symbols
- Can access `ctx/` data and call `ctx/` tools

**Differences from Clojure:**
- No multi-arity: `(defn f ([x] ...) ([x y] ...))` not supported
- No pre/post conditions
- No destructuring in param list (use `let` inside body)
- No variadic args (`& rest`)

**Limitations (v1):**
- No closure capture: functions cannot close over `let`-bound variables
  - Can reference: parameters, user-ns symbols, `ctx/` values, builtins
  - Rationale: simplifies implementation, avoids serialization issues

---

## 4. Migration from Current System

### 4.1 Syntax Mapping

| Current (v1) | Proposed (v2) | Notes |
|--------------|---------------|-------|
| `memory/results` | `results` | After `(def results ...)` |
| `ctx/expenses` | `ctx/expenses` | Unchanged |
| `(call "search" args)` | `(ctx/search args)` | Tools are functions in ctx |
| `{:results [...]}` (implicit store) | `(def results [...])` | Explicit binding |
| `{:return value :key data}` | `(do (def key data) value)` | Explicit, return last expr |

### 4.2 Example Migration

**Current (v1):**
```clojure
;; Turn 1: Search and store
(call "search" {:query "topic"})
;; Returns {:results [...] :cursor "abc"} → stored in memory/results, memory/cursor

;; Turn 2: Fetch more, accumulate
{:all-results memory/results
 :next (call "search" {:cursor memory/cursor})}

;; Turn 3: Return combined
(return (concat memory/all-results (:results memory/next)))
```

**Proposed (v2):**
```clojure
;; Turn 1: Search and store explicitly
(def search-result (ctx/search {:query "topic"}))
;; Returns the search result; 'search-result' now available

;; Turn 2: Fetch more, store both
(def page1 (:results search-result))
(def page2 (ctx/search {:cursor (:cursor search-result)}))

;; Turn 3: Return combined
(return (concat page1 (:results page2)))
```

### 4.3 Return and Fail

The `return` and `fail` forms remain unchanged:

```clojure
;; Terminate with success
(return final-value)

;; Terminate with failure
(fail "reason for failure")
```

These are **not** in `ctx/` — they're special forms that terminate the agent loop.

---

## 5. Prompt Template

The system prompt presents the `ctx` namespace to the LLM using a consistent format for both data and tools.

```clojure
(ns ctx)

;;; Data

;; expenses : [{:id :int :amount :float :category :string :user-id :int}]
;;   Expense claims from the current quarter.
;; users : [{:id :int :name :string :department :string}]

;;; Tools

;; ctx/search : (query :string, limit :int) -> [{:id :int}]
;;   Search for items matching query.
;; ctx/fetch-user : (id :int) -> {:id :int :name :string :email :string}
;;   Fetch user details by ID.
```

### 5.1 Format Details

**Unified signature format** — both data and tools use the same type notation:

| Entry | Signature | Description |
|-------|-----------|-------------|
| Data | `{:id :int :name :string}` | Type of the value |
| Tool | `(id :int) -> {:id :int :name :string}` | Input params `->` return type |

**Display rules:**
1. Signatures are displayed **as-is** — no parsing or reformatting
2. Prepend `ctx/` to tool names (LLM calls `(ctx/search ...)`)
3. Descriptions are listed on the next line, indented with `;;   `
4. Description format is free-form text — no Clojure conventions required

```clojure
;; name : <signature>
;;   <description if present>
```

**Examples:**

```clojure
;;; Data

;; expenses : [{:id :int :amount :float :category :string}]
;;   Expense claims submitted this quarter.
;; config : {:threshold :int :enabled :bool}

;;; Tools

;; ctx/search : (query :string) -> [{:id :int :title :string}]
;;   Full-text search across all documents.
;; ctx/fetch-user : (id :int) -> {:name :string :email :string}
```

### 5.2 Comparison with Current Format

| Aspect | Current | Proposed |
|--------|---------|----------|
| Tool call | `(call "search" args)` | `(ctx/search args)` |
| Format | Markdown code blocks | Clojure comments |
| Signature | Reformatted | Shown as-is |

### 5.3 Descriptions for Data and Tools

Both data and tools can have descriptions via `field_descriptions`:

```elixir
SubAgent.new(
  prompt: "Double the number",
  signature: "(n :int) -> {result :int}",
  field_descriptions: %{
    n: "The number to double",
    result: "The doubled value"
  }
)
```

**Rendering:** Descriptions appear on the line after the signature:

```clojure
;;; Data

;; n : :int
;;   The number to double.

;;; Tools

;; ctx/search : (query :string) -> [{:id :int}]
;;   Full-text search across documents.
```

**Tool descriptions:** Tools have an overall `description` field. When a tool also has `field_descriptions`, the overall description is shown (not per-parameter docs):

```elixir
%Tool{
  signature: "(id :int) -> {:name :string}",
  description: "Fetch user by ID"
}
# Renders as:
# ;; ctx/fetch-user : (id :int) -> {:name :string}
# ;;   Fetch user by ID.
```

**CompiledAgent preservation:**

```elixir
%CompiledAgent{
  signature: "(n :int) -> {result :int}",
  field_descriptions: %{n: "Input number", result: "The doubled value"},
  ...
}
```

The `field_descriptions` must be preserved in CompiledAgent so descriptions flow correctly when:
1. CompiledAgent is chained with other agents
2. CompiledAgent is used as a tool (via `as_tool/1`)

**Chaining flow:**

When agents are chained, output descriptions from agent A become input descriptions for agent B:

```elixir
# Agent A defines output descriptions
agent_a = SubAgent.new(
  signature: "() -> {result :int}",
  field_descriptions: %{result: "The doubled value"},
  ...
)

# Agent B receives them as input descriptions automatically
agent_b = SubAgent.new(
  signature: "(result :int) -> {final :int}",
  ...
)

# When chained, agent B sees:
# ;; result : :int
# ;;   The doubled value.
```

**Implementation requirement:** The `Step` struct must carry `field_descriptions` so `then!/2` can propagate them:

```elixir
# Step struct needs field_descriptions
defstruct [:return, :memory, :traces, :field_descriptions, ...]

# then!/2 extracts output descriptions and passes as input descriptions
```

**Status:** Required for v1 — enables self-documenting chains.

### 5.4 Chaining Example

Two SubAgents chained together, showing what each LLM sees and generates:

**Elixir Setup:**
```elixir
# Agent A: Double a number
agent_a = SubAgent.new(
  prompt: "Double the input number",
  signature: "(n :int) -> {result :int}",
  field_descriptions: %{
    n: "The number to process",
    result: "The doubled value"
  },
  max_turns: 1
)

# Agent B: Add 10 to the result
agent_b = SubAgent.new(
  prompt: "Add 10 to the result",
  signature: "(result :int) -> {final :int}",
  field_descriptions: %{
    result: "Input from previous calculation",  # Could be auto-populated from agent_a
    final: "The final computed value"
  },
  max_turns: 1
)

# Chain execution
SubAgent.run!(agent_a, llm: llm, context: %{n: 5})
|> SubAgent.then!(agent_b, llm: llm)
```

---

**Agent A — LLM sees this prompt:**

```clojure
(ns ctx)

;;; Data

;; n : :int
;;   The number to process.

;;; Expected Output: {:result :int}
;;;   result: The doubled value
```

**Agent A — LLM generates:**

```clojure
{:result (* 2 ctx/n)}
```

**Agent A — Returns:** `{:result 10}`

---

**Agent B — LLM sees this prompt:**

```clojure
(ns ctx)

;;; Data

;; result : :int
;;   The doubled value.
;;   (Description flowed from agent_a's output)

;;; Expected Output: {:final :int}
;;;   final: The final computed value
```

Note: `result`'s description ("The doubled value") came from agent_a's `field_descriptions[:result]`.

**Agent B — LLM generates:**

```clojure
{:final (+ ctx/result 10)}
```

**Agent B — Returns:** `{:final 20}`

---

**Multi-turn Example with Tools:**

```elixir
# Agent with tools requiring explicit return
search_agent = SubAgent.new(
  prompt: "Find products under $50",
  signature: "() -> {products [{:id :int :name :string :price :float}], count :int}",
  tools: %{"search" => &Products.search/1},
  field_descriptions: %{
    products: "List of matching products",
    count: "Total number found"
  },
  max_turns: 3
)
```

**LLM sees:**

```clojure
(ns ctx)

;;; Data

;; (no input data for this agent)

;;; Tools

;; ctx/search : (query :map) -> [{:id :int :name :string :price :float}]
;;   Search product catalog.

;;; Expected Output: {:products [...] :count :int}
```

**LLM generates (turn 1):**

```clojure
(do
  (def results (ctx/search {:max_price 50}))
  (str "Found " (count results) " products"))
```

**Feedback:** `"Found 12 products"`

**LLM generates (turn 2):**

```clojure
(return {:products results :count (count results)})
```

**Returns:** `{:products [...12 items...], :count 12}`

### 5.5 Integration with SubAgent Signature

The SubAgent `signature` field already defines input/output types:

```elixir
SubAgent.new(
  prompt: "Double the number",
  signature: "(n :int) -> {result :int}",
  tools: %{"fetch" => &MyModule.fetch/1}
)
```

This generates a prompt with:

```clojure
(ns ctx)

;;; Data

;; n : :int
;; extra_data : {:map}

;;; Tools

;; ctx/fetch : (id :int) -> {:name :string :email :string}
;;   Fetch record by ID.

;;; Expected Output: {:result :int}
;;; Call (return {:result 42}) when complete.
```

**Implementation notes** (not shown to LLM):
- Signature input params (`n :int`) become `ctx/n` data entries
- Signature return type shown as "Expected Output"
- Tool signatures displayed as-is with `ctx/` prefix

### 5.6 Quick Reference (shown after namespace)

```clojure
;; Quick reference:
;; - Access data:     ctx/n, ctx/extra_data
;; - Call tools:      (ctx/fetch 123)
;; - Define values:   (def name value)
;; - Define helpers:  (defn name [args] body)
;; - Previous result: *1, *2, *3
;; - Finish:          (return {:result value})
```

### 5.7 SubAgent Description Field

SubAgents gain an optional `:description` field for external documentation:

| Field | Purpose | Audience |
|-------|---------|----------|
| `prompt` | Detailed instructions, templates | The agent itself |
| `description` | One-sentence summary | Parent agents, UIs, catalogs |
| `signature` | Input/output contract | Type validation |

**Example:**

```elixir
doubler = SubAgent.new(
  description: "Doubles a given number",
  prompt: "Multiply {{n}} by 2 and return the result",
  signature: "(n :int) -> {result :int}"
)

# Use as a tool in parent agent
parent = SubAgent.new(
  prompt: "Use the doubler tool to process the input",
  tools: %{"double" => SubAgent.as_tool(doubler)}
)
```

When a SubAgent is used as a tool via `as_tool/1`, the description flows into the `ctx/` namespace:

```clojure
;; ctx/double : (n :int) -> {result :int}
;;   Doubles a given number.
```

**Requirement**: `as_tool/1` requires `:description` to be set. This ensures all tools have proper documentation when presented to the LLM.

---

## 6. Complete Examples

### 6.1 Single-Turn Query

```clojure
;; Find total travel expenses over $1000
(->> ctx/expenses
     (filter #(and (= (:category %) "travel")
                   (> (:amount %) 1000)))
     (map :amount)
     (reduce +))
```

### 6.2 Multi-Turn with State

```clojure
;; Turn 1: Define helper and find suspicious expenses
(do
  (defn suspicious? [e]
    (and (> (:amount e) 5000)
         (= (:category e) "equipment")))
  (def suspects (filter suspicious? ctx/expenses))
  suspects)  ; return value to see results

;; Observation: [{:id 101 :amount 15000 :user-id 42} ...]

;; Turn 2: Enrich with user data
(do
  (defn enrich [expense]
    (assoc expense :user (ctx/fetch-user (:user-id expense))))
  (def enriched (map enrich suspects))
  enriched)

;; Observation: [{:id 101 :amount 15000 :user {:name "Bob"}} ...]

;; Turn 3: Return summary
(return
  (map #(select-keys % [:id :amount :user]) enriched))
```

### 6.3 Pagination with Accumulation

```clojure
;; Turn 1: Start search, evaluate to see result
(do
  (def page1 (ctx/search {:query "budget reports"}))
  page1)

;; Observation: {:results [{...} {...}] :cursor "abc123"}

;; Turn 2: Get next page, keep both
(do
  (def results-so-far (:results page1))
  (def page2 (ctx/search {:query "budget reports" :cursor (:cursor page1)}))
  page2)

;; Observation: {:results [{...}] :cursor "def456"}

;; Turn 3: Combine and return
(return (concat results-so-far (:results page2)))
```

### 6.4 Iterative Refinement

```clojure
;; Turn 1: Explore the data (no def needed, just evaluate)
(->> ctx/expenses
     (group-by :category)
     (map (fn [[cat items]]
            {:category cat
             :count (count items)
             :total (reduce + (map :amount items))})))

;; Observation: [{:category "travel" :count 45 :total 23000} ...]

;; Turn 2: Based on observation, equipment looks odd - define and evaluate
(do
  (def equipment-expenses
    (filter #(= (:category %) "equipment") ctx/expenses))
  equipment-expenses)

;; Observation: [{:id 5 :amount 15000 :user-id 42} {:id 8 :amount 12000 :user-id 42}]

;; Turn 3: Same user-id for both large equipment purchases
(return {:finding "User 42 has multiple large equipment purchases"
         :user-id 42
         :total (reduce + (map :amount equipment-expenses))})
```

---

## 7. Semantic Details

### 7.1 Evaluation Order

Each turn is a single expression. Use `do` for multiple sub-expressions:

```clojure
;; This works: a is defined before b uses it
(do
  (def a 1)
  (def b (+ a 1))
  b)  ; → 2

;; This fails: c not yet defined when d tries to use it
(do
  (def d (+ c 1))  ; Error: c is undefined
  (def c 1))
```

### 7.2 Redefinition Semantics

`def` always creates or overwrites. Across turns:

```clojure
;; Turn 1
(def x 1)    ; → #'x (x = 1)

;; Turn 2
(def x 2)    ; → #'x (x = 2, overwrites previous)

;; Turn 3
(def x (+ x 1))  ; → #'x (x = 3, uses current value then overwrites)
```

Within a single turn using `do`:

```clojure
(do
  (def x 1)
  (def x (+ x 1))
  x)  ; → 2 (last expression is the value, not the var)
```

### 7.3 Scope Rules

1. **Let-bound symbols** shadow everything within their lexical scope (including user-defined and builtins)
2. **User-defined symbols** (`def`) cannot shadow builtins
3. **`ctx/` prefix** always accesses context namespace (cannot be shadowed)

```clojure
;; Turn 1: Define x
(def x 10)  ; → #'x

;; Turn 2: Let shadows def within its scope
(let [x 20]
  x)        ; → 20 (let shadows def)

;; Turn 3: Outside let, def value is accessible
x           ; → 10

;; Let can shadow builtins (lexical scope only)
(let [map {:a 1}]
  (:a map))        ; → 1 (map is the local binding)

;; def cannot shadow builtins
(def map {:a 1})   ; Error: cannot shadow builtin 'map'

;; def can shadow ctx (but ctx/ still works)
(def expenses [])
expenses           ; → [] (user definition)
ctx/expenses       ; → original data
```

### 7.4 Turn Boundaries

- User-defined symbols persist across turns
- `*1`/`*2`/`*3` update automatically
- `ctx/` remains constant
- Evaluation restarts fresh (no continuation)

### 7.5 What `def` Returns

Like Clojure, `def` returns the var, not the value:

```clojure
;; Turn 1
(def x 42)  ; → #'x (the var)
;; *1 = #'x

;; Turn 2: Evaluate symbol to get value (implicit deref)
x           ; → 42
;; *1 = 42
```

This follows standard Clojure REPL behavior. To see a value after `def`, evaluate the symbol at the end:

```clojure
;; Pattern: def then evaluate to see result
(do
  (def x 42)
  (def y (+ x 10))
  y)  ; → 52

;; Multiple values
(do
  (def a 1)
  (def b 2)
  [a b])  ; → [1 2]
```

**Var representation:** Print as `#'name` (e.g., `#'x`, `#'suspicious?`). Since there's only one user namespace, no need for `#'user/x`.

**Consistency with functions:** Just as `*1` can hold a function and you can call it, `*1` can hold a var. Both are first-class values.

---

## 8. Implementation Hints

### 8.1 Data Structure Reuse

The existing infrastructure can be reused with minimal changes:

| Concept | Current Implementation | Proposed Use |
|---------|----------------------|--------------|
| `memory` map | Stores `memory/key` values | Stores user `def` bindings |
| `context` struct | Stores `ctx/key` values | Unchanged |
| `tools` map | Tool name → function | Becomes `ctx/tool-name` functions |
| `turn_history` | `*1`/`*2`/`*3` values | Unchanged |

### 8.2 Evaluation Context Changes

```elixir
# Current EvalContext
defstruct [:memory, :ctx, :tools, :turn_history, ...]

# Proposed: rename 'memory' to 'user_namespace' for clarity
defstruct [:user_ns, :ctx, :tools, :turn_history, ...]
```

### 8.3 Parser Changes

**New AST nodes:**

```elixir
# (def name value)
{:def, name_symbol, value_ast}

# (defn name [params] body)
{:defn, name_symbol, params_list, body_ast}
# Desugars to: {:def, name_symbol, {:fn, params_list, body_ast}}
```

**Symbol resolution:**

```elixir
# Current: memory/foo → {:ns_symbol, :memory, :foo}
# Proposed: keep ctx/foo → {:ns_symbol, :ctx, :foo}
#           bare symbols → {:symbol, :foo} (resolve in user_ns or builtins)
```

### 8.4 Evaluator Changes

```elixir
# Evaluate (def name value)
# Note: def cannot shadow builtins (validated here)
defp do_eval({:def, name, value_ast}, %EvalContext{} = ctx) do
  if builtin?(name) do
    {:error, {:cannot_shadow_builtin, name}}
  else
    with {:ok, value, ctx2} <- do_eval(value_ast, ctx) do
      new_user_ns = Map.put(ctx2.user_ns, name, value)
      # Return the var, not the value (Clojure semantics)
      {:ok, {:var, name}, %{ctx2 | user_ns: new_user_ns}}
    end
  end
end

# Resolve bare symbol
# Note: let-bindings are resolved during analysis (renamed to unique symbols)
# Resolution order: user namespace → builtins (no conflict possible due to def validation)
defp do_eval({:symbol, name}, %EvalContext{user_ns: user_ns} = ctx) do
  cond do
    Map.has_key?(user_ns, name) -> {:ok, Map.get(user_ns, name), ctx}
    builtin?(name) -> {:ok, get_builtin(name), ctx}
    true -> {:error, {:undefined_symbol, name}}
  end
end
```

### 8.5 Tool Invocation Change

Tools move from `(call "name" args)` to `(ctx/name args)`:

```elixir
# Current: (call "search" {:query "x"})
# {:call, "search", args_ast}

# Proposed: (ctx/search {:query "x"})
# Parsed as: {:ns_call, :ctx, :search, [args_ast]}

defp do_eval({:ns_call, :ctx, tool_name, args_ast}, %EvalContext{tools: tools} = ctx) do
  with {:ok, args, ctx2} <- eval_args(args_ast, ctx),
       {:ok, result} <- invoke_tool(tools, tool_name, args) do
    {:ok, result, ctx2}
  end
end
```

### 8.6 Memory Contract Changes — Simplified

The current "return map to store" pattern with `:return` output firewall becomes explicit `def`:

**Current (v1) — magic `:return` key:**
```clojure
;; Map without :return → entire map merged into memory, LLM sees all
{:all-users (call "fetch-users" {})}
;; LLM sees: {:all-users [{...500 items...}]}
;; memory/all-users = same

;; Map with :return → :return shown to LLM, rest merged into memory
{:all-users (call "fetch-users" {})
 :return "Stored 500 users"}
;; LLM sees: "Stored 500 users"
;; memory/all-users = full dataset
```

**Proposed (v2) — explicit `def`, no magic:**
```clojure
;; def stores explicitly, last expression is feedback
(do
  (def all-users (ctx/fetch-users {}))
  (str "Stored " (count all-users) " users"))
;; LLM sees: "Stored 500 users"
;; all-users = full dataset (via def)
```

**Benefits:**
- No magic `:return` key — just normal Clojure `do` semantics
- Explicit storage via `def` — clear what persists
- Last expression = feedback — standard REPL behavior
- `(return value)` still terminates multi-turn loops

**Single-shot vs Multi-turn:**

| Mode | Termination | Example |
|------|-------------|---------|
| Single-shot (`max_turns: 1`) | Last expression is result | `(+ ctx/a ctx/b)` |
| Multi-turn | Must call `(return ...)` | `(return {:id 42})` |

The `(return ...)` form is only needed for multi-turn to signal "I'm done". Single-shot just evaluates and returns.

### 8.7 Prompt Generation Changes

The `generate_tool_schemas/2` function in `prompt.ex` changes from markdown format to Clojure comments.

**Key principle:** Signatures are displayed as-is — no parsing required.

```elixir
# Current format_tool/2 output:
"""
### search
```
search(query :string, limit :int) -> [{id :int}]
```
Search for items matching query
Example: `(call "search" {:query "..." :limit 10})`
"""

# Proposed format_tool/2 output:
"""
;; ctx/search : (query :string, limit :int) -> [{:id :int}]
;;   Search for items matching query.
"""
```

**Implementation:**

```elixir
defp format_tool_as_comment(name, %Tool{signature: sig, description: desc}) do
  # No parsing — just prepend ctx/name and append description
  desc_line = if desc, do: "\n;;   #{desc}", else: ""
  ";; ctx/#{name} : #{sig}#{desc_line}"
end

defp format_data_as_comment(name, signature, field_descriptions) do
  # Signature displayed as-is, description from field_descriptions
  desc = Map.get(field_descriptions, name)
  desc_line = if desc, do: "\n;;   #{desc}", else: ""
  ";; #{name} : #{signature}#{desc_line}"
end
```

**Full namespace template:**

```elixir
defp generate_ctx_namespace(data_entries, tools, field_descriptions) do
  data_section = Enum.map_join(data_entries, "\n", fn {name, sig} ->
    format_data_as_comment(name, sig, field_descriptions)
  end)

  tools_section = Enum.map_join(tools, "\n", fn {name, tool} ->
    format_tool_as_comment(name, tool)
  end)

  """
  (ns ctx)

  ;;; Data

  #{data_section}

  ;;; Tools

  #{tools_section}

  ;; Quick reference:
  ;; - Access data:     ctx/expenses, ctx/users
  ;; - Call tools:      (ctx/search {:query "..."})
  ;; - Define values:   (def name value)
  ;; - Define helpers:  (defn name [args] body)
  ;; - Previous result: *1, *2, *3
  ;; - Finish:          (return value) or (fail "reason")
  """
end
```

### 8.8 Output Formatting Options

The library should provide configurable output truncation/formatting. Currently:

| What | Current Location | Current Default | Problem |
|------|------------------|-----------------|---------|
| Turn feedback | `ResponseHandler.format_execution_result/2` | `:infinity` (no limit!) | Context bloat |
| `*1`/`*2`/`*3` history | `ResponseHandler.truncate_for_history/2` | 1024 bytes | OK |
| Final answer format | Demo app `format_answer/1` | 500 chars, inspect limit 50 | Should be in library |

**Proposed: `format_options` in SubAgent**

```elixir
SubAgent.new(
  prompt: "...",
  signature: "...",
  format_options: [
    # Turn feedback (shown to LLM after each turn)
    feedback_limit: 20,           # max collection items (default: 20)
    feedback_max_chars: 2048,     # max chars (default: 2KB)

    # REPL history (*1/*2/*3)
    history_max_bytes: 1024,      # truncation limit (default: 1KB)

    # Final result formatting
    result_limit: 50,             # inspect :limit for collections (default: 50)
    result_max_chars: 500         # final string truncation (default: 500)
  ]
)
```

**Feedback truncation example:**

```clojure
;; Tool returns 500 items
(ctx/search {:query "budget"})

;; LLM sees truncated feedback:
;; Result: {:results [{:id 1} {:id 2} ... {:id 20}] (500 total, showing first 20), :cursor "abc"}
```

The LLM sees enough to understand the shape and sample data, but not the full payload.

**Flow:**

```
SubAgent.format_options
    ↓
Loop (passes to ResponseHandler)
    ↓
ResponseHandler.format_execution_result/2  ← uses :feedback_limit, :feedback_max_chars
ResponseHandler.truncate_for_history/2     ← uses :history_max_bytes
ResponseHandler.format_result/2            ← new function, uses :result_limit, :result_max_chars
```

**Implementation notes:**

1. Add `format_options` field to SubAgent struct with defaults
2. Pass options through `Loop` to `ResponseHandler`
3. Create `ResponseHandler.format_result/2` — move logic from demo app's `format_answer/1`
4. Update demo app to use library's formatting (delete `format_answer/1` and `truncate/2`)

**Demo app migration:**

```elixir
# Before (demo/lib/ptc_demo/agent.ex)
defp format_answer(result) do
  result
  |> inspect(limit: 50, pretty: false)
  |> truncate(500)
end

# After — use library function
answer = PtcRunner.SubAgent.format_result(result, agent.format_options)
```

This consolidates truncation logic in the library and makes limits configurable per-agent.

---

## 9. Simplifications and Removals

**Backward compatibility is NOT a goal.** This migration is an opportunity to delete code and simplify the system. The following should be removed entirely, not deprecated.

### 9.1 Code to Delete

#### Parser (`lib/ptc_runner/lisp/ast.ex`)

| Remove | Location | Reason |
|--------|----------|--------|
| `memory/` namespace parsing | `symbol()` function, lines ~38-40 | Replaced by user namespace symbols |

#### Analyzer (`lib/ptc_runner/lisp/analyze.ex`)

| Remove | Location | Reason |
|--------|----------|--------|
| `{:ns_symbol, :memory, key}` dispatch | Line ~90-91 | No more `memory/` reads |
| `memory/put` special form | Lines ~135, ~527-531 | Use `def` instead |
| `memory/get` special form | Lines ~136, ~538-541 | Use bare symbols instead |
| `(call "name" args)` special form | Lines ~130, ~444-468 | Use `(ctx/name args)` instead |

#### Evaluator (`lib/ptc_runner/lisp/eval.ex`)

| Remove | Location | Reason |
|--------|----------|--------|
| `{:memory, key}` eval clause | Lines ~140-142 | No more `memory/` reads |
| `{:memory_put, key, value}` eval | Lines ~145-148 | Use `def` instead |
| `{:memory_get, key}` eval | Lines ~152-154 | Use bare symbols instead |

#### Core AST Types (`lib/ptc_runner/lisp/core_ast.ex`)

| Remove | Reason |
|--------|--------|
| `{:memory, atom()}` type | No more `memory/` reads |
| `{:memory_put, atom(), t()}` type | Use `def` instead |
| `{:memory_get, atom()}` type | Use bare symbols instead |

#### Memory Contract (`lib/ptc_runner/lisp.ex`)

| Remove | Location | Reason |
|--------|----------|--------|
| Implicit map merge in `apply_memory_contract/3` | Lines ~281-312 | State via explicit `def` only |
| `:return` key special handling | Same function | No magic keys |
| `memory_delta` tracking | Throughout | Simplified model |

#### Prompt Templates (`priv/prompts/`)

| Remove/Rewrite | Reason |
|----------------|--------|
| `lisp-addon-memory.md` | Completely rewrite for `def`/`defn` model |
| Memory accumulation docs | No longer needed |
| `(call "tool" args)` examples | Replace with `(ctx/tool args)` |

### 9.2 Prompt Simplification

The current `lisp-addon-memory.md` explains complex implicit behavior:
- "Only maps are stored in memory"
- "Map keys become accessible via `memory/key`"
- "Use `:return` to control what's returned vs stored"

**Replace with simple explanation:**

```markdown
## State Management

Use `def` to store values that persist across turns:

```clojure
(def results (ctx/search {:query "budget"}))
(def threshold 5000)
```

Access defined values by name:

```clojure
results      ; → the search results
threshold    ; → 5000
```

Use `defn` to define reusable functions:

```clojure
(defn expensive? [item] (> (:price item) threshold))
(filter expensive? ctx/items)
```
```

### 9.3 Loop Simplification

Current loop has "memory contract" logic that:
1. Checks if result is a map
2. Extracts `:return` key if present
3. Merges remaining keys into memory
4. Tracks `memory_delta` for observability

**Simplified loop:**
1. Evaluate expression
2. If `(return value)` called → loop ends with value
3. If `(fail reason)` called → loop ends with error
4. Otherwise → result becomes turn feedback, `def` bindings persist

The `memory` map now only stores `def` bindings. No implicit merge logic.

### 9.4 Turn Feedback Simplification

Current feedback shows "Memory Hints" like:
```
;; (Access this result with memory/results...)
```

**Simplified feedback** mimics Clojure REPL output — just the result of evaluation:

```clojure
;; LLM writes:
(def results (ctx/search {:query "budget"}))

;; Feedback (like REPL output):
#'results
```

```clojure
;; LLM writes:
(do
  (def data (ctx/fetch-all))
  (count data))

;; Feedback:
42
```

```clojure
;; LLM writes:
results

;; Feedback (truncated for large data):
[{:id 1 :name "Alice"} {:id 2 :name "Bob"} ...] (500 items, showing first 20)
```

**Key points:**
- Feedback is the expression result, nothing more
- Large collections are truncated with count indicator
- `def` returns the var (`#'name`), consistent with Clojure
- To see a value after `def`, evaluate the symbol in the next turn (or use `do`)

### 9.5 Evaluator Simplification

Current symbol resolution has multiple paths:
1. Check if `memory/key` → read from memory map
2. Check if `ctx/key` → read from context
3. Check let-bindings
4. Check builtins

**Simplified resolution:**
1. Check let-bindings (lexical scope)
2. Check user namespace (`def` bindings)
3. Check builtins
4. Check `ctx/key` (namespace-qualified only)

Tool calls become unified: `(ctx/tool args)` resolves like any namespace-qualified call, checks if it's a tool, invokes it.

### 9.6 Summary of Wins

| Area | Before | After |
|------|--------|-------|
| Memory storage | Implicit map merge | Explicit `def` |
| Tool calls | `(call "name" args)` special form | `(ctx/name args)` unified call |
| Symbol resolution | 4+ paths | 3 clear paths |
| Prompt docs | ~100 lines explaining magic | ~20 lines explaining `def`/`defn` |
| AST node types | `call_tool`, `memory`, `memory_put`, `memory_get` | `def`, `ctx_call` |

---

## 10. Comparison Summary (v1 vs v2)

| Aspect | Current (v1) | Proposed (v2) |
|--------|--------------|---------------|
| Read input | `ctx/expenses` | `ctx/expenses` |
| Call tool | `(call "search" args)` | `(ctx/search args)` |
| Store value | `{:key value}` (implicit) | `(def key value)` (explicit) |
| Read stored | `memory/key` | `key` |
| Define function | Inline `(fn ...)` only | `(defn name ...)` |
| Clojure feel | Custom syntax | Standard forms |
| REPL history | `*1`/`*2`/`*3` | `*1`/`*2`/`*3` |

---

## 11. Open Questions

1. **Metadata support?** Skip for v1, but might want `^:dynamic` or `^:private` later for advanced use cases.

2. **Docstrings in `def`/`defn`?** Allow and ignore (Clojure compat) ?

3. **Var reader syntax `#'x`?** In Clojure, `#'x` explicitly references the var (vs `x` which derefs). Do we need this? Probably skip for v1 — the LLM rarely needs explicit var references.

### Resolved Decisions

| Question | Decision | Rationale |
|----------|----------|-----------|
| Multiple expressions per turn | Out of scope for v1 | Keep single-expression model unless trivial to implement |
| `def` inside `let` | Out of scope for v1 | Unusual pattern, adds complexity |
| Name collision with ctx | Shadow allowed, `ctx/` always accessible | Standard Clojure namespace behavior |
| ctx/ tool vs data | Tools in separate registry | `(ctx/name args)` checks tools first, then data; data access is `ctx/name` without call syntax |
| What `def` returns | The var (`#'x`) | Matches Clojure; consistent with `*1` holding functions |
| What `*1` captures | Last expression result | Var after `def`, value after symbol evaluation |
| Closure capture in `defn` | Not supported in v1 | Simplifies impl, avoids serialization issues |
| ctx/ tool vs data conflict | Validate at SubAgent creation | Fail-fast, clear error |
| Chain key mismatch | Validate at `then!/2` | Ensure output keys ⊇ input keys |

---

## 12. Implementation Roadmap

### 12.1 Feasibility Assessment

| Aspect | Feasibility | Notes |
|--------|-------------|-------|
| Remove `memory/` syntax | Easy | Delete identified code paths |
| Remove `(call "name" args)` | Easy | Delete `analyze_call_tool` |
| Add `def`/`defn` | Medium | New analyzer+evaluator clauses |
| Add `(ctx/tool args)` | Medium | New dispatch + evaluator clause |
| Symbol resolution change | Medium | Defer to runtime for user symbols |
| Struct field additions | Easy | Add optional fields with defaults |
| Prompt rewrites | Easy | Text changes only |

### 12.2 Critical Dependencies

Changes must be coordinated across modules. Here are the atomic change groups:

#### Group 1: Analyzer Changes (must happen together)

| File | Change | Lines |
|------|--------|-------|
| `analyze.ex` | Remove `{:ns_symbol, :memory, key}` dispatch | ~91 |
| `analyze.ex` | Remove `memory/put` special form | ~135, 527-531 |
| `analyze.ex` | Remove `memory/get` special form | ~136, 538-541 |
| `analyze.ex` | Remove `(call "name" args)` dispatch | ~130, 444-468 |
| `analyze.ex` | Add `def` special form dispatch | new |
| `analyze.ex` | Add `defn` special form dispatch (desugar to `def` + `fn`) | new |
| `analyze.ex` | Add `{:ns_symbol, :ctx, name}` call dispatch for `(ctx/tool args)` | new |
| `analyze.ex` | Add validation: `def` cannot shadow builtins | new |

#### Group 2: Evaluator Changes (must happen together)

| File | Change | Lines |
|------|--------|-------|
| `eval.ex` | Remove `{:memory, key}` clause | ~140-142 |
| `eval.ex` | Remove `{:memory_put, key, value}` clause | ~145-148 |
| `eval.ex` | Remove `{:memory_get, key}` clause | ~152-154 |
| `eval.ex` | Add `{:def, name, value}` evaluation (writes to `user_ns`) | new |
| `eval.ex` | Add `{:ctx_call, name, args}` evaluation (invokes tool) | new |
| `eval.ex` | Add bare symbol resolution from `user_ns` at runtime | new |

#### Group 3: Core Types (must happen with Group 1+2)

| File | Change | Lines |
|------|--------|-------|
| `core_ast.ex` | Remove `{:memory, atom()}` | ~32 |
| `core_ast.ex` | Remove `{:memory_put, atom(), t()}` | ~33 |
| `core_ast.ex` | Remove `{:memory_get, atom()}` | ~34 |
| `core_ast.ex` | Add `{:def, atom(), t()}` | new |
| `core_ast.ex` | Add `{:ctx_call, atom(), [t()]}` | new |
| `core_ast.ex` | Add `{:var, atom()}` for var references | new |

#### Group 4: Parser Changes

| File | Change | Lines |
|------|--------|-------|
| `ast.ex` | Remove `memory/` namespace parsing | ~40 |

#### Group 5: Memory Contract Simplification

| File | Change | Lines |
|------|--------|-------|
| `lisp.ex` | Remove implicit map merge in `apply_memory_contract/3` | ~268-312 |
| `lisp.ex` | Remove `:return` key special handling | same |
| `lisp.ex` | Simplify to: `def` bindings only, last expr = feedback | same |

#### Group 6: Struct Additions (can happen first)

| File | Change |
|------|--------|
| `step.ex` | Add `:field_descriptions` field |
| `sub_agent.ex` | Add `:description` field |
| `sub_agent.ex` | Add `:format_options` field |
| `sub_agent.ex` | Add `:field_descriptions` field |

#### Group 7: Prompt Templates (can happen last)

| File | Change |
|------|--------|
| `priv/prompts/lisp-addon-memory.md` | Rewrite for `def`/`defn` model |
| `priv/prompts/lisp-base.md` | Update examples, add `def`/`defn` reference |

### 12.3 Symbol Resolution Implementation

Current resolution (static, at analysis time):
```
let-bindings → builtins
```

Proposed resolution (runtime for user symbols):
```
let-bindings → user_ns (def bindings) → builtins → ctx/ (qualified)
```

**Implementation approach:**

1. Analyzer produces `{:symbol, name}` for bare symbols (unchanged)
2. Evaluator checks resolution order at runtime:

```elixir
defp do_eval({:symbol, name}, %EvalContext{user_ns: user_ns} = ctx) do
  cond do
    Map.has_key?(user_ns, name) -> {:ok, Map.get(user_ns, name), ctx}
    builtin?(name) -> {:ok, get_builtin(name), ctx}
    true -> {:error, {:undefined_symbol, name}}
  end
end
```

### 12.4 Var Representation

`def` returns a var reference, not the value:

```elixir
# New AST node
{:var, :name}

# Evaluation of def
defp do_eval({:def, name, value_ast}, %EvalContext{user_ns: user_ns} = ctx) do
  with {:ok, value, ctx2} <- do_eval(value_ast, ctx) do
    new_user_ns = Map.put(ctx2.user_ns, name, value)
    {:ok, {:var, name}, %{ctx2 | user_ns: new_user_ns}}
  end
end

# Format.to_clojure for vars
def to_clojure({:var, name}), do: "#'#{name}"
```

### 12.5 Tool Call Syntax Migration

Current: `(call "search" {:query "x"})` → `{:call_tool, "search", args}`

Proposed: `(ctx/search {:query "x"})` → `{:ctx_call, :search, args}`

**Analyzer addition:**

```elixir
# In dispatch_list_form, add before catch-all:
defp dispatch_list_form({:ns_symbol, :ctx, tool_name}, rest, _list) do
  analyze_ctx_call(tool_name, rest)
end

defp analyze_ctx_call(tool_name, arg_asts) do
  with {:ok, args} <- analyze_list(arg_asts) do
    {:ok, {:ctx_call, tool_name, args}}
  end
end
```

**Evaluator addition:**

```elixir
defp do_eval({:ctx_call, tool_name, arg_asts}, %EvalContext{tool_exec: tool_exec} = ctx) do
  with {:ok, args, memory2} <- eval_args(arg_asts, ctx) do
    # Convert atom to string for backward compatibility with tool_exec
    result = tool_exec.(Atom.to_string(tool_name), build_args_map(args))
    {:ok, result, memory2}
  end
end
```

---

## 13. References

- [Clojure Vars and the Global Environment](https://clojure.org/reference/vars)
- [Clojure REPL Guide](https://clojure.org/guides/repl/introduction)
- Current PTC-Lisp Specification: `docs/ptc-lisp-specification.md`
- PR #544: Clojure REPL-style output formatting
