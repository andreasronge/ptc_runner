# Kernel maintainer guide

> **Audience:** people changing PtcRunner itself.

Application authors should use
the [Quickstart](../guides/quickstart.md),
[manifest guide](../guides/manifests-and-capabilities.md),
[host configuration](../guides/host-configuration.md),
[agent guide](../guides/building-agents.md), and
[Kernel REPL guide](../guides/kernel-repl.md).

This guide is an architectural map. Exact fields, return values, limits, state
transitions, and error atoms belong in the owning `PtcRunner.Kernel.*` or
`PtcRunner.Lisp.*` module documentation. Language semantics live in the
[PTC-Lisp specification](../ptc-lisp-specification.md), trace semantics in the
[TraceLog and run-analysis reference](trace-log-contract.md), and
admitted Java behavior in the generated
[Java interop reference](../java-interop.md).

## Architecture and invariants

![PtcRunner execution architecture: seven layers from frontend entry down to
artifact publication, separated by the path-free boundary and the
ExecutionSessionOwner lifetime](assets/architecture.png)

Preserve these invariants across every change:

- **Unsealed paths stop above execution.** Frontends acquire and confine
  application, host, input, and destination documents. Execution receives a
  sealed request and anchored publication authority, not caller path input.
- **Preparation is inert.** It may compile, normalize, narrow limits, and
  derive identity. It must not resolve credentials, invoke provider callbacks,
  start processes, or use the network.
- **Authority is explicit.** A compiled component requirement proves that a
  grant is needed; it does not create the grant. Workflow and mission
  environments remain structurally separate.
- **Every effectful resource has one owner.** Ownership transfer is explicit.
  Cleanup is bounded, reverse-order, and idempotent.
- **Nested work shares one absolute deadline.** A child may narrow a deadline
  but must not reset it.
- **Public evidence is closed and path-free.** Diagnostics, canonical events,
  results, and usage expose only their bounded public contracts. Exact payloads
  require explicit private-inspection authority.
- **Publication comes last.** Destinations are authorized before provider
  activity, but execution publishes only immutable evidence after provider
  cleanup.

The Kernel is a bounded runtime, not an agent framework. BEAM code owns
authority, containment, deadlines, quotas, cleanup, and public/private
projection. PTC-Lisp owns replaceable workflow policy such as prompts,
planning, retries, feedback, and completion. Frontends own path acquisition,
presentation, and host interaction.

## Lifecycle

The main path is:

```text
ApplicationSource -> Manifest -> ApplicationPackage
                                  + ExecutionInput
                                  + ExecutionPolicy
                                          |
                                          v
                                   sealed RunRequest
                                          |
                                          v
                  RunCoordinator.prepare (inert phases 4-5)
                                          |
                                          v
                   authorize artifact destinations
                                          |
                                          v
                      ExecutionSessionOwner
                        |              |
                        |              +-> optional ProviderActiveSession
                        v
                    RunBuilder -> RunConfig -> Kernel.run
                                          |
                                          v
                     sealed ExecutionOutcome
                                          |
                                          v
                       cleanup, then publication
```

### Acquire and seal

`PtcRunner.Kernel.ApplicationSource` is the bounded byte-acquisition boundary
for directory and memory applications. Both feed the same strict
`PtcRunner.Kernel.Manifest` decoder. Referenced bytes are captured once, so
validation and compilation see the same document.

Acquisition is not a multi-file transaction. A directory-backed application
must remain quiescent while its closure is captured, or be published through
an immutable versioned directory.

`ApplicationPackage`, `ExecutionInput`, and `ExecutionPolicy` separate
application identity, selected input authority, and execution/publication
policy. `RunRequest` seals those values. Provider implementations remain in a
host-owned `InstallationCatalog`; manifests select trusted aliases and cannot
install callbacks, endpoints, commands, or credentials.

`RunCoordinator.prepare/2` compiles workflow and mission bundles, validates the
workflow entry, checks provider declarations through data-only
`SelectionRules`, narrows limits, and derives the effective identity. It
returns a one-shot `PreparedRun` whose owner must close it if execution does
not consume it.

Audited local checks have one coordinator entry,
`RunCoordinator.local_checks/3`. Active and unverified checks run later under
the operation deadline. Keep this split: an application-selected callback must
not enter the inert preparation or audited-local boundary.

### Activate and execute

One-shot runs use `ExecutionSessionOwner` whether or not they select a
provider. The owner opens canonical and optional private sinks, monitors its
caller and worker, and returns sealed execution evidence.

Provider-bearing runs open one `ProviderActiveSession` inside that owner.
`ProviderAcquisition` prepares and acquires selected providers in dependency
order. Each scope registers resources through `ResourceRegistrar` before it can
be exposed, then either commits one closer or aborts its provisional resources.

`RunBuilder` assembles immutable workflow and mission environments and returns
one `RunConfig`. A configuration is one-shot. A caller that builds but does not
execute it must use `RunBuilder.close/1`.

Environment assembly has one separate, subjectless acquisition diagnostic.
`capability_requirement_missing` reports the sorted, bundle-attested capability
names that the assembled provider surface did not supply. It applies to both
provider-backed and provider-free runs, records whether provider work actually
occurred, and is not admitted to `doctor --connect`, which never assembles a run
environment.

`PtcRunner.Kernel.run/2` delegates to `Runner`, `RunState`, `Dispatcher`, and
`Evaluation`. `RunState` is the single mutable owner of a run's deadline,
quotas, reservations, protocol state, terminal state, and mission
continuations. State-dependent decisions must be one atomic owner operation;
a separate read followed by an update is a race.

### Close and publish

Normal completion, timeout, caller death, worker death, and termination all
drain the same owned resource set. Provider work is drained before provider
closers run. Cleanup remains bounded even when a callback or owner fails.

`PublicationAuthority.authorize/4` anchors and reserves destinations before
provider activity. `ArtifactPublisher` later consumes only the sealed
authority and `ExecutionOutcome`. A private result uses an owner-only recovery
file so a trace, inspection, or final-link failure cannot silently lose an
already durable result. Exact reservation, recovery, and finalization states
belong to those two module contracts.

### Commands and REPLs

The runtime release's `bin/ptc` entrypoint and `mix ptc` share
`CommandEntry`, `CommandEngine`, the diagnostic catalog, rendering, and
publication machinery. Adapters supply runtime bootstrap and interactive host
policy; they do not define another parser, evaluator, event model, or provider
registry.

`validate`, `models`, and both doctor modes are terminal command operations.
Only `doctor --connect` performs provider connectivity work. Exact command
envelopes and diagnostic rows are owned by `CommandOutcome`,
`CommandContract`, and `DiagnosticCatalog`; `mix ptc.gen_docs` projects their
schemas.

Manifest REPL startup follows the same acquisition, preparation, local-check,
sink, and active-provider prefix as a one-shot run. It then transfers the
opening and run state to `ReplSessionOwner`. `ReplSession` is process-affine;
passing its public value does not transfer ownership.

The frontend separately classifies whether it will enter the line loop. That
classification is independent of TTY attachment and drives the REPL-only limit
profile before the application package, event sink, provider session, and run
state are sealed. Omitted manifest `run_duration_ms` and
`subordinate_evaluations` rows and retained-event capacity then inherit their
installed ceilings; explicit manifest values remain effective. The resulting
deadline stays absolute for the whole session, including prompt time. An
owner-side timer records deadline failure and closes provider resources even
while the frontend is blocked reading the next line.

An explicit manifest mission first derives an attested target from the inactive
`PreparedRun` and its exact installation catalog. That target seals direct
occurrences, dependency-closure declarations and aliases, and the closure's
effective data/event policy. Every provider-facing opening phase consumes that
same target. The built `RunConfig` contains an empty workflow environment and
only the selected mission; dependency providers remain lifecycle support while
direct occurrences alone contribute task capabilities. `ReplSessionOwner`
atomically adopts the mission mode with the config, and `ReplSession` dispatches
forms through ordinary `Evaluation` rather than the workflow evaluator.

## Bundles and authority

`PtcRunner.Kernel.compile_bundle/1` compiles a closed component dependency
graph into a `FrozenBundle`. Compilation records public exports and transitive
`tool:*` requirements but grants no capability.

Each source is parsed once into a compiler description, then compiled in
dependency order against only its declared namespace scope. The bundle
compiler rejects namespace collisions explicitly and composes those validated
Core artifacts into the aggregate prelude; it does not recompile concatenated
source. `FrozenBundle.components` retains only each component's ID, direct
dependencies, origin, source hash, and namespaces. Callable per-component
preludes exist only during bounded compilation, so bundle attestation does not
serialize a duplicate callable graph.

Within one `RunCoordinator.prepare/2` or direct provider-bearing build,
byte-identical normalized workflow and mission component sets reuse the same
sealed bundle. This reuse is local to that preparation: there is no process,
ETS table, `persistent_term`, or cross-preparation cache, and a cache hit grants
no authority.

Compiler-rendered strings do not cross the command boundary. Prelude analysis
represents an unknown namespace as bounded structured detail: the rejected
namespace plus the canonical sorted list owned by the Lisp namespace diagnostic
catalog. `BundleCompiler` admits that reason;
`CompileDiagnostic` accepts it only when the rejected namespace is present in
the submitted component and the available list exactly matches the canonical
runtime list, then rebuilds the catalog-authorized message from literals.
Malformed or substituted detail remains `bundle/compile_failed`. Separately,
`CommandRenderer` projects any already-sealed component span as a logical name
and half-open byte range; it has neither source bytes nor authority to derive a
different location.

Authority appears only when the bundle is installed in an environment:

| Environment | Purpose | Typical grants |
| --- | --- | --- |
| `WorkflowEnvironment` | trusted orchestration | model calls, annotations, subordinate evaluation |
| `MissionEnvironment` | confined generated programs | selected files, remote tools, trace queries |

Subordinate evaluation receives only its selected mission environment. It must
not inherit workflow grants or fall back to another mission. Preserve that
separation in data structures and function arguments, not through name
filtering.

Components may call public exports in their direct declared dependencies.
Evaluated source can call every public export in the resolved bundle, including
`:discoverable` exports omitted from prompts. Review every new dependency edge
as a callable-surface change. [Components and preludes](../guides/components-and-preludes.md)
has the author-facing rules.

`MissionInventory` owns the deterministic structured and prompt-facing mission
API projection, including mission data grants. `agent.prompt` renders model
context from the compact secondary projection. Prompt visibility never changes
the underlying environment grant. `ptc validate` reports parseable data forms,
all public exports, and selected providers per mission under `mission_grants`
without acquiring providers.

## Evaluation, limits, and concurrency

`kernel-eval` delegates mission programs to `Evaluation`. Each mission has one
transactional continuation owned by `RunState`:

- ordinary success commits bounded definitions and result history;
- `return` commits and completes successfully;
- `fail` terminates the workflow; and
- parse, analysis, runtime, limit, projection, and capability failures leave
  the previous continuation intact.

Only bounded public observations cross back to workflow Lisp. Native
definitions, callables, evaluator context, and Java provenance remain in the
continuation owner. Keep effect capture and merge rules in
`PtcRunner.Lisp.Eval.*`; do not add a second effect transport.

A run holds one evaluation lease. The public fail-fast reservation returns
busy when occupied. The `kernel-eval` tool uses the blocking FIFO admission
path so concurrent agent branches can wait without spending a model turn.
Server-side timers, the run deadline, owner monitors, and lease tokens ensure
that an expired, dead, or stale evaluator cannot overlap the next one. Exact
admission outcomes are documented by `RunState` and `Evaluation`.

`Dispatcher` validates capability input before callback entry, reserves
budgets, bounds the trusted callback worker, normalizes output, and rejects late
completion. It may retain small schema-authored correction facts, but never
submitted values, undeclared property names, enum values, or opaque validator
reasons. `RunState` opens the callback worker's one-shot gate in the same owner
operation that records the dispatched reservation; an uncertain gate
acknowledgement remains possibly dispatched and is charged fail-closed.

`LimitCatalog` is the authority for limit names, scope, defaults, ranges, and
identity participation. Installed limits are ceilings; manifests may narrow
only rows marked manifest-narrowable. Generated host and manifest schemas must
remain consistent with the catalog and `Limits` struct.

Providers are trusted host extensions, not hostile same-VM code. The Kernel
contains ordinary faults and bounds work and results; it is not a security
sandbox for malicious BEAM callbacks.

## Identity

Keep these identities distinct:

- `FrozenBundle.hash` covers component IDs, source hashes, and direct
  dependency edges.
- `application_content_digest` covers captured application content while
  excluding the selected input and override attribution.
- `effective_application_digest` also covers the prepared workflow/mission
  bundles, normalized provider selections, effective policy, identity-bearing
  limits, and semantic revision.
- `installation_config_digest` covers one decoded host `install.<alias>`
  declaration after schema defaults, excluding `installation_revision`,
  secrets, and machine-local resolved paths. Set-valued declaration fields are
  ordered canonically before hashing. Selected aliases are published as
  `installation_config_digests` from `ptc validate` and `run-started`. This
  stays a sibling of the application digests; host configuration is not folded
  into them.
- `ptc_semantic_revision` describes the execution-semantics build and relevant
  runtime dependency artifacts.

`TypedCanonicalJSON` preserves JSON type identity for semantic hashes.
`StrictJSON` owns duplicate-key, UTF-8, number, depth, and node admission.
`ApplicationPackage`, `EffectiveApplication`, `FrozenBundle`, and
`SemanticRevision` document the exact framing and projections.

`priv/semantic_build_inventory.exs` classifies semantic source and dependency
inputs. Regenerate the checked-in projection only on main as part of release
work, using `mix ptc.gen_semantic_revision`; feature branches must not rewrite
or hand-merge its hashes. Release verification checks staleness and compiles a
verified revision into the artifact.

## Results and observability

The public run algebra is `{:ok, %PtcRunner.Kernel.Result{}}` or
`{:error, %PtcRunner.Kernel.Error{}}`. Capability failures are usually bounded
Lisp values so workflow policy can decide whether they are terminal.

Observability has separate planes:

| Plane | Contract |
| --- | --- |
| Logger | sparse operator diagnostics; no payloads, prompts, source, credentials, or transport secrets |
| Telemetry | bounded, low-cardinality measurements and closed metadata |
| `EventSink` / `TraceLog` | sanitized canonical events and immutable queries |
| `InspectionSink` / `InspectionArtifact` | explicit private model, source, capability, and eligible result evidence |

Do not move private data into canonical events for convenience. Add safe
correlation metadata to the canonical plane and retain exact payloads only
under private authority.

`EventSink` owns event identity, sequence, bounds, loss policy, and terminal
finalization. `TraceLog` owns canonical persistence and queries.
`InspectionArtifact` owns the private grammar and correlation rules.
`RunAnalysis` and the Viewer consume those snapshots rather than define another
event model.

Normal trace admission validates structural headroom after host ceilings and
application requests have been resolved. `normal_event_count` must be at least
three: one ordinary `run-started` event plus the `events-dropped` and
`run-stopped` terminal reserve. `normal_event_bytes` must be at least the
measured normal terminal reserve plus
`EventBudget.maximum_event_bytes("run-started", event_payload_bytes)`, preserving
one complete maximum-size `run-started` envelope in addition to the terminal
envelopes. `EventBudget` owns the bounded payload and envelope shapes;
`LimitConfiguration` owns the cross-field check for manifest-backed validate,
doctor, run, and REPL paths; a refusal is the pre-execution
`application/limit_configuration_invalid` diagnostic. Private trace policy
still uses a zero terminal reserve and is not subject to this normal-trace byte
relationship.

The Lisp execution Telemetry prefix is `[:ptc_runner, :lisp, :execute]`. Its
closed `caller` values are `:direct`, `:kernel`, and `:repl`. Stop metadata
carries the semantic `outcome` while measurements carry duration, program and
result byte counts, and print count. Exception telemetry may identify the
exception class but never attaches the raw reason, stacktrace, source,
arguments, or result. Canonical events are not implemented by forwarding Logger
or Telemetry callbacks, and are not mirrored wholesale back into them: neither
plane supplies the retention, sequencing, bounds, source grants, or fail-closed
policy the trace contract requires. All planes may share run, evaluation, and
capability correlation IDs, subject to their own cardinality rules. Owner
processes that retain private inspection or evaluation values, or connector
endpoint and session state, use closed callback fallbacks and a constant
redacted OTP status, including in abnormal-exit reports. Erlang VM tracing
(`:erlang.trace`, `:dbg`, `:sys.trace`) is an operator debugging facility, not
a product trace source.

## Trace storage and analysis sessions

What a trace contains and how it may be queried is the
[TraceLog and run-analysis reference](trace-log-contract.md).
This section owns the parts that are implementation rather than contract.

### Canonical persistence

Ordinary host-selected append takes an OS-released advisory lease before it
validates the existing prefix and writes a batch. Existing files are keyed by
device and inode, so hard-link aliases share the lease across BEAM processes and
separate local runtimes. An unlocked lease file may remain after exit but cannot
wedge later appenders. Two appenders therefore cannot both approve the same
prefix and then race the byte or sequence checks.

Complete analysis-session batches use atomic no-clobber publication rather than
append. `TraceLog` validates and deterministically encodes the whole batch,
writes and syncs an exclusive same-directory temporary sibling whose name is not
a discoverable trace, installs the final name with a hard link, and syncs the
containing directory before reporting success. Removing the temporary link is
followed by another directory sync. An existing byte-identical complete
destination is a successful retry only after the directory is synced; a
different or partial destination is a collision and is never replaced or
appended. The open temporary descriptor, the temporary pathname before linking,
and the published pathname after linking must retain the same device/inode
identity; pathname replacement is a collision and is never acknowledged as
successful. Observed failure paths remove the temporary sibling. Hard-link
creation rather than `File.rename/2` is what makes this no-clobber: a rename can
replace an existing destination, a link create fails when one exists. The same
shape is used for inspection artifacts. This publication contract is for
host-selected destinations only and grants no Lisp write authority.

### Immutable directory captures

`TraceSnapshot` pins one host-selected canonical trace directory for a bounded
analysis session. It is deliberately not another public `TraceLog.source()`
variant and cannot capture a file or an inspection artifact. The constructor
fixes whether the directory is ordinary normal-only input or private-authorized
canonical input; a caller cannot widen an existing handle or relabel it for
another profile.

Ordinary capture selects normal `<run-id>.jsonl` names in raw-byte sorted order,
records a pre-read directory and file inventory, compares path and descriptor
identity, retains the baseline bytes, and performs repeated byte-for-byte and
namespace verification before installation. Any selected name, identity,
metadata, type, or content change between baseline and final verification
returns `:source_changed`; a mixed capture is never installed. Stable damaged
members instead enter one deterministic run/trace claim graph. The complete
connected component is isolated for a malformed file, unsupported version,
filename/run mismatch, non-regular or unreadable member, repeated identity, or
sequence/lifecycle failure, while disjoint canonical files remain queryable.
There is no filename-ordered winner or partial-run merge.

Private `.private.jsonl` and `.ptcins` artifacts stay excluded by normal
discovery. The private-authorized capture instead selects both ordinary and
`<run-id>.private.jsonl` traces, records `sanitized` or `private` provenance per
admitted run, and still excludes inspection artifacts. A run split across
files or source classes is isolated as one connected component.

The private inspection snapshot carries that decision forward: a sealed
`.ptcins` artifact whose exact run and trace footer identity belongs to an
isolated trace component is validated into disposable indexes and dropped with
the component. Its digest remains part of inspection snapshot identity, while
disjoint healthy trace and inspection pairs remain queryable and retain the
trace classifier's bounded isolation metadata.

The default aggregate encoded-source ceiling is 8,000,000 bytes. Snapshot
retention independently limits the decoded representation to 32,000,000
retained bytes, and query results keep the 1,000,000-byte default. Capture
enumerates under a fixed heap and time bound and rejects directories above
4,096 total entries or 1,024 selected trace files before sorting, stating,
opening, or verifying any selected file. Hosts may lower the construction
limits but cannot raise them, and browser or Lisp input cannot select them.
The owner retains the detached `directory_admission_v1` value: selected source
proofs and classifications, admitted events and compiled projection, complete
isolation components, and source identity. Fixed query limits, safe capture
metadata, and the owner monitor live alongside that admission in owner state.
Its tokenized handle carries only a PID and an unforgeable reference; neither
owner state, status output, capability closures, safe metadata, nor errors
retain or expose the directory path. Safe capture metadata is the capture
digest, UTC capture time, visible run count, raw encoded source bytes, and
retained admission bytes. All four
snapshot queries execute the same `TraceLog` filtering,
metadata, ordering, pagination, cursor, and result-limit code as ordinary
sources, and cursors bind to the captured digest so they stay stable when the
directory changes later. Owner death cancels an in-progress capture worker as
well as stopping an installed snapshot; cleanup is idempotent.

### Local analysis sessions

`AnalysisSession`, `AnalysisSessionBuilder`, and `SessionTrace` own their own
lifecycle contracts; read those module docs before changing one. The facts that
span them:

- The server-owned `run-analysis-v1` profile is shared by the Viewer and
  ordinary terminal REPL frontends. Its mission bundle contains `cap` and
  `analysis`, its explicit authority the four `analysis-*` capabilities
  (`analysis-runs`, `analysis-open`, `analysis-read`, `analysis-counters`).
  Ordinary implicit mission introspection remains available. Filesystem,
  network, LLM, agent, workflow, MCP, private-inspection, and nested
  `kernel-eval` authority are absent. `private-run-analysis-v1` uses the
  private-authorized capture, adds the validated private-inspection source, and
  requires a private terminal gate; its own session trace is still a sanitized
  normal artifact.
- Each session queries one immutable snapshot and records its own canonical
  events under a separate token, in the same owner that holds its continuation
  and quotas. The active mutating session trace is never queryable from that
  session, because the query would mutate the digest-bound source it is paging.
- The Viewer publishes into its host-configured input directory, so a later
  refreshed Viewer session captures the directory again and can query its
  predecessor. A terminal `ptc repl` session publishes into a physically
  separate host-selected or private temporary directory and never mutates its
  captured input tree. The builder binds the accepted output directory's
  filesystem identity into `SessionTrace`, and publication verifies that
  identity before it receives trace bytes, so replacing or retargeting the
  pathname cannot redirect the write.
- The session relies on the measured terminal reserve every normal `EventSink`
  carries by default — two measured terminal envelopes; private sinks reserve
  nothing. Ordinary events stop before the count and byte ceilings would consume
  capacity for one bounded `events-dropped` summary and exactly one
  `run-stopped`. Atomic finalization returns the frozen terminal batch in that
  same owner call without exceeding either hard ceiling.
- Exhausting a terminal session budget persists an error run with that
  authoritative limit reason even when abort or deadline expiry performs the
  eventual close. The reason is transferred to the trace owner before the
  triggering evaluation reply, so it outranks the generic unexpected-owner
  reason. Every evaluation admission rechecks the same authoritative deadline,
  so expiry publishes the same outcome regardless of timer-message ordering.
- The trace owner is constructed only when every part of its contract agrees:
  the limits, the combined runtime and sink, a normal fail-closed sink policy,
  the exact two-event measured terminal reserve, an empty unbegun recorder, an
  open `RunState` whose limits are identical, matching sink run and trace
  identity, and a `<run-id>.jsonl` destination basename. Assembly validation
  rechecks the runtime binding, and the sole session attaches before
  `run-started`, so a rejected assembly replay is side-effect free.
- Orderly close, reset, and deadline expiry each finalize and publish the
  batch; explicit `return` and `fail` are evaluation facts, not session
  lifecycle commands. Session death before the builder releases its
  construction guard cleans partial owners without publishing a run, and every
  post-start handoff failure explicitly stops the partial session even when the
  trace owner has already died. `SessionTrace` and `AnalysisSession` own the
  rest — unexpected-owner best-effort publication, retry authority, and
  idempotent close — in their module docs.
- Ordering invariants the two owners must preserve: recorder readiness and
  continuation commit are one owner callback, so combined-runtime or trace-owner
  death cannot leave a committed result without event authority; orderly close
  synchronously stops and observes the combined runtime and snapshot before
  relinquishing their handles or starting persistence; the deadline message is
  privately correlated and cannot be forged from the session PID alone; session
  information requests serialize behind an accepted evaluation rather than
  mistaking that bounded wait for owner death; assembly validation rechecks the
  runtime binding, and the sole session attaches before `run-started` so a
  rejected assembly replay is side-effect free. A combined runtime that died
  before orderly `RunState.close/1` was accepted turns an otherwise open
  recorder into `backend_failed` before its monitor is flushed, so cleanup
  cannot erase the failure signal. Failure before terminal-batch handoff makes
  finalization fail without inventing a retry batch; failure after the batch is
  frozen preserves its terminal reason, events, and persistence state.
- The builder's caller remains the stable lifecycle owner once the construction
  guard is marked complete, and its monitor is intentionally retained. A host
  must therefore call the builder from a long-lived connected backend owner, not
  a disposable request or callback task, and must explicitly stop the session
  after its final close or abort attempt.

## Providers

The catalog has no implicit providers. CLI commands receive aliases from the
strict host document; embedding code constructs an explicit catalog. Exact
installation fields and source types belong in
[Host configuration](../guides/host-configuration.md).

`ProviderDescriptor` and `SelectionRules` own inert declarations.
`ProviderRegistry`, `ProviderActiveSession`, `ProviderAcquisition`, and
`ProviderSession` own activation and cleanup. A builder must remain bound to
its sealed descriptor, and every acquired provider resource must be committed
to the session's cleanup stack before assembly exposes it.

Explicit dotenv loading belongs to command frontends. They anchor the exact
`--env-file` path at command entry and load it only when inert preparation
proves that a selected LLM uses an environment credential. Kernel modules
never search for or load dotenv input; embedders acquire environment state
explicitly.

`MCPSource` owns discovery and capability assembly; `MCPProtocol` owns pure
protocol validation. HTTP and stdio transport owners bound, correlate, and
cancel requests. Host configuration owns endpoints, commands, credentials,
tool mapping, effects, and ceilings; server annotations do not grant authority.

`MCPHTTPAdapter` uses one absolute deadline across DNS, connection, and
response handling, with separate bounded header, body, and pending-parser
state. Exact socket and parser ceilings belong in its module documentation and
tests, not in this guide.

OAuth state remains behind `MCPOAuth.Store`. `MCPOAuth.Authorization` owns
authorization-code flows and `MCPOAuth.TokenManager` coordinates local refresh
and rejection fencing. Store and network work runs outside owner callbacks and
must remain bounded. A possibly spent credential is never made reusable merely
because a worker died or a lease expired.

Canonical traces remain native. Trace and inspection snapshot providers expose
the same bounded `RunAnalysisCapability` operations over immutable captures.
Fixed analysis profiles are code-owned recipes selected through
`AnalysisProfileRegistry`; callers do not supply their modules, grants, limits,
or paths.

## Code map

| Responsibility | Primary owners |
| --- | --- |
| Public run API | `Kernel`, `RunConfig`, `Result`, `Error` |
| Acquisition and sealing | `ApplicationSource`, `Manifest`, `ApplicationPackage`, `ExecutionInput`, `ExecutionPolicy`, `RunRequest` |
| Command lifecycle | `CommandEntry`, `CommandEngine`, `RunCoordinator`, `ExecutionSessionOwner`, `PublicationAuthority`, `ArtifactPublisher` |
| Components and authority | `Component`, `FrozenBundle`, `Library`, `Capability`, `WorkflowEnvironment`, `MissionEnvironment`, `MissionInventory` |
| Mutable run state | `Limits`, `LimitCatalog`, `RunState`, `BoundedWorker`, `Dispatcher` |
| Subordinate execution | `Runner`, `Evaluation`, `RuntimeTools`, `Lisp.Eval.*` |
| Providers | `InstallationCatalog`, `ProviderRegistry`, `ProviderAcquisition`, `ProviderSession`, `MCPSource`, `MCPProtocol` |
| Evidence | `EventSink`, `TraceLog`, `InspectionSink`, `InspectionArtifact`, `RunAnalysis` |
| Interactive evaluation | `ManifestRepl`, `ReplSession`, `AnalysisProfileRegistry`, `AnalysisSession` |

Modules grouped as Kernel internals in ExDoc remain documented for maintenance
and review. They are not alternative supported entry points.

## Change checklists

### Capability or provider

1. Put commands, endpoints, credentials, effects, and outer ceilings under
   host authority.
2. Freeze schemas and safe metadata before activation.
3. Grant the capability only through the intended environment.
4. Bound callback execution and normalize every public result.
5. Test timeout, caller and owner death, late completion, cleanup, redaction,
   and denied authority through an integration path.

### Lisp runtime or agent policy

1. Keep replaceable policy in shipped or local PTC-Lisp.
2. Update the owning evaluator effect/outcome path instead of adding a parallel
   transport.
3. Preserve transactional continuation and public projection.
4. Test direct, higher-order, parallel, and agent consumers as applicable.
5. Update the language specification only when language semantics change.

### Manifest or frontend

1. Reuse `ApplicationSource`, `ApplicationPackage`, `RunRequest`,
   `RunCoordinator`, and `RunBuilder`.
2. Keep manifest data non-executable and path acquisition confined.
3. Preserve workflow/mission authority and installed-ceiling precedence.
4. Keep input outside application content identity and destinations outside
   execution evidence.
5. Exercise both one-shot and REPL paths where their contracts overlap.

### Events or inspection

1. Choose the observability plane before adding a field.
2. Keep canonical metadata bounded, sanitized, and queryable.
3. Keep private capture explicit, correlated, no-clobber, and independently
   bounded.
4. Update TraceLog and Viewer consumers from the authoritative schema owner.

### Java interop

Update the Java manifest and structured oracle cases together. Use the
generated Java reference and pinned JVM/Babashka/PTC conformance tasks as
behavior evidence. Do not add fallback dispatch through the ordinary Lisp
environment.

## Verification

Prefer contract-level integration tests over tests that mirror implementation:

- core contract and evaluation-admission tests for authority, limits, and
  continuation;
- command, manifest, and REPL tests for lifecycle and frontend behavior;
- provider tests for transport, timeout, cancellation, cleanup, and redaction;
- event, trace, inspection, and Viewer tests for evidence boundaries;
- agent library tests for shipped workflow policy; and
- Java oracle/conformance tests for admitted Java behavior.

"Evidence boundaries" is the largest of those, so what the trace and inspection
suites must keep proving, concretely:

- canonical JSONL appends and reloads deterministically; a deleted index
  rebuilds identical results from canonical events; malformed events,
  unsupported versions, path traversal, and symlink escape all fail closed;
- the bounded in-memory sink stays bounded;
- normal and private canonical turn queries never contain inspection payloads,
  and evaluation source hashes and byte counts match the executed bounded
  source;
- directory loading is sorted and capped, cursors are stable, and a changed
  source invalidates them;
- truncation is deterministic and never allocates an unbounded intermediate;
- run discovery returns every required metadata field, and sanitization keeps
  credentials and private source out of it;
- a private source is denied without its own explicit grant, and mission-only
  confinement plus missing-`requires` rejection hold;
- library, capability prelude, and Viewer share one query semantics, and the
  semantic overview, internal canonical filters, ordering, and pagination all
  hold;
- snapshot-backed trace capability closures retain only the opaque token and
  return the same four canonical query projections as `TraceLog`;
- the fixed run-analysis profile keeps its positive and negative authority
  inventory, direct `Evaluation` parity, exact continuation behavior, bounded
  result and accounting projection, terminal-budget lifecycle, and path and
  source redaction;
- an immutable directory capture verifies the root plus selected raw names,
  identities, sizes, and bytes around classification; retains one complete
  `directory_admission_v1` value containing admitted events, provenance,
  compiled analysis, and all isolation evidence; enforces encoded and retained
  ceilings independently; redacts paths and unsafe names from public metadata;
  keeps snapshot cursors stable after the original directory mutates; and
  cleans up idempotently under owner death;
- saturating event count and byte capacity still retains one dropped summary
  plus exactly one terminal event through a reloadable persisted batch;
- atomic publication faulted before, during, and after write and at cleanup
  yields one complete file or a stable collision — never a partial
  discoverable trace or duplicate sequences;
- the inspection loader rejects unknown or duplicate envelope and payload keys,
  invalid record types, non-monotonic sequences, and correlation IDs absent from
  the selected canonical run;
- required capability-input and evaluation-source records are accepted before
  their callback or evaluation can run, and outputs hold the exact normalized
  Dispatcher envelope;
- inspection capture cannot be enabled by manifest or Lisp input, the
  destination is restricted before its first record, and per-record and
  aggregate ceilings fail closed without partial persistence;
- the capture path adds no connector credentials, transport headers, session
  IDs, or endpoints, normal discovery omits `.ptcins`, and querying a
  trace source never grants or reconstructs an inspection record;
- the local Viewer accepts only the exact host-configured inspection artifact
  and rejects symlinks, changed files, wrong run IDs, and oversized input.

Run focused tests while editing, then `mix precommit` for quality. When
documentation changed, also run `MIX_ENV=dev mix docs --warnings-as-errors`.
For an ordinary push, let the tracked pre-push hook invoke the same
repository-owned root, Viewer, launcher, release, and documentation scripts as
GitHub Actions. Invoke `mix prepush` directly only for static or Dialyzer
diagnosis, or when hooks are unavailable. Secret-dependent and model-driven
E2E tests require their documented credentials; deterministic tests remain the
authority for containment, ownership, accounting, rollback, and cleanup.
