# PTC-Lisp Base Language Reference

Core language reference for PTC-Lisp.

<!-- version: 8 -->
<!-- date: 2026-01-08 -->
<!-- changes: Added try/catch/throw restriction -->

<!-- PTC_PROMPT_START -->

## PTC-Lisp

Safe Clojure subset. Standard functions work — this documents PTC extensions and restrictions only.

### Context & Tools
```clojure
ctx/products                      ; read-only context data
(ctx/search {:query "budget"})    ; tool invocation
```

**Tip:** `(pmap #(ctx/tool {:id %}) ids)` runs tool calls concurrently.

### PTC Extensions

**Predicate Builders** — for `filter`, `remove`, `find`:
```clojure
(where :status = "active")        ; operator REQUIRED: = not= > < >= <= in includes
(where :amount > 100)             ; comparison
(where :deleted)                  ; truthy check
(where [:user :role] = "admin")   ; nested path
(all-of pred1 pred2)              ; combine predicates (NOT and/or)
(any-of pred1 pred2)
(none-of pred)
```

**Aggregation:**
```clojure
(sum-by :amount items)            ; sum of field values
(avg-by :price items)             ; average
(min-by :price items)             ; item with min (not value!)
(max-by :salary items)            ; item with max
(pluck :name items)               ; extract field from each
```

### Restrictions

- No namespaced keywords (`:foo/bar`)
- No `(range)` without args — use `(range 10)`
- No `if` without else — use `(if x y nil)` or `when`
- No chained comparisons — `(<= 1 x 10)` must be `(and (>= x 1) (<= x 10))`
- No `some` — use `(first (filter pred coll))`
- No `for` — use `map` or `->>`
- No regex literals (`#"..."`) — use `(re-pattern "\\d+")` then `re-find`/`re-matches`
- `loop/recur` limited to 1000 iterations
- No atoms/refs — no `(atom ...)`, `@deref`, `swap!`, `reset!` — use `def` for state
- No `partial` — use anonymous functions `#(...)`
- No reader macros — no `#_` (discard), `#'` (var quote), `#""` (regex literal)
- No `try/catch/throw` — use `fail` for errors

### Common Mistakes

| Wrong | Right |
|-------|-------|
| `(where :status "active")` | `(where :status = "active")` |
| `(and (where :a = 1) (where :b = 2))` | `(all-of (where :a = 1) (where :b = 2))` |
| `(max [1 2 3])` | `(apply max [1 2 3])` |
| `(sort-by :price coll >)` | `(sort-by :price > coll)` |
| `(includes s "x")` | `(includes? s "x")` |
| `(-> coll (filter f))` | `(->> coll (filter f))` |
| `(def x (atom {})) @x` | `(def x {})` then `x` |

<!-- PTC_PROMPT_END -->
