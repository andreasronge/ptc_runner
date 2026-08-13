# Kernel maintainer guide

**Audience: people changing PtcRunner itself.** Application authors should use
the [Quickstart](quickstart.md), [manifest guide](manifests-and-capabilities.md),
[host configuration](host-configuration.md), [agent guide](building-agents.md),
and [Kernel REPL guide](kernel-repl.md).

This guide is an architectural map. Exact fields, return values, limits, state
transitions, and error atoms belong in the owning `PtcRunner.Kernel.*` or
`PtcRunner.Lisp.*` module documentation. Language semantics live in the
[PTC-Lisp specification](../ptc-lisp-specification.md), trace semantics in the
[TraceLog contract](../trace-log-contract.md), and admitted Java behavior in
the generated [Java interop reference](../java-interop.md).

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

## Bundles and authority

`PtcRunner.Kernel.compile_bundle/1` compiles a closed component dependency
graph into a `FrozenBundle`. Compilation records public exports and transitive
`tool:*` requirements but grants no capability.

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
as a callable-surface change. [Components and preludes](components-and-preludes.md)
has the author-facing rules.

`MissionInventory` owns the deterministic structured and prompt-facing mission
API projection. `agent.prompt` renders model context. Prompt visibility never
changes the underlying environment grant.

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
reasons.

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

## Providers

The catalog has no implicit providers. CLI commands receive aliases from the
strict host document; embedding code constructs an explicit catalog. Exact
installation fields and source types belong in
[Host configuration](host-configuration.md).

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

Run focused tests while editing, then:

```bash
mix precommit
MIX_ENV=dev mix docs --warnings-as-errors  # when documentation changed
```

For an ordinary push, let the tracked pre-push hook invoke the same
repository-owned root, Viewer, launcher, release, and documentation scripts as
GitHub Actions. Invoke `mix prepush` directly only for static or Dialyzer
diagnosis, or when hooks are unavailable. Secret-dependent and model-driven
E2E tests require their documented credentials; deterministic tests remain the
authority for containment, ownership, accounting, rollback, and cleanup.
