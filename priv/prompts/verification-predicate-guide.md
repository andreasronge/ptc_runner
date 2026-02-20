# Verification Predicate Syntax (PTC-Lisp)

Verification predicates are boolean expressions that validate task outputs.
They use PTC-Lisp syntax. Keep predicates simple — prefer `get`, type checks, and comparisons.

<bindings>
Use these pre-defined variables to access task data:
- `data/result` - The task's output (this is what you're validating)
- `data/input` - The task's input
- `data/depends` - Map of upstream task results (keyed by task ID)

DO NOT use bare variable names like `output`, `result`, `response`, `symbol`, or `price`.
Always access values through `data/result`.
</bindings>

<recommended_functions>
These cover most verification needs:

```lisp
;; Map/Object access
(get map "key")                    ; Returns value or nil
(get-in map ["key1" "key2"])       ; Nested access
(keys map)                         ; Get all keys
(vals map)                         ; Get all values
(contains? map "key")              ; Check if key exists

;; Comparisons
(= a b)                            ; Equality (NOT eq, equal, equals)
(> a b)  (< a b)  (>= a b)  (<= a b)

;; Logic
(and expr1 expr2 ...)
(or expr1 expr2 ...)
(not expr)

;; Conditionals
(if condition then-expr else-expr)
(when condition body)

;; Type checks
(map? x)      (number? x)   (string? x)
(boolean? x)  (coll? x)     (nil? x)
(some? x)     (keyword? x)  (sequential? x)

;; Collections
(count coll)    (empty? coll)   (first coll)
(rest coll)     (every? pred coll)  (some pred coll)

;; Local binding
(let [name value] body)

;; String concatenation
(str a b ...)
```

Additional functions are available: `filter`, `map`, `reduce`, `sort-by`,
`keys`, `vals`, `distinct`, `frequencies`, `every?`, `some`, `concat`, and more.
Keep predicates simple for reliability.
</recommended_functions>

<return_values>
- Return `true` for validation success
- Return a string for failure diagnosis (explains what went wrong)
</return_values>

<correct_examples>
```lisp
;; Check that result is a map with a "price" key
(if (and (map? data/result) (contains? data/result "price"))
    true
    "Result must have a price field")

;; Check price is a positive number
(let [price (get data/result "price")]
  (if (and (number? price) (> price 0))
      true
      "Price must be a positive number"))

;; Check result has items
(let [items (get data/result "items")]
  (if (and (coll? items) (> (count items) 0))
      true
      (str "Expected items, got " (count items))))

;; Check multiple required keys
(if (and (contains? data/result "symbol")
         (contains? data/result "price")
         (contains? data/result "currency"))
    true
    "Missing required fields")

;; Validate all items have a required field
(if (every? #(contains? % "name") (get data/result "items"))
    true
    "All items must have a name")
```
</correct_examples>

<common_mistakes>
```lisp
;; WRONG - undefined variables (must use data/result)
(map? output)
(map? result)
(= symbol "AAPL")
(number? price)

;; WRONG - these functions do not exist in PTC-Lisp
(has-key? data/result "price")    ; Use: (contains? data/result "price")
(contains-key? data/result "x")   ; Use: (contains? data/result "x")
(object? data/result)             ; Use: (map? data/result)
(eq a b)                          ; Use: (= a b)
(length coll)                     ; Use: (count coll)
(size coll)                       ; Use: (count coll)
(is-nil x)                        ; Use: (nil? x)
(is-number x)                     ; Use: (number? x)

;; WRONG - quote syntax not supported
'(1 2 3)                          ; Use: [1 2 3]
```
</common_mistakes>
