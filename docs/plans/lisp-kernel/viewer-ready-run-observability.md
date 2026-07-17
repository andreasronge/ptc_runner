# Viewer-ready run observability

Status: planned, not implemented. Created 2026-07-17.

This plan closes three gaps between the Kernel's frozen run model and the
developer experience exposed by `ptc_viewer` and `mix ptc.run`:

1. canonical run metadata will retain the safe component dependency graph that
   is already present in each frozen bundle;
2. the shipped `agent.core` annotation will use an exact closed vocabulary
   accepted by `PtcRunner.Kernel.SafeMetadata`; and
3. manifest execution will reject an occupied inspection destination before it
   performs provider discovery or spends model tokens.

The planned outcome is one trustworthy run-inspection path: a developer can see
which prelude components were frozen and how they depend on one another, read
real agent-action annotations without false protocol failures, and select an
inspection destination without discovering a no-clobber conflict after an
expensive run.

## Why this work is needed

The current implementation has all the underlying information, but loses or
rejects it at three different boundaries.

### Frozen dependency information stops before the trace

`PtcRunner.Kernel.Component` and `PtcRunner.Kernel.FrozenBundle` retain each
component's bounded dependency IDs. `PtcRunner.Kernel.Runner.trace_bundle/1`
and the equivalent REPL helper currently project a bundle to only
`component_ids` and the aggregate `hash`. The canonical `run-started` event
therefore cannot explain why a component is present or which components it
requires.

The Viewer already renders ordered component chips and its dependency renderer
recognizes the proposed `prelude.components: [{id, dependencies}]` shape. With
current traces that renderer has no edges to display, so the UI can show load
order but not the dependency graph that produced it. This makes prelude
diagnosis unnecessarily indirect, especially when a trusted library expands
to a transitive dependency closure.

### The shipped agent emits an annotation the Kernel rejects

`priv/preludes/kernel/agent.core.lisp` emits an `"agent-action"` annotation on
every turn. `PtcRunner.Kernel.SafeMetadata.annotation?/2` currently accepts
only `"progress"` with one enumerated stage. The annotation capability itself
works, but the shipped agent's call does not belong to its accepted vocabulary.

Each rejected call produces a failed `workflow-annotate` capability event and
charges one protocol error. As a result:

- the Viewer reports errors that are instrumentation defects rather than
  workflow failures;
- the promised `agent-action` event in the Kernel tutorial never appears;
- `usage.protocol_errors` is inflated once per agent turn; and
- a sufficiently long otherwise-valid run can consume its protocol-error
  budget because of shipped library behavior.

This is a correctness issue, not merely presentation polish. Developers must
be able to trust that Viewer error counts and Kernel usage describe the run
rather than an internal vocabulary mismatch.

### Inspection no-clobber failures arrive after expensive execution

`PtcRunner.Kernel.InspectionArtifact` correctly installs a new artifact with an
exclusive, atomic no-clobber operation. `PtcRunner.Kernel.RunBuilder` performs
that persistence only after `PtcRunner.Kernel.run/2` completes. When
`--inspect` names an existing path, the CLI may perform connector discovery,
run the workflow, and spend model tokens before returning
`:inspection_destination_exists`.

The atomic persistence check must remain authoritative because a destination
can appear after any preflight. An early read-only preflight is still valuable:
it catches the common deterministic conflict before the run acquires expensive
authority. The preflight improves cost and feedback latency without weakening
the no-clobber contract.

## Planned canonical prelude metadata

Each workflow and mission prelude in `run-started` will have this additive
shape:

```elixir
%{
  component_ids: [binary()],
  components: [
    %{
      id: binary(),
      dependencies: [binary()]
    }
  ],
  hash: binary() | nil
}
```

The following rules will apply:

- `components` uses the same frozen dependency-before-dependant order as
  `component_ids`.
- Every component entry contains exactly `id` and `dependencies`.
- Every dependency ID names another entry in the same prelude.
- A missing bundle produces empty `component_ids` and `components` plus a nil
  hash.
- Component source, compiled prelude values, origins, namespaces, and other
  private or unnecessary compilation data do not enter canonical events.
- Existing compiler bounds remain the authority: at most 128 components and
  512 dependency edges, with bounded component IDs. The ordinary
  `event_payload_bytes` limit remains the final event bound.

This is an additive V1 metadata field rather than a new trace schema version.
Previously persisted V1 traces without `components` remain readable and the
Viewer continues to show their ordered component chips without inventing
edges.

### Implementation work

1. Add failing Kernel and REPL tests that assert exact dependency projections
   in `run-started`.
2. Update both `trace_bundle/1` implementations to project only `id` and
   `dependencies` from `FrozenBundle.components`.
3. Verify `PtcRunner.Kernel.TraceLog` returns the complete nested prelude map
   through run metadata and uses an empty `components` list for its default.
   The current metadata extraction already preserves the nested map; this work
   should not introduce a second transformation model.
4. Add a Viewer integration/render test using a real canonical run rather than
   only a hand-edited metadata fixture.
5. Keep the component-chip fallback test for older traces without edges.

## Planned `agent-action` vocabulary

`PtcRunner.Kernel.SafeMetadata` will accept the exact normalized tool-boundary
shape emitted by `agent.core`:

```elixir
%{
  "turn" => 0..127,
  "kind" => "tool-call" | "protocol-error" | "provider-error",
  "reason" => nil | protocol_reason
}
```

Cross-field validation will keep the vocabulary closed:

- `"tool-call"` and `"provider-error"` require a nil reason.
- `"protocol-error"` requires one of the finite reasons currently produced by
  `agent.native/normalize`:
  `"invalid-response"`, `"assistant-text-with-tool-call"`,
  `"missing-tool-call"`, `"multiple-or-missing-tool-calls"`,
  `"wrong-tool-name"`, `"invalid-tool-call-id"`,
  `"invalid-json-arguments"`, `"extra-or-missing-arguments"`,
  `"program-not-string"`, `"program-empty"`, or
  `"program-too-large"`.
- No caller-defined annotation keys, kinds, reasons, or strings are accepted.
- The existing retained-size and encoded event-payload bounds continue to
  apply.

The implementation will extend the finite safe vocabulary rather than weaken
it. It will not restore arbitrary JSON annotations or allow prompts, generated
source, tool arguments, provider errors, or other application payloads into
canonical events.

### Implementation work

1. Add failing `SafeMetadata` tests for every accepted cross-field form and
   representative rejected extra keys, arbitrary values, negative/oversized
   turns, and private-marker attempts.
2. Add a shipped-agent integration test proving one turn emits
   `workflow-annotation` with `annotation_type: "agent-action"`.
3. Assert that the successful annotation capability stops with `status: "ok"`
   and does not increment `usage.protocol_errors`.
4. Retain the existing privacy probes proving arbitrary annotation content
   cannot enter EventSink JSON.
5. Update the tutorial evidence so its documented event sequence is exercised
   by the integration test.

## Planned inspection-destination preflight

`PtcRunner.Kernel.RunBuilder.run/3` will perform a read-only inspection
destination preflight before manifest/provider assembly when `:inspect` is
selected. Keeping the check in the shared runner protects the Mix task and
other manifest frontends consistently.

The preflight will:

- expand the destination exactly as the later inspection configuration does;
- apply the existing `.inspection.jsonl` path validation;
- use `File.lstat/1` so any existing directory entry, including a symlink or
  directory, is treated as occupied; and
- return a distinct pre-execution error that does not pretend a Kernel result
  exists.

The planned pre-execution error is:

```elixir
{:error, {:inspection_preflight_failed, reason}}
```

For the reported case, `reason` is `:inspection_destination_exists`. The
post-run persistence error continues to include the completed Kernel result,
because a race or later filesystem failure can still occur after execution.
The implementation must preserve the exclusive temporary-file and hard-link
installation in `InspectionArtifact.persist/3`; a preflight is never authority
to overwrite or assume the path remains free.

### Implementation work

1. Add a failing `RunBuilder.run/3` test with an occupied destination and a
   provider callback that would signal if invoked. Assert the callback is not
   invoked and no Kernel run events are created.
2. Add focused path tests for an existing regular file, symlink, and directory,
   plus an available valid destination.
3. Add the shared read-only destination check to `InspectionArtifact` and call
   it from `RunBuilder.run/3` before `load_and_build/3`.
4. Retain the post-run race test proving persistence still refuses a
   destination created after preflight.
5. Add a Mix task regression test proving `--inspect EXISTING` fails before a
   model/provider call and reports the preflight phase clearly.

## Non-goals

- Showing prelude source or compiled values in canonical traces or the Viewer.
- Adding a general dependency editor or changing bundle compilation.
- Accepting arbitrary workflow annotations.
- Adding `--force`, overwriting inspection artifacts, or weakening exclusive
  creation.
- Guaranteeing that a destination remains writable after preflight.
- Redesigning the CLI's complete diagnostic envelope; the broader stable CLI
  error contract remains product-readiness work.

## Delivery sequence

The work can land as three independently reviewable commits while preserving
one end-to-end outcome:

1. Correct the shipped `agent-action` vocabulary and usage accounting.
2. Emit and render canonical prelude dependency edges in Kernel and REPL runs.
3. Add the shared inspection-destination preflight while retaining atomic
   no-clobber persistence.

Each bug fix begins with its failing regression test. Viewer changes are
formatted and tested from `ptc_viewer/`; the root `mix precommit` gate and
`mix prepush` run after the complete slice.

## Acceptance gate

This plan is complete when all of the following are demonstrated:

- A real manifest run with trusted library dependencies exposes ordered
  `components: [{id, dependencies}]` in both the canonical `run-started` event
  and `TraceLog.list_runs` metadata.
- A REPL run emits the same prelude metadata shape.
- The Viewer renders actual dependency relationships from that run while an
  older V1 trace without edges still renders its ordered component list.
- A shipped `agent.core` turn emits one accepted `agent-action` annotation,
  its annotation capability succeeds, and it adds no protocol error.
- Arbitrary annotation keys and values remain rejected and private markers do
  not appear in canonical EventSink JSON.
- An occupied inspection destination is rejected before provider discovery,
  workflow execution, or model expenditure.
- A destination created after preflight is still rejected by atomic
  persistence and is never overwritten.
- Root and Viewer tests, `mix precommit`, and `mix prepush` pass.

## Documentation migration when implemented

This file is a disposable plan. Before deleting it after implementation:

- move the exact prelude metadata contract into
  `docs/trace-log-contract.md`, the Kernel maintainer guide, and the owning
  EventSink/TraceLog module documentation;
- document the closed `agent-action` vocabulary in `SafeMetadata`, the Kernel
  maintainer guide, and the tutorial;
- document inspection preflight and post-run race errors in
  `InspectionArtifact`, `RunBuilder`, and CLI user guidance; and
- update `ptc_viewer/README.md` to describe dependency rendering as current
  behavior rather than a future producer capability.

Remove this plan and its plans-index entry once those retained contracts and
their tests are in place.
