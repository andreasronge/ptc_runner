# PTC-Lisp Base Language Reference

Core language reference for PTC-Lisp.

<!-- PTC_PROMPT_START -->

## PTC-Lisp

Minimal Clojure subset for data queries. Programs are **single expressions**.
Only use functions documented below.

### Data Types
```clojure
nil true false        ; nil and booleans
42 3.14 "hello"       ; numbers, strings
:keyword              ; keywords (NO namespaced :foo/bar)
[1 2 3] {:a 1}        ; vectors, maps
```

### Data Access
```clojure
ctx/products          ; dataset access
ctx/orders
```

### Special Forms
```clojure
(let [x 1] body)                  ; local binding
(let [{:keys [a b]} m] body)      ; destructuring
(if cond then else)               ; conditional (else REQUIRED)
(when cond body)                  ; returns nil if false
(cond c1 r1 c2 r2 :else default)  ; multi-way
(fn [x] body)                     ; anonymous function
#(+ % 1)                          ; short syntax
```

### Predicates
```clojure
(where :field = value)            ; equality (operator REQUIRED)
(where :field > 10)               ; comparison: = not= > < >= <=
(where :field)                    ; truthy check
(where :status in ["a" "b"])      ; membership

; Combine with all-of/any-of (NOT and/or):
(filter (all-of (where :a = 1) (where :b = 2)) coll)
(filter (any-of (where :x) (where :y)) coll)
```

### Core Functions
```clojure
; Arithmetic
(+ 1 2) (- 10 3) (* 2 3) (/ 10 2) (mod 10 3)
(inc x) (dec x) (abs x) (max 1 5) (min 1 5)
(floor x) (ceil x) (round x)

; Comparison (2-arity only)
(= a b) (not= a b) (< a b) (> a b) (<= a b) (>= a b)

; Logic
(and x y) (or x y) (not x)

; Collections
(filter pred coll)  (remove pred coll)  (find pred coll)
(map f coll)        (pluck :key coll)   (reduce f init coll)
(sort coll)         (sort-by :key coll) (sort-by :key > coll)
(first coll)        (last coll)         (take n coll)  (drop n coll)
(count coll)        (empty? coll)       (distinct coll)
(conj coll x)       (concat c1 c2)      (into [] coll)

; Aggregation
(sum-by :key coll)  (avg-by :key coll)
(min-by :key coll)  (max-by :key coll)
(group-by :key coll)                    ; returns {key => [items...]}

; Maps
(get m :key)        (get-in m [:a :b])
(assoc m :k v)      (dissoc m :k)       (merge m1 m2)
(keys m)            (vals m)            (select-keys m [:a :b])
(:key m)                                ; keyword as function
(update-vals m f)                       ; apply f to each value

; Strings
(str "a" "b")       (split s ",")       (join ", " coll)
(trim s)            (upcase s)          (downcase s)

; Type checks
(nil? x) (number? x) (string? x) (map? x) (vector? x)
```

### Threading
```clojure
(->> coll (filter pred) (map f) (take 5))  ; thread-last
(-> m (assoc :a 1) (dissoc :b))            ; thread-first
```

### Return Values
Return raw values directly:
```clojure
(avg-by :price ctx/products)        ; GOOD - raw number
{:avg (avg-by :price ctx/products)} ; BAD - unnecessary wrapper
```

### Common Mistakes
| Wrong | Right |
|-------|-------|
| `(where :status "active")` | `(where :status = "active")` |
| `(and (where :a = 1) (where :b = 2))` | `(all-of (where :a = 1) (where :b = 2))` |
| `(<= 1 x 10)` | `(and (>= x 1) (<= x 10))` |
| `(if cond then)` | `(if cond then nil)` |
| `(apply max salaries)` | `(:salary (max-by :salary items))` |
| `(reduce max 0 nums)` | Use `max-by` on records, or sort+first |

### Getting Min/Max Values
```clojure
; From records - use min-by/max-by then extract field:
(:salary (max-by :salary employees))   ; max salary value
(:salary (min-by :salary employees))   ; min salary value

; Range (max - min):
(let [emps (filter (where :dept = "sales") ctx/employees)]
  (- (:salary (max-by :salary emps))
     (:salary (min-by :salary emps))))
```

<!-- PTC_PROMPT_END -->
