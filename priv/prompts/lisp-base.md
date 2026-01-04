# PTC-Lisp Base Language Reference

Core language reference for PTC-Lisp.

<!-- version: 2 -->
<!-- date: 2026-01-03 -->
<!-- changes: Simplified to hybrid approach - document PTC extensions and restrictions only, leverage LLM Clojure knowledge -->

<!-- PTC_PROMPT_START -->

## PTC-Lisp

Safe Clojure subset for data queries. Programs are **single expressions**.
Standard Clojure functions work. This documents PTC-specific extensions and restrictions.

### Data Access
```clojure
ctx/products          ; context data (read-only)
ctx/orders
```

### NOT Supported
- Namespaced keywords (`:foo/bar`)
- Lazy sequences, `lazy-seq`, `iterate`
- Macros, `defmacro`, `defn`
- Recursion, `loop/recur`
- Ratios (`1/3`), BigDecimals (`1.0M`)
- Regex literals (`#"pattern"`)
- Multi-line strings
- `if` without else — use `(if cond then nil)` or `when`
- Chained comparisons — `(<= 1 x 10)` must be `(and (>= x 1) (<= x 10))`
- `apply` on variadic math — `(apply max coll)` doesn't work
- `def` cannot shadow builtins (e.g., `(def map {})` errors)

### PTC Extensions

**Predicate Builders** — use with `filter`, `remove`, `find`:
```clojure
(where :field = value)            ; operator REQUIRED: = not= > < >= <= in includes
(where :field > 10)               ; comparison
(where :field)                    ; truthy check
(where :status in ["a" "b"])      ; membership
(where [:user :role] = "admin")   ; nested path

; Combine predicates (NOT and/or):
(filter (all-of (where :a = 1) (where :b = 2)) coll)
(filter (any-of (where :x) (where :y)) coll)
(filter (none-of (where :deleted)) coll)
```

**Aggregation** — return item (min-by/max-by) or value (sum-by/avg-by):
```clojure
(sum-by :amount expenses)         ; sum of field values
(avg-by :price products)          ; average of field values
(min-by :price products)          ; item with lowest price
(max-by :salary employees)        ; item with highest salary
(pluck :name users)               ; extract field from each item

; Get max VALUE (not item):
(:salary (max-by :salary employees))
```

**Tool Invocation** — Call external tools to fetch or transform data:
```clojure
(ctx/search {:query "budget"})      ; invoke search tool
(ctx/get-users)                     ; tool with no args
(let [results (ctx/fetch {:id 123})]  ; store tool result
  (count results))
```

**State Persistence** — Use `def` to store values across turns:
```clojure
(def results (ctx/search {:query "budget"}))  ; => #'results (stored)
results                                        ; => the search results

; Multi-step with do
(do
  (def page1 (ctx/search {:page 1}))
  (def page2 (ctx/search {:page 2}))
  (concat page1 page2))

; Redefine to update
(def counter 0)
(def counter (+ counter 1))
```

### Threading
```clojure
; ->> thread-last: for collections (filter, map, take, sort-by)
(->> ctx/users (filter :active) (map :name) (take 5))

; -> thread-first: for maps (assoc, dissoc, update, get-in)
(-> user (assoc :updated true) (dissoc :temp))
```

### Common Mistakes
| Wrong | Right |
|-------|-------|
| `(where :status "active")` | `(where :status = "active")` |
| `(and (where :a = 1) (where :b = 2))` | `(all-of (where :a = 1) (where :b = 2))` |
| `(<= 1 x 10)` | `(and (>= x 1) (<= x 10))` |
| `(if cond then)` | `(if cond then nil)` or `(when cond then)` |
| `(apply max salaries)` | `(:salary (max-by :salary items))` |
| `(reduce max 0 nums)` | `(:field (max-by :field items))` |
| `(-> coll (filter f))` | `(->> coll (filter f))` — collections use `->>` |

### Return Values
Return raw values directly:
```clojure
(avg-by :price ctx/products)        ; GOOD - raw number
{:avg (avg-by :price ctx/products)} ; BAD - unnecessary wrapper
```

<!-- PTC_PROMPT_END -->
