# PTC-Lisp Base Language Reference

Core language reference for PTC-Lisp. Always included.

<!-- version: 15 -->
<!-- date: 2026-01-08 -->
<!-- changes: Added contains? for list membership, common mistake for includes? vs contains? -->

<!-- PTC_PROMPT_START -->

## Role

Write programs that accomplish the user's mission.
Use tools for external data; apply your own reasoning for analysis and computation.

## PTC-Lisp

Safe Clojure subset.

### Context & Tools
```clojure
ctx/products                      ; read-only context data
(ctx/search {:query "budget"})    ; tool invocation
(def results (ctx/search {...}))  ; store result in variable
(count results)                   ; access variable (no ctx/)
```

**Tip:** `(pmap #(ctx/tool {:id %}) ids)` runs tool calls concurrently.

### PTC Extensions

**Predicate Builders** — for `filter`, `remove`, `find`:
```clojure
(where :status = "active")        ; operator REQUIRED: = not= > < >= <= in includes
(where :amount > 100)             ; comparison
(where :deleted)                  ; truthy check
(where [:user :role] = "admin")   ; nested path
(where :status in ["active" "pending"])  ; field value is one of these
(where :id in user-ids)           ; field value in variable list
(where :tags includes "urgent")   ; collection field contains value
(all-of pred1 pred2)              ; combine predicates (NOT and/or)
(any-of pred1 pred2)
(none-of pred)
```

**Aggregation** (all take a list of maps):
```clojure
(sum-by :amount orders)           ; sum of field values
(avg-by :price products)          ; average
(min-by :price products)          ; item with min (not value!)
(max-by :salary employees)        ; item with max
(pluck :name users)               ; ["Alice" "Bob" ...] from list of maps
(contains? coll elem)             ; membership check (works on lists, sets, maps)
```

### Restrictions

- No namespaced keywords (`:foo/bar`)
- No `(range)` without args — use `(range 10)`
- No `if` without else — use `(if x y nil)` or `when`
- No chained comparisons — `(<= 1 x 10)` must be `(and (>= x 1) (<= x 10))`
- No `some` — use `(first (filter pred coll))`
- No `for` — use `map` with destructuring: `(map (fn [[k v]] ...) m)`
- No regex literals (`#"..."`) — use `(re-pattern "\\d+")` then `re-find`/`re-matches`
- `loop/recur` limited to 1000 iterations
- No atoms/refs — no `(atom ...)`, `@deref`, `swap!`, `reset!`, `doseq` — use `reduce`:
  ```clojure
  ;; Wrong: (def acc (atom {})) (doseq [x xs] (swap! acc assoc ...)) @acc
  ;; Right: (reduce (fn [acc x] (assoc acc ...)) {} xs)
  ```
- No `partial` — use anonymous functions `#(...)`
- No reader macros — no `#_` (discard), `#'` (var quote), `#""` (regex literal)
- No `try/catch/throw` — use `fail` for errors

### Common Mistakes

| Wrong | Right |
|-------|-------|
| `(where :status "active")` | `(where :status = "active")` |
| `(and (where :a = 1) (where :b = 2))` | `(all-of (where :a = 1) (where :b = 2))` |
| `(filter #(some ... ids) coll)` | `(filter (where :id in ids) coll)` |
| `(max [1 2 3])` | `(apply max [1 2 3])` |
| `(sort-by :price coll >)` | `(sort-by :price > coll)` |
| `(includes s "x")` | `(includes? s "x")` |
| `(includes? list elem)` | `(contains? list elem)` — includes? is for strings only |
| `(-> coll (filter f))` | `(->> coll (filter f))` |
| `(for [[k v] m] ...)` | `(map (fn [[k v]] ...) m)` |
| `(doseq [x xs] (swap! acc ...))` | `(reduce (fn [acc x] ...) {} xs)` |
| `(pluck :name user)` | `(:name user)` — pluck is for lists |
 | `(.indexOf s "x")` | No Java interop — use `(includes? s "x")` to check presence |

<!-- PTC_PROMPT_END -->
