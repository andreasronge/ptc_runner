# Clojure Conformance Gaps

Tracked differences between PTC-Lisp and Clojure semantics, discovered via conformance testing against SCI, Babashka, Joker, and manual investigation.

**Test file:** `test/ptc_runner/lisp/sci_conformance_test.exs`
**Related issue:** [#832](https://github.com/andreasronge/ptc_runner/issues/832)
**Audit (function coverage):** `docs/clojure-core-audit.md`
**Function reference:** `docs/function-reference.md`

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

`:foo/bar` style namespaced keywords are not supported. Only simple keywords like `:name`, `:user-id`.

**Rationale:** Simplicity. No user-defined namespaces means namespace-qualified keywords have no use.

### DIV-14: `if-let`/`when-let` only support single symbol bindings

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

```clojure
;; Clojure: supports destructuring
(if-let [{:keys [a]} (get-map)] a nil)

;; PTC-Lisp: only single symbol
(if-let [x (get-map)] (:a x) nil)
```

**Rationale:** Simplicity. Destructuring in `let` covers this need.

### DIV-15: No multi-arity `defn`

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

```clojure
;; Clojure
(defn f ([x] x) ([x y] (+ x y)))

;; PTC-Lisp: not supported — use separate defn forms or rest args
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

### DIV-18: `parse-long`/`parse-double` return `nil` for non-string input

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |
| **Source** | Spec §8.9 |

```clojure
;; Clojure 1.11+
(parse-long 42)   ;=> IllegalArgumentException

;; PTC-Lisp
(parse-long 42)   ;=> nil
```

**Rationale:** No exception handling (DIV-10). Returning `nil` is safer for LLM-generated code.

### DIV-19: `symbol?` always returns false

| Field | Value |
|-------|-------|
| **Priority** | n/a |
| **Status** | by design |

```clojure
;; Clojure
(symbol? 'foo)   ;=> true

;; PTC-Lisp
(symbol? :foo)   ;=> false (always false)
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
(decimal? 1.0)    ;=> false (always false)
(ratio? 1)        ;=> false (always false)
(rational? 42)    ;=> true  (integers only, no ratios on BEAM)
```

BEAM has no BigDecimal or ratio types. `rational?` returns true only for integers (the only BEAM rationals).

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

---

## Adding New Gaps

When conformance testing reveals a new gap:

1. Classify it: Semantics (S), Special Form (F), Core Function (C), or Intentional Divergence (DIV)
2. Assign the next number in that category (e.g., GAP-S04)
3. Set priority: P0 if it causes silent wrong results, P1 if it errors where Clojure succeeds, P2 if edge case
4. Include a minimal reproducer with both Clojure and PTC-Lisp output
5. Note the source (SCI test name + line, Joker test, manual, etc.)
