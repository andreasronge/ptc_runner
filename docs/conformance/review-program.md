# PTC-Lisp Conformance Review Program

This is the standing, hand-edited methodology and backlog for the repeatable
PTC-Lisp Clojure-conformance review. It defines how we classify behavioral
differences, the order in which we work through namespaces, and the future
probe phases that are not yet built.

This document is **not** a findings log and **not** a coverage report. Those
live elsewhere and must not be duplicated here:

- **Findings sink** — [`docs/clojure-conformance-gaps.md`](../clojure-conformance-gaps.md)
  holds every canonical `GAP-*` (bug) and `DIV-*` (intentional divergence)
  record, with Clojure behavior, PTC behavior, rationale, and linked test ids.
- **Classification log** — [`docs/conformance-classification-log.md`](../conformance-classification-log.md)
  records classification decisions as they are made.
- **Coverage dashboard** — [`docs/conformance/index.md`](./index.md) is the
  per-namespace coverage dashboard. It is **auto-generated** by
  `mix ptc.gen_docs`; never hand-edit it. The same applies to every
  `docs/conformance/*-audit.md` file.

The deterministic case suite, the Babashka/PTC oracle runner, the coverage
report task, and their proving tests already exist in the codebase
(`test/support/lisp_conformance_cases/`,
`PtcRunner.TestSupport.LispConformanceRunner`, `mix ptc.conformance_report`,
and `test/ptc_runner/lisp/conformance_runner_test.exs`). This program assumes
that machinery is in place and focuses on the ongoing triage loop and the
unbuilt extensions to it.

Repository policy that frames every decision:

- This is a 0.x library. Prefer simplification over compatibility shims.
- Clojure compatibility is the default.
- Sandbox safety and recoverable signal values take precedence.
- Java-named dot methods keep Java semantics.
- Generated conformance docs must not be edited by hand.

## Classification model (BUG / DIV / UNSUPPORTED / PTC_EXTENSION)

Every reviewed behavior ends in exactly one of these buckets:

- **MATCH** — PTC-Lisp matches Clojure/Java. No record needed.
- **BUG** — PTC-Lisp claims support but behavior differs *accidentally*.
  Recorded as a `GAP-*` entry in `clojure-conformance-gaps.md`.
- **DIV** — PTC-Lisp differs *intentionally* because of the language policy.
  Recorded as a `DIV-*` entry in `clojure-conformance-gaps.md`.
- **UNSUPPORTED** — the Clojure feature is intentionally outside the PTC-Lisp
  target surface. No `GAP-*`; tracked as an unsupported case in the suite.
- **PTC_EXTENSION** — the feature is PTC-specific and must be tested against
  the PTC spec, not against Clojure.
- **UNKNOWN** — needs a manual decision; park it in the classification log
  until resolved into one of the buckets above.

### Decision rules for a mismatch

Apply these in order when PTC and the oracle disagree:

1. **Clojure-named function, normal finite data input** → default to **BUG**
   unless the spec clearly justifies a **DIV**.
2. **Bad external input that can reasonably be recovered from** → **DIV** may
   be valid if PTC returns a signal value (`nil` / `false` / empty / a bounded
   sentinel) instead of raising.
3. **The program itself is invalid** → it *should* raise. A silent signal
   value here is suspicious and usually a **BUG**.
4. **Java-named method or class/member call** → Java semantics win, including
   exceptions. A recovered signal value where Java raises is a **BUG**.
5. **Behavior depends on laziness, unbounded execution, host state, I/O,
   macros, `eval`, metadata, vars, atoms, refs, agents, or JVM internals** →
   likely **UNSUPPORTED** or **DIV**, not BUG.

When a mismatch is accepted as a BUG or DIV: add or update the `GAP-*` / `DIV-*`
record in `clojure-conformance-gaps.md` (with example Clojure behavior, example
PTC behavior, rationale, and the linked test id), edit the audit **metadata
source** rather than any generated doc when the audit status itself is wrong,
then regenerate with `mix ptc.gen_docs` and run the relevant tests.

## Review methodology & namespace order

The review is namespace-by-namespace triage. Each namespace pass uses the
deterministic case suite and the oracle runner; new mismatches are classified
with the model above and recorded in the live findings docs.

Recommended namespace order:

1. `clojure.core` high-use subset
2. `clojure.string`
3. `clojure.set`
4. `clojure.walk`
5. Java string / math / number / time methods
6. PTC-specific extensions
7. remaining candidate functions

Within `clojure.core`, review in clusters rather than alphabetically, so that
related policy questions surface together:

- syntax / special forms
- truthiness / control flow
- function invocation
- binding / destructuring
- collections
- maps
- sets
- sequences
- numbers
- strings / regex
- predicates
- ordering / comparison
- formatting / printing
- resource limits

For each supported function in a cluster, aim for at least:

- one smoke case,
- one nil / empty / boundary case where relevant,
- one error-semantics case where the behavior is risky.

The boundary/error matrix is where most `DIV-*` candidates appear. For each
important function, probe: wrong arity, wrong type, nil input, empty
collection, missing key, out-of-range index, malformed string, `##NaN` /
`##Inf` / `##-Inf`, large number, and large collection. Classify each with the
decision rules; only promote a difference to a `DIV-*` once it is decided to be
intentional.

## Future probes (deferred)

The phases below extend the review beyond hand-seeded cases. They are **not yet
built**. Add them only once the deterministic suite is genuinely useful, and
keep anything large or non-deterministic behind the `conformance_slow` tag (see
below) so normal CI stays fast.

### Phase 6 — upstream test mining

Use other Clojure implementations as test sources, but import conservatively.

Potential sources: Clojure official tests, Babashka tests, SCI tests, Joker
tests, and Clojure docstring examples.

Process:

1. Download or vendor references only if licensing is acceptable.
2. Extract simple assertions first:
   - `(is (= expected form))`
   - `(is (true? form))`
   - `(is (false? form))`
   - `(is (nil? form))`
   - `(is (thrown? ... form))`
3. Filter out unsupported constructs: macros, metadata, vars, namespaces,
   dynamic binding, atoms/refs/agents, JVM arrays/classes (unless the Java
   audit covers them), lazy infinite sequences, and file/network/I/O.
4. Convert accepted assertions into the local case format.
5. Mark the source and original location on each imported case.

Suggested script: `scripts/extract_clojure_conformance_cases.exs`.

Do not attempt to import arbitrary upstream test code. Start with pattern-based
extraction of the simple assertion shapes above.

### Phase 7 — doc-example extraction

Extract executable examples from local docs first, then later from external
Clojure docs/docstrings.

Local sources: `docs/ptc-lisp-specification.md`, `docs/function-reference.md`,
and `docs/clojure-conformance-gaps.md`.

Process:

1. Extract fenced `clojure` code blocks.
2. Split into individual forms where possible.
3. Classify each as Clojure-compatible, PTC extension, unsupported, or
   documentation-only.
4. Add cases or spec tests for the executable ones.

This catches doc drift: examples in our docs should either execute or be
explicitly marked as illustrative.

### Phase 8 — differential fuzzing

Add only after the deterministic suite is useful. This is a mismatch-discovery
tool, not a perfect fuzzer.

Generate small supported expressions — literals, vectors/maps/sets, `if`,
`let`, `fn`, `map`/`filter`/`reduce`, `get`/`assoc`/`update`, string functions,
numeric ops, comparisons — and run each generated form against both PTC-Lisp
and Babashka.

Record, per generated form: the seed, the form, the PTC result/error, the
Clojure result/error, and the classification.

Useful constraints to keep generated forms safe and deterministic:

- small depth,
- finite collections only,
- no division by zero unless explicitly testing numeric edge cases,
- no infinite / lazy constructs,
- no unsupported macros,
- deterministic forms only.

## CI: conformance_slow tag

Fast, deterministic conformance tests run in normal CI. Large imported suites
(Phase 6), broad doc-example sweeps (Phase 7), and the differential fuzzer
(Phase 8) must run behind a dedicated tag so they do not slow the default run:

```bash
mix test --only conformance_slow
```

Keep the fuzzer and any imported-test bulk out of the normal suite unless a
given subset is deterministic and fast enough to belong there.
