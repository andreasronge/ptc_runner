# Dynamic Upstream Requirement Metadata

**Status:** future issue, surfaced by the 2026-07-06 scoped-base-surface
promotion measurement in `ptc-bench-comparison`. Related design:
[`composable-prelude-library-demo.md`](../composable-prelude-library-demo.md)
Slice E and
[`prelude-selected-capability-namespaces.md`](prelude-selected-capability-namespaces.md).

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

## Direction

Add a way for public prelude exports with dynamic upstream dispatch to declare
or derive exact upstream requirements. The mechanism should let role policy
answer:

> This export may call only `fixture/read_page`, even though the runtime form
> uses `(tool/call {:server server :tool tool} ...)`.

Possible shapes:

- explicit export metadata, for example `requires: ["upstream:fixture/read_page"]`;
- a typed source descriptor value whose permitted upstream operation is part of
  its checked metadata;
- compiler-supported contracts that connect a dynamic `tool/call` to a finite
  set of upstream operation refs.

The invariant is more important than the encoding: finite grants must not
silently widen to cover unknown dynamic calls, and dynamic exports should not
force broad `"all"` grants when their actual upstream operation is knowable.

## Validation

- A dynamic `tool/call` export with exact metadata attaches under the matching
  finite upstream grant and is visible in prompt/discovery output.
- The same export is absent or attach-fails under a finite grant that lacks the
  declared upstream operation.
- A dynamic `tool/call` export without exact metadata remains absent or
  attach-fails under finite grants.
- Broad grants continue to work, and turn metadata records that broad grant
  fingerprint so later evidence readers can distinguish diagnostic reach from
  fail-closed role validation.

This issue is independent of `scoped_base_surface`'s demotion. It is a role
grant and auditability gap, not an attention-cost optimization.
