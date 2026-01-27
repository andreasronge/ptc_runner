# PTC-Lisp Language Specification

---

## 1. Overview

PTC-Lisp is a small, safe, deterministic subset of Clojure designed for Programmatic Tool Calling. Programs are expressions that transform data through pipelines of operations. Multiple top-level expressions are supported with implicit `do` semantics.

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

### Clojure Extensions

PTC-Lisp extends standard Clojure with features designed for data transformation in agentic contexts. These are **not valid Clojure** but provide significant utility for LLM-generated programs:

| Extension | Description |
|-----------|-------------|
| Implicit `do` | Multiple expressions in `fn`, `let`, `when`, `when-let` bodies (§5, §13.2) |
| `data/path`, `tool/name` | Namespace-qualified access to context data and tool invocation (§9) |
| `*1`, `*2`, `*3` | Turn history symbols for accessing previous results (§9.4) |
| `where`, `all-of`, `any-of`, `none-of` | Predicate builders for filtering (§7) |
| `sum-by`, `avg-by`, `min-by`, `max-by`, `distinct-by` | Collection aggregators (§8) |
| `min-key`, `max-key` | Clojure-compatible variadic key comparison (§8) |
| `re-pattern` | Compile string to regex without literal syntax (§8.8) |
| `pluck` | Extract field values from collections (§8) |
| `floor`, `ceil`, `round`, `trunc` | Integer rounding |
| `float`, `double`, `int` | Type coercion (to float / to integer) |
| `call` | Tool invocation special form (§9) |
| Keyword/string coercion in `where` | `:status = :active` matches `"active"` (§7.6) |
| Path-based `where` | `(where [:user :role] = :admin)` for nested access (§7.1) |

All other syntax and functions are valid Clojure and are tested against Babashka for conformance.

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

Note: `/` appears in both `special-initial` (for the division operator) and `special-rest` (for namespaced symbols like `data/bar` or `tool/search`).

Valid symbols: `filter`, `map`, `sort-by`, `empty?`, `+`, `->>`, `high-paid`, `data/bar`, `tool/search`

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

**Special Values (IEEE 754)** — namespaced constants:
```clojure
Double/POSITIVE_INFINITY    ; => ##Inf
Double/NEGATIVE_INFINITY    ; => ##-Inf
Double/NaN                  ; => ##NaN (Not a Number)
```

Special values are returned by operations like division by zero (`(/ 1.0 0.0)`) or indeterminate forms (`(/ 0.0 0.0)`). They are formatted using Clojure's reader syntax (`##Inf`, `##NaN`) but evaluate to their respective symbolic representations.

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

**Not supported:** Multi-line strings, regex literals (use `re-pattern` instead).

**String operations:** Strings support `count`, `empty?`, `seq`, `str`, `subs`, `join`, `split`, `trim`, `replace`, `re-find`, and `re-matches`. The `seq` function converts a string to a sequence of characters (graphemes), enabling character iteration. See Section 8.3 and 8.8 for details.

**String as sequence:** Strings can be used as sequences in many collection operations. Functions like `filter`, `map`, `first`, `last`, `take`, `drop`, `reverse`, `sort`, and others work directly on strings, treating them as sequences of characters (graphemes). These operations return lists of single-character strings:

```clojure
(first "hello")                    ; => "h"
(filter #(= \e %) "hello")         ; => ["e"]
(map identity "abc")               ; => ["a" "b" "c"]
(take 2 "hello")                   ; => ["h" "e"]
(count (filter #(= \r %) "raspberry"))  ; => 3
```

### 3.5 Character Literals

Character literals provide a concise syntax for single-character strings, using Clojure's backslash notation:

```clojure
\a          ; => "a"
\Z          ; => "Z"
\5          ; => "5"
\λ          ; => "λ" (Unicode supported)
```

**Special characters** use named escapes:

| Literal | Value | Description |
|---------|-------|-------------|
| `\newline` | `"\n"` | Newline |
| `\space` | `" "` | Space |
| `\tab` | `"\t"` | Tab |
| `\return` | `"\r"` | Carriage return |
| `\backspace` | `"\b"` | Backspace |
| `\formfeed` | `"\f"` | Form feed |

**Important:** Character literals are represented as single-character strings internally. This means `\r` produces the string `"r"`, while `\return` produces `"\r"` (carriage return). Character equality with strings works naturally:

```clojure
(= \a "a")           ; => true
(= \newline "\n")    ; => true
(char? \a)           ; => true
(char? "ab")         ; => false
```

**Use case:** Character literals are particularly useful with collection operations on strings:

```clojure
;; Count occurrences of 'r' in a string
(count (filter #(= \r %) "raspberry"))  ; => 3

;; Find vowels
(filter #(contains? #{\a \e \i \o \u} %) "hello")  ; => ["e" "o"]
```

### 3.6 Keywords

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

Maps can also be called as functions with a keyword to access values:

```clojure
({:name "Alice" :age 30} :name)  ; => "Alice"
({:name "Alice"} :missing)       ; => nil
({:name "Alice"} :missing "default")  ; => "default"
```

Keywords also work as predicates in higher-order functions, checking if the field is truthy:

```clojure
;; As predicate in filter/remove/find (checks field truthiness)
(filter :active [{:active true} {:active false}])  ; => [{:active true}]
(remove :deleted [{:deleted true} {:deleted nil}]) ; => [{:deleted nil}]

;; As accessor in map (extracts field value)
(map :name [{:name "Alice"} {:name "Bob"}])        ; => ["Alice" "Bob"]
```

### 3.7 Vectors

Ordered, indexed collections:

```clojure
[]
[1 2 3]
["a" "b" "c"]
[1 "mixed" :types true nil]
[[1 2] [3 4]]  ; nested
```

### 3.8 Maps

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

**Maps as functions:** Maps can be invoked as functions to look up values by key:

| Expression | Result | Description |
|------------|--------|-------------|
| `({:a 1 :b 2} :a)` | `1` | Keyword key lookup |
| `({:a 1} :missing)` | `nil` | Missing key returns nil |
| `({:a 1} :missing "default")` | `"default"` | Missing key with default |
| `({"name" "Alice"} "name")` | `"Alice"` | String key lookup |

**Note:** Maps cannot be passed directly to higher-order functions like `mapv` or `filter`. Use a wrapper closure instead:

```clojure
;; Won't work: (mapv my-map keys)
;; Use instead:
(let [lookup {:a 1 :b 2}]
  (mapv #(lookup %) [:a :b]))  ; => [1 2]
```

### 3.9 Sets

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
| `vec` | `(vec coll)` | Convert collection to vector |
| `vector` | `(vector & args)` | Create vector from arguments |
| `count` | `(count #{1 2})` | Returns element count |
| `empty?` | `(empty? #{})` | Returns true if empty |
| `contains?` | `(contains? #{1 2} 1)` | Membership test (O(1)) |
| `intersection` | `(clojure.set/intersection & sets)` | Returns the intersection of one or more sets |
| `union` | `(clojure.set/union & sets)` | Returns the union of zero or more sets |
| `difference` | `(clojure.set/difference & sets)` | Returns the difference of one or more sets |

**Sets as predicates:** Sets can be invoked as functions to check membership:

| Expression | Result | Description |
|------------|--------|-------------|
| `(#{1 2 3} 2)` | `2` | Element found, returns it |
| `(#{1 2 3} 4)` | `nil` | Not found, returns nil |
| `(filter #{:a :b} [:a :c :b])` | `[:a :b]` | Filter using set membership |
| `(some #{"x"} ["a" "x"])` | `"x"` | Find first matching element |

**Not supported for sets:** `first`, `last`, `nth`, `sort`, `sort-by` (sets are unordered).

**Not supported:** Lists (`'()`)

### 3.10 Vars

Vars are references to bindings created by the `def` form. They allow you to create references to named values that can be stored in collections and passed around.

**Reader syntax:** The `#'name` syntax produces a var reference:

```clojure
#'x                    ; var reference to binding x
#'my-var               ; var reference to binding my-var
#'suspicious?          ; var reference to binding suspicious?
#'save!                ; var reference to binding save!
```

Vars can be stored in collections:

| Expression | Description |
|------------|-------------|
| `[#'x #'y]` | Vector containing two var references |
| `{:result #'foo}` | Map with var reference as value |
| `#{#'a #'b #'c}` | Set containing var references |

**Var dereferencing:** The actual dereferencing of vars and access to the values they reference is handled by the `def` form. See the `def` form documentation for details on how var bindings work and how vars are evaluated.

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

```clojure
(if nil "truthy" "falsy")    ; => "falsy"
(if false "truthy" "falsy")  ; => "falsy"
(if true "truthy" "falsy")   ; => "truthy"
(if 0 "truthy" "falsy")      ; => "truthy"
(if "" "truthy" "falsy")     ; => "truthy"
(if [] "truthy" "falsy")     ; => "truthy"
(if {} "truthy" "falsy")     ; => "truthy"
```

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
(let [x 10] x)                    ; => 10
(let [x 10] (+ x 5))              ; => 15
(let [x 1 y 2] (+ x y))           ; => 3
(let [x 1 y (+ x 1)] y)           ; => 2
```

```clojure
(let [x 10
      y (+ x 5)]    ; y can use x
  (* x y))          ; => 150

(let [x 1]
  (let [x 2]        ; shadows outer x
    x))             ; => 2
```

#### Implicit `do` (Clojure Extension)

Multiple body expressions are supported without explicit `do`:

```clojure
;; Multiple expressions - last value is returned
(let [x 10]
  (def saved x)     ; side effect: store in memory
  (* x 2))          ; => 20, saved = 10

;; Equivalent to explicit do
(let [x 10]
  (do
    (def saved x)
    (* x 2)))
```

#### Destructuring
Destructuring allows you to bind names to values within collections.

**Sequential (Vector) Destructuring:**
Extract values from vectors by position.

```clojure
; Basic sequential destructuring
(let [[a b] [1 2]]
  (+ a b))  ; => 3

; Use _ to skip elements
(let [[_ b] [1 2]]
  b)        ; => 2

; Nested sequential destructuring
(let [[a [b c]] [1 [2 3]]]
  (+ a b c)) ; => 6

; Rest pattern: bind remaining elements to a variable
(let [[x & rest] [1 2 3 4]]
  rest)      ; => [2 3 4]

; Rest pattern with multiple leading elements
(let [[a b & rest] [1 2 3 4 5]]
  [a b rest]) ; => [1 2 [3 4 5]]

; Bind entire list (no leading elements)
(let [[& all] [1 2 3]]
  all)       ; => [1 2 3]
```

**Map Destructuring:**
Extract values from maps by key. Supports both keyword and string keys.

```clojure
; Basic map destructuring
(let [{:keys [name age]} {:name "Alice" :age 30}]
  name)  ; => "Alice"

; With defaults
(let [{:keys [name age] :or {age 0}} {:name "Bob"}]
  age)   ; => 0

; Renaming bindings
(let [{the-name :name} {:name "Carol"}]
  the-name)  ; => "Carol"

; Binding the whole map with :as
(let [{:keys [id] :as user} {:id 123 :name "Alice"}]
  (:name user)) ; => "Alice"
```

**Supported destructuring forms:**
- `[a b]` — sequential (vector)
- `[a & rest]` — rest pattern (bind remaining elements)
- `{:keys [a b]}` — map keyword keys
- `{:keys [a] :or {a default}}` — map with defaults
- `{new-name :old-key}` — map renaming
- `{:as symbol}` — bind collection to symbol


### 5.2 `if` — Conditional

Conditional (else is **optional**):

```clojure
(if condition
  then-expression
  else-expression)
```

```clojure
(if true "yes" "no")              ; => "yes"
(if false "yes" "no")             ; => "no"
(if (> 5 3) "bigger" "smaller")   ; => "bigger"
(if (< 5 3) "bigger" "smaller")   ; => "smaller"
(if (empty? []) "empty" "full")   ; => "empty"
(if (empty? [1]) "empty" "full")  ; => "full"
```

**Single-branch `if` is allowed** and returns `nil` if the condition is false. However, `when` is often more idiomatic for side effects.

### 5.3 `if-not` — Negative Conditional

Swapped branch conditional. Evaluates `else` if condition is truthy, otherwise evaluates `then`.

```clojure
(if-not condition
  then-expression
  else-expression?)
```

**Semantics:**
- Desugars at analysis time to `if`:
  - `(if-not cond then else)` → `(if cond else then)`
  - `(if-not cond then)` → `(if cond nil then)`

```clojure
(if-not true "yes" "no")           ; => "no"
(if-not false "yes" "no")          ; => "yes"
(if-not (> 3 5) "smaller" "bigger") ; => "smaller"
(if-not true "yes")                ; => nil
(if-not false "yes")               ; => "yes"
```

### 5.4 `when` — Single-branch Conditional

Returns body if condition is truthy, otherwise `nil`:

```clojure
(when condition
  body)
```

```clojure
(when true "yes")                 ; => "yes"
(when false "yes")                ; => nil
(when (> 5 3) "bigger")           ; => "bigger"
(when (< 5 3) "smaller")          ; => nil
```

**Implicit `do` (Clojure Extension):** Multiple body expressions are supported:

```clojure
(when (> x 0)
  (def positive x)    ; side effect
  (* x 2))            ; return value
```

### 5.5 `when-not` — Negative Single-branch Conditional

Returns body if condition is falsy, otherwise `nil`:

```clojure
(when-not condition
  body)
```

**Semantics:**
- Desugars at analysis time to `if`: `(when-not cond body ...)` → `(if cond nil (do body ...))`
- Supports implicit `do` for multiple body expressions.

```clojure
(when-not false "yes")            ; => "yes"
(when-not true "yes")             ; => nil
(when-not (> x 0) (log "neg"))    ; => result of log, or nil
```

### 5.6 `cond` — Multi-way Conditional

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

```clojure
(cond true "first" :else "default")           ; => "first"
(cond false "first" :else "default")          ; => "default"
(cond false "a" false "b" :else "c")          ; => "c"
(cond (> 5 3) "yes" :else "no")               ; => "yes"
(cond (< 5 3) "yes" :else "no")               ; => "no"
(cond false "only")                           ; => nil
```

### 5.7 `if-let` and `when-let` — Conditional Binding

Binds a value from an expression and evaluates the body only if the value is truthy.

**`if-let` syntax:**
```clojure
(if-let [name condition-expr]
  then-expr
  else-expr)
```

**`when-let` syntax:**
```clojure
(when-let [name condition-expr]
  body-expr)
```

**Semantics:**
- `if-let` evaluates `condition-expr`, binds result to `name`, then evaluates `then-expr` if truthy, otherwise `else-expr`
- `when-let` is like `if-let` but returns `nil` instead of an else branch
- Both only support single symbol bindings (no destructuring)
- Desugars at analysis time: `(if-let [x expr] then else)` → `(let [x expr] (if x then else))`

**Examples:**
```clojure
(if-let [user (get-user 123)]
  (str "Hello " user)
  "User not found")               ; => ...

(when-let [result (compute)]
  (process result))               ; => result of process, or nil

(if-let [x 0]
  "truthy"
  "falsy")                        ; => "truthy" (0 is truthy in Lisp)

(if-let [x nil]
  "yes"
  "no")                           ; => "no"

(when-let [x false]
  (do-something))                 ; => nil
```

**Implicit `do` (Clojure Extension):** `when-let` supports multiple body expressions:

```clojure
(when-let [x (find-value)]
  (def found x)     ; side effect
  (* x 2))          ; return value
```

**Limitations:**
- Only single bindings are supported (no sequential bindings like Clojure)
- Binding names must be symbols (no destructuring patterns)

---

### 5.8 `do` — Sequential Evaluation

Evaluates expressions in order, returning the value of the last expression:

```clojure
(do expr1 expr2 ... exprN)
```

**Semantics:**
- All expressions are evaluated left-to-right
- The value of the last expression is returned
- `(do)` with no expressions returns `nil`
- Unlike `and`/`or`, there is no short-circuiting

```clojure
1 2 3                             ; => 3 (not needed at top level)
(tool/log {:msg "hi"})            ; => result of log call
(do)                              ; => nil
```

---

### 5.9 `def` — User Namespace Binding

Binds a name to a value in the user namespace, persisting across turns:

```clojure
(def name value)
(def name docstring value)  ; docstring is optional and ignored
```

**Semantics:**
- Returns the var (`#'name`), not the value (like Clojure)
- Creates or overwrites the binding in user namespace
- Value is evaluated before binding
- Binding persists until session ends or redefined
- Cannot shadow builtin function names (returns error)
- Can shadow data names, but `data/` prefix still works

```clojure
(def x 42)                        ; => #'x (x = 42)
(def threshold 5000)              ; => #'threshold
(def results (tool/search {}))    ; => ...

; Redefinition
(def x 1)                         ; x = 1
(def x 2)                         ; x = 2 (overwrites)

; Define and return (using implicit multi-expression)
(def x 10) x                      ; => 10

; Reference previous defs (single evaluation)
(def a 1) (def b (+ a 1)) b       ; => 2

; Error: cannot shadow builtins
(def map {})                      ; => error: cannot shadow builtin 'map'
```

**Differences from Clojure:**
- No `^:dynamic`, `^:private`, or other metadata
- No destructuring in def (use `let` then `def`)
- Docstrings allowed but ignored (for Clojure compatibility)

---

### 5.10 `defn` — Named Function Definition

Syntactic sugar for defining named functions in the user namespace:

```clojure
(defn name [params] body)
(defn name docstring [params] body)  ; docstring is optional and ignored
```

**Desugars to:** `(def name (fn [params] body))`

**Semantics:**
- Returns the var (`#'name`), not the function
- Creates or overwrites the function binding in user namespace
- Functions persist across turns via user namespace
- Can reference other user-defined symbols and functions
- Can access `data/` data and call `tool/` tools
- Cannot shadow builtin function names (returns error)

```clojure
; Note: using `twice` not `double` since `double` is a builtin (§8.4)
(defn twice [x] (* x 2))              ; => #'twice
(defn greet [name] (str "Hello, " name))  ; => #'greet

; Use defined function (single evaluation with implicit do)
(defn twice [x] (* x 2)) (twice 21)   ; => 42

; Reference data/ data
(defn expensive? [e] (> (:amount e) data/threshold))

; Reference other defs (single evaluation)
(def rate 0.1) (defn apply-rate [x] (* x rate)) (apply-rate 100)  ; => 10.0

; With higher-order functions
(defn expensive? [e] (> (:amount e) 5000))
(filter expensive? data/expenses)  ; => filtered list
```

**Multiple body expressions (implicit do):**
```clojure
(defn with-logging [x]
  (def last-input x)                  ; side effect
  (* x 2))                            ; return value
```

**Multi-turn persistence:**
```clojure
; Turn 1: Define function
(defn expensive? [e] (> (:amount e) 5000))

; Turn 2: Use function (passed via memory)
(filter expensive? data/expenses)
```

**Destructuring in parameters:**
`defn` supports the same destructuring patterns as `fn` and `let`:

```clojure
; Vector destructuring (single evaluation)
(defn first-name [[first last]] first) (first-name ["Alice" "Smith"])  ; => "Alice"

; Map destructuring (single evaluation)
(defn greet [{:keys [name]}] (str "Hello " name)) (greet {:name "World"})  ; => "Hello World"

; Nested destructuring (single evaluation)
(defn process [[id {:keys [status]}]] (str id ":" status)) (process [42 {:status "ok"}])  ; => "42:ok"
```


**Not supported:**
- Multi-arity: `(defn f ([x] ...) ([x y] ...))` — use separate `defn` forms
- Pre/post conditions

---

### 5.11 `loop` and `recur` — Tail Recursion

`loop` establishes a recursion point, and `recur` transfers control back to that point with new values.

**`loop` syntax:**
```clojure
(loop [bindings] body)
```

**`recur` syntax:**
```clojure
(recur expr1 expr2 ...)
```

**Semantics:**
- `loop` establishes bindings just like `let`.
- `recur` can only appear in a **tail position** of a `loop` or `fn`.
- When `recur` is evaluated, it re-binds the arguments and jumps back to the start of the `loop` or `fn` body.
- Evaluation is **stack-safe** (no stack growth).
- An iteration check is enforced to prevent infinite loops (default limit: 1000 iterations).

**Examples:**
```clojure
;; Summing numbers 0 to 4
(loop [i 0 acc 0]
  (if (< i 5)
    (recur (inc i) (+ acc i))
    acc))
; => 10

;; Factorial with recur in fn
((fn [n acc]
   (if (> n 0)
     (recur (dec n) (* acc n))
     acc))
 5 1)
; => 120

;; Process list with rest pattern destructuring
(loop [[head & tail] [1 2 3 4]
       sum 0]
  (if head
    (recur tail (+ sum head))
    sum))
; => 10
```

**Safety Mechanism:**
To ensure sandbox safety, PTC-Lisp enforces an iteration limit on recursive calls. If a loop exceeds the allowed number of iterations (default 1000), execution is terminated with a `loop_limit_exceeded` error.

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
(->> [1 2 3] (map inc))                       ; => [2 3 4]
(->> [1 2 3 4] (filter odd?))                 ; => [1 3]
(->> [3 1 2] (sort))                          ; => [1 2 3]
(->> [1 2 3] (map inc) (filter even?))        ; => [2 4]
(->> [1 2 3 4 5] (filter odd?) (take 2))      ; => [1 3]
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
(-> {:a 1} (assoc :b 2))                      ; => {:a 1 :b 2}
(-> {:a 1 :b 2} (dissoc :b))                  ; => {:a 1}
(-> {:a 1} (assoc :b 2) (assoc :c 3))         ; => {:a 1 :b 2 :c 3}
(-> {:a {:b 1}} (get-in [:a :b]))             ; => 1
(-> {:a 1} (update :a inc))                   ; => {:a 2}
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

```clojure
(count (filter (where :x = 1) [{:x 1} {:x 2}]))           ; => 1
(count (filter (where :x > 1) [{:x 1} {:x 2} {:x 3}]))    ; => 2
(count (filter (where :x < 2) [{:x 1} {:x 2} {:x 3}]))    ; => 1
(count (filter (where :x not= 2) [{:x 1} {:x 2} {:x 3}])) ; => 2
(count (filter (where :x >= 2) [{:x 1} {:x 2} {:x 3}]))   ; => 2
(count (filter (where :x <= 2) [{:x 1} {:x 2} {:x 3}]))   ; => 2
```

#### Nested Field (Path)

Use a vector for nested access:

```clojure
(where [:user :age] > 18)
(where [:profile :email] not= nil)
(where [:address :country] = "US")
```

```clojure
(count (filter (where [:a :b] = 1) [{:a {:b 1}} {:a {:b 2}}]))  ; => 1
```

#### Field Exists / Is Truthy

Check if field is truthy (not `nil` or `false`):

```clojure
(where :active)           ; field is truthy (not nil, not false)
(where :verified = true)    ; explicit boolean check
(where [:user :premium])  ; nested truthy check
```

```clojure
(count (filter (where :a) [{:a 1} {:a nil} {:a false}]))  ; => 1
(count (filter (where :a = true) [{:a true} {:a false}])) ; => 1
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

```clojure
(count (filter (where :s = :a) [{:s "a"} {:s "b"}]))             ; => 1
(count (filter (where :s in [:a :b]) [{:s "a"} {:s "c"}]))       ; => 1
(count (filter (where :t includes :x) [{:t ["x" "y"]} {:t []}])) ; => 1
```

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

```clojure
(count (filter (all-of (where :a = 1) (where :b = 2)) [{:a 1 :b 2} {:a 1 :b 3}]))  ; => 1
(count (filter (any-of (where :a = 1) (where :a = 2)) [{:a 1} {:a 2} {:a 3}]))     ; => 2
(count (filter (none-of (where :a = 1)) [{:a 1} {:a 2}]))                          ; => 1
```

**Zero predicates:**

| Expression | Result |
|------------|--------|
| `(all-of)` | Always true (vacuous truth) |
| `(any-of)` | Always false (no predicate matches) |
| `(none-of)` | Always true (no predicate to fail) |

```clojure
(count (filter (all-of) [{:a 1} {:a 2}]))     ; => 2
(count (filter (any-of) [{:a 1} {:a 2}]))     ; => 0
(count (filter (none-of) [{:a 1} {:a 2}]))    ; => 2
```

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

Field accessors in `where` and key-based functions (`sort-by`, `sum-by`, `avg-by`, `min-by`, `max-by`, `distinct-by`, `group-by`, `pluck`, `get`) support **bidirectional key matching**. This means:
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
;; Using where (explicit predicate builder)
(filter (where :active) users)
(remove (where :deleted) items)
(find (where :id = 42) users)

;; Using keyword directly (concise, checks truthiness)
(filter :active users)
(remove :deleted items)
(find :special items)
```

**Map support:** `filter` and `remove` accept maps as input, treating each entry as a `[key value]` pair passed to the predicate. They return a **list** of `[key value]` pairs (not a map):

```clojure
;; Filter map entries by value
(filter (fn [[k v]] (> v 100)) {:food 50 :travel 200 :office 150})
;; => [[:travel 200] [:office 150]]

;; Remove entries where value is nil
(remove (fn [[k v]] (nil? v)) {:a 1 :b nil :c 3})
;; => [[:a 1] [:c 3]]
```

#### Transforming

| Function | Signature | Description |
|----------|-----------|-------------|
| `map` | `(map f coll)` | Apply f to each item |
| `map` | `(map f c1 c2)` | Apply f to pairs from c1, c2 |
| `map` | `(map f c1 c2 c3)` | Apply f to triples |
| `mapcat` | `(mapcat f coll)` | Apply f to each item, concatenate results |
| `pmap` | `(pmap f coll)` | Apply f to each item in parallel |
| `pcalls` | `(pcalls f1 f2 ...)` | Execute thunks in parallel |
| `mapv` | `(mapv f coll)` | Like map, returns vector |
| `mapv` | `(mapv f c1 c2)` | Like map with two collections |
| `mapv` | `(mapv f c1 c2 c3)` | Like map with three collections |
| `map-indexed` | `(map-indexed f coll)` | Apply f to index and item |
| `select-keys` | `(select-keys map keys)` | Pick specific keys |
| `pluck` | `(pluck key coll)` | Extract single field from each item |

```clojure
(map :name users)                    ; extract :name from each
(mapcat (fn [x] [x (* x 2)]) [1 2 3])  ; => [1 2 2 4 3 6] (map + flatten)
(pmap :name users)                   ; same, but parallel execution
(pcalls #(tool/get-user) #(tool/get-stats))  ; parallel heterogeneous calls
(mapv :name users)                   ; same, ensures vector
(map-indexed (fn [i x] [i x]) ["a" "b"]) ; => [[0 "a"] [1 "b"]]
(select-keys user [:name :email])    ; pick keys from map
(pluck :name users)                  ; shorthand for (map :name coll)

;; Multi-arity map - parallel iteration over collections
(map + [1 2 3] [10 20 30])           ; => [11 22 33]
(map (fn [a b] [a b]) [1 2] [:a :b]) ; => [[1 :a] [2 :b]]
(map + [1 2 3 4] [10 20])            ; => [11 22] (stops at shortest)

;; 3-collection map requires explicit closure for variadic ops
(map (fn [a b c] (+ a b c)) [1 2] [10 20] [100 200])  ; => [111 222]

;; mapcat - apply function and concatenate results (flat_map)
(mapcat (fn [x] (range 0 x)) [2 3 1])   ; => [0 1 0 1 2 0]
(mapcat identity [[1 2] [3 4] [5]])     ; => [1 2 3 4 5] (flatten one level)
(mapcat (fn [x] (if (> x 0) [x] [])) [-1 2 -3 4])  ; => [2 4] (filter + flatten)
```

**Limitation:** Variadic builtins (`+`, `*`, `str`) don't work directly with 3-collection map—use explicit closures. See [#668](https://github.com/andreasronge/ptc_runner/issues/668).

**Note:** Since PTC-Lisp has no lazy sequences (see Section 13.1), `map` and `mapv` are functionally identical—both return vectors. `mapv` is provided for Clojure compatibility and to make intent explicit.

**Parallel Map (`pmap`):** Executes the function for each element concurrently using BEAM processes. Useful when the mapping function involves I/O-bound operations (like tool calls) that can benefit from parallelism:

```clojure
;; Process multiple items in parallel - much faster for I/O-bound tasks
(pmap #(tool/fetch-data {:id %}) item-ids)

;; Closures work - captures outer scope at evaluation time
(let [factor 10]
  (pmap #(* % factor) [1 2 3]))    ; => [10 20 30]
```

**pmap semantics:**
- Order is preserved - results match input order
- Each parallel branch gets a read-only snapshot of the user namespace
- Writes within branches (via `def`) are isolated and discarded
- Errors in any branch propagate to the caller
- Concurrency is bounded to `2 × CPU cores` to prevent resource exhaustion
- Individual tasks timeout after 5 seconds

**Parallel Calls (`pcalls`):** Executes multiple zero-arity functions (thunks) concurrently and returns their results as a vector. Unlike `pmap` which applies one function to many items, `pcalls` runs multiple different functions in parallel:

```clojure
;; Fetch multiple pieces of data in parallel
(let [[user stats config] (pcalls
                            #(tool/get-user {:id data/user-id})
                            #(tool/get-stats {:id data/user-id})
                            #(tool/get-config {}))]
  {:user user :stats stats :config config})

;; Simple parallel computations
(pcalls #(+ 1 1) #(* 2 3) #(- 10 5))    ; => [2 6 5]
```

**pcalls semantics:**
- Order is preserved - results match argument order
- All functions must be zero-arity thunks (use `#()` syntax)
- If any function fails, entire `pcalls` expression fails (atomic)
- Errors include the failed function index and error details
- Each parallel branch gets a read-only snapshot of the user namespace
- Concurrency is bounded to `2 × CPU cores` to prevent resource exhaustion
- Individual tasks timeout after 5 seconds

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
(sort :desc [1 3 2])          ; => [3 2 1] (Clojure extension)
(sort :asc [3 1 2])           ; => [1 2 3] (Clojure extension)
(sort-by :price products)     ; ascending by price
(sort-by :price > products)   ; descending by price (boolean comparator)
(sort-by :price :desc products) ; descending by price (simplified keyword)
(sort-by :price (fn [a b] (compare b a)) products) ; descending by price (Clojure-style)
(sort-by :name products)      ; alphabetical by name
(sort-by first [["b" 2] ["a" 1] ["c" 3]])  ; => [["a" 1] ["b" 2] ["c" 3]]
(sort-by (fn [x] (nth x 1)) > [["a" 2] ["b" 1] ["c" 3]])  ; descending by second element
(reverse [1 2 3])             ; => [3 2 1]
```

**Note:** While `sort` and `sort-by` support string comparison internally, the explicit comparison operators (`>`, `<`, `>=`, `<=`) only work on numbers. This prevents ambiguous comparisons in user code while allowing natural sorting.

**Map support:** `sort-by` accepts maps, treating each entry as a `[key value]` pair. Returns a **list** of `[key value]` pairs (not a map) to preserve sort order:

```clojure
;; Sort map by values (descending)
(sort-by second > {:food 100 :travel 500 :office 200})
;; => [[:travel 500] [:office 200] [:food 100]]

;; Sort map by keys
(sort-by first {:z 1 :a 2 :m 3})
;; => [[:a 2] [:m 3] [:z 1]]
```

#### Subsetting

| Function | Signature | Description |
|----------|-----------|-------------|
| `first` | `(first coll)` | First item or nil |
| `second` | `(second coll)` | Second item or nil |
| `last` | `(last coll)` | Last item or nil |
| `nth` | `(nth coll idx)` | Item at index or nil |
| `rest` | `(rest coll)` | All but first (empty list if none) |
| `butlast` | `(butlast coll)` | All but last (empty list if none) |
| `next` | `(next coll)` | All but first (nil if none) |
| `ffirst` | `(ffirst coll)` | First of first |
| `fnext` | `(fnext coll)` | First of next |
| `nfirst` | `(nfirst coll)` | Next of first |
| `nnext` | `(nnext coll)` | Next of next |
| `take` | `(take n coll)` | First n items |
| `drop` | `(drop n coll)` | Skip first n items |
| `take-last` | `(take-last n coll)` | Last n items |
| `drop-last` | `(drop-last coll)` `(drop-last n coll)` | All but last n items (default n=1) |
| `take-while` | `(take-while pred coll)` | Take while pred is true |
| `drop-while` | `(drop-while pred coll)` | Drop while pred is true |
| `distinct` | `(distinct coll)` | Remove duplicates |
| `partition` | `(partition n coll)` | Chunk into groups of n |
| `partition` | `(partition n step coll)` | Sliding window chunks |

```clojure
(first [1 2 3])       ; => 1
(first [])            ; => nil
(second [1 2 3])      ; => 2
(last [1 2 3])        ; => 3
(nth [1 2 3] 1)       ; => 2
(nth [1 2 3] 10)      ; => nil (out of bounds)
(rest [1 2 3])        ; => [2 3]
(rest [])             ; => []
(butlast [1 2 3 4])   ; => [1 2 3]
(butlast [1])         ; => []
(butlast [])          ; => []
(next [1 2 3])        ; => [2 3]
(next [])             ; => nil
(next [1])            ; => nil
(ffirst [[1 2] [3]])  ; => 1
(fnext [1 2 3])       ; => 2
(nfirst [[1 2] [3]])  ; => [2]
(nnext [1 2 3 4])     ; => [3 4]
(take 2 [1 2 3 4])    ; => [1 2]
(drop 2 [1 2 3 4])    ; => [3 4]
(distinct [1 2 1 3])  ; => [1 2 3]

;; partition - chunk collection into groups
(partition 2 [1 2 3 4 5 6])          ; => [[1 2] [3 4] [5 6]]
(partition 3 [1 2 3 4 5])            ; => [[1 2 3]] (incomplete discarded)
(partition 2 1 [1 2 3 4])            ; => [[1 2] [2 3] [3 4]] (sliding window)
```

**take-while and drop-while with keywords:**

```clojure
;; Using keyword directly (checks field truthiness)
(take-while :active [{:active true} {:active true} {:active false}])
;; => [{:active true} {:active true}]

(drop-while :pending [{:pending true} {:pending true} {:pending false}])
;; => [{:pending false}]
```

#### Combining

| Function | Signature | Description |
|----------|-----------|-------------|
| `conj` | `(conj coll x ...)` | Add elements to collection |
| `concat` | `(concat coll1 coll2 ...)` | Join collections |
| `into` | `(into to from)` | Pour from into to |
| `flatten` | `(flatten coll)` | Flatten nested collections |
| `interleave` | `(interleave c1 c2)` | Interleave collections |
| `interpose` | `(interpose sep coll)` | Insert separator between elements |
| `zip` | `(zip c1 c2)` | Combine into pairs |

```clojure
(conj [1 2] 3)             ; => [1 2 3]
(conj #{1 2} 3)            ; => #{1 2 3}
(conj {:a 1} [:b 2])       ; => {:a 1 :b 2}
(concat [1 2] [3 4])       ; => [1 2 3 4]
(into [] [1 2 3])          ; => [1 2 3]
(into [] {:a 1 :b 2})       ; => [[:a 1] [:b 2]]
(into #{} [1 2 2 3])       ; => #{1 2 3}
(into {} [[:a 1] [:b 2]])  ; => {:a 1 :b 2}
(into #{} {:a 1})          ; => #{[:a 1]}
(into {} #{[:a 1]})        ; => {:a 1}
(flatten [[1 2] [3 [4]]])  ; => [1 2 3 4]
(interpose ", " ["a" "b" "c"]) ; => ["a" ", " "b" ", " "c"]
(zip [1 2] [:a :b])        ; => [[1 :a] [2 :b]]
```

#### Conversion

| Function | Signature | Description |
|----------|-----------|-------------|
| `seq` | `(seq coll)` | Convert to sequence (nil if empty) |

The `seq` function converts a collection to a sequence:
- **Lists**: Returns the list unchanged, or nil if empty
- **Strings**: Returns a list of characters (graphemes), or nil if empty
- **Sets**: Returns a list of elements, or nil if empty
- **Maps**: Returns a list of `[key value]` pairs, or nil if empty
- **nil**: Returns nil

```clojure
(seq [1 2 3])              ; => [1 2 3]
(seq [])                   ; => nil
(seq "hello")              ; => ["h" "e" "l" "l" "o"]
(seq "")                   ; => nil
(seq #{1 2 3})             ; => [1 2 3] or another order (sets are unordered)
(seq {})                   ; => nil
(seq {:a 1 :b 2})          ; => [[:a 1] [:b 2]]
(count (seq "abc"))        ; => 3 (iterate over characters)
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
| `distinct-by` | `(distinct-by key coll)` | Items with unique field values |
| `min-key` | `(min-key f x y & more)` | Return x for which (f x) is least |
| `max-key` | `(max-key f x y & more)` | Return x for which (f x) is greatest |
| `group-by` | `(group-by keyfn coll)` | Group items by key |
| `frequencies` | `(frequencies coll)` | Count occurrences of each item |

```clojure
(count [1 2 3])                   ; => 3
(reduce + 0 [1 2 3])              ; => 6
(reduce - 10 [1 2 3])             ; => 4 (10 - 1 - 2 - 3, Clojure style: f receives (acc, elem))

;; reduce on maps (v is [key value] pair)
;; NOTE: 3-arg form is preferred for maps as the 2-arg form uses the first [k v] pair as init.
(reduce (fn [acc [k v]] (+ acc v)) 0 {:a 1 :b 2}) ; => 3

;; reduce on strings (iterates over graphemes)
(reduce (fn [acc x] (str acc "-" x)) "a" "bc") ; => "a-b-c"

;; reduce on sets
(reduce + 0 #{1 2 3})              ; => 6

(sum-by :amount expenses)         ; sum of :amount fields
(avg-by :price products)          ; average of :price fields
(min-by :price products)          ; item with lowest price
(max-by :years employees)         ; item with highest years
(group-by :category products)     ; map of category -> items
(distinct-by :category products)  ; one item per category (first occurrence)
(frequencies [:a :b :a :c :b :a]) ; => {:a 3, :b 2, :c 1}
(frequencies "hello")                 ; => {"h" 1, "e" 1, "l" 2, "o" 1}
(frequencies (pluck :status orders))  ; count orders by status
(min-by first [["b" 2] ["a" 1]])  ; => ["a" 1] (item with minimum first element)
(max-by (fn [x] (nth x 1)) [["a" 2] ["b" 3]])  ; item with maximum second element
(sum-by (fn [x] (nth x 1)) [["a" 2] ["b" 3]])  ; => 5 (sum second elements)
(group-by first [["a" 1] ["a" 2] ["b" 3]])  ; {"a" [["a" 1] ["a" 2]], "b" [["b" 3]]}
(distinct-by first [["a" 1] ["a" 2] ["b" 3]])  ; [["a" 1] ["b" 3]] (first of each key)

;; max-key / min-key - compare variadic args using function
(max-key count "a" "abc" "ab")              ; => "abc" (longest string)
(min-key count "abc" "a" "ab")              ; => "a" (shortest string)
(max-key #(nth % 1) ["a" 1] ["b" 5] ["c" 3]) ; => ["b" 5]

;; Common pattern: find map entry with max/min value using apply
(apply max-key second (seq {:a 3 :b 7 :c 2}))  ; => [:b 7]

;; Note: max-key/min-key are variadic (take individual items) - use apply to spread a collection
;; max-by/min-by take a collection directly - no apply needed: (max-by :key coll)
```

#### Predicates on Collections

| Function | Signature | Description |
|----------|-----------|-------------|
| `empty?` | `(empty? coll)` | True if empty or nil |
| `not-empty` | `(not-empty coll)` | `coll` if not empty, else `nil` |
| `some` | `(some pred coll)` | First truthy result of pred, or nil |
| `some` | `(some :key coll)` | First truthy `:key` value, or nil |
| `every?` | `(every? pred coll)` | True if all match |
| `every?` | `(every? :key coll)` | True if all have truthy `:key` |
| `not-any?` | `(not-any? pred coll)` | True if none match |
| `not-any?` | `(not-any? :key coll)` | True if none have truthy `:key` |
| `contains?` | `(contains? coll key)` | True if key/element exists (maps, sets, lists) |

```clojure
(empty? [])                        ; => true
(empty? nil)                       ; => true
(not-empty [1 2])                  ; => [1 2]
(not-empty [])                     ; => nil
(not-empty nil)                    ; => nil
(some (where :admin) users)        ; any admins? (with predicate)
(some :admin users)                ; any admins? (keyword shorthand)
(every? (where :active) users)     ; all active? (with predicate)
(every? :active users)             ; all active? (keyword shorthand)
(not-any? :error items)            ; no errors?
(contains? {:a 1} :a)              ; => true
(contains? {:a 1} :b)              ; => false
(contains? ["a" "b" "c"] "b")      ; => true (works on lists too)
(contains? ["a" "b" "c"] "x")      ; => false
```

#### Sequence Generation

| Function | Signature | Description |
|----------|-----------|-------------|
| `range` | `(range end)` | Returns sequence from 0 to end (exclusive) |
| `range` | `(range start end)` | Returns sequence from start to end (exclusive) |
| `range` | `(range start end step)` | Returns sequence with specific step |

```clojure
(range 5)                          ; => [0 1 2 3 4]
(range 5 10)                       ; => [5 6 7 8 9]
(range 0 10 2)                     ; => [0 2 4 6 8]
(range 10 0 -2)                    ; => [10 8 6 4 2]
(range 5 5)                        ; => []
```

**Note:** Unlike Clojure, `range` in PTC-Lisp is always finite and **requires at least one argument**. The zero-arity `(range)` which produces an infinite sequence is not supported because PTC-Lisp does not support lazy sequences.

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
| `update` | `(update m key f & args)` | Update with extra args passed to f |
| `update-in` | `(update-in m path f)` | Update nested with function |
| `update-in` | `(update-in m path f & args)` | Update nested with extra args |
| `dissoc` | `(dissoc m key)` | Remove key |
| `merge` | `(merge m1 m2 ...)` | Merge maps (later wins) |
| `select-keys` | `(select-keys m keys)` | Pick specific keys |
| `keys` | `(keys m)` | Get all keys |
| `vals` | `(vals m)` | Get all values |
| `entries` | `(entries m)` | Get all `[key value]` pairs as a list |
| `update-vals` | `(update-vals m f)` | Apply f to each value (matches Clojure 1.11) |

```clojure
(get {:a 1} :a)                    ; => 1
(get {:a 1} :b "default")          ; => "default"
(get-in {:user {:name "A"}} [:user :name])  ; => "A"
(assoc {:a 1} :b 2)                ; => {:a 1 :b 2}
(assoc-in {} [:user :name] "Bob")  ; => {:user {:name "Bob"}}
(update {:n 1} :n inc)             ; => {:n 2}
(update {:n 1} :n + 5)             ; => {:n 6} - extra args passed to f
(update {:n nil} :n (fnil inc 0))  ; => {:n 1} - fnil with 1-arity fn
(update {:n nil} :n (fnil + 0) 5)  ; => {:n 5} - fnil with 2-arity fn + extra arg
(update-in {:a {:b 1}} [:a :b] + 10) ; => {:a {:b 11}}
(dissoc {:a 1 :b 2} :b)            ; => {:a 1}
(merge {:a 1} {:b 2} {:a 3})       ; => {:a 3 :b 2}
(select-keys {:a 1 :b 2 :c 3} [:a :c])  ; => {:a 1 :c 3}
(keys {:a 1 :b 2})                 ; => [:a :b]
(vals {:a 1 :b 2})                 ; => [1 2]
(entries {:a 1 :b 2})              ; => [[:a 1] [:b 2]]

;; update-vals: apply function to each value (matches Clojure 1.11)
(update-vals {:a 1 :b 2} inc)      ; => {:a 2 :b 3}

;; Common pattern: count items per group after group-by
;; Note: Use -> (not ->>) since map is first argument
(-> orders
    (group-by :status)
    (update-vals count))           ; => ...
```

**List Index Support:**

`get-in`, `assoc`, `assoc-in`, and `update-in` support numeric indices for list/vector access:

```clojure
(get-in {:results [{:title "A"}]} [:results 0 :title])  ; => "A"
(get-in [1 2 3] [0])                                     ; => 1
(get-in [[1 2] [3 4]] [1 0])                             ; => 3
(get-in [1 2 3] [10])                                    ; => nil (out of bounds)
(get-in [1 2 3] [-1])                                    ; => nil (negative not supported)

(assoc [1 2 3] 1 5)                                      ; => [1 5 3]
(assoc-in [1 2 3] [1] 99)                                ; => [1 99 3]
(assoc-in [[1 2] [3 4]] [0 1] 99)                        ; => [[1 99] [3 4]]
(update-in [1 2 3] [1] inc)                              ; => [1 3 3]
```

**Note:** `assoc`, `assoc-in`, and `update-in` raise `ArgumentError` for out-of-bounds indices.

### 8.3 String Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `str` | `(str ...)` | Convert and concatenate to string |
| `subs` | `(subs s start)` | Substring from index to end |
| `subs` | `(subs s start end)` | Substring from start to end |
| `split` | `(split s separator)` | Split string by separator |
| `split-lines` | `(split-lines s)` | Split string into lines (\n or \r\n) |
| `join` | `(join separator coll)` | Join collection elements with separator |
| `join` | `(join coll)` | Join collection elements (no separator) |
| `trim` | `(trim s)` | Remove leading/trailing whitespace |
| `replace` | `(replace s pattern replacement)` | Replace all occurrences |
| `upcase` / `upper-case` | `(upcase s)` | Convert to uppercase |
| `downcase` / `lower-case` | `(downcase s)` | Convert to lowercase |
| `starts-with?` | `(starts-with? s prefix)` | Check if string starts with prefix |
| `ends-with?` | `(ends-with? s suffix)` | Check if string ends with suffix |
| `includes?` | `(includes? s substring)` | Check if string contains substring |
| `grep` | `(grep pattern text)` | Return lines containing pattern (substring match) |
| `grep-n` | `(grep-n pattern text)` | Return lines with 1-based line numbers as `{:line n :text s}` |

**Type coercion:** `str` converts values to strings using these rules:
- `nil` → `""`
- `true` / `false` → `"true"` / `"false"`
- Numbers → decimal representation (e.g., `42` → `"42"`, `3.14` → `"3.14"`)
- Strings → unchanged
- Keywords → `:keyword` (with leading colon)
- Collections → string representation

```clojure
(str "hello")                  ; => "hello"
(str "Hello" " " "World")      ; => "Hello World"

(subs "hello" 1)               ; => "ello"
(subs "hello" 1 4)             ; => "ell"
```

**PTC-Lisp specific string examples:**
- `(str)` → `""` (empty call)
- `(str 42)` → `"42"` (number conversion)
- `(str true)` → `"true"` (boolean conversion)
- `(str :user)` → `":user"` (keyword with colon)
- `(str nil "x")` → `"x"` (nil coerced to empty string)
- `(split "a,b,c" ",")` → `["a" "b" "c"]` (split by separator)
- `(split "hello" "")` → `["h" "e" "l" "l" "o"]` (split into characters)
- `(split "a,,b" ",")` → `["a" "" "b"]` (preserves empty elements)
- `(split-lines "a\nb\r\nc")` → `["a" "b" "c"]` (split by line endings)
- `(split-lines "a\n\n\n")` → `["a"]` (discards trailing empty lines)
- `(join ", " ["a" "b" "c"])` → `"a, b, c"` (join with separator)
- `(join "-" [1 2 3])` → `"1-2-3"` (numeric types converted)
- `(trim "\n\tworld\r\n")` → `"world"` (remove all whitespace)
- `(replace "hello" "l" "L")` → `"heLLo"` (replace all occurrences)
- `(replace "aaa" "a" "b")` → `"bbb"` (replace pattern)
- `(upcase "hello")` → `"HELLO"` (uppercase conversion)
- `(upper-case "world")` → `"WORLD"` (alias for upcase)
- `(downcase "HELLO")` → `"hello"` (lowercase conversion)
- `(lower-case "WORLD")` → `"world"` (alias for downcase)
- `(starts-with? "hello" "he")` → `true` (prefix check)
- `(starts-with? "hello" "lo")` → `false` (does not start with)
- `(starts-with? "hello" "")` → `true` (empty prefix always matches)
- `(ends-with? "hello" "lo")` → `true` (suffix check)
- `(ends-with? "hello" "he")` → `false` (does not end with)
- `(ends-with? "hello" "")` → `true` (empty suffix always matches)
- `(includes? "hello" "ll")` → `true` (substring check)
- `(includes? "hello" "x")` → `false` (does not contain)
- `(includes? "hello" "")` → `true` (empty substring always matches)
- `(grep "error" "info\nerror: bad\nok")` → `["error: bad"]` (lines containing pattern)
- `(grep "" "a\nb")` → `["a" "b"]` (empty pattern matches all lines)
- `(grep-n "error" "info\nerror: bad")` → `[{:line 2 :text "error: bad"}]` (with line numbers)

### 8.4 Arithmetic

| Function | Signature | Description |
|----------|-----------|-------------|
| `+` | `(+ x y ...)` | Addition |
| `-` | `(- x y ...)` | Subtraction |
| `*` | `(* x y ...)` | Multiplication |
| `/` | `(/ x y)` | Division |
| `mod` | `(mod x y)` | Modulo (floored division, result sign matches divisor) |
| `rem` | `(rem x y)` | Remainder (truncated division, result sign matches dividend) |
| `inc` | `(inc x)` | Add 1 |
| `dec` | `(dec x)` | Subtract 1 |
| `abs` | `(abs x)` | Absolute value |
| `compare` | `(compare x y)` | Numeric comparison: `-1` if `x < y`, `0` if `x == y`, `1` if `x > y`. Only supports numbers in PTC-Lisp. |
| `max` | `(max x y ...)` | Maximum value |
| `min` | `(min x y ...)` | Minimum value |
| `floor` | `(floor x)` | Round toward -∞ |
| `ceil` | `(ceil x)` | Round toward +∞ |
| `round` | `(round x)` | Round to nearest integer |
| `float` | `(float x)` | Alias for double (Clojure compat) |
| `double` | `(double x)` | Type coercion (to float) |
| `int` | `(int x)` | Type coercion (to integer) |

**Special Value Behavior:**
- **NaN Propagation**: Any arithmetic operation involving `Double/NaN` returns `Double/NaN`.
- **Division by Zero**: `(/ n 0)` returns `Double/POSITIVE_INFINITY` (if `n > 0`), `Double/NEGATIVE_INFINITY` (if `n < 0`), or `Double/NaN` (if `n = 0`).
- **Indeterminate Forms**: Operations like `(- Double/POSITIVE_INFINITY Double/POSITIVE_INFINITY)` or `(* Double/POSITIVE_INFINITY 0)` return `Double/NaN`.
- **Coercion**: Converting `Infinity` or `NaN` to `int` raises an `arithmetic-error`.

```clojure
(+ 1 2 3)       ; => 6
(- 10 3)        ; => 7
(* 2 3 4)       ; => 24
(/ 10 2)        ; => 5.0
(/ 10 3)        ; => 3.333...
(mod 10 3)      ; => 1
(mod -10 3)     ; => 2   (sign matches divisor)
(rem 10 3)      ; => 1
(rem -10 3)     ; => -1  (sign matches dividend)
(inc 5)         ; => 6
(dec 5)         ; => 4
(abs -5)        ; => 5
(max 1 5 3)     ; => 5
(min 1 5 3)     ; => 1
(floor 3.7)     ; => 3
(ceil 3.2)      ; => 4
(round 3.5)     ; => 4
(double 5)      ; => 5.0
(int 3.7)       ; => 3

(/ 1.0 0.0)                         ; => ##Inf
(/ 0.0 0.0)                         ; => ##NaN
(sqrt -1)                           ; => ##NaN
(+ Double/POSITIVE_INFINITY 1)      ; => ##Inf
(* Double/NaN 10)                   ; => ##NaN
(int Double/POSITIVE_INFINITY)      ; => ARITHMETIC ERROR
```

**Division behavior:** The `/` operator always returns a float, even for exact divisions. Integer division (`quot`) is not supported. Division by zero returns `Infinity`, `-Infinity`, or `NaN` as per IEEE 754 standard for floats. Converting `Infinity` or `NaN` to `int` raises an `arithmetic-error`.

### 8.5 Comparison

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

;; Special Value Comparisons (IEEE 754)
(< 1.0 Double/POSITIVE_INFINITY)     ; => true
(> -1.0 Double/NEGATIVE_INFINITY)    ; => true
(= Double/NaN Double/NaN)            ; => false
(< Double/NaN 0.0)                   ; => false
(>= Double/NaN 0.0)                  ; => false
```

### 8.6 Logic

| Function | Signature | Description |
|----------|-----------|-------------|
| `and` | `(and x y ...)` | Logical AND (short-circuits) |
| `or` | `(or x y ...)` | Logical OR (short-circuits) |
| `not` | `(not x)` | Logical NOT |
| `identity` | `(identity x)` | Returns argument unchanged |

```clojure
(and true true)     ; => true
(and true false)    ; => false
(and nil "x")       ; => nil (short-circuits)
(or false true)     ; => true
(or nil false "x")  ; => "x" (returns first truthy)
(not true)          ; => false
(not nil)           ; => true
(identity 42)       ; => 42
```

**`identity` function:** Returns its argument unchanged. Useful as a default function argument, for passing to higher-order functions, or in pipelines where no transformation is needed.

### 8.7 Type Predicates

| Function | Description |
|----------|-------------|
| `nil?` | Is nil? |
| `some?` | Is not nil? |
| `boolean?` | Is boolean? |
| `number?` | Is number? |
| `string?` | Is string? |
| `char?` | Is single-character string? (See §3.5) |
| `keyword?` | Is keyword? |
| `vector?` | Is vector? |
| `map?` | Is map? |
| `set?` | Is set? |
| `coll?` | Is collection? (vectors only, not maps or strings) |

**Note:** In PTC-Lisp, `coll?` returns `true` only for vectors (and any future sequence types). Maps and strings are not considered collections by `coll?`. This affects functions like `flatten` which only flatten values where `coll?` is true.

**Collection Functions on Maps and Strings:**

Although maps and strings are not "collections" per `coll?`, many collection functions work on them:

| Function | Maps | Strings | Notes |
|----------|------|---------|-------|
| `count` | ✓ | ✓ | Returns key count / character count |
| `empty?` | ✓ | ✓ | True if no keys / no characters (or nil) |
| `not-empty` | ✓ | ✓ | Returns map/string if not empty, else nil |
| `first` | ✗ | ✓ | Maps: use `(first (keys m))`. Strings: returns first character |
| `second` | ✗ | ✓ | Maps: use `(second (keys m))`. Strings: returns second character |
| `last` | ✗ | ✓ | Maps: use `(last (keys m))`. Strings: returns last character |
| `nth` | ✗ | ✓ | Maps: not supported. Strings: returns character at index |
| `rest` | ✗ | ✓ | Strings: returns list of remaining characters |
| `butlast` | ✗ | ✓ | Strings: returns list of all but last character |
| `next` | ✗ | ✓ | Strings: returns list of remaining characters or nil |
| `take` | ✗ | ✓ | Strings: returns list of first n characters |
| `drop` | ✗ | ✓ | Strings: returns list of characters after dropping n |
| `take-last` | ✗ | ✓ | Strings: returns list of last n characters |
| `drop-last` | ✗ | ✓ | Strings: returns list of characters after dropping last n |
| `take-while` | ✗ | ✓ | Strings: returns list of characters while predicate is true |
| `drop-while` | ✗ | ✓ | Strings: returns list of characters after predicate becomes false |
| `map` | ✓ | ✓ | Maps: iterates over `[key value]` pairs. Strings: iterates over characters |
| `mapv` | ✓ | ✓ | Same as `map`, returns vector |
| `filter` | ✓ | ✓ | Maps: returns list of `[key value]` pairs. Strings: returns list of characters |
| `remove` | ✓ | ✓ | Maps: returns list of `[key value]` pairs. Strings: returns list of characters |
| `find` | ✗ | ✓ | Strings: returns first character matching predicate |
| `sort` | ✗ | ✓ | Strings: returns sorted list of characters |
| `sort-by` | ✓ | ✓ | Maps: returns sorted list of `[key value]` pairs. Strings: sorted list of characters |
| `reverse` | ✗ | ✓ | Strings: returns reversed list of characters |
| `distinct` | ✗ | ✓ | Strings: returns list of unique characters |
| `some` | ✗ | ✓ | Strings: returns first truthy result of predicate |
| `every?` | ✗ | ✓ | Strings: true if predicate is truthy for all characters |
| `not-any?` | ✗ | ✓ | Strings: true if predicate is false for all characters |
| `reduce` | ✓ | ✓ | Maps: iterates over `[key value]` pairs. Strings: iterates over characters |
| `entries` | ✓ | ✗ | Explicit conversion to list of `[key value]` pairs |

**Note:** String operations that return characters return lists of single-character strings, not a string. Use `(join "" result)` to convert back to a string if needed.

**Mapping over maps:** When you call `map` on a map, each entry is passed as a `[key value]` vector. Use destructuring to extract the key and value:

```clojure
;; Transform grouped data
(let [by-category (group-by :category expenses)]
  (map (fn [[cat items]]
         {:category cat :total (sum-by :amount items)})
       by-category))
```

To iterate over just keys or values, extract them first:
```clojure
(->> (keys my-map)
     (map (fn [k] {:key k :val (get my-map k)})))
```

### 8.8 Numeric Predicates

| Function | Description |
|----------|-------------|
| `zero?` | Is zero? |
| `pos?` | Is positive? |
| `neg?` | Is negative? |
| `even?` | Is even? |
| `odd?` | Is odd? |

**Note on Special Values:**
- `number?` returns `true` for `Infinity` and `NaN`.
- `pos?` returns `true` for `Double/POSITIVE_INFINITY`.
- `neg?` returns `true` for `Double/NEGATIVE_INFINITY`.
- All predicates (including `zero?`) return `false` for `Double/NaN`.
- `Double/NaN` is not equal to itself: `(= Double/NaN Double/NaN)` is `false`.

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

### 8.9 String Parsing

| Function | Description |
|----------|-------------|
| `parse-long` | Parse string to integer, returns nil on failure |
| `parse-double` | Parse string to double, returns nil on failure |

String parsing functions provide safe conversion from strings to numbers, compatible with Clojure 1.11+. These functions return `nil` on parse failure rather than throwing exceptions.

**Parsing behavior:**
- Both functions require the entire string to be consumed by the parse. Partial parses are rejected.
- Leading/trailing whitespace is not stripped—the string must be in exact numeric form.
- Invalid input returns `nil` rather than an error.

```clojure
;; Successful parses
(parse-long "42")          ; => 42
(parse-long "-17")         ; => -17
(parse-double "3.14")      ; => 3.14
(parse-double "-0.5")      ; => -0.5
(parse-double "1.23e-4")   ; => 1.23e-4
```

### 8.10 Regex Functions

Regex functions provide validation and extraction capabilities. To ensure system stability, PTC-Lisp uses a "Safety-First" regex engine with forced backtracking and recursion limits.

| Function | Signature | Description |
|----------|-----------|-------------|
| `re-pattern` | `(re-pattern s)` | Compile string `s` into an opaque regex object |
| `re-find` | `(re-find re s)` | Returns the first match of `re` in `s` |
| `re-matches` | `(re-matches re s)` | Returns match if `re` matches the **entire** string `s` |
| `re-seq` | `(re-seq re s)` | Returns all matches of `re` in `s` as a list |
| `re-split` | `(re-split re s)` | Split string `s` by regex pattern `re` |
| `regex?` | `(regex? x)` | Returns true if `x` is a regex object |

**Opaque Regex Type:** Regexes do not have a literal syntax. They must be created using `re-pattern`. Internally, they are opaque objects that can be passed to functions but not inspected directly.

**Return Value Semantics:**
- If no match is found, `re-find` and `re-matches` return `nil`; `re-seq` returns an empty list.
- If the regex has no capture groups, returns the matching string (or list of strings for `re-seq`).
- If the regex contains capture groups, returns a **vector** where the first element is the full match and subsequent elements are the groups.

```clojure
(re-find (re-pattern "\\d+") "v1")              ; => "1"
(re-matches (re-pattern "\\d+") "123")          ; => "123"
(re-matches (re-pattern "\\d+") "123abc")       ; => nil (not entire string)
(re-find (re-pattern "(\\d+)-(\\d+)") "10-20")  ; => ["10-20" "10" "20"]
(re-seq (re-pattern "\\d+") "a1b22c333")        ; => ["1" "22" "333"]
(re-seq (re-pattern "(\\d)(\\w)") "1a2b")       ; => [["1a" "1" "a"] ["2b" "2" "b"]]
(re-split (re-pattern "\\s+") "a  b   c")       ; => ["a" "b" "c"]
(re-split (re-pattern ",") "a,b,c")             ; => ["a" "b" "c"]
```

**Note:** Regex literals (`#"..."`) are not supported. Use `(re-pattern "...")` instead. For simple delimiter splitting, prefer `(split s "delimiter")` or `(split-lines s)` for newlines.

**Safety Constraints:**
- **Match Limit:** Regex execution is restricted to 100,000 backtracking steps. Exceeding this limit (e.g., due to ReDoS) terminates evaluation with an error.
- **Input Truncation:** To prevent super-linear scaling on massive inputs, regex functions only scan the first 32KB of any input string.
- **Pattern Complexity:** Patterns are limited to 256 bytes in length.


```clojure
;; Failed parses

(parse-long "abc")         ; => nil
(parse-double "invalid")   ; => nil
(parse-long "42abc")       ; => nil (partial parse rejected - must consume entire string)
(parse-double "3.14 ")     ; => nil (trailing whitespace not allowed)
```

**Type checking:**
Both functions accept strings and return `nil` for non-string input. **Note: This diverges from Clojure 1.11+, which raises `IllegalArgumentException` for non-string input. PTC-Lisp returns `nil` for safety in agentic contexts.**

```clojure
(parse-long 42)            ; => ...
(parse-long nil)           ; => ...
(parse-double nil)         ; => ...
(parse-double 3.14)        ; => ...
```

**Use cases:**
Typical usage involves filtering valid parses from potentially invalid input:

```clojure
;; Extract valid integers from mixed data
(->> ["1" "2" "not-a-number" "4"]
     (map parse-long)
     (filter some?)
     (reduce + 0))  ; => 7
```

### 8.10 Function Combinators

| Function | Signature | Description |
|----------|-----------|-------------|
| `juxt` | `(juxt f1 f2 ...)` | Returns a function that applies all functions and returns a vector of results |

The `juxt` combinator creates a function that applies each of its argument functions to the same input and returns a vector containing all results. This is particularly useful for multi-criteria sorting and extracting multiple values at once.

```clojure
;; Basic usage: extract multiple values from a map
((juxt :name :age) {:name "Alice" :age 30})
; => ["Alice" 30]

;; Multi-criteria sorting (primary: priority, secondary: name)
(sort-by (juxt :priority :name) tasks)
; Sorts first by priority, then by name for equal priorities

;; Extracting coordinates from point maps
(map (juxt :x :y) points)
; => [[1 2] [3 4] ...]

;; Using closures for computed values
((juxt #(+ % 1) #(* % 2)) 5)
; => [6 10]

;; Using builtin functions
((juxt first last) [1 2 3])
; => [1 3]

;; Empty juxt returns empty vector
((juxt) {:a 1})
; => []
```

**Comparison with explicit function:**

```clojure
;; These are equivalent:
(sort-by (juxt :priority :name) tasks)
(sort-by (fn [t] [(:priority t) (:name t)]) tasks)

;; juxt is more concise for multiple key extraction
(map (juxt :id :name :email) users)
(map (fn [u] [(:id u) (:name u) (:email u)]) users)
```

**Supported function types:**
- Keywords (used as map accessors)
- Closures (`fn` and `#()` syntax)
- Builtin functions (`first`, `last`, `count`, etc.)

### 8.11 Functional Tools: apply

| Function | Signature | Description |
|----------|-----------|-------------|
| `apply` | `(apply f coll)` | Applies function `f` to the argument sequence `coll` |
| | `(apply f x y ... coll)` | Applies function `f` to `x`, `y`, ... and the argument sequence `coll` |

The `apply` function invokes a function `f` with the provided arguments. The last argument must be a collection (vector or set), which is "unrolled" into individual arguments. Any arguments between `f` and the collection are passed as fixed prefix arguments.

```clojure
;; Basic usage
(apply + [1 2 3])              ; => 6
(apply str ["a" "b" "c"])      ; => "abc"

;; Spreading with fixed arguments
(apply + 1 2 [3 4])            ; => 10
(apply merge {:a 1} [{:b 2} {:c 3}]) ; => {:a 1 :b 2 :c 3}

;; With Keywords as functions
(apply :name [{:name "Alice"}]) ; => "Alice"

;; With Sets as functions
(apply #{1 2 3} [2])           ; => 2

;; With filtering (passing apply as a value)
(map #(apply + %) [[1 2] [3 4]]) ; => [3 7]
```

**Edge Cases:**
- **Empty collection:** `(apply + [])` is equivalent to `(+)`, returning `0`.
- **Nil as last argument:** `(apply + 1 2 nil)` returns a `type-error`. PTC-Lisp requires an explicit collection.
- **Sets as last argument:** `(apply + 1 #{2 3})` is allowed, but since sets are unordered, the application order is undefined (not an issue for commutative operations like `+`).
- **Non-callable first argument:** Raises a `not-callable` error.
- **Non-collection last argument:** Raises a `type_error`.

### 8.12 Debugging with println

| Function | Signature | Description |
|----------|-----------|-------------|
| `println` | `(println ...)` | Prints arguments to the execution trace, separated by spaces. Returns `nil`. |

The `println` function is the **only way to inspect values** during multi-turn SubAgent execution. Expression results are NOT shown to the LLM — only explicit `println` output appears in feedback.

**Behavior:**
- Arguments are converted to Clojure syntax strings.
- Multiple arguments are separated by single spaces.
- Each `println` call results in a new line in the output buffer.
- Returns `nil`.

```clojure
(def results (tool/search {:q "test"}))
(println "Found:" (count results))      ; shown in feedback
(println "First:" (first results))      ; shown in feedback
results                                  ; NOT shown - use println to inspect
```

**Multi-Turn Feedback:**
In SubAgent multi-turn loops, the LLM only sees:
1. `println` output from the current turn
2. Stored symbol names (from `def`)
3. Turn information

Expression results are intentionally hidden to encourage explicit inspection and reduce token waste.

**Trace Output:**
Programs that call `println` will have their output available in the `prints` list of the result:

```elixir
# Result of Lisp.run(...)
{:ok, %Step{
  return: [...],
  prints: ["Found: 42", "First: {:id 1}"]
}}
```

**Note:** In parallel operations like `pmap`, `println` output from parallel branches is NOT captured. Only the main execution thread's output is captured.

### 8.13 Date and Time (Minimal Java Interop)

PTC-Lisp supports a minimal subset of Java interop for date and time handling, simulating the behavior of `java.util.Date`, `java.time.LocalDate`, and `java.lang.System`.

| Symbol | Signature | Description |
|--------|-----------|-------------|
| `java.util.Date.` | `(java.util.Date.)` | Current UTC time |
| | `(java.util.Date. arg)` | Construct from timestamp (ms/sec) or ISO-8601/RFC 2822 string |
| `java.time.LocalDate/parse` | `(java.time.LocalDate/parse s)` | Parse ISO-8601 date string into a Date object |
| `.getTime` | `(.getTime date)` | Return Unix timestamp in milliseconds (**DateTime only**) |
| `System/currentTimeMillis` | `(System/currentTimeMillis)` | Return current Unix milliseconds |

#### Constructor `java.util.Date.`

- **No arguments**: Returns a `DateTime` object for the current UTC time.
- **Integer argument**: Smart unit detection.
    - If `abs(ts) < 1,000,000,000,000`: Treated as **Unix seconds**.
    - Otherwise: Treated as **Unix milliseconds**.
- **String argument**: Attempts to parse in the following order:
    1. **ISO-8601** (e.g., `"2026-01-08T14:30:00Z"`)
    2. **Date-only ISO** (e.g., `"2026-01-08"`, defaults to midnight UTC)
    3. **RFC 2822** (e.g., `"Wed, 8 Jan 2026 14:30:00 +0000"`, common in email headers)

#### `java.time.LocalDate/parse`

- **Shorthand**: `(LocalDate/parse s)` is also supported.
- **Behavior**: Parses a string in ISO-8601 date format (`YYYY-MM-DD`). Returns an opaque Date object representing just the date (no time).
- **Format**: When displayed or returned to an LLM, it is formatted as an ISO string: `"2023-10-27"`.

#### Methods and Utilities

- **`.getTime`**: Takes a **DateTime** object (from `java.util.Date.`) and returns its value as Unix milliseconds (integer). **Note:** This method does not work on objects from `LocalDate/parse`.
- **`System/currentTimeMillis`**: Returns the current system time in milliseconds.

#### Errors and Type Safety
- Passing `nil` to `java.util.Date.`, `LocalDate/parse`, or `.getTime` raises an error.
- Invalid strings or types raise descriptive errors.
- **Unsupported Methods**: Calling unregistered dot-methods (e.g., `(.toString date)`) provides a hint listing supported interop functions.

#### Comparison
`java.util.Date` objects themselves do not support direct comparison via `>`, `<`. Instead, extract the milliseconds:
```clojure
(< (.getTime d1) (.getTime d2))  ; check if d1 is before d2
```

`LocalDate` objects can be compared by converting to strings as they are ISO-8601 formatted:
```clojure
(< (str d1) (str d2))  ; lexicographical comparison works for YYYY-MM-DD
```

### 8.14 String Methods (Java Interop)

PTC-Lisp supports Java-style string methods for common operations.

| Method | Signature | Description |
|--------|-----------|-------------|
| `.indexOf` | `(.indexOf s substr)` | Index of first occurrence, or -1 if not found |
| `.indexOf` | `(.indexOf s substr from)` | Index of first occurrence starting from position |
| `.lastIndexOf` | `(.lastIndexOf s substr)` | Index of last occurrence, or -1 if not found |

```clojure
(.indexOf "hello" "ll")      ; => 2
(.indexOf "hello" "x")       ; => -1
(.indexOf "hello" "l" 3)     ; => 3 (finds second 'l')
(.lastIndexOf "hello" "l")   ; => 3 (last 'l')
```

**Return Value**: These methods return -1 when the substring is not found (Java semantics), unlike Clojure which returns nil.

**Errors**: Passing a non-string raises a descriptive error:
```clojure
(.indexOf 123 "x")  ; => error: .indexOf: expected string, got integer
```

---

---

## 9. Namespaces, Context, and Tools

Programs have access to data and functions through **namespaced symbols** and **special forms**.

### 9.1 Namespace Overview

| Access Pattern | Source | Description |
|----------------|--------|-------------|
| Plain symbols | Stored values | Values from map returns (defined via `def` form) |
| `data/` | Current request context | Current request context (read-only) |
| `tool/` | Tool invocation | Call registered tools |
| `budget/` | Budget introspection | Query remaining budget (turns, tokens, depth) |
| `*1`, `*2`, `*3` | Recent results | Previous turn results (for debugging) |

### 9.2 Persistent Values — User Namespace symbols

Access values stored in the User Namespace as plain symbols. These values are defined using the `def` or `defn` forms and persist across turns within a session:

```clojure
high-paid          ; access symbol defined via (def high-paid ...)
orders             ; access symbol defined via (def orders ...)
query-count        ; access symbol defined via (def query-count ...)
```

Stored values are **read-only during evaluation** unless redefined via `def`. To update a value for the next turn, use `def` in your program (see Section 16).

```clojure
(def new-orders (tool/get-orders {:since "2024-01-01"}))
(def orders (concat orders new-orders))
orders ; return current total
```

With default values (using `or`):

```clojure
(def current-count (or query-count 0))
(def query-count (inc current-count))
query-count
```


### 9.3 Context Access — `data/`

Read from current request context using the `data/` namespace prefix:

```clojure
data/input                ; get :input from context
data/user-id              ; get :user-id from context
data/request-id           ; get :request-id from context
```

Context is **per-request** data passed by the host. It does not persist across turns.

```clojure
(->> data/expenses
     (filter (where :category = "travel"))
     (sum-by :amount))
```

### 9.4 Turn History — `*1`, `*2`, `*3`

Access results from previous turns using the turn history symbols:

```clojure
*1                        ; result from the previous turn (most recent)
*2                        ; result from 2 turns ago
*3                        ; result from 3 turns ago
```

**Semantics:**
- `*1` returns the result of the most recent turn
- Returns `nil` if the turn doesn't exist (e.g., `*1` on turn 1)
- Results are **truncated** to ~1KB to prevent memory bloat
- Use stored values (plain symbols from map returns) for persistent access to full values

**Use cases:**
- Quick inspection of previous results during debugging
- Lightweight chaining when full values aren't needed

```clojure
;; On turn 2, check if previous result was a list
(if (list? *1)
  (count *1)
  0)

;; Compare current with previous
(> (count data/items) (count *1))
```

**For reliable multi-turn patterns**, use `(def name value)` to store values in the User Namespace. Turn history (`*1`, `*2`, `*3`) is primarily a debugging aid, not a storage mechanism.

### 9.5 Budget Introspection — `budget/remaining`

Query the remaining budget using the `budget/` namespace. This enables programs to make intelligent decisions based on available resources.

```clojure
(budget/remaining)            ; returns budget map
```

**Return value:**

The `budget/remaining` primitive returns a map with hyphenated keys (Clojure-style):

```clojure
{:turns 15                    ; total turns remaining
 :work-turns 10               ; work turns remaining
 :retry-turns 5               ; retry turns remaining
 :depth {:current 1 :max 3}   ; nesting depth info
 :tokens {:input 5000         ; input tokens used
          :output 2000        ; output tokens used
          :total 7000         ; total tokens used
          :cache-creation 1000
          :cache-read 2000}
 :llm-requests 3}             ; LLM API calls made
```

**Accessing hyphenated keys:**

```clojure
(:work-turns (budget/remaining))              ; => 10
(:retry-turns (budget/remaining))             ; => 5
(:cache-read (:tokens (budget/remaining)))    ; => 2000
```

**Use cases:**

- Adjust processing strategy based on remaining turns
- Batch operations when budget is low
- Log resource usage for monitoring

```clojure
;; Choose strategy based on remaining budget
(let [b (budget/remaining)
      items data/items]
  (if (< (:turns b) (count items))
    ;; Low budget: batch process
    (tool/batch-process {:items items})
    ;; High budget: process individually
    (mapv (fn [i] (tool/process {:item i})) items)))
```

**Note:** Returns an empty map `{}` when running outside a SubAgent context (e.g., standalone `Lisp.run/2` without budget option).

### 9.6 Tool Invocation — `tool/tool-name`

Invoke registered tools using the `tool/` namespace:

```clojure
(tool/tool-name)                   ; no arguments
(tool/tool-name args-map)          ; with arguments (named parameters)
```

**Syntax:**
- Tool names become atoms in `tool/` namespace: `tool/tool-name`
- **Tools require named arguments** (maps):
  - No arguments: `(tool/get-users)` → tool receives `%{}`
  - Map argument: `(tool/fetch {:id 123})` → tool receives `%{"id" => 123}`
  - Keyword-style: `(tool/search :query "x" :limit 10)` → tool receives `%{"query" => "x", "limit" => 10}`

**Examples:**
```clojure
(tool/get-users)                   ; no arguments
(tool/search {:query "budget"})    ; single map argument
(tool/fetch {:id 123})             ; with parameters
(tool/search {:query "foo" :limit 10})

;; Store tool result for later use
(let [users (tool/get-users)]
  (->> users
       (filter (where :active))
       (count)))
```

**Tool boundary contract:**
- PTC-Lisp keywords (`:foo`) become **string keys** at the Elixir boundary
- Tools always receive string-keyed maps: `%{"key" => value}`
- This matches JSON conventions and prevents atom memory leaks
- Tool authors pattern match on string keys: `def run(%{"query" => q}, _ctx)`

**Tool behavior:**
- Tools are Elixir functions registered by the host
- Tools may have side effects (external API calls, database queries)
- Tool errors propagate as execution errors
- Tool calls are logged for auditing

### 9.7 Clojure Namespace Compatibility

LLMs often generate code with Clojure-style namespaced symbols. PTC-Lisp normalizes these to built-in functions at analysis time.

**Supported namespaces:**

| Namespace | Shorthand | Category |
|-----------|-----------|----------|
| `clojure.string` | `str`, `string` | String functions |
| `clojure.core` | `core` | Core functions |
| `clojure.set` | `set` | Set functions |
| `System` | - | Java System properties/time |
| `java.util.Date` | - | Java Date constructors |
| `java.time.LocalDate` | `LocalDate` | Java Date parsing (ISO-8601) |

**Examples of normalization:**

```clojure
;; These all normalize to the same built-in function:
(clojure.string/join "," items)   ; → (join "," items)
(str/join "," items)               ; → (join "," items)
(join "," items)                   ; (no change)

;; Core functions work too:
(clojure.core/map inc xs)          ; → (map inc xs)
(core/filter even? xs)             ; → (filter even? xs)
```

**Error handling:**

When a namespaced function doesn't exist as a built-in, the analyzer provides helpful error messages with available alternatives:

```clojure
(clojure.string/capitalize s)
;; Error: capitalize is not available. String functions: str, subs, join, split, trim, ...

(clojure.set/project relations [:id])
;; Error: project is not available. Set functions: set, set?, vec, vector, contains?, intersection, union, difference
```

**Note:** The `data/` and `tool/` namespaces are reserved for context access and tool invocation respectively. Clojure-style namespaces cannot be used for these purposes.

---

## 10. Complete Examples

### 10.1 Filter and Sum (Pure Query)

Filter expenses by category and sum amounts:

```clojure
(->> data/expenses
     (filter (where :category = "travel"))
     (sum-by :amount))
```

Returns a number. No memory update (non-map result).

### 10.2 Find Single Item

Find the cheapest product:

```clojure
(min-by :price data/products)
```

Find employee with most years:

```clojure
(max-by :years-employed data/employees)
```

### 10.3 Sort and Limit

Get top 5 products by price:

```clojure
(->> data/products
     (sort-by :price >)
     (take 5))
```

### 10.4 Extract Field Values

Get all product names:

```clojure
(pluck :name data/products)
;; or
(map :name data/products)
```

### 10.5 Conditional Classification

Classify invoice by total:

```clojure
(let [{:keys [total]} data/invoice]
  (cond
    (> total 1000) "high-value"
    (> total 100)  "medium-value"
    :else          "low-value"))
```

### 10.6 Complex Filtering

Find eligible orders (high value, premium status, not flagged):

```clojure
(->> data/orders
     (filter (all-of (where :total > 100)
                     (any-of (where :status = "vip")
                             (where :status = "premium"))
                     (none-of (where :flagged)))))
```

### 10.7 Transform and Select Fields

Get names and emails of active users:

```clojure
(->> data/users
     (filter (where :active))
     (mapv (fn [u] (select-keys u [:name :email]))))
```

### 10.8 Combine Multiple Data Sources

Join orders with user information:

```clojure
(let [users (tool/get-users)
      orders (tool/get-orders)]
  (->> orders
       (filter (where :total > 100))
       (mapv (fn [order]
               (let [user (find (where :id = (:user-id order)) users)]
                 (merge order (select-keys user [:name :email])))))))
```

### 10.9 Grouping and Aggregation

Sum expenses by category:

```clojure
(let [by-category (group-by :category data/expenses)]
  (->> (keys by-category)
       (mapv (fn [cat]
               {:category cat
                :total (sum-by :amount (get by-category cat))}))))
```

### 10.10 Nested Data Access

Get email from nested user profile:

```clojure
(get-in data/user [:profile :contact :email])
```

Filter by nested field:

```clojure
(->> data/users
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
| `(distinct-by :x [])` | `[]` | `[]` |
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
(and false (tool/expensive))  ; "expensive" not called
(or true (tool/expensive))   ; "expensive" not called
```

### 11.7 Keyword as Function with Default

```clojure
(:name {:name "Alice"})           ; => "Alice"
(:name {})                        ; => nil
(:name {} "Unknown")              ; => "Unknown"
```

### 11.8 Map as Function

Maps can be called as functions with a keyword argument:

```clojure
({:name "Alice"} :name)           ; => "Alice"
({} :name)                        ; => nil
({} :name "Unknown")              ; => "Unknown"
```

### 11.9 Flatten Behavior

`flatten` recursively flattens nested collections:

```clojure
(flatten [[1 2] [3 [4]]])         ; => [1 2 3 4]
(flatten [1 [2 {:a 3}] "str"])    ; => [1 2 {:a 3} "str"]
```

- Only vectors are flattened (they satisfy `coll?`)
- Maps, strings, and other non-collection values pass through unchanged
- Flattening depth is bounded by `max_depth` limit

### 11.10 Tool Call Evaluation Order

Tool calls are evaluated in left-to-right order and never reordered:

```clojure
(let [a (tool/tool-1)   ; called first
      b (tool/tool-2)]  ; called second
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
| `arithmetic-error` | Arithmetic operation error (division by zero) |
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
    (let [items data/data] ...)
```

### 12.3 Common Errors and Hints

| Error | Hint |
|-------|------|
| Unknown symbol `foo` | Did you mean: `filter`, `first`, `find`? |
| `where` missing operator | Use `(where :field = value)`, not `(where :field value)` |
| Wrong arity for `if` | `if` requires 2 or 3 arguments (condition, then, else?) |
| `let` bindings not paired | `let` requires an even number of binding forms |

---

## 13. What Is NOT Supported

### 13.1 Language Features

| Feature | Reason |
|---------|--------|
| `lazy-seq` | All operations are eager |
| Macros | No metaprogramming |
| Namespaces (user-defined) | No modules |
| Full Java interop | Security (Minimal subset for Date/Time supported: see §8.13) |
| Atoms, refs, agents | No mutable state |
| `eval`, `read-string` | Security |
| File I/O (`slurp`, `spit`) | Security |
| Regex literals | Complexity (use `re-pattern`) |
| Multi-methods, protocols | Complexity |
| `try`, `catch`, `throw` | No exception handling (use `fail` for errors) |

**Note:** `println` IS supported — see section 8.12. It writes to an internal trace buffer, not stdout.

### 13.2 Anonymous Functions

Anonymous functions are supported via `fn` or `#()` shorthand with restrictions:

#### Full `fn` Syntax

```clojure
(fn [x] body)           ; single argument
(fn [a b] body)         ; multiple arguments
(fn [a & rest] body)    ; variadic arguments
(fn [[a b]] body)       ; vector destructuring in params
(fn [{:keys [x]}] body) ; map destructuring in params
```

**Implicit `do` (Clojure Extension):** Multiple body expressions are supported:

```clojure
(fn [x]
  (def last-input x)   ; side effect
  (* x 2))             ; return value
```

#### Short `#()` Syntax

The `#()` shorthand syntax provides concise lambdas (like Clojure):

```clojure
#(+ % 1)           ; % is the first parameter (p1)
#(+ %1 %2)         ; explicit numbered parameters
#(* % %)           ; same parameter used multiple times
#(42)              ; zero-arity thunk (no parameters)
```

The `#()` syntax desugars to the equivalent `fn`:
- `#(+ % 1)` → `(fn [p1] (+ p1 1))`
- `#(+ %1 %2)` → `(fn [p1 p2] (+ p1 p2))`
- `#()` with no placeholders → `(fn [] ...)`
- Arity is determined by the highest numbered placeholder, or 1 if only `%` is used

**Restrictions:**
- `#()` accepts a single expression as the body
- `%` and `%1`, `%2`, etc. are parameter placeholders (not regular symbols within `#()`)
- Nested `#()` is not allowed
- Recursion is supported via `recur` (no self-reference by name, see §5.9)
- Closures over local `let` bindings are allowed
- No closures over mutable host state (there is none)

**Examples:**
```clojure
;; Filter with #() shorthand
(filter #(> % 10) items)

;; Map with string construction
(map #(str "id-" %) items)

;; Transform each item with fn (more complex)
(mapv (fn [u] (select-keys u [:name :email])) users)

;; Access outer let bindings (closure)
(let [threshold 100]
  (filter #(> (:price %) threshold) products))

;; Destructuring in fn params
(mapv (fn [{:keys [name age]}] {:name name :years age}) users)
```

**When to use `#()` vs `fn` vs `where`:**
- Use `#()` for simple, single-argument lambdas (most common LLM use case)
- Use `fn` for complex logic, destructuring, or multiple parameters
- Use `where` for simple field comparisons in `filter`/`remove`/`find`

### 13.3 Functions Excluded from Core

- `iterate`, `repeat`, `cycle` (infinite sequences)
- Infinite `(range)` (standard finite `range` is supported: see §8.1)
- `partial`, `comp` (function composition)
- Transducers

### 13.4 Clojure Compatibility Issues

The following behaviors differ from standard Clojure/Babashka:

| Issue | PTC-Lisp Behavior | Clojure Behavior | Workaround |
|-------|-------------------|------------------|------------|
| `keys` return type | Returns keywords (atoms) | Returns keywords | Use `(count (keys m))` for comparison |

**Example workarounds:**

```clojure
;; Instead of possibly-nil values having to be guarded before destructuring
;; You can now destructure nil directly (returns nil for all bindings)
(let [{:keys [a]} nil]
  a) ; => nil
```

---

## 14. Grammar (EBNF)

```ebnf
program     = expression* ;  (* Multiple top-level expressions with implicit do *)

expression  = literal
            | symbol
            | keyword
            | vector
            | set
            | map
            | list-expr ;

literal     = nil | boolean | number | string | char ;

nil         = "nil" ;
boolean     = "true" | "false" ;
number      = integer | float ;
integer     = ["-"] digit+ ;
float       = ["-"] digit+ "." digit+ [exponent]
            | ["-"] digit+ exponent ;
exponent    = ("e" | "E") ["+" | "-"] digit+ ;
string      = '"' string-char* '"' ;
string-char = escape-seq | (any char except '"', '\', and newline) ;
escape-seq  = '\\' ('"' | '\\' | 'n' | 't' | 'r') ;
char        = '\\' (char-name | any-char) ;
char-name   = "newline" | "space" | "tab" | "return" | "backspace" | "formfeed" ;
any-char    = (any single Unicode grapheme) ;

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
- `/` is allowed in symbols for namespaced access (`data/bar`, `tool/bar`)
- `/` is NOT allowed in keywords (`:foo/bar` is invalid)
- The operator position in `list-expr` accepts any expression, enabling:
  - `(:name user)` — keyword as function
  - `((fn [x] x) 42)` — anonymous function application
  - `(tool/tool-name args)` — tool invocation

**Tokenization precedence:** When a token could match multiple grammar rules, literals take precedence over symbols:
1. `nil`, `true`, `false` → reserved literals (not symbols)
2. `-123`, `3.14` → numbers (not symbols starting with `-` or digits)
3. `:foo` → keyword
4. `\a`, `\newline` → character literal
5. Everything else → symbol

This means `-1` is always the integer negative one, never a symbol named "-1". Similarly, `\r` is the character "r", not a symbol.

---

## 15. Implementation Notes

### 15.1 Evaluation Model

- Programs can contain multiple expressions (evaluated sequentially, last value returned)
- Evaluation is strict (eager), not lazy
- No side effects except tool calls
- Tools may have side effects (external)

### 15.2 Resource Limits

| Resource | Default | Notes |
|----------|---------|-------|
| Timeout | 1,000 ms | Execution time limit |
| Max Heap | ~10 MB | Memory limit (1,250,000 words) |

*Note: Hosts may configure higher timeouts (e.g., 5,000ms) to accommodate slow tool calls.*

### 15.3 Compatibility Testing

Programs should produce identical results when run in:
1. PTC-Lisp interpreter (Elixir)
2. Clojure (with stub implementations for `data/`, `tool/`, `call`, `where`, etc.)

---

## 16. Memory Model for Agentic Loops

This section specifies how PTC-Lisp programs interact with persistent memory across multiple turns in an LLM-agent loop.

### 16.1 Core Principle: Functional Transactions

Programs are **pure functions** that:
- Read from stored values (plain symbols) and `data/` namespace
- Return a result value
- The result determines stored value updates

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

### 16.3 Result Contract (V2 Simplified Model)

The program's return value is passed through unchanged. Storage is explicit via `def`:

| Behavior | How It Works |
|----------|--------------|
| **Return value** | Last expression result (standard REPL semantics) |
| **Persistent storage** | Use `(def name value)` to store values |
| **Access stored values** | Use plain symbols (e.g., `my-value`) |

**No implicit map merge.** Unlike earlier versions, returning a map does NOT automatically store its keys. Use `def` for explicit storage.

#### Pure Query (No Storage)

```clojure
;; Returns a number - nothing stored
(->> data/expenses
     (filter (where :category = "travel"))
     (sum-by :amount))
```

#### Explicit Storage with def

```clojure
;; Store values explicitly, return a result
(def high-paid (->> (tool/find-employees {})
                    (filter (where :salary > 100000))))
(def last-query "employees")
(pluck :email high-paid)
```

After execution:
- `high-paid` = the filtered list (available as symbol in next turn)
- `last-query` = `"employees"` (available as symbol in next turn)
- Return value = `["alice@example.com", "bob@example.com", ...]`

#### Return Map Without Storage

Maps return as-is, no special handling:

```clojure
;; Returns a map - nothing stored unless you use def
{:summary "Query complete"
 :count (count data/items)
 :items data/items}
```

Return value = `{:summary "Query complete", :count 5, :items [...]}`, no symbols stored.

### 16.4 Symbol Storage Semantics

Values stored via `def` persist across turns. Each `def` sets a single key:

```clojure
;; Turn 1: Store values
(def a 1)
(def b {:x 10})
"stored"

;; Turn 2: Access and update
(def b {:y 20})  ; replaces previous value
(def c 3)        ; new value
{:a a, :b b, :c c}
```

After Turn 2: `a=1, b={:y 20}, c=3`

- New symbols are added
- Existing symbols are replaced (not deep-merged)
- Symbols not referenced remain unchanged

### 16.5 Execution Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  AGENTIC LOOP EXECUTION FLOW                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. HOST BUILDS ENVIRONMENT                                     │
│     ├─ Load stored symbols from previous turns (def bindings)   │
│     ├─ Attach current request context                           │
│     └─ Register available tools                                 │
│                                                                 │
│  2. RECEIVE PROGRAM FROM LLM                                    │
│     └─ Parse source → AST                                       │
│                                                                 │
│  3. EXECUTE IN SANDBOX                                          │
│     ├─ Validate AST                                             │
│     ├─ Evaluate with resource limits                            │
│     ├─ Track def bindings (become symbols for next turn)        │
│     └─ Track tool calls for logging                             │
│                                                                 │
│  4. HANDLE RESULT                                               │
│     │                                                           │
│     ├─ ON SUCCESS:                                              │
│     │   ├─ Return last expression value (standard REPL)         │
│     │   ├─ Persist def bindings as symbols                      │
│     │   └─ Log: program, tool calls, stored symbols, result     │
│     │                                                           │
│     └─ ON ERROR:                                                │
│         ├─ NO symbol changes (rollback)                         │
│         ├─ Log: program, error, partial trace                   │
│         └─ Return error to LLM for retry                        │
│                                                                 │
│  5. NEXT TURN                                                   │
│     ├─ Feed stored symbols to LLM                               │
│     └─ LLM generates next program                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 16.6 Multi-Turn Example

**Turn 1:** Find high-paid employees and store with def

```clojure
(def high-paid (->> (tool/find-employees {})
                    (filter (where :salary > 100000))))
(count high-paid)
```

*Returns:* `5`
*Symbols stored:* `{:high-paid [{:id 1, :name "Alice", :salary 150000}, ...]}`

**Turn 2:** Query stored data (no symbol update)

```clojure
(count high-paid)
```

*Returns:* `5`
*Symbols unchanged*

**Turn 3:** Fetch orders for stored employees, add new symbol

```clojure
(def orders (let [ids (pluck :id high-paid)]
              (tool/get-orders {:employee-ids ids})))
{:orders-count (count orders)}
```

*Returns:* `{:orders-count 42}`
*Symbols stored:* `{:high-paid [...], :orders [...]}`

**Turn 4:** Return summary

```clojure
{:employee-count (count high-paid)
 :order-count (count orders)}
```

*Returns:* `{:employee-count 5, :order-count 42}`
*Symbols unchanged*

### 16.7 Logging and Audit Trail

Every execution produces a log entry:

```elixir
%{
  call_id: "uuid-...",
  turn: 3,
  timestamp: ~U[2024-01-15 10:30:00Z],

  # Input
  program_source: "(do (def orders (call \"get-orders\" {:ids (pluck :id high-paid)})) ...)",
  memory_before: %{high_paid: [...]},
  ctx: %{user_id: "user-123"},

  # Execution trace
  tool_calls: [
    %{tool: "get-orders", args: %{ids: [1, 2, 3]},
      result_size: 42, duration_ms: 150}
  ],

  # Output
  status: :success,  # or :error
  result: {:orders-count 42},  # last expression value
  memory_after: %{high_paid: [...], orders: [...]},  # includes def bindings

  # Metrics
  duration_ms: 180,
  memory_bytes: 102400
}
```

### 16.8 Resource Limits for Agentic Execution

| Limit | Default | Description |
|-------|---------|-------------|
| `timeout_ms` | 1,000 | Max execution time per program |
| `max_heap` | ~10 MB | Memory limit (1,250,000 words) |
| `max_tool_calls` | 10 | Max tool invocations per program *(planned)* |

*Note: Hosts can configure higher timeouts (e.g., 5,000ms) to accommodate slow tool calls.*

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
| `{"op": "load", "name": "x"}` | `data/x` |
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
| `{"op": "call", "tool": "t"}` | `(tool/t)` |
| `{"op": "and", "conditions": [...]}` | `(and ...)` |
| `{"op": "merge", "objects": [...]}` | `(merge ...)` |

---

## Appendix B: Symbol Resolution

### Resolution Order

When the interpreter encounters a symbol, it resolves in this order:

1. **Local bindings** — `let`-bound variables in current scope
2. **Namespaced symbols** — `memory/x`, `data/y`, `tool/z`
3. **Built-in functions** — `filter`, `map`, `count`, etc.

### Namespace Symbols

| Pattern | Resolves To |
|---------|-------------|
| `memory/foo` | `(get env.memory :foo)` |
| `data/bar` | `(get env.data :bar)` |
| `tool/baz` | Tool invocation |
| `foo` | Local binding or built-in |

### Example

```clojure
(let [x 10]                    ; x is local
  (+ x                         ; resolves to local x (10)
     memory/x                  ; resolves to env.memory[:x]
     data/x))                  ; resolves to env.data[:x]
```

### Whole Map Access

The bare symbols `memory` and `data` are **not accessible** as whole maps. Only namespaced access is allowed:

```clojure
memory/foo     ; OK - access :foo key
data/bar       ; OK - access :bar key
memory         ; ERROR - cannot access whole memory map
data           ; ERROR - cannot access whole data map
(keys memory)  ; ERROR - memory is not a value
```

This restriction prevents accidental data leakage and simplifies reasoning about what data a program can access.

---

## Appendix C: Documentation Tests

This specification contains executable examples that are automatically validated against the PTC-Lisp implementation using `PtcRunner.Lisp.SpecValidator`.

### Example Syntax

Examples use the pattern `code  ; => expected` where the expected value is parsed and compared to the actual execution result:

```clojure
(+ 1 2)                ; => 3
(filter even? [1 2 3]) ; => [2]
{:a 1 :b 2}            ; => {:a 1 :b 2}
```

### Semantic Markers

For examples that cannot be automatically validated, use these markers:

| Marker | Meaning | Example |
|--------|---------|---------|
| `; => TODO: description` | Feature not yet implemented | `; => TODO: :or defaults not implemented` |
| `; => BUG: description` | Known bug | `; => BUG: edge case fails` |
| `; => ...` | Illustrative example (requires external context) | `; => ...` |

**When to use each:**

- **TODO** — The feature is documented but the implementation is incomplete. Running the example would fail.
- **BUG** — The example documents expected behavior but currently fails due to a known bug.
- **...** — The example requires external context (tools, data/memory data) that isn't available during automated testing. These are illustrative examples showing usage patterns.

### Running Validation

```elixir
# Validate all examples
{:ok, results} = PtcRunner.Lisp.SpecValidator.validate_spec()

# Results include:
# - passed: count of passing examples
# - failed: count of failing examples
# - todos: list of {code, description, section} tuples
# - bugs: list of {code, description, section} tuples
# - skipped: count of illustrative examples (using ...)
```


### Supported Expected Values

The validator can parse these value types:

- **Literals**: `nil`, `true`, `false`, integers (`42`), floats (`3.14`)
- **Strings**: `"hello"` (with escape sequences)
- **Keywords**: `:name`, `:user-id`
- **Collections**: `[1 2 3]`, `(1 2 3)`
- **Maps**: `{:a 1 :b 2}` (simple keyword/value pairs only)
