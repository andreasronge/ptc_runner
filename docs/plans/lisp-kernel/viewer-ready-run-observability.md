# Viewer-ready run observability

Status: planned, not implemented. Created 2026-07-17; revised 2026-07-17 after
boundedness and ownership review.

This plan closes three gaps between the Kernel's frozen run model and the
developer experience exposed by `ptc_viewer` and `mix ptc.run`:

1. canonical run metadata will retain a compact, bounded dependency graph for
   each frozen prelude;
2. the shipped `agent.core` annotation will use an exact coarse vocabulary
   accepted by `PtcRunner.Kernel.SafeMetadata`; and
3. manifest execution will reject an unusable inspection destination after
   input validation but before provider discovery or model expenditure.

The planned outcome is one trustworthy inspection path: a developer can see
which prelude components were frozen and how they depend on one another, read
real agent-action annotations without false protocol failures, and discover a
common no-clobber conflict before an expensive run begins.

## Why this work is needed

The current implementation has the required information and safety machinery,
but loses or rejects useful facts at three boundaries.

### Frozen dependency information stops before the trace

`PtcRunner.Kernel.Component` and `PtcRunner.Kernel.FrozenBundle` retain each
component's bounded dependency IDs. `PtcRunner.Kernel.Runner.trace_bundle/1`
and the equivalent REPL helper currently project a bundle to only
`component_ids` and the aggregate `hash`. The canonical `run-started` event
therefore cannot explain why a component is present or which components it
requires.

The committed Viewer baseline can show the ordered component IDs and bundle
hash, but it does not implement a dependency renderer. Renderer implementation
and validation are part of this plan; the plan must not rely on behavior that
exists only in a local worktree or hand-edited fixture.

The initially considered readable representation duplicated IDs in
`components: [%{id: id, dependencies: ids}]`. At the existing maxima of 128
components and 512 edges in each of the workflow and mission bundles, a probe
measured approximately 206,245 encoded JSON bytes and 335,080 retained bytes.
`PtcRunner.Kernel.EventSink` enforces retained size, and the default
`event_payload_bytes` is 262,144. That shape could silently drop `run-started`
under normal policy or fail a private-policy run before execution.

The graph therefore needs an index representation that stores every component
ID once. A maximum projection for both bundles measured approximately 74 KB
retained. Compactness alone is not enough: manifests may request a lower event
payload ceiling, and labels, inventory fingerprints, and connector snapshots
share the same `run-started` payload. Successful assembly must validate the
complete static payload before execution so the graph is never silently
omitted.

### The shipped agent emits an annotation the Kernel rejects

`priv/preludes/kernel/agent.core.lisp` emits an `"agent-action"` annotation on
every turn. `PtcRunner.Kernel.SafeMetadata.annotation?/2` currently accepts
only `"progress"` with one enumerated stage. The annotation capability itself
works, but the shipped agent's call does not belong to its accepted vocabulary.

Each rejected call produces a failed `workflow-annotate` capability event and
charges one protocol error. As a result:

- the Viewer reports errors caused by instrumentation rather than the run;
- the promised `agent-action` event in the Kernel tutorial never appears;
- `usage.protocol_errors` is inflated once per agent turn; and
- a sufficiently long otherwise-valid run can consume its protocol-error
  budget because of shipped library behavior.

Copying every detailed `agent.native/normalize` reason into `SafeMetadata`
would fix the immediate defect but create a lockstep maintenance boundary
between PTC-Lisp and Elixir. A new correction reason could silently recreate
the failure. The canonical annotation needs only stable coarse action state;
the exact correction reason remains available to the agent and, when enabled,
through private inspection.

### Inspection no-clobber failures arrive after expensive execution

`PtcRunner.Kernel.InspectionArtifact` correctly installs a new artifact with an
exclusive, atomic no-clobber operation. `PtcRunner.Kernel.RunBuilder` performs
that persistence only after `PtcRunner.Kernel.run/2` completes. When
`--inspect` names an existing path, the CLI may perform connector discovery,
run the workflow, and spend model tokens before returning
`:inspection_destination_exists`.

The atomic persistence check must remain authoritative because a destination
can appear after preflight. A read-only preflight still catches common
deterministic path conflicts before provider builders run. It must follow
manifest loading and input override so a bad output path does not mask a more
useful manifest or input error.

## Planned assembly order

The manifest-backed execution path will use this order:

```text
load and validate manifest
→ apply input override
→ normalize and preflight inspection destination
→ build bundles and providers
→ build and size-check complete run-started metadata
→ execute run
→ perform authoritative atomic persistence
```

The preflight prevents provider builders—including MCP discovery—from running
for a known destination conflict. The full metadata check prevents either
EventSink policy from discovering a static `run-started` overflow only after
run state has started.

## Compact canonical prelude metadata

Each workflow and mission prelude in `run-started` will have this additive
shape:

```elixir
%{
  component_ids: ["kernel", "llm", "agent.core"],
  dependency_indices: [
    [],
    [],
    [0, 1]
  ],
  hash: "..."
}
```

`dependency_indices` is positionally aligned with `component_ids`. The list at
position `i` contains the indexes of that component's direct dependencies.

The following rules will apply:

- `component_ids` uses the frozen dependency-before-dependant order.
- Component IDs are unique.
- `dependency_indices` has exactly the same length as `component_ids`.
- Every dependency list contains unique, ascending integers.
- Every dependency index at position `i` is greater than or equal to zero and
  less than `i`; forward references and cycles are impossible.
- A missing bundle produces empty `component_ids` and `dependency_indices`
  plus a nil hash.
- Prelude source, compiled values, origins, namespaces, and other compilation
  data do not enter canonical events.
- Existing compiler maxima remain the graph authority: 128 components and 512
  edges per bundle, with bounded component IDs.

This is an additive V1 metadata field rather than a new trace schema version.
Previously persisted V1 traces without `dependency_indices` remain readable
and render as ordered component chips without invented edges.

### One owner for projection and run-start metadata

The compact projection will have one owner, planned as the internal function
`PtcRunner.Kernel.FrozenBundle.trace_metadata/1`. It will derive and validate
the aligned ID/index representation. Runner and REPL will not retain separate
private graph transformations.

A shared internal run-start metadata builder will compose labels, both prelude
projections, mission inventory fingerprints, and connector snapshots. It will
measure the complete payload with the same retained-size rule as EventSink
against the selected `event_payload_bytes` limit. Runner and REPL will emit the
already-validated payload rather than reconstructing it independently.

If the complete static payload cannot fit, configuration assembly will return
the stable error `:run_started_metadata_exceeded`. EventSink remains the final
runtime authority, but a successful build cannot knowingly begin with a
`run-started` payload that its configured sink must reject.

### Implementation work

1. Add failing projection tests for empty, ordinary, and maximum component
   graphs, including exact index alignment and earlier-index invariants.
2. Add `FrozenBundle.trace_metadata/1` as the only safe graph projection.
3. Replace both private `trace_bundle/1` implementations with the shared
   run-start metadata builder.
4. Add build-time validation of the complete static payload and the stable
   `:run_started_metadata_exceeded` error.
5. Verify `PtcRunner.Kernel.TraceLog.query/3` with `:list_runs` returns the
   complete nested prelude map without inventing missing
   `dependency_indices`; the Viewer owns legacy chip fallback.
6. Test the maximum complete payload through both normal and private EventSink
   policies. Both must retain `run-started` after successful assembly.
7. Test a deliberately narrower event ceiling. Both policies must receive the
   same assembly error; normal policy must not silently omit `run-started`.

## Planned Viewer graph contract

The Viewer will implement the dependency renderer as part of this slice. It
will treat canonical input as untrusted even when TraceLog has accepted the
generic event envelope.

The Viewer will render a graph only when:

- `component_ids` is an array of unique strings;
- `dependency_indices` is an array of the same length;
- every dependency list contains unique integers; and
- every index is non-negative and less than the current component position.

Missing or malformed graph metadata falls back to the ordered component chips.
The Viewer must not partially render invalid edges, reorder supplied IDs, infer
unknown dependencies, or reject the complete run solely because optional graph
metadata is malformed.

### Implementation work

1. Implement the compact dependency renderer in the committed Viewer code.
2. Add focused renderer tests for valid graphs and each malformed condition.
3. Keep a legacy V1 fixture without `dependency_indices` and assert chip
   fallback.
4. Add a malformed V1 fixture and assert the same safe fallback.
5. Add a real-run integration fixture produced by Kernel/TraceLog rather than
   only hand-editing Viewer metadata.
6. Ensure fixture component IDs use the exact frozen order and every dependency
   points to an earlier component.

## Planned `agent-action` vocabulary

`PtcRunner.Kernel.SafeMetadata` will accept the exact coarse tool-boundary shape
emitted by `agent.core`:

```elixir
%{
  "turn" => 0..127,
  "kind" => "tool-call" | "protocol-error" | "provider-error"
}
```

The map contains exactly those two keys. It carries no detailed reason,
provider error, tool call, generated program, or caller-defined value. The
existing retained-size and encoded event-payload bounds continue to apply.

`agent.core` will omit `reason` from its annotation while retaining the
detailed reason in its local action for correction feedback. This avoids a
duplicated reason enum across `agent.native` and `SafeMetadata` without
weakening the useful distinction between tool, protocol, and provider actions.

### Implementation work

1. Add failing `SafeMetadata` tests for the three accepted kinds and
   representative rejected extra keys, arbitrary kinds, negative/oversized
   turns, detailed reasons, and private-marker attempts.
2. Add end-to-end table tests that route tool-call, protocol-error, and
   provider-error results from `agent.native/normalize` through
   `workflow.event/annotate`.
3. Assert every annotation capability stops with `status: "ok"` and the
   annotation itself does not increment `usage.protocol_errors`.
4. Retain existing privacy probes proving arbitrary annotation content cannot
   enter EventSink JSON.
5. Update the tutorial evidence so its documented event sequence is exercised
   by the shipped-agent integration test.

## Planned inspection-destination preflight

After manifest loading and input override, `PtcRunner.Kernel.RunBuilder.run/3`
will normalize and preflight `:inspect` before invoking any provider builder.
Keeping the check in the shared runner protects the Mix task and other manifest
frontends consistently.

The read-only check will use the same path rules as later persistence and
classify outcomes as follows:

| Condition | Preflight result |
| --- | --- |
| non-binary path, invalid suffix, or otherwise invalid path | `:invalid_inspection_path` |
| `File.lstat/1` returns `{:ok, _}` for a file, symlink, or directory | `:inspection_destination_exists` |
| `File.lstat/1` returns `{:error, :enoent}` | available; continue |
| `File.lstat/1` returns another error | `:inspection_destination_unavailable` |

Preflight errors use the pre-execution envelope:

```elixir
{:error, {:inspection_preflight_failed, reason}}
```

A nonexistent or unwritable parent may still pass this narrow read-only check
and fail during post-run persistence. The plan does not promise that a path
that was free remains creatable. A destination can also appear after preflight.
For those cases, the existing post-run persistence error continues to include
the completed Kernel result.

The implementation must preserve exclusive temporary-file creation and the
hard-link no-clobber installation in `InspectionArtifact.persist/3`. Preflight
never authorizes overwrite and never replaces the atomic check.

### Implementation work

1. Split manifest loading/input override from provider construction so the
   preflight fits between them without duplicating frontend logic.
2. Add focused path tests for invalid paths, an existing regular file, symlink,
   directory, `:enoent`, and other `lstat` failures.
3. Add a `RunBuilder.run/3` test with a valid manifest, occupied destination,
   and provider builder that signals immediately if invoked. Assert the builder
   is not invoked; testing only a later capability callback is insufficient.
4. Add precedence tests proving an invalid manifest or input override is
   reported before an occupied inspection destination.
5. Retain the post-preflight race test proving atomic persistence rejects a
   destination created later and never overwrites it.
6. Add a Mix task regression proving `--inspect EXISTING` reports the preflight
   phase without provider discovery or model expenditure.

## Non-goals

- Showing prelude source or compiled values in canonical traces or the Viewer.
- Adding a separate graph API or chunked graph events.
- Adding a general dependency editor or changing bundle compilation.
- Accepting arbitrary workflow annotations or detailed correction payloads.
- Adding `--force`, overwriting inspection artifacts, or weakening exclusive
  creation.
- Guaranteeing that a destination remains writable after preflight.
- Redesigning the CLI's complete diagnostic envelope; the broader stable CLI
  error contract remains product-readiness work.

## Delivery sequence

The work will land in this order:

1. Correct the shipped coarse `agent-action` vocabulary and usage accounting.
2. Add inspection preflight after manifest/input validation and before provider
   construction.
3. Add the compact graph projection and complete `run-started` size validation
   under one owner.
4. Implement strict Viewer graph validation, real-run rendering, and legacy or
   malformed-input fallback.
5. Exercise maximum graph bounds under both EventSink policies.

Each bug fix begins with its failing regression test. Viewer changes are
formatted and tested from `ptc_viewer/`; root `mix precommit` and `mix prepush`
run after the complete slice.

## Acceptance gate

This plan is complete when all of the following are demonstrated:

- A real manifest run with trusted library dependencies exposes aligned
  `component_ids` and `dependency_indices` in canonical `run-started` and in
  `PtcRunner.Kernel.TraceLog.query/3` with `:list_runs`.
- A REPL run emits the exact same metadata projection from the shared owner.
- A maximum graph plus the rest of the static `run-started` payload is retained
  under both normal and private policies after successful assembly.
- A configured event ceiling below the complete static payload produces
  `:run_started_metadata_exceeded` before execution under either policy; normal
  policy never silently loses the lifecycle start.
- The Viewer renders dependency relationships from a real run whose edges all
  point backward in frozen order.
- Legacy metadata without indices and malformed graph metadata both fall back
  to ordered chips without misleading edges or loss of the run.
- Tool-call, protocol-error, and provider-error agent outcomes each emit an
  accepted coarse `agent-action`; annotation capability calls succeed and add
  no protocol errors.
- Arbitrary annotation keys and values remain rejected and private markers do
  not appear in canonical EventSink JSON.
- Invalid manifest and input errors take precedence over inspection preflight
  errors.
- An occupied inspection destination is rejected before its provider builder,
  workflow, or model can run.
- A destination created after preflight is still rejected by atomic
  persistence and is never overwritten.
- Root and Viewer tests, `mix precommit`, and `mix prepush` pass.

## Documentation migration when implemented

This file is a disposable plan. Before deleting it after implementation:

- move the compact prelude metadata and complete-payload bound into
  `docs/trace-log-contract.md`, the Kernel maintainer guide, and the owning
  FrozenBundle/EventSink/TraceLog module documentation;
- document strict graph validation and fallback in `ptc_viewer/README.md`;
- document the closed coarse `agent-action` vocabulary in `SafeMetadata`, the
  Kernel maintainer guide, and the tutorial;
- document inspection preflight ordering and post-run race errors in
  `InspectionArtifact`, `RunBuilder`, and CLI user guidance; and
- replace any fixture-only claims with evidence from the canonical Viewer API
  and renderer.

Remove this plan and its plans-index entry once those retained contracts and
their tests are in place.
