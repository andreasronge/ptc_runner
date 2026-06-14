# Finite `repeat` Builtin for PTC-Lisp

**Status:** proposed 2026-06-12. This plan intentionally changes only the
bounded two-arity shape of Clojure's `repeat`; the infinite one-arity lazy
sequence remains unsupported.

## Problem

LLMs commonly reach for Clojure's `repeat` when they need a fixed number of
copies of a value, for example:

```clojure
(apply str (repeat 5000 "x"))
```

PTC-Lisp currently rejects that with `Undefined variable: repeat`. The
exclusion is documented in the conformance audit and language spec because
Clojure's one-arity `repeat` returns an infinite lazy sequence, which conflicts
with PTC-Lisp's sandbox-safety and finite-data bias.

The useful LLM idiom is not the infinite form. It is almost always the bounded
two-arity form: "give me `n` copies of this value". Today users must write a
less obvious equivalent:

```clojure
(map (constantly "x") (range 5000))
```

That works but is noisier and increases the chance that generated programs use
unsupported `repeat` anyway.

## Goal

Add a PTC-safe finite `repeat` builtin:

```clojure
(repeat n x) ; => [x x ...] with exactly n entries
```

This should be convenient, bounded, documented as a deliberate conformance
deviation, and covered by tests that lock down the unsupported infinite arity.

## Non-Goals

- Do not support `(repeat x)`.
- Do not introduce lazy sequences.
- Do not add transducer arities.
- Do not add a special `repeat`-specific memory cap. Existing sandbox heap,
  timeout, and program limits remain the enforcement boundary.
- Do not make compatibility shims for old behavior. This is a 0.x library and
  adding the missing bounded builtin is an intentional surface change.

## Semantics

### Supported

`(repeat n x)` returns a finite sequential value containing `n` copies of `x`.

Examples:

```clojure
(repeat 3 "x") ; => ["x" "x" "x"]
(repeat 0 "x") ; => []
(apply str (repeat 3 "x")) ; => "xxx"
```

The result should use the same concrete sequence representation as other
PTC-Lisp sequence-producing builtins. In the current runtime that means an
Elixir list, rendered as a Clojure vector-like sequence by the formatter.

Values are repeated by immutable term reference in the BEAM. That is acceptable:
PTC-Lisp values are immutable, and existing collection operations already share
subterms naturally.

### Rejected

`(repeat x)` must fail with a clear arity error. It must not be interpreted as
an infinite sequence, and it must not silently return a singleton.

`n` must be an integer. Non-integers should fail with the normal builtin
argument validation path. Negative `n` should fail with a recoverable type or
argument error rather than returning an empty list, because Clojure's bounded
repeat expects a non-negative count in practical use and silent coercion hides
model mistakes.

Open decision before implementation: whether to accept only `nat-int?` or to
mirror nearby functions like `range`/`take` if they currently tolerate broader
numeric input. Prefer consistency with existing runtime argument validation,
but document whichever behavior the implementation chooses.

## Impact

### Positive

- Makes common generated programs shorter and more likely to run.
- Avoids teaching agents a workaround for a familiar Clojure function.
- Keeps the useful part of `repeat` while preserving the no-infinite-sequences
  rule.

### Compatibility

This is partial Clojure compatibility:

- Clojure `(repeat n x)` is finite from the consumer's perspective because it
  is a lazy infinite source bounded by `n`; PTC-Lisp materializes the finite
  result immediately.
- Clojure `(repeat x)` is infinite; PTC-Lisp rejects it.

The conformance docs should mark `repeat` as finite-only / partial rather than
fully supported.

### Resource Behavior

`repeat` allocates `O(n)` list cells and returns a value whose encoded/rendered
size also scales with `n`. Very large `n` can still exhaust heap or time, just
like `(range huge)` or `(map ... large-coll)`.

No special limit is needed in V1. The sandbox already enforces:

- program timeout;
- program heap limit;
- MCP/session result and envelope caps;
- persisted session memory caps if the result is stored.

If a future benchmark shows `repeat` is a common accidental heap-kill source,
add general collection-size guidance rather than a one-off cap.

## Implementation Plan

### P1 - Runtime Builtin

1. Add `Runtime.repeat/2` or `Runtime.Collection.repeat/2` near related
   sequence constructors (`range`, `take`, `list`, `vector`).
2. Validate `n` through the existing builtin argument validator where possible.
   If the current validator lacks a non-negative integer contract, either add a
   reusable contract or perform a local guard that raises the same style of
   recoverable runtime error as sibling collection functions.
3. Implement with `List.duplicate(value, n)` or an equivalent tail-safe helper.
4. Add `{:repeat, {:normal, &Runtime.repeat/2}}` to
   `lib/ptc_runner/lisp/runtime/builtins.ex`.

### P2 - Tests

Add focused runtime/eval tests:

- `(repeat 3 "x")` returns `["x", "x", "x"]`.
- `(repeat 0 "x")` returns `[]`.
- `(apply str (repeat 3 "x"))` returns `"xxx"`.
- `(repeat 2 {:a 1})` preserves compound values.
- `(repeat "3" "x")` fails with a type/argument error.
- `(repeat -1 "x")` fails.
- `(repeat "x")` fails with an arity error and does not enter any fallback path.

Add a regression test for the exact LLM-shaped idiom that motivated the change:

```clojure
(count (repeat 5000 "x"))
```

Keep the count modest enough that the normal test suite is fast and stable.
Do not add a heap-kill test unless implementation changes resource policy.

### P3 - Docs and Discovery

Update:

- `docs/function-reference.md` with finite-only `repeat` docs and examples.
- `docs/ptc-lisp-specification.md` §13.2 to remove `repeat` from the key
  exclusions list or qualify it as "one-arity infinite repeat remains
  excluded".
- `docs/conformance/clojure-core-audit.md` to mark `repeat` as partial /
  finite-only, with notes that one-arity lazy repeat is unsupported.
- `priv/function_audit.exs` so regenerated conformance output does not drift.
- Prompt/reference material that currently lists `repeat` as excluded, such as
  `priv/prompts/reference.md`, to say only infinite/lazy repeat is excluded.

If `apropos`/discovery derives builtins from the runtime registry plus function
reference metadata, verify `repeat` appears with the finite-only caveat.

### P4 - Verification

Run at minimum:

```sh
mix format --check-formatted
mix test test/ptc_runner/lisp/runtime/collection_ops_test.exs
mix test test/ptc_runner/lisp/integration/collection_ops_test.exs
mix test test/ptc_runner/lisp/clojure_conformance_test.exs
```

Then run the repository gate before commit:

```sh
mix precommit
```

If docs generation or conformance generation has a dedicated task, run it after
updating `priv/function_audit.exs`.

## Open Questions

1. Should `n` accept only non-negative integers, or should it follow whatever
   coercion behavior `take` and `range` currently expose?
2. Should the conformance status vocabulary use `partial`, `supported`, or a
   note on `supported`? Prefer whatever the existing audit generator already
   supports.
3. Should `repeat` live in the general runtime facade or a collection-specific
   module if the collection runtime is later split more aggressively?

## Acceptance Criteria

- `(repeat n x)` works for non-negative integer `n`.
- `(repeat x)` remains unsupported with a clear arity error.
- Non-integer and negative counts fail recoverably.
- Docs and conformance files describe the finite-only semantics.
- The implementation relies on existing sandbox/resource limits and introduces
  no lazy sequence machinery.
