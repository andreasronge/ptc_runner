# Dynamic Upstream Requirement Metadata

**Status:** narrowed future issue, surfaced by the 2026-07-06
scoped-base-surface promotion measurement in `ptc-bench-comparison`.
The explicit per-export metadata slice is implemented and seed-path verified
by [`../seed-time-upstream-requires.md`](../seed-time-upstream-requires.md)
and
`mcp_server/test/ptc_runner_mcp/sessions_lifecycle_test.exs`
(`seeded explicit upstream requires attach and filter under finite role
grants`). Remaining work here is for genuinely dynamic shapes where the
permitted upstream operation must be derived from typed descriptors or
compiler-checkable contracts, not from a literal attr-map. Related design:
[`composable-prelude-library-demo.md`](../composable-prelude-library-demo.md)
Slice E and
[`prelude-selected-capability-namespaces.md`](prelude-selected-capability-namespaces.md).
The legibility/mitigation layer — making the conservative filter
self-explaining at attach, call-error, and turn-metadata surfaces while this
root fix is pending — is filed separately as
[`grant-projection-legibility.md`](grant-projection-legibility.md)
(2026-07-06, from the same run's Stage 2/Stage 6 instances).

## Problem

Finite role grants can only fail closed when the server can prove which
upstream operations a visible prelude export may call. Literal upstream calls
are checkable:

```clojure
(tool/call {:server "fixture" :tool "read_page"} args)
```

Dynamic upstream calls are not checkable from the call form alone:

```clojure
(tool/call {:server server :tool tool} args)
```

The current safe behavior is therefore conservative: under a finite
`upstream_tools` grant, dynamic `tool/call` exports are absent or attach-fail
unless they carry explicit upstream requirements. They can remain visible only
under a deliberately broad grant such as `upstream_tools: "all"`.

The scoped-base-surface promotion run hit this as measurement friction. Two
archived attempts failed before the valid control cell:

- `attempt1-ptc-tools-filtered`: an explicit empty `ptc_tools` grant filtered
  dynamic tool-using exports.
- `attempt2-store-seed-not-callable`: a finite upstream grant still filtered
  exports that dispatch through dynamic `tool/call`, because the exports had
  no exact upstream-requirement metadata the role policy could check.

The valid run had to use `auditor.upstream_tools: "all"`. That was acceptable
for the measurement, but it is not the fail-closed role story Slice E is trying
to reach.

**Gated-run evidence (2026-07-06, `composable-demo-3-source-first-20260706`
Stage 2 Phase B):** the gap now has a live gated-stage hit, not just
measurement friction. The analyst role's finite
`upstream_tools: ["upstream:fixture/read_jsonl"]` grant let
`preludes: [{"id": "paged_audit", "version": 1}]` attach cleanly
(`prelude_refs` carried both preludes with correct checksums and
`required_by` provenance) while the authority filter removed every dynamic
`tool/call` export: `(dir 'paged_audit)` and `(dir 'paged_base)` returned
`[]`, calls failed `not a public export`, and `prelude/read` introspection
kept answering. The model documented the split surface in-session
(`prelude_refs_attached true`, `reconcile-totals_callable false`) and
re-implemented the library's aggregation ad hoc from raw granted upstream
reads plus source transcription — a concrete demonstration that the gap
converts a packaged, versioned capability back into copy-paste code at
exactly the moment a narrow-grant session tries to use it. Two additional
data points for the design: (1) attach-time success with empty runtime
surface is a confusing failure mode — the export filter should surface a
reason in discovery/`prelude_refs` so sessions do not have to probe for it,
and should stamp the filtered surface in session/turn metadata the way
`scoped_base_surface` already stamps `masked_namespaces`, so a gate audit
can detect an emptied surface without the model's cooperation. This is not
only ergonomics: a grant-filtered export is behaviorally indistinguishable
from a dangling reference — both fail `not a public export` — and in this
run that ambiguity let a dangling guidance-string reference pass as
plausibly-filtered and enter the evidence lane endorsed as valid guidance;
(2) the bench's boot preflight validated grant projection via `(dir
"fixture")` but had no callable-export probe, so the gap reached a live
model stage undetected.

**Second gated-run instance (2026-07-06, same run, Stage 6 validator):** the
validator role's finite `upstream_tools` grant produced the same signature at
the stage where it is fatal rather than degradable — validation *requires*
calling the packaged export. The validator attached the edited
`paged_audit` (checksum `1eb91357…`) with the correct transitive closure,
confirmed the edit, exports, and guard source as public via `prelude/read`,
then had its direct `reconcile-totals` call rejected `not a public export`
and burned its turn budget against the ambiguity without completing the
behavior proof (sealed failed stage, bench commit `3fc699f`). The relaxation
to `upstream_tools: "all"` had been pre-declared for exactly this stage but
was not applied to the role config before boot — which is itself a data
point: the fail-closed filter's cost lands on whoever forgets it, and
nothing at boot or attach time warns that a role's grant will empty a
prelude's callable surface. A boot- or attach-time warning ("N exports
filtered by grant") would have converted both instances into config fixes
before launch.

## Direction

For future work, add a way for public prelude exports with dynamic upstream
dispatch to derive exact upstream requirements when a static attr-map is not
enough. The mechanism should let role policy answer:

> This export may call only `fixture/read_page`, even though the runtime form
> uses `(tool/call {:server server :tool tool} ...)`.

The explicit metadata shape already works:

```clojure
(defn collect-page
  "Collect through a dynamic helper."
  {:requires ["upstream:fixture/read_page"]}
  [source]
  ...)
```

Remaining possible shapes:

- a typed source descriptor value whose permitted upstream operation is part of
  its checked metadata;
- compiler-supported contracts that connect a dynamic `tool/call` to a finite
  set of upstream operation refs.

The invariant is more important than the encoding: finite grants must not
silently widen to cover unknown dynamic calls, and dynamic exports should not
force broad `"all"` grants when their actual upstream operation is knowable.

## Validation

- Done for explicit attr-map metadata: a seeded dynamic `tool/call` export
  with exact metadata attaches under the matching finite upstream grant, is
  visible, and is callable through the root upstream runtime.
- Done for explicit attr-map metadata: the same seeded prelude surface filters
  an export whose declared upstream operation is not granted.
- Done for the unmarked control: a seeded dynamic `tool/call` export without
  exact metadata remains absent under finite grants.
- Broad grants continue to work, and turn metadata records that broad grant
  fingerprint so later evidence readers can distinguish diagnostic reach from
  fail-closed role validation.

This issue is independent of `scoped_base_surface`'s demotion. It is a role
grant and auditability gap, not an attention-cost optimization.
