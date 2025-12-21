# PTC-Lisp Language Specification

---

## 1. Overview

PTC-Lisp is a small, safe, deterministic subset of Clojure designed for Programmatic Tool Calling. Programs are **single expressions** that transform data through pipelines of operations.

### Execution Model

A PTC-Lisp program is a **pure function** of `(memory, ctx) → result`:

- **Input**: Persistent memory from previous turns + current request context
- **Output**: A result value that may update persistent memory
- **Semantics**: Functional, transactional, all-or-nothing

This design enables safe execution in **agentic LLM loops** where programs are generated, executed, and refined across multiple turns.

### Design Goals

1. **LLM-friendly**: Easy for language models to generate correctly
2. **Safe**: No side effects, no unbounded recursion, no system access
3. **Compact**: Minimal syntax, high information density
4. **Verifiable**: Can be validated against real Clojure for correctness
5. **Expressive**: Sufficient for common data transformation tasks
6. **Transactional**: All-or-nothing memory updates, safe for retry loops

### Non-Goals

- General-purpose programming
- Turing completeness
- Full Clojure compatibility

---

## 2. Lexical Structure

### 2.1 Whitespace

Whitespace separates tokens. The following are whitespace:
- Space (` `)
- Tab (`\t`)
- Newline (`\n`, `\r\n`)
- Comma (`,`) — treated as whitespace for readability

```clojure
{:a 1, :b 2}    ; comma is optional
{:a 1 :b 2}    ; equivalent
[1, 2, 3]      ; comma is optional
[1 2 3]        ; equivalent
```

### 2.2 Comments

Single-line comments start with `;` and extend to end of line:

```clojure
; This is a comment
(+ 1 2) ; inline comment
```

### 2.3 Identifiers (Symbols)

Symbols are names that refer to values or functions:

```
symbol        = symbol-first symbol-rest*
symbol-first  = letter | special-initial
symbol-rest   = letter | digit | special-rest
letter        = a-z | A-Z
digit         = 0-9
special-initial = + | - | * | / | < | > | = | ? | !
special-rest    = special-initial | - | _ | /
```

Note: `/` appears in both `special-initial` (for the division operator) and `special-rest` (for namespaced symbols like `memory/foo`).

Valid symbols: `filter`, `map`, `sort-by`, `empty?`, `+`, `->>`, `memory/foo`, `ctx/bar`

Reserved symbols (cannot be redefined): `nil`, `true`, `false`

### 2.4 Keywords

Keywords are symbolic identifiers that evaluate to themselves:

```
keyword = : symbol
```

Examples: `:name`, `:user-id`, `:total`, `:else`

Keywords with namespaces are **not supported**: ~~`:foo/bar`~~

---

## 3. Data Types

### 3.1 Nil

The absence of a value:

```clojure
nil
```

### 3.2 Booleans

```clojure
true
false
```

### 3.3 Numbers

**Integers** — arbitrary precision:
```clojure
0
42
-17
1000000
```

**Floats** — double precision:
```clojure
3.14
-0.5
1.0
2.5e10
1.23e-4
```

**Not supported:** Ratios (`1/3`), BigDecimals (`1.0M`), octal/hex literals

### 3.4 Strings

Double-quoted, with escape sequences:

```clojure
"hello"
"hello world"
""
"line1\nline2"
"tab\there"
"quote: \""
"backslash: \\"
```

Supported escapes: `\\`, `\"`, `\n`, `\t`, `\r`

**Single-line only:** Strings must not contain literal newline characters (`\n`, `\r`). Use escape sequences (`\n`, `\r`) for newlines within string content.

**Not supported:** Multi-line strings, regex literals

**String operations:** Strings support `count` and `empty?` but are otherwise opaque. Character access (`nth`, `first`), substring extraction, and string manipulation are not supported—use tools for complex string processing. See Section 8.6 for details.

### 3.5 Keywords

Self-evaluating symbolic identifiers:

```clojure
:name
:user-id
:category
:else
```

Keywords can be called as functions to access map values:

```clojure
(:name {:name "Alice" :age 30})  ; => "Alice"
(:missing {:name "Alice"})       ; => nil
(:missing {:name "Alice"} "default")  ; => "default"
```

### 3.6 Vectors

Ordered, indexed collections:

```clojure
[]
[1 2 3]
["a" "b" "c"]
[1 "mixed" :types true nil]
[[1 2] [3 4]]  ; nested
```

### 3.7 Maps

Key-value associations:

```clojure
{}
{:name "Alice"}
{:name "Alice" :age 30}
{:user {:name "Bob" :email "bob@example.com"}}  ; nested
{"string-key" 42}  ; string keys allowed
```

**Map keys:** Only keywords and strings are valid map keys. Keywords are preferred for their readability and self-documenting nature. Using other types (numbers, vectors, maps) as keys raises a `validation-error`.

```clojure
{:name "Alice"}           ; OK - keyword key
{"name" "Alice"}          ; OK - string key
{1 "one"}                 ; VALIDATION ERROR - number key
{[:a :b] "nested"}        ; VALIDATION ERROR - vector key
```

### 3.8 Sets

Unordered collections of unique values:

```clojure
#{}                    ; empty set
#{1 2 3}               ; set with 3 elements
#{1 1 2}               ; duplicates silently removed: equivalent to #{1 2}
#{:a :b :c}            ; keyword set
```

Sets are **unordered** - iteration order is not guaranteed.

**Set operations:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `set?` | `(set? x)` | Returns true if x is a set |
| `set` | `(set coll)` | Convert collection to set |
| `count` | `(count #{1 2})` | Returns element count |
| `empty?` | `(empty? #{})` | Returns true if empty |
| `contains?` | `(contains? #{1 2} 1)` | Membership test (O(1)) |

**Not supported for sets:** `first`, `last`, `nth`, `sort`, `sort-by` (sets are unordered).

**Not supported:** Lists (`'()`)

---

## 4. Truthiness

Only `nil` and `false` are **falsy**. Everything else is **truthy**:

| Value | Truthy? |
|-------|---------|
| `nil` | No |
| `false` | No |
| `true` | Yes |
| `0` | Yes |
| `""` (empty string) | Yes |
| `[]` (empty vector) | Yes |
| `{}` (empty map) | Yes |
| Any other value | Yes |

---

## 5. Special Forms

Special forms are fundamental constructs with special evaluation rules.

### 5.1 `let` — Local Bindings

Binds names to values for use in the body expression:

```clojure
(let [name value]
  body)

(let [name1 value1
      name2 value2]
  body)
```

**Semantics:**
- Bindings are evaluated left-to-right
- Later bindings can reference earlier ones
- Bindings are scoped to the body
- Inner `let` can shadow outer bindings

```clojure
(let [x 10
      y (+ x 5)]    ; y can use x
  (* x y))          ; => 150

(let [x 1]
  (let [x 2]        ; shadows outer x
    x))             ; => 2
```

#### Map Destructuring

Extract values from maps:

```clojure
; Basic destructuring
(let [{:keys [name age]} {:name "Alice" :age 30}]
  name)  ; => "Alice"

; With defaults
(let [{:keys [name age] :or {age 0}} {:name "Bob"}]
  age)   ; => 0

; Renaming
(let [{the-name :name} {:name "Carol"}]
  the-name)  ; => "Carol"

; Nested destructuring
(let [{:keys [user]} {:user {:name "Dan"}}
      {:keys [name]} user]
  name)  ; => "Dan"
```

**Supported destructuring forms:**
- `{:keys [a b c]}` — extract keyword keys
- `{:keys [a] :or {a default}}` — with defaults
- `{new-name :old-key}` — rename binding
- `{:keys [a] :as m}` — bind whole map to `m`

### 5.2 `if` — Conditional

Two-branch conditional (else is **required**):

```clojure
(if condition
  then-expression
  else-expression)
```

```clojure
(if (> x 10)
  "big"
  "small")

(if (empty? items)
  nil
  (first items))
```

**Single-branch `if` is not allowed.** Use `when` instead.

### 5.3 `when` — Single-branch Conditional

Returns body if condition is truthy, otherwise `nil`:

```clojure
(when condition
  body)
```

```clojure
(when (> x 10)
  "big")  ; => "big" or nil
```

### 5.4 `cond` — Multi-way Conditional

Tests conditions in order, returns first matching result:

```clojure
(cond
  condition1 result1
  condition2 result2
  :else default-result)
```

```clojure
(cond
  (> total 1000) "high"
  (> total 100)  "medium"
  :else          "low")
```

**Semantics:**
- Conditions are evaluated in order
- First truthy condition's result is returned
- `:else` is conventional for default (it's truthy)
- Returns `nil` if no condition matches and no `:else`

---

## 6. Threading Macros

Threading macros transform nested function calls into linear pipelines.

### 6.1 `->>` — Thread Last

Threads the value as the **last argument** to each form:

```clojure
(->> value
     (fn1 arg1)
     (fn2 arg2)
     (fn3))
```

Equivalent to:
```clojure
(fn3 (fn2 arg2 (fn1 arg1 value)))
```

**Primary use:** Collection pipelines where data is the last argument.

```clojure
(->> ctx/products
     (filter (where :in-stock))
     (sort-by :price)
     (take 10))
```

### 6.2 `->` — Thread First

Threads the value as the **first argument** to each form:

```clojure
(-> value
    (fn1 arg1)
    (fn2 arg2))
```

Equivalent to:
```clojure
(fn2 (fn1 value arg1) arg2)
```

**Primary use:** Map transformations where data is the first argument.

```clojure
(-> user
    (assoc :updated-at now)
    (dissoc :password))
```

---

## 7. Predicate Builders

Predicate builders create **predicate functions** for use with `filter`, `remove`, `find`, etc. They eliminate the need for anonymous functions in most filtering scenarios.

### 7.1 `where` — Field Comparison

Creates a predicate function that compares a field value:

```clojure
(where field-key operator value)
(where path operator value)
```

**Operators:** `=`, `not=`, `>`, `<`, `>=`, `<=`, `includes`, `in`

#### Single Field

```clojure
(where :status = "active")      ; field equals value
(where :age > 18)               ; field greater than
(where :price <= 100)           ; field less than or equal
(where :category not= "hidden") ; field not equals
(where :tags includes "urgent") ; field includes value (substring or member)
```

#### Nested Field (Path)

Use a vector for nested access:

```clojure
(where [:user :age] > 18)
(where [:profile :email] not= nil)
(where [:address :country] = "US")
```

#### Field Exists / Is Truthy

Check if field is truthy (not `nil` or `false`):

```clojure
(where :active)           ; field is truthy (not nil, not false)
(where :verified = true)    ; explicit boolean check
(where [:user :premium])  ; nested truthy check
```

#### Keyword/String Coercion

For the equality operators (`=`, `not=`), `in`, and `includes`, keywords are coerced to strings for comparison. This allows LLM-generated keywords to match string data values:

```clojure
;; Keyword coerces to string
(where :status = :active)        ; matches if field is "active"
(where :status in [:active :pending])  ; both keywords coerce to strings
(where :tags includes :urgent)   ; keyword "urgent" matches in ["urgent" "bug"]
```

**Coercion rules:**
- Keywords (atoms that are not booleans) coerce to their string representation
- `true` and `false` do **not** coerce (prevent `true` from matching `"true"`)
- Empty keyword `:""` coerces to empty string `""`
- Other types (`strings`, `numbers`, `nil`) are unchanged

**Note:** Ordering comparisons (`>`, `<`, `>=`, `<=`) do **not** use coercion. Type mismatches return `false` (same as `nil` handling).

### 7.2 Combining Predicates

Use `all-of`, `any-of`, `none-of` to combine predicate functions:

```clojure
;; ALL-OF - all predicates must match
(filter (all-of (where :status = "active")
                (where :age >= 18))
        users)

;; ANY-OF - at least one predicate must match
(filter (any-of (where :role = "admin")
                (where :role = "moderator"))
        users)

;; NONE-OF - no predicate must match (inverts)
(filter (none-of (where :deleted))
        items)

;; Complex combinations
(filter (all-of (where :status = "active")
                (any-of (where :role = "admin")
                        (where :premium))
                (none-of (where :banned)))
        users)
```

**Zero predicates:**

| Expression | Result |
|------------|--------|
| `(all-of)` | Always true (vacuous truth) |
| `(any-of)` | Always false (no predicate matches) |
| `(none-of)` | Always true (no predicate to fail) |

**Why not `and`/`or`/`not`?**

The logical operators `and`, `or`, `not` operate on **boolean values** and short-circuit. Predicate combinators `all-of`, `any-of`, `none-of` combine **predicate functions** into a new predicate function. Keeping them separate avoids confusion:

```clojure
;; WRONG - and returns last truthy value, not a combined predicate
(filter (and (where :a = 1) (where :b = 2)) coll)  ; BUG!

;; CORRECT - all-of returns a new predicate that checks both
(filter (all-of (where :a = 1) (where :b = 2)) coll)  ; OK
```

### 7.3 Membership Testing

Test if field value is in a set of values:

```clojure
(where :status in ["active" "pending"])
(where :category in ["travel" "food" "transport"])
```

Equivalent to: `(or (where :status = "active") (where :status = "pending"))`

**Variables in `in` clause:** The value can be a bound variable, not just a literal:

```clojure
;; Using a variable for the membership set
(let [premium-ids (->> users
                       (filter (where :tier = "premium"))
                       (pluck :id))]
  (filter (where :user-id in premium-ids) orders))
```

At eval time, `premium-ids` is resolved to its value before the predicate closure is created.

### 7.4 `where` Semantics

| Expression | True when |
|------------|-----------|
| `(where :f = v)` | `(= (get item :f) v)` |
| `(where :f not= v)` | `(not= (get item :f) v)` |
| `(where :f > v)` | `(> (get item :f) v)` |
| `(where :f < v)` | `(< (get item :f) v)` |
| `(where :f >= v)` | `(>= (get item :f) v)` |
| `(where :f <= v)` | `(<= (get item :f) v)` |
| `(where :f includes v)` | Value `v` is in field `f` (string substring or collection member) |
| `(where :f in [vs])` | Field value equals any value in list |
| `(where :f)` | Field is truthy (not `nil`, not `false`) |
| `(where [:a :b] op v)` | `(op (get-in item [:a :b]) v)` |

### 7.5 `where` Edge Cases

```clojure
; Missing field returns nil, comparisons handle gracefully
(where :missing = nil)     ; matches items without the field
(where :missing > 0)       ; false (nil > 0 is false inside where)

; nil handling
(where :field = nil)       ; explicitly match nil
(where :field not= nil)    ; field exists and is not nil
(where :field)             ; field is truthy (not nil, not false)
```

**`where` vs raw comparisons with nil:**

Inside `where`, ordering comparisons (`>`, `<`, `>=`, `<=`) with `nil` or missing fields return `false` instead of raising a type error. This enables safe filtering without pre-checking for nil:

```clojure
; INSIDE where: nil comparisons return false (safe for filtering)
(filter (where :age > 18) users)   ; users without :age are excluded, no error

; OUTSIDE where: nil comparisons are type errors
(> 5 nil)                          ; => TYPE ERROR
(< nil 10)                         ; => TYPE ERROR
```

This distinction exists because `where` is designed for safe filtering over potentially incomplete data, while raw comparisons should fail explicitly on invalid input.

**Flexible Key Access — String and Atom Keys:**

Field accessors in `where` and key-based functions (`sort-by`, `sum-by`, `avg-by`, `min-by`, `max-by`, `group-by`, `pluck`, `get`) support **bidirectional key matching**. This means:
- Atom keys in code (`:status`) match both atom and string keys in data
- String keys in code (`"status"`) match both string and atom keys in data

This makes it easy to work with data from various sources without preprocessing:

```clojure
; Atom keys (preferred Elixir style)
(filter (where :status = "active") users)

; String keys (from JSON APIs or LLM-generated code)
(filter (where :status = "active") data)
;; If data is %{"status" => "active"}, it will match!

; String key parameter also works (LLM compatibility)
(sort-by "price" products)   ; Works with both %{price: 10} and %{"price" => 10}
(sum-by "amount" expenses)   ; Same bidirectional matching

; Mixed: nested structure with different key types
(filter (where [:user :email] = "alice@example.com") items)
;; Matches both: %{user: %{"email" => ...}} and %{"user" => %{email: ...}}

; Atom key takes precedence when both exist
;; If a map has both :category and "category", the atom key wins
%{category: "priority", "category" => "ignored"}
;; (where :category = "priority") matches "priority", not "ignored"
```

**How it works:**
1. When looking up a field, the accessor tries the exact key type first
2. If not found, it falls back to the alternative type (atom↔string conversion)
3. When both exist, the exact key type takes precedence
4. This applies to nested fields too—each level independently tries exact match first, then fallback
5. Missing fields at any level still return `nil`

This design eliminates the need to manually convert JSON responses to atom-keyed maps before filtering, and provides resilience to LLM-generated code that may use strings instead of keywords.

---

## 8. Core Functions

### 8.1 Collection Operations

#### Filtering

| Function | Signature | Description |
|----------|-----------|-------------|
| `filter` | `(filter pred coll)` | Keep items where pred is truthy |
| `remove` | `(remove pred coll)` | Remove items where pred is truthy |
| `find` | `(find pred coll)` | First item where pred is truthy, or nil |

```clojure
(filter (where :active) users)
(remove (where :deleted) items)
(find (where :id = 42) users)
```

#### Transforming

| Function | Signature | Description |
|----------|-----------|-------------|
| `map` | `(map f coll)` | Apply f to each item |
| `mapv` | `(mapv f coll)` | Like map, returns vector |
| `select-keys` | `(select-keys map keys)` | Pick specific keys |
| `pluck` | `(pluck key coll)` | Extract single field from each item |

```clojure
(map :name users)                    ; extract :name from each
(mapv :name users)                   ; same, ensures vector
(select-keys user [:name :email])    ; pick keys from map
(pluck :name users)                  ; shorthand for (map :name coll)
```

**Note:** Since PTC-Lisp has no lazy sequences (see Section 13.1), `map` and `mapv` are functionally identical—both return vectors. `mapv` is provided for Clojure compatibility and to make intent explicit.

#### Ordering

| Function | Signature | Description |
|----------|-----------|-------------|
| `sort` | `(sort coll)` | Sort by natural order |
| `sort-by` | `(sort-by keyfn coll)` | Sort by extracted key |
| `sort-by` | `(sort-by keyfn comp coll)` | Sort with comparator |
| `reverse` | `(reverse coll)` | Reverse order |

**Sortable types:** Numbers and strings can be sorted. Numbers use numeric order; strings use lexicographic (alphabetical) order. Sorting mixed types or unsortable types (maps, nil) raises a type error.

```clojure
(sort [3 1 2])                ; => [1 2 3]
(sort ["b" "a" "c"])          ; => ["a" "b" "c"]
(sort-by :price products)     ; ascending by price
(sort-by :price > products)   ; descending by price
(sort-by :name products)      ; alphabetical by name
(sort-by first [["b" 2] ["a" 1] ["c" 3]])  ; => [["a" 1] ["b" 2] ["c" 3]]
(sort-by (fn [x] (nth x 1)) > [["a" 2] ["b" 1] ["c" 3]])  ; descending by second element
(reverse [1 2 3])             ; => [3 2 1]
```

**Note:** While `sort` and `sort-by` support string comparison internally, the explicit comparison operators (`>`, `<`, `>=`, `<=`) only work on numbers. This prevents ambiguous comparisons in user code while allowing natural sorting.

#### Subsetting

| Function | Signature | Description |
|----------|-----------|-------------|
| `first` | `(first coll)` | First item or nil |
| `second` | `(second coll)` | Second item or nil |
| `last` | `(last coll)` | Last item or nil |
| `nth` | `(nth coll idx)` | Item at index or nil |
| `take` | `(take n coll)` | First n items |
| `drop` | `(drop n coll)` | Skip first n items |
| `take-while` | `(take-while pred coll)` | Take while pred is true |
| `drop-while` | `(drop-while pred coll)` | Drop while pred is true |
| `distinct` | `(distinct coll)` | Remove duplicates |

```clojure
(first [1 2 3])       ; => 1
(first [])            ; => nil
(second [1 2 3])      ; => 2
(last [1 2 3])        ; => 3
(nth [1 2 3] 1)       ; => 2
(nth [1 2 3] 10)      ; => nil (out of bounds)
(take 2 [1 2 3 4])    ; => [1 2]
(drop 2 [1 2 3 4])    ; => [3 4]
(distinct [1 2 1 3])  ; => [1 2 3]
```

#### Combining

| Function | Signature | Description |
|----------|-----------|-------------|
| `concat` | `(concat coll1 coll2 ...)` | Join collections |
| `into` | `(into to from)` | Pour from into to |
| `flatten` | `(flatten coll)` | Flatten nested collections |
| `interleave` | `(interleave c1 c2)` | Interleave collections |
| `zip` | `(zip c1 c2)` | Combine into tuples |

```clojure
(concat [1 2] [3 4])       ; => [1 2 3 4]
(into [] [1 2 3])          ; => [1 2 3]
(flatten [[1 2] [3 [4]]])  ; => [1 2 3 4]
(zip [1 2] [:a :b])        ; => [[1 :a] [2 :b]]
```

#### Aggregation

| Function | Signature | Description |
|----------|-----------|-------------|
| `count` | `(count coll)` | Number of items |
| `reduce` | `(reduce f init coll)` | Fold collection |
| `sum-by` | `(sum-by key coll)` | Sum field values |
| `avg-by` | `(avg-by key coll)` | Average field values |
| `min-by` | `(min-by key coll)` | Item with minimum field |
| `max-by` | `(max-by key coll)` | Item with maximum field |
| `group-by` | `(group-by keyfn coll)` | Group items by key |

```clojure
(count [1 2 3])                   ; => 3
(reduce + 0 [1 2 3])              ; => 6
(sum-by :amount expenses)         ; sum of :amount fields
(avg-by :price products)          ; average of :price fields
(min-by :price products)          ; item with lowest price
(max-by :years employees)         ; item with highest years
(group-by :category products)     ; map of category -> items
(min-by first [["b" 2] ["a" 1]])  ; => ["a" 1] (item with minimum first element)
(max-by (fn [x] (nth x 1)) [["a" 2] ["b" 3]])  ; item with maximum second element
(sum-by (fn [x] (nth x 1)) [["a" 2] ["b" 3]])  ; => 5 (sum second elements)
(group-by first [["a" 1] ["a" 2] ["b" 3]])  ; {"a" [["a" 1] ["a" 2]], "b" [["b" 3]]}
```

#### Predicates on Collections

| Function | Signature | Description |
|----------|-----------|-------------|
| `empty?` | `(empty? coll)` | True if empty |
| `some` | `(some pred coll)` | First truthy result of pred, or nil |
| `every?` | `(every? pred coll)` | True if all match |
| `not-any?` | `(not-any? pred coll)` | True if none match |
| `contains?` | `(contains? coll key)` | True if key exists |

```clojure
(empty? [])                        ; => true
(some (where :admin) users)   ; any admins?
(every? (where :active) users); all active?
(contains? {:a 1} :a)              ; => true
(contains? {:a 1} :b)              ; => false
```

### 8.2 Map Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `get` | `(get m key)` | Get value by key |
| `get` | `(get m key default)` | Get with default |
| `get-in` | `(get-in m path)` | Get nested value |
| `get-in` | `(get-in m path default)` | Get nested with default |
| `assoc` | `(assoc m key val)` | Add/update key |
| `assoc-in` | `(assoc-in m path val)` | Add/update nested |
| `update` | `(update m key f)` | Update value with function |
| `update-in` | `(update-in m path f)` | Update nested with function |
| `dissoc` | `(dissoc m key)` | Remove key |
| `merge` | `(merge m1 m2 ...)` | Merge maps (later wins) |
| `select-keys` | `(select-keys m keys)` | Pick specific keys |
| `keys` | `(keys m)` | Get all keys |
| `vals` | `(vals m)` | Get all values |
| `update-vals` | `(update-vals m f)` | Apply f to each value (matches Clojure 1.11) |

```clojure
(get {:a 1} :a)                    ; => 1
(get {:a 1} :b "default")          ; => "default"
(get-in {:user {:name "A"}} [:user :name])  ; => "A"
(assoc {:a 1} :b 2)                ; => {:a 1 :b 2}
(assoc-in {} [:user :name] "Bob")  ; => {:user {:name "Bob"}}
(update {:n 1} :n inc)             ; => {:n 2}
(dissoc {:a 1 :b 2} :b)            ; => {:a 1}
(merge {:a 1} {:b 2} {:a 3})       ; => {:a 3 :b 2}
(select-keys {:a 1 :b 2 :c 3} [:a :c])  ; => {:a 1 :c 3}
(keys {:a 1 :b 2})                 ; => [:a :b]
(vals {:a 1 :b 2})                 ; => [1 2]

;; update-vals: apply function to each value (matches Clojure 1.11)
(update-vals {:a 1 :b 2} inc)      ; => {:a 2 :b 3}

;; Common pattern: count items per group after group-by
;; Note: Use -> (not ->>) since map is first argument
(-> orders
    (group-by :status)
    (update-vals count))           ; => {"pending" 2 "done" 3}
```

### 8.3 Arithmetic

| Function | Signature | Description |
|----------|-----------|-------------|
| `+` | `(+ x y ...)` | Addition |
| `-` | `(- x y ...)` | Subtraction |
| `*` | `(* x y ...)` | Multiplication |
| `/` | `(/ x y)` | Division |
| `mod` | `(mod x y)` | Modulo |
| `inc` | `(inc x)` | Add 1 |
| `dec` | `(dec x)` | Subtract 1 |
| `abs` | `(abs x)` | Absolute value |
| `max` | `(max x y ...)` | Maximum value |
| `min` | `(min x y ...)` | Minimum value |

**Division behavior:** The `/` operator always returns a float, even for exact divisions. Integer division (`quot`) is not supported. Division by zero raises an execution error.

```clojure
(+ 1 2 3)       ; => 6
(- 10 3)        ; => 7
(* 2 3 4)       ; => 24
(/ 10 2)        ; => 5.0
(/ 10 3)        ; => 3.333...
(mod 10 3)      ; => 1
(inc 5)         ; => 6
(dec 5)         ; => 4
(abs -5)        ; => 5
(max 1 5 3)     ; => 5
(min 1 5 3)     ; => 1
```

### 8.4 Comparison

| Function | Signature | Description |
|----------|-----------|-------------|
| `=` | `(= x y)` | Equality |
| `not=` | `(not= x y)` | Inequality |
| `<` | `(< x y)` | Less than |
| `>` | `(> x y)` | Greater than |
| `<=` | `(<= x y)` | Less or equal |
| `>=` | `(>= x y)` | Greater or equal |

**Note:** Comparison operators in PTC-Lisp are strictly 2-arity. Chained comparisons like `(< 1 2 3)` are **not supported**. Use `and` to combine comparisons: `(and (< 1 2) (< 2 3))`.

```clojure
(= 1 1)         ; => true
(= 1 2)         ; => false
(not= 1 2)      ; => true
(< 1 2)         ; => true
(> 3 2)         ; => true
(<= 1 1)        ; => true
(>= 3 2)        ; => true
```

### 8.5 Logic

| Function | Signature | Description |
|----------|-----------|-------------|
| `and` | `(and x y ...)` | Logical AND (short-circuits) |
| `or` | `(or x y ...)` | Logical OR (short-circuits) |
| `not` | `(not x)` | Logical NOT |

```clojure
(and true true)     ; => true
(and true false)    ; => false
(and nil "x")       ; => nil (short-circuits)
(or false true)     ; => true
(or nil false "x")  ; => "x" (returns first truthy)
(not true)          ; => false
(not nil)           ; => true
```

### 8.6 Type Predicates

| Function | Description |
|----------|-------------|
| `nil?` | Is nil? |
| `some?` | Is not nil? |
| `boolean?` | Is boolean? |
| `number?` | Is number? |
| `string?` | Is string? |
| `keyword?` | Is keyword? |
| `vector?` | Is vector? |
| `map?` | Is map? |
| `set?` | Is set? |
| `coll?` | Is collection? (vectors only, not maps or strings) |

**Note:** In PTC-Lisp, `coll?` returns `true` only for vectors (and any future sequence types). Maps and strings are not considered collections by `coll?`. This affects functions like `flatten` which only flatten values where `coll?` is true.

**Collection Functions on Maps and Strings:**

Although maps and strings are not "collections" per `coll?`, some collection functions still work on them:

| Function | Maps | Strings | Notes |
|----------|------|---------|-------|
| `count` | ✓ | ✓ | Returns key count / character count |
| `empty?` | ✓ | ✓ | True if no keys / no characters |
| `first` | ✗ | ✗ | Use `(first (keys m))` or `(first (vals m))` |
| `last` | ✗ | ✗ | Use `(last (keys m))` or `(last (vals m))` |
| `map` | ✗ | ✗ | Use `(map f (vals m))` or `(map f (keys m))` |
| `filter` | ✗ | ✗ | Not applicable to maps/strings |
| `nth` | ✗ | ✗ | String indexing not supported |

To iterate over maps, extract keys or values first:
```clojure
(->> (keys my-map)
     (map (fn [k] {:key k :val (get my-map k)})))
```

### 8.7 Numeric Predicates

| Function | Description |
|----------|-------------|
| `zero?` | Is zero? |
| `pos?` | Is positive? |
| `neg?` | Is negative? |
| `even?` | Is even? |
| `odd?` | Is odd? |

**Integer predicates on floats:** The predicates `even?` and `odd?` require integers. Passing a float raises a `type-error`, even if the float represents a whole number:

```clojure
(even? 4)      ; => true
(even? 4.0)    ; => TYPE ERROR (float, not integer)
(odd? 3)       ; => true
(odd? 3.0)     ; => TYPE ERROR (float, not integer)
```

Since division always returns floats (see Section 8.3), avoid using `even?`/`odd?` on division results. Use `mod` instead:

```clojure
;; Check if x is divisible by 2
(zero? (mod x 2))    ; works for integers
```

---

## 9. Namespaces, Context, and Tools

Programs have access to data and functions through **namespaced symbols** and **special forms**.

### 9.1 Namespace Overview

| Namespace | Access Pattern | Description |
|-----------|----------------|-------------|
| `memory/` | Read via symbol | Persistent state across turns |
| `ctx/` | Read via symbol | Current request context (read-only) |
| `(call ...)` | Function call | Tool invocation |

### 9.2 Memory Access — `memory/`

Read from persistent memory using the `memory/` namespace prefix:

```clojure
memory/high-paid          ; get :high-paid from memory
memory/orders             ; get :orders from memory
memory/query-count        ; get :query-count from memory
```

Memory values are **read-only during execution**. To update memory, return a map (see Section 16).

```clojure
;; Read previous results, compute new value, return delta
(let [prev-orders memory/orders
      new-orders (call "get-orders" {:since "2024-01-01"})]
  {:orders (concat prev-orders new-orders)})
```

With default values (using `or`):

```clojure
(let [count (or memory/query-count 0)]
  {:query-count (inc count)})
```

### 9.3 Context Access — `ctx/`

Read from current request context using the `ctx/` namespace prefix:

```clojure
ctx/input                 ; get :input from context
ctx/user-id               ; get :user-id from context
ctx/request-id            ; get :request-id from context
```

Context is **per-request** data passed by the host. It does not persist across turns.

```clojure
(->> ctx/expenses
     (filter (where :category = "travel"))
     (sum-by :amount))
```

### 9.4 Tool Invocation — `call`

Call registered tools using the `call` function:

```clojure
(call tool-name)
(call tool-name args-map)
```

**Important:** `tool-name` MUST be a string literal. Using symbols, keywords, or other types is a type error:

```clojure
(call "get-users")                       ; OK - string literal
(call get-users)                         ; TYPE ERROR - symbol not allowed
(call :get-users)                        ; TYPE ERROR - keyword not allowed
```

```clojure
(call "get-users")                       ; no arguments
(call "get-expenses" {:year 2024})       ; with arguments
(call "search" {:query "foo" :limit 10})

;; Store tool result for later use
(let [users (call "get-users")]
  (->> users
       (filter (where :active))
       (count)))
```

**Tool behavior:**
- Tools are Elixir functions registered by the host
- Tools may have side effects (external API calls, database queries)
- Tool errors propagate as execution errors
- Tool calls are logged for auditing

---

## 10. Complete Examples

### 10.1 Filter and Sum (Pure Query)

Filter expenses by category and sum amounts:

```clojure
(->> ctx/expenses
     (filter (where :category = "travel"))
     (sum-by :amount))
```

Returns a number. No memory update (non-map result).

### 10.2 Find Single Item

Find the cheapest product:

```clojure
(min-by :price ctx/products)
```

Find employee with most years:

```clojure
(max-by :years-employed ctx/employees)
```

### 10.3 Sort and Limit

Get top 5 products by price:

```clojure
(->> ctx/products
     (sort-by :price >)
     (take 5))
```

### 10.4 Extract Field Values

Get all product names:

```clojure
(pluck :name ctx/products)
;; or
(map :name ctx/products)
```

### 10.5 Conditional Classification

Classify invoice by total:

```clojure
(let [{:keys [total]} ctx/invoice]
  (cond
    (> total 1000) "high-value"
    (> total 100)  "medium-value"
    :else          "low-value"))
```

### 10.6 Complex Filtering

Find eligible orders (high value, premium status, not flagged):

```clojure
(->> ctx/orders
     (filter (all-of (where :total > 100)
                     (any-of (where :status = "vip")
                             (where :status = "premium"))
                     (none-of (where :flagged)))))
```

### 10.7 Transform and Select Fields

Get names and emails of active users:

```clojure
(->> ctx/users
     (filter (where :active))
     (mapv (fn [u] (select-keys u [:name :email]))))
```

### 10.8 Combine Multiple Data Sources

Join orders with user information:

```clojure
(let [users (call "get-users")
      orders (call "get-orders")]
  (->> orders
       (filter (where :total > 100))
       (mapv (fn [order]
               (let [user (find (where :id = (:user-id order)) users)]
                 (merge order (select-keys user [:name :email])))))))
```

### 10.9 Grouping and Aggregation

Sum expenses by category:

```clojure
(let [by-category (group-by :category ctx/expenses)]
  (->> (keys by-category)
       (mapv (fn [cat]
               {:category cat
                :total (sum-by :amount (get by-category cat))}))))
```

### 10.10 Nested Data Access

Get email from nested user profile:

```clojure
(get-in ctx/user [:profile :contact :email])
```

Filter by nested field:

```clojure
(->> ctx/users
     (filter (where [:profile :verified] = true)))
```

---

## 11. Semantics and Edge Cases

### 11.1 Empty Collections

| Operation | Empty Input | Result |
|-----------|-------------|--------|
| `(count [])` | `[]` | `0` |
| `(first [])` | `[]` | `nil` |
| `(last [])` | `[]` | `nil` |
| `(sum-by :x [])` | `[]` | `0` |
| `(avg-by :x [])` | `[]` | `nil` |
| `(min-by :x [])` | `[]` | `nil` |
| `(max-by :x [])` | `[]` | `nil` |
| `(filter pred [])` | `[]` | `[]` |
| `(sort-by :x [])` | `[]` | `[]` |

### 11.2 Nil Handling

```clojure
;; Accessing missing key returns nil
(get {:a 1} :b)              ; => nil
(:b {:a 1})                  ; => nil
(get-in {:a {:b 1}} [:a :c]) ; => nil

;; Arithmetic with nil is a type error
(+ 1 nil)                    ; => TYPE ERROR

;; Equality with nil is allowed
(= nil nil)                  ; => true
(= 5 nil)                    ; => false
(nil? nil)                   ; => true

;; Ordering comparisons with nil are type errors
(> 5 nil)                    ; => TYPE ERROR
(< nil 10)                   ; => TYPE ERROR

;; filter/map handle nil gracefully
(filter (where :x = nil) [{:x nil} {:x 1}])  ; => [{:x nil}]
```

### 11.3 Type Errors in Comparisons

Ordering comparisons (`>`, `<`, `>=`, `<=`) are only defined for numbers:

```clojure
;; Valid
(> 5 3)                      ; => true
(< 1.5 2.0)                  ; => true

;; Type errors
(> "a" "b")                  ; => TYPE ERROR (strings not orderable via >)
(< {:a 1} {:b 2})            ; => TYPE ERROR (maps not orderable)
(>= 5 nil)                   ; => TYPE ERROR (nil not orderable)
```

**Note on sorting:** While explicit comparison operators reject strings, the `sort` and `sort-by` functions use internal comparison that supports both numbers and strings. This design prevents ambiguous user-written comparisons while enabling natural sorting:

```clojure
;; These work (internal comparison)
(sort ["b" "a" "c"])         ; => ["a" "b" "c"]
(sort-by :name users)        ; sorts alphabetically

;; This fails (explicit comparison)
(> "bob" "alice")            ; => TYPE ERROR
```

### 11.4 Aggregation with Missing/Nil Fields

```clojure
;; sum-by skips nil/missing fields
(sum-by :amount [{:amount 10} {:amount nil} {:other 5}])  ; => 10

;; avg-by skips nil/missing (not counted in denominator)
(avg-by :amount [{:amount 10} {:amount nil} {:amount 20}])  ; => 15.0

;; min-by/max-by skip nil values
(min-by :price [{:price nil} {:price 10} {:price 5}])  ; => {:price 5}
```

### 11.5 Non-Numeric Aggregation Fields

Aggregation functions require numeric field values:

```clojure
;; Type error - string in numeric aggregation
(sum-by :amount [{:amount "10"} {:amount 20}])  ; => TYPE ERROR

;; Type error - map in numeric aggregation
(avg-by :value [{:value {:x 1}}])              ; => TYPE ERROR
```

**Rule:** If a field exists and is not `nil` but is non-numeric, aggregation functions raise a type error. Only `nil` and missing fields are silently skipped.

### 11.6 Short-Circuit Evaluation

`and` and `or` short-circuit:

```clojure
(and false (call "expensive"))  ; "expensive" not called
(or true (call "expensive"))    ; "expensive" not called
```

### 11.7 Keyword as Function with Default

```clojure
(:name {:name "Alice"})           ; => "Alice"
(:name {})                        ; => nil
(:name {} "Unknown")              ; => "Unknown"
```

### 11.8 Flatten Behavior

`flatten` recursively flattens nested collections:

```clojure
(flatten [[1 2] [3 [4]]])         ; => [1 2 3 4]
(flatten [1 [2 {:a 3}] "str"])    ; => [1 2 {:a 3} "str"]
```

- Only vectors are flattened (they satisfy `coll?`)
- Maps, strings, and other non-collection values pass through unchanged
- Flattening depth is bounded by `max_depth` limit

### 11.9 Tool Call Evaluation Order

Tool calls are evaluated in left-to-right order and never reordered:

```clojure
(let [a (call "tool-1")    ; called first
      b (call "tool-2")]   ; called second
  [a b])
```

This matters because tools may have side effects. The interpreter guarantees:
- Arguments evaluated left-to-right
- Tool calls execute in program order
- No speculative or parallel execution

---

## 12. Error Handling

Errors are represented as tagged tuples: `{:error, {error_type, details}}`. The error type is an atom, and details vary by error type (usually a message string, but may include additional context like expected/got values for type errors). Examples:

```elixir
{:error, {:parse_error, "unexpected token at line 3"}}
{:error, {:validation_error, "unknown function: foo"}}
{:error, {:type_error, "expected number", "got string"}}
{:error, {:execution_error, "tool 'get-users' failed"}}
{:error, {:timeout, 5000}}
{:error, {:memory_exceeded, 10_000_000}}
```

The formatted strings shown below are human-readable renderings for display to users or LLMs.

### 12.1 Error Types

| Error Type | Cause |
|------------|-------|
| `parse-error` | Invalid syntax |
| `validation-error` | Invalid program structure |
| `type-error` | Wrong argument type |
| `arity-error` | Wrong number of arguments |
| `undefined-error` | Unknown function/symbol |
| `execution-error` | Runtime error |
| `timeout` | Execution time exceeded |
| `memory-exceeded` | Memory limit exceeded |

### 12.2 Error Message Format

Errors should include location and context when available. Source location tracking (line/column) is recommended but optional for v1 implementations—at minimum, errors must include the error type and a descriptive message.

```
parse-error at line 3, column 15:
  (filter (where :status "active") coll)
                 ^
  Expected operator (=, >, <, >=, <=, not=, includes, in)
  after field name in 'where' expression.

  Hint: Use (where :status = "active") for equality comparison.
```

```
type-error at line 5:
  (sum-by :amount items)

  'sum-by' expected a collection, got string: "not a list"

  Context: items was bound at line 2:
    (let [items ctx/data] ...)
```

### 12.3 Common Errors and Hints

| Error | Hint |
|-------|------|
| Unknown symbol `foo` | Did you mean: `filter`, `first`, `find`? |
| `where` missing operator | Use `(where :field = value)`, not `(where :field value)` |
| Wrong arity for `if` | `if` requires exactly 3 arguments (condition, then, else) |
| `let` bindings not paired | `let` requires an even number of binding forms |

---

## 13. What Is NOT Supported

### 13.1 Language Features

| Feature | Reason |
|---------|--------|
| `def`, `defn` | No global definitions |
| `#()` | Short fn syntax excluded (see 13.2 for `fn`) |
| `loop`, `recur` | No unbounded recursion |
| `lazy-seq` | All operations are eager |
| Macros | No metaprogramming |
| Namespaces (user-defined) | Single expression, no modules |
| Java interop | Security |
| Atoms, refs, agents | No mutable state |
| `eval`, `read-string` | Security |
| I/O (`println`, `slurp`) | Security |
| Regex | Complexity (use tools) |
| Multi-methods, protocols | Complexity |

### 13.2 Anonymous Functions

Anonymous functions are supported via `fn` with restrictions:

```clojure
(fn [x] body)           ; single argument
(fn [a b] body)         ; multiple arguments
(fn [[a b]] body)       ; vector destructuring in params
(fn [{:keys [x]}] body) ; map destructuring in params
```

**Restrictions:**
- No recursion within `fn` (no self-reference)
- No `#()` short syntax (simplifies parsing)
- Closures over local `let` bindings are allowed
- No closures over mutable host state (there is none)

**Examples:**
```clojure
;; Transform each item
(mapv (fn [u] (select-keys u [:name :email])) users)

;; Access outer let bindings (closure)
(let [threshold 100]
  (filter (fn [x] (> (:price x) threshold)) products))

;; Multiple arguments with reduce
(reduce (fn [acc x] (+ acc (:amount x))) 0 items)

;; Destructuring in fn params (now supported)
(mapv (fn [{:keys [name age]}] {:name name :years age}) users)
```

**When to use `fn` vs `where`:**
- Use `where` for simple field comparisons in `filter`/`remove`/`find`
- Use `fn` when you need complex transformations or access to multiple fields

### 13.3 Functions Excluded from Core

- String manipulation: `str`, `subs`, `split`, `join`, `upper-case`, etc.
- Regex: `re-find`, `re-matches`, `re-seq`
- `range` (infinite sequences)
- `iterate`, `repeat`, `cycle` (infinite sequences)
- `partial`, `comp`, `juxt` (function composition)
- Transducers

---

## 14. Grammar (EBNF)

```ebnf
program     = expression ;

expression  = literal
            | symbol
            | keyword
            | vector
            | set
            | map
            | list-expr ;

literal     = nil | boolean | number | string ;

nil         = "nil" ;
boolean     = "true" | "false" ;
number      = integer | float ;
integer     = ["-"] digit+ ;
float       = ["-"] digit+ "." digit+ [exponent] ;
exponent    = ("e" | "E") ["+" | "-"] digit+ ;
string      = '"' string-char* '"' ;
string-char = escape-seq | (any char except '"', '\', and newline) ;
escape-seq  = '\\' ('"' | '\\' | 'n' | 't' | 'r') ;

symbol      = symbol-first symbol-rest* ;
symbol-first = letter | special-initial ;
symbol-rest  = letter | digit | special-rest ;
letter      = "a"-"z" | "A"-"Z" ;
digit       = "0"-"9" ;
special-initial = "+" | "-" | "*" | "/" | "<" | ">" | "=" | "?" | "!" ;
special-rest    = special-initial | "-" | "_" | "/" ;

keyword     = ":" keyword-char+ ;
keyword-char = letter | digit | "-" | "_" | "?" | "!" ;  (* no "/" in keywords *)

vector      = "[" expression* "]" ;

set         = "#{" expression* "}" ;

map         = "{" (map-entry)* "}" ;
map-entry   = expression expression ;

list-expr   = "(" expression expression* ")" ;  (* operator can be any expression *)

comment     = ";" (any char except newline)* newline ;

whitespace  = " " | "\t" | "\n" | "\r" | "," ;
```

**Grammar notes:**
- `/` is allowed in symbols for namespaced access (`memory/foo`, `ctx/bar`)
- `/` is NOT allowed in keywords (`:foo/bar` is invalid)
- The operator position in `list-expr` accepts any expression, enabling:
  - `(:name user)` — keyword as function
  - `((fn [x] x) 42)` — anonymous function application
  - `(call "tool" args)` — normal function calls

**Tokenization precedence:** When a token could match multiple grammar rules, literals take precedence over symbols:
1. `nil`, `true`, `false` → reserved literals (not symbols)
2. `-123`, `3.14` → numbers (not symbols starting with `-` or digits)
3. `:foo` → keyword
4. Everything else → symbol

This means `-1` is always the integer negative one, never a symbol named "-1".

---

## 15. Implementation Notes

### 15.1 Evaluation Model

- Programs are single expressions
- Evaluation is strict (eager), not lazy
- No side effects except tool calls
- Tools may have side effects (external)

### 15.2 Resource Limits

| Resource | Default | Notes |
|----------|---------|-------|
| Timeout | 5,000 ms | Execution time limit |
| Max Heap | ~10 MB | Memory limit |
| Max Depth | 50 | Nesting depth limit |

*Note: The 5,000 ms default accommodates tool calls in agentic loops. Hosts may configure lower limits for pure computation.*

### 15.3 Compatibility Testing

Programs should produce identical results when run in:
1. PTC-Lisp interpreter (Elixir)
2. Clojure (with stub implementations for `memory/`, `ctx/`, `call`, `where`, etc.)

---

## 16. Memory Model for Agentic Loops

This section specifies how PTC-Lisp programs interact with persistent memory across multiple turns in an LLM-agent loop.

### 16.1 Core Principle: Functional Transactions

Programs are **pure functions** that:
- Read from `memory/` and `ctx/` namespaces
- Return a result value
- The result determines memory updates

This provides **transactional semantics**: either the entire program succeeds and memory updates, or it fails and memory remains unchanged.

### 16.2 Environment Structure

The host builds an execution environment for each program:

```elixir
%{
  memory: %{                    # Persistent across turns
    high_paid: [...],
    query_count: 5,
    ...
  },
  ctx: %{                       # Current request only
    input: [...],
    user_id: "user-123",
    request_id: "req-456",
    ...
  },
  tools: %{                     # Registered tool functions
    "get-users" => &Host.get_users/1,
    "get-orders" => &Host.get_orders/1,
    ...
  },
  __meta__: %{                  # Execution metadata (not exposed to DSL)
    call_id: "uuid-...",
    turn: 3,
    retry_count: 0,
    timestamp: ~U[2024-01-15 10:30:00Z],
    limits: %{max_tool_calls: 10, timeout_ms: 5000}
  }
}
```

### 16.3 Result Contract

The program's return value determines memory behavior:

| Return Value | Memory Behavior | Use Case |
|--------------|-----------------|----------|
| Non-map value | No memory change | Pure queries |
| Map without `:result` | Entire map merged into memory | Update memory only |
| Map with `:result` | Map (minus `:result`) merged into memory; `:result` returned to caller | Update memory AND return value |

**Reserved key:** `:result` is reserved at the top level of return maps. It controls the return value and is never persisted to memory. Do not use `:result` as a memory key name—use alternatives like `:query-result`, `:computation-result`, or `:output`.

#### Case 1: Pure Query (No Memory Update)

```clojure
;; Returns a number - memory unchanged
(->> ctx/expenses
     (filter (where :category = "travel"))
     (sum-by :amount))
```

#### Case 2: Memory Update Only

```clojure
;; Returns a map - merged into memory
(let [high-paid (->> (call "find-employees" {})
                     (filter (where :salary > 100000)))]
  {:high-paid high-paid
   :last-query "employees"})
```

After execution:
- `memory/high-paid` = the filtered list
- `memory/last-query` = `"employees"`
- Return value to caller = the same map

#### Case 3: Memory Update AND Return Value

```clojure
;; Returns map with :result - memory updated, :result returned
(let [high-paid (->> (call "find-employees" {})
                     (filter (where :salary > 100000)))]
  {:result (pluck :email high-paid)   ; returned to caller
   :high-paid high-paid})              ; merged into memory
```

After execution:
- `memory/high-paid` = the filtered list
- Return value to caller = `["alice@example.com", "bob@example.com", ...]`

#### Returning a Map Without Memory Update

If you want to return a map to the caller without updating memory, wrap it in `:result`:

```clojure
;; Return a map structure but don't persist anything
{:result {:summary "Query complete"
          :count (count ctx/items)
          :items ctx/items}}
```

After execution:
- Memory unchanged
- Return value = `{:summary "Query complete", :count 5, :items [...]}`

### 16.4 Memory Merge Semantics

Memory updates use **shallow merge**:

```clojure
;; Before: memory = {:a 1, :b {:x 10}}
;; Program returns: {:b {:y 20}, :c 3}
;; After:  memory = {:a 1, :b {:y 20}, :c 3}
```

- New keys are added
- Existing keys are replaced (not deep-merged)
- Keys not in the result are preserved
- To delete a key, explicitly set it to `nil`

### 16.5 Execution Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  AGENTIC LOOP EXECUTION FLOW                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. HOST BUILDS ENVIRONMENT                                     │
│     ├─ Load persistent memory from store                        │
│     ├─ Attach current request context                           │
│     └─ Register available tools                                 │
│                                                                 │
│  2. RECEIVE PROGRAM FROM LLM                                    │
│     └─ Parse source → AST                                       │
│                                                                 │
│  3. EXECUTE IN SANDBOX                                          │
│     ├─ Validate AST                                             │
│     ├─ Evaluate with resource limits                            │
│     └─ Track tool calls for logging                             │
│                                                                 │
│  4. HANDLE RESULT                                               │
│     │                                                           │
│     ├─ ON SUCCESS:                                              │
│     │   ├─ Apply result contract (see 16.3)                     │
│     │   ├─ Commit memory delta to persistent store              │
│     │   ├─ Log: program, tool calls, memory delta, result       │
│     │   └─ Return result to LLM/caller                          │
│     │                                                           │
│     └─ ON ERROR:                                                │
│         ├─ NO memory changes (rollback)                         │
│         ├─ Log: program, error, partial trace                   │
│         └─ Return error to LLM for retry                        │
│                                                                 │
│  5. NEXT TURN                                                   │
│     ├─ Feed memory summary to LLM                               │
│     └─ LLM generates next program                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 16.6 Multi-Turn Example

**Turn 1:** Find high-paid employees and store in memory

```clojure
{:high-paid (->> (call "find-employees" {})
                 (filter (where :salary > 100000)))}
```

*Memory after:* `{:high-paid [{:id 1, :name "Alice", :salary 150000}, ...]}`

**Turn 2:** Query stored data (no memory change)

```clojure
{:result (count memory/high-paid)}
```

*Returns:* `5`
*Memory unchanged*

**Turn 3:** Fetch orders for stored employees, update memory

```clojure
(let [ids (pluck :id memory/high-paid)
      orders (call "get-orders" {:employee-ids ids})]
  {:orders orders
   :order-count (count orders)})
```

*Memory after:* `{:high-paid [...], :orders [...], :order-count 42}`

**Turn 4:** Return summary and update query count

```clojure
(let [prev-count (or memory/query-count 0)]
  {:result {:employee-count (count memory/high-paid)
            :order-count memory/order-count}
   :query-count (inc prev-count)})
```

*Returns:* `{:employee-count 5, :order-count 42}`
*Memory after:* `{:high-paid [...], :orders [...], :order-count 42, :query-count 1}`

### 16.7 Logging and Audit Trail

Every execution produces a log entry:

```elixir
%{
  call_id: "uuid-...",
  turn: 3,
  timestamp: ~U[2024-01-15 10:30:00Z],

  # Input
  program_source: "(let [ids (pluck :id memory/high-paid)] ...)",
  memory_before: %{high_paid: [...]},
  ctx: %{user_id: "user-123"},

  # Execution trace
  tool_calls: [
    %{tool: "get-orders", args: %{employee_ids: [1, 2, 3]},
      result_size: 42, duration_ms: 150}
  ],

  # Output
  status: :success,  # or :error
  result: %{orders: [...], order_count: 42},
  memory_delta: %{orders: [...], order_count: 42},
  memory_after: %{high_paid: [...], orders: [...], order_count: 42},

  # Metrics
  duration_ms: 180,
  memory_bytes: 102400
}
```

### 16.8 Resource Limits for Agentic Execution

| Limit | Default | Description |
|-------|---------|-------------|
| `timeout_ms` | 5,000 | Max execution time per program |
| `max_heap` | ~10 MB | Memory limit |
| `max_tool_calls` | 10 | Max tool invocations per program |
| `max_depth` | 50 | Max AST nesting depth |
| `max_memory_size` | ~1 MB | Max size of memory after update |

On limit violation:
- Execution aborts immediately
- No memory changes (transaction rollback)
- Error returned to LLM with limit details
- LLM can retry with a modified program

### 16.9 Error Handling in Agentic Loops

Errors are designed to be **LLM-recoverable**:

```elixir
# Error structure
{:error, %{
  type: :tool_call_limit_exceeded,
  message: "Program made 12 tool calls, limit is 10",
  context: %{
    limit: 10,
    actual: 12,
    last_tool: "get-orders"
  },
  hint: "Consider batching requests or filtering data before tool calls"
}}
```

The LLM receives this error and can generate a corrected program.

### 16.10 Security Considerations

| Concern | Mitigation |
|---------|------------|
| Memory exhaustion | Max memory size limit |
| Infinite loops | Timeout + no recursion |
| Tool abuse | Per-program tool call limit |
| Data exfiltration | Tools are host-controlled, audited |
| Memory pollution | Shallow merge, explicit keys only |
| Cross-turn attacks | Memory is agent-scoped, not shared |

---

## Appendix A: JSON DSL to PTC-Lisp Migration

| JSON DSL | PTC-Lisp |
|----------|----------|
| `{"op": "literal", "value": 42}` | `42` |
| `{"op": "load", "name": "x"}` | `ctx/x` |
| `{"op": "var", "name": "x"}` | `x` (let-bound) or `memory/x` (persistent) |
| `{"op": "pipe", "steps": [...]}` | `(->> ...)` |
| `{"op": "filter", "where": ...}` | `(filter pred coll)` |
| `{"op": "eq", "field": "f", "value": v}` | `(where :f = v)` |
| `{"op": "gt", "field": "f", "value": v}` | `(where :f > v)` |
| `{"op": "sum", "field": "f"}` | `(sum-by :f coll)` |
| `{"op": "count"}` | `(count coll)` |
| `{"op": "first"}` | `(first coll)` |
| `{"op": "get", "path": ["a", "b"]}` | `(get-in m [:a :b])` |
| `{"op": "let", "name": "x", ...}` | `(let [x ...] ...)` |
| `{"op": "if", ...}` | `(if cond then else)` |
| `{"op": "call", "tool": "t"}` | `(call "t")` |
| `{"op": "and", "conditions": [...]}` | `(and ...)` |
| `{"op": "merge", "objects": [...]}` | `(merge ...)` |

---

## Appendix B: Symbol Resolution

### Resolution Order

When the interpreter encounters a symbol, it resolves in this order:

1. **Local bindings** — `let`-bound variables in current scope
2. **Namespaced symbols** — `memory/x`, `ctx/y`
3. **Built-in functions** — `filter`, `map`, `count`, etc.

### Namespace Symbols

| Pattern | Resolves To |
|---------|-------------|
| `memory/foo` | `(get env.memory :foo)` |
| `ctx/bar` | `(get env.ctx :bar)` |
| `foo` | Local binding or built-in |

### Example

```clojure
(let [x 10]                    ; x is local
  (+ x                         ; resolves to local x (10)
     memory/x                  ; resolves to env.memory[:x]
     ctx/x))                   ; resolves to env.ctx[:x]
```

### Whole Map Access

The bare symbols `memory` and `ctx` are **not accessible** as whole maps. Only namespaced access is allowed:

```clojure
memory/foo     ; OK - access :foo key
ctx/bar        ; OK - access :bar key
memory         ; ERROR - cannot access whole memory map
ctx            ; ERROR - cannot access whole ctx map
(keys memory)  ; ERROR - memory is not a value
```

This restriction prevents accidental data leakage and simplifies reasoning about what data a program can access.
