# Verification Predicate Syntax (PTC-Lisp Subset)

Verification predicates are **simple boolean expressions** that validate task outputs.
They use a minimal Lisp syntax with a **very limited** set of functions.

## CRITICAL: Available Bindings

**You can ONLY use these pre-defined variables:**
- `data/result` - The task's output (this is what you're validating)
- `data/input` - The task's input
- `data/depends` - Map of upstream task results (keyed by task ID)

**DO NOT use:** `output`, `result`, `response`, `input`, `symbol`, `price`, or any other variable name.

## CRITICAL: Available Functions

**ONLY these functions exist.** Any other function name will cause an error:

```lisp
;; Map/Object access (ONLY way to get values)
(get map "key")                    ; Returns value or nil
(get-in map ["key1" "key2"])       ; Nested access

;; Comparisons (ONLY these operators)
(= a b)                            ; Equality (NOT eq, equal, equals)
(> a b)  (< a b)  (>= a b)  (<= a b)

;; Logic
(and expr1 expr2 ...)
(or expr1 expr2 ...)
(not expr)

;; Conditionals
(if condition then-expr else-expr)
(when condition body)

;; Type checks (ONLY these)
(map? x)     ; Is x a map/object? (NOT object?, hash?, dict?)
(number? x)  ; Is x a number?
(string? x)  ; Is x a string?
(coll? x)    ; Is x a collection?
(nil? x)     ; Is x nil/null?

;; Collections (ONLY these)
(count coll)    ; Number of items
(empty? coll)   ; Is collection empty?
(first coll)    ; First item
(rest coll)     ; All items except first

;; Local binding
(let [name value] body)

;; String concatenation
(str a b ...)
```

## Return Values

- Return `true` for validation success
- Return a **string** for failure diagnosis (explains what went wrong)

## Correct Examples

```lisp
;; Check that result is a map with a "price" key
(if (and (map? data/result) (not (nil? (get data/result "price"))))
    true
    "Result must have a price field")

;; Check price is a number
(if (number? (get data/result "price"))
    true
    "Price must be a number")

;; Check result has items
(let [items (get data/result "items")]
  (if (and (coll? items) (> (count items) 0))
      true
      (str "Expected items, got " (count items))))

;; Simple check with diagnostic message
(if (= (get data/result "symbol") "AAPL")
    true
    "Expected AAPL symbol")

;; Using let for clarity
(let [price (get data/result "price")]
  (if (and (number? price) (> price 0))
      true
      "Price must be positive number"))
```

## DO NOT Use (These Will Fail)

```lisp
;; WRONG - undefined variables (must use data/result)
(map? output)
(map? result)
(= symbol "AAPL")
(number? price)

;; WRONG - these functions DO NOT EXIST
(has-key? data/result "price")    ; Use: (not (nil? (get data/result "price")))
(contains-key? data/result "x")   ; Use: (not (nil? (get data/result "x")))
(object? data/result)             ; Use: (map? data/result)
(eq a b)                          ; Use: (= a b)
(equal a b)                       ; Use: (= a b)
(gt a b)                          ; Use: (> a b)
(gte a b)                         ; Use: (>= a b)
(lt a b)                          ; Use: (< a b)
(lte a b)                         ; Use: (<= a b)
(length coll)                     ; Use: (count coll)
(size coll)                       ; Use: (count coll)
(is-nil x)                        ; Use: (nil? x)
(is-number x)                     ; Use: (number? x)
(type x)                          ; NOT AVAILABLE
(keys map)                        ; NOT AVAILABLE
(vals map)                        ; NOT AVAILABLE

;; WRONG - quote syntax not supported
'(1 2 3)                          ; Use: [1 2 3]
```

## Pattern: Check if Key Exists

Since `has-key?` doesn't exist, use this pattern:

```lisp
;; Check if "price" key exists
(not (nil? (get data/result "price")))

;; Check multiple required keys
(and (not (nil? (get data/result "symbol")))
     (not (nil? (get data/result "price")))
     (not (nil? (get data/result "currency"))))
```
