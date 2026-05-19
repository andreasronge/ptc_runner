# PTC-Lisp Design Guidelines

Brief rationale for why PTC-Lisp looks like Clojure but does not try to be all of Clojure.

PTC-Lisp is a small, Clojure-shaped language for LLM-generated programs that run inside a sandbox. Clojure compatibility is useful because models already know the syntax and idioms, and conformance checks catch subtle behavior bugs. The stronger goal is predictable, bounded, recoverable data transformation inside an agent loop.

See also: [PTC-Lisp Specification](../ptc-lisp-specification.md), [Function Reference](../function-reference.md), and [Clojure Conformance Gaps](../clojure-conformance-gaps.md).

## Design Shape

PTC-Lisp favors:

- sandbox safety over language completeness,
- ordinary data transformation over general runtime features,
- deterministic eager evaluation over laziness, ambient state, or host access,
- Clojure names and behavior where they are safe and useful,
- small compatibility shims where LLMs commonly generate familiar Java or Clojure-shaped code.

This is why the language includes collection operations, predicates, threading forms, destructuring, string and JSON helpers, bounded regex use, tool calls, and a narrow Java compatibility surface. It does not aim to include broad host interop, macros, eval, mutable runtime state, arbitrary I/O, or large abstraction systems.

## Clojure Compatibility

Clojure is the default reference point for Clojure-named functions and forms. Matching Clojure keeps generated code familiar and gives the conformance suite a concrete oracle.

PTC-Lisp diverges when exact Clojure behavior would make sandboxed generated programs less safe, less bounded, or harder to recover from. The common examples are laziness, infinite sequences, host capabilities, and exceptions for messy external data.

Intentional differences are tracked in [Clojure Conformance Gaps](../clojure-conformance-gaps.md), especially when user-visible behavior differs from Clojure.

## Recoverable Signals

Generated programs often process incomplete tool output, scraped text, or user-provided data. For those cases, PTC-Lisp sometimes returns ordinary signal values such as `nil`, `false`, `""`, or an empty collection instead of aborting execution.

The intent is not to hide program bugs. Invalid arity, unknown symbols, non-callable values, malformed tool calls, and sandbox limits should still fail loudly. Signals are for expected data misses: absent keys, failed parses, no regex match, malformed upstream JSON, and similar cases where the caller can branch, filter, or choose to `(fail ...)`.

The practical split is: messy data should be composable; broken generated programs should be visible.

## Java-Named Compatibility

Dot-prefixed methods such as `.substring`, `.indexOf`, and `.length` exist because models often generate Java-shaped code. The dot prefix is a signal that the caller opted into Java-style behavior.

For example, `.indexOf` returns `-1` when not found and `.substring` raises for invalid indices. Clojure/PTC-named helpers can choose safer data-shaped behavior, such as `index-of` returning `nil`.

## Namespace Compatibility

PTC-Lisp does not support general Clojure namespace forms such as `ns`,
`require`, `refer`, or `import`. Namespaced symbols are an explicit,
allowlisted surface with two meanings:

- **Clojure compatibility namespaces** such as `clojure.string/` and
  `clojure.set/` expose Clojure-derived functions under their familiar names.
  They should resolve only to the functions intentionally exposed by that
  namespace; cross-namespace fallback makes the advertised namespace misleading
  and should fail with a helpful list of available functions.
- **PTC capability namespaces** such as `tool/`, `data/`, `json/`, `budget/`,
  and `catalog/` are owned by PTC-Lisp. They do not claim Clojure library
  compatibility and should be documented in prompts only when relevant to the
  current agent mode or enabled capability. Keep unimplemented/reserved
  namespaces such as `mcp/` out of the analyzer and prompt surfaces until they
  are backed by runtime functions.

Prefer real Clojure namespaces for Clojure-derived functions when they exist.
Use short PTC-owned namespaces for non-standard capabilities. Tests should cover
both accepted namespaced calls and rejected unknown or cross-category members.

## When Extending

New syntax or builtins fit best when they help LLM-generated code transform data predictably inside the sandbox. Prefer small, deterministic, bounded features with clear examples and tests.

When a choice depends on compatibility, keep the reason visible in the function reference, spec, tests, or conformance gaps rather than expanding this guideline into a second specification.
