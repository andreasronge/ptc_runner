# PTC-Lisp Design Guidelines

Rules for deciding what belongs in PTC-Lisp and when it should diverge from Clojure.

PTC-Lisp is a Clojure-shaped language for LLM-generated, sandboxed programs. Clojure conformance is valuable because models already know Clojure idioms and conformance tests catch subtle behavior bugs. It is not the top-level goal. The top-level goal is deterministic, bounded, recoverable data transformation inside an agent loop.

See also: [PTC-Lisp Specification](ptc-lisp-specification.md), [Function Reference](function-reference.md), and [Clojure Conformance Gaps](clojure-conformance-gaps.md).

## Design Priorities

Apply these in order when adding syntax, functions, or interop:

1. **Sandbox safety** - programs must be bounded in time, memory, and host access.
2. **Recoverability for LLM code** - common bad inputs should produce guardable signal values when recovery is useful.
3. **Clojure familiarity** - use Clojure names, arities, truthiness, collection behavior, and data idioms unless a higher priority overrides them.
4. **Determinism** - avoid ambient state, uncontrolled time, random behavior, filesystem access, and network access except through explicit tools.
5. **Small surface area** - prefer a compact set of predictable primitives over full language completeness.
6. **Boundary clarity** - distinguish PTC-Lisp data functions, tool calls, and Java-named compatibility methods by name and behavior.

## What To Include

Include a feature when it:

- Helps with data transformation, filtering, aggregation, validation, string processing, JSON, or tool-result shaping.
- Runs eagerly within sandbox limits.
- Is deterministic and has no hidden global state.
- Does not expose host capabilities, filesystem I/O, arbitrary class access, or runtime code loading.
- Can be documented with a few examples that LLMs are likely to generate correctly.
- Preserves the Clojure contract or has an explicit `DIV-*` rationale.

Good candidates: pure collection functions, predicates, threading forms, destructuring patterns, bounded regex helpers, JSON helpers, and small Java compatibility shims that models commonly generate.

Poor candidates: lazy or infinite sequences, macros, `eval`, `read-string`, mutable references, arbitrary host interop, dynamic vars, filesystem I/O, exception machinery, protocols, multimethods, and large abstraction systems.

## Clojure Conformance Rules

Use Clojure behavior as the default for Clojure-named functions and forms:

- Preserve truthiness: only `nil` and `false` are falsey.
- Preserve return-value idioms: `and`/`or` return actual values, `seq` returns `nil` for empty collections, `some` returns the first truthy result.
- Preserve nil-friendly data access: `get`, keyword lookup, `get-in`, `first`, `last`, and `nth` should remain easy to compose with `some->` and `when`.
- Preserve names and arities when the Clojure contract is safe and bounded.
- Test supported Clojure-compatible behavior against the conformance suite when practical.

If a feature is marked supported in the audits but behaves differently from Clojure, either fix it or move it to an intentional `DIV-*` entry with rationale.

## Intentional Divergence Rules

Diverge from Clojure when matching Clojure would make LLM-generated sandbox code less safe, less bounded, or less recoverable.

Prefer an intentional divergence when one of these applies:

- **Clojure raises for bad input data.** PTC-Lisp has no `try`/`catch`; raising terminates the program. For Clojure-named helpers, prefer signal values such as `nil`, `""`, `false`, or an empty collection when the caller can reasonably continue.
- **Clojure relies on laziness or infinity.** PTC-Lisp is eager and bounded. Require finite inputs and explicit limits.
- **Clojure relies on mutable or global runtime state.** Omit it unless there is a narrow deterministic substitute.
- **Clojure exposes host power.** Omit it or provide a tiny whitelisted compatibility surface.
- **Clojure's exact behavior would create plausible wrong output.** Prefer a clean signal over a value that looks valid but means "miss".

Do not signal when collapsing distinguishable failures would hide a likely code bug. The practical line is: properties of input data may signal; properties of the program should raise. For example, `(parse-long "abc")` returns `nil` because external text failed to parse, but `(+ 1 nil)`, invalid arity, or an unknown symbol raises because the generated program is wrong.

Every intentional divergence must be documented in [Clojure Conformance Gaps](clojure-conformance-gaps.md#intentional-divergences--by-design-not-bugs) with:

- the Clojure behavior,
- the PTC-Lisp behavior,
- the reason for diverging,
- the expected caller idiom,
- links from the function reference or spec when the function is user-visible,
- a regression test that fails if the divergence is accidentally "fixed" back to Clojure behavior.

## Signal Values

Signal values are ordinary return values that let code keep running and branch explicitly:

| Signal | Use when |
|--------|----------|
| `nil` | Missing value, parse failure, absent match, invalid non-critical input |
| `""` | String extraction miss where the result is naturally string-shaped |
| `false` | Predicate cannot prove the property or receives unsupported input |
| `[]` / `{}` / `#{}` | Collection result is naturally empty and the operation succeeded |

Use a signal value only when it is unlikely to hide a serious programmer fault. Arithmetic with `nil`, invalid arity, unknown symbols, and malformed tool calls should still raise because continuing would hide a bug in the generated program.

When choosing between signals, keep the output type stable. A string function should usually return a string signal such as `""`; a lookup or parser should usually return `nil`; a predicate should return `false`.

## Error Rules

Raise an execution error for programmer faults:

- syntax and parse errors,
- invalid arity,
- unknown symbols or tools,
- non-callable values in call position,
- type errors where no useful recovery signal exists,
- invalid tool or catalog arguments,
- sandbox limits such as timeout, memory, recursion, or iteration caps.

Return signal values for world faults and expected data misses:

- missing keys,
- no regex match,
- failed parse of external text,
- absent JSON or malformed JSON in data supplied by a tool,
- upstream failures that are explicitly modeled as recoverable.

This split is part of the language contract: program bugs should be loud; messy data should be composable.

Callers should convert a signal into `(fail ...)` when the missing or invalid value means the agent cannot complete the requested task. Otherwise, guard or filter the signal locally. See [Getting Started](guides/subagent-getting-started.md) for the multi-turn `return` / `fail` flow.

## Java-Named Methods

Java-named methods keep Java semantics.

Dot-prefixed forms such as `.substring`, `.indexOf`, `.length`, and date/time methods exist because LLMs often generate Java-shaped code. The dot prefix signals that the caller opted into Java compatibility. These methods should follow Java's arity, index, sentinel, and error behavior unless a specific method is documented otherwise.

This is intentionally different from Clojure-named helpers. For example:

- `.indexOf` returns `-1` when not found, matching Java.
- `index-of` returns `nil` when not found, matching the safer Clojure-shaped PTC-Lisp idiom.
- `.substring` raises on invalid indices, matching Java.
- `subs` returns string-shaped signal values for out-of-range cases, per `DIV-22`.

Do not silently soften Java-named methods unless the method's name or docs make the new contract obvious. If safer behavior is needed, prefer an existing Clojure/PTC-named wrapper or choose a plain descriptive name that states the operation, not a `safe-*` prefix.

## Feature Review Checklist

Before adding a function or form, answer:

- What LLM-generated task does this make easier?
- Is the operation pure and deterministic?
- Can it be bounded without lazy evaluation?
- Does it expose host capabilities or new side effects?
- If Clojure would raise, should PTC-Lisp raise or return a signal value?
- What is the smallest useful arity set?
- Does it fit the existing data model, especially vector-first sequential data and string-keyed tool boundaries?
- Should it appear in `priv/functions.exs`, `priv/function_audit.exs`, the function reference, the spec, or the conformance gaps doc?
- What regression test pins the intended divergence?

If the answer depends on "models might generate it", prefer a narrow compatibility shim over a broad subsystem.

## Conformance Workflow

When checking Clojure conformance:

1. Run the existing conformance tests or add a minimal reproducer against SCI, Babashka, Joker, or direct Clojure output.
2. Classify the result as a bug, missing candidate, not relevant, or intentional divergence.
3. Fix bugs that violate the design priorities or common Clojure idioms.
4. Document intentional divergences as `DIV-*` entries.
5. Add a regression test that encodes the PTC-Lisp contract, not only the Clojure comparison.
6. Link user-visible divergences from the spec and generated registry metadata.

Conformance should keep the language familiar. It should not force PTC-Lisp to inherit features that make sandboxed LLM programs harder to execute safely.
