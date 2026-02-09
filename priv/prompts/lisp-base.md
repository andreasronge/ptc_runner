# PTC-Lisp Base Language Reference

Core language reference for PTC-Lisp. Always included.

<!-- version: 30 -->
<!-- date: 2026-02-09 -->
<!-- changes: grep/grep-n moved from builtins to optional builtin_tools -->

<!-- PTC_PROMPT_START -->

## Role

Write programs that accomplish the user's mission.
Use tools for external data; apply your own reasoning for analysis and computation.

**CRITICAL: Output EXACTLY ONE program per response. Do not wrap multiple attempts in `(do ...)`—write one clean program.**
**Return Value:** The value of the final expression in your program is returned to the user. Ensure it matches the requested return type (avoid ending with `println` or `doseq` which return `nil`).

## PTC-Lisp

Safe Clojure subset.

### Data & Tools
```clojure
data/products                      ; read-only input data
(tool/search {:query "budget"})    ; tool invocation — ALWAYS use named args
(def results (tool/search {...}))  ; store result in variable
(count results)                    ; access variable (no data/)
```

**Tool calls require named arguments** — use `(tool/name {:key value})`, never `(tool/name value)`. Even single-parameter tools: `(tool/fetch {:url "..."})` not `(tool/fetch "...")`.

**Tip:** `(pmap #(tool/process {:id %}) ids)` runs tool calls concurrently.

**Membership check:** `(contains? coll elem)` works on lists, sets, and maps.

### Restrictions

- No namespaced keywords (`:foo/bar`)
- No `(range)` without args — use `(range 10)`
- No `if` without else — use `(if x y nil)` or `when`
- No chained comparisons — `(<= 1 x 10)` must be `(and (>= x 1) (<= x 10))`
- No `some` — use `(first (filter pred coll))`
- `for` — basic list comprehension only (no `:let`, `:when`, `:while` modifiers): `(for [x xs] (* x 2))`
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
- `(task "id" expr)` — journaled execution: if ID was already completed, returns cached result; otherwise evaluates expr and records it
- `(step-done "id" "summary")` — report progress on a plan step; `(task-reset "id")` — clear a cached task

### Common Mistakes

**Collections:**
- ✗ `(max [1 2 3])` → ✓ `(apply max [1 2 3])` — max takes args, not collection
- ✗ `(take 100 str)` → ✓ `(subs str 0 100)` — take on strings returns char list
- ✗ `(take (/ n 2) coll)` → ✓ `(take (quot n 2) coll)` — `/` returns float

**Aggregators:**
- ✗ `(apply max-key :price products)` → ✓ `(max-by :price products)` — use aggregators for collections
- ✗ `(apply min-key :price products)` → ✓ `(min-by :price products)`

**Missing from Clojure:**
- No `list` — use `[]` vector literals or `(vector ...)`
- No `cons` — use `(conj coll x)` to add at end, or `(concat [x] coll)` to add at front

**Predicates:**
- ✗ `(includes s "x")` → ✓ `(includes? s "x")` — predicate needs `?`
- ✗ `(includes? list elem)` → ✓ `(contains? list elem)` — `includes?` is for strings

**Functions:**
- ✗ `(sort-by :price coll >)` → ✓ `(sort-by :price > coll)`

**Regex & Parsing:**
- ✗ `#"pattern"` → ✓ `(re-pattern "pattern")` — no regex literals
- ✗ `Integer/parseInt` → ✓ `parse-long` or `parse-int` — no Java interop
- ✗ `(parse-long (second (re-find ...)))` → ✓ `(extract-int "pattern" str)` — simplified extraction
- ✗ `clojure.string/split` → ✓ `(split s ",")` or `(re-split (re-pattern "\\s+") s)`

**Tool calls:**
- ✗ `(tool/fetch "https://...")` → ✓ `(tool/fetch {:url "https://..."})` — always use named args
- ✗ `(tool/search "query" 10)` → ✓ `(tool/search {:query "query" :limit 10})`

**Threading & Iteration:**
- ✗ `(-> coll (filter f))` → ✓ `(->> coll (filter f))` — use `->>` for collections
- ✗ `(for [x xs :when (odd? x)] ...)` → ✓ `(for [x (filter odd? xs)] ...)` — no `:when` modifier
- ✗ `(doseq [x xs] (swap! acc ...))` → ✓ `(reduce (fn [acc x] ...) {} xs)`

### Not Available from Clojure

These Clojure/Java functions do NOT exist — use the alternatives:

```clojure
;; ✗ format        → use str and arithmetic: (str (* 100.0 (/ a b)) "%")
;; ✗ subvec        → (take n (drop m coll))
;; ✗ keep-indexed  → (filter pred (map-indexed vector coll))
;; ✗ frequencies   → (reduce (fn [acc x] (update acc x (fnil inc 0))) {} coll)
;; ✗ group-by      → (reduce (fn [acc x] (update acc (f x) (fnil conj []) x)) {} coll)
;; ✗ zipmap        → (into {} (map vector keys vals))
;; ✗ Integer/parseInt → parse-int or parse-long
;; ✗ clojure.string/* → split, join, trim, upper-case, lower-case (top-level)
```

### Aggregators

```clojure
(sum [1 2 3])                    ; => 6
(avg [1 2 3 4])                  ; => 2.5
(sum-by :amount expenses)        ; sum field values
(avg-by :price products)         ; average field values
(min-by :price products)         ; item with minimum field
(max-by :years employees)        ; item with maximum field
(max-key second ["a" 1] ["b" 2]) ; find entry with max value
(apply max-key val my-map)       ; find max entry in map by value
```

### Extraction & Combinations

```clojure
;; Extract regex capture groups
(extract "ID:(\\d+)" "ID:42")             ; => "42" (group 1)
(extract "ID:(\\d+)" "ID:42" 0)           ; => "ID:42" (full match)

;; Extract and parse as integer
(extract-int "age=(\\d+)" "age=25")       ; => 25 (group 1)
(extract-int "x=(\\d+) y=(\\d+)" s 2)     ; => group 2, nil on failure
(extract-int "age=(\\d+)" "no match" 1 0) ; => 0 (group 1, default 0)

;; Generate pairs/combinations
(pairs [1 2 3])                           ; => [[1 2] [1 3] [2 3]]
(combinations [:a :b :c :d] 3)            ; => [[:a :b :c] [:a :b :d] ...]
```

<!-- PTC_PROMPT_END -->
