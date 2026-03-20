# SCI Test Coverage Tracking

Systematic tracking of every `deftest` in the SCI test suite against PTC-Lisp.

**Source:** https://github.com/borkdude/sci (`test/sci/core_test.cljc`)

## Status Key

| Status | Meaning |
|--------|---------|
| `ported` | Converted to ExUnit and running in `sci_conformance_test.exs` |
| `partial` | Some assertions ported, others skipped |
| `todo` | Relevant to PTC-Lisp, not yet ported |
| `n/a` | Not applicable — with reason code |

### N/A Reason Codes

| Code | Feature | Related Divergence |
|------|---------|-------------------|
| `macros` | defmacro, macroexpand, syntax-quote | DIV-04 |
| `mutable` | atom, swap!, reset!, volatile!, deref | DIV-05 |
| `namespaces` | ns, require, resolve, intern, ns-resolve | Not supported |
| `try-catch` | try, catch, throw, finally | Not supported |
| `metadata` | meta, with-meta, alter-meta! | Not supported |
| `protocols` | defprotocol, defrecord, deftype, instance? | Not supported |
| `java-interop` | Java classes, type hints, arrays | Not supported |
| `sci-api` | SCI-specific APIs (sci/init, sci/eval-string, etc.) | Not applicable |
| `permissions` | SCI allow/deny permission system | Not applicable |
| `reader` | Reader conditionals, tagged literals, data readers | Not supported |
| `lazy` | lazy-seq, delay, trampoline | DIV-02 |
| `quoting` | quote, syntax-quote, unquote | Not supported |
| `multi-arity-fn` | Multi-arity fn definitions `(fn ([x] ...) ([x y] ...))` | Not supported |
| `letfn` | letfn (mutual recursion) | Not supported |
| `dynamic` | Dynamic vars, binding | Not supported |
| `eval` | eval, read-string, load-string | DIV-04 |

---

## `core_test.cljc` — Deftest Tracking

| Line | Deftest | Status | Notes |
|------|---------|--------|-------|
| 48 | `core-test` | partial | `do`, `if`/`when`, `and`/`or`, `fn` literals, `map`, `keep`, calling IFns, duplicate keys ported. Skipped: `as->` (not supported), `some->` (not supported), quoting, EvalFn |
| 131 | `destructure-test` | partial | `:keys`, `:or`, `:strs` ported. Skipped: symbol destructuring `{foo-val k}`, `:person/keys` (namespaced keys), `:syms` |
| 155 | `rand-test` | n/a | `rand`, `rand-int`, `rand-nth`, `random-sample` not supported |
| 162 | `let-test` | ported | Dependent bindings, map destructuring, multiple body, nested shadowing |
| 185 | `closure-test` | ported | Closure capture, nested closures. GAP-S03: defn-in-let scoping fails |
| 191 | `fn-literal-test` | ported | `#(do %)`, `map-indexed #()`, `%&` rest args all ported. `%&` fails (GAP-C03) |
| 199 | `fn-test` | partial | Recursive named fn, rest args, destructuring ported (all fail — GAP-F01). Skipped: multi-arity fn |
| 220 | `pre-post-conditions-test` | n/a | Pre/post conditions `:pre`/`:post` not supported |
| 229 | `def-test` | partial | Basic def, redefinition ported. Skipped: unbound vars, try+def, metadata on def, namespace-qualified def |
| 245 | `def-location-test` | n/a | macros |
| 260 | `defn-test` | partial | Basic defn, redefinition ported. Skipped: multi-arity defn, metadata, docstring introspection |
| 299 | `source-fn-test` | n/a | `clojure.repl/source-fn` not supported |
| 303 | `defn-kwargs-test` | ported | Keyword args via rest destructuring — fails (GAP-S07) |
| 307 | `resolve-test` | n/a | namespaces, resolve |
| 352 | `type-hint-let-test` | n/a | java-interop |
| 365 | `type-hint-let-pops-after-nest-test` | n/a | java-interop |
| 384 | `type-hint-shadowed-def-test` | n/a | java-interop |
| 397 | `type-hint-catch-test` | n/a | java-interop |
| 411 | `type-hint-letfn-test` | n/a | java-interop |
| 424 | `type-hint-fn-test` | n/a | java-interop |
| 436 | `ns-resolve-test` | n/a | namespaces |
| 439 | `top-level-test` | ported | `nil` as last expression. Skipped: side-effect ordering (uses println binding) |
| 452 | `macroexpand-test` | n/a | macros |
| 466 | `permission-test` | n/a | sci-api, permissions |
| 532 | `idempotent-eval-test` | partial | Map identity ported. Skipped: `symbol` (not supported), `list` (not supported) |
| 540 | `error-location-test` | n/a | sci-api (error location metadata) |
| 576 | `disable-arity-checks-test` | n/a | sci-api |
| 582 | `macro-test` | n/a | macros |
| 632 | `comment-test` | ported | All assertions ported — all fail (GAP-C02: `comment` not supported) |
| 638 | `GH-54-recursive-function-test` | n/a | mutable (uses atom/swap!) |
| 649 | `trampoline-test` | n/a | lazy (`trampoline` not supported) |
| 667 | `recur-test` | partial | Basic defn recur + variadic recur ported. Skipped: tail-position validation, letfn+recur |
| 761 | `loop-test` | ported | Destructuring, conj accumulation, shadowed bindings |
| 800 | `for-test` | ported | `:while`, `:when`, nested destructuring |
| 822 | `doseq-test` | n/a | mutable (uses println binding, with-out-str) |
| 832 | `cond-test` | partial | Basic cond, `:else` ported. `int?` missing (GAP-C01). Skipped: odd-arg error |
| 842 | `condp-test` | n/a | `condp` not supported |
| 850 | `regex-test` | ported | `re-find` with regex literal |
| 853 | `case-test` | n/a | `case` not supported (only `cond`) |
| 900 | `variable-can-have-macro-or-var-name` | ported | 3 tests: `merge`, cross-defn, `fn` shadowing. `fn` shadow fails (GAP-S06) |
| 906 | `throw-test` | n/a | try-catch |
| 911 | `try-catch-finally-throw-test` | n/a | try-catch |
| 956 | `syntax-quote-test` | n/a | quoting, macros |
| 1004 | `defmacro-test` | n/a | macros |
| 1022 | `declare-test` | n/a | `declare`, dynamic vars, metadata |
| 1036 | `reader-conditionals` | n/a | reader |
| 1040 | `add-to-clojure-core-test` | n/a | sci-api |
| 1043 | `try-catch-test` | n/a | try-catch |
| 1056 | `recursion-test` | ported | Named fn recursion — fails (GAP-F01) |
| 1061 | `syntax-errors` | ported | 6 assertions: namespace-qualified def/defn, too many args, missing params, parens vs vector |
| 1078 | `ex-message-test` | n/a | try-catch |
| 1082 | `assert-test` | n/a | `assert` not supported |
| 1100 | `dotimes-test` | n/a | mutable (uses atom) |
| 1106 | `clojure-walk-test` | n/a | `stringify-keys`, `macroexpand-all` — walk tests already in conformance suite |
| 1110 | `letfn-test` | n/a | letfn |
| 1123 | `core-delay-test` | n/a | lazy (`delay`/`deref`) |
| 1126 | `defn--test` | n/a | `defn-` (private), metadata |
| 1131 | `core-resolve-test` | n/a | namespaces, resolve |
| 1136 | `compatibility-test` | n/a | namespaces, resolve, var? |
| 1142 | `defonce-test` | ported | `defonce` preserves first value |
| 1145 | `metadata-on-var-test` | n/a | metadata |
| 1149 | `eval-colls-once` | n/a | Implementation detail (sort-by + for) |
| 1153 | `macroexpand-1-test` | n/a | macros |
| 1180 | `macroexpand-call-test` | n/a | macros |
| 1186 | `load-fn-test` | n/a | eval, namespaces |
| 1203 | `reload-test` | n/a | namespaces, eval |
| 1229 | `reload-all-test` | n/a | namespaces, eval |
| 1246 | `alter-meta!-test` | n/a | metadata, mutable |
| 1250 | `could-not-resolve-symbol-test3` | n/a | sci-api |
| 1256 | `function-results-dont-have-metadata` | n/a | metadata |
| 1260 | `fn-on-meta-test` | n/a | metadata |
| 1265 | `readers-test` | n/a | reader |
| 1272 | `built-in-vars-are-read-only-test` | n/a | sci-api, mutable |
| 1283 | `tagged-literal-test` | n/a | reader |
| 1287 | `ifs-test` | ported | `if-let`, `if-some` (note: `if-some` not in PTC-Lisp) |
| 1293 | `whens-test` | ported | `when-let`, `when-some` (note: `when-some` not in PTC-Lisp) |
| 1299 | `read-string-eval-test` | n/a | eval |
| 1310 | `while-test` | n/a | mutable (atom) |
| 1313 | `meta-on-syntax-quote-test` | n/a | metadata, quoting |
| 1316 | `atom-with-meta-test` | n/a | mutable |
| 1319 | `resolve-unquote` | n/a | quoting |
| 1322 | `ctx-test` | n/a | sci-api |
| 1339 | `copy-var-test` | n/a | sci-api |
| 1363 | `copy-var-private-test` | n/a | sci-api |
| 1378 | `copy-var-copy-meta-from-test` | n/a | sci-api |
| 1410 | `copy-var*-test` | n/a | sci-api |
| 1420 | `data-readers-test` | n/a | reader |
| 1424 | `exception-without-message-location-test` | n/a | try-catch |
| 1432 | `intern-test` | n/a | namespaces |
| 1457 | `instance?-test` | n/a | protocols, java-interop |
| 1463 | `threading-macro-test` | partial | `->`, `->>` ported. Skipped: macroexpand of threading |
| 1477 | `bound-test` | n/a | dynamic |
| 1484 | `call-quoted-symbol-test` | n/a | quoting (symbols as fns) |
| 1487 | `meta-test` | n/a | metadata |
| 1517 | `symbol-on-var-test` | n/a | metadata |
| 1526 | `macro-val-error-test` | n/a | macros |
| 1538 | `var-isnt-fn` | n/a | metadata |
| 1541 | `array-based-map-test` | n/a | Implementation detail (Clojure array-map vs hash-map ordering). Uses `zipmap` (not supported) |
| 1547 | `merge-opts-test` | n/a | sci-api |
| 1558 | `merge-opts-with-new-vars-test` | n/a | sci-api |
| 1564 | `merge-opts-preserves-features-test` | n/a | sci-api |
| 1569 | `dynamic-meta-def-test` | n/a | metadata, dynamic |
| 1579 | `self-ref-test` | n/a | Named fn self-reference + letfn. Blocked by GAP-F01 |
| 1596 | `more-than-twenty-args-test` | partial | `assoc` with many kv pairs ported — fails (GAP-S04). Skipped: `comment` with many args (comment not supported) |
| 1606 | `eval-file-meta-test` | n/a | sci-api |
| 1637 | `copy-ns-test` | n/a | sci-api |
| 1664 | `copy-ns-default-meta-test` | n/a | sci-api |
| 1671 | `vswap-test` | n/a | mutable (volatile) |
| 1675 | `to-array-2d-test` | n/a | java-interop |
| 1682 | `aclone-test` | n/a | java-interop |
| 1690 | `areduce-test` | n/a | java-interop |
| 1696 | `amap-test` | n/a | java-interop |
| 1712 | `empty-coll-identical-test` | n/a | Implementation detail (identity of empty colls) |
| 1717 | `var-name-test` | n/a | namespaces, metadata |
| 1742 | `ns-aliases-test` | n/a | namespaces |
| 1754 | `memfn-test` | n/a | java-interop |
| 1757 | `sci-error-test` | n/a | sci-api |
| 1765 | `sci-error-multiple-catches-test` | n/a | sci-api, try-catch |
| 1806 | `var->sym-test` | n/a | sci-api |
| 1809 | `api-resolve-test` | n/a | sci-api |
| 1812 | `do-and-or-test` | ported | and/or return values — GAP-S01 |
| 1831 | `type-test` | n/a | metadata, protocols |
| 1835 | `conditional-var-test` | n/a | metadata |
| 1839 | `override-ns-test` | n/a | sci-api |
| 1842 | `lazy-seq-macroexpand-test` | n/a | lazy, macros |
| 1845 | `eval-string+-test` | n/a | sci-api |
| 1858 | `time-test` | n/a | sci-api (time macro) |
| 1903 | `issue-977-test` | n/a | namespaces |
| 1906 | `var-without-configured-namespace-test` | n/a | sci-api |

---

## Summary

| Status | Count |
|--------|-------|
| ported | 22 |
| partial | 9 |
| todo | 0 |
| n/a | 55 |
| **Total** | **86** |

### Partially Ported (remaining assertions not yet covered)

1. **`core-test`** — `as->` (not supported), `some->` (not supported), EvalFn
2. **`destructure-test`** — symbol destructuring `{foo-val k}`, `:person/keys` (namespaced keys), `:syms`
3. **`fn-test`** — multi-arity fn `(fn ([x] ...) ([x y] ...))` (not supported)
4. **`def-test`** — unbound vars, try+def, metadata
5. **`defn-test`** — multi-arity, metadata, docstring introspection
6. **`recur-test`** — tail-position validation errors, letfn+recur
7. **`cond-test`** — error for odd number of args
8. **`idempotent-eval-test`** — `symbol`, `list` functions (not supported)
9. **`more-than-twenty-args-test`** — `comment` with many args (comment not supported)

---

## Other SCI Test Files

Status of other test files in `test/sci/`:

| File | Relevance | Notes |
|------|-----------|-------|
| `read_test.cljc` | **high** | Parser/reader conformance — should port next |
| `error_test.cljc` | medium | Error messages and locations |
| `parse_test.cljc` | **high** | Parsing edge cases |
| `vars_test.cljc` | low | Var semantics — mostly n/a (namespaces, dynamic) |
| `namespaces_test.cljc` | n/a | Namespace system not supported |
| `interop_test.cljc` | n/a | Java/JS interop |
| `multimethods_test.cljc` | n/a | Multimethods not supported |
| `protocols_test.cljc` | n/a | Protocols not supported |
| `hierarchies_test.cljc` | n/a | Hierarchies not supported |
| `defrecords_and_deftype_test.cljc` | n/a | Records/types not supported |
| `reify_test.cljc` | n/a | Reify not supported |
| `core_protocols_test.cljc` | n/a | Protocols not supported |
| `io_test.cljc` | n/a | I/O not supported |
| `repl_test.cljc` | n/a | REPL not applicable |
| `pprint_test.clj` | n/a | Pretty printing not supported |
| `proxy_test.clj` | n/a | Java proxy not supported |
| `array_test.clj` | n/a | Java arrays not supported |
