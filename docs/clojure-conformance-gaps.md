# Clojure Conformance Gaps

Tracked differences between PTC-Lisp and Clojure semantics, discovered via conformance testing against SCI, Babashka, Joker, and manual investigation.

**Test file:** `test/ptc_runner/lisp/sci_conformance_test.exs`
**Related issue:** [#832](https://github.com/andreasronge/ptc_runner/issues/832)
**Audit (function coverage):** `docs/clojure-core-audit.md`

## Priority Levels

| Level | Meaning |
|-------|---------|
| **P0** | Breaks idiomatic Clojure patterns; likely to cause silent bugs in LLM-generated code |
| **P1** | Missing feature that limits expressiveness; workarounds exist |
| **P2** | Edge case or minor divergence; rarely encountered in practice |

---

## 1. Semantics — Supported features with incorrect behavior

Features marked ✅ in the audit but whose behavior diverges from Clojure.

### GAP-S01: `and`/`or` return boolean instead of actual value

| Field | Value |
|-------|-------|
| **Priority** | P0 |
| **Status** | open |
| **Source** | SCI `core-test` line 81, `do-and-or-test` line 1812 |

**Clojure behavior:** `and` returns the last truthy value or the first falsey value. `or` returns the first truthy value or the last falsey value.

```clojure
;; Clojure
(and true true 0)   ;=> 0
(and 1)             ;=> 1
(and 1 nil)         ;=> nil

;; PTC-Lisp (incorrect)
(and true true 0)   ;=> true
(and 1)             ;=> true
```

**Impact:** Breaks idiomatic patterns like `(and (get m :key) (process it))` and `(or val (compute-default))` where the return value matters.

### GAP-S02: `#()` wrapping a `defn` call returns closure instead of invoking

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | SCI `core-test` line 92 |

```clojure
;; Clojure
(do (defn foo [] 1) (#(foo)))   ;=> 1

;; PTC-Lisp (incorrect)
(do (defn foo [] 1) (#(foo)))   ;=> <closure object>
```

### GAP-S03: `defn` inside `let` not visible across program expressions

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | SCI `closure-test` line 185 |

```clojure
;; Clojure
(let [x 1] (defn foo [] x)) (foo)   ;=> 1

;; PTC-Lisp
(let [x 1] (defn foo [] x)) (foo)   ;=> error: Undefined variable: foo
```

`defn` inside a `let` should register the var at the top-level scope (it creates a global var in Clojure). The second program expression `(foo)` cannot see it.

---

## 2. Special Forms — Missing or broken language constructs

### GAP-F01: Named `fn` not supported

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | SCI `fn-test` line 199 |

Clojure allows `(fn name [args] body)` where `name` is bound inside the body for self-recursion.

```clojure
;; Clojure
((fn foo [x] (if (< x 3) (foo (inc x)) x)) 0)   ;=> 3

;; PTC-Lisp
((fn foo [x] (if (< x 3) (foo (inc x)) x)) 0)   ;=> error
```

This is the standard pattern for recursive anonymous functions. Without it, users must use `defn` + separate call or `loop`/`recur`.

**Variants also affected:**
- Named fn with rest args: `((fn foo [x & xs] xs) 1 2 3)`
- Named fn with destructuring: `((fn foo [[x & xs]] xs) [1 2 3])`

### GAP-F02: Destructuring inside rest args

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | SCI `fn-test` line 206 |

```clojure
;; Clojure
((fn [x & [y]] y) 1 2 3)   ;=> 2

;; PTC-Lisp
((fn [x & [y]] y) 1 2 3)   ;=> error
```

The `& [y]` pattern destructures the rest args as a vector. Less common than plain `& xs` but used in Clojure code.

---

## 3. Core Functions — Missing functions

Functions listed as `🔲 candidate` in the audit that showed up in conformance testing.

### GAP-C01: `int?` predicate not implemented

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | SCI `cond-test` line 832; audit lists as candidate |
| **Audit status** | `🔲 candidate` |

```clojure
;; Clojure
(int? 2)       ;=> true
(int? 2.0)     ;=> false
(int? "hello") ;=> false
```

Also missing from the same family: `nat-int?`, `neg-int?`, `pos-int?` (all `🔲 candidate` in audit).

### GAP-C02: `comment` form not supported

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | SCI `comment-test` line 632 |

```clojure
;; Clojure
(comment "anything")     ;=> nil
(comment (+ 1 2 3))     ;=> nil

;; PTC-Lisp
(comment "anything")     ;=> error: Undefined variable: comment
```

`comment` ignores all its arguments and returns nil. Useful for documentation and REPL exploration.

### GAP-C03: `%&` rest args in anonymous function shorthand

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | SCI `fn-literal-test` line 196 |

```clojure
;; Clojure
(apply #(do %&) [1 2 3])   ;=> (1 2 3)

;; PTC-Lisp
(apply #(do %&) [1 2 3])   ;=> error
```

### GAP-C04: `:strs` map destructuring

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | SCI `destructure-test` line 139 |

```clojure
;; Clojure
((fn [{:strs [a]}] a) {"a" 1})   ;=> 1

;; PTC-Lisp
((fn [{:strs [a]}] a) {"a" 1})   ;=> error
```

Destructuring with `:strs` binds string keys to local variables. Less common than `:keys` but used with JSON-like data.

---

### Additional semantics gaps

### GAP-S04: `assoc` with many key-value pairs

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | SCI `more-than-twenty-args-test` line 1596 |

```clojure
;; Clojure
(assoc {} 1 2 3 4 5 6 7 8 9 1 2 3 4 5 6 7 8 9 1 2 3 4 5 6 7 8 9 10)
;=> {1 2, 2 3, 3 4, 4 5, 5 6, 6 7, 7 8, 8 9, 9 10}

;; PTC-Lisp: errors or produces wrong result
```

### GAP-S05: No duplicate key detection at runtime in set/map literals

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | SCI `core-test` line 114-116 |

```clojure
;; Clojure: throws "Duplicate key: 1"
(let [a 1 b 1] #{a b})

;; PTC-Lisp: silently creates #{1} (no error)
```

Clojure detects duplicate keys at runtime when computed values collide. PTC-Lisp silently deduplicates.

### GAP-S06: Parameter named `fn` shadows builtin incorrectly

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | SCI `variable-can-have-macro-or-var-name` line 904 |

```clojure
;; Clojure
(defn foo [fn] (fn 1)) (foo inc)   ;=> 2

;; PTC-Lisp: errors (parameter named `fn` doesn't properly shadow the special form)
```

### GAP-S07: Keyword args via rest destructuring `[& {:keys [a]}]`

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | SCI `defn-kwargs-test` line 303 |

```clojure
;; Clojure
(defn foo [& {:keys [a]}] {:a a}) (foo :a 1)   ;=> {:a 1}

;; PTC-Lisp
;; error: destructure_error: expected map or nil, got [:a, 1]
```

Clojure auto-coerces rest args to a map when the destructuring pattern is a map. This enables keyword-argument style calling.

---

## Intentional Divergences — By design, not bugs

Documented differences where PTC-Lisp intentionally departs from Clojure for sandbox safety or simplicity.

### DIV-01: Loop/recursion iteration limit

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | SCI `recur-test` line 667 |

PTC-Lisp enforces a default limit of 1,000 iterations (configurable up to 10,000) on `loop`/`recur` and recursive function calls. Clojure has no such limit.

```clojure
;; Clojure: succeeds
(defn hello [x] (if (< x 10000) (recur (inc x)) x)) (hello 0)   ;=> 10000

;; PTC-Lisp: loop_limit_exceeded (default limit 1000)
```

**Rationale:** Sandbox safety. LLM-generated code must terminate within bounded time/memory. See `lib/ptc_runner/lisp/eval/context.ex`.

### DIV-02: No lazy sequences

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

All collection operations are eager. `(range)` without arguments is not supported; bounds must be specified. No `lazy-seq`, `iterate`, or infinite sequences.

**Rationale:** Sandbox safety and simplicity. All operations must complete within timeout.

### DIV-03: Comparison operators are strictly 2-arity

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

```clojure
;; Clojure
(< 1 2 3)   ;=> true (chained comparison)

;; PTC-Lisp
(< 1 2 3)   ;=> error (only 2 args allowed)
```

### DIV-04: No macros, eval, or metaprogramming

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

No `defmacro`, `macroexpand`, `eval`, `read-string`. LLM safety boundary.

### DIV-05: No mutable state

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

No `atom`, `ref`, `agent`, `swap!`, `reset!`. Pure functional only.

---

## Adding New Gaps

When conformance testing reveals a new gap:

1. Classify it: Semantics (S), Special Form (F), Core Function (C), or Intentional Divergence (DIV)
2. Assign the next number in that category (e.g., GAP-S04)
3. Set priority: P0 if it causes silent wrong results, P1 if it errors where Clojure succeeds, P2 if edge case
4. Include a minimal reproducer with both Clojure and PTC-Lisp output
5. Note the source (SCI test name + line, Joker test, manual, etc.)
