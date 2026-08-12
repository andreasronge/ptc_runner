# Named mission environments (#1237)

Branch: `codex/issue-1237-named-missions`.

This plan replaces the historical singular mission environment with named,
independent mission environments. It is based on current `origin/main` and
uses `spike/mission-spaces` only as evidence: the spike proved environment,
continuation, prompt, and authority partitioning, but predates the current FIFO
evaluation admission queue, workflow model routing, effective-application
identity, inspection V3, stable command envelope, and provider preparation
pipeline. It is not a merge candidate.

## Observable change

One application run declares zero to sixteen missions. Each declared mission
owns one compiled component bundle, one data map, one direct grant selected
from the run-wide `providers.mission` pool, one full inventory and compact model
context, and one continuation. Workflow code selects a mission by name for
evaluation, checking, and inventory access. Omission selects the explicitly
declared `default`; it never selects the first mission and never creates an
implicit empty mission.

The production cutover is complete and breaking:

- manifest `mission` is removed and `missions` is the only accepted shape;
- `RunConfig.mission_environment` / `mission_inventory` become one sorted
  mission map;
- `PreparedRun.mission_bundle` and every downstream singular bundle identity
  become sorted mission bundle maps;
- existing Kernel Lisp functions keep their names and select `default`, while
  new `*-in` functions carry an explicit mission;
- `agent.core` accepts `mission` independently of `model` and uses it for both
  prompt rendering and generated-code evaluation;
- canonical evidence uses `mission_name`, never `space` and never an
  agent-invocation attribution.
- the stable command envelope advances to V2 rather than silently changing its
  closed V1 shapes; Mix, standalone, launcher, fixtures, and generated schemas
  cut over together.

The reader/writer example is a real workflow with two agent loops: a read-only
reader mission and a write-authorized writer mission, each with distinct
components, data, prompt-visible API, task capabilities, and continuation. The
workflow alone orchestrates the handoff.

## Explicit non-goals

- No mission calls another mission or the workflow; handoff is workflow-owned.
- No mission receives model authority; model routing remains workflow-only and
  orthogonal to mission selection.
- No concurrent evaluation leases are introduced. Current FIFO admission and
  one run-wide lease remain authoritative.
- No per-mission spend budget or agent identity is invented. Run budgets remain
  shared; retained continuation bytes obey both selected-mission and run-wide
  ceilings.
- No mission REPL selector is added (#1239). A manifest-backed workflow REPL
  receives all declared mission routes, but direct attachment to one mission is
  separate work.
- No compatibility parser, deprecated singular field, implicit default, or
  fallback from an unknown name is retained in this 0.x library.

## Public contract

### Manifest and grants

`missions` is optional and may be `{}`. Mission names use
`^[a-z][a-z0-9._-]{0,127}$`. Each value is a closed object with optional
`components`, `data`, and `providers`; omitted values mean empty components,
empty data, and no direct task-provider grant. `providers.mission` remains the
unique run-wide acquisition pool. A mission grant is a unique list of at most
32 aliases, every alias naming exactly one occurrence in that pool.

Provider acquisition still computes and acquires the complete internal service
dependency closure. Capability exposure is partitioned from the directly named
occurrences only: a dependency provider's services may be used to build a
granted provider, but its task capabilities are absent unless that alias is
also directly granted to the mission.

Migration is explicit:

```json
"mission": {"components": [{"library": "agent.tools"}]},
"providers": {"mission": [{"name": "notes_read"}]}
```

becomes:

```json
"missions": {
  "default": {
    "components": [{"library": "agent.tools"}],
    "providers": ["notes_read"]
  }
},
"providers": {"mission": [{"name": "notes_read"}]}
```

Every shipped agent manifest that relied on the old implicit mission declares
`"missions": {"default": {}}`; workflow-only applications may omit it.

### Bounds and phase order

The loader/preparer enforces bounds at the first phase where their input exists:

1. Decode and structurally normalize every mission and component/provider
   selection without reading local component source. Reject more than 16
   missions, invalid/duplicate names, unknown or duplicate provider aliases,
   more than 32 grants per mission, more than 128 component occurrences, or
   more than 512 direct dependency edges across the expanded mission bundles.
2. Materialize components through the existing bounded `ApplicationSource`.
   Increment the aggregate source count per mission occurrence and refuse above
   2,000,000 bytes before compilation. Reusing one component in two missions
   counts twice.
3. Compile the required workflow bundle and each mission bundle in sorted name
   order under one 5,000 ms aggregate compilation deadline, passing the bounded
   absolute deadline through the complete `BundleCompiler` call. Main workers
   clamp to the remaining budget and failure-span resolution clamps or is
   skipped when that budget is exhausted. Retain the existing per-bundle
   ceilings without allowing their timeouts to multiply by seventeen. After
   every compile, add the
   existing `:erlang.external_size/1` bundle measurement and refuse an aggregate
   above 4,000,000 bytes before provider declaration or acquisition.
4. Declare/acquire providers only after every bundle passes. Build each mission
   environment and inventory, adding rendered full bytes and compact model bytes
   independently. Refuse either aggregate above 256 KiB before `run-started` or
   evaluation. On an acquired-build inventory error, close the provider session
   through the existing cleanup path and emit no canonical event.
5. The assembled `run-started` payload and private inspection artifact remain
   subject to their existing exact byte ceilings; no evidence is truncated to
   force acceptance.

The manifest refactor separates component declaration validation from source
materialization so structural aggregate failures provably precede reads. The
bundle compiler exposes the same artifact measurement it already enforces so
the coordinator can add it without duplicating size logic.

### Kernel and agent API

Existing wrappers select `default`:

```clojure
(kernel/eval program)
(kernel/eval-source source)
(kernel/eval-with program params)
(kernel/eval-source-with source params)
(kernel/check-source source)
(kernel/mission-inventory)
(kernel/mission-model-context)
```

Named wrappers are explicit because PTC-Lisp `defn` has no multi-arity:

```clojure
(kernel/eval-in mission program)
(kernel/eval-source-in mission source)
(kernel/eval-with-in mission program params)
(kernel/eval-source-with-in mission source params)
(kernel/check-source-in mission source)
(kernel/mission-inventory-in mission)
(kernel/mission-model-context-in mission)
```

The reserved `kernel-eval` and `kernel-check-source` request objects add an
optional `"mission"` field to their existing exact shapes. Inventory routes
accept exactly `{}` or `{"mission": name}`. Explicit null, empty/invalid names,
extra keys, and unknown missions are protocol errors. Unknown-name errors are
bounded and list sorted declared names. They perform no evaluation or mission
task call. Ledger projections include the selected mission without leaking
source or params.

`agent.core/run`, `run-value`, `run-outcome`, and `run-result-value` advertise
`mission :string?` beside `model :string?`; nil/omission in this public config
means `default`, and the wrappers never send null to the reserved protocol.
`agent.main/run` passes the exact agent config through. The prompt context and
evaluation always use the same normalized mission. Tests cover all four exports
plus `agent.main` in one-shot Runner and manifest-workflow REPL route assembly,
and prove model and mission selectors vary independently.

### Isolation and continuation state

`RunState` keeps one `continuations` map keyed by mission name. Each entry owns
native memory, three-value history, and a continuation revision. The current
single evaluation lease additionally records its mission name. Reserve, commit,
release, source check, and memory summary are atomic owner operations:

- evaluation reservation returns only the selected mission's memory/history;
- successful commit replaces only that mission and increments only its revision;
- failed evaluation preserves every mission;
- source check snapshots and validates only the selected mission revision, so a
  commit in another mission does not make it stale;
- a closure never crosses mission state because no value produced inside a
  mission enters another mission's native continuation; workflow receives only
  the existing projected boundary value;
- per-mission memory/history candidates and the sum across all missions must
  each fit the existing limits.

Workflow REPL continuation is a separate owner-held slot, never a mission-map
entry. Its memory/history and revision persist workflow forms in a manifest or
direct REPL even when there are zero missions, contribute to the same run-wide
retained-byte ceilings, and never increment `evaluations_by_mission` or touch a
mission continuation. Tests cover persistent workflow definitions with no
missions and with a real `default` mission.

The FIFO queue stores the requested mission with each waiter. Admission order,
absolute admission deadlines, stale-lease drain gate, exactly-once waiter
reply discipline, mission lease authentication, and provider-call serialization
remain unchanged from #1241.

### Identity, override targeting, and prepared state

Application content records use `mission/<mission-name>/<component-id>`.
Component occurrences, kinds, data, and direct normalized grants are stored in
a deterministically sorted mission map throughout `Manifest`,
`ApplicationPackage`, `RunRequest`, `PreparedRun`, and attestations. The
effective-application projection contains the workflow bundle projection plus
that mission map; acquired inventory hashes do not feed back into its digest.

The override descriptor is a closed object requiring `target`, `component_id`,
`base_source_hash`, `source_hash`, and `path`; only `provenance` is optional.
`target` is exactly `{"environment":"workflow"}` or
`{"environment":"mission","mission":name}`. It is validated and resolved
before source read/compilation/provider activity. Application applies one
descriptor to exactly one qualified component occurrence; identity and
run-started provenance include the qualified target. Ambiguous implicit target
inference is deleted. `mix ptc.materialize` therefore requires an explicit
`--workflow` or `--target-mission NAME` selector; base lookup, candidate compilation,
the emitted descriptor, and the gate report use that exact occurrence. Its
tests reuse one component ID in workflow and two missions to prove no first
match survives.

Application-content and effective-application domains advance to
`ptc.application-content.v2` and `ptc.effective-application.v2`; golden identity
tests distinguish V2 named projections from the retired singular recipes.

Preparation, provider selection context, sealed post-selection context, and
validation results carry sorted `mission_bundle_hashes`. `mix ptc validate` and
the command-envelope V2 schema replace nullable `mission_bundle_hash` with the
closed object. V2 command usage also requires sorted
`evaluations_by_mission`; aggregate memory/history byte fields remain the
run-wide sums, and the public `evaluation_memory` object remains an aggregate
summary rather than exposing continuation contents. Writers emit only V2, and
the Mix frontend, standalone executable, launcher, human fixtures, repo-analyst
schemas/scripts, and Lisp consumers migrate atomically. The V1 schema remains a
historical artifact and is never redefined.

### Evidence, inspection, and Viewer

Canonical events advance to schema V2. Every mission-scoped V2 event carries `mission_name`, including
evaluation, capability, and limit events. Runtime instrumentation receives the
mission from the selected environment/lease rather than accepting caller
attribution. Aggregate usage adds sorted `evaluations_by_mission`.

Private inspection advances to V4. New `evaluation-source`, mission
`prelude-source`, mission `capability-input`/`capability-output`, and their MCP
transport joins carry `mission_name`; workflow records forbid it.
Mission prelude uniqueness is `(environment, mission_name, component_id)` and
evaluation correlation verifies mission attribution against canonical events.
Writers emit V4 only. Artifact loaders, inspection snapshots/queries, and the
Viewer continue to read legacy V1-V3: a legacy mission record/event without a
name maps to `default` only for matching/filtering, while new writes are never
silently downgraded.

`run-started` carries a sorted `missions` metadata map with each bundle dependency
projection and acquired full/model inventory hashes and byte counts. The Viewer
surfaces declared missions in run metadata and qualifies source/prelude joins
and transcript rows with mission names without labeling them as agents.

Trace query result projections advance to schema V2. `trace-list-runs` and
`trace-get-run` replace singular mission prelude/inventory fields with the exact
sorted `missions` metadata map. When reading a canonical V1 run, their V2
projection places its singular metadata under `missions.default`; canonical V2
writers never emit singular metadata. Trace-capability, library, and Viewer
consumers use that one normalized result shape.

One canonical run uses exactly one event schema version. A trace source and
append file may contain separate complete V1 and V2 runs; V2 batches append to
an existing V1 prefix and the combined source reloads and queries normally.
Events from two versions under one run identity are malformed. V2 mission-event
shapes require `mission_name`; legacy default inference is available only for
schema V1, never merely because a V2 field is absent.

`trace-list-turns` and `trace-counters` accept `mission_name`. Run/label/tag/time
filters select the source set first; mission matching then retains attributed
events. A legacy event matches `default` only when
`environment == "mission"` and `mission_name` is absent. Workflow and lifecycle
events never match. Cursors hash the complete filter including mission name.
With a mission filter, counters derive every field from the narrowed events:
matching event/error counts, distinct matching runs, matching mission
evaluation/capability counts, zero workflow capability calls, and empty LLM
usage. `trace-list-runs` and `trace-get-run` keep their current filters.

## Ownership and failure matrix

| Resource | Creator | Fixed owner | Authorized users | Closer |
| --- | --- | --- | --- | --- |
| Manifest/application source | `ApplicationPackage` acquisition | acquisition caller | loader only | acquisition `after` block |
| Compiled workflow/mission bundles | `RunCoordinator.prepare` or direct `RunBuilder` | immutable attested value | coordinator/builder | garbage collection |
| Provider pool/session | existing provider acquisition | provider/execution-session owner | workflow plus mission grant partitions | existing cleanup/drain path |
| Mission environments/inventories | `RunBuilder` after acquisition | immutable `RunConfig` owned by execution session | workflow routes by validated name | run teardown |
| Continuations and revisions | `RunState` | `RunState` GenServer | current authenticated evaluation lease; source checks read | `RunState.stop` |
| Canonical/inspection sinks | existing publication authority flow | execution/session owner | event/inspection emitters | existing finalization/abort |

| Condition | Required behavior |
| --- | --- |
| Success | Only selected mission commits; evidence is qualified; all providers/sinks close normally. |
| Structural/source/compile bound failure | Fail before provider declaration/acquisition and before canonical events. |
| Inventory bound failure after acquisition | Close every acquired provider, abort sinks/authority, emit no canonical event. |
| Unknown/malformed mission request | Bounded protocol error with sorted names; no evaluation/task dispatch. |
| Ordinary evaluation error | Preserve selected and all other continuations; qualified stop/limit evidence. |
| Evaluation caller/worker death | Existing monitor releases the one lease; queued mission requests continue FIFO. |
| RunState owner death | Existing provider tracker and execution owner drain/close all resources. |
| Provider worker death/call timeout | Existing lease-authenticated failure path; mission attribution remains fixed. |
| Run/admission/evaluation deadline | Existing absolute deadlines win; the preparation-local 5,000 ms compile-batch deadline is passed as remaining absolute budget and does not extend a later run deadline. |
| Ambiguous `GenServer.call` timeout | Server-side admission deadline remains authoritative; no retry or second commit. |
| Sink failure | Fail closed through existing owner path; do not continue with partial unqualified evidence. |

Private source, params, provider payloads, and native continuation values remain
out of process status, canonical traces, diagnostics, command results, and
run-started metadata. Only hashes, byte counts, declared names, safe normalized
provider projections, and explicitly private inspection records may contain the
corresponding evidence already allowed by their sinks.

## Test-first implementation order

Each numbered slice starts with integration/contract tests that fail on current
main. Implementation follows only after the expected failure is observed.

1. **Manifest migration and early bounds.** Add manifest/application tests for
   singular rejection, absent/empty missions, explicit default migration with
   copied grants, invalid names, unknown/duplicate grants, 16/32 limits, and
   aggregate component/edge/source bounds. Use an instrumented
   `ApplicationSource` reader to prove structural failures happen before source
   reads. Update manifest structs, schemas, application content names, override
   target validation/application, package attestations, the application-content
   V2 domain and golden identity tests, and the explicit
   `ptc.materialize` workflow/mission selector plus same-ID collision cases.
2. **Bundle maps and compiled bound.** Add coordinator/direct-builder tests for
   sorted compilation, a late-mission aggregate compile timeout and a
   near-cutoff compile failure proving diagnostic span work cannot extend it,
   per-bundle and aggregate artifact ceilings, failure
   before provider activity, validation `mission_bundle_hashes`, effective
   projection identity, and qualified override provenance. Cut over
   `ProviderPlan`, selection contexts, `PreparedRun`, command results/schema,
   V2 command envelope/frontends/launcher/human fixtures, the effective-application V2 identity domain,
   repo-analyst contracts, and both direct and prepared build paths.
3. **Grant/environment/inventory assembly.** Add provider fixtures that expose
   dependency-only and direct capabilities; prove dependencies are acquired but
   not exposed, reader cannot write, and inventory overflow closes acquired
   providers without `run-started`. Preserve per-occurrence acquired capability
   grouping, construct sorted mission environments, enforce independent full
   and compact aggregate inventory caps, and publish per-mission metadata. The
   same green slice cuts every Elixir `RunConfig` consumer over atomically:
   builders, Runner, `ReplSession`, fixed analysis profiles, and
   `AnalysisSession`; no singular compatibility field exists between slices.
4. **Continuations and evaluation routing.** Add deterministic integration tests
   for isolated definitions/history/data, deliberate sharing within one mission,
   per-mission revisions, cross-mission closure refusal/projection, retained-byte
   total, unknown-name no-dispatch, FIFO requests carrying different missions,
   and lease-authenticated capability attribution. Replace singular RunState
   fields with the continuation map and thread mission names through Evaluation,
   SourceCheck, limits, and task dispatch without changing the admission owner.
5. **Kernel/agent APIs and REPL routes.** Contract-test every legacy default and
   named `*-in` Kernel wrapper, exact raw request shapes, all four agent.core
   exports, `agent.main`, prompt-visible API choice, model/mission orthogonality,
   and both one-shot Runner and manifest-workflow REPL construction. A
   table-driven case with only non-default missions exercises every legacy
   Kernel wrapper plus omitted/nil selectors and proves bounded
   `default`-missing errors with no evaluation/provider dispatch. Fixed
   `log-analysis-v2` and `inspection-analysis-v2` sessions each use the already
   migrated single mission named `default`; directly test both profile identities,
   inventories, and evaluation paths. Then update
   runtime callbacks, ledger projections, Kernel/agent preludes, signatures,
   and prompt rendering.
6. **Trace, inspection, and Viewer.** Add trace query/counter tests for new and
   legacy default attribution, cursor identity, qualified usage, V2 normalized
   list/get-run mission maps, mixed complete V1/V2 sources, V2 append to a V1
   file, per-run version consistency, strict V2 required attribution,
   trace-capability parity, and no workflow leakage.
   Add V4 inspection writer/legacy-loader/join tests, including two missions
   invoking the same capability, and Viewer API/UI
   fixtures proving sources/preludes from equal component IDs in two missions do
   not collide. Thread `mission_name`, bump schemas, and expose mission metadata
   in the Viewer.
7. **Migration, example, and durable documentation.** Mechanically migrate all
   manifests, fixtures, repo-analyst schemas/scripts, examples, and generated
   artifacts. Add a provider-backed runnable reader/writer agentic-flow example
   with separate mission components/config/data/grants/state and one workflow;
   its guide documents setup, execution, security boundary, expected result,
   shared budgets, and how to inspect traces. Update manifest/capability,
   agent-building, Kernel maintainer, inspection/trace, CLI, schema, and language
   function-reference documentation. No durable doc links to this plan.

## Verification and bounded review

Before plan review: format Markdown, run `git diff --check`, then one fresh
`codex-review consult` scoped to this plan and issue contract. Batch fixes and
use the same session for at most two follow-ups (three total passes), stopping
early when clean.

During implementation, run the focused test file after each red/green slice and
the affected nested Viewer suite from `ptc_viewer/`. Before implementation
review run formatting, compilation with warnings as errors, all targeted tests,
generated-artifact staleness checks/write forms, Viewer tests, and
`MIX_ENV=dev mix docs --warnings-as-errors`.

Run one fresh cumulative implementation review with
`codex-independent-review review --base origin/main --fetch-base`. Batch fixes
and use that session for at most three follow-ups (four total passes), stopping
early when clean. If fixes materially expand scope or the guarded base advances,
that required fresh pass consumes one of the four. After the exact reviewed tree
is clean, run `mix precommit`, re-run any gate affected by repairs, commit with a
Conventional Commit message, push with hooks enabled, and create a draft PR with
`Closes #1237`. If pass four remains non-clean, list the residual findings and
their risk in the PR rather than claiming approval.
