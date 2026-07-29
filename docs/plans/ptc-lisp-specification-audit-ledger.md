# PTC-Lisp specification audit ledger

This is the short decision record for the current specification audit. It
separates corrections backed by existing behavior from changes that expand or
alter the public contract.

| Area | What changed | Why | Decision |
| --- | --- | --- | --- |
| Specification corrections | Fixed escape syntax, collection return shapes, function notes, and other statements that disagreed with existing tests and runtime behavior. | The implementation and established tests already agree. | **Keep** |
| Clojure `distinct` claim | Corrected the claim that Clojure rejects a direct map. PTC-Lisp still rejects it under DIV-29. | The old compatibility statement was wrong; no PTC behavior was changed. | **Keep** |
| Quoted-symbol syntax | Documented the already-supported `'name` and `(quote name)` forms as narrow inert references, not general Clojure quotation. | The parser and evaluator already accepted these forms. | **Keep** |
| Quoted symbols at host boundaries | Made quoted-symbol values round-trip through context, memory, history, tools, Kernel results, JSON artifacts, and terminal output. | This makes parallel public paths consistent and defines the durable contract. | **Keep** |
| `quote` conformance status | Reclassified `quote` as supported with DIV-19 because only symbols can be quoted. | This follows from accepting narrow quote support as a public feature. | **Keep** |
| Boundary validation | Reject malformed wrappers, improper lists, and projection collisions in retained public values instead of raising, changing shape, or losing entries. | Public boundaries must be fail-closed and lossless. | **Keep** |
| Tool arguments and cache keys | Preserve quoted-symbol key spelling and prevent different quoted keys from sharing a cache entry. | Required because quoted symbols are public boundary values. | **Keep** |
| Namespace export | Validate exportable values, preserve exact source forms, and order constants/helpers so exported source can be loaded again. | Export that cannot hydrate is broken. Round-trip tests now cover it. | **Keep** |
| Closure serialization API | `serialize_closure/1` and `serialize_namespace/1` now return `{:ok, value}` or `{:error, reason}`. | Safe rejection needs an error channel; the breaking change is acceptable for this 0.x library. | **Keep** |
| Context filtering | Use AST-bounded direct lookups before setup; validate and normalize retained values inside the bounded worker. | Avoids enumerating or copying unrelated hostile input in the caller process. | **Keep** |
| Early errors | Validate continuation memory inside setup bounds before returning parse, configuration, attachment, or compile errors. | Keeps the original error and valid memory without traversing malformed or oversized memory in the caller. | **Keep** |
| Sandbox lifecycle | Hardened worker cleanup, setup limits, alias handling, and invalid-memory behavior. | Prevents leaked work and unsafe reprojection after setup failure. | **Keep** |
| Sandbox timeout result | Timeout details now identify `:setup` or `:eval`. | The phase is needed to diagnose whether host setup or program evaluation exhausted the deadline. | **Keep** |
| Generated references | Updated function reference, conformance inventory, indexes, and checksums to match the accepted decisions. | These files are derived, not independent design decisions. | **Regenerate before commit** |

Before merging:

1. Regenerate derived documentation and checksums.
2. Run the full precommit suite and a fresh independent review.
