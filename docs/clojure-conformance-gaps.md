# Clojure Conformance Gaps

Tracked differences between PTC-Lisp and Clojure semantics, discovered via conformance testing against SCI, Babashka, Joker, and manual investigation.

**Test file:** `test/ptc_runner/lisp/sci_conformance_test.exs`
**Design policy:** see the *Design Philosophy* section in [`docs/ptc-lisp-specification.md`](ptc-lisp-specification.md)
**Function reference:** [`docs/function-reference.md`](function-reference.md)

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
| **Status** | **fixed** |
| **Source** | SCI `core-test` line 81, `do-and-or-test` line 1812 |

**Clojure behavior:** `and` returns the last truthy value or the first falsey value. `or` returns the first truthy value or the last falsey value.

**Fix:** `do_eval_and` now tracks the last evaluated truthy value and returns it when the expression list is exhausted, matching Clojure semantics. `or` was already correct.

### GAP-S02: `#()` wrapping a `defn` call returns closure instead of invoking

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | SCI `core-test` line 92 |

**Fix:** `#(foo)` short fn desugaring now wraps a single symbol as a function call `(fn [] (foo))` instead of a variable reference.

### GAP-S03: `defn` inside `let` not visible across program expressions

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | SCI `closure-test` line 185 |

**Fix:** Static analysis (`collect_undefined_vars`) now uses `extract_def_names/1` to find `def`/`defonce` names inside definite-execution contexts (`let`, `do`, `loop`), propagating them to subsequent program expressions. Runtime eval already handled this correctly.

---

## 2. Special Forms — Missing or broken language constructs

### GAP-F01: Named `fn` not supported

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | SCI `fn-test` line 199 |

**Fix:** Added named `fn` support: `(fn name [params] body)` stores the name in closure metadata, and `do_execute_closure` binds the closure to its name at call time for self-recursion. Variants with rest args and destructuring also work.

### GAP-F02: Destructuring inside rest args

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | SCI `fn-test` line 206 |

**Fix:** Already working — rest args with vector destructuring (`[& [y]]`) are handled correctly by the existing variadic binding + pattern matching logic.

---

## 3. Core Functions — Missing functions

Functions listed as `🔲 candidate` in the audit that showed up in conformance testing.

### GAP-C01: `int?` predicate not implemented

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | SCI `cond-test` line 832; audit lists as candidate |
| **Audit status** | `🔲 candidate` |

**Fix:** Added `int?` predicate delegating to `is_integer/1`. Still missing from the same family: `nat-int?`, `neg-int?`, `pos-int?` (all `🔲 candidate` in audit).

### GAP-C02: `comment` form not supported

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | SCI `comment-test` line 632 |

**Fix:** Added `comment` as a special form in the analyzer that returns `nil` without evaluating its arguments.

### GAP-C03: `%&` rest args in anonymous function shorthand

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | SCI `fn-literal-test` line 196 |

**Fix:** Updated `placeholder?` to recognize `%&`, and extended the short fn desugarer (`determine_arity`, `generate_params`, `placeholder_to_param`) to produce variadic `(fn [p1 & rest] ...)` forms when `%&` is present.

### GAP-C04: `:strs` map destructuring

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | fixed |
| **Source** | SCI `destructure-test` line 139 |

```clojure
;; Clojure
((fn [{:strs [a]}] a) {"a" 1})   ;=> 1

;; PTC-Lisp
((fn [{:strs [a]}] a) {"a" 1})   ;=> 1
```

**Fix:** Added `:strs` as a parallel pattern type to `:keys` across analyzer, pattern matcher, scope analysis, and formatter. `:strs` converts key atoms to strings before lookup via `flex_fetch`.

---

### Additional semantics gaps

### GAP-S04: `assoc` with many key-value pairs

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | SCI `more-than-twenty-args-test` line 1596 |

**Fix:** `assoc_variadic` already handled many pairs correctly. The conformance test comparison failed because Babashka output goes through JSON (string keys) while PTC-Lisp uses integer keys. Fixed `normalize_value` in `ClojureValidator` to normalize integer map keys to strings.

### ~~GAP-S05~~: Moved to DIV-06 (intentional divergence)

### GAP-S06: Parameter named `fn` shadows builtin incorrectly

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | SCI `variable-can-have-macro-or-var-name` line 904 |

```clojure
;; Clojure
(defn foo [fn] (fn 1)) (foo inc)   ;=> 2

;; PTC-Lisp (fixed)
(defn foo [fn] (fn 1)) (foo inc)   ;=> 2
```

**Fix:** The analyzer pre-marks shadowed special form names in RawAST before analysis. When `fn`/`defn`/`let`/`loop` bindings introduce a name matching a shadowable form (Clojure macros like `fn`, `let`, `when`, `cond`), occurrences in call position are rewritten to `{:shadowed_local, name}`, treated as a plain variable reference. True special forms (`if`, `def`, `recur`, `do`) remain unshadowable, matching Clojure.

### GAP-S07: Keyword args via rest destructuring `[& {:keys [a]}]`

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | SCI `defn-kwargs-test` line 303 |

**Fix:** Added coercion in `bind_args/2` that converts rest args from a flat key-value list to a map when the rest pattern is a map destructuring form (`{:keys ...}` or `{:map ...}`).

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

### DIV-06: Silent deduplication of computed duplicate keys in map/set literals

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | SCI `core-test` line 114-116 |

```clojure
;; Clojure: throws "Duplicate key: 1"
(let [a 1 b 1] #{a b})

;; PTC-Lisp: silently creates #{1} (no error)
```

Clojure detects duplicate computed keys at runtime and throws an error. PTC-Lisp silently deduplicates. Without exception handling (`try`/`catch`), a duplicate-key error would crash the entire program with no recovery path. Silent deduplication is more resilient for LLM-generated sandboxed code.

### DIV-07: No user-defined namespaces

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

No user-defined namespaces or modules. All definitions live in a single flat namespace.

**Rationale:** Simplicity. Single-file programs don't need module systems.

### DIV-08: No full Java interop

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

No general Java/host interop. A minimal Date/Time subset is supported (see spec §8.13).

**Rationale:** Security. Arbitrary host access would break the sandbox.

### DIV-09: No file I/O

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

No `slurp`, `spit`, or any filesystem access.

**Rationale:** Security. All data must flow through the tool/context API.

### DIV-10: No exception handling

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

No `try`, `catch`, `throw`. Use `(fail reason)` for error signaling.

**Rationale:** Simplicity and safety. Exception handling adds complexity; `fail` provides a single, predictable error path.

### DIV-11: No multi-methods or protocols

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

No `defmulti`, `defmethod`, `defprotocol`, `defrecord`.

**Rationale:** Complexity. Not needed for data transformation pipelines.

### DIV-12: No transducers

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

Transducers are not supported. `comp`, `partial`, `complement`, `constantly`, `every-pred`, and `some-fn` are now supported (see §8.10).

**Rationale:** Transducers add significant complexity. Threading macros (`->`, `->>`) and the supported combinators cover most composition needs.

### DIV-13: Namespaced keywords not supported

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

`:foo/bar` style namespaced keywords are not supported. Only simple keywords
like `:name`, `:user-id`. This applies to literal parsing, runtime coercion
through `(keyword "foo/bar")`, and syntactic contexts that require namespaced
keyword literals such as `:keys` destructuring.

**Rationale:** Simplicity. No user-defined namespaces means namespace-qualified keywords have no use.

### DIV-14: Conditional binding forms only support single symbol bindings

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/if-let-destructuring-001`, `div/if-let-vector-destructuring-001`, `div/when-let-destructuring-001`, `div/when-let-map-destructuring-001`, `div/if-some-destructuring-001`, `div/if-some-map-destructuring-001`, `div/when-some-destructuring-001` |

```clojure
;; Clojure: supports destructuring
(if-let [{:keys [a]} (get-map)] a nil)
(if-let [[a b] [1 2]] [a b] nil)
(when-let [[a b] [1 2]] [a b])
(when-let [{:keys [a]} {:a 1}] a)
(if-some [[a b] [1 2]] [a b] nil)
(if-some [{:keys [a]} {:a nil}] a :none)
(when-some [[a b] [1 2]] [a b])

;; PTC-Lisp: only single symbol
(if-let [x (get-map)] (:a x) nil)
(when-let [x [1 2]] x)
(if-some [x [1 2]] x nil)
(when-some [x [1 2]] x)
```

**Rationale:** Simplicity. Destructuring in `let` covers this need.

### DIV-15: No multi-arity `fn`/`defn`

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

```clojure
;; Clojure
(fn ([x] x) ([x y] (+ x y)))
(defn f ([x] x) ([x y] (+ x y)))

;; PTC-Lisp: not supported — use separate functions or rest args
```

**Rationale:** Simplicity. Rest args and separate functions cover most cases.

### DIV-16: No pre/post conditions in `defn`

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

No `:pre`/`:post` condition maps in `defn`. Without exception handling, assertion failures would crash the program.

**Rationale:** No exception handling (DIV-10) makes pre/post conditions dangerous in sandboxed code.

### DIV-17: Nested `#()` not allowed

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

```clojure
;; Clojure: also disallows this
#(map #(+ % 1) %&)   ;=> error in both Clojure and PTC-Lisp
```

**Rationale:** Matches Clojure. Ambiguous which `%` refers to which scope.

### DIV-18: `parse-long`/`parse-double`/`parse-boolean` return `nil` for non-string input

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Spec §8.9; manual conformance cases `div/parse-long-001`, `div/parse-long-nil-001`, `div/parse-double-001`, `div/parse-double-nil-001`, `div/parse-boolean-001`, `div/parse-boolean-boolean-001`, `div/parse-boolean-nil-001` |

```clojure
;; Clojure 1.11+
(parse-long 42)      ;=> IllegalArgumentException
(parse-long nil)     ;=> IllegalArgumentException
(parse-double 42)    ;=> IllegalArgumentException
(parse-double nil)   ;=> IllegalArgumentException
(parse-boolean 42)   ;=> IllegalArgumentException
(parse-boolean true) ;=> IllegalArgumentException
(parse-boolean nil)  ;=> IllegalArgumentException

;; PTC-Lisp
(parse-long 42)      ;=> nil
(parse-long nil)     ;=> nil
(parse-double 42)    ;=> nil
(parse-double nil)   ;=> nil
(parse-boolean 42)   ;=> nil
(parse-boolean true) ;=> nil
(parse-boolean nil)  ;=> nil
```

Clojure-named parse helpers intentionally use the safe signal-value behavior
above. Java-shaped parse aliases are tracked separately under `GAP-J01` and
`GAP-J02`: Java-named class/member calls should keep Java semantics.

**Rationale:** No exception handling (DIV-10). Returning `nil` is safer for LLM-generated code.

### GAP-J01: Java numeric parse aliases return nil instead of raising on invalid input

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `java/integer-parse-int-bug-001`, `java/integer-parse-int-empty-bug-001`, `java/integer-parse-int-whitespace-bug-001`, `java/integer-parse-int-overflow-bug-001`, `java/integer-parse-int-plus-overflow-bug-001`, `java/integer-parse-int-underflow-bug-001`, `java/integer-parse-int-nil-bug-001`, `java/long-parse-long-bug-001`, `java/long-parse-long-empty-bug-001`, `java/long-parse-long-whitespace-bug-001`, `java/long-parse-long-overflow-bug-001`, `java/long-parse-long-plus-overflow-bug-001`, `java/long-parse-long-underflow-bug-001`, `java/long-parse-long-nil-bug-001`, `java/double-parse-double-bug-001`, `java/double-parse-double-empty-bug-001`, `java/double-parse-double-whitespace-bug-001`, `java/double-parse-double-hex-float-bug-001`, `java/double-parse-double-nil-bug-001`, `java/float-parse-float-bug-001`, `java/float-parse-float-empty-bug-001`, `java/float-parse-float-whitespace-bug-001`, `java/float-parse-float-nil-bug-001` |

```clojure
;; Java / Clojure
(Integer/parseInt "x")    ;=> NumberFormatException
(Integer/parseInt "")     ;=> NumberFormatException
(Integer/parseInt " 1")   ;=> NumberFormatException
(Integer/parseInt "2147483648") ;=> NumberFormatException
(Integer/parseInt "+2147483648") ;=> NumberFormatException
(Integer/parseInt nil)    ;=> NumberFormatException
(Long/parseLong "x")      ;=> NumberFormatException
(Long/parseLong "")       ;=> NumberFormatException
(Long/parseLong " 1")     ;=> NumberFormatException
(Long/parseLong "9223372036854775808") ;=> NumberFormatException
(Long/parseLong "+9223372036854775808") ;=> NumberFormatException
(Long/parseLong nil)      ;=> NumberFormatException
(Double/parseDouble "x")  ;=> NumberFormatException
(Double/parseDouble "")   ;=> NumberFormatException
(Double/parseDouble nil)  ;=> NullPointerException
(Float/parseFloat "x")    ;=> NumberFormatException
(Float/parseFloat "")     ;=> NumberFormatException
(Float/parseFloat nil)    ;=> NullPointerException
(Double/parseDouble " 1.5") ;=> 1.5
(Double/parseDouble "0x1.0p0") ;=> 1.0
(Float/parseFloat "1.5 ")  ;=> 1.5

;; PTC-Lisp current behavior
(Integer/parseInt "x")    ;=> nil
(Integer/parseInt "")     ;=> nil
(Integer/parseInt " 1")   ;=> nil
(Integer/parseInt "2147483648") ;=> 2147483648
(Integer/parseInt "+2147483648") ;=> 2147483648
(Integer/parseInt nil)    ;=> nil
(Long/parseLong "x")      ;=> nil
(Long/parseLong "")       ;=> nil
(Long/parseLong " 1")     ;=> nil
(Long/parseLong "9223372036854775808") ;=> 9223372036854775808
(Long/parseLong "+9223372036854775808") ;=> 9223372036854775808
(Long/parseLong nil)      ;=> nil
(Double/parseDouble "x")  ;=> nil
(Double/parseDouble "")   ;=> nil
(Double/parseDouble nil)  ;=> nil
(Float/parseFloat "x")    ;=> nil
(Float/parseFloat "")     ;=> nil
(Float/parseFloat nil)    ;=> nil
(Double/parseDouble " 1.5") ;=> nil
(Double/parseDouble "0x1.0p0") ;=> nil
(Float/parseFloat "1.5 ")  ;=> nil
```

**Decision:** BUG. These are Java-shaped class calls, so Java semantics should
win even when the safer Clojure-named helpers return signal values. For
integer parsers that includes Java primitive range checks; for floating parsers
that includes Java's accepted leading/trailing whitespace.

### GAP-J02: `Boolean/parseBoolean` returns nil for non-true strings

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `java/boolean-parse-boolean-bug-001`, `java/boolean-parse-boolean-case-bug-001`, `java/boolean-parse-boolean-mixed-case-bug-001`, `java/boolean-parse-boolean-nil-bug-001`, `java/boolean-parse-boolean-empty-bug-001`, `java/boolean-parse-boolean-boolean-bug-001` |

```clojure
;; Java / Clojure
(Boolean/parseBoolean "x")  ;=> false
(Boolean/parseBoolean "TRUE") ;=> true
(Boolean/parseBoolean "TrUe") ;=> true
(Boolean/parseBoolean nil)  ;=> false
(Boolean/parseBoolean "")   ;=> false
(Boolean/parseBoolean true) ;=> ClassCastException

;; PTC-Lisp current behavior
(Boolean/parseBoolean "x")  ;=> nil
(Boolean/parseBoolean "TRUE") ;=> nil
(Boolean/parseBoolean "TrUe") ;=> nil
(Boolean/parseBoolean nil)  ;=> nil
(Boolean/parseBoolean "")   ;=> nil
(Boolean/parseBoolean true) ;=> nil
```

**Decision:** BUG. `Boolean/parseBoolean` is a Java-shaped class call. Java
returns `false` for every string other than case-insensitive `"true"`.

### GAP-J15: Java integer parse radix overloads are unsupported

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `java/integer-parse-int-radix-bug-001`, `java/long-parse-long-radix-bug-001` |

```clojure
;; Java / Clojure
(Integer/parseInt "10" 16) ;=> 16
(Long/parseLong "10" 16)   ;=> 16

;; PTC-Lisp current behavior
(Integer/parseInt "10" 16) ;=> arity_error
(Long/parseLong "10" 16)   ;=> arity_error
```

**Decision:** BUG. These are Java-shaped static calls. The two-argument radix
overload is a normal finite Java parser surface and should not be rejected as
an unsupported arity while the one-argument parse methods are marked supported.

### GAP-J03: `java.util.Date.` numeric constructor treats milliseconds as seconds

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `java/util-date-numeric-constructor-bug-001`, `java/util-date-single-millisecond-constructor-bug-001`, `java/util-date-negative-single-millisecond-constructor-bug-001`, `java/util-date-negative-numeric-constructor-bug-001` |

```clojure
;; Java / Clojure
(.getTime (java.util.Date. 1000))   ;=> 1000
(.getTime (java.util.Date. 1))      ;=> 1
(.getTime (java.util.Date. -1))     ;=> -1
(.getTime (java.util.Date. -1000))  ;=> -1000

;; PTC-Lisp current behavior
(.getTime (java.util.Date. 1000))   ;=> 1000000
(.getTime (java.util.Date. 1))      ;=> 1000
(.getTime (java.util.Date. -1))     ;=> -1000
(.getTime (java.util.Date. -1000))  ;=> -1000000
```

**Decision:** BUG. `java.util.Date.` is a Java-shaped constructor; numeric
arguments should be epoch milliseconds.

### GAP-J04: `.getTime` is exposed on `Instant/parse` results

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `java/instant-get-time-bug-001`, `java/instant-get-time-millis-bug-001`, `java/instant-get-time-offset-bug-001`, `java/instant-get-time-negative-bug-001`, `java/instant-get-time-nanos-bug-001` |

```clojure
;; Java / Clojure
(.getTime (java.time.Instant/parse "1970-01-01T00:00:01Z"))
;=> NoSuchFieldException
(.getTime (java.time.Instant/parse "1970-01-01T00:00:00.123Z"))
;=> NoSuchFieldException
(.getTime (java.time.Instant/parse "1970-01-01T01:00:00+01:00"))
;=> NoSuchFieldException
(.getTime (java.time.Instant/parse "1969-12-31T23:59:59Z"))
;=> NoSuchFieldException
(.getTime (java.time.Instant/parse "1970-01-01T00:00:00.999999999Z"))
;=> NoSuchFieldException

;; PTC-Lisp current behavior
(.getTime (java.time.Instant/parse "1970-01-01T00:00:01Z")) ;=> 1000
(.getTime (java.time.Instant/parse "1970-01-01T00:00:00.123Z")) ;=> 123
(.getTime (java.time.Instant/parse "1970-01-01T01:00:00+01:00")) ;=> 0
(.getTime (java.time.Instant/parse "1969-12-31T23:59:59Z")) ;=> -1000
(.getTime (java.time.Instant/parse "1970-01-01T00:00:00.999999999Z")) ;=> 999
```

**Decision:** BUG/audit mismatch. Java `Instant` uses `toEpochMilli`, not
`getTime`. If PTC keeps `.getTime` as a convenience on DateTime values, it
should be documented as a PTC extension or Java `Date` compatibility helper,
not as `java.time.Instant` compatibility.

### GAP-J20: `java.util.Date` exposes non-Java `.isBefore`/`.isAfter` methods

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `java/util-date-is-before-method-bug-001`, `java/util-date-is-after-method-bug-001` |

```clojure
;; Java / Clojure
(.isBefore (java.util.Date. 0) (java.util.Date. 1000))
;=> IllegalArgumentException
(.isAfter (java.util.Date. 1000) (java.util.Date. 0))
;=> IllegalArgumentException

;; PTC-Lisp current behavior
(.isBefore (java.util.Date. 0) (java.util.Date. 1000)) ;=> true
(.isAfter (java.util.Date. 1000) (java.util.Date. 0)) ;=> true
```

**Decision:** BUG. `java.util.Date` uses `.before` and `.after`; `.isBefore`
and `.isAfter` are `java.time` method names. Java-shaped dot calls should keep
Java receiver semantics unless explicitly reclassified as PTC extensions.

### GAP-J18: `Instant.toEpochMilli` is unsupported

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance case `java/instant-to-epoch-milli-unsupported-bug-001` |

```clojure
;; Java / Clojure
(.toEpochMilli (java.time.Instant/parse "1970-01-01T00:00:01Z")) ;=> 1000

;; PTC-Lisp current behavior
(.toEpochMilli (java.time.Instant/parse "1970-01-01T00:00:01Z")) ;=> unsupported_method
```

**Decision:** BUG/candidate gap. PTC-Lisp exposes `Instant/parse` and a
non-Java `.getTime` convenience, but the actual Java `Instant` epoch-millisecond
method is missing. Java-shaped temporal APIs should prefer Java's method names
and semantics.

### GAP-J19: `Duration.between` accepts `java.util.Date` inputs

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `java/duration-between-date-instant-bug-001`, `java/duration-between-dates-bug-001` |

```clojure
;; Java / Clojure
(.toMillis (java.time.Duration/between
  (java.util.Date. 0)
  (java.time.Instant/parse "1970-01-01T00:00:01Z")))
;=> ClassCastException

(.toMillis (java.time.Duration/between
  (java.util.Date. 0)
  (java.util.Date. 0)))
;=> ClassCastException

;; PTC-Lisp current behavior
(.toMillis (java.time.Duration/between
  (java.util.Date. 0)
  (java.time.Instant/parse "1970-01-01T00:00:01Z")))
;=> 1000

(.toMillis (java.time.Duration/between
  (java.util.Date. 0)
  (java.util.Date. 0)))
;=> 0
```

**Decision:** BUG. `Duration/between` is a Java-shaped class call, so Java
type semantics should apply. Java `Duration.between` operates on
`java.time.temporal.Temporal` values; `java.util.Date` is not a `Temporal` and
raises through Clojure Java interop. PTC-Lisp should not silently coerce Date
values in a Java-named API.

### GAP-J05: Supported Java string methods miss overloads

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `java/string-starts-with-offset-bug-001`, `java/string-starts-with-offset-negative-bug-001`, `java/string-starts-with-offset-too-large-bug-001`, `java/string-starts-with-empty-offset-too-large-bug-001`, `java/string-last-index-of-from-bug-001`, `java/string-last-index-of-from-negative-bug-001`, `java/string-last-index-of-from-too-large-bug-001`, `java/string-last-index-of-empty-from-bug-001`, `java/string-last-index-of-empty-from-too-large-bug-001`, `java/string-last-index-of-empty-from-negative-bug-001`, `java/string-index-of-char-code-bug-001`, `java/string-index-of-char-code-from-bug-001`, `java/string-last-index-of-char-code-bug-001`, `java/string-last-index-of-char-code-from-bug-001` |

```clojure
;; Java / Clojure
(.startsWith "abc" "b" 1)       ;=> true
(.startsWith "abc" "a" -1)      ;=> false
(.startsWith "abc" "a" 99)      ;=> false
(.startsWith "abc" "" 4)        ;=> false
(.lastIndexOf "ababa" "ba" 2)   ;=> 1
(.lastIndexOf "abcabc" "b" -1)  ;=> -1
(.lastIndexOf "abcabc" "b" 99)  ;=> 4
(.lastIndexOf "abc" "" 2)       ;=> 2
(.lastIndexOf "abc" "" 4)       ;=> 3
(.lastIndexOf "abc" "" -1)      ;=> -1
(.indexOf "abc" 98)             ;=> 1
(.indexOf "abc" 97 1)           ;=> -1
(.lastIndexOf "abca" 97)        ;=> 3
(.lastIndexOf "abc" 97 1)       ;=> 0

;; PTC-Lisp current behavior
(.startsWith "abc" "b" 1)       ;=> arity error
(.startsWith "abc" "a" -1)      ;=> arity error
(.startsWith "abc" "a" 99)      ;=> arity error
(.startsWith "abc" "" 4)        ;=> arity error
(.lastIndexOf "ababa" "ba" 2)   ;=> arity error
(.lastIndexOf "abcabc" "b" -1)  ;=> arity error
(.lastIndexOf "abcabc" "b" 99)  ;=> arity error
(.lastIndexOf "abc" "" 2)       ;=> arity error
(.lastIndexOf "abc" "" 4)       ;=> arity error
(.lastIndexOf "abc" "" -1)      ;=> arity error
(.indexOf "abc" 98)             ;=> type error
(.indexOf "abc" 97 1)           ;=> type error
(.lastIndexOf "abca" 97)        ;=> type error
(.lastIndexOf "abc" 97 1)       ;=> arity error
```

**Decision:** BUG. These are Java-shaped method calls, so Java overload
semantics should win for supported `java.lang.String` methods.

### ~~GAP-J16~~: Reclassified as DIV-40 (intentional divergence)

Java string predicate methods accept character literals as arguments — see
**DIV-40**. PTC-Lisp has no `Character` type, so this is by design.

### ~~GAP-J17~~: Reclassified as DIV-41 (intentional divergence)

Java string methods accept character literals as receivers — see **DIV-41**.
PTC-Lisp has no `Character` type, so this is by design.

### DIV-40: Java string methods accept character literals as arguments

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `java/string-starts-with-char-001`, `java/string-ends-with-char-001`, `java/string-contains-char-001` |

```clojure
;; Java / Clojure
(.startsWith "abc" \a)   ;=> ClassCastException
(.endsWith "abc" \c)     ;=> ClassCastException
(.contains "abc" \b)     ;=> ClassCastException

;; PTC-Lisp
(.startsWith "abc" \a)   ;=> true
(.endsWith "abc" \c)     ;=> true
(.contains "abc" \b)     ;=> true
```

**Rationale:** PTC-Lisp has no `Character` type — character literals are
one-character strings (see DIV-35 and the char-literal cases under GAP-S120,
GAP-S133). So `\a` *is* the string `"a"`, and these Java `String` methods
operate on it correctly. Java raises only because a `char` is not a `String`;
that distinction does not exist in PTC-Lisp's value model. Reproducing the Java
exception would require tracking char *provenance* (so `"a"` behaves
differently depending on whether it came from `\a` or `"a"`) purely to raise an
unrecoverable error — exactly the invisible distinction that makes
LLM-generated programs worse. Java-named methods follow Java-compatible
*conventions* that are meaningful in PTC-Lisp; they do not preserve Java
object/type distinctions PTC-Lisp intentionally does not model.

### DIV-41: Java string methods accept character literals as receivers

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `java/string-length-char-receiver-001`, `java/string-to-lower-case-char-receiver-001`, `java/string-to-upper-case-char-receiver-001`, `java/string-contains-char-receiver-001`, `java/string-index-of-char-receiver-001`, `java/string-last-index-of-char-receiver-001`, `java/string-starts-with-char-receiver-001`, `java/string-ends-with-char-receiver-001`, `java/string-substring-char-receiver-001` |

```clojure
;; Java / Clojure
(.length \a)          ;=> NoSuchFieldException
(.toLowerCase \A)     ;=> NoSuchFieldException
(.toUpperCase \a)     ;=> NoSuchFieldException
(.contains \a "a")    ;=> IllegalArgumentException
(.indexOf \a "a")     ;=> IllegalArgumentException
(.lastIndexOf \a "a") ;=> IllegalArgumentException
(.startsWith \a "a")  ;=> IllegalArgumentException
(.endsWith \a "a")    ;=> IllegalArgumentException
(.substring \a 0)     ;=> IllegalArgumentException

;; PTC-Lisp
(.length \a)          ;=> 1
(.toLowerCase \A)     ;=> "a"
(.toUpperCase \a)     ;=> "A"
(.contains \a "a")    ;=> true
(.indexOf \a "a")     ;=> 0
(.lastIndexOf \a "a") ;=> 0
(.startsWith \a "a")  ;=> true
(.endsWith \a "a")    ;=> true
(.substring \a 0)     ;=> "a"
```

**Rationale:** Same as DIV-40 — PTC-Lisp has no `Character` type, so a
character-literal receiver is the one-character string `"a"` and these Java
`String` methods return the correct values for that string. Combined with the
no-`try`/`catch` policy (raising is an unrecoverable dead program), raising
here would be both incoherent (treating a string as a non-string) and strictly
worse for the agent loop. Non-string-like receivers (e.g. `(.length 5)`) still
raise — the divergence only covers values PTC-Lisp genuinely models as strings.
The UTF-16-vs-grapheme index-unit difference is a separate axis tracked under
GAP-J09.

### GAP-J06: Java temporal parsers/constructors accept date strings Java rejects

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `java/instant-parse-date-only-bug-001`, `java/instant-parse-no-zone-bug-001`, `java/instant-parse-no-zone-non-midnight-bug-001`, `java/local-date-parse-datetime-bug-001`, `java/local-date-parse-datetime-non-midnight-bug-001`, `java/util-date-string-constructor-bug-001` |

```clojure
;; Java / Clojure
(java.time.Instant/parse "2024-01-02")      ;=> DateTimeParseException
(java.time.Instant/parse "2024-01-02T00:00:00") ;=> DateTimeParseException
(java.time.Instant/parse "2024-01-02T03:04:05") ;=> DateTimeParseException
(java.time.LocalDate/parse "2024-01-02T00:00:00") ;=> DateTimeParseException
(java.time.LocalDate/parse "2024-01-02T03:04:05") ;=> DateTimeParseException
(.getTime (java.util.Date. "2024-01-02"))   ;=> IllegalArgumentException

;; PTC-Lisp current behavior
(java.time.Instant/parse "2024-01-02")      ;=> LocalDate value
(java.time.Instant/parse "2024-01-02T00:00:00") ;=> DateTime value
(java.time.Instant/parse "2024-01-02T03:04:05") ;=> DateTime value
(java.time.LocalDate/parse "2024-01-02T00:00:00") ;=> DateTime value
(java.time.LocalDate/parse "2024-01-02T03:04:05") ;=> DateTime value
(.getTime (java.util.Date. "2024-01-02"))   ;=> 1704153600000
```

**Decision:** BUG. These are Java-shaped constructor/parser calls. Java
semantics should win, including rejection of inputs outside the Java method's
accepted format.

### GAP-J11: `java.util.Date.` rejects Java-accepted legacy date strings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `java/util-date-legacy-string-constructor-bug-001` |

```clojure
;; Java / Clojure
(.getTime (java.util.Date. "Thu Jan 01 00:00:01 UTC 1970")) ;=> 1000

;; PTC-Lisp current behavior
(.getTime (java.util.Date. "Thu Jan 01 00:00:01 UTC 1970")) ;=> type_error
```

**Decision:** BUG. `java.util.Date.` is exposed as a Java-shaped constructor,
so Java constructor semantics should win for accepted finite inputs. The
constructor is deprecated on the JVM, but while it remains in the supported
audit surface it should either match Java's accepted legacy string forms or be
reclassified away from exact Java compatibility.

### GAP-J12: `LocalDate` day arithmetic rejects numeric day counts Clojure accepts

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `java/local-date-plus-days-float-bug-001`, `java/local-date-plus-days-fractional-bug-001`, `java/local-date-plus-days-nan-bug-001`, `java/local-date-minus-days-float-bug-001`, `java/local-date-minus-days-fractional-bug-001`, `java/local-date-minus-days-nan-bug-001` |

```clojure
;; Java / Clojure
(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-02") 1.0))
;=> 19725
(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-01") 1.9))
;=> 19724
(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-01") ##NaN))
;=> 19723
(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-02") 1.0))
;=> 19723
(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-01") 1.9))
;=> 19722
(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-01") ##NaN))
;=> 19723

;; PTC-Lisp current behavior
(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-02") 1.0))
;=> type_error
(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-01") 1.9))
;=> type_error
(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-01") ##NaN))
;=> type_error
(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-02") 1.0))
;=> type_error
(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-01") 1.9))
;=> type_error
(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-01") ##NaN))
;=> type_error
```

**Decision:** BUG. `.plusDays` and `.minusDays` are exposed as Java-shaped
methods and Clojure's Java interop coerces finite numeric arguments for the
`long` parameter. PTC-Lisp should either match that invocation behavior or
document a deliberate narrower numeric contract.

### GAP-J09: Java string methods use grapheme indexes for non-BMP characters

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `java/string-length-utf16-bug-001`, `java/string-substring-utf16-bug-001`, `java/string-index-of-utf16-bug-001`, `java/string-last-index-of-utf16-bug-001` |

```clojure
;; Java / Clojure
(.length "😀a")              ;=> 3
(.substring "😀a" 0 1)      ;=> leading surrogate string
(.indexOf "😀a" "a")        ;=> 2
(.lastIndexOf "😀a😀" "😀") ;=> 3

;; PTC-Lisp current behavior
(.length "😀a")              ;=> 2
(.substring "😀a" 0 1)      ;=> "😀"
(.indexOf "😀a" "a")        ;=> 1
(.lastIndexOf "😀a😀" "😀") ;=> 2
```

**Decision:** BUG. PTC-Lisp's Clojure-named string helpers intentionally use
Unicode grapheme indexes (see `DIV-36`), but these are Java-shaped method calls.
Java `String` indexes and lengths are UTF-16 code units, so Java semantics
should win here.

### GAP-J14: Java `String.substring` rejects finite numeric indexes

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `java/string-substring-float-start-bug-001`, `java/string-substring-float-start-end-bug-001` |

```clojure
;; Java / Clojure
(.substring "abcd" 1.0)     ;=> "bcd"
(.substring "abcd" 1.0 3.0) ;=> "bc"

;; PTC-Lisp current behavior
(.substring "abcd" 1.0)     ;=> type_error
(.substring "abcd" 1.0 3.0) ;=> type_error
```

**Decision:** BUG. `.substring` is exposed as a Java-shaped method, and
Clojure's Java interop coerces finite numeric index arguments for Java `int`
parameters. This is separate from PTC-Lisp's intentional grapheme indexing
policy for Clojure-named string helpers such as `subs`.

### ~~GAP-J07~~: Reclassified as DIV-44 (intentional divergence)

`Math/min` / `Math/max` are variadic aliases of the Clojure-named helpers — see
**DIV-44**.

### ~~GAP-J08~~: Reclassified as DIV-43 (intentional divergence)

`Math/round` keeps PTC-Lisp's round semantics (half-away, integer result,
preserves special values) — see **DIV-43**.

### ~~GAP-J10~~: Reclassified as DIV-45 (intentional divergence)

`Math/abs` / `Math/min` / `Math/max` / `Math/round` follow PTC-Lisp's
arbitrary-precision, generic-comparison value model — see **DIV-45**.

### DIV-44: Java `Math/min` / `Math/max` are variadic

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `java/math-min-three-args-001`, `java/math-min-one-arg-001`, `java/math-max-three-args-001`, `java/math-max-one-arg-001` |

```clojure
;; Java / Clojure
(Math/min 3 2 1)   ;=> IllegalArgumentException
(Math/max 1)       ;=> IllegalArgumentException

;; PTC-Lisp
(Math/min 3 2 1)   ;=> 1
(Math/min 1)       ;=> 1
(Math/max 1 2 3)   ;=> 3
(Math/max 1)       ;=> 1
```

**Rationale:** PTC-Lisp's `min`/`max` are the Clojure-named variadic helpers,
and `Math/min`/`Math/max` are aliases for them — they are not separate
two-argument Java primitives. Restricting them to Java's two-argument overloads
would mean manufacturing a `Math/`-namespace distinction solely to raise an
unrecoverable error (no `try`/`catch`) on a well-defined variadic call. Java is
a compatibility heuristic here, not the design owner.

### DIV-43: `Math/round` keeps PTC-Lisp round semantics

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `java/math-round-negative-half-001`, `java/math-round-nan-001`, `java/math-round-pos-inf-001`, `java/math-round-neg-inf-001` |

```clojure
;; Java / Clojure
(Math/round -1.5)   ;=> -1
(Math/round ##NaN)  ;=> 0
(Math/round ##Inf)  ;=> 9223372036854775807
(Math/round ##-Inf) ;=> -9223372036854775808

;; PTC-Lisp
(Math/round -1.5)   ;=> -2
(Math/round ##NaN)  ;=> ##NaN
(Math/round ##Inf)  ;=> ##Inf
(Math/round ##-Inf) ;=> ##-Inf
```

**Rationale:** PTC-Lisp's `round` is an integer-returning extension that uses
round-half-away-from-zero and **preserves** the special signal values
(`:nan`, `:infinity`, `:negative_infinity`). Java's `Math.round` instead uses
`floor(x + 0.5)` for negative halves and converts NaN/infinity to long values
(`0` / `Long/MAX_VALUE` / `Long/MIN_VALUE`). Preserving the special value is
more useful in the agent loop (it stays recoverable and informative) than
saturating to a long bound, and matching Java would require a `Math/`-namespace
distinction from the bare `round` extension (pinned to half-away integer
results). The `Math/round` integer/bignum argument cases live under DIV-45.

### DIV-45: Java `Math` uses PTC-Lisp's arbitrary-precision / generic value model

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `java/math-abs-long-min-001`, `java/math-abs-bigint-001`, `java/math-max-mixed-numeric-001`, `java/math-min-mixed-numeric-001`, `java/math-min-nil-001`, `java/math-max-string-001`, `java/math-round-integer-overload-001`, `java/math-round-bigint-overload-001` |

```clojure
;; Java / Clojure
(Math/abs -9223372036854775808) ;=> -9223372036854775808  (long overflow)
(Math/abs 9223372036854775808)  ;=> IllegalArgumentException
(Math/max 1 2.0)                ;=> IllegalArgumentException
(Math/min nil 1)                ;=> IllegalArgumentException
(Math/max "a" 1)                ;=> IllegalArgumentException
(Math/round 1)                  ;=> IllegalArgumentException
(Math/round 9223372036854775808);=> IllegalArgumentException

;; PTC-Lisp
(Math/abs -9223372036854775808) ;=> 9223372036854775808  (mathematically correct)
(Math/abs 9223372036854775808)  ;=> 9223372036854775808
(Math/max 1 2.0)                ;=> 2.0
(Math/min 1 2.0)                ;=> 1
(Math/min nil 1)                ;=> 1
(Math/max "a" 1)                ;=> "a"
(Math/round 1)                  ;=> 1
(Math/round 9223372036854775808);=> 9223372036854775808
```

**Rationale:** PTC-Lisp numbers are arbitrary-precision integers and floats,
and `min`/`max` compare generically across the numeric tower (and via total
ordering across types). The `Math/*` aliases inherit that value model. Java's
behaviors here are *primitive* artifacts — 64-bit two's-complement overflow
(`Math/abs` of `Long/MIN_VALUE`), no mixed `long`/`double` overload, and
exceptions for out-of-range or non-numeric arguments — that PTC-Lisp
intentionally does not model. Reproducing them would manufacture a
`Math/`-namespace distinction purely to emit overflow values or unrecoverable
errors; PTC-Lisp's answers (e.g. the correct positive `abs`) are more useful in
the agent loop.

### DIV-46: `select-keys` with a string keyseq matches keyword keys

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/select-keys-string-keyseq-001`, `div/select-keys-string-keyseq-002` |

```clojure
;; Clojure
(select-keys {:a 1 :b 2} ":a") ;=> {}
(select-keys {:a 1 :b 2} "ab") ;=> {}

;; PTC-Lisp
(select-keys {:a 1 :b 2} ":a") ;=> {"a" 1}
(select-keys {:a 1 :b 2} "ab") ;=> {"a" 1, "b" 2}
```

**Rationale:** A string keyseq is seqable, so it iterates as one-character
strings. PTC-Lisp has no distinct character type (char ≡ one-character string)
and stores keyword keys as strings, so `select-keys` (like `get`/`assoc`) looks
keys up flexibly: the one-char string `"a"` flex-matches keyword key `:a`. The
result is therefore populated where Clojure — whose chars never equal keywords —
returns `{}`. This is the same universal behavior as
`(select-keys {:a 1} ["a"])` => `{"a" 1}`; forcing Clojure's `{}` would require
strict non-flex lookup in this one function, contradicting PTC-Lisp's value
model (which takes precedence over Clojure-compat where they conflict). The
related nil-keyseq protocol-error case was fixed as a BUG under
[GAP-S23](#gap-s23-select-keys-with-nil-keyseq-raises-instead-of-returning-an-empty-map).

### GAP-J13: Java `Math/pow` special double results differ

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `java/math-pow-negative-fractional-001`, `java/math-pow-zero-negative-exponent-001`, `java/math-pow-one-nan-exponent-001`, `java/math-pow-one-infinite-exponent-001`, `java/math-pow-negative-one-infinite-exponent-001`, `java/math-pow-negative-zero-negative-odd-exponent-001` |

```clojure
;; Java / Clojure
(Math/pow -1 0.5) ;=> ##NaN
(Math/pow 0 -1)   ;=> ##Inf
(Math/pow 1 ##NaN) ;=> ##NaN
(Math/pow 1 ##Inf) ;=> ##NaN
(Math/pow -1 ##Inf) ;=> ##NaN
(Math/pow -0.0 -3) ;=> ##-Inf

;; PTC-Lisp (fixed)
(Math/pow -1 0.5) ;=> ##NaN
(Math/pow 0 -1)   ;=> ##Inf
(Math/pow 1 ##NaN) ;=> ##NaN
(Math/pow 1 ##Inf) ;=> ##NaN
(Math/pow -1 ##Inf) ;=> ##NaN
(Math/pow -0.0 -3) ;=> ##-Inf
```

**Fix:** `Runtime.Math.pow/2` now follows `java.lang.Math.pow`'s IEEE 754
special-case table. Because PTC-Lisp has no `try`/`catch`, the IEEE results are
returned as **recoverable signal values** (`:nan`, `:infinity`,
`:negative_infinity`) rather than raising — consistent with the Design
Philosophy rule that bad numeric input may signal. This applies to both the
Java-shaped `Math/pow` and the bare `pow` extension (there is no separate
Clojure `pow` with different semantics). An exponent of zero still yields `1.0`
for any base; `|base| == 1` with an infinite exponent yields `NaN`; a negative
base with a non-integer exponent yields `NaN`; a zero base with a negative
exponent yields signed infinity.

### ~~GAP-J21~~: Reclassified as DIV-42 (intentional divergence)

`Math/ceil` / `Math/floor` are integer-returning extensions — see **DIV-42**.

### DIV-42: Java `Math/ceil` / `Math/floor` return integer-shaped values

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `java/math-ceil-double-rendering-001`, `java/math-floor-double-rendering-001` |

```clojure
;; Java / Clojure
(str (Math/ceil 1.2))   ;=> "2.0"
(str (Math/floor -1.2)) ;=> "-2.0"

;; PTC-Lisp
(str (Math/ceil 1.2))   ;=> "2"
(str (Math/floor -1.2)) ;=> "-2"
```

**Rationale:** PTC-Lisp's `ceil` and `floor` are integer-returning extensions
(pinned as such; see the function reference), so an integral result renders as
`2`, not Java's `double` `2.0`. The `Math/ceil`/`Math/floor` aliases inherit
that. The int-vs-double *shape* is the only difference (the numeric value is
equal), and matching Java's `.0` rendering would require manufacturing a
`Math/`-namespace distinction from the bare integer-returning extensions solely
for that rendering. Java is a compatibility heuristic here, not the design
owner.

### DIV-34: Empty keyword names are not supported

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance case `div/empty-keyword-function-001` |

PTC-Lisp keywords require at least one keyword character. Clojure can construct
an empty-name keyword with `(keyword "")`; PTC-Lisp treats that as an invalid
program because empty keyword names are outside the data model.

```clojure
;; Clojure
(keyword "")   ;=> :

;; PTC-Lisp
(keyword "")   ;=> runtime error
```

**Rationale:** Simplicity and readability. Empty keywords are not useful for
tool-oriented data transformation and are easy to confuse with parse/rendering
artifacts.

### DIV-35: Keywords use a stricter character set

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance case `div/strict-keyword-character-function-001` |

PTC-Lisp keywords intentionally use an identifier-like character set. Clojure
can construct keywords whose names are punctuation or whitespace via
`keyword`; PTC-Lisp rejects those names at coercion time.

```clojure
;; Clojure
(keyword ".")   ;=> :.

;; PTC-Lisp
(keyword ".")   ;=> runtime error
```

**Rationale:** Simplicity, readability, and sandbox safety. Restricting keyword
names keeps generated programs close to the documented data shape, avoids
surprising renderings, and avoids broad atom-like identifier growth.

### DIV-19: No first-class symbol runtime values

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/symbol-predicate-001`, `div/name-symbol-001` |

```clojure
;; Clojure
(symbol? 'foo)   ;=> true
(name 'foo)      ;=> "foo"

;; PTC-Lisp
(symbol? :foo)   ;=> false (always false)
(name 'foo)      ;=> runtime error
```

PTC-Lisp uses keywords where Clojure uses symbols. There is no symbol type.

**Rationale:** Simplicity. Keywords cover all identifier needs in data transformation pipelines.

### DIV-20: `decimal?` and `ratio?` always return false

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

```clojure
;; Clojure
(decimal? 1.0M)   ;=> true
(ratio? 1/3)      ;=> true
(rational? 1/3)   ;=> true

;; PTC-Lisp
(decimal? 1.0M)   ;=> unsupported literal, program error before decimal? runs
(ratio? 1/3)      ;=> unsupported literal, program error before ratio? runs
(decimal? 1.0)    ;=> false (always false)
(ratio? 1)        ;=> false (always false)
(rational? 42)    ;=> true  (integers only, no ratios on BEAM)
```

BEAM has no BigDecimal or ratio types, and PTC-Lisp does not parse BigDecimal
or ratio literals. `decimal?` and `ratio?` therefore return false for every
representable PTC-Lisp value. `rational?` returns true only for integers (the
only BEAM rationals).

**Rationale:** Platform difference. BEAM number types are integers and floats only.

### DIV-21: `format` renders nil as empty string

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

```clojure
;; Clojure
(format "%s" nil)   ;=> "null"

;; PTC-Lisp
(format "%s" nil)   ;=> "" (empty string)
```

PTC-Lisp's `str` converts nil to `""` (not `"nil"` or `"null"`), and `format %s` follows the same convention for consistency.

**Rationale:** Consistency with `(str nil)` → `""`, which is already an established PTC-Lisp convention.

### DIV-22: `subs` returns signal values instead of raising on out-of-range indices

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Issue #886, follow-up to codex review of c45bdbc; manual conformance cases `div/subs-oob-001`, `div/subs-start-end-oob-001`, `div/subs-negative-001`, `div/subs-end-oob-001`, `div/subs-reversed-range-001` |

```clojure
;; Clojure
(subs "abcdef" -1)                              ;=> StringIndexOutOfBoundsException
(subs "abc" 10)                                 ;=> StringIndexOutOfBoundsException
(subs "abc" 4 4)                                ;=> StringIndexOutOfBoundsException
(subs "abc" 1 99)                               ;=> StringIndexOutOfBoundsException
(subs "abc" 2 1)                                ;=> StringIndexOutOfBoundsException
(let [s "abcdef"] (subs s (.indexOf s "xyz"))) ;=> StringIndexOutOfBoundsException

;; PTC-Lisp
(subs "abcdef" -1)                              ;=> ""
(subs "abc" 10)                                 ;=> ""
(subs "abc" 4 4)                                ;=> ""
(subs "abc" 1 99)                               ;=> "bc"
(subs "abc" 2 1)                                ;=> ""
(let [s "abcdef"] (subs s (.indexOf s "xyz"))) ;=> ""  (the canonical idiom, clean signal)
(subs "abc" 1 10)                               ;=> "bc"   (end > length truncates)
(subs "abc" 0 100)                              ;=> "abc"  ("first N chars" idiom preserved)
```

**Rationale:** No exception handling (DIV-10). Clojure's `subs` raises on out-of-range, but in PTC-Lisp raising means the program crashes with no recovery path. We return signal values (empty string) so callers can guard with `(when (seq result) ...)`.

The negative-start rule specifically kills the `(.indexOf s needle) → -1 → subs` trap, where `.indexOf` misses and feeds -1 into `subs`. Pre-fix, `subs` clamped -1 to 0 and silently returned the *whole string* — wrong-but-plausible output that propagated downstream. Post-fix, the negative start short-circuits to `""`.

**Asymmetry with `.substring` is principled:** Java-named methods (`.substring`, `.indexOf`, `.length`) follow Java semantics and raise on out-of-range (see a44b75c for the `.substring` fix). The dot-prefix signals "Java idiom expected." Clojure-named functions (`subs`, `parse-long`, `get`) follow the safer-for-sandbox pattern. The naming convention tells the LLM which contract applies.

### DIV-36: Clojure-named string indexes use Unicode graphemes

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/string-grapheme-count-001`, `div/string-grapheme-nth-001`, `div/string-grapheme-index-of-001`, `div/string-grapheme-last-index-of-001`, `div/string-grapheme-subs-001`, `div/string-grapheme-split-with-001` |

PTC-Lisp treats strings as sequences of Unicode graphemes. Clojure and Java
string APIs expose UTF-16 code units, so non-BMP characters such as emoji count
as two positions in Clojure but one position in PTC-Lisp.

```clojure
;; Clojure
(count "😀a")                       ;=> 3
(nth "😀a" 0)                       ;=> leading surrogate char
(clojure.string/index-of "😀a" "a") ;=> 2
(subs "😀a" 1)                      ;=> string beginning with the trailing surrogate
(split-with #(not= % "c") "abcd")   ;=> (("a" "b" "c" "d") ())

;; PTC-Lisp
(count "😀a")                       ;=> 2
(nth "😀a" 0)                       ;=> "😀"
(clojure.string/index-of "😀a" "a") ;=> 1
(subs "😀a" 1)                      ;=> "a"
(split-with #(not= % "c") "abcd")   ;=> [["a" "b"] ["c" "d"]]
```

**Rationale:** PTC-Lisp is a data transformation language, not a JVM string
compatibility layer. Grapheme-based indexing matches what users see as
characters and is consistent across `count`, `seq`, `nth`, `subs`,
`clojure.string/index-of`, and `clojure.string/last-index-of`. PTC-Lisp also
represents string sequence elements as one-character strings rather than JVM
`Character` values, so predicates over string elements compare against string
values.

### DIV-23: `json/parse-string` returns `nil` on invalid input

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | PtcRunner JSON support design decision |

```clojure
;; Cheshire / Jason.decode!
(cheshire.core/parse-string "not json")   ;=> JsonParseException
(cheshire.core/parse-string nil)          ;=> NullPointerException

;; PTC-Lisp
(json/parse-string "not json")            ;=> nil
(json/parse-string nil)                   ;=> nil
(json/parse-string 42)                    ;=> nil   (non-binary)
(json/parse-string "null")                ;=> nil   (real JSON null — collides with parse-error signal; see OQ-1)
```

**Rationale:** No exception handling in the sandbox (DIV-10) means raising = unrecoverable program crash. `json/parse-string` returns `nil` on any failure (invalid JSON, `nil` input, non-binary input) so callers can guard with `(when result ...)` or thread through `(some->)`. Map keys are decoded as **strings** (not atoms) to match PTC-Lisp's tool-boundary convention and avoid atom memory leaks on untrusted input.

The `nil` return for both real JSON `null` and parse failure is a known ambiguity (OQ-1 in the plan). Programs that need to distinguish should guard on `(empty? s)` / shape *before* calling. MCP aggregator calls use a separate tagged `tool/call` result where `:ok` distinguishes success from failure.

### DIV-24: `json/generate-string` returns `nil` on non-encodable input

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | PtcRunner JSON support design decision |

```clojure
;; Vanilla Jason.encode/1 silently coerces non-boolean atoms to JSON strings:
;;   Jason.encode!(:fs)        ;=> "\"fs\""        (lossy auto-stringification)
;;   Jason.encode!(%{a: 1})    ;=> "{\"a\":1}"     (atom key silently stringified)

;; PTC-Lisp deliberately rejects them up-front, returning nil:
(json/generate-string :fs)                  ;=> nil      (non-boolean atom value)
(json/generate-string {:server "fs"})       ;=> nil      (atom key)
(json/generate-string {"server" :fs})       ;=> nil      (atom value)
(json/generate-string {1 "a"})              ;=> "{\"1\":\"a\"}"   (integer keys allowed; carve-out, no round-trip)
(json/generate-string POSITIVE_INFINITY)    ;=> nil      (special-float carve-out)
(json/generate-string {:tuple [{:ok 1}]})   ;=> nil      (any tuple, anywhere)

;; Programs that want strings on the wire convert explicitly:
(json/generate-string {"server" (name :fs)})
;=> "{\"server\":\"fs\"}"
```

**Rationale:** Silently auto-stringifying keywords would erode PTC-Lisp's type signal at the wire boundary. The implementation runs a pre-validation walk (`encodable_value?` / `encodable_key?`) over the value tree *before* invoking `Jason.encode/1` — any non-boolean atom, atom-keyed map entry, tuple, PID, reference, or function short-circuits to `nil`. Special floats (`POSITIVE_INFINITY`, `NEGATIVE_INFINITY`, `NaN` — which resolve to atoms `:infinity` / `:negative_infinity` / `:nan`) are also rejected because they aren't valid JSON scalars.

Map-key validation is **stricter** than value validation: JSON only accepts string keys. Once stringified, atom and float keys preserve no type signal across a round-trip and would break the §4.3 round-trip property, so they are rejected at the key position even when acceptable as values. Integer keys are allowed (Jason's default stringifies them) but **do not round-trip** — `{1 "a"}` parses back as `%{"1" => "a"}`.

The asymmetry with `parse-string` (returns `nil` on bad *input*) is the same DIV-* signal-value pattern: failures are observable as `nil` and the caller decides how to react.

### GAP-S08: `even?`/`odd?` handle floats gracefully

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | fixed (intentional divergence) |
| **Source** | Spec §8.8 |

```clojure
;; Clojure
(even? 4.0)   ;=> IllegalArgumentException

;; PTC-Lisp
(even? 4.0)   ;=> true
(even? 4.5)   ;=> false
```

Clojure throws on float arguments. PTC-Lisp accepts whole-number floats (returns true/false) and returns false for non-whole floats, consistent with the no-exceptions design (DIV-10). Previously PTC-Lisp crashed with an arithmetic error on any float input.

**Fix:** Changed `even?`/`odd?` to truncate whole-number floats before `rem`, and return `false` for non-whole floats and non-numbers.

### GAP-S09: `find` uses predicate-search semantics instead of Clojure map lookup

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `core/find-bug-001`, `core/find-missing-key-bug-001`, `core/find-present-nil-value-bug-001`, `core/find-nil-bug-001`, `core/find-vector-index-bug-001`, `core/find-vector-present-nil-bug-001`, `core/find-vector-out-of-range-bug-001`, `core/find-vector-negative-index-bug-001`, `core/find-set-nil-bug-001` |

```clojure
;; Clojure
(find {:a 1} :a)   ;=> [:a 1]
(find {:a 1} :b)   ;=> nil
(find {:a nil} :a) ;=> [:a nil]
(find nil :a)      ;=> nil
(find [10 20] 1)   ;=> [1 20]
(find [nil :b] 0)  ;=> [0 nil]
(find [10 20] 2)   ;=> nil
(find [nil :b] -1) ;=> nil
(find #{nil} nil)  ;=> IllegalArgumentException

;; PTC-Lisp current behavior
(find {:a 1} :a)   ;=> type_error
(find {:a 1} :b)   ;=> type_error
(find {:a nil} :a) ;=> type_error
(find nil :a)      ;=> type_error
(find [10 20] 1)   ;=> type_error
(find [nil :b] 0)  ;=> type_error
(find [10 20] 2)   ;=> type_error
(find [nil :b] -1) ;=> type_error
(find #{nil} nil)  ;=> nil
(find :a {:a 1})   ;=> nil
```

The PTC-Lisp function registry marks `find` as `clojure.core/find`, but the
implementation signature is `(find pred coll)` and behaves like a predicate
search. Clojure's `find` is `(find map key)` and returns a map/vector entry
or `nil`.

**Decision:** BUG. This is a Clojure-named function on normal finite data, and
the spec does not justify a divergence.

### GAP-S10: `nth` with a negative index reads from the end

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** (reclassified as DIV-26) |
| **Source** | Manual conformance case `core/nth-negative-div-001` |

```clojure
;; Clojure
(nth [1 2] -1)   ;=> IndexOutOfBoundsException

;; PTC-Lisp (fixed)
(nth [1 2] -1)   ;=> nil
```

**Decision:** BUG, fixed by folding negative indices into the existing
out-of-range signal-value policy (`DIV-26`). The 2-arity `nth` previously
delegated to `Enum.at`, which reads from the end for a negative index and
silently returned unrelated data; it now returns the `nil` signal for any
negative index, matching positive out-of-range access and the 3-arity `nth`'s
default. The remaining divergence (returning `nil` rather than raising) is the
intentional `DIV-26` behavior.

### GAP-S11: 3-arity `nth` default form is unsupported

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/nth-default-001`, `core/nth-negative-default-001`, `core/nth-nil-default-001`, `core/nth-string-default-001` |

```clojure
;; Clojure
(nth [1 2] 5 :x)   ;=> :x
(nth [1 2] -1 :x)  ;=> :x
(nth nil 0 :x)     ;=> :x
(nth "a" 1 :missing) ;=> :missing

;; PTC-Lisp (fixed)
(nth [1 2] 5 :x)   ;=> :x
(nth [1 2] -1 :x)  ;=> :x
(nth nil 0 :x)     ;=> :x
(nth "a" 1 :missing) ;=> :missing
```

**Fix:** Added the 3-arity `(nth coll idx not-found)` (the `nth` builtin is now
bound `:multi_arity`). It returns the element when `0 <= idx < count`, otherwise
the default — including for negative indexes and nil collections. The 2-arity
`nth` is now consistent: a negative or out-of-range index returns the `nil`
signal (DIV-26, GAP-S10) where the 3-arity returns the supplied default.
Maps/sets remain unindexed and raise, matching Clojure and the 2-arity.

### GAP-S94: `nth` rejects nil input instead of returning nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/nth-nil-001` |

```clojure
;; Clojure
(nth nil 0)   ;=> nil
(nth nil 5)   ;=> nil

;; PTC-Lisp (fixed)
(nth nil 0)   ;=> nil
(nth nil 5)   ;=> nil
```

**Decision:** BUG. `nth` is a supported Clojure-named finite access helper.
PTC-Lisp already prefers recoverable boundary values in adjacent access cases,
so nil input should not raise here.

**Fix:** Added a 2-arity `(nth nil idx)` => nil clause (any integer index),
mirroring the existing 3-arity nil clause and PTC's lenient out-of-range `nth`.

### GAP-S12: `get` does not support string indexes

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/get-string-index-bug-001`, `core/get-string-index-default-bug-001`, `core/get-string-non-index-key-bug-001`, `core/get-in-string-index-bug-001` |

```clojure
;; Clojure
(get "abc" 1)   ;=> \b
(get "ab" 9 :x) ;=> :x
(get "abc" :a)  ;=> nil
(get-in "ab" [0]) ;=> \a

;; PTC-Lisp current behavior
(get "abc" 1)   ;=> type_error
(get "ab" 9 :x) ;=> type_error
(get "abc" :a)  ;=> type_error
(get-in "ab" [0]) ;=> type_error
```

**Decision:** BUG. PTC-Lisp already treats strings as indexed sequences for
`nth`; `get` should not raise on the equivalent finite string/index access or
on ordinary missing-key lookup.

### GAP-S13: Vectors are not callable by index

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/vector-call-bug-001`, `core/apply-vector-function-bug-001`, `core/ifn-vector-bug-001` |

```clojure
;; Clojure
([10 20] 1)   ;=> 20
(apply [10 20] [1]) ;=> 20
(ifn? [1 2])  ;=> true

;; PTC-Lisp current behavior
([10 20] 1)   ;=> not_callable
(apply [10 20] [1]) ;=> not_callable
(ifn? [1 2])  ;=> false
```

**Decision:** BUG. PTC-Lisp supports keywords, maps, and sets as callables, and
vectors are normal finite indexed values. The same callability gap is visible
through `apply` and `ifn?`.

### GAP-S14: `contains?` on nil raises instead of returning false

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/contains-nil-001` |

```clojure
;; Clojure
(contains? nil :a)   ;=> false

;; PTC-Lisp (fixed)
(contains? nil :a)   ;=> false
```

**Fix:** Added a `contains?(nil, _key)` clause returning `false` — a nil
collection contains no keys, matching Clojure (and the recoverable signal-value
convention for Clojure-named predicates).

### GAP-S15: `clojure.string/split` keeps trailing empty element for empty regex

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `string/split-empty-regex-bug-001` |

```clojure
;; Clojure
(clojure.string/split "abc" #"")   ;=> ["a" "b" "c"]

;; PTC-Lisp current behavior
(clojure.string/split "abc" #"")   ;=> ["a" "b" "c" ""]
```

**Decision:** BUG. This is a Clojure-named string function on normal finite
input, and the extra trailing empty string is accidental.

### GAP-S95: `clojure.string/split` mishandles trailing empty fields and empty input

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/split-trailing-empty-bug-001`, `string/split-empty-input-bug-001` |

```clojure
;; Clojure
(clojure.string/split "a,b," #",")   ;=> ["a" "b"]
(clojure.string/split "" #",")       ;=> [""]

;; PTC-Lisp current behavior
(clojure.string/split "a,b," #",")   ;=> ["a" "b" ""]
(clojure.string/split "" #",")       ;=> []
```

**Decision:** BUG. `clojure.string/split` is marked supported. The two-arity
form follows Java split behavior with limit `0`, which discards trailing empty
fields while preserving the single empty input field.

### GAP-S16: `clojure.core/replace` sequence form is not implemented

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/replace-seq-001` |

```clojure
;; Clojure
(replace {:a :x} [:a :b])        ;=> [:x :b]
(replace [10 20 30] [0 1 2 0])   ;=> [10 20 30 10]

;; PTC-Lisp (fixed)
(replace {:a :x} [:a :b])        ;=> [:x :b]
(replace [10 20 30] [0 1 2 0])   ;=> [10 20 30 10]
```

**Decision:** BUG. The `clojure.core/replace` audit row is marked supported,
but the implemented `replace` was the 3-arity string function only.

**Fix:** `replace` is now a `:multi_arity` builtin — arity-2 is
`clojure.core/replace` (`replace_coll/2`: each element looked up in the
map/vector `smap`, absent elements unchanged), and arity-3 remains the
`clojure.string/replace` convenience alias. The seq replace uses flexible
lookup, so PTC's keyword/string key normalization matches keyword elements and
a vector `smap` resolves elements as 0-based indexes; `coll` is normalized as a
seq, so any seqable (incl. `nil` → `[]`) is accepted. The 1-arity transducer
form stays unsupported.

**Known limitation:** PTC collapses `clojure.core/replace` and
`clojure.string/replace` onto one unqualified `:replace` builtin (no
namespace-aware dispatch — see the `Math/` note in
[clojure-conformance-gaps](clojure-conformance-gaps.md)), so the two forms are
distinguished only by arity (2 → seq replace, 3 → string replace). A consequence
is that `(clojure.string/replace smap coll)` runs the seq form instead of
raising on arity; this nonsensical call is not worth a namespace-dispatch
refactor.

Seq replace also follows PTC's `get` value model: a list-valued element is a
get-in path rather than an exact key, so vector map keys are not matched
(`(replace {[:a] :x} [[:a]])` keeps `[:a]`, mirroring `(get {[:a] :x} [:a])` =>
nil). Special-casing exact vector-key lookup here would make `replace`
inconsistent with the rest of the flex-access model, so PTC's model takes
precedence.

### GAP-S17: `key`/`val` accept plain sequential pairs as map entries

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/key-vector-bug-001`, `core/val-vector-bug-001`, `core/key-list-pair-bug-001`, `core/val-list-pair-bug-001` |

```clojure
;; Clojure
(key [:a 1])   ;=> ClassCastException
(val [:a 1])   ;=> ClassCastException
(key (list :a 1)) ;=> ClassCastException
(val (list :a 1)) ;=> ClassCastException

;; PTC-Lisp current behavior
(key [:a 1])   ;=> :a
(val [:a 1])   ;=> 1
(key (list :a 1)) ;=> :a
(val (list :a 1)) ;=> 1
```

**Decision:** BUG. The program is invalid for Clojure's `key`/`val`; PTC-Lisp
should not silently treat arbitrary two-element vectors as JVM map entries
under Clojure compatibility.

### GAP-S136: `map-entry?` does not recognize explicit map seq entries

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance case `core/map-entry-predicate-seq-map-bug-001` |

```clojure
;; Clojure
(map-entry? (first (seq {:a 1})))   ;=> true

;; PTC-Lisp current behavior
(map-entry? (first (seq {:a 1})))   ;=> false
```

**Decision:** BUG. PTC-Lisp has a distinct explicit seq map-entry view that
`key` and `val` already understand, but `map-entry?` does not recognize the
same values as map entries.

### GAP-S18: `doseq` body `def` side effects do not update the outer var

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance case `core/doseq-def-side-effect-bug-001` |

```clojure
;; Clojure
(do (def xs [])
    (doseq [x [1 2]]
      (def xs (conj xs x)))
    xs)
;;=> [1 2]

;; PTC-Lisp current behavior
(do (def xs [])
    (doseq [x [1 2]]
      (def xs (conj xs x)))
    xs)
;;=> []
```

**Decision:** BUG. `doseq` is marked supported as a side-effecting iteration
form, and `def` is itself supported. Side effects performed inside the body
should be visible after the loop.

### GAP-S19: Nil-root map helpers raise instead of using Clojure nil-as-empty semantics

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `core/dissoc-nil-bug-001`, `core/get-in-nil-bug-001`, `core/get-in-nil-default-bug-001`, `core/update-nil-bug-001` |

```clojure
;; Clojure
(dissoc nil :a)                  ;=> nil
(get-in nil [:a])                ;=> nil
(get-in nil [:a] :x)             ;=> :x
(update nil :a (fnil inc 0))     ;=> {:a 1}

;; PTC-Lisp current behavior
(dissoc nil :a)                  ;=> type_error
(get-in nil [:a])                ;=> type_error
(get-in nil [:a] :x)             ;=> type_error
(update nil :a (fnil inc 0))     ;=> type_error
```

**Decision:** BUG. These are Clojure-named helpers on normal finite inputs.
PTC-Lisp already treats missing keys as recoverable `nil`; raising on a nil
map root is inconsistent with both Clojure compatibility and the signal-value
policy.

### GAP-S83: `update` cannot append at a vector's count index

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/update-vector-append-bug-001`, `core/update-in-vector-append-bug-001`, `core/update-in-empty-vector-append-bug-001` |

```clojure
;; Clojure
(update [10 20] 2 (fnil inc 0)) ;=> [10 20 1]
(update-in [10 20] [2] (fnil inc 0)) ;=> [10 20 1]
(update-in [] [0] (fnil identity :x)) ;=> [:x]

;; PTC-Lisp current behavior
(update [10 20] 2 (fnil inc 0)) ;=> runtime_error
(update-in [10 20] [2] (fnil inc 0)) ;=> runtime_error
(update-in [] [0] (fnil identity :x)) ;=> runtime_error
```

**Decision:** BUG. `update` is a supported Clojure-named associative helper,
and PTC-Lisp already supports adjacent vector associative behavior such as
`assoc` at index `count` and in-range vector `update`. The count-index append
case should follow Clojure's `assoc`-based `update` semantics.

### GAP-S84: `seq?` returns true for vectors

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/seq-predicate-vector-bug-001` |

```clojure
;; Clojure
(seq? [1]) ;=> false

;; PTC-Lisp current behavior
(seq? [1]) ;=> true
```

**Decision:** BUG. `seq?` is a supported Clojure-named predicate. PTC-Lisp
can keep using vectors as its primary concrete sequential collection, but the
predicate should still distinguish vectors from actual seq values when exposing
Clojure-compatible predicate behavior.

### GAP-S20: Some seq helpers reject nil instead of treating it as an empty seq

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/take-nil-bug-001`, `core/drop-nil-bug-001`, `core/frequencies-nil-bug-001`, `core/frequencies-map-bug-001`, `core/flatten-nil-bug-001`, `core/distinct-nil-bug-001`, `core/interleave-left-nil-001`, `core/interleave-right-nil-001`, `core/reverse-nil-bug-001`, `core/sort-nil-input-bug-001` |

```clojure
;; Clojure
(take 2 nil)       ;=> ()
(drop 2 nil)       ;=> ()
(frequencies nil)  ;=> {}
(frequencies {:a 1}) ;=> {[:a 1] 1}
(flatten nil)      ;=> ()
(distinct nil)     ;=> ()
(interleave nil [1]);=> ()
(interleave [1] nil);=> ()
(reverse nil)      ;=> ()
(sort nil)         ;=> ()

;; PTC-Lisp current behavior
(take 2 nil)       ;=> type_error
(drop 2 nil)       ;=> type_error
(frequencies nil)  ;=> type_error
(frequencies {:a 1}) ;=> type_error
(flatten nil)      ;=> type_error
(distinct nil)     ;=> type_error
(interleave nil [1]);=> type_error
(interleave [1] nil);=> type_error
(reverse nil)      ;=> type_error
(sort nil)         ;=> type_error
```

**Decision:** BUG. PTC-Lisp already handles `nil` as empty for adjacent
sequence helpers such as `map`, `filter`, `partition`, `split-at`, `into`, and
`select-keys`. These functions should not be stricter without a documented
design reason.

**Partially fixed:** the `interleave` sub-cases (`core/interleave-left-nil-001`,
`core/interleave-right-nil-001`) were closed alongside
[GAP-S98](#gap-s98-interleave-rejects-string-inputs). The remaining helpers
(`take`, `drop`, `frequencies`, `flatten`, `distinct`, `reverse`, `sort`) still
reject `nil` and keep this gap open.

### GAP-S134: `distinct` accepts direct map input Clojure rejects

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/distinct-map-bug-001` |

```clojure
;; Clojure
(distinct {:a 1 :b 2}) ;=> UnsupportedOperationException

;; PTC-Lisp current behavior
(distinct {:a 1 :b 2}) ;=> [[:a 1] [:b 2]]
```

**Decision:** BUG. `distinct` is a supported Clojure-named sequence helper,
but direct map inputs are not a supported ordered map view in PTC-Lisp's
documented map policy. Returning entries silently makes an invalid direct-map
call look successful; callers should use `seq`, `entries`, `keys`, or `vals`
when they need an ordered map view.

### GAP-S21: `reduce` without init on empty input ignores the reducing function identity

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/reduce-empty-no-init-bug-001`, `core/reduce-nil-no-init-bug-001`, `core/reduce-vector-empty-no-init-bug-001` |

```clojure
;; Clojure
(reduce + [])    ;=> 0
(reduce + nil)   ;=> 0
(reduce vector []) ;=> []

;; PTC-Lisp current behavior
(reduce + [])    ;=> nil
(reduce + nil)   ;=> nil
(reduce vector []) ;=> nil
```

**Decision:** BUG. For an empty input and a reducing function with a zero-arity
identity, Clojure calls that function. Returning `nil` silently changes numeric
and string reductions.

### GAP-S59: `reduce-kv` does not support vectors

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/reduce-kv-vector-bug-001`, `core/reduce-kv-empty-vector-bug-001` |

```clojure
;; Clojure
(reduce-kv (fn [acc k v] (conj acc [k v])) [] [:a :b])
;=> [[0 :a] [1 :b]]
(reduce-kv (fn [acc k v] (conj acc [k v])) [] [])
;=> []

;; PTC-Lisp current behavior
(reduce-kv (fn [acc k v] (conj acc [k v])) [] [:a :b])
;=> type error
(reduce-kv (fn [acc k v] (conj acc [k v])) [] [])
;=> type error
```

**Decision:** BUG. `reduce-kv` is a supported Clojure-named helper. Clojure
supports vectors by passing each index and value to the reducing function.

### GAP-S60: `interpose` rejects string inputs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/interpose-string-001` |

```clojure
;; Clojure
(interpose "," "ab")   ;=> ("a" "," "b")

;; PTC-Lisp (fixed)
(interpose "," "ab")   ;=> ["a" "," "b"]
(interpose "," "")     ;=> []
```

**Decision:** BUG. `interpose` is a supported Clojure-named sequence helper,
and PTC-Lisp already treats strings as seqable in adjacent helpers such as
`map`, `filter`, `partition`, `seq`, and `dedupe`.

**Fix:** Added a string clause that interposes the separator between the
string's characters (graphemes). Direct maps/sets still raise, preserving
[DIV-29](#div-29-direct-positional-sequence-operations-reject-maps) (positional
ops require an explicit ordered view via `seq`/`entries`/`keys`/`vals`).

### GAP-S98: `interleave` rejects string inputs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/interleave-string-001`, `core/interleave-left-nil-001`, `core/interleave-right-nil-001`, `div/interleave-map-direct-001` |

```clojure
;; Clojure
(interleave "ab" [1 2])   ;=> ("a" 1 "b" 2)

;; PTC-Lisp (fixed)
(interleave "ab" [1 2])   ;=> ["a" 1 "b" 2]
(interleave "ab" "cd")    ;=> ["a" "c" "b" "d"]
(interleave nil [1])      ;=> []                ; GAP-S20 sub-case
(interleave {:a 1} [2])   ;=> type_error        ; DIV-29 (direct maps/sets)
```

**Decision:** BUG. `interleave` is a supported Clojure-named sequence helper.
Strings are finite seqable inputs in Clojure and are already supported by
neighboring PTC-Lisp sequence helpers such as `map`, `filter`, `partition`,
`partition-by`, and `split-at` — and by its closest twin `interpose`
([GAP-S60](#gap-s60-interpose-rejects-string-inputs)).

**Fix:** Dropped the `{:rest, :list}` arg-spec and coerce each argument through
`interleave_seq/1` (list → itself, string → graphemes, `nil` → `[]`). This also
closes the `interleave` sub-cases of [GAP-S20](#gap-s20-some-seq-helpers-reject-nil-instead-of-treating-it-as-an-empty-seq).
Direct maps/sets have no clause and surface a `type_error`, preserving
[DIV-29](#div-29-direct-positional-sequence-operations-reject-maps), exactly as
`interpose` does.

### GAP-S143: Unary `interleave` is unsupported

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/interleave-one-coll-001` |

```clojure
;; Clojure
(interleave)                   ;=> ()
(interleave [1 2])             ;=> (1 2)
(interleave [1 2] [3 4] [5 6]) ;=> (1 3 5 2 4 6)

;; PTC-Lisp (fixed)
(interleave)                   ;=> []
(interleave [1 2])             ;=> [1 2]
(interleave [1 2] [3 4] [5 6]) ;=> [1 3 5 2 4 6]
```

**Decision:** BUG. `interleave` is marked supported, and Clojure's `interleave`
is variadic (0/1/n arity), all finite, eager, and pure.

**Fix:** Registered `interleave` as a `:collect` builtin over
`interleave_variadic/1` (0 args → `[]`, one seqable → its seq, n seqables →
interleaved, stopping at the shortest). Arguments are coerced through
`interleave_seq/1` (list → itself, string → graphemes, `nil` → `[]`), so
[GAP-S98](#gap-s98-interleave-rejects-string-inputs) and the `interleave`
sub-cases of [GAP-S20](#gap-s20-some-seq-helpers-reject-nil-instead-of-treating-it-as-an-empty-seq)
are also closed. Direct maps/sets still raise a `type_error`, preserving
[DIV-29](#div-29-direct-positional-sequence-operations-reject-maps).

### GAP-S102: Multi-collection `map` rejects string inputs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/map-multi-string-bug-001` |

```clojure
;; Clojure
(map vector "ab" [1 2]) ;=> (["a" 1] ["b" 2])

;; PTC-Lisp current behavior
(map vector "ab" [1 2]) ;=> type_error
```

**Decision:** BUG. `map` is a supported Clojure-named sequence helper.
PTC-Lisp already accepts string input for single-collection `map`; the
multi-collection arity should treat the same finite string value as seqable
instead of rejecting it.

### GAP-S22: `get-in` default is returned for an explicitly present nil value

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `core/get-in-default-present-nil-bug-001`, `core/get-in-default-nested-present-nil-bug-001`, `core/get-in-default-vector-present-nil-bug-001` |

```clojure
;; Clojure
(get-in {:a nil} [:a] :missing)   ;=> nil
(get-in {:a {:b nil}} [:a :b] :missing) ;=> nil
(get-in [nil :b] [0] :missing)    ;=> nil

;; PTC-Lisp current behavior
(get-in {:a nil} [:a] :missing)   ;=> :missing
(get-in {:a {:b nil}} [:a :b] :missing) ;=> :missing
(get-in [nil :b] [0] :missing)    ;=> :missing
```

**Decision:** BUG. This is a Clojure-named helper on normal finite data.
`get` already distinguishes a present nil value from a missing key when a
default is supplied, and `contains?` can observe the present nil key.

### GAP-S23: `select-keys` with nil keyseq raises instead of returning an empty map

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** (nil); string keyseq reclassified as [DIV-46](#div-46-select-keys-with-a-string-keyseq-matches-keyword-keys) |
| **Source** | Manual conformance case `core/select-keys-nil-keys-001` |

```clojure
;; Clojure
(select-keys {:a 1} nil)   ;=> {}

;; PTC-Lisp (fixed)
(select-keys {:a 1} nil)   ;=> {}
```

**Decision:** BUG (nil keyseq). Clojure treats nil as an empty key sequence;
PTC's signal-value policy favors an empty result over a low-level protocol
error.

**Fix:** `select_keys/2` now coerces the keyseq through the canonical
`Normalize.to_seq/1` (as `zipmap` does), honoring the `:seqable` arg-spec it
already advertises. nil → `[]` → `{}`, matching Clojure.

**String keyseq → DIV-46 (not a bug).** `(select-keys {:a 1 :b 2} ":a")` returns
`{"a" 1}` in PTC, not Clojure's `{}`. A string keyseq seqs to one-character
strings, and PTC (no char type; keyword keys stored as strings) flex-matches
`"a"` to keyword key `:a` — the same universal behavior as
`(select-keys {:a 1} ["a"])` => `{"a" 1}`. Forcing `{}` would require strict
non-flex lookup in this one function, contradicting the value model. See
[DIV-46](#div-46-select-keys-with-a-string-keyseq-matches-keyword-keys).

### GAP-S24: `update-keys`/`update-vals` on nil return nil instead of an empty map

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/update-keys-nil-bug-001`, `core/update-vals-nil-bug-001` |

```clojure
;; Clojure
(update-keys nil name)   ;=> {}
(update-vals nil inc)    ;=> {}

;; PTC-Lisp current behavior
(update-keys nil name)   ;=> nil
(update-vals nil inc)    ;=> nil
```

**Decision:** BUG. These functions are map transformations. On a nil map,
Clojure returns an empty map and does not call the transform function.

### GAP-S25: 3-arity `clojure.string/split` limit form is unsupported

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/split-limit-bug-001`, `string/split-limit-zero-bug-001`, `string/split-limit-one-bug-001`, `string/split-limit-negative-bug-001` |

```clojure
;; Clojure
(clojure.string/split "abc" #"" 2)   ;=> ["a" "bc"]
(clojure.string/split "a,,b" #"," 0) ;=> ["a" "" "b"]
(clojure.string/split "a,,b" #"," 1) ;=> ["a,,b"]
(clojure.string/split "a,,b" #"," -1) ;=> ["a" "" "b"]

;; PTC-Lisp current behavior
(clojure.string/split "abc" #"" 2)   ;=> arity error
(clojure.string/split "a,,b" #"," 0) ;=> arity error
(clojure.string/split "a,,b" #"," 1) ;=> arity error
(clojure.string/split "a,,b" #"," -1) ;=> arity error
```

**Decision:** BUG. The audit marks `clojure.string/split` supported, but a
documented finite Clojure arity is missing.

### GAP-S26: `clojure.string/join` rejects nil and seqable boundary inputs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/join-nil-bug-001`, `string/join-separator-nil-bug-001`, `string/join-string-coll-bug-001`, `string/join-map-coll-bug-001` |

```clojure
;; Clojure
(clojure.string/join nil)       ;=> ""
(clojure.string/join "," nil)   ;=> ""
(clojure.string/join nil [1 2]) ;=> "12"
(clojure.string/join "ab")      ;=> "ab"
(clojure.string/join "," {:a 1}) ;=> "[:a 1]"

;; PTC-Lisp current behavior
(clojure.string/join nil)       ;=> type_error
(clojure.string/join "," nil)   ;=> type_error
(clojure.string/join nil [1 2]) ;=> type_error
(clojure.string/join "ab")      ;=> type_error
(clojure.string/join "," {:a 1}) ;=> type_error
```

**Decision:** BUG. This is a Clojure-named helper on normal finite data.
Treating nil as empty and strings/maps as seqable is consistent with adjacent
sequence behavior.

### GAP-S27: `clojure.string/replace` does not support function replacements

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/replace-fn-bug-001`, `string/replace-fn-groups-bug-001` |

```clojure
;; Clojure
(clojure.string/replace "a1" #"\d" (fn [m] "X"))   ;=> "aX"
(clojure.string/replace "a1b2" #"(\d)" (fn [[m g]] (str "<" g ">"))) ;=> "a<1>b<2>"

;; PTC-Lisp current behavior
(clojure.string/replace "a1" #"\d" (fn [m] "X"))   ;=> type_error
(clojure.string/replace "a1b2" #"(\d)" (fn [[m g]] (str "<" g ">"))) ;=> type_error
```

**Decision:** BUG. The supported `clojure.string/replace` audit row currently
covers literal replacement only; Clojure's finite function replacement form is
not implemented.

### GAP-S73: `clojure.string/replace` does not honor regex replacement group references

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `string/replace-regex-backref-bug-001`, `string/replace-regex-invalid-dollar-bug-001` |

```clojure
;; Clojure
(clojure.string/replace "a1" #"(\d)" "<$1>") ;=> "a<1>"
(clojure.string/replace "a1" #"\d" "$$")    ;=> IllegalArgumentException

;; PTC-Lisp current behavior
(clojure.string/replace "a1" #"(\d)" "<$1>") ;=> "a<$1>"
(clojure.string/replace "a1" #"\d" "$$")    ;=> "a$$"
```

**Decision:** BUG. `clojure.string/replace` is marked supported for regex
replacement. Clojure follows Java replacement-string group reference semantics
for regex matches, including rejecting malformed dollar references.

### GAP-S74: `clojure.string/split` accepts plain string delimiters

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `string/split-string-delimiter-bug-001` |

```clojure
;; Clojure
(clojure.string/split "a.b.c" ".")   ;=> ClassCastException

;; PTC-Lisp current behavior
(clojure.string/split "a.b.c" ".")   ;=> ["a" "b" "c"]
```

**Decision:** BUG. The supported Clojure-named `split` function requires a
regex pattern delimiter. Accepting a plain string silently changes invalid
program structure into plausible data.

### GAP-S116: `clojure.string` helpers accept character arguments Clojure rejects

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/includes-char-hit-bug-001`, `string/includes-char-miss-bug-001`, `string/starts-with-char-hit-bug-001`, `string/starts-with-char-miss-bug-001`, `string/ends-with-char-hit-bug-001`, `string/ends-with-char-miss-bug-001`, `string/replace-char-match-string-replacement-bug-001`, `string/replace-string-match-char-replacement-bug-001`, `string/split-char-delimiter-bug-001`, `string/blank-char-bug-001`, `string/trim-newline-char-bug-001` |

```clojure
;; Clojure
(clojure.string/includes? "abc" \a)      ;=> ClassCastException
(clojure.string/includes? "abc" \z)      ;=> ClassCastException
(clojure.string/starts-with? "abc" \a)   ;=> ClassCastException
(clojure.string/starts-with? "abc" \b)   ;=> ClassCastException
(clojure.string/ends-with? "abc" \c)     ;=> ClassCastException
(clojure.string/ends-with? "abc" \b)     ;=> ClassCastException
(clojure.string/replace "aba" \a "x")   ;=> ClassCastException
(clojure.string/replace "aba" "a" \x)   ;=> ClassCastException
(clojure.string/split "a,b" \,)          ;=> ClassCastException
(clojure.string/blank? \space)           ;=> ClassCastException
(clojure.string/trim-newline \newline)   ;=> ClassCastException

;; PTC-Lisp current behavior
(clojure.string/includes? "abc" \a)      ;=> true
(clojure.string/includes? "abc" \z)      ;=> false
(clojure.string/starts-with? "abc" \a)   ;=> true
(clojure.string/starts-with? "abc" \b)   ;=> false
(clojure.string/ends-with? "abc" \c)     ;=> true
(clojure.string/ends-with? "abc" \b)     ;=> false
(clojure.string/replace "aba" \a "x")   ;=> "xbx"
(clojure.string/replace "aba" "a" \x)   ;=> "xbx"
(clojure.string/split "a,b" \,)          ;=> ["a" "b"]
(clojure.string/blank? \space)           ;=> true
(clojure.string/trim-newline \newline)   ;=> ""
```

**Decision:** BUG. These helpers are marked supported Clojure-named string
functions. PTC-Lisp represents character literals as one-character strings in
some contexts, but these API positions have stricter Clojure type expectations
and invalid programs should not be converted into plausible string operations.

### GAP-S124: `clojure.string/index-of` helpers reject finite numeric from-index arguments

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/index-of-float-from-index-bug-001`, `string/last-index-of-float-from-index-bug-001`, `string/index-of-float-truncating-from-index-bug-001`, `string/last-index-of-float-truncating-from-index-bug-001` |

```clojure
;; Clojure
(clojure.string/index-of "abc" "b" 1.0)         ;=> 1
(clojure.string/last-index-of "ababa" "a" 3.0)  ;=> 2
(clojure.string/index-of "abcabc" "b" 1.9)      ;=> 1
(clojure.string/last-index-of "ababa" "a" 3.9)  ;=> 2

;; PTC-Lisp current behavior
(clojure.string/index-of "abc" "b" 1.0)         ;=> type_error
(clojure.string/last-index-of "ababa" "a" 3.0)  ;=> type_error
(clojure.string/index-of "abcabc" "b" 1.9)      ;=> type_error
(clojure.string/last-index-of "ababa" "a" 3.9)  ;=> type_error
```

**Decision:** BUG. `index-of` and `last-index-of` are supported
Clojure-named string helpers. Their finite numeric from-index arguments should
follow Clojure's coercion behavior, matching the existing numeric index/count
coercion gap tracked for core helpers.

### GAP-S50: `clojure.string` whitespace classification differs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/blank-nbsp-bug-001`, `string/blank-em-space-bug-001`, `string/trim-nbsp-bug-001`, `string/trim-em-space-bug-001`, `string/triml-nbsp-bug-001`, `string/triml-em-space-bug-001`, `string/trimr-nbsp-bug-001`, `string/trimr-em-space-bug-001` |

```clojure
;; Clojure
(clojure.string/blank? "\u00A0")      ;=> false
(clojure.string/blank? "\u2003")      ;=> true
(clojure.string/trim "\u00A0x\u00A0") ;=> "\u00A0x\u00A0"
(clojure.string/trim "\u2003x\u2003") ;=> "x"
(clojure.string/triml "\u00A0x")     ;=> "\u00A0x"
(clojure.string/triml "\u2003x")     ;=> "x"
(clojure.string/trimr "x\u00A0")     ;=> "x\u00A0"
(clojure.string/trimr "x\u2003")     ;=> "x"

;; PTC-Lisp current behavior
(clojure.string/blank? "\u00A0")      ;=> true
(clojure.string/blank? "\u2003")      ;=> false
(clojure.string/trim "\u00A0x\u00A0") ;=> "x"
(clojure.string/trim "\u2003x\u2003") ;=> "\u2003x\u2003"
(clojure.string/triml "\u00A0x")     ;=> "x"
(clojure.string/triml "\u2003x")     ;=> "\u2003x"
(clojure.string/trimr "x\u00A0")     ;=> "x"
(clojure.string/trimr "x\u2003")     ;=> "x\u2003"
```

**Decision:** BUG. The audit marks these Clojure-named string helpers
supported. Clojure uses Java whitespace semantics here, where non-breaking
space is not removed by these helpers but EM SPACE is considered whitespace.

### GAP-S51: `clojure.string/split-lines` on empty string returns an empty vector

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `string/split-lines-empty-bug-001` |

```clojure
;; Clojure
(clojure.string/split-lines "")   ;=> [""]

;; PTC-Lisp current behavior
(clojure.string/split-lines "")   ;=> []
```

**Decision:** BUG. This is a supported Clojure-named string helper on finite
input, and returning an empty collection loses the single empty line.

### GAP-S52: Bit shift/test helpers do not apply JVM index masking

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/bit-shift-left-negative-bug-001`, `core/bit-shift-right-negative-bug-001`, `core/bit-test-negative-index-bug-001`, `core/bit-set-negative-index-bug-001`, `core/bit-clear-negative-index-bug-001`, `core/bit-flip-negative-index-bug-001`, `core/bit-set-large-index-bug-001`, `core/bit-clear-large-index-bug-001`, `core/bit-test-large-index-bug-001`, `core/bit-flip-large-index-bug-001`, `core/bit-clear-large-index-present-bug-001`, `core/bit-shift-left-large-count-bug-001`, `core/bit-shift-right-large-count-bug-001` |

```clojure
;; Clojure / JVM semantics
(bit-shift-left 1 -1)   ;=> -9223372036854775808
(bit-shift-right 8 -1)  ;=> 0
(bit-test 1 -1)         ;=> false
(bit-set 1 -1)          ;=> -9223372036854775807
(bit-clear 1 -1)        ;=> 1
(bit-flip 1 -1)         ;=> -9223372036854775807
(bit-set 0 64)          ;=> 1
(bit-clear -1 64)       ;=> -2
(bit-test 1 64)         ;=> true
(bit-flip 0 64)         ;=> 1
(bit-clear 1 64)        ;=> 0
(bit-shift-left 1 64)   ;=> 1
(bit-shift-right -2 64) ;=> -2

;; PTC-Lisp current behavior
(bit-shift-left 1 -1)   ;=> type error
(bit-shift-right 8 -1)  ;=> type error
(bit-test 1 -1)         ;=> type error
(bit-set 1 -1)          ;=> type error
(bit-clear 1 -1)        ;=> type error
(bit-flip 1 -1)         ;=> type error
(bit-set 0 64)          ;=> 18446744073709551616
(bit-clear -1 64)       ;=> -18446744073709551617
(bit-test 1 64)         ;=> false
(bit-flip 0 64)         ;=> 18446744073709551616
(bit-clear 1 64)        ;=> 1
(bit-shift-left 1 64)   ;=> 18446744073709551616
(bit-shift-right -2 64) ;=> -1
```

**Decision:** BUG. These are supported Clojure-named bit helpers, and JVM
shift/index masking gives defined results for negative and out-of-range counts.
If PTC-Lisp chooses to reject or reinterpret them for readability, that should
be promoted to an explicit divergence; under the default Clojure compatibility
policy this is a mismatch.

### GAP-S108: Unary bitwise helpers return the argument instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/bit-and-unary-001`, `core/bit-or-unary-001`, `core/bit-xor-unary-001`, `core/bit-and-not-unary-001` |

```clojure
;; Clojure
(bit-and 7)   ;=> ArityException
(bit-or 7)    ;=> ArityException
(bit-xor 7)   ;=> ArityException
(bit-and-not 7) ;=> ArityException

;; PTC-Lisp (fixed)
(bit-and 7)   ;=> raises (requires at least 2 arguments)
(bit-or 7)    ;=> raises
(bit-xor 7)   ;=> raises
(bit-and-not 7) ;=> raises
```

**Fix:** The unary clause of `reduce_bitwise` (and `bit_and_not`) now raises an
arity error instead of returning the argument. `bit-and`/`bit-or`/`bit-xor`/
`bit-and-not` require at least two arguments; a unary call is bad program shape
(Design Philosophy rule 4). `bit-not` remains correctly unary.

### GAP-S142: Bit helpers accept BigInt operands Clojure rejects

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/bit-not-bigint-bug-001`, `core/bit-and-bigint-bug-001`, `core/bit-or-bigint-bug-001`, `core/bit-set-bigint-bug-001`, `core/bit-test-bigint-bug-001`, `core/bit-shift-left-bigint-bug-001`, `core/bit-and-not-bigint-bug-001`, `core/bit-xor-bigint-bug-001`, `core/bit-clear-bigint-bug-001`, `core/bit-flip-bigint-bug-001`, `core/bit-shift-right-bigint-bug-001`, `core/bit-test-bigint-index-bug-001` |

```clojure
;; Clojure
(bit-not 9223372036854775808)          ;=> IllegalArgumentException
(bit-and 9223372036854775808 1)        ;=> IllegalArgumentException
(bit-or 9223372036854775808 1)         ;=> IllegalArgumentException
(bit-set 9223372036854775808 1)        ;=> IllegalArgumentException
(bit-test 9223372036854775808 1)       ;=> IllegalArgumentException
(bit-shift-left 9223372036854775808 1) ;=> IllegalArgumentException
(bit-and-not 9223372036854775808 1)    ;=> IllegalArgumentException
(bit-xor 9223372036854775808 1)        ;=> IllegalArgumentException
(bit-clear 9223372036854775808 1)      ;=> IllegalArgumentException
(bit-flip 9223372036854775808 1)       ;=> IllegalArgumentException
(bit-shift-right 9223372036854775808 1) ;=> IllegalArgumentException
(bit-test 1 9223372036854775808)       ;=> IllegalArgumentException

;; PTC-Lisp current behavior
(bit-not 9223372036854775808)          ;=> -9223372036854775809
(bit-and 9223372036854775808 1)        ;=> 0
(bit-or 9223372036854775808 1)         ;=> 9223372036854775809
(bit-set 9223372036854775808 1)        ;=> 9223372036854775810
(bit-test 9223372036854775808 1)       ;=> false
(bit-shift-left 9223372036854775808 1) ;=> 18446744073709551616
(bit-and-not 9223372036854775808 1)    ;=> 9223372036854775808
(bit-xor 9223372036854775808 1)        ;=> 9223372036854775809
(bit-clear 9223372036854775808 1)      ;=> 9223372036854775808
(bit-flip 9223372036854775808 1)       ;=> 9223372036854775810
(bit-shift-right 9223372036854775808 1) ;=> 4611686018427387904
(bit-test 1 9223372036854775808)       ;=> false
```

**Decision:** BUG. These are supported Clojure-named bit helpers. Clojure's
bit operations are defined for fixed-width primitive integer values and reject
BigInt operands; PTC-Lisp currently applies arbitrary-precision BEAM bit
semantics and returns plausible but non-Clojure results.

### GAP-S54: Nil/zero-map `merge` helpers return empty map instead of nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/merge-zero-arity-bug-001`, `core/merge-with-zero-maps-bug-001`, `core/merge-single-nil-bug-001`, `core/merge-with-single-nil-bug-001` |

```clojure
;; Clojure
(merge)        ;=> nil
(merge-with +) ;=> nil
(merge nil)    ;=> nil
(merge-with + nil) ;=> nil

;; PTC-Lisp current behavior
(merge)        ;=> {}
(merge-with +) ;=> {}
(merge nil)    ;=> {}
(merge-with + nil) ;=> {}
```

**Decision:** BUG. These are supported Clojure-named map helpers on finite
input. PTC-Lisp already matches Clojure's nil-as-empty behavior when nil maps
are supplied explicitly; only the zero-map arity differs.

### GAP-S146: One-collection `merge`/`merge-with` reject non-map values

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/merge-single-string-001`, `core/merge-single-vector-001`, `core/merge-with-single-string-001`, `core/merge-with-single-vector-001` |

```clojure
;; Clojure
(merge "ab")        ;=> "ab"
(merge [1 2])       ;=> [1 2]
(merge-with + "ab") ;=> "ab"
(merge-with + [1 2]) ;=> [1 2]

;; PTC-Lisp (fixed)
(merge "ab")        ;=> "ab"
(merge [1 2])       ;=> [1 2]
(merge-with + "ab") ;=> "ab"
(merge-with + [1 2]) ;=> [1 2]
```

**Fix:** `merge_variadic`/`merge_with_variadic` now return a single non-nil
supplied collection unchanged (Clojure's one-argument identity, regardless of
type). The `:merge`/`:merge-with` arg-specs use a new count-aware `:rest_min2`
shape that validates the rest args as maps only once 2+ are supplied, so a
single non-map is accepted while multi-collection non-map arguments still fail
validation with the canonical "expected map" error (matching Clojure, which
also raises). A single nil keeps the existing empty-map behavior (GAP-S54).

### GAP-S90: `merge`/`merge-with` reject vector targets

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/merge-vector-target-bug-001`, `core/merge-with-vector-target-bug-001` |

```clojure
;; Clojure
(merge [1 2] [3 4]) ;=> [1 2 [3 4]]
(merge-with + [1 2] {1 10}) ;=> [1 12]

;; PTC-Lisp current behavior
(merge [1 2] [3 4]) ;=> type_error
(merge-with + [1 2] {1 10}) ;=> type_error
```

**Decision:** BUG. `merge` and `merge-with` are supported Clojure-named
helpers. Clojure's finite semantics reduce by conjoining later inputs into the
first collection, so a vector target is valid even though unusual. PTC-Lisp
currently requires maps for all inputs without documenting that narrower
contract as a divergence.

### GAP-S144: `get-in` with a nil path returns nil instead of the root

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/get-in-nil-path-001` |

```clojure
;; Clojure
(get-in {:a 1} nil) ;=> {:a 1}

;; PTC-Lisp (fixed)
(get-in {:a 1} nil) ;=> {:a 1}
```

**Fix:** Added a `flex_get_in(data, nil)` clause that returns the root, matching
Clojure's treatment of a nil key path as an empty sequence (PTC-Lisp already
handled empty `[]` paths this way). The with-default arity also returns the
root rather than the default, since the path resolves successfully.

### GAP-S100: `merge` rejects vector map-entry sources

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/merge-vector-entry-source-bug-001` |

```clojure
;; Clojure
(merge {:a 1} [:b 2]) ;=> {:a 1, :b 2}

;; PTC-Lisp current behavior
(merge {:a 1} [:b 2]) ;=> type_error
```

**Decision:** BUG. `merge` is a supported Clojure-named helper. Clojure reduces
later inputs with `conj`, so a finite vector map-entry source is accepted when
the target is a map. PTC-Lisp already accepts nested entry collections such as
`[[:b 2]]`; the direct map-entry vector source is the missing case.

### GAP-S91: `clojure.walk/walk` accepts invalid transformed map entries

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `walk/walk-invalid-map-entry-bug-001` |

```clojure
;; Clojure
(clojure.walk/walk reverse identity {:a [1 2]})
;=> ClassCastException

;; PTC-Lisp current behavior
(clojure.walk/walk reverse identity {:a [1 2]})
;=> {[1 2] :a}
```

**Decision:** BUG. `clojure.walk/walk` is a supported Clojure-named structural
helper. When an inner transform turns a map entry into a shape that cannot be
conjoined back into a Clojure map as a map entry, Clojure raises. PTC-Lisp
currently accepts the transformed vector as a key/value pair and returns a
plausible but non-Clojure map.

### GAP-S55: `update-in` empty or nil path does not update the nil key

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/update-in-empty-path-001`, `core/update-in-empty-path-replace-001`, `core/update-in-nil-path-001` |

```clojure
;; Clojure
(update-in {:a 1} [] identity)   ;=> {:a 1, nil nil}
(update-in {:a 1} [] (constantly 2)) ;=> {:a 1, nil 2}
(update-in {:a 1} nil identity)  ;=> {:a 1, nil nil}

;; PTC-Lisp (fixed)
(update-in {:a 1} [] identity)   ;=> {:a 1, nil nil}
(update-in {:a 1} [] (constantly 2)) ;=> {:a 1, nil 2}
(update-in {:a 1} nil identity)  ;=> {:a 1, nil nil}
```

**Fix:** `assoc-in`/`update-in` now normalize an empty or nil path to the
single nil-key path `[nil]` (in `Runtime.MapOps`), matching Clojure's recursive
definition: `(update-in m [] f)` ≡ `(assoc m nil (f (get m nil)))`. Shared with
`GAP-S68` (`assoc-in`).

### GAP-S56: `empty` on strings returns an empty string instead of nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/empty-string-bug-001` |

```clojure
;; Clojure
(empty "abc")   ;=> nil

;; PTC-Lisp current behavior
(empty "abc")   ;=> ""
```

**Decision:** BUG. `empty` is a supported Clojure-named helper. Clojure strings
are seqable but not persistent collections, so `empty` returns nil even though
nearby helpers such as `seq`, `not-empty`, and `count` handle strings.

### GAP-S88: `empty` on non-collections does not return nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/empty-number-bug-001`, `core/empty-boolean-bug-001`, `core/empty-keyword-bug-001`, `core/empty-char-bug-001` |

```clojure
;; Clojure
(empty 1)      ;=> nil
(empty true)   ;=> nil
(empty :a)     ;=> nil
(empty \a)     ;=> nil

;; PTC-Lisp current behavior
(empty 1)      ;=> type_error
(empty true)   ;=> type_error
(empty :a)     ;=> {}
(empty \a)     ;=> ""
```

**Decision:** BUG. `empty` is a supported Clojure-named helper and Clojure
defines non-collection inputs as returning nil. This is a finite value
classification case, not a sandbox safety issue.

### GAP-S57: `concat` rejects string inputs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/concat-string-bug-001` |

```clojure
;; Clojure
(concat "ab" "cd")   ;=> ("a" "b" "c" "d")

;; PTC-Lisp current behavior
(concat "ab" "cd")   ;=> type error
```

**Decision:** BUG. `concat` is a supported Clojure-named sequence helper, and
PTC-Lisp already treats strings as seqable in adjacent helpers such as `seq`,
`partition`, `cons`, `vec`, and `not-empty`.

### GAP-S58: `juxt` result supports only one call argument

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/juxt-multiple-args-bug-001` |

```clojure
;; Clojure
((juxt + vector) 1 2 3)   ;=> [6 [1 2 3]]

;; PTC-Lisp current behavior
((juxt + vector) 1 2 3)   ;=> arity error
```

**Decision:** BUG. `juxt` is a supported Clojure-named higher-order helper.
The resulting function should forward all call arguments to every wrapped
function, just like `partial`, `complement`, and the predicate combinators
already do for multi-argument calls.

### GAP-S110: Zero-arity `juxt` returns a function instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/juxt-zero-arity-001`, `core/juxt-zero-arity-call-001` |

```clojure
;; Clojure
(juxt)   ;=> ArityException
((juxt) 1) ;=> ArityException

;; PTC-Lisp (fixed)
(juxt)   ;=> raises (requires at least one function)
((juxt) 1) ;=> raises (the (juxt) form fails analysis)
```

**Fix:** `analyze_juxt([])` now raises an arity error; `juxt` requires at least
one function, so a zero-arity `(juxt)` is bad program shape rather than a
function that always returns `[]` (Design Philosophy rule 4). Because the error
is raised at analysis time, `((juxt) 1)` also fails (its `(juxt)` operand fails
to analyze).
The zero-arity constructor call is an invalid Clojure program, and returning a
callable silently hides that arity error.

### GAP-S61: `parse-double` rejects valid Java decimal spellings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/parse-double-whitespace-bug-001`, `core/parse-double-trailing-whitespace-bug-001`, `core/parse-double-tab-whitespace-bug-001`, `core/parse-double-leading-dot-bug-001`, `core/parse-double-trailing-dot-bug-001`, `core/parse-double-hex-float-bug-001` |

```clojure
;; Clojure
(parse-double " 1.5")   ;=> 1.5
(parse-double "1.5 ")   ;=> 1.5
(parse-double "\t1.5")  ;=> 1.5
(parse-double ".5")     ;=> 0.5
(parse-double "1.")     ;=> 1.0
(parse-double "0x1.0p0") ;=> 1.0

;; PTC-Lisp current behavior
(parse-double " 1.5")   ;=> nil
(parse-double "1.5 ")   ;=> nil
(parse-double "\t1.5")  ;=> nil
(parse-double ".5")     ;=> nil
(parse-double "1.")     ;=> nil
(parse-double "0x1.0p0") ;=> nil
```

**Decision:** BUG. `parse-double` is a supported Clojure-named helper. The
documented `DIV-18` signal behavior covers non-string and invalid parse input;
surrounding whitespace and Java decimal spellings are valid Clojure input and
should parse.

### GAP-S85: `parse-long` accepts values outside Java long range

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/parse-long-overflow-bug-001`, `core/parse-long-plus-overflow-bug-001`, `core/parse-long-underflow-bug-001` |

```clojure
;; Clojure
(parse-long "9223372036854775808") ;=> nil
(parse-long "+9223372036854775808") ;=> nil
(parse-long "-9223372036854775809") ;=> nil

;; PTC-Lisp current behavior
(parse-long "9223372036854775808") ;=> 9223372036854775808
(parse-long "+9223372036854775808") ;=> 9223372036854775808
(parse-long "-9223372036854775809") ;=> -9223372036854775809
```

**Decision:** BUG. `parse-long` is a supported Clojure-named parser. Its safe
signal behavior should match Clojure's nil-on-failure contract for values that
cannot fit in a Java long, even though PTC-Lisp integers are otherwise
arbitrary precision.

### GAP-S62: `int` rejects NaN instead of returning zero

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/int-nan-bug-001` |

```clojure
;; Clojure
(int ##NaN)   ;=> 0

;; PTC-Lisp current behavior
(int ##NaN)   ;=> arithmetic error
```

**Decision:** BUG. `int` is a supported Clojure-named numeric coercion helper.
NaN is a representable PTC-Lisp numeric value, and Clojure/JVM defines this
finite coercion result.

### GAP-S138: `mod`/`quot`/`rem` mishandle non-finite operands

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/mod-nan-bug-001`, `core/quot-nan-bug-001`, `core/rem-nan-bug-001`, `core/mod-nan-divisor-bug-001`, `core/quot-nan-divisor-bug-001`, `core/rem-nan-divisor-bug-001`, `core/mod-infinite-dividend-bug-001`, `core/quot-infinite-dividend-bug-001`, `core/rem-infinite-dividend-bug-001`, `core/quot-infinite-divisor-bug-001` |

```clojure
;; Clojure
(mod ##NaN 2)   ;=> NumberFormatException
(quot ##NaN 2)  ;=> NumberFormatException
(rem ##NaN 2)   ;=> NumberFormatException
(mod 2 ##NaN)   ;=> NumberFormatException
(quot 2 ##NaN)  ;=> NumberFormatException
(rem 2 ##NaN)   ;=> NumberFormatException
(mod ##Inf 2)   ;=> NumberFormatException
(quot ##Inf 2)  ;=> NumberFormatException
(rem ##Inf 2)   ;=> NumberFormatException
(quot 2 ##Inf)  ;=> 0.0

;; PTC-Lisp current behavior
(mod ##NaN 2)   ;=> ##NaN
(quot ##NaN 2)  ;=> ##NaN
(rem ##NaN 2)   ;=> ##NaN
(mod 2 ##NaN)   ;=> ##NaN
(quot 2 ##NaN)  ;=> ##NaN
(rem 2 ##NaN)   ;=> ##NaN
(mod ##Inf 2)   ;=> ##NaN
(quot ##Inf 2)  ;=> ##NaN
(rem ##Inf 2)   ;=> ##NaN
(quot 2 ##Inf)  ;=> ##NaN
```

**Decision:** BUG. These are supported Clojure-named integer arithmetic
helpers. Clojure either rejects non-finite operands or returns the JVM-defined
finite quotient result. PTC-Lisp should not silently collapse these
integer-only operations to NaN.

### GAP-S139: `clojure.string` helpers reject numeric receiver input

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/lower-case-number-bug-001`, `string/includes-number-hit-bug-001`, `string/includes-number-miss-bug-001`, `string/replace-number-receiver-bug-001`, `string/starts-with-number-bug-001`, `string/ends-with-number-bug-001`, `string/last-index-of-number-bug-001`, `string/upper-case-number-bug-001`, `string/index-of-number-bug-001` |

```clojure
;; Clojure
(clojure.string/lower-case 12)       ;=> "12"
(clojure.string/includes? 123 "2")   ;=> true
(clojure.string/includes? 123 "9")   ;=> false
(clojure.string/replace 121 "1" "x") ;=> "x2x"
(clojure.string/starts-with? 123 "1") ;=> true
(clojure.string/ends-with? 123 "3")  ;=> true
(clojure.string/last-index-of 123 "2") ;=> 1
(clojure.string/upper-case 12)       ;=> "12"
(clojure.string/index-of 123 "2")    ;=> 1

;; PTC-Lisp current behavior
(clojure.string/lower-case 12)       ;=> type_error
(clojure.string/includes? 123 "2")   ;=> type_error
(clojure.string/includes? 123 "9")   ;=> type_error
(clojure.string/replace 121 "1" "x") ;=> type_error
(clojure.string/starts-with? 123 "1") ;=> type_error
(clojure.string/ends-with? 123 "3")  ;=> type_error
(clojure.string/last-index-of 123 "2") ;=> type_error
(clojure.string/upper-case 12)       ;=> type_error
(clojure.string/index-of 123 "2")    ;=> type_error
```

**Decision:** BUG. These are supported Clojure string helpers. Numeric receiver
inputs are finite values that Clojure stringifies before applying deterministic
string operations; PTC-Lisp currently rejects them even though the result is
deterministic and recoverable.

### GAP-S140: No-init `def` raises instead of creating an unbound var

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/def-no-init-bug-001` |

```clojure
;; Clojure
(def no-init-probe) ;=> #'user/no-init-probe

;; PTC-Lisp current behavior
(def no-init-probe) ;=> invalid_arity
```

**Decision:** BUG. `def` is a supported Clojure-named special form. The
no-init form is valid Clojure syntax and creates an interned but unbound var;
PTC-Lisp currently rejects it during analysis.

### GAP-S141: `def`/`defonce` return unqualified var references

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/def-return-var-namespace-bug-001`, `core/defonce-return-var-namespace-bug-001` |

```clojure
;; Clojure
(def return-var-probe 1)       ;=> #'user/return-var-probe
(defonce return-once-probe 1)  ;=> #'user/return-once-probe

;; PTC-Lisp current behavior
(def return-var-probe 1)       ;=> #'return-var-probe
(defonce return-once-probe 1)  ;=> #'return-once-probe
```

**Decision:** BUG. `def` and `defonce` are supported Clojure-named forms, and
their return values are observable. PTC-Lisp creates the bindings but returns
unqualified var references instead of matching Clojure's namespace-qualified
var representation.

### GAP-S111: `int` accepts values outside the Java int range

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/int-overflow-positive-bug-001`, `core/int-overflow-negative-bug-001` |

```clojure
;; Clojure
(int 2147483648)    ;=> ArithmeticException
(int -2147483649)   ;=> ArithmeticException

;; PTC-Lisp current behavior
(int 2147483648)    ;=> 2147483648
(int -2147483649)   ;=> -2147483649
```

**Decision:** BUG. `int` is a supported Clojure-named numeric coercion helper
whose contract follows JVM primitive int coercion. PTC-Lisp can keep
arbitrary-precision integers generally, but this supported coercion should not
turn overflow into plausible unchanged data.

### GAP-S121: `int` rejects character literals instead of returning code points

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/int-char-bug-001`, `core/int-newline-char-bug-001`, `core/int-tab-char-bug-001` |

```clojure
;; Clojure
(int \A)        ;=> 65
(int \newline)  ;=> 10
(int \tab)      ;=> 9

;; PTC-Lisp current behavior
(int \A)        ;=> runtime error
(int \newline)  ;=> runtime error
(int \tab)      ;=> runtime error
```

**Decision:** BUG. `int` is a supported Clojure-named coercion helper.
Character literals are valid Clojure inputs and should coerce to their numeric
code points. PTC-Lisp's character literals are represented as strings today,
but accepting them here avoids a recoverable runtime failure in supported core
behavior.

### GAP-S122: `float` accepts infinite inputs Clojure rejects

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/float-infinity-bug-001`, `core/float-negative-infinity-bug-001` |

```clojure
;; Clojure
(float ##Inf)   ;=> IllegalArgumentException
(float ##-Inf)  ;=> IllegalArgumentException

;; PTC-Lisp current behavior
(float ##Inf)   ;=> infinity
(float ##-Inf)  ;=> negative_infinity
```

**Decision:** BUG. `float` is a supported Clojure-named numeric coercion
helper. Clojure rejects infinities as out of range for this coercion while
accepting `##NaN`; returning infinite signal values makes range failure look
like successful data.

### GAP-S127: `double?`/`float?` reject special float literals

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/double-predicate-nan-bug-001`, `core/double-predicate-infinity-bug-001`, `core/float-predicate-nan-bug-001`, `core/float-predicate-infinity-bug-001` |

```clojure
;; Clojure
(double? ##NaN)  ;=> true
(double? ##Inf)  ;=> true
(float? ##NaN)   ;=> true
(float? ##Inf)   ;=> true

;; PTC-Lisp current behavior
(double? ##NaN)  ;=> false
(double? ##Inf)  ;=> false
(float? ##NaN)   ;=> false
(float? ##Inf)   ;=> false
```

**Decision:** BUG. `double?` and `float?` are supported Clojure-named numeric
predicates. PTC-Lisp exposes `##NaN` and infinities as numeric literals, so the
floating predicates should not classify those representable special values as
non-floating.

### GAP-S63: Keyword invocation matches string keys

| Field | Value |
|-------|-------|
| **Priority** | P0 |
| **Status** | open |
| **Source** | Manual conformance case `core/keyword-call-string-key-bug-001` |

```clojure
;; Clojure
(:a {"a" 1})   ;=> nil

;; PTC-Lisp current behavior
(:a {"a" 1})   ;=> 1
```

**Decision:** BUG. Keyword invocation should perform exact keyword lookup.
Returning a string-keyed value is a silent wrong result and can hide data-shape
errors at map boundaries. String-key convenience belongs in explicit helpers
such as `clojure.walk/keywordize-keys`, not in keyword lookup itself.

### GAP-S64: Zero-arity `distinct?` returns true instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/distinct-predicate-zero-arity-bug-001` |

```clojure
;; Clojure
(distinct?)   ;=> ArityException

;; PTC-Lisp current behavior
(distinct?)   ;=> true
```

**Decision:** BUG. `distinct?` is a supported Clojure-named predicate, but
Clojure defines no zero-arity form. PTC-Lisp should keep the supported arity
surface aligned unless there is an explicit recoverability reason to diverge.

### GAP-S101: `distinct?` treats repeated NaN values as duplicates

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/distinct-predicate-nan-bug-001`, `core/distinct-predicate-three-nan-bug-001`, `core/distinct-predicate-separated-nan-bug-001` |

```clojure
;; Clojure
(distinct? ##NaN ##NaN) ;=> true
(distinct? ##NaN ##NaN ##NaN) ;=> true
(distinct? ##NaN 1 ##NaN) ;=> true

;; PTC-Lisp current behavior
(distinct? ##NaN ##NaN) ;=> false
(distinct? ##NaN ##NaN ##NaN) ;=> false
(distinct? ##NaN 1 ##NaN) ;=> false
```

**Decision:** BUG. `distinct?` is a supported Clojure-named predicate. PTC-Lisp
already matches Clojure for `(= ##NaN ##NaN)` and `(not= ##NaN ##NaN)`, so
treating repeated NaN arguments as duplicates is an isolated predicate
inconsistency rather than a documented numeric-equality divergence.

### GAP-S65: `format` ignores width and padding flags

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `core/format-zero-padding-bug-001`, `core/format-left-width-bug-001`, `core/format-string-width-bug-001`, `core/format-float-zero-padding-bug-001`, `core/format-plus-sign-bug-001`, `core/format-space-sign-bug-001`, `core/format-hex-zero-padding-bug-001`, `core/format-alternate-hex-bug-001`, `core/format-parentheses-negative-bug-001` |

```clojure
;; Clojure
(format "%02d" 3)      ;=> "03"
(format "%-4s!" "x")   ;=> "x   !"
(format "%5s" "x")     ;=> "    x"
(format "%05.2f" 3.1)  ;=> "03.10"
(format "%+d" 3)       ;=> "+3"
(format "% d" 3)       ;=> " 3"
(format "%04x" 15)     ;=> "000f"
(format "%#x" 15)      ;=> "0xf"
(format "%(d" -3)      ;=> "(3)"

;; PTC-Lisp current behavior
(format "%02d" 3)      ;=> "3"
(format "%-4s!" "x")   ;=> "x!"
(format "%5s" "x")     ;=> "x"
(format "%05.2f" 3.1)  ;=> "3.10"
(format "%+d" 3)       ;=> runtime_error
(format "% d" 3)       ;=> runtime_error
(format "%04x" 15)     ;=> "f"
(format "%#x" 15)      ;=> runtime_error
(format "%(d" -3)      ;=> runtime_error
```

**Decision:** BUG. `format` is marked supported and already accepts Java-style
format strings for normal finite values. Ignoring or rejecting field width,
padding, and sign flags produces silent presentation/data-export mismatches.

### GAP-S89: `format` rejects boolean and newline conversions

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/format-boolean-conversion-bug-001`, `core/format-newline-conversion-bug-001`, `core/format-newline-only-conversion-bug-001` |

```clojure
;; Clojure
(format "%b %B" nil true) ;=> "false TRUE"
(format "a%nb")           ;=> "a\nb"
(format "%n")             ;=> "\n"

;; PTC-Lisp current behavior
(format "%b %B" nil true) ;=> runtime_error
(format "a%nb")           ;=> runtime_error
(format "%n")             ;=> runtime_error
```

**Decision:** BUG. `format` is a supported Clojure-named helper backed by
Java Formatter semantics for finite strings and values. Boolean and newline
conversions do not require host access, mutation, laziness, or unbounded
execution.

### GAP-S117: `format` rejects nil for supported numeric conversions

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/format-decimal-nil-bug-001`, `core/format-octal-nil-bug-001`, `core/format-hex-nil-bug-001`, `core/format-float-nil-bug-001` |

```clojure
;; Clojure
(format "%d" nil)   ;=> "null"
(format "%o" nil)   ;=> "null"
(format "%x" nil)   ;=> "null"
(format "%f" nil)   ;=> "null"

;; PTC-Lisp current behavior
(format "%d" nil)   ;=> runtime_error
(format "%o" nil)   ;=> runtime_error
(format "%x" nil)   ;=> runtime_error
(format "%f" nil)   ;=> runtime_error
```

**Decision:** BUG. These conversions are already part of the supported
`format` surface for normal finite values. Java Formatter renders nil/null as
`"null"` for numeric conversions instead of type-checking before formatting.
This is separate from `DIV-21`, where PTC-Lisp intentionally renders `%s` nil
as an empty string for consistency with `(str nil)`.

### GAP-S96: `format` misses common Java Formatter conversions and argument indexes

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/format-uppercase-string-conversion-bug-001`, `core/format-grouping-integer-bug-001`, `core/format-grouping-float-bug-001`, `core/format-uppercase-hex-conversion-bug-001`, `core/format-general-float-conversion-bug-001`, `core/format-general-precision-conversion-bug-001`, `core/format-uppercase-general-float-conversion-bug-001`, `core/format-uppercase-exponent-conversion-bug-001`, `core/format-character-conversion-bug-001`, `core/format-hash-code-conversion-bug-001`, `core/format-uppercase-hash-code-conversion-bug-001`, `core/format-argument-index-bug-001`, `core/format-argument-index-with-width-bug-001`, `core/format-previous-argument-index-bug-001`, `core/format-date-year-conversion-bug-001` |

```clojure
;; Clojure
(format "%S" "ab")             ;=> "AB"
(format "%,d" 1000)            ;=> "1,000"
(format "%,.2f" 1234.5)        ;=> "1,234.50"
(format "%X" 255)              ;=> "FF"
(format "%g" 1.0)              ;=> "1.00000"
(format "%.2g" 12.34)          ;=> "12"
(format "%G" 1.0)              ;=> "1.00000"
(format "%E" 1.0)              ;=> "1.000000E+00"
(format "%c" \A)               ;=> "A"
(format "%h" "abc")            ;=> "17862"
(format "%H" "abc")            ;=> "17862"
(format "%2$s %1$s" "a" "b")   ;=> "b a"
(format "%2$04d %1$s" "x" 3)   ;=> "0003 x"
(format "%s %<s" "a")          ;=> "a a"
(format "%tY" (java.util.Date. 0)) ;=> "1970"

;; PTC-Lisp current behavior
(format "%S" "ab")             ;=> runtime_error
(format "%,d" 1000)            ;=> runtime_error
(format "%,.2f" 1234.5)        ;=> runtime_error
(format "%X" 255)              ;=> runtime_error
(format "%g" 1.0)              ;=> runtime_error
(format "%.2g" 12.34)          ;=> runtime_error
(format "%G" 1.0)              ;=> runtime_error
(format "%E" 1.0)              ;=> runtime_error
(format "%c" \A)               ;=> runtime_error
(format "%h" "abc")            ;=> runtime_error
(format "%H" "abc")            ;=> runtime_error
(format "%2$s %1$s" "a" "b")   ;=> runtime_error
(format "%2$04d %1$s" "x" 3)   ;=> runtime_error
(format "%s %<s" "a")          ;=> runtime_error
(format "%tY" (java.util.Date. 0)) ;=> runtime_error
```

**Decision:** BUG. `format` is marked supported and intentionally follows
Java Formatter-style strings for finite values. These conversions and argument
indexes are deterministic formatting behavior, not unsupported host access.

### GAP-S66: `re-pattern` rejects existing regex patterns

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/re-pattern-pattern-input-bug-001` |

```clojure
;; Clojure
(re-find (re-pattern #"a+") "baac")   ;=> "aa"

;; PTC-Lisp current behavior
(re-find (re-pattern #"a+") "baac")   ;=> type_error
```

**Decision:** BUG. `re-pattern` is a supported Clojure-named regex helper.
Clojure treats an existing pattern as already compiled; PTC-Lisp should return
it unchanged.

### GAP-S82: `re-seq` no-match returns empty vector instead of nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/re-seq-no-match-bug-001` |

```clojure
;; Clojure
(re-seq #"z" "abc")   ;=> nil

;; PTC-Lisp current behavior
(re-seq #"z" "abc")   ;=> []
```

**Decision:** BUG. `re-seq` is a supported Clojure-named regex helper. A
no-match result is a normal finite input case, and Clojure uses `nil` to signal
absence rather than an empty sequence.

### GAP-S92: Regex helpers mishandle optional unmatched capture slots

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/re-find-optional-capture-bug-001`, `core/re-matches-optional-capture-bug-001`, `core/re-seq-optional-capture-bug-001`, `core/re-find-leading-optional-capture-bug-001`, `core/re-matches-leading-optional-capture-bug-001`, `core/re-seq-leading-optional-capture-bug-001`, `core/re-find-multiple-optional-captures-bug-001`, `core/re-matches-multiple-optional-captures-bug-001`, `core/re-seq-multiple-optional-captures-bug-001` |

```clojure
;; Clojure
(re-find #"a(\d+)?" "xa")       ;=> ["a" nil]
(re-matches #"a(\d+)?" "a")     ;=> ["a" nil]
(re-seq #"a(\d+)?" "a a2")      ;=> (["a" nil] ["a2" "2"])
(re-find #"(a)?(b)" "b")        ;=> ["b" nil "b"]
(re-matches #"(a)?(b)" "b")     ;=> ["b" nil "b"]
(re-seq #"(a)?(b)" "b ab")      ;=> (["b" nil "b"] ["ab" "a" "b"])
(re-find #"(a)?(b)?(c)" "c")    ;=> ["c" nil nil "c"]
(re-matches #"(a)?(b)?(c)" "c") ;=> ["c" nil nil "c"]
(re-seq #"(a)?(b)?(c)" "c abc") ;=> (["c" nil nil "c"] ["abc" "a" "b" "c"])

;; PTC-Lisp current behavior
(re-find #"a(\d+)?" "xa")       ;=> "a"
(re-matches #"a(\d+)?" "a")     ;=> "a"
(re-seq #"a(\d+)?" "a a2")      ;=> ["a" ["a2" "2"]]
(re-find #"(a)?(b)" "b")        ;=> ["b" "" "b"]
(re-matches #"(a)?(b)" "b")     ;=> ["b" "" "b"]
(re-seq #"(a)?(b)" "b ab")      ;=> [["b" "" "b"] ["ab" "a" "b"]]
(re-find #"(a)?(b)?(c)" "c")    ;=> ["c" "" "" "c"]
(re-matches #"(a)?(b)?(c)" "c") ;=> ["c" "" "" "c"]
(re-seq #"(a)?(b)?(c)" "c abc") ;=> [["c" "" "" "c"] ["abc" "a" "b" "c"]]
```

**Decision:** BUG. `re-find`, `re-matches`, and `re-seq` are supported
Clojure-named regex helpers. Optional groups that do not participate still
occupy capture positions in Clojure with `nil`; dropping those slots or
returning empty strings loses structural information.

### GAP-S131: Regex helpers accept character inputs as strings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/re-find-char-input-bug-001`, `core/re-matches-char-input-bug-001`, `core/re-seq-char-input-bug-001`, `core/re-pattern-char-bug-001` |

```clojure
;; Clojure
(re-find #"a" \a)     ;=> ClassCastException
(re-matches #"a" \a)  ;=> ClassCastException
(re-seq #"a" \a)      ;=> ClassCastException
(re-pattern \a)       ;=> ClassCastException

;; PTC-Lisp current behavior
(re-find #"a" \a)     ;=> "a"
(re-matches #"a" \a)  ;=> "a"
(re-seq #"a" \a)      ;=> ["a"]
(re-pattern \a)       ;=> regex pattern
```

**Decision:** BUG. Regex helpers are supported Clojure-named string/pattern
APIs. Character literals are not valid CharSequence/String inputs in these
positions, and accepting them converts invalid program structure into plausible
regex results.

### GAP-S93: `str` on regex patterns leaks the internal representation

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/str-regex-bug-001`, `core/str-empty-regex-bug-001` |

```clojure
;; Clojure
(str #"a+")   ;=> "a+"
(str (re-pattern "")) ;=> ""

;; PTC-Lisp current behavior
(str #"a+")   ;=> "{:re_mp, {:re_pattern, ...}, ...}"
(str (re-pattern "")) ;=> "{:re_mp, {:re_pattern, ...}, ...}"
```

**Decision:** BUG. `str` and regex literals are both supported finite
Clojure-named surfaces, and `pr-str` already renders regex literals in a
Clojure-compatible readable form. `str` should not expose Erlang regex internals.

### GAP-S126: `pr-str` prints character literals as strings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/pr-str-char-bug-001`, `core/pr-str-newline-char-bug-001` |

```clojure
;; Clojure
(pr-str \a)        ;=> "\\a"
(pr-str \newline)  ;=> "\\newline"

;; PTC-Lisp current behavior
(pr-str \a)        ;=> "\"a\""
(pr-str \newline)  ;=> "\"\\n\""
```

**Decision:** BUG. `pr-str` is a supported Clojure-named readable printer.
Character literals should retain character syntax at the API boundary instead
of being emitted as string literals.

### GAP-S129: `name` accepts character literals as strings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/name-char-bug-001`, `core/name-newline-char-bug-001` |

```clojure
;; Clojure
(name \a)        ;=> ClassCastException
(name \newline)  ;=> ClassCastException

;; PTC-Lisp current behavior
(name \a)        ;=> "a"
(name \newline)  ;=> "\n"
```

**Decision:** BUG. `name` is a supported Clojure-named helper for strings and
identifiers. Character literals are not `Named` values in Clojure, and treating
them as strings leaks PTC-Lisp's internal character representation into another
public API.

### GAP-S130: Sequence helpers treat character literals as strings

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `core/count-char-bug-001`, `core/seq-char-bug-001`, `core/first-char-bug-001`, `core/nth-char-bug-001`, `core/vec-char-bug-001`, `core/not-empty-char-bug-001`, `core/map-char-bug-001`, `core/filterv-char-bug-001`, `core/reduce-char-bug-001`, `core/frequencies-char-bug-001`, `core/partition-all-char-bug-001`, `core/cons-char-bug-001`, `core/zipmap-char-keys-bug-001`, `core/zipmap-char-vals-bug-001`, `core/dedupe-char-bug-001`, `core/drop-last-char-bug-001`, `core/drop-while-char-bug-001`, `core/take-while-char-bug-001`, `core/remove-char-bug-001`, `core/not-every-char-bug-001`, `core/rest-char-bug-001`, `core/next-char-bug-001`, `core/last-char-bug-001`, `core/second-char-bug-001`, `core/butlast-char-bug-001`, `core/nthnext-char-bug-001`, `core/nthrest-char-bug-001`, `core/split-at-char-bug-001`, `core/split-with-char-bug-001`, `core/keep-char-bug-001`, `core/keep-indexed-char-bug-001`, `core/every-char-bug-001`, `core/some-char-bug-001`, `core/not-any-char-bug-001` |

```clojure
;; Clojure
(count \a)  ;=> UnsupportedOperationException
(seq \a)    ;=> IllegalArgumentException
(first \a)  ;=> IllegalArgumentException
(nth \a 0)  ;=> UnsupportedOperationException
(vec \a)    ;=> RuntimeException
(not-empty \a)        ;=> IllegalArgumentException
(map identity \a)      ;=> IllegalArgumentException
(filterv identity \a)  ;=> IllegalArgumentException
(reduce str \a)        ;=> IllegalArgumentException
(frequencies \a)       ;=> IllegalArgumentException
(partition-all 1 \a)   ;=> IllegalArgumentException
(cons :x \a)           ;=> IllegalArgumentException
(zipmap \a [1])        ;=> IllegalArgumentException
(zipmap [:a] \b)       ;=> IllegalArgumentException
(dedupe \a)            ;=> IllegalArgumentException
(drop-last 1 \a)       ;=> IllegalArgumentException
(drop-while identity \a) ;=> IllegalArgumentException
(take-while identity \a) ;=> IllegalArgumentException
(remove identity \a)   ;=> IllegalArgumentException
(not-every? identity \a) ;=> IllegalArgumentException
(rest \a)              ;=> IllegalArgumentException
(next \a)              ;=> IllegalArgumentException
(last \a)              ;=> IllegalArgumentException
(second \a)            ;=> IllegalArgumentException
(butlast \a)           ;=> IllegalArgumentException
(nthnext \a 1)         ;=> IllegalArgumentException
(nthrest \a 1)         ;=> IllegalArgumentException
(split-at 1 \a)        ;=> IllegalArgumentException
(split-with identity \a) ;=> IllegalArgumentException
(keep identity \a)     ;=> IllegalArgumentException
(keep-indexed vector \a) ;=> IllegalArgumentException
(every? identity \a)   ;=> IllegalArgumentException
(some identity \a)     ;=> IllegalArgumentException
(not-any? identity \a) ;=> IllegalArgumentException

;; PTC-Lisp current behavior
(count \a)  ;=> 1
(seq \a)    ;=> ["a"]
(first \a)  ;=> "a"
(nth \a 0)  ;=> "a"
(vec \a)    ;=> ["a"]
(not-empty \a)        ;=> "a"
(map identity \a)      ;=> ["a"]
(filterv identity \a)  ;=> ["a"]
(reduce str \a)        ;=> "a"
(frequencies \a)       ;=> {"a" 1}
(partition-all 1 \a)   ;=> [["a"]]
(cons :x \a)           ;=> [:x "a"]
(zipmap \a [1])        ;=> {"a" 1}
(zipmap [:a] \b)       ;=> {:a "b"}
(dedupe \a)            ;=> ["a"]
(drop-last 1 \a)       ;=> []
(drop-while identity \a) ;=> []
(take-while identity \a) ;=> ["a"]
(remove identity \a)   ;=> []
(not-every? identity \a) ;=> false
(rest \a)              ;=> []
(next \a)              ;=> nil
(last \a)              ;=> "a"
(second \a)            ;=> nil
(butlast \a)           ;=> []
(nthnext \a 1)         ;=> nil
(nthrest \a 1)         ;=> []
(split-at 1 \a)        ;=> [["a"] []]
(split-with identity \a) ;=> [["a"] []]
(keep identity \a)     ;=> ["a"]
(keep-indexed vector \a) ;=> [[0 "a"]]
(every? identity \a)   ;=> true
(some identity \a)     ;=> "a"
(not-any? identity \a) ;=> false
```

**Decision:** BUG. These are supported Clojure-named sequence helpers.
Character literals are scalar values in Clojure, not seqable strings. Treating
them as single-character strings turns invalid program structure into plausible
collection data.

### GAP-S132: `pmap` rejects nil/string collections and multiple collections

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/pmap-nil-001`, `core/pmap-string-001`, `core/pmap-multi-coll-001`, `core/pmap-multi-coll-truncate-001`, `regression/gap-s132-pmap-keyword-multi-coll-001` |

```clojure
;; Clojure
(pmap inc nil)          ;=> ()
(pmap str "ab")         ;=> ("a" "b")
(pmap + [1 2] [3 4])    ;=> (4 6)
(pmap :a [{:a 1}] [99]) ;=> (1)

;; PTC-Lisp (fixed)
(pmap inc nil)          ;=> ()
(pmap str "ab")         ;=> ("a" "b")
(pmap + [1 2] [3 4])    ;=> (4 6)
(pmap :a [{:a 1}] [99]) ;=> (1)
```

**Fix:** `pmap` now shares `map`'s finite seqable contract. The `{:pmap, …}`
core node carries a list of collection expressions; each collection is coerced
through `Collection.Normalize.to_seq/1` (nil → `[]`, string → graphemes,
map → `[k v]` pairs) and multiple collections are zipped element-wise,
truncating to the shortest. Bounded parallel safety limits (per-worker heap,
worker budget, shared deadline) are unchanged. The single-collection keyword
accessor guard (`(pmap :k single-map)`) is preserved. A keyword accessor over
multiple collections is kept un-converted so it dispatches as the 2-arg
lookup-with-default (`(pmap :k maps defaults)`) — matching `map` and Clojure —
instead of crashing on the strict arity-1 closure `value_to_erlang_fn` builds.

### GAP-S68: `assoc-in` empty or nil path does not update the nil key

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/assoc-in-empty-path-001`, `core/assoc-in-empty-map-empty-path-001`, `core/assoc-in-nil-path-001` |

```clojure
;; Clojure
(assoc-in {:a 1} [] 2)   ;=> {:a 1, nil 2}
(assoc-in {} [] 1)       ;=> {nil 1}
(assoc-in {:a 1} nil 2)  ;=> {:a 1, nil 2}

;; PTC-Lisp (fixed)
(assoc-in {:a 1} [] 2)   ;=> {:a 1, nil 2}
(assoc-in {} [] 1)       ;=> {nil 1}
(assoc-in {:a 1} nil 2)  ;=> {:a 1, nil 2}
```

**Fix:** `assoc-in`/`update-in` normalize an empty or nil path to the single
nil-key path `[nil]` (in `Runtime.MapOps`), matching Clojure's recursive
definition: `(assoc-in m [] v)` ≡ `(assoc m nil v)`. Shared with `GAP-S55`
(`update-in`).

### GAP-S105: One-arity `assoc` returns the collection instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/assoc-one-arity-001` |

```clojure
;; Clojure
(assoc {})   ;=> ArityException

;; PTC-Lisp (fixed)
(assoc {})   ;=> raises (assoc requires key/value pairs)
```

**Fix:** `assoc_variadic` now requires at least one key/value pair (`pairs != []`
in the map/list/nil guards); a bare `(assoc m)` falls through to the raising
clause. A one-arity call is bad program shape, so it raises rather than silently
returning the unchanged collection (Design Philosophy rule 4).

### GAP-S67: `group-by` rejects string inputs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/group-by-string-bug-001` |

```clojure
;; Clojure
(group-by identity "aba")   ;=> {\\a [\\a \\a], \\b [\\b]}

;; PTC-Lisp current behavior
(group-by identity "aba")   ;=> type_error
```

**Decision:** BUG. `group-by` is a supported Clojure-named finite collection
helper. Adjacent helpers such as `partition-by`, `frequencies`, `zipmap`,
`split-at`, and `map` already treat strings as seqable character collections.

### GAP-S69: Floating division by zero returns infinity

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance case `core/divide-float-zero-bug-001` |

```clojure
;; Clojure
(/ 1.0 0.0)   ;=> ArithmeticException

;; PTC-Lisp current behavior
(/ 1.0 0.0)   ;=> ##Inf
```

**Decision:** BUG. `/` is a supported Clojure-named numeric operation. Integer
division by zero already raises in PTC-Lisp, and floating division by zero is
an invalid program rather than bad external input, so silently returning
infinity hides a numeric error.

### GAP-S70: Collection protocol predicates return true for strings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/counted-string-bug-001`, `core/indexed-string-bug-001`, `core/reversible-string-bug-001` |

```clojure
;; Clojure
(counted? "ab")    ;=> false
(indexed? "ab")    ;=> false
(reversible? "ab") ;=> false

;; PTC-Lisp current behavior
(counted? "ab")    ;=> true
(indexed? "ab")    ;=> true
(reversible? "ab") ;=> true
```

**Decision:** BUG. These are supported Clojure-named predicates. PTC-Lisp may
choose to treat strings as finite seqable values in helpers such as `map`,
`partition-by`, and `split-at`, but protocol predicates should still report the
Clojure-compatible answer unless the audit documents an intentional
divergence.

### GAP-S71: Higher-order helpers reject associative/set callables

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `core/map-map-function-bug-001`, `core/map-vector-function-bug-001`, `core/filter-map-function-bug-001`, `core/some-map-function-bug-001`, `core/some-vector-function-bug-001`, `core/keep-map-function-bug-001`, `core/every-map-function-bug-001`, `core/every-vector-function-bug-001`, `core/not-any-map-function-bug-001`, `core/not-any-vector-function-bug-001`, `core/update-keys-map-function-bug-001`, `core/update-keys-set-function-bug-001`, `core/update-keys-vector-function-bug-001`, `core/update-vals-map-function-bug-001`, `core/update-vals-set-function-bug-001`, `core/update-vals-vector-function-bug-001`, `walk/prewalk-map-function-bug-001`, `walk/prewalk-set-function-bug-001`, `walk/postwalk-map-function-bug-001`, `walk/postwalk-set-function-bug-001`, `walk/walk-map-function-bug-001`, `walk/walk-set-function-bug-001`, `walk/walk-vector-function-bug-001`, `core/comp-map-function-bug-001`, `core/comp-set-function-bug-001`, `core/comp-vector-function-bug-001`, `core/partial-map-function-bug-001`, `core/partial-set-function-bug-001`, `core/partial-vector-function-bug-001`, `core/juxt-map-set-function-bug-001`, `core/juxt-vector-function-bug-001`, `core/complement-map-function-bug-001`, `core/complement-set-function-bug-001`, `core/every-pred-map-function-bug-001`, `core/every-pred-set-function-bug-001`, `core/every-pred-vector-function-bug-001`, `core/some-fn-map-function-bug-001`, `core/some-fn-set-function-bug-001`, `core/some-fn-vector-function-bug-001`, `core/fnil-map-function-bug-001`, `core/fnil-keyword-function-bug-001`, `core/fnil-set-function-bug-001`, `core/fnil-vector-function-bug-001`, `core/partition-by-map-function-bug-001`, `core/partition-by-vector-function-bug-001`, `core/drop-while-map-function-bug-001`, `core/drop-while-vector-function-bug-001`, `core/take-while-map-function-bug-001`, `core/take-while-vector-function-bug-001`, `core/split-with-map-function-bug-001`, `core/split-with-vector-function-bug-001`, `core/map-indexed-map-function-bug-001`, `core/keep-indexed-map-function-bug-001`, `core/keep-vector-function-bug-001`, `core/mapcat-map-function-bug-001`, `core/mapcat-vector-function-bug-001`, `core/filterv-map-function-bug-001`, `core/mapv-map-function-bug-001`, `core/mapv-vector-function-bug-001`, `core/group-by-map-function-bug-001`, `core/group-by-set-function-bug-001`, `core/group-by-vector-function-bug-001`, `core/reduce-map-function-bug-001`, `core/reduce-map-function-singleton-bug-001`, `core/reduce-map-function-init-bug-001`, `core/sort-by-map-function-bug-001`, `core/sort-by-vector-function-bug-001`, `core/max-key-map-function-bug-001`, `core/max-key-vector-function-bug-001`, `core/min-key-map-function-bug-001`, `core/min-key-vector-function-bug-001` |

```clojure
;; Clojure
(map {:a 1 :b 2} [:a :c :b])             ;=> (1 nil 2)
(map [10 20] [0 1])                      ;=> (10 20)
(filter {:a true :b false} [:a :b :c])   ;=> (:a)
(some {:a 1 :b 2} [:c :b :a])            ;=> 2
(some [nil :x] [0 1])                    ;=> :x
(keep {:a 1 :b nil :c false} [:a :b :c]) ;=> (1 false)
(every? {:a true :b true} [:a :b])       ;=> true
(every? [true true] [0 1])               ;=> true
(not-any? {:a true} [:b :c])             ;=> true
(not-any? [nil false] [0 1])             ;=> true
(update-keys {:a 1 :b 2} {:a :x :b :y})  ;=> {:x 1, :y 2}
(update-keys {:a 1 :b 2} #{:a})          ;=> {:a 1, nil 2}
(update-keys {0 :a 1 :b} [:x :y])        ;=> {:x :a, :y :b}
(update-vals {:a :x :b :y} {:x 1 :y 2})  ;=> {:a 1, :b 2}
(update-vals {:a :x :b :z} #{:x})        ;=> {:a :x, :b nil}
(update-vals {:a 0 :b 1} [:x :y])        ;=> {:a :x, :b :y}
(clojure.walk/prewalk {:a :x} [:a :b])   ;=> nil
(clojure.walk/prewalk #{:a} [:a :b])     ;=> nil
(clojure.walk/postwalk {:a :x} [:a :b])  ;=> nil
(clojure.walk/postwalk #{:a} [:a :b])    ;=> nil
(clojure.walk/walk {:a :x} identity [:a :b]) ;=> (:x nil)
(clojure.walk/walk #{:a} identity [:a :b])   ;=> (:a nil)
(clojure.walk/walk [10 20] identity [1])     ;=> (20)
((comp inc {:a 1}) :a)                   ;=> 2
((comp boolean #{:a}) :a)                ;=> true
((comp [10 20]) 1)                       ;=> 20
((partial {:a 1}) :a)                    ;=> 1
((partial #{:a}) :a)                     ;=> :a
((partial [10 20]) 1)                    ;=> 20
((juxt #{:a} {:a 1}) :a)                 ;=> [:a 1]
((juxt [10 20] :a) 1)                    ;=> [20 nil]
((complement {:a true}) :b)              ;=> true
((complement #{:a}) :b)                  ;=> true
((every-pred {:a true} {:a 1}) :a)       ;=> true
((every-pred #{:a}) :a)                  ;=> true
((every-pred [true]) 0)                  ;=> true
((some-fn {:a nil} {:b 2}) :b)           ;=> 2
((some-fn #{:a}) :a)                     ;=> :a
((some-fn [nil :x]) 1)                   ;=> :x
((fnil {:a 1} :x) nil)                   ;=> nil
((fnil :a :x) nil)                       ;=> nil
((fnil #{:a} :x) nil)                    ;=> nil
((fnil [10 20] 0) nil)                   ;=> 10
(partition-by {:a 1 :b 2} [:a :a :b])    ;=> ((:a :a) (:b))
(partition-by [0 1] [0 0 1])             ;=> ((0 0) (1))
(drop-while {:a true :b false} [:a :b :c]) ;=> (:b :c)
(drop-while [true false] [0 1])          ;=> (1)
(take-while {:a true :b false} [:a :b :c]) ;=> (:a)
(take-while [true false] [0 1])          ;=> (0)
(split-with {:a true :b false} [:a :b :c]) ;=> [(:a) (:b :c)]
(split-with [true false] [0 1])          ;=> [(0) (1)]
(map-indexed {0 :z 1 :o} [:a :b])        ;=> (:z :o)
(keep-indexed {0 :z 1 nil 2 false} [:a :b :c]) ;=> (:z false)
(keep [nil :x] [0 1])                    ;=> (:x)
(mapcat {0 [1 2]} [0])                   ;=> (1 2)
(mapcat [[1] [2]] [0 1])                 ;=> (1 2)
(filterv {:a true :b false} [:a :b :c])  ;=> [:a]
(mapv {:a 1 :b 2} [:a :b])               ;=> [1 2]
(mapv [10 20] [0 1])                     ;=> [10 20]
(group-by {:a 1 :b 2} [:a :b :c])        ;=> {1 [:a], 2 [:b], nil [:c]}
(group-by #{:a} [:a :b])                 ;=> {:a [:a], nil [:b]}
(group-by [0 1] [0 1])                   ;=> {0 [0], 1 [1]}
(reduce {:a 1 :b 2} [:a :b])             ;=> 1
(reduce {:a 1 :b 2} [:a])                ;=> :a
(reduce {:a 1 :b 2} nil [:a])            ;=> :a
(sort-by {:a 2 :b 1} [:a :b])            ;=> (:b :a)
(sort-by [2 1] [0 1])                    ;=> (1 0)
(max-key {:a 1 :b 2} :a :b)              ;=> :b
(max-key [1 2] 0 1)                      ;=> 1
(min-key {:a 1 :b 2} :a :b)              ;=> :a
(min-key [1 2] 0 1)                      ;=> 0

;; PTC-Lisp current behavior
(map {:a 1 :b 2} [:a :c :b])             ;=> type_error
(map [10 20] [0 1])                      ;=> type_error
(filter {:a true :b false} [:a :b :c])   ;=> type_error
(some {:a 1 :b 2} [:c :b :a])            ;=> type_error
(some [nil :x] [0 1])                    ;=> type_error
(keep {:a 1 :b nil :c false} [:a :b :c]) ;=> type_error
(every? {:a true :b true} [:a :b])       ;=> type_error
(every? [true true] [0 1])               ;=> type_error
(not-any? {:a true} [:b :c])             ;=> type_error
(not-any? [nil false] [0 1])             ;=> type_error
(update-keys {:a 1 :b 2} {:a :x :b :y})  ;=> type_error
(update-keys {:a 1 :b 2} #{:a})          ;=> type_error
(update-keys {0 :a 1 :b} [:x :y])        ;=> type_error
(update-vals {:a :x :b :y} {:x 1 :y 2})  ;=> type_error
(update-vals {:a :x :b :z} #{:x})        ;=> type_error
(update-vals {:a 0 :b 1} [:x :y])        ;=> type_error
(clojure.walk/prewalk {:a :x} [:a :b])   ;=> type_error
(clojure.walk/prewalk #{:a} [:a :b])     ;=> type_error
(clojure.walk/postwalk {:a :x} [:a :b])  ;=> type_error
(clojure.walk/postwalk #{:a} [:a :b])    ;=> type_error
(clojure.walk/walk {:a :x} identity [:a :b]) ;=> type_error
(clojure.walk/walk #{:a} identity [:a :b])   ;=> type_error
(clojure.walk/walk [10 20] identity [1])     ;=> type_error
((comp inc {:a 1}) :a)                   ;=> runtime_error
((comp boolean #{:a}) :a)                ;=> runtime_error
((comp [10 20]) 1)                       ;=> runtime_error
((partial {:a 1}) :a)                    ;=> runtime_error
((partial #{:a}) :a)                     ;=> runtime_error
((partial [10 20]) 1)                    ;=> runtime_error
((juxt #{:a} {:a 1}) :a)                 ;=> runtime_error
((juxt [10 20] :a) 1)                    ;=> runtime_error
((complement {:a true}) :b)              ;=> runtime_error
((complement #{:a}) :b)                  ;=> runtime_error
((every-pred {:a true} {:a 1}) :a)       ;=> runtime_error
((every-pred #{:a}) :a)                  ;=> runtime_error
((every-pred [true]) 0)                  ;=> runtime_error
((some-fn {:a nil} {:b 2}) :b)           ;=> runtime_error
((some-fn #{:a}) :a)                     ;=> runtime_error
((some-fn [nil :x]) 1)                   ;=> runtime_error
((fnil {:a 1} :x) nil)                   ;=> type_error
((fnil :a :x) nil)                       ;=> type_error
((fnil #{:a} :x) nil)                    ;=> type_error
((fnil [10 20] 0) nil)                   ;=> type_error
(partition-by {:a 1 :b 2} [:a :a :b])    ;=> type_error
(partition-by [0 1] [0 0 1])             ;=> type_error
(drop-while {:a true :b false} [:a :b :c]) ;=> type_error
(drop-while [true false] [0 1])          ;=> type_error
(take-while {:a true :b false} [:a :b :c]) ;=> type_error
(take-while [true false] [0 1])          ;=> type_error
(split-with {:a true :b false} [:a :b :c]) ;=> type_error
(split-with [true false] [0 1])          ;=> type_error
(map-indexed {0 :z 1 :o} [:a :b])        ;=> type_error
(keep-indexed {0 :z 1 nil 2 false} [:a :b :c]) ;=> type_error
(keep [nil :x] [0 1])                    ;=> type_error
(mapcat {0 [1 2]} [0])                   ;=> type_error
(mapcat [[1] [2]] [0 1])                 ;=> type_error
(filterv {:a true :b false} [:a :b :c])  ;=> type_error
(mapv {:a 1 :b 2} [:a :b])               ;=> type_error
(mapv [10 20] [0 1])                     ;=> type_error
(group-by {:a 1 :b 2} [:a :b :c])        ;=> type_error
(group-by #{:a} [:a :b])                 ;=> type_error
(group-by [0 1] [0 1])                   ;=> {nil [0 1]}
(reduce {:a 1 :b 2} [:a :b])             ;=> type_error
(reduce {:a 1 :b 2} [:a])                ;=> type_error
(reduce {:a 1 :b 2} nil [:a])            ;=> type_error
(sort-by {:a 2 :b 1} [:a :b])            ;=> type_error
(sort-by [2 1] [0 1])                    ;=> type_error
(max-key {:a 1 :b 2} :a :b)              ;=> runtime_error
(max-key [1 2] 0 1)                      ;=> runtime_error
(min-key {:a 1 :b 2} :a :b)              ;=> runtime_error
(min-key [1 2] 0 1)                      ;=> runtime_error
```

**Decision:** BUG. PTC-Lisp already supports maps as direct callables for key
lookup, and keywords/sets work in adjacent higher-order positions. Supported
Clojure-named higher-order helpers should accept the same finite invokable
values instead of requiring only function literals or keywords.

### GAP-S81: `flatten` raises for non-sequential roots

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/flatten-scalar-bug-001`, `core/flatten-string-bug-001`, `core/flatten-char-bug-001`, `core/flatten-map-bug-001` |

```clojure
;; Clojure
(flatten 1)          ;=> ()
(flatten "ab")       ;=> ()
(flatten \a)         ;=> ()
(flatten {:a [1 2]}) ;=> ()

;; PTC-Lisp current behavior
(flatten 1)          ;=> type_error
(flatten "ab")       ;=> type_error
(flatten \a)         ;=> type_error
(flatten {:a [1 2]}) ;=> type_error
```

**Decision:** BUG. `flatten` is marked supported, and Clojure returns an empty
sequence for roots that are not sequential collections. PTC-Lisp already tracks
nil input under `GAP-S20`; finite scalar/string/map roots are the same supported
boundary surface and should not raise unless a narrower divergence is documented.

### GAP-S75: `update-keys`/`update-vals` reject vectors

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/update-keys-vector-bug-001`, `core/update-keys-empty-vector-bug-001`, `core/update-vals-vector-bug-001`, `core/update-vals-empty-vector-bug-001` |

```clojure
;; Clojure
(update-keys [10 20] inc) ;=> {1 10, 2 20}
(update-keys [] inc)      ;=> {}
(update-vals [10 20] inc) ;=> [11 21]
(update-vals [] inc)      ;=> []

;; PTC-Lisp current behavior
(update-keys [10 20] inc) ;=> type_error
(update-keys [] inc)      ;=> type_error
(update-vals [10 20] inc) ;=> type_error
(update-vals [] inc)      ;=> type_error
```

**Decision:** BUG. These are supported Clojure-named associative
transformations on finite data. PTC-Lisp already treats vectors as indexed
associative values for adjacent helpers such as `get`, `assoc`, and
the `reduce-kv` behavior tracked under `GAP-S59`.

### GAP-S76: `conj` cannot conjoin a map into a map

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/conj-map-source-bug-001` |

```clojure
;; Clojure
(conj {:a 1} {:b 2})   ;=> {:a 1, :b 2}

;; PTC-Lisp current behavior
(conj {:a 1} {:b 2})   ;=> runtime_error
```

**Decision:** BUG. `conj` is a supported Clojure-named collection helper.
PTC-Lisp already supports conjoining vector map entries into maps; a finite map
source should be treated as a sequence of map entries, matching adjacent `into`
behavior.

### GAP-S137: `conj` treats list pairs as map entries

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/conj-map-list-entry-bug-001` |

```clojure
;; Clojure
(conj {:a 1} (list :b 2))   ;=> ClassCastException

;; PTC-Lisp current behavior
(conj {:a 1} (list :b 2))   ;=> {:a 1, :b 2}
```

**Decision:** BUG. Clojure only accepts actual map entries, maps, or vector
entries for map `conj` inputs. Treating arbitrary two-item lists as entries
silently accepts invalid program structure.

### GAP-S106: Zero-arity `conj` raises instead of returning an empty vector

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/conj-zero-arity-001` |

```clojure
;; Clojure
(conj)   ;=> []   (empty vector, conj's identity)

;; PTC-Lisp (fixed)
(conj)   ;=> []
```

**Fix:** Bound `conj` as a `:variadic` builtin with identity `[]`, so the
zero-arity form returns an empty vector (Clojure's `conj` identity) while every
other arity is unchanged. (The prior gap text said `()`; Clojure's `(conj)` is
actually the empty vector `[]`.)

### GAP-S77: `tree-seq` over string roots recurses until heap limit

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance case `core/tree-seq-string-root-bug-001` |

```clojure
;; Clojure
(tree-seq string? seq "ab")   ;=> ("ab" \a \b)

;; PTC-Lisp current behavior
(tree-seq string? seq "ab")   ;=> memory_exceeded
```

**Decision:** BUG. This is a supported Clojure-named traversal helper on
finite data. PTC-Lisp represents characters as one-character strings, so
`seq` of `"a"` appears to reintroduce `"a"` and `tree-seq` never reaches a
leaf. The implementation needs a finite string/character boundary rather than
relying on the sandbox heap limit.

### GAP-S53: `partition` rejects negative sizes instead of returning empty

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/partition-negative-count-bug-001` |

```clojure
;; Clojure
(partition -1 [1 2 3])   ;=> ()

;; PTC-Lisp current behavior
(partition -1 [1 2 3])   ;=> type error
```

**Decision:** BUG. This is a supported Clojure-named helper on finite input.
Clojure treats the negative partition size as producing no groups. PTC-Lisp
currently rejects it, unlike nearby negative-count helpers such as `nthrest`
and `drop-last` that already match Clojure boundary behavior.

### GAP-S28: Zero-arity `-` returns 0 instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/minus-zero-arity-bug-001` |

```clojure
;; Clojure
(-)   ;=> ArityException

;; PTC-Lisp current behavior
(-)   ;=> 0
```

**Decision:** BUG. Zero-arity subtraction is an invalid program in Clojure.
Returning `0` silently changes a programmer fault into plausible data.

### GAP-S29: Unary `/` returns the argument instead of reciprocal

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance case `core/divide-unary-bug-001` |

```clojure
;; Clojure
(/ 2)   ;=> 1/2

;; PTC-Lisp current behavior
(/ 2)   ;=> 2
```

**Decision:** BUG. This is a Clojure-named arithmetic function on normal finite
numeric input. Returning the argument is silent wrong data.

### GAP-S104: Unary arithmetic returns nonnumeric inputs unchanged

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `core/plus-unary-nonnumeric-bug-001`, `core/plus-unary-keyword-bug-001`, `core/plus-unary-string-bug-001`, `core/multiply-unary-nonnumeric-bug-001`, `core/multiply-unary-keyword-bug-001`, `core/divide-unary-nonnumeric-bug-001` |

```clojure
;; Clojure
(+ [1 2])   ;=> ClassCastException
(+ :a)      ;=> ClassCastException
(+ "a")     ;=> ClassCastException
(* [1 2])   ;=> ClassCastException
(* :a)      ;=> ClassCastException
(/ :a)      ;=> ClassCastException

;; PTC-Lisp current behavior
(+ [1 2])   ;=> [1 2]
(+ :a)      ;=> :a
(+ "a")     ;=> "a"
(* [1 2])   ;=> [1 2]
(* :a)      ;=> :a
(/ :a)      ;=> :a
```

**Decision:** BUG. These are supported Clojure-named arithmetic functions.
Invalid nonnumeric input should not be converted into plausible data by
returning it unchanged.

### GAP-S30: Set helpers reject nil or seqable inputs accepted by Clojure

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/set-nil-bug-001`, `core/set-string-bug-001`, `core/set-map-bug-001`, `set/union-nil-bug-001`, `set/union-second-nil-bug-001`, `set/intersection-nil-bug-001`, `set/intersection-second-nil-bug-001`, `set/difference-nil-bug-001`, `set/difference-second-nil-bug-001`, `set/difference-vector-second-bug-001`, `set/union-vector-bug-001`, `set/union-map-bug-001`, `set/intersection-map-bug-001`, `set/intersection-vector-first-bug-001`, `set/intersection-vector-second-bug-001`, `set/union-list-bug-001`, `set/difference-string-second-bug-001`, `set/difference-map-second-bug-001` |

```clojure
;; Clojure
(set nil)                         ;=> #{}
(set "ab")                        ;=> #{\a \b}
(set {:a 1})                      ;=> #{[:a 1]}
(clojure.set/union nil #{1})       ;=> #{1}
(clojure.set/union #{1} nil)       ;=> #{1}
(clojure.set/intersection nil #{1});=> nil
(clojure.set/intersection #{1 2} nil);=> nil
(clojure.set/difference nil #{1})  ;=> nil
(clojure.set/difference #{1 2} nil) ;=> #{1 2}
(clojure.set/difference #{1 2} [2]) ;=> #{1}
(clojure.set/union [1 2] #{2 3})   ;=> [1 2 3 2]
(clojure.set/union {:a 1} #{[:b 2]}) ;=> {:a 1, :b 2}
(clojure.set/intersection {:a 1} #{[:a 1]}) ;=> {:a 1}
(clojure.set/intersection [1 2] #{2}) ;=> #{}
(clojure.set/intersection #{1 2} [2 3]) ;=> #{1}
(clojure.set/difference #{"a" "b"} "ab") ;=> #{"a" "b"}
(clojure.set/difference #{[:a 1]} {:a 1}) ;=> #{}

;; PTC-Lisp current behavior
(set nil)                         ;=> type_error
(set "ab")                        ;=> type_error
(set {:a 1})                      ;=> type_error
(clojure.set/union nil #{1})       ;=> runtime_error
(clojure.set/union #{1} nil)       ;=> runtime_error
(clojure.set/intersection nil #{1});=> runtime_error
(clojure.set/intersection #{1 2} nil);=> runtime_error
(clojure.set/difference nil #{1})  ;=> runtime_error
(clojure.set/difference #{1 2} nil) ;=> runtime_error
(clojure.set/difference #{1 2} [2]) ;=> runtime_error
(clojure.set/union [1 2] #{2 3})   ;=> runtime_error
(clojure.set/union {:a 1} #{[:b 2]}) ;=> runtime_error
(clojure.set/intersection {:a 1} #{[:a 1]}) ;=> runtime_error
(clojure.set/intersection [1 2] #{2}) ;=> runtime_error
(clojure.set/intersection #{1 2} [2 3]) ;=> runtime_error
(clojure.set/difference #{"a" "b"} "ab") ;=> runtime_error
(clojure.set/difference #{[:a 1]} {:a 1}) ;=> runtime_error
```

**Decision:** BUG. These are supported Clojure-named helpers on bounded finite
inputs. PTC-Lisp already treats nil as empty for many sequence operations, and
strings are seqable elsewhere. Clojure's set helpers are permissive for some
non-set finite collections, so PTC-Lisp should either match or explicitly
document a narrower set-only divergence.

### GAP-S31: `partition` with nil padding raises instead of treating padding as empty

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/partition-nil-pad-bug-001` |

```clojure
;; Clojure
(partition 3 3 nil [1 2])   ;=> ((1 2))

;; PTC-Lisp current behavior
(partition 3 3 nil [1 2])   ;=> protocol Enumerable error
```

**Decision:** BUG. This is the supported finite padding arity of
`clojure.core/partition`. A nil padding collection is treated as empty by
Clojure, yielding the partial final group rather than raising.

### GAP-S32: Negative counts in seq slicing helpers produce non-Clojure slices

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/take-negative-bug-001`, `core/drop-negative-bug-001`, `core/take-last-negative-bug-001`, `core/take-last-string-negative-bug-001` |

```clojure
;; Clojure
(take -1 [1 2])        ;=> ()
(drop -1 [1 2])        ;=> (1 2)
(take-last -1 [1 2])   ;=> nil
(take-last -1 "ab")    ;=> nil

;; PTC-Lisp current behavior
(take -1 [1 2])        ;=> [2]
(drop -1 [1 2])        ;=> [1]
(take-last -1 [1 2])   ;=> []
(take-last -1 "ab")    ;=> []
```

**Decision:** BUG. These are Clojure-named helpers on normal finite data.
PTC-Lisp appears to pass negative counts into Elixir slicing behavior, which
returns plausible but wrong slices instead of Clojure's boundary results.

### GAP-S33: `apply` rejects nil or string final argument sequences

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/apply-plus-nil-bug-001`, `core/apply-vector-nil-bug-001`, `core/apply-str-nil-bug-001`, `core/apply-string-final-bug-001`, `core/apply-str-prefix-string-final-bug-001` |

```clojure
;; Clojure
(apply + nil)       ;=> 0
(apply vector nil)  ;=> []
(apply str nil)     ;=> ""
(apply str "ab")    ;=> "ab"
(apply str "a" "bc");=> "abc"

;; PTC-Lisp current behavior
(apply + nil)       ;=> type_error
(apply vector nil)  ;=> type_error
(apply str nil)     ;=> type_error
(apply str "ab")    ;=> type_error
(apply str "a" "bc");=> type_error
```

**Decision:** BUG. The final `apply` argument is a sequence position, and
Clojure treats nil as empty and strings as seqable there. This is normal finite
data and does not require laziness or host interop.

### GAP-S109: `apply` with nil function position returns nil instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/apply-nil-function-001` |

```clojure
;; Clojure
(apply nil [1])   ;=> NullPointerException

;; PTC-Lisp (fixed)
(apply nil [1])   ;=> raises (nil is not callable)
```

**Fix:** `Eval.Apply.do_apply_fun` now intercepts a `nil` function before the
`is_atom/1` keyword-accessor clause (`nil` is an atom, so it was being treated
as a keyword), returning `{:not_callable, nil}`. Calling nil as a function is
bad program shape and raises (Design Philosophy rule 4). One change closes both
this gap and GAP-S135 — `(nil x)`, `(apply nil ...)`, and `((comp nil) x)` all
flow through this path.

### GAP-S135: `comp` with nil function position returns nil instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/comp-nil-function-001` |

```clojure
;; Clojure
((comp nil) 1)   ;=> NullPointerException

;; PTC-Lisp (fixed)
((comp nil) 1)   ;=> raises (nil is not callable)
```

**Fix:** Same change as GAP-S109 — `Eval.Apply.do_apply_fun` rejects a `nil`
function position as `{:not_callable, nil}` rather than treating it as a keyword
accessor. When the composed function is applied, the `nil` step raises.

### GAP-S34: 2-arity `keyword` namespace/name form is unsupported

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/keyword-two-arity-bug-001` |

```clojure
;; Clojure
(keyword "ns" "a")   ;=> :ns/a

;; PTC-Lisp current behavior
(keyword "ns" "a")   ;=> arity error
```

**Decision:** BUG. The audit marks `keyword` supported, and the namespace/name
arity is a finite pure data coercion with no host or lazy-seq dependency.

### GAP-S78: `keyword` raises on non-ident inputs instead of returning nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/keyword-non-ident-bug-001`, `core/keyword-number-bug-001`, `core/keyword-false-bug-001` |

```clojure
;; Clojure
(keyword true)   ;=> nil
(keyword 1)      ;=> nil
(keyword false)  ;=> nil

;; PTC-Lisp current behavior
(keyword true)   ;=> runtime error
(keyword 1)      ;=> runtime error
(keyword false)  ;=> runtime error
```

**Decision:** BUG. Clojure's `keyword` is total for non-ident values and returns
nil rather than raising. PTC-Lisp already returns nil for `(keyword nil)`, so
returning nil for other unsupported source types would keep the supported
coercion recoverable without expanding the keyword data model.

### GAP-S79: Index/count helpers reject floating numeric arguments Clojure accepts

| Field | Value |
|-------|-------|
| **Priority** | P3 |
| **Status** | open |
| **Source** | Manual conformance cases `core/subs-float-index-bug-001`, `core/subs-float-start-bug-001`, `core/subs-float-end-bug-001`, `core/nth-float-index-bug-001`, `core/subvec-float-start-bug-001`, `core/subvec-float-start-end-bug-001`, `core/subvec-float-truncating-indexes-bug-001`, `core/take-float-count-bug-001`, `core/drop-float-count-bug-001`, `core/split-at-float-count-bug-001`, `core/partition-float-count-bug-001`, `core/partition-float-step-bug-001`, `core/partition-float-step-pad-bug-001`, `core/partition-all-float-count-bug-001`, `core/partition-all-float-step-bug-001`, `core/nthrest-float-count-bug-001`, `core/nthnext-float-count-bug-001` |

```clojure
;; Clojure
(subs "abcd" 1.0 2.0)   ;=> "b"
(subs "abcd" 1.0)       ;=> "bcd"
(subs "abcd" 1 3.0)     ;=> "bc"
(nth [10 20] 1.0)       ;=> 20
(subvec [1 2 3] 1.0)    ;=> [2 3]
(subvec [1 2 3] 1.0 2.0) ;=> [2]
(subvec [1 2 3] 0.9 2.9) ;=> [1 2]
(take 1.0 [10 20])      ;=> (10)
(drop 1.0 [10 20])      ;=> (20)
(split-at 1.0 [1 2])    ;=> [(1) (2)]
(partition 2.0 [1 2 3]) ;=> ()
(partition 2 1.0 [1 2 3]) ;=> ((1 2) (2 3))
(partition 2 1.0 [:x] [1 2 3]) ;=> ((1 2) (2 3) (3 :x))
(partition-all 2.0 [1 2 3]) ;=> ((1 2) (3))
(partition-all 2 1.0 [1 2 3]) ;=> ((1 2) (2 3) (3))
(nthrest [1 2 3] 1.0) ;=> (2 3)
(nthnext [1 2 3] 1.0) ;=> (2 3)

;; PTC-Lisp current behavior
(subs "abcd" 1.0 2.0)   ;=> type_error
(subs "abcd" 1.0)       ;=> type_error
(subs "abcd" 1 3.0)     ;=> type_error
(nth [10 20] 1.0)       ;=> type_error
(subvec [1 2 3] 1.0)    ;=> type_error
(subvec [1 2 3] 1.0 2.0) ;=> type_error
(subvec [1 2 3] 0.9 2.9) ;=> type_error
(take 1.0 [10 20])      ;=> type_error
(drop 1.0 [10 20])      ;=> type_error
(split-at 1.0 [1 2])    ;=> type_error
(partition 2.0 [1 2 3]) ;=> type_error
(partition 2 1.0 [1 2 3]) ;=> type_error
(partition 2 1.0 [:x] [1 2 3]) ;=> type_error
(partition-all 2.0 [1 2 3]) ;=> type_error
(partition-all 2 1.0 [1 2 3]) ;=> type_error
(nthrest [1 2 3] 1.0) ;=> type_error
(nthnext [1 2 3] 1.0) ;=> type_error
```

**Decision:** BUG. These helpers are marked supported, and Clojure accepts
finite numeric index/count arguments by coercing them to Java `int`. PTC-Lisp
can keep its documented signal-value behavior for out-of-range indexes while
still accepting numeric values that Clojure accepts.

### GAP-S80: `clojure.string/last-index-of` mishandles negative from-index

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `string/last-index-of-negative-from-bug-001`, `string/last-index-of-empty-negative-from-bug-001` |

```clojure
;; Clojure
(clojure.string/last-index-of "abc" "a" -1)   ;=> nil
(clojure.string/last-index-of "abc" "" -1)    ;=> nil

;; PTC-Lisp current behavior
(clojure.string/last-index-of "abc" "a" -1)   ;=> 0
(clojure.string/last-index-of "abc" "" -1)    ;=> 0
```

**Decision:** BUG. `clojure.string/last-index-of` is marked supported and
already returns `nil` for ordinary no-match cases. A negative starting position
cannot contain a match and should also return `nil`.

### GAP-S35: `contains?` does not support string indexes

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/contains-string-index-bug-001`, `core/contains-string-float-index-bug-001`, `core/contains-string-out-of-range-bug-001` |

```clojure
;; Clojure
(contains? "abc" 1)   ;=> true
(contains? "abc" 1.0) ;=> true
(contains? "abc" 3)   ;=> false

;; PTC-Lisp current behavior
(contains? "abc" 1)   ;=> type_error
(contains? "abc" 1.0) ;=> type_error
(contains? "abc" 3)   ;=> type_error
```

**Decision:** BUG. This is a Clojure-named predicate on normal finite data.
PTC-Lisp already treats strings as seqable/indexed in adjacent helpers such as
`seqable?` and `nth`.

### GAP-S36: `get`/`get-in` do not support sets

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/get-set-present-bug-001`, `core/get-set-default-bug-001`, `core/get-set-present-nil-bug-001`, `core/get-in-set-present-bug-001`, `core/get-in-set-default-bug-001`, `core/get-in-set-present-nil-bug-001` |

```clojure
;; Clojure
(get #{1 2} 1)     ;=> 1
(get #{1 2} 3 :x)  ;=> :x
(get #{nil} nil :x);=> nil
(get-in #{:a} [:a])            ;=> :a
(get-in #{:a} [:b] :missing)   ;=> :missing
(get-in #{nil} [nil] :missing) ;=> nil

;; PTC-Lisp current behavior
(get #{1 2} 1)     ;=> type_error
(get #{1 2} 3 :x)  ;=> type_error
(get #{nil} nil :x);=> type_error
(get-in #{:a} [:a])            ;=> type_error
(get-in #{:a} [:b] :missing)   ;=> type_error
(get-in #{nil} [nil] :missing) ;=> type_error
```

**Decision:** BUG. Sets are functions of their members elsewhere in PTC-Lisp,
and Clojure's `get`/`get-in` use set membership lookup for finite sets.

### GAP-S37: `case` without a matching clause and without default returns nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/case-no-default-bug-001` |

```clojure
;; Clojure
(case 3 1 :one 2 :two)   ;=> IllegalArgumentException

;; PTC-Lisp current behavior
(case 3 1 :one 2 :two)   ;=> nil
```

**Decision:** BUG. This is an invalid Clojure program at runtime, and silently
returning `nil` can mask missing dispatch cases as valid data.

### GAP-S112: Zero-clause `cond` raises instead of returning nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance case `core/cond-zero-clauses-001` |

```clojure
;; Clojure
(cond)   ;=> nil

;; PTC-Lisp (fixed)
(cond)   ;=> nil
```

**Fix:** Removed the zero-clause error in `Conditionals.analyze_cond`; an empty
`(cond)` now flows through the general path as an empty pair list with a nil
default — the same nil a no-match `cond` yields.

### GAP-S113: Bodyless `when`/`when-not` raise instead of returning nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/when-no-body-001`, `core/when-not-no-body-001` |

```clojure
;; Clojure
(when true)      ;=> nil
(when-not true)  ;=> nil

;; PTC-Lisp (fixed)
(when true)      ;=> nil
(when-not true)  ;=> nil
```

**Fix:** `analyze_when`/`analyze_when_not` now accept zero body expressions, and
a new `wrap_body([])` clause analyzes an empty implicit-do body to nil. So
`(when test)` desugars to `(if test nil nil)` → nil regardless of the test.

### GAP-S114: Bodyless binding/function forms raise instead of returning nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/let-no-body-001`, `core/loop-no-body-001`, `core/fn-no-body-001`, `core/defn-no-body-001`, `core/when-let-no-body-001`, `core/when-some-no-body-001`, `core/when-first-no-body-001` |

```clojure
;; Clojure
(let [x 1])                ;=> nil
(loop [x 1])               ;=> nil
((fn [x]) 1)               ;=> nil
(do (defn f [x]) (f 1))    ;=> nil
(when-let [x 1])           ;=> nil
(when-some [x false])      ;=> nil
(when-first [x [1 2]])     ;=> nil

;; PTC-Lisp (fixed)
(let [x 1])                ;=> nil
(loop [x 1])               ;=> nil
((fn [x]) 1)               ;=> nil
(do (defn f [x]) (f 1))    ;=> nil
(when-let [x 1])           ;=> nil
(when-some [x false])      ;=> nil
(when-first [x [1 2]])     ;=> nil
```

**Fix:** The analyzers for `let`, `loop`, `fn`, `defn`, `when-let`,
`when-some`, and `when-first` now accept zero body expressions (reusing the
`wrap_body([])` → nil clause from GAP-S113). An empty body evaluates to nil
while bindings/params are still established; a missing binding vector or
condition still raises.

### GAP-S123: `cond->` and `cond->>` reject trailing unmatched tests

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/cond-thread-dangling-test-bug-001`, `core/cond-thread-last-dangling-test-bug-001` |

```clojure
;; Clojure
(cond-> 1 true)       ;=> 1
(cond->> [1] false)   ;=> [1]

;; PTC-Lisp current behavior
(cond-> 1 true)       ;=> invalid_thread_form
(cond->> [1] false)   ;=> invalid_thread_form
```

**Decision:** BUG. `cond->` and `cond->>` are supported threading macros.
Clojure partitions test/form pairs and ignores an unmatched trailing test,
leaving the threaded expression unchanged. PTC-Lisp currently rejects the same
finite forms during analysis.

### GAP-S128: Threading through nil returns nil instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P1 |
| **Status** | open |
| **Source** | Manual conformance cases `core/thread-first-nil-form-bug-001`, `core/thread-last-nil-form-bug-001`, `core/some-thread-nil-form-bug-001`, `core/some-thread-last-nil-form-bug-001`, `core/cond-thread-true-nil-form-bug-001`, `core/cond-thread-last-true-nil-form-bug-001` |

```clojure
;; Clojure
(-> 1 nil)   ;=> NullPointerException
(->> 1 nil)  ;=> NullPointerException
(some-> 1 nil)   ;=> NullPointerException
(some->> 1 nil)  ;=> NullPointerException
(cond-> 1 true nil)   ;=> NullPointerException
(cond->> 1 true nil)  ;=> NullPointerException

;; PTC-Lisp current behavior
(-> 1 nil)   ;=> nil
(->> 1 nil)  ;=> nil
(some-> 1 nil)   ;=> nil
(some->> 1 nil)  ;=> nil
(cond-> 1 true nil)   ;=> nil
(cond->> 1 true nil)  ;=> nil
```

**Decision:** BUG. These are supported Clojure-named threading macros. A nil
thread target is invalid program structure once the threaded value reaches that
form; returning nil silently can mask a malformed pipeline as a valid absent
value.

### GAP-S115: `if-let`/`if-some` no-else arity is unsupported

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/if-let-no-else-bug-001`, `core/if-let-no-else-truthy-bug-001`, `core/if-some-no-else-bug-001`, `core/if-some-no-else-nil-bug-001` |

```clojure
;; Clojure
(if-let [x nil] :yes)      ;=> nil
(if-let [x 1] :yes)        ;=> :yes
(if-some [x false] :yes)   ;=> :yes
(if-some [x nil] :yes)     ;=> nil

;; PTC-Lisp current behavior
(if-let [x nil] :yes)      ;=> invalid_arity
(if-let [x 1] :yes)        ;=> invalid_arity
(if-some [x false] :yes)   ;=> invalid_arity
(if-some [x nil] :yes)     ;=> invalid_arity
```

**Decision:** BUG. `if-let` and `if-some` are marked supported, and their
no-else arity is a small finite extension of the already-supported four-form
shape.

### GAP-S145: Binding condition macros reject extra binding-vector forms

| Field | Value |
|-------|-------|
| **Priority** | P3 |
| **Status** | open |
| **Source** | Manual conformance cases `core/if-let-extra-binding-bug-001`, `core/if-some-extra-binding-bug-001`, `core/when-let-extra-binding-bug-001`, `core/when-some-extra-binding-bug-001`, `core/when-first-extra-binding-bug-001` |

```clojure
;; Clojure
(if-let [x 1 y] x :no)       ;=> 1
(if-some [x false y] x :no)  ;=> false
(when-let [x 1 y] x)         ;=> 1
(when-some [x false y] x)    ;=> false
(when-first [x [1] y] x)     ;=> 1

;; PTC-Lisp current behavior
(if-let [x 1 y] x :no)       ;=> invalid_form
(if-some [x false y] x :no)  ;=> invalid_form
(when-let [x 1 y] x)         ;=> invalid_form
(when-some [x false y] x)    ;=> invalid_form
(when-first [x [1] y] x)     ;=> invalid_form
```

**Decision:** BUG. These macros are marked supported. Clojure destructures
their binding vector as a binding form plus test expression and ignores extra
forms after that pair. PTC-Lisp currently requires exactly one pair. This is a
low-priority macro-shape compatibility gap, but it is finite and
Clojure-defined.

### GAP-S72: `case` mishandles duplicate and compound constants

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/case-duplicate-constant-bug-001`, `core/case-vector-constant-bug-001`, `core/case-map-constant-bug-001`, `core/case-set-constant-bug-001`, `core/case-list-constant-bug-001` |

```clojure
;; Clojure
(case "a" "a" 1 "a" 2)       ;=> analysis error, duplicate constant
(case [1 2] [1 2] :ok :no)   ;=> :ok
(case {:a 1} {:a 1} :ok :no) ;=> :ok
(case #{:a} #{:a} :ok :no)   ;=> :ok
(case (quote a) (a b) :ok :no) ;=> :ok

;; PTC-Lisp current behavior
(case "a" "a" 1 "a" 2)       ;=> 1
(case [1 2] [1 2] :ok :no)   ;=> invalid_form
(case {:a 1} {:a 1} :ok :no) ;=> invalid_form
(case #{:a} #{:a} :ok :no)   ;=> invalid_form
(case (quote a) (a b) :ok :no) ;=> invalid_form
```

**Decision:** BUG. `case` is marked supported and these are finite constant
dispatch forms. Accepting duplicate constants silently hides invalid program
structure, while rejecting compound constants excludes valid Clojure case
constants that do not require laziness or host interop.

### GAP-S38: `condp` does not support `:>>` result-function clauses

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/condp-result-fn-bug-001` |

```clojure
;; Clojure
(condp = 2 1 :one 2 :>> (fn [x] [:hit x]) :other) ;=> [:hit true]

;; PTC-Lisp current behavior
(condp = 2 1 :one 2 :>> (fn [x] [:hit x]) :other) ;=> invalid_form
```

**Decision:** BUG. The audit marks `condp` supported, and the `:>>` form is a
finite pure dispatch form. It does not require laziness, macros at runtime, or
host interop.

### GAP-S103: `condp` without a matching clause and without default returns nil

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/condp-no-default-bug-001` |

```clojure
;; Clojure
(condp = 3 1 :one 2 :two) ;=> IllegalArgumentException

;; PTC-Lisp current behavior
(condp = 3 1 :one 2 :two) ;=> nil
```

**Decision:** BUG. `condp` is a supported Clojure-named dispatch helper.
Silently returning nil for an unmatched no-default form masks invalid program
structure and is inconsistent with the corresponding `case` behavior tracked
in `GAP-S37`.

### GAP-S39: Vector destructuring does not support `:as`

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/vector-destructuring-as-bug-001`, `core/fn-vector-destructuring-as-bug-001`, `core/vector-rest-destructuring-as-bug-001` |

```clojure
;; Clojure
(let [[a b :as xs] [1 2 3]] [a b xs])   ;=> [1 2 [1 2 3]]
((fn [[a b :as xs]] xs) [1 2])          ;=> [1 2]
(let [[a & more :as xs] [1 2 3]] [more xs]) ;=> [(2 3) [1 2 3]]

;; PTC-Lisp current behavior
(let [[a b :as xs] [1 2 3]] [a b xs])   ;=> unsupported_pattern
((fn [[a b :as xs]] xs) [1 2])          ;=> unsupported_pattern
(let [[a & more :as xs] [1 2 3]] [more xs]) ;=> invalid_form
```

**Decision:** BUG. Destructuring in `let` is a supported Clojure-named binding
feature, function-parameter destructuring is supported, and the `:as` vector
form is finite pure data binding.

### GAP-S86: Map destructuring does not support `:syms`

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/map-destructuring-syms-bug-001`, `core/fn-map-destructuring-syms-bug-001` |

```clojure
;; Clojure
(let [{:syms [a]} {'a 1}] a)       ;=> 1
((fn [{:syms [a]}] a) {'a 1})      ;=> 1

;; PTC-Lisp current behavior
(let [{:syms [a]} {'a 1}] a)       ;=> unsupported_pattern
((fn [{:syms [a]}] a) {'a 1})      ;=> unsupported_pattern
```

**Decision:** BUG. Map destructuring is already supported for `:keys`,
`:strs`, `:or`, and `:as`; `:syms` is another finite Clojure map
destructuring form over symbol keys. The current failure is a missing pattern
case, not a sandbox or laziness limitation.

### GAP-S118: Map destructuring rejects associative vector sources

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/map-destructuring-vector-source-bug-001`, `core/fn-map-destructuring-vector-source-bug-001`, `core/defn-map-destructuring-vector-source-bug-001` |

```clojure
;; Clojure
(let [{a 0 b 1} [10 20]] [a b])                 ;=> [10 20]
((fn [{a 0 b 1}] [a b]) [10 20])                ;=> [10 20]
(do (defn f [{a 0 b 1}] [a b]) (f [10 20]))     ;=> [10 20]

;; PTC-Lisp current behavior
(let [{a 0 b 1} [10 20]] [a b])                 ;=> invalid_form
((fn [{a 0 b 1}] [a b]) [10 20])                ;=> invalid_form
(do (defn f [{a 0 b 1}] [a b]) (f [10 20]))     ;=> invalid_form
```

**Decision:** BUG. Map destructuring is supported and Clojure implements it
with associative lookup. Vectors are finite associative collections by numeric
index, so numeric source keys should bind from vector inputs instead of being
rejected during pattern analysis.

### GAP-S87: Vector destructuring rejects string inputs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/vector-destructuring-string-bug-001`, `core/vector-rest-destructuring-string-bug-001`, `core/fn-vector-destructuring-string-bug-001`, `core/fn-vector-rest-destructuring-string-bug-001` |

```clojure
;; Clojure
(let [[a b] "xy"] [a b])                    ;=> [\x \y]
(let [[a b & more] "xyz"] [a b more])       ;=> [\x \y (\z)]
((fn [[a b]] [a b]) "xy")                   ;=> [\x \y]
((fn [[a b & more]] [a b more]) "xyz")      ;=> [\x \y (\z)]

;; PTC-Lisp current behavior
(let [[a b] "xy"] [a b])                    ;=> destructure_error
(let [[a b & more] "xyz"] [a b more])       ;=> destructure_error
((fn [[a b]] [a b]) "xy")                   ;=> destructure_error
((fn [[a b & more]] [a b more]) "xyz")      ;=> destructure_error
```

**Decision:** BUG. Vector destructuring in Clojure consumes seqable finite
inputs, including strings. PTC-Lisp already supports strings as finite
collections in several Clojure-named functions, so binding destructuring should
use the same sequence view instead of rejecting strings outright.

### GAP-S97: Vector rest destructuring binds `nil` rest input as an empty vector

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/vector-rest-destructuring-nil-bug-001`, `core/fn-vector-rest-destructuring-nil-bug-001`, `core/vector-only-rest-destructuring-nil-bug-001` |

```clojure
;; Clojure
(let [[a b & more] nil] [a b more])       ;=> [nil nil nil]
((fn [[a b & more]] [a b more]) nil)      ;=> [nil nil nil]
(let [[& more] nil] more)                 ;=> nil

;; PTC-Lisp current behavior
(let [[a b & more] nil] [a b more])       ;=> [nil nil []]
((fn [[a b & more]] [a b more]) nil)      ;=> [nil nil []]
(let [[& more] nil] more)                 ;=> []
```

**Decision:** BUG. Vector destructuring itself is supported for `let` and
function parameters. Clojure treats `nil` as an empty seq for positional
bindings but preserves `nil` for the rest binding. PTC-Lisp currently coerces
the rest binding to an empty vector.

### GAP-S119: Vector rest map destructuring does not coerce key/value rest pairs

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/vector-rest-map-destructuring-bug-001`, `core/fn-vector-rest-map-destructuring-bug-001`, `core/defn-vector-rest-map-destructuring-bug-001` |

```clojure
;; Clojure
(let [[a & {:keys [b]}] [1 :b 2]] [a b])                 ;=> [1 2]
((fn [[a & {:keys [b]}]] [a b]) [1 :b 2])                ;=> [1 2]
(do (defn f [[a & {:keys [b]}]] [a b]) (f [1 :b 2]))     ;=> [1 2]

;; PTC-Lisp current behavior
(let [[a & {:keys [b]}] [1 :b 2]] [a b])                 ;=> destructure_error
((fn [[a & {:keys [b]}]] [a b]) [1 :b 2])                ;=> destructure_error
(do (defn f [[a & {:keys [b]}]] [a b]) (f [1 :b 2]))     ;=> destructure_error
```

**Decision:** BUG. PTC-Lisp already fixed top-level rest keyword-argument
destructuring under `GAP-S07`. The same finite key/value rest-pair coercion is
part of Clojure vector rest map destructuring in `let`, `fn`, and `defn`
parameter patterns.

### GAP-S40: `vec nil` returns nil instead of an empty vector

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/vec-nil-bug-001` |

```clojure
;; Clojure
(vec nil)   ;=> []

;; PTC-Lisp current behavior
(vec nil)   ;=> nil
```

**Decision:** BUG. This is a supported Clojure-named collection coercion on a
normal finite nil input. Adjacent sequence helpers generally treat nil as
empty.

### GAP-S41: `into` lacks Clojure arities and rejects seqable string sources or nil targets

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/into-set-string-bug-001`, `core/into-nil-target-bug-001`, `core/into-zero-arity-bug-001`, `core/into-one-arity-bug-001` |

```clojure
;; Clojure
(into)          ;=> []
(into [])       ;=> []
(into #{} "ab")   ;=> #{\a \b}
(into nil [1 2])  ;=> (2 1)

;; PTC-Lisp current behavior
(into)          ;=> arity_error
(into [])       ;=> arity_error
(into #{} "ab")   ;=> runtime_error
(into nil [1 2])  ;=> type_error
```

**Decision:** BUG. `into` is a supported Clojure-named collection-construction
helper. Its zero- and one-arity forms are finite normal inputs, strings are
seqable in Clojure, and PTC-Lisp already exposes string sequence behavior
through helpers such as `seqable?`, `nth`, and `vec`. Nil target handling is
the corresponding Clojure list-building behavior.

### GAP-S42: `fnil` only supports one default value

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/fnil-two-defaults-bug-001`, `core/fnil-three-defaults-bug-001` |

```clojure
;; Clojure
((fnil + 10 20) nil nil)          ;=> 30
((fnil vector 1 2 3) nil nil nil) ;=> [1 2 3]

;; PTC-Lisp current behavior
((fnil + 10 20) nil nil)          ;=> arity error
((fnil vector 1 2 3) nil nil nil) ;=> arity error
```

**Decision:** BUG. `fnil` is marked supported, and the two- and three-default
forms are finite pure function wrappers in Clojure.

### GAP-S43: `select-keys` does not support vector indexes

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/select-keys-vector-bug-001` |

```clojure
;; Clojure
(select-keys [10 20] [0 1])   ;=> {0 10, 1 20}

;; PTC-Lisp current behavior
(select-keys [10 20] [0 1])   ;=> type_error
```

**Decision:** BUG. This is a Clojure-named helper on normal finite indexed
data. PTC-Lisp already supports vector lookup through `get`, `nth`, and
`assoc`.

### GAP-S44: `char?` returns true for one-character strings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/char-predicate-string-bug-001` |

```clojure
;; Clojure
(char? "a")   ;=> false

;; PTC-Lisp current behavior
(char? "a")   ;=> true
```

**Decision:** BUG. `char?` is marked supported as a Clojure-named predicate.
Clojure strings are not Character values, even when they contain one character.

### GAP-S133: `string?` reports character literals as strings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/string-predicate-char-bug-001` |

```clojure
;; Clojure
(string? \a)   ;=> false

;; PTC-Lisp current behavior
(string? \a)   ;=> true
```

**Decision:** BUG. `string?` is a supported Clojure-named predicate.
Character literals are scalar `Character` values in Clojure, not strings.
PTC-Lisp may represent character literals internally as one-character strings,
but that representation should not leak through type predicates.

### GAP-S120: Character literals compare equal to one-character strings

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/equality-char-string-bug-001`, `core/equality-char-string-multi-bug-001`, `core/not-equality-char-string-bug-001`, `core/numeric-equality-char-string-bug-001`, `core/case-char-string-bug-001` |

```clojure
;; Clojure
(= \a "a")     ;=> false
(= \a "a" \a)  ;=> false
(not= \a "a")  ;=> true
(== \a "a")    ;=> ClassCastException
(case \a "a" :string :char) ;=> :char

;; PTC-Lisp current behavior
(= \a "a")     ;=> true
(= \a "a" \a)  ;=> true
(not= \a "a")  ;=> false
(== \a "a")    ;=> true
(case \a "a" :string :char) ;=> :string
```

**Decision:** BUG. Equality, `not=`, and `==` are supported Clojure-named
predicates. PTC-Lisp may expose string sequence elements as one-character
strings under `DIV-36`, but direct Character-vs-String equality in Clojure keeps
the runtime types distinct. Treating them as equal also leaks into ordinary
finite data comparisons outside string sequence traversal.

### GAP-S125: `seqable?` reports character literals as seqable

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/seqable-char-bug-001` |

```clojure
;; Clojure
(seqable? \a)  ;=> false

;; PTC-Lisp current behavior
(seqable? \a)  ;=> true
```

**Decision:** BUG. `seqable?` is a supported Clojure-named predicate.
PTC-Lisp may expose character literals as strings internally, but the predicate
should still distinguish Clojure Character values from seqable strings at the
API boundary.

### GAP-S45: Zero-step `range` returns empty instead of repeating the start

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/range-zero-step-bug-001` |

```clojure
;; Clojure
(take 3 (range 1 5 0))   ;=> (1 1 1)

;; PTC-Lisp current behavior
(take 3 (range 1 5 0))   ;=> []
```

**Decision:** BUG. PTC-Lisp intentionally excludes unbounded zero-arity
`range` under `DIV-02`, but this is a bounded use of the supported three-arity
`range` combined with `take`. Returning an empty vector silently drops data.

### GAP-S99: `range` with nil or nonnumeric bounds returns empty instead of raising

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/range-nil-end-bug-001`, `core/range-nil-start-bug-001`, `core/range-nil-stop-bug-001`, `core/range-nil-step-bug-001`, `core/range-string-start-bug-001` |

```clojure
;; Clojure
(range nil)       ;=> NullPointerException
(range nil 5)     ;=> NullPointerException
(range 1 nil)     ;=> NullPointerException
(range 1 5 nil)   ;=> NullPointerException
(range "1" 3)     ;=> ClassCastException

;; PTC-Lisp current behavior
(range nil)       ;=> []
(range nil 5)     ;=> []
(range 1 nil)     ;=> []
(range 1 5 nil)   ;=> []
(range "1" 3)     ;=> []
```

**Decision:** BUG. `range` is a supported Clojure-named numeric sequence
helper. Nil or nonnumeric bounds/steps are invalid program inputs; silently
returning an empty vector hides a type error and can make downstream data look
valid.

### GAP-S46: `sort` with nil comparator raises instead of using default compare

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance case `core/sort-nil-comparator-bug-001` |

```clojure
;; Clojure
(sort nil [2 1])   ;=> (1 2)

;; PTC-Lisp current behavior
(sort nil [2 1])   ;=> type_error
```

**Decision:** BUG. This is a supported Clojure-named finite sorting operation.
Clojure treats a nil comparator as the default comparator.

### GAP-S107: `sort`/`sort-by` do not honor boolean comparator functions

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/sort-boolean-comparator-bug-001`, `core/sort-by-boolean-comparator-bug-001` |

```clojure
;; Clojure
(sort (fn [a b] false) [3 1 2])             ;=> (3 1 2)
(sort-by identity (fn [a b] false) [2 1])   ;=> (2 1)

;; PTC-Lisp current behavior
(sort (fn [a b] false) [3 1 2])             ;=> [2 1 3]
(sort-by identity (fn [a b] false) [2 1])   ;=> [1 2]
```

**Decision:** BUG. Boolean comparator functions are valid Clojure comparators
for supported finite `sort` and `sort-by` calls. PTC-Lisp currently appears to
fall back to its default ordering instead of preserving the comparator's
ordering relation.

### GAP-S47: `min-key`/`max-key` return the first tied value

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/min-key-tie-bug-001`, `core/min-key-all-tie-bug-001`, `core/max-key-tie-bug-001`, `core/max-key-all-tie-bug-001` |

```clojure
;; Clojure
(min-key count "a" "bb" "c")   ;=> "c"
(min-key count "a" "b" "c")    ;=> "c"
(max-key count "aa" "bb" "c")  ;=> "bb"
(max-key count "a" "b" "c")    ;=> "c"

;; PTC-Lisp current behavior
(min-key count "a" "bb" "c")   ;=> "a"
(min-key count "a" "b" "c")    ;=> "a"
(max-key count "aa" "bb" "c")  ;=> "aa"
(max-key count "a" "b" "c")    ;=> "a"
```

**Decision:** BUG. `min-key` and `max-key` are marked supported and these are
finite Clojure-named reductions. Clojure returns the later value when key
results tie for the selected extremum.

### GAP-S48: Some sequence boundary helpers mishandle nil input

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | **fixed** |
| **Source** | Manual conformance cases `core/last-nil-001`, `core/butlast-nil-001`, `core/butlast-empty-001`, `core/butlast-singleton-001`, `core/butlast-empty-string-001`, `core/butlast-singleton-string-001`, `core/take-last-nil-001`, `core/take-last-empty-001`, `core/ffirst-nil-001`, `core/fnext-nil-001`, `core/nfirst-nil-001`, `core/nnext-nil-001` |

```clojure
;; Clojure
(last nil)        ;=> nil
(butlast [1])     ;=> nil
(take-last 2 nil) ;=> nil
(take-last 2 [])  ;=> nil
(ffirst nil)      ;=> nil

;; PTC-Lisp (fixed)
(last nil)        ;=> nil
(butlast [1])     ;=> nil
(take-last 2 nil) ;=> nil
(take-last 2 [])  ;=> nil
(ffirst nil)      ;=> nil
```

**Decision:** BUG. These are supported Clojure-named sequence helpers on nil
input. Adjacent helpers such as `first`, `rest`, `next`, and `second` already
match Clojure's nil behavior.

**Fix:** Added nil clauses (`last`/`ffirst`/`fnext`/`nfirst`/`nnext` on nil =>
nil, `butlast nil` => nil), and both `butlast` and `take-last` now return nil
for any empty result (nil input, or an empty/too-short collection) via Clojure's
empty-seq punning. Non-positive `take-last` counts still return `[]`
([GAP-S32](#gap-s32-negative-counts-in-seq-slicing-helpers-produce-non-clojure-slices),
tracked separately).

### GAP-S49: `mapcat` misses multi-collection and string-result behavior

| Field | Value |
|-------|-------|
| **Priority** | P2 |
| **Status** | open |
| **Source** | Manual conformance cases `core/mapcat-two-colls-bug-001`, `core/mapcat-string-result-bug-001`, `core/mapcat-nil-result-bug-001` |

```clojure
;; Clojure
(mapcat vector [1 2] [:a :b])   ;=> (1 :a 2 :b)
(mapcat identity ["ab" "c"])    ;=> (\a \b \c)
(mapcat (fn [x] nil) [1 2])     ;=> ()

;; PTC-Lisp current behavior
(mapcat vector [1 2] [:a :b])   ;=> arity error
(mapcat identity ["ab" "c"])    ;=> runtime_error
(mapcat (fn [x] nil) [1 2])     ;=> runtime_error
```

**Decision:** BUG. `mapcat` is marked supported. These are finite
Clojure-named sequence operations, and PTC-Lisp already treats strings as
seqable for adjacent helpers such as `map` and `vec`. Nil mapping results are
also finite empty sequence positions in Clojure.

### DIV-25: `list` is an alias for `vector`

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/conj-list-001`, `div/conj-nil-multiple-001`, `div/pop-list-001`, `div/peek-list-001`, `div/vector-predicate-list-001`, `div/list-predicate-list-001`, `div/list-predicate-vector-001` |

```clojure
;; Clojure
(list 1 2 3)       ;=> (1 2 3)   ; a persistent list
(list? (list 1))   ;=> true
(conj nil :a :b)   ;=> (:b :a)
(pop (list 1 2 3)) ;=> (2 3)
(peek (list 1 2))  ;=> 1
(vector? (list 1)) ;=> false
(list? [1 2])      ;=> false

;; PTC-Lisp
(list 1 2 3)       ;=> [1 2 3]   ; a vector
(vector? (list 1)) ;=> true
(list? (list 1))   ;=> unbound
(list? [1 2])      ;=> unbound
(conj nil :a :b)   ;=> [:a :b]
(pop (list 1 2 3)) ;=> [1 2]
(peek (list 1 2))  ;=> 2
```

PTC-Lisp has no separate list type — it is vector-first. `list` is provided
because LLMs reach for it out of Clojure training data; it returns a vector so
downstream code behaves uniformly. `list?` and `list*` are not provided.

**Rationale:** Eliminates a common LLM error class (`list`/`cons` reflexes) at
near-zero cost, without introducing a second sequential collection type.

### DIV-26: Collection boundary helpers return signal values instead of raising

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `core/nth-oob-div-001`, `core/nth-negative-div-001`, `div/subvec-oob-001`, `div/subvec-negative-start-001`, `div/pop-empty-001` |

```clojure
;; Clojure
(nth [1 2] 5)          ;=> IndexOutOfBoundsException
(nth [1 2] -1)         ;=> IndexOutOfBoundsException
(subvec [1 2 3] 0 9)   ;=> IndexOutOfBoundsException
(subvec [1 2 3] -1)    ;=> IndexOutOfBoundsException
(pop [])               ;=> IllegalStateException

;; PTC-Lisp
(nth [1 2] 5)          ;=> nil
(nth [1 2] -1)         ;=> nil
(subvec [1 2 3] 0 9)   ;=> [1 2 3]
(subvec [1 2 3] -1)    ;=> [1 2 3]
(pop [])               ;=> nil
```

**Rationale:** These Clojure-named helpers commonly receive indices or
collections derived from external data. PTC-Lisp returns recoverable signal
values or clamps bounded slices so generated programs can continue.

### DIV-27: `contains?` uses membership semantics for sequential collections

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/contains-vector-membership-001`, `div/contains-vector-index-present-value-absent-001`, `div/contains-map-entry-index-present-001`, `div/contains-map-entry-key-member-001` |

```clojure
;; Clojure: vectors are associative by index
(contains? [1 2] 1)   ;=> true
(contains? [1 2] 2)   ;=> false
(contains? [10 20] 1) ;=> true
(contains? (first (seq {:a 1})) 0)  ;=> true
(contains? (first (seq {:a 1})) :a) ;=> false

;; PTC-Lisp: vectors/lists use membership semantics
(contains? [1 2] 1)   ;=> true
(contains? [1 2] 2)   ;=> true
(contains? [10 20] 1) ;=> false
(contains? (first (seq {:a 1})) 0)  ;=> false
(contains? (first (seq {:a 1})) :a) ;=> true
```

**Rationale:** PTC-Lisp intentionally documents `contains?` as "key/element
exists" for maps, sets, lists, and map-entry views. This favors the membership
test LLMs usually intend; Clojure's vector/map-entry index interpretation is
surprising in data pipelines.

### DIV-28: `type` returns PTC type keywords instead of host classes

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance case `div/type-keyword-001` |

```clojure
;; Clojure
(type 1)   ;=> java.lang.Long

;; PTC-Lisp
(type 1)   ;=> :number
```

**Rationale:** PTC-Lisp does not expose the host JVM class model. Returning a
small stable keyword vocabulary (`:number`, `:string`, `:map`, etc.) is the
documented behavior and avoids leaking implementation details into sandboxed
programs.

### DIV-29: Direct positional sequence operations reject maps

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/first-map-direct-001`, `div/rest-map-direct-001`, `div/second-map-direct-001`, `div/last-map-direct-001`, `div/next-map-direct-001`, `div/reverse-map-direct-001`, `div/interpose-map-direct-001`, `div/interleave-map-direct-001` |

```clojure
;; Clojure
(first {:a 1})        ;=> [:a 1]
(rest {:a 1 :b 2})    ;=> sequence of map entries
(second {:a 1 :b 2})  ;=> a map entry
(last {:a 1})         ;=> [:a 1]
(next {:a 1})         ;=> nil
(reverse {:a 1 :b 2}) ;=> sequence of map entries
(interpose :x {:a 1 :b 2}) ;=> sequence of map entries separated by :x
(interleave {:a 1} [:x]) ;=> sequence of map entry then :x

;; PTC-Lisp
(first {:a 1})        ;=> type_error
(rest {:a 1 :b 2})    ;=> type_error
(second {:a 1 :b 2})  ;=> type_error
(last {:a 1})         ;=> type_error
(next {:a 1})         ;=> type_error
(reverse {:a 1 :b 2}) ;=> type_error
(interpose :x {:a 1 :b 2}) ;=> type_error
(interleave {:a 1} [:x]) ;=> type_error
(first (seq {:a 1}))  ;=> [:a 1]
```

**Rationale:** PTC-Lisp keeps direct positional operations away from unordered
maps and points callers toward explicit ordered views: `seq`, `entries`,
`keys`, or `vals`. This avoids accidental dependence on host map iteration
order while preserving an explicit escape hatch.

### DIV-30: Ordering uses PTC's recoverable total term ordering

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/lt-mixed-scalar-001`, `div/lt-string-scalar-001`, `div/lte-char-scalar-001`, `div/gt-string-scalar-001`, `div/gte-char-scalar-001`, `div/sort-mixed-scalar-001`, `div/sort-nil-001`, `div/sort-by-nil-key-001`, `div/compare-nil-001`, `div/compare-map-001`, `div/compare-string-keyword-001`, `div/compare-string-number-001`, `div/max-nil-001`, `div/min-nil-001`, `div/max-string-number-001`, `div/min-string-number-001`, `div/min-boolean-001`, `div/max-keyword-001`, `div/min-key-boolean-001`, `div/max-key-keyword-001`, `div/max-key-nil-key-001`, `div/min-key-nil-key-001` |

```clojure
;; Clojure
(< "a" 1)       ;=> ClassCastException
(< "a" "b")     ;=> ClassCastException
(<= \a \a)      ;=> ClassCastException
(> "b" "a")     ;=> ClassCastException
(>= \b \a)      ;=> ClassCastException
(sort [1 "a"])  ;=> ClassCastException
(sort [1 nil])  ;=> (nil 1)
(sort-by :a [{:a nil} {:a 1}]) ;=> ({:a nil} {:a 1})
(compare nil 1) ;=> -1
(compare {:a 1} {:a 2}) ;=> ClassCastException
(compare "a" :a) ;=> ClassCastException
(compare "a" 1) ;=> ClassCastException
(max nil 1)     ;=> NullPointerException
(min nil 1)     ;=> NullPointerException
(max "a" 1)     ;=> ClassCastException
(min "a" 1)     ;=> ClassCastException
(min true false) ;=> ClassCastException
(max :a :b)      ;=> ClassCastException
(min-key identity true false) ;=> ClassCastException
(max-key identity :a :b) ;=> ClassCastException
(max-key :a {:a nil} {:a 1}) ;=> NullPointerException
(min-key :a {:a nil} {:a 1}) ;=> NullPointerException

;; PTC-Lisp
(< "a" 1)       ;=> false
(< "a" "b")     ;=> true
(<= \a \a)      ;=> true
(> "b" "a")     ;=> true
(>= \b \a)      ;=> true
(sort [1 "a"])  ;=> [1 "a"]
(sort [1 nil])  ;=> [1 nil]
(sort-by :a [{:a nil} {:a 1}]) ;=> [{:a 1} {:a nil}]
(compare nil 1) ;=> 1
(compare {:a 1} {:a 2}) ;=> -1
(compare "a" :a) ;=> 1
(compare "a" 1) ;=> 1
(max nil 1)     ;=> nil
(min nil 1)     ;=> 1
(max "a" 1)     ;=> "a"
(min "a" 1)     ;=> 1
(min true false) ;=> false
(max :a :b)      ;=> :b
(min-key identity true false) ;=> false
(max-key identity :a :b) ;=> :b
(max-key :a {:a nil} {:a 1}) ;=> {:a nil}
(min-key :a {:a nil} {:a 1}) ;=> {:a 1}
```

**Rationale:** PTC-Lisp documents ordering comparisons as recoverable
predicates over nil, maps, and mixed values, using the runtime's total term
ordering for deterministic data pipelines. Clojure's exception behavior is less
useful in a sandbox without `try`/`catch`.

### DIV-31: Numeric predicates return false for nil and non-numeric inputs

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/zero-predicate-nil-001`, `div/pos-predicate-nil-001`, `div/even-predicate-nil-001`, `div/odd-predicate-nil-001`, `div/even-predicate-char-001`, `div/odd-predicate-char-001`, `div/neg-predicate-string-001`, `div/zero-predicate-numeric-string-001`, `div/pos-predicate-numeric-string-001`, `div/neg-predicate-numeric-string-001`, `div/infinite-predicate-nil-001`, `div/nan-predicate-nil-001`, `div/infinite-predicate-string-001`, `div/nan-predicate-string-001` |

```clojure
;; Clojure
(zero? nil)   ;=> NullPointerException
(pos? nil)    ;=> NullPointerException
(even? nil)   ;=> IllegalArgumentException
(odd? nil)    ;=> IllegalArgumentException
(even? \a)    ;=> IllegalArgumentException
(odd? \a)     ;=> IllegalArgumentException
(neg? "x")    ;=> ClassCastException
(zero? "0")   ;=> ClassCastException
(pos? "1")    ;=> ClassCastException
(neg? "-1")   ;=> ClassCastException
(infinite? nil) ;=> NullPointerException
(NaN? nil)      ;=> NullPointerException
(infinite? "x") ;=> ClassCastException
(NaN? "x")      ;=> ClassCastException

;; PTC-Lisp
(zero? nil)   ;=> false
(pos? nil)    ;=> false
(even? nil)   ;=> false
(odd? nil)    ;=> false
(even? \a)    ;=> false
(odd? \a)     ;=> false
(neg? "x")    ;=> false
(zero? "0")   ;=> false
(pos? "1")    ;=> false
(neg? "-1")   ;=> false
(infinite? nil) ;=> false
(NaN? nil)      ;=> false
(infinite? "x") ;=> false
(NaN? "x")      ;=> false
```

**Rationale:** These Clojure-named helpers are commonly used as predicates in
data pipelines. Returning `false` for non-matching input is recoverable and
consistent with PTC's no-exception predicate policy.

### DIV-32: Equality is numeric type-independent

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/equality-int-float-001`, `div/not-equality-int-float-001`, `div/case-numeric-equality-001` |

```clojure
;; Clojure
(= 1 1.0)    ;=> false
(not= 1 1.0) ;=> true
(== 1 1.0)   ;=> true
(case 1.0 1 :one :other) ;=> :other

;; PTC-Lisp
(= 1 1.0)    ;=> true
(not= 1 1.0) ;=> false
(== 1 1.0)   ;=> true
(case 1.0 1 :one :other) ;=> :one
```

**Rationale:** PTC-Lisp intentionally uses type-independent numeric equality
for data transformation, where JSON and tool inputs may erase integer-vs-float
distinctions.

### DIV-33: `compare` treats NaN as unordered

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/compare-nan-001`, `div/compare-nan-self-001` |

```clojure
;; Clojure
(compare ##NaN 1)   ;=> 0
(compare ##NaN ##NaN) ;=> 0

;; PTC-Lisp
(compare ##NaN 1)   ;=> type_error
(compare ##NaN ##NaN) ;=> type_error
```

**Rationale:** PTC-Lisp follows IEEE-style unordered NaN semantics for numeric
comparisons. Returning `0` would incorrectly imply equality.

### DIV-38: Map sequence views are sorted by key

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/seq-map-sorted-001`, `div/keys-map-sorted-001`, `div/vals-map-sorted-001` |

```clojure
;; Clojure
(seq {:b 2 :a 1})  ;=> ([:b 2] [:a 1])
(keys {:b 2 :a 1}) ;=> (:b :a)
(vals {:b 2 :a 1}) ;=> (2 1)

;; PTC-Lisp
(seq {:b 2 :a 1})  ;=> [[:a 1] [:b 2]]
(keys {:b 2 :a 1}) ;=> [:a :b]
(vals {:b 2 :a 1}) ;=> [1 2]
```

**Rationale:** PTC-Lisp treats maps as unordered and exposes deterministic
ordered views by sorting entries by key. This avoids accidental dependence on
host map iteration order and matches the explicit map-view guidance in the
PTC-Lisp specification.

### DIV-39: Readable collection rendering is deterministic and space-separated

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/pr-str-map-rendering-001`, `div/pr-str-nested-map-rendering-001`, `div/format-map-rendering-001` |

```clojure
;; Clojure
(pr-str {:b 2 :a 1})           ;=> "{:b 2, :a 1}"
(pr-str {:a {:b 2 :c 3}})      ;=> "{:a {:b 2, :c 3}}"
(format "%s" {:b 2 :a 1})      ;=> "{:b 2, :a 1}"

;; PTC-Lisp
(pr-str {:b 2 :a 1})           ;=> "{:a 1 :b 2}"
(pr-str {:a {:b 2 :c 3}})      ;=> "{:a {:b 2 :c 3}}"
(format "%s" {:b 2 :a 1})      ;=> "{:a 1 :b 2}"
```

**Rationale:** PTC-Lisp treats maps as unordered data and renders them in a
stable key-sorted order. It also follows its own reader/formatter convention
that commas are optional and output is space-separated. This keeps printed data
stable for agent feedback and aligns with the PTC-Lisp specification's readable
representation, even though Clojure's `pr-str` includes commas and preserves
the host map iteration order.

### DIV-37: Integer operations and predicates use arbitrary-precision semantics

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Manual conformance cases `div/quot-long-min-overflow-001`, `div/abs-long-min-overflow-001`, `div/int-predicate-bigint-001`, `div/pos-int-predicate-bigint-001`, `div/neg-int-predicate-bigint-001`, `div/nat-int-predicate-bigint-001` |

```clojure
;; Clojure
(quot -9223372036854775808 -1) ;=> -9223372036854775808
(abs -9223372036854775808)     ;=> -9223372036854775808
(int? 922337203685477580812345) ;=> false
(pos-int? 922337203685477580812345) ;=> false
(neg-int? -922337203685477580812345) ;=> false
(nat-int? 922337203685477580812345) ;=> false

;; PTC-Lisp
(quot -9223372036854775808 -1) ;=> 9223372036854775808
(abs -9223372036854775808)     ;=> 9223372036854775808
(int? 922337203685477580812345) ;=> true
(pos-int? 922337203685477580812345) ;=> true
(neg-int? -922337203685477580812345) ;=> true
(nat-int? 922337203685477580812345) ;=> true
```

**Rationale:** PTC-Lisp has arbitrary-precision integers and no distinct JVM
`int`/`long` width. Clojure preserves Java `long` overflow edges for the
`Long/MIN_VALUE` literal and reports arbitrary-precision integer literals as
not satisfying the fixed-width `int?` family predicates. PTC-Lisp follows its
documented integer model instead.

---

## Adding New Gaps

When conformance testing reveals a new gap:

1. Classify it: Semantics (S), Special Form (F), Core Function (C), or Intentional Divergence (DIV)
2. Assign the next number in that category (e.g., GAP-S04)
3. Set priority: P0 if it causes silent wrong results, P1 if it errors where Clojure succeeds, P2 if edge case
4. Include a minimal reproducer with both Clojure and PTC-Lisp output
5. Note the source (SCI test name + line, Joker test, manual, etc.)
6. For `DIV-*` entries, apply the design policy from the [PTC-Lisp Specification](ptc-lisp-specification.md) — state why Clojure conformance loses to sandbox safety, bounded execution, or recoverable signal values
