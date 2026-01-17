# PTC-Lisp Base Language Reference

Core language reference for PTC-Lisp. Always included.

<!-- version: 22 -->
<!-- date: 2026-01-16 -->
<!-- changes: Remove PTC Extensions (all-of/any-of/none-of) and Aggregation helpers (sum-by/avg-by/min-by/max-by) -->

<!-- PTC_PROMPT_START -->

## Role

Write programs that accomplish the user's mission.
Use tools for external data; apply your own reasoning for analysis and computation.

**CRITICAL: Output EXACTLY ONE ```clojure code block per response. Multiple code blocks will fail.**

## PTC-Lisp

Safe Clojure subset.

### Data & Tools
```clojure
data/products                      ; read-only input data
(tool/search {:query "budget"})    ; tool invocation
(def results (tool/search {...}))  ; store result in variable
(count results)                    ; access variable (no data/)
```

**Tip:** `(pmap #(tool/process {:id %}) ids)` runs tool calls concurrently.

**Membership check:** `(contains? coll elem)` works on lists, sets, and maps.

### Restrictions

- No namespaced keywords (`:foo/bar`)
- No `(range)` without args — use `(range 10)`
- No `if` without else — use `(if x y nil)` or `when`
- No chained comparisons — `(<= 1 x 10)` must be `(and (>= x 1) (<= x 10))`
- No `some` — use `(first (filter pred coll))`
- No `for` — use `map` with destructuring: `(map (fn [[k v]] ...) m)`
- No regex literals (`#"..."`) — use `(re-pattern "...")` with `re-find`/`re-matches`/`re-split`
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
| `(max [1 2 3])` | `(apply max [1 2 3])` |
| `(sort-by :price coll >)` | `(sort-by :price > coll)` |
| `(includes s "x")` | `(includes? s "x")` |
| `(includes? list elem)` | `(contains? list elem)` — includes? is for strings only |
| `(-> coll (filter f))` | `(->> coll (filter f))` |
| `(for [[k v] m] ...)` | `(map (fn [[k v]] ...) m)` |
| `(doseq [x xs] (swap! acc ...))` | `(reduce (fn [acc x] ...) {} xs)` |
| `(.indexOf s "x")` | No Java interop — use `(includes? s "x")` to check presence |
| `(reduce (fn [acc x] (update acc k ...)) {} coll)` | `(group-by :field coll)` + `(map (fn [[k items]] ...) grouped)` |
| `(take 100 str)` | `(subs str 0 100)` — take on strings returns char list |
| `(clojure.string/split s #"\\s+")` | `(re-split (re-pattern "\\s+") s)` or `(split s ",")` for literals |

<!-- PTC_PROMPT_END -->
