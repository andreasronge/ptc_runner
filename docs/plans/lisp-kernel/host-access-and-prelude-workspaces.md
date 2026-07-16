# Host access and prelude workspaces

Status: narrow 0.x local-inspection and read-only installed-prelude increments
are implemented. Authenticated host access and writable prelude workspaces
remain deferred. Reviewed 2026-07-16.

## Decision

Do not build shared IAM, a proposal/PR subsystem, or a prelude workspace service
before a concrete host product needs them.

For the current 0.x library:

- model authority remains the explicit frozen capability environment;
- the current local read-only Viewer remains local and read-only;
- shipped preludes remain repository files compiled into source-hashed frozen
  components;
- manifests may select an installed read-only shipped prelude dependency
  closure without creating a writable workspace;
- prelude changes use ordinary source edits, Git review, tests, and rebuilds;
- a host may explicitly capture one bounded private inspection artifact for a
  local development run and open that exact artifact in the local Viewer;
- the MCP connector uses its own small execution context and does not depend on
  shared host authorization; and
- no new generic host-resource vocabulary is added merely for future reuse.

This replaces the earlier H0-H2, G0, P0-P4, V1, and C-H0 delivery program. The
useful invariants remain below as design constraints for features that may be
earned later.

## Why defer

The previous plan combined three products:

1. shared authorization for humans, model runs, and services;
2. a versioned prelude authoring and promotion system; and
3. connector adoption of the same policy vocabulary.

None is required for the first external-tool journey. Implementing their shared
types first would leave the library at the least useful stopping point: a small
IAM framework and persistence design with no authenticated host workflow.

Local inspection is a different problem. The concrete pre-production journey
needs to compare the mission inventory sent to the model, the model's generated
program, connector calls, and evaluation results. A host-selected `0600`
artifact and loopback-only Viewer can satisfy that need without designing human
identity, grants, remote storage, or a writable prelude service.

PtcRunner is a 0.x library. It is cheaper to change one concrete service after
learning from use than to preserve abstractions designed around hypothetical
consumers.

## Current boundaries to preserve

The current code already has appropriate narrow boundaries:

- `Kernel.TraceLog` owns canonical trace validation and bounded queries.
- `Kernel.TraceCapability` projects selected trace queries into explicit Lisp
  capabilities.
- `ptc_viewer` adapts the same trace semantics for a local read-only UI.
- `Kernel.Library` loads shipped prelude source from repository files.
- compiled components and run environments are immutable.

The Viewer is not an authority source. A manifest cannot add executable host
callbacks. Moving a repository file or Git ref never mutates a running
environment.

## Near-term host access

There is no H0 milestone.

If an authenticated Viewer or host API becomes a real product requirement,
implement the smallest trace-specific boundary first:

```text
authenticated host session
        -> trace access context
        -> TraceService operation
        -> TraceLog
```

That first context should contain only what the TraceService needs: host-created
caller identity, exact installed trace source, permitted trace operations,
operation bounds, correlation ID, and audit sink. Browser JSON must not supply
or override any of those fields.

Do not generalize that context into `Principal`, `Grant`, `ScopedGrant`, role
expansion, or a universal `ResourceRef` registry yet. If a second concrete
domain service later needs the same semantics, compare the two implementations
and extract the smallest shared vocabulary supported by both.

The first authenticated TraceService must still prove:

- exact source confinement and bounded results;
- equivalent results for equivalent host-resolved access, regardless of
  whether the adapter is a UI or model capability;
- private source captured and authorized separately from sanitized traces;
- stable redacted errors and audit records; and
- no browser-selected paths, roles, grants, or sensitive capture mode.

Cryptographic grant attestation, remote audit delivery, policy engines, and
general role management require a real remote or hostile boundary. They are
not library prerequisites.

## Local developer inspection

The absence of H0 does not block a narrow local observability feature. The
current private event policy contains the same sanitized canonical events as
the normal policy; it is not exact-source capture.

This feature is the sensitive inspection plane defined by the TraceLog
contract. It does not replace OTP Logger, turn canonical events into Telemetry
spans, or introduce a second run-trace format. Logger and Telemetry receive no
inspection payload. The canonical event stream supplies run structure and
correlation IDs; the sidecar supplies only the explicitly captured private
records joined through those IDs.

A host-opt-in 0.x increment correlates subordinate evaluations with source
hashes and byte counts in canonical events while storing exact sensitive
development data in a separate bounded `0600` inspection artifact. Trace
queries, including queries over private canonical files, never return that
artifact's payloads.

The artifact is a distinct `.inspection.jsonl` record stream, not another
canonical trace policy. It contains only records needed to diagnose the
pre-production journey:

- the exact normalized LLM request submitted by the workflow, including system
  text, messages, tool schema, and frozen mission inventory;
- the normalized LLM response returned to the workflow, including the
  `run_ptc_lisp` tool call;
- the exact bounded subordinate PTC-Lisp source plus its hash and byte count;
- connector capability arguments and normalized result or error; and
- run, capability, and evaluation identifiers needed to join those records to
  the sanitized canonical trace.

The inspection stream does not add transport headers, connector credentials,
session IDs, arbitrary BEAM terms, or the MCP endpoint. Capability arguments
and results are application payloads and may themselves be sensitive, which is
why the entire artifact is private. The stream also does not need complete
workflow entry source or exact prelude source: the LLM request shows the prompt
inventory the model actually received, while the canonical run summary supplies
the effective workflow/mission component IDs and hashes.

Capture is disabled by default and cannot be enabled by a manifest or Lisp
value. The CLI/host selects an exact destination, creates or restricts it to
`0600` before writing, and applies per-record and aggregate byte ceilings. The
initial implementation has two modes only: disabled, or required/fail-closed.
It may retain bounded records in memory and persist them with the completed
canonical trace; crash-durable streaming is production work.

Use one optional `Kernel.InspectionSink` owner rather than connector-specific
observer hooks. `RunBuilder` starts the canonical event sink early, obtains its
run/trace identity through a bounded read API, and starts the inspection sink
with the same identity when the host requested capture. `RunConfig` carries the
optional sink. `Dispatcher` records capability arguments and normalized
results/errors under its existing capability ID, while `Evaluation` records the
exact bounded source under its existing evaluation ID. This captures LLM, file,
native, and MCP calls uniformly. The sink is stopped only after `RunBuilder` has
persisted the completed inspection artifact; build failure and REPL closure stop
it through the same explicit configuration cleanup path.

Do not add a generic logging facade or make `InspectionSink` a Logger backend or
Telemetry handler. Its fail-closed retention and authorization contract is
run-owned and explicit; operator log configuration must not change it.

The minimal public/internal seam is intentionally small:

- `EventSink.identity/1` returns only `run_id` and `trace_id` to the holder of
  the sink token;
- `RunConfig.inspection_sink` is either `nil` or the required sink owner;
- `InspectionSink.emit/4` accepts one V1 record type, one exact correlation
  map, and one JSON-like payload, assigning sequence and timestamp itself;
- `InspectionSink.records/1` returns retained records only to the holder; and
- `InspectionSink.stop/1` is idempotent.

Dispatcher and Evaluation receive the optional sink explicitly from
`RunConfig`; capability callbacks do not receive a logging object. This is
enough to capture all current capability types uniformly and avoids a general
observer/plugin API.

Normal `TraceLog` file and directory discovery must reject or omit
`.inspection.jsonl`, just as it already isolates `.private.jsonl`. No `log/`
capability can read inspection records.

### Local Viewer path

The same increment adds an explicit local-only Viewer mode, for example:

```console
mix ptc.run ptc.json --trace traces/run.jsonl --inspect traces/run.inspection.jsonl
mix ptc.viewer --trace-dir traces --inspection-file traces/run.inspection.jsonl
```

The host process fixes the exact inspection file; the browser cannot select a
server-side path or enable capture. The Viewer binds to loopback, rejects
symlinks and changed/oversized files, verifies that the requested run ID occurs
in the fixed artifact, and displays a persistent sensitive-data warning. Its
inspection endpoint is separate from the canonical `TraceLog` query API.

This is not an authenticated Viewer service, directory-wide private discovery,
or a general private-data API. It is a read-only local diagnostic for an
explicit artifact. Remote binding, multiple users, arbitrary private sources,
and cross-user policy still require a real host product and the trace-specific
access context described above.

If automated historical diagnosis later needs source, the host may install one
explicit read-only capability for completed source records. Frozen environment
membership supplies model authority; it does not require shared principals or
grants. Model access to inspection records, authenticated remote Viewer access,
cross-user policy, and audit presentation remain deferred until a host
application exists.

Same-run correction should retain the exact bounded prior program directly in
the provider-valid assistant/tool/result history. A workflow should not query
its own changing trace to recover data it already possesses.

## Read-only installed prelude selection

Manifest selection of shipped preludes is not a writable workspace. Before the
connector developer journey, add one small read-only path that resolves IDs
only from `Kernel.Library`, expands their declared dependency closure, and sends
the resulting ordinary components through the existing compiler.

The existing `workflow.components` and `mission.components` arrays accept this
strict tagged union without adding another manifest section:

```json
{"id": "workflow.main", "path": "workflow.lisp", "dependencies": ["agent.core"]}
{"library": "agent.core"}
```

A local entry accepts exactly `id`, `path`, and optional `dependencies`; an
installed entry accepts exactly `library`. The library value is a
`Kernel.Library` component ID, not a repository, path, URL, Git ref, version, or
replacement source. Repeating one explicit library selection is invalid;
transitive occurrences coalesce. Dependency expansion is deterministic with
dependencies before dependants and lexical component-ID tie breaking. Any
local/installed ID collision, missing dependency, or dependency cycle fails
assembly before compilation. This is an additive manifest-version-1 form.

The compiled bundle remains immutable and source hashed. Canonical run metadata
records its selected component IDs and aggregate hash. The model-facing agent
inventory is rendered from the frozen mission bundle's
`Prelude.prompt_exports/1` plus model-visible capability metadata; this uses the
implemented prelude visibility contract rather than copying full source into a
prompt.

Use one explicit workflow-only reserved route, `kernel-mission-inventory`, to
make that already-rendered bounded text available to `agent.core`. The route is
closed over the frozen mission environment and carries metadata only; it cannot
invoke or transfer mission capabilities. Add a small `kernel/mission-inventory`
wrapper to the shipped prelude and have `agent.core` append its result to the
domain-blind system instructions. Normal runs and `ReplSession` assemble the
same route. Do not add a mutable prompt registry or let the manifest supply the
inventory text.

The inventory renderer has one versioned normalized input so tests can compare
what the model saw without comparing prose assembled in several modules:

```json
{
  "schema_version": 1,
  "exports": [
    {"ref": "fs/read", "kind": "function", "call": "(fs/read path)",
     "doc": "...", "effect": "read", "contract": null}
  ],
  "capabilities": [
    {"name": "file-read", "description": "...", "effect": "read",
     "input_schema": {}, "output_schema": null}
  ],
  "limits": {
    "evaluation_timeout_ms": 1000,
    "subordinate_source_bytes": 131072,
    "mission_capability_calls": 128,
    "mission_capability_calls_per_name": 32,
    "capability_argument_bytes": 262144,
    "capability_result_bytes": 1000000
  }
}
```

Arrays are sorted by `ref` and `name`; object keys are emitted in the order
shown, while embedded schemas use the connector contract's recursive
deterministic JSON ordering; nullable fields remain present. Exports come only from
`Prelude.prompt_exports/1`, and capabilities only from model-visible mission
metadata. The host renders this normalized object as compact UTF-8 JSON,
computes a lower-case SHA-256 hash over those exact rendered bytes, and fails
assembly rather than truncating if it exceeds an installed 256 KiB ceiling.
`run-started` records only `mission_inventory_hash` and
`mission_inventory_bytes`; the complete inventory appears in the captured LLM
request when inspection is enabled. `kernel-mission-inventory` returns the
rendered text, not the mutable source object.

The first connector lab runs the same domain-neutral task with a direct
capability inventory and with a small wrapper prelude. The private inspection
artifact makes the exact difference in model-visible input reviewable, while
the canonical trace proves which immutable components were active.

Acceptance tests use one golden normalized inventory and assert byte-for-byte
rendering, hash stability, sort order, hidden-export/capability exclusion,
installed ceiling failure, deterministic library dependency expansion,
explicit-selection duplication failure, and local/installed ID collision.

## Near-term prelude workflow

There is no PtcRunner proposal inbox, PR handoff adapter, candidate repository,
or runtime promotion service in the 0.x roadmap.

The supported development workflow remains:

1. edit a prelude source file in the repository;
2. run the canonical compiler and repository quality gates;
3. review and merge through the repository's normal Git workflow; and
4. rebuild so later runs receive the new source-hashed component.

This is intentionally outside the runtime API. Git already supplies history,
diffs, review, and atomic ref updates for maintainers. PtcRunner should not wrap
those facilities until a non-maintainer or runtime workflow needs a product
surface.

No running environment observes the edit or merge. A later explicit build
compiles a new frozen component; compilation failure produces no runnable
replacement.

## Trigger for a writable prelude feature

Start a new implementation plan only when at least one concrete workflow needs
more than repository editing, for example:

- a model must submit a change during a run for later human review;
- an authenticated operator who is not a repository maintainer must author a
  change;
- a deployment must activate a revision without a normal code rebuild; or
- prelude state must live outside Git.

Begin with the smallest workflow that satisfies that demand. For model
submission, that may be a single host callback accepting complete bounded
source plus the current base source hash and returning a validated immutable
record. It need not immediately imply a generic repository, Viewer editor,
draft state machine, diff service, or runtime promotion.

Only persist or expose fields required by the workflow. Likely invariants are:

- complete source and canonical source hash;
- exact base identity and stale-base rejection;
- canonical validation/compilation before accepting the record;
- host-created provenance and correlation;
- bounds, idempotency, cancellation, redaction, and retention; and
- activation only for later environments.

These are constraints, not a committed struct or module layout.

## Trigger for a workspace service

A full workspace becomes justified only by demonstrated demand for iterative
server-side editing, concurrent candidates, authenticated browser authoring,
runtime promotion, non-Git durability, or richer history queries.

If built, preserve these invariants:

- promoted revisions are immutable and content hashed;
- candidate updates use optimistic concurrency;
- validation and compilation use the canonical compiler;
- promotion compares the exact candidate and base in one atomic operation;
- source read, candidate write, and promotion are separately authorized;
- model policy does not include promotion by default;
- owner-process state changes use one atomic operation; and
- promotion affects only later explicitly rebuilt environments.

Repository, UI, CLI, and authorization contracts should be designed from that
real workflow, not copied from these notes.

## Connector relationship

The first MCP connector remains independent. Its authority is structural:

```text
host-supplied source registry
        ∩ installed tool mappings and ceilings
        ∩ manifest narrowing
        ∩ destination rules
        ∩ frozen environment membership
```

Its context carries destination, owner, and lifecycle data, not shared IAM.

If an authenticated human or service later needs to use the same connector
source, first expose one source-specific host service. Shared authorization is
extracted only if that service and TraceService (or another real service)
actually share stable semantics. Discovered remote tools remain explicit
frozen capabilities rather than universal IAM resources.

## What remains deferred

- universal `Principal`, `Grant`, `Bounds`, `ScopedGrant`, and `ResourceRef`
  structs;
- role expansion and model delegation templates;
- a shared audit subsystem beyond domain-owned bounded audit records;
- authenticated or remotely bound Viewer sessions and directory-wide
  private-source UI;
- effective-prelude source capture, proposal storage, and Git/PR automation;
- prelude candidates, workspaces, promotion APIs, and Viewer editing;
- connector adoption of shared host grants; and
- inbound HTTP or MCP frontends.

Deleting these from the 0.x roadmap is not a decision against them. It is a
decision to obtain a real consumer before fixing their public shape.

## Decision gates

Before starting a deferred feature, record:

1. the exact user journey that current repository or local-Viewer workflows
   cannot satisfy;
2. the smallest domain service needed for that journey;
3. its trust boundary and who constructs caller identity;
4. which data is sensitive and how errors/audit are redacted;
5. its concurrency, cancellation, and persistence invariants; and
6. which existing second consumer justifies any shared abstraction.

## Related documents

- [`kernel-maintainer.md`](../../guides/kernel-maintainer.md) — current Kernel
  authority and ownership model.
- [`tracelog-contract.md`](tracelog-contract.md) — current canonical trace
  contract.
- [`capability-connectors.md`](capability-connectors.md) — active MCP-first
  external-tools and developer-validation plan.
- [`product-readiness.md`](product-readiness.md) — active roadmap and deferred
  product work.
