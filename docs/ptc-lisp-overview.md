# PTC-Lisp Documentation Overview

**Status:** Prototype / Evaluation Phase

This document provides a high-level introduction to PTC-Lisp and guides you through the documentation suite.

---

## Why PTC-Lisp?

### The Problem

Large Language Models (LLMs) are increasingly used in agentic loops where they need to:
- Query and transform data from multiple sources
- Execute multi-step workflows across turns
- Maintain state between interactions
- Call external tools and APIs

Using raw programming languages (Python, JavaScript) for LLM-generated code introduces risks:
- **Security**: Arbitrary code execution can access the filesystem, network, or system resources
- **Unbounded computation**: Infinite loops or excessive memory usage
- **Non-determinism**: Side effects make debugging difficult
- **Complexity**: General-purpose syntax has too many ways to do things wrong

### The Solution

**PTC-Lisp** is a minimal, safe, Clojure subset designed specifically for **Programmatic Tool Calling (PTC)**. It provides:

1. **Safety by design**: No filesystem access, no network access, no unbounded recursion
2. **Deterministic execution**: Pure functions with transactional memory updates
3. **LLM-friendly syntax**: Compact, high information density, easy to generate correctly
4. **Sandboxed execution**: Resource limits (timeout, memory) enforced by BEAM

---

## What is PTC-Lisp?

PTC-Lisp is a domain-specific language for data transformation in agentic LLM workflows.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Single expressions** | Programs are one expression, not sequences of statements |
| **Functional** | No mutable state during execution |
| **Transactional** | All-or-nothing memory updates |
| **Sandboxed** | Runs in isolated BEAM processes with limits |
| **Verifiable** | Can validate against real Clojure |

### What It Supports

- **Data types**: nil, booleans, numbers, strings, keywords, vectors, maps
- **Collections**: filter, map, reduce, sort, group, aggregate
- **Predicates**: `where` builder with operators (=, not=, >, <, >=, <=, includes, in)
- **Control flow**: let, if, when, cond, fn (anonymous functions)
- **Threading**: `->>` (thread-last), `->` (thread-first) for pipelines
- **Tool calls**: Invoke host-registered functions
- **Memory**: Persistent state across turns via `memory/` namespace

### What It Explicitly Excludes

- General-purpose programming (no loops, no recursion)
- I/O operations (no print, no file access)
- Macros and metaprogramming
- Mutable state (no atoms, refs, agents)
- String manipulation functions (use tools instead)

---

## Comparison with JSON DSL

PtcRunner already has a working JSON-based DSL. PTC-Lisp is an alternative that trades implementation complexity for token efficiency.

### Side-by-Side Example

**JSON DSL (current, implemented)**
```json
{
  "op": "let",
  "name": "high_paid",
  "value": {
    "op": "pipe",
    "steps": [
      {"op": "call", "tool": "find_employees"},
      {"op": "filter", "where": {"op": "gt", "field": "salary", "value": 100000}}
    ]
  },
  "in": {
    "op": "pipe",
    "steps": [
      {"op": "var", "name": "high_paid"},
      {"op": "count"}
    ]
  }
}
```

**PTC-Lisp**
```clojure
(let [high-paid (->> (call "find-employees" {})
                     (filter (where :salary > 100000)))]
  (count high-paid))
```

### Trade-off Summary

| Aspect | JSON DSL | PTC-Lisp |
|--------|----------|----------|
| **Status** | Implemented, tested | Design phase |
| **Token efficiency** | ~1x (baseline) | ~3-5x better |
| **Parser complexity** | `JSON.decode` (1 line) | NimbleParsec (~500 LOC) |
| **Error location** | Exact position | Harder to pinpoint |
| **LLM familiarity** | Universal | Clojure subset |
| **Tooling** | Universal syntax highlighting | Less common |
| **Predicate syntax** | `{"op": "gt", "field": ...}` | `(where :f > v)` |
| **Anonymous functions** | Not supported | `(fn [x] body)` |
| **Closures** | Not supported | Yes |

### When to Prefer Each

**Stick with JSON DSL if:**
- Stability and proven implementation matter most
- Simple pipelines (filter → transform → aggregate) suffice
- Universal tooling and logging are priorities

**Consider PTC-Lisp if:**
- Token costs are significant (3-5x reduction)
- Complex predicates with combinators are common
- Closures and dynamic predicates are needed
- Multi-turn agentic loops benefit from memory contract

---

### Memory Model

Programs are pure functions of `(memory, context) → result`:

```clojure
;; Turn 1: Fetch and filter users, store in memory
{:high-paid (->> (call "get-users" {})
                 (filter (where :salary > 100000)))}

;; Turn 2: Use previous results from memory
(->> memory/high-paid
     (sort-by :salary >)
     (take 10))
```

**Result contract** determines memory behavior:

| Return Value | Memory Effect |
|--------------|---------------|
| Non-map (number, vector, etc.) | No memory change |
| Map without `:result` | Entire map merged into memory |
| Map with `:result` | Rest merged into memory, `:result` returned |

### Resource Limits

| Timeout | 5,000 ms | Interpreter sandbox limit (prevents infinite execution) |
| Max Heap | ~10 MB | Prevent memory exhaustion |
| Max Depth | 50 | Prevent stack overflow |

> **Note:** The default timeout of 5,000 ms is designed to accommodate external API latency in agentic loops.

---

## Document Guide

### Core Documents

| Document | Purpose | Audience |
|----------|---------|----------|
| **[ptc-lisp-overview.md](ptc-lisp-overview.md)** | This document - rationale and evaluation plan | Everyone |
| **[ptc-lisp-specification.md](ptc-lisp-specification.md)** | Complete language specification | Language designers, implementers |
| **[ptc-lisp-llm-guide.md](ptc-lisp-llm-guide.md)** | Quick reference for LLM prompts | Application developers, prompt engineers |

---

## Quick Start

### For Application Developers

1. Read **[ptc-lisp-llm-guide.md](ptc-lisp-llm-guide.md)** for API usage
2. Extract the "Quick Reference" section for your LLM prompts
3. Register your tools and execute programs

```elixir
{:ok, result, metrics} = PtcRunner.Lisp.run(
  ~s/(->> ctx/users (filter (where :active = true)) (count))/,
  context: %{users: users},
  tools: %{"get-orders" => &MyApp.get_orders/1}
)
```

### For Language Implementers

1. Start with **[ptc-lisp-specification.md](ptc-lisp-specification.md)** for full semantics
2. Review the parser implementation in `lib/ptc_runner/lisp/parser.ex`
3. Review the analyzer in `lib/ptc_runner/lisp/analyzer.ex`
4. Review the interpreter in `lib/ptc_runner/lisp/eval.ex`

### For LLM Prompt Engineers

The **[ptc-lisp-llm-guide.md](ptc-lisp-llm-guide.md)** contains a compact quick reference (~2.5KB) designed to be included in LLM system prompts. Key sections:

- Data types and access patterns
- Predicate builders (`where`, `all-of`, `any-of`, `none-of`)
- Common mistakes to avoid
- Memory result contract

---

## Example Program

```clojure
;; Find high-value orders with premium customers
;; and store summary in memory
(let [orders (call "get-orders" {:since "2024-01-01"})
      users (call "get-users" {})
      premium-ids (->> users
                       (filter (where :tier = "premium"))
                       (pluck :id))]
  {:result {:count (count filtered)
            :total (sum-by :amount filtered)}
   :high-value-orders filtered})

;; where filtered is computed as:
;; (->> orders
;;      (filter (all-of (where :amount > 1000)
;;                      (where :user-id in premium-ids))))
```

This program:
1. Calls two tools to fetch data
2. Filters and transforms using predicates
3. Returns a summary to the caller
4. Persists results in memory for the next turn

---

## Future Improvements

### Runtime Enhancements

Testing with LLM-generated code has revealed gaps in string/atom key flexibility. While many operations (`pluck`, `sort-by`, `sum-by`, `get`) use `flex_get` for bidirectional key matching, some operations still require exact key types:

| Operation | String Key Support | Priority | Notes |
|-----------|-------------------|----------|-------|
| `(:key map)` keyword-as-function | ❌ No | High | Uses `Map.get`, should use `flex_get` |
| `select-keys` | ❌ No | High | Uses `Map.take`, needs flexible key matching |
| `where` value comparison | ❌ No | Medium | `:active` doesn't match `"active"` |
| `#(...)` anonymous shorthand | ❌ Not supported | Low | Nice-to-have Clojure syntax |

**Recommended fixes:**

1. **Keyword-as-function** (`eval.ex:347`): Replace `Map.get(m, k)` with `flex_get(m, k)` pattern
2. **select-keys** (`runtime.ex:196`): Implement flexible key matching instead of `Map.take`

### LLM Guide Enhancements

Testing with various LLM models has revealed common patterns where LLMs generate invalid PTC-Lisp code due to Clojure habits that don't apply to this subset. The LLM guide should be enhanced to explicitly address these issues:

| Issue | LLM Mistake | Correct PTC-Lisp |
|-------|-------------|------------------|
| **Keyword-as-function** | `(:name map)` returns nil with string keys | Use `(get :name map)` for map access |
| **select-keys** | `(select-keys m [:a :b])` returns `%{}` with string keys | Use `get` in a `map` or ensure consistent key types |
| **Keywords vs strings** | `:engineering` when data has `"engineering"` | String values in data require quoted strings in `where` |

#### Example Corrections

**Map value extraction:**
```clojure
;; WRONG: Clojure keyword-as-function syntax (fails with string-keyed maps)
(->> ctx/products (max-by :price) (:name))  ; Returns nil

;; CORRECT: Use get function (works with both atom and string keys)
(->> ctx/products (max-by :price) (get :name))
```

**Set membership (now supported):**
```clojure
;; Set literals are now supported with #{...} syntax
(let [ids #{1 2 3}]
  (filter (fn [x] (contains? ids (:id x))) items))

;; Or create sets dynamically
(let [engineering-ids (->> employees
                           (filter (where :department = "engineering"))
                           (pluck :id)
                           (set))]
  (filter (fn [e] (contains? engineering-ids (:employee_id e))) expenses))
```

**String vs keyword comparison:**
```clojure
;; WRONG: Using keyword when data contains string
(filter (where :department = :engineering) employees)  ; Returns []

;; CORRECT: Use string to match string data
(filter (where :department = "engineering") employees)
```

These patterns should be prominently documented in the "Common Mistakes" section of `ptc-lisp-llm-guide.md`.

### Test Report Analysis (2025-12-10)

From testing with DeepSeek V3.2 model (19/21 tests passed, 90% pass rate):

**What works well:**
- Core operations: `count`, `filter`, `sum-by`, `avg-by`, `sort-by`, `take`, `pluck`, `distinct`
- Threading macros (`->>`) used naturally
- `where` macro with string comparisons
- Set creation with `(set ...)` and `contains?` for membership
- Memory persistence for multi-turn queries
- Complex `let` bindings and pipelines

**Remaining issues:**
- Keyword-as-function `(:name map)` fails with string-keyed data (test 12)
- LLMs sometimes use `:keyword` instead of `"string"` in `where` clauses (test 21)

