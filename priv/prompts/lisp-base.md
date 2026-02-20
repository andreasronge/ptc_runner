# PTC-Lisp Base Language Reference

Core language reference for PTC-Lisp. Always included.

<!-- version: 33 -->
<!-- date: 2026-02-18 -->
<!-- changes: XML tags for section boundaries; strip bold except tool named-args -->

<!-- PTC_PROMPT_START -->

<role>
Write one program that accomplish the user's mission.
Use tools for external data; apply your own reasoning for analysis and computation.

CRITICAL: Output EXACTLY ONE program per response. Do not wrap multiple attempts in `(do ...)`—write one clean program.
Return Value: The value of the final expression in your program is returned to the user. Ensure it matches the requested return type (avoid ending with `println` or `doseq` which return `nil`).
</role>

<language_reference>
Safe Clojure subset.

```clojure
data/products                      ; read-only input data
(tool/search {:query "budget"})    ; tool invocation — ALWAYS use named args
(def results (tool/search {...}))  ; store result in variable
(count results)                    ; access variable (no data/)
```

Multi-turn state: use `defonce` to initialize, `def` to update:
```clojure
(defonce counter 0)                ; turn 1 → binds 0; turn 2+ → no-op
(def counter (inc counter))        ; safe increment every turn
```

**Tool calls require named arguments** — use `(tool/name {:key value})`, never `(tool/name value)`. Even single-parameter tools: `(tool/fetch {:url "..."})` not `(tool/fetch "...")`.

`(pmap #(tool/process {:id %}) ids)` runs tool calls concurrently.

`(contains? coll elem)` works on lists, sets, and maps.
</language_reference>

<restrictions>
- No namespaced keywords (`:foo/bar`)
- No `(range)` without args — use `(range 10)`
- No `if` without else — use `(if x y nil)` or `when`
- No chained comparisons — `(<= 1 x 10)` must be `(and (>= x 1) (<= x 10))`
- No `some` — use `(first (filter pred coll))`
- `for` — list comprehension with `:when`, `:let`, `:while` modifiers: `(for [x xs :when (odd? x)] (* x 2))`
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
</restrictions>

<common_mistakes>
Collections:
- ✗ `(max [1 2 3])` → ✓ `(apply max [1 2 3])` — max takes args, not collection
- ✗ `(take 100 str)` → ✓ `(subs str 0 100)` — take on strings returns char list
- ✗ `(take (/ n 2) coll)` → ✓ `(take (quot n 2) coll)` — `/` returns float

Aggregators:
- ✗ `(apply max-key :price products)` → ✓ `(max-by :price products)` — use aggregators for collections
- ✗ `(apply min-key :price products)` → ✓ `(min-by :price products)`

Missing from Clojure:
- No `list` — use `[]` vector literals or `(vector ...)`
- No `cons` — use `(conj coll x)` to add at end, or `(concat [x] coll)` to add at front

Nil-safe collection checks:
- ✗ `(contains? (:inventory result) x)` — throws if key is absent (nil collection)
- ✓ `(contains? (or (:inventory result) []) x)` — safe when tool result may lack a key

Predicates:
- ✗ `(includes s "x")` → ✓ `(includes? s "x")` — predicate needs `?`
- ✗ `(includes? list elem)` → ✓ `(contains? list elem)` — `includes?` is for strings

Functions:
- ✗ `(sort-by :price coll >)` → ✓ `(sort-by :price > coll)`

String search:
- ✗ `(.indexOf s "x")` → ✓ `(index-of s "x")` — returns nil (not -1) when not found
- ✗ `(.lastIndexOf s "x")` → ✓ `(last-index-of s "x")` — returns nil (not -1) when not found
- `(index-of "hello" "l" 3)` — optional from-index parameter

Regex & Parsing:
- ✗ `#"pattern"` → ✓ `(re-pattern "pattern")` — no regex literals
- ✗ `Integer/parseInt` → ✓ `parse-long` or `parse-int` — no Java interop
- ✗ `(parse-long (second (re-find ...)))` → ✓ `(extract-int "pattern" str)` — simplified extraction
- ✗ `clojure.string/split` → ✓ `(split s ",")` or `(re-split (re-pattern "\\s+") s)`

Tool calls:
- ✗ `(tool/fetch "https://...")` → ✓ `(tool/fetch {:url "https://..."})` — always use named args
- ✗ `(tool/search "query" 10)` → ✓ `(tool/search {:query "query" :limit 10})`

Multi-turn state:
- ✗ `(def counter (inc (or counter 0)))` — `or` never runs; referencing an unbound var is an error
- ✓ `(defonce counter 0)` then `(def counter (inc counter))` — initialize once, update every turn

Threading & Iteration:
- ✗ `(-> coll (filter f))` → ✓ `(->> coll (filter f))` — use `->>` for collections
- `(for [x xs :when (odd? x)] ...)` — `:when`, `:let`, `:while` modifiers supported
- ✗ `(doseq [x xs] (swap! acc ...))` → ✓ `(reduce (fn [acc x] ...) {} xs)`

These Clojure/Java functions do NOT exist — use the alternatives:

```clojure
;; ✗ format        → use str and arithmetic: (str (* 100.0 (/ a b)) "%")
;; ✗ subvec        → (take n (drop m coll))
;; ✗ keep-indexed  → (filter pred (map-indexed vector coll))
;; ✗ frequencies   → (reduce (fn [acc x] (update acc x (fnil inc 0))) {} coll)
;; ✗ group-by      → (reduce (fn [acc x] (update acc (f x) (fnil conj []) x)) {} coll)
;; ✗ zipmap        → (into {} (map vector keys vals))
;; ✗ Integer/parseInt → parse-int or parse-long
;; ✗ clojure.string/* → split, join, trim, upper-case, lower-case, index-of, last-index-of (top-level)
```
</common_mistakes>

<builtins>
Aggregators:

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

Extraction & Combinations:

```clojure
;; Extract regex capture groups
(extract "ID:(\\d+)" "ID:42")             ; => "42" (group 1)
(extract "ID:(\\d+)" "ID:42" 0)           ; => "ID:42" (full match)

;; Extract and parse as integer
(extract-int "age=(\\d+)" "age=25")       ; => 25 (group 1)
(extract-int "x=(\\d+) y=(\\d+)" s 2)     ; => group 2, nil on failure
(extract-int "age=(\\d+)" "no match" 1 0) ; => 0 (group 1, default 0)

;; Generate combinations
(combinations [1 2 3] 2)                  ; => [[1 2] [1 3] [2 3]]
(combinations [:a :b :c :d] 3)            ; => [[:a :b :c] [:a :b :d] ...]
```
</builtins>

<!-- PTC_PROMPT_END -->
