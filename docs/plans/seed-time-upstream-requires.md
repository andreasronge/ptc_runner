# Seed-Time Explicit Upstream Requires Under Finite Grants — Plan

## Status

Implemented 2026-07-06. The verification spike passed: explicit per-export
`{:requires ["upstream:<server>/<tool>"]}` metadata in seed `.clj` files
works through `--prelude-store-seed`, finite role grants, session projection,
and runtime upstream calls. The contract is pinned by
`mcp_server/test/ptc_runner_mcp/sessions_lifecycle_test.exs`
(`seeded explicit upstream requires attach and filter under finite role
grants`).

This plan activates the "explicit export metadata" shape from
[`future/dynamic-upstream-requirement-metadata.md`](future/dynamic-upstream-requirement-metadata.md)
and, if the spike passes, rescopes that doc to the genuinely dynamic shapes
(typed source descriptors, compiler contracts for runtime-computed
server/tool pairs), which this plan does not attempt. The legibility layer is
tracked separately in
[`future/grant-projection-legibility.md`](future/grant-projection-legibility.md);
its first slice shipped at HEAD (`feat(mcp): explain grant-filtered prelude
exports`).

Motivation: the launch blocker for `autonomous-shakedown-1` in the external
repo `ptc-bench-comparison`
(`agent-runs/autonomous-shakedown-1-20260706/README.md`) states that
"seed-time upstream `requires` metadata is not expressible through the
current `.deps` seed sidecar path". That framing assumes the sidecar is the
metadata channel for upstream requires. It is not, and never was: the
sidecar carries prelude-to-prelude deps only. Per-export upstream requires
is inline source metadata, compiled identically at seed time and runtime.

## Problem

Finite role grants fail closed against dynamic upstream dispatch: under
`upstream_tools != "all"`, a public export whose transitive closure contains
a non-literal `(tool/call {:server s :tool t} ...)` is rejected at attach
unless it carries explicit `upstream:<server>/<tool>` requirements
(`lib/ptc_runner/lisp/prelude/attach.ex:208`). This is the correct
invariant — finite grants must not silently widen — but two gated bench runs
(demo 3 Stage 2 and Stage 6, 2026-07-06, recorded in
`future/dynamic-upstream-requirement-metadata.md`) hit it as an apparent
capability gap because the seeded preludes carried no requirement metadata
and the bench believed there was no seed-time channel to add it.

The `autonomous-shakedown-1` prelude (`paged_stream`) has the same shape:
`collect-events` dispatches through a private helper that builds
`:server`/`:tool` from its argument, so inference cannot derive the
requirement, and under the validator's finite grant the export would be
filtered at exactly the stage that must call it.

## Finding: the mechanism already exists at HEAD

- The compiler reads per-defn attr-map metadata:
  `Map.get(spec.metadata, "requires")` at
  `lib/ptc_runner/lisp/prelude/compiler.ex:768`, shape-validated at
  `:1457`, unioned with inferred requirements at `:887`.
- The supported source shape is the attr-map between docstring and argvector:

  ```clojure
  (defn collect-events
    "Collect all events from a token-paged source."
    {:requires ["upstream:fixture/read_events"]}
    [source]
    ...)
  ```

  `test/ptc_runner/lisp/prelude/tool_requires_test.exs:173-177` covers
  exactly this: a dynamic `tool/call` proxy with explicit requires compiles
  to `requires == ["upstream:svc/op"]`.
- Attach enforces it fail-closed: `attach.ex:208`
  (`validate_dynamic_upstream_export`) rejects dynamic-`tool/call` exports
  with no explicit upstream requirements under finite grants, and
  `attach.ex:221` (`upstream_requirements/1`) is what explicit metadata
  satisfies. Grant matching itself is `check_upstream_grant` via
  `AttachContext`.
- Seed writes and runtime writes compile source through the same
  `compile_bounded` path (`lib/ptc_runner/prelude_store.ex:463`), so there
  is no seed/runtime asymmetry: inline requires works (in principle) for
  `--prelude-store-seed` files exactly as for `prelude/write`.
- The `.deps` sidecar (`mcp_server/lib/ptc_runner_mcp/application.ex:820`,
  writer at `lib/ptc_runner/prelude_store.ex:930`) carries
  `requires_preludes` refs only. **It should stay that way.** A sidecar or
  store-metadata channel for upstream requires would create a second truth
  not covered by the version checksum; the attr-map is part of the source
  and therefore part of the checksum, which is strictly better provenance.

The previously missing composition is now covered: seed directory → server
boot seed path → finite-grant role session → export visible, callable, and
correctly filtered. The regression seeds one marked namespace and one
unmarked control namespace, starts a root OpenAPI upstream runtime, and
asserts that the marked dynamic export is callable while the ungranted and
unmarked controls are projected out with legible reasons.

## Phase 0 — end-to-end spike (decision gate)

Outcome: passed in-tree via the Phase 2 regression test, using the existing
OpenAPI observatory fixture instead of the external bench fixture. Phase 1 is
not needed.

Copy the bench's `paged_stream.clj` seed, add
`{:requires ["upstream:fixture/read_events"]}` to `collect-events` and
`{:requires ["upstream:fixture/ungranted_events"]}` to `ungranted-control`.
Boot the mcp_server with `--prelude-store-seed` pointing at it, the fixture
MCP upstream configured, and a role config mirroring the bench's
`roles.json` validator (finite
`upstream_tools: ["upstream:fixture/read_events"]`,
`strict_transitive_calls: true`). Then, in a session under that role:

1. `collect-events` attaches, appears in `dir`/discovery, and is callable
   against the fixture (the finite grant matches its declared requirement).
2. `ungranted-control` is filtered, and the filter reason is legible via the
   HEAD grant-projection surface (not a bare `not a public export`).
3. Control: the same prelude *without* the attr-maps still filters
   `collect-events` under the finite grant (current fail-closed behavior,
   sanity that the spike is measuring the metadata and not a loosened
   filter).

Pass → skip Phase 1 entirely; the shakedown blocker is a bench-side seed
edit. Fail → Phase 1, and the failing seam is now precisely identified.

## Phase 1 — minimal fix (only if the spike fails)

Outcome: skipped. No implementation seam failed.

Fix at whichever seam broke, nothing wider. Candidate seams, in likelihood
order:

- attr-map parse at seed compile for the docstring + attr-map + argvector
  ordering (FormScanner / compiler metadata extraction);
- mcp_server wiring of role `upstream_tools` grants into the
  `AttachContext` for seeded (vs runtime-written) preludes;
- the discovery/`dir` projection honoring explicit requires where attach
  already does.

Each fix carries a regression test in the exact failing shape. Out of
scope regardless of outcome: extending `.deps` or store-candidate metadata
to carry per-export upstream requires (two-truths problem, above).

## Phase 2 — pin the contract with a seed-path test

Outcome: complete. The regression lives in
`mcp_server/test/ptc_runner_mcp/sessions_lifecycle_test.exs`, because the
behavior is session attach/projection/call behavior rather than application
argument parsing.

The test seeds a prelude whose public export has a docstring, an explicit
`{:requires ["upstream:observatory/list-traces"]}` attr-map, and a dynamic
`tool/call` in a `defn-` helper; it asserts attach + visibility + call under
the matching finite grant, and legible filtering both without the grant and
without the metadata. This is the same contract the autonomous shakedown
needs for `upstream:fixture/read_events`; it lives in the session suite, not
only as an observed bench outcome.

Verified with `cd mcp_server && mix test test/ptc_runner_mcp/sessions_lifecycle_test.exs`.

## Phase 3 — docs and pin hygiene

Outcome in this repo: docs updated. External bench pin/bundle work remains
bench-side.

- Commit the currently dirty planning docs (all five dirty paths are docs;
  no source is dirty).
- Rescope `future/dynamic-upstream-requirement-metadata.md`: its "explicit
  export metadata" shape is implemented and (after Phase 0/2) verified —
  link here and to the new test; what remains future is requirement
  metadata for genuinely runtime-computed dispatch.
- The bench then bumps `minimum_ptc_runner_commit` from `2c99c87c` to the
  new HEAD (docs + test commits, behavior-identical, but replay-at-pin
  wants tree == pin) and reruns Stage 0 preflight against the clean tree.

## Phase 4 — bench-side consequences (external repo, for the record)

In `ptc-bench-comparison`, in order, because the run bundle is
hash-sealed: add the two attr-maps to
`agent-runs/autonomous-shakedown-1-20260706/run/store-seed/paged_stream.clj`
→ add the callable-export / finite-grant projection probe to the Stage 0
preflight (the design requires it, and its absence is how demo 3 reached a
live model stage with an empty callable surface) → reseal the bundle →
rerun preflight at the new pin → evidence replay → launch Stage 2. The
pre-declared amendment path ("accept the finite-grant probe as the guard")
is retired: there is no longer a limitation for it to compensate for.

## Validation

Maps onto the Validation section of
`future/dynamic-upstream-requirement-metadata.md`, which this plan
discharges for the explicit-metadata shape:

- dynamic export with exact metadata attaches under the matching finite
  grant and is visible in discovery (Phase 0.1, Phase 2);
- the same export is absent/attach-fails under a finite grant lacking the
  operation (Phase 2);
- a dynamic export without metadata remains filtered under finite grants
  (Phase 0.3, Phase 2);
- broad grants keep working; turn metadata distinguishes broad-grant reach
  from fail-closed validation (existing behavior, re-asserted by the full
  suites in Phase 2).

## References

- `lib/ptc_runner/lisp/prelude/compiler.ex:768` — attr-map `requires` read;
  `:887` union with inferred; `:1457` shape validation.
- `lib/ptc_runner/lisp/prelude/attach.ex:208` — fail-closed dynamic-dispatch
  rule; `:221` upstream requirement extraction.
- `lib/ptc_runner/prelude_store.ex:463` — shared seed/runtime compile;
  `:930` `.deps` sidecar writer (prelude deps only).
- `mcp_server/lib/ptc_runner_mcp/application.ex:716` — seed entry point;
  `:820` sidecar read; `:800` seed metadata (whitelisted keys only).
- `test/ptc_runner/lisp/prelude/tool_requires_test.exs` — compile/attach
  coverage for explicit + inferred requires, including the dynamic-proxy
  shape.
- External: `ptc-bench-comparison`
  `agent-runs/autonomous-shakedown-1-20260706/` (run scaffold, roles,
  seed), `policies/gates/autonomous-shakedown-1.json` (pin, bundle seal).
