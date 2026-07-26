# Kernel maintainer guide

This guide is the architectural map for the implemented Kernel. It explains
ownership and responsibility boundaries without duplicating field-level API
reference. Exact options, return values, limits, state transitions, and error
atoms belong in the owning `PtcRunner.Kernel.*` or `PtcRunner.Lisp.*` module
documentation.

For application authoring, start with the
[Kernel tutorial](kernel-tutorial.md), [manifest guide](manifests-and-capabilities.md),
and [Kernel REPL guide](kernel-repl.md). PTC-Lisp semantics live in the
[language specification](../ptc-lisp-specification.md); canonical trace
storage/query semantics live in the
[TraceLog contract](../trace-log-contract.md); the admitted Java surface is
generated in [Java interop](../java-interop.md).

## Responsibility boundary

The Kernel is a bounded runtime, not an agent framework.

BEAM code owns:

- authority assembly and immutable capability grants;
- owner-process state, deadlines, quotas, and cancellation;
- process containment and provider lifecycle;
- public/private value projection; and
- unavoidable canonical events and private-capture boundaries.

PTC-Lisp owns replaceable workflow policy:

- model messages and tool protocol;
- planning, retries, feedback, and completion policy;
- application-specific composition of capabilities; and
- reusable prompt and agent behavior in shipped or local components.

Frontends own presentation and host choices. They must enter through
`PtcRunner.Kernel.RunBuilder` or construct the same public Kernel values; they
must not create another manifest parser, provider registry, event model, or
evaluator.

When placing new behavior, prefer the lowest layer that must own it:

- containment or authority belongs in the Kernel;
- replaceable orchestration belongs in PTC-Lisp;
- external effects become explicit capabilities;
- frontend-only interaction remains above `RunBuilder`.

## Run lifecycle

The normal path is:

```text
manifest + host-owned registry
          |
          v
Manifest -> RunBuilder -> components/providers/limits/input
                         |
                         v
                 immutable RunConfig
                         |
                         v
Kernel.run -> Runner -> RunState + Dispatcher + Evaluation
                         |
                         +-> Result | Error
                         +-> canonical EventSink batch
                         +-> optional private inspection records
                         |
                         v
             close providers and persist artifacts
```

`PtcRunner.Kernel.Manifest` strictly decodes untrusted data and confines
manifest-relative paths. It never creates executable host callbacks.
`PtcRunner.Kernel.ProviderRegistry` maps selected names to trusted builders.
`PtcRunner.Kernel.RunBuilder` is the shared assembly and cleanup boundary.

Assembly compiles components, builds providers, constructs workflow and mission
environments, freezes limits and inventories, and returns one
`PtcRunner.Kernel.RunConfig`. A configuration is one-shot. The Runner owns its
state and attached provider work until terminal publication; provider resources
close only after in-flight work is cancelled and observed.

Construction failures close already-built resources in reverse order.
Frontends that build but do not execute a configuration must call the
documented `RunBuilder` close operation.

## Bundles, environments, and capabilities

`PtcRunner.Kernel.compile_bundle/1` compiles a closed component dependency
graph into one `PtcRunner.Kernel.FrozenBundle`. Compilation validates code and
records requirements; it grants no authority.

Authority appears only when a frozen bundle is placed in an environment:

| Environment | Purpose | Typical grants |
| --- | --- | --- |
| `WorkflowEnvironment` | trusted orchestration | model requests, annotations, subordinate evaluation |
| `MissionEnvironment` | confined generated programs | narrowly selected files, remote tools, or trace queries |

The subordinate evaluator receives only the mission environment. It never
inherits or falls back to workflow capabilities. Preserve that separation in
data structures and function inputs rather than relying on symbol filtering.

Each `PtcRunner.Kernel.Capability` freezes its public identity, effect,
visibility, bounded schemas, validator, and trusted callback. Environment
membership grants authority; descriptions and remote annotations do not.
Public prelude signatures/types and direct capability schemas are compiled
before execution and remain authoritative at their respective boundaries.

`PtcRunner.Kernel.MissionInventory` owns the deterministic structured and
model-facing projections of the mission API. The shipped `agent.prompt`
component renders the model context. When prompt-visible prelude functions
exist, they form the facade and raw capabilities are omitted from the prompt;
the underlying environment grant is unchanged.

Exact component, schema, inventory, prompt-rendering, and projection rules live
in `Component`, `FrozenBundle`, `Capability`, `MissionInventory`, and the Lisp
runtime-contract module docs.

## Subordinate evaluation and workflow policy

The reserved `kernel-eval` capability delegates dynamic or compiled mission
programs to `PtcRunner.Kernel.Evaluation`. One transactional continuation is
owned by `RunState` for the whole run.

At a high level:

- ordinary success continues the workflow and commits bounded definitions and
  result history;
- explicit `return` commits and completes successfully;
- explicit `fail` terminates as a workflow failure; and
- parse, analysis, runtime, limit, projection, and capability failures do not
  alter the previously committed continuation.

Only inert public observations cross back into workflow Lisp. Native
definitions, result history, callables, Java provenance, and evaluator context
remain inside the continuation owner. The exact outcome algebra, history
rules, correction feedback, and commit preconditions are documented by
`PtcRunner.Kernel.Evaluation`, `PtcRunner.Kernel.RunState`, and
`PtcRunner.Kernel.ReplSession`.

Evaluator audit effects use one `PtcRunner.Lisp.Eval.Effects` representation.
Nested host callbacks use the evaluator capture boundary, and parallel
evaluation separates Lisp semantics from process scheduling. Do not duplicate
effect merge/order rules or outcome transport outside the owning
`PtcRunner.Lisp.Eval.*` modules.

The shipped `agent.core` component owns the multi-turn provider/evaluation
loop. Prompt wording and transition policy belong in `agent.prompt`; hard
limits and capability authority remain in the Kernel.

## Ownership, limits, and concurrency

`PtcRunner.Kernel.RunState` is the single mutable owner for one run. It owns
the deadline, open/closed state, reservations, usage, protocol errors, terminal
failure, and mission continuation.

Any decision that depends on current owner state must be one atomic owner
operation. A separate read followed by an update is a race and is
review-blocking.

`PtcRunner.Kernel.Dispatcher` validates calls, reserves budgets, supervises the
trusted callback process, normalizes results, and rejects late completion after
timeout or closure. Run termination kills and drains attached provider work
before connector cleanup. Providers are trusted host extensions: the Kernel
contains ordinary faults and bounded results, but it is not a security
sandbox for malicious BEAM code.

Limits are host-enforced ceilings. Manifest values may narrow installed
ceilings; Lisp policy such as turn counts cannot grant more authority.
`PtcRunner.Kernel.Limits`, `RunState`, `BoundedWorker`, and `Dispatcher`
document exact counters, deadlines, byte accounting, and cleanup ordering.

Standalone `PtcRunner.Kernel.ReplSession` is process-affine. Passing its public
value does not transfer ownership. A product that needs transferable or
multi-client sessions requires a separate supervised abstraction rather than
weakening the current owner contract.

## Results and observability

The public execution algebra is `{:ok, %PtcRunner.Kernel.Result{}}` or
`{:error, %PtcRunner.Kernel.Error{}}`. Capability failures are normally
bounded values returned to Lisp so workflow policy can decide whether they are
terminal.

Observability uses separate planes:

| Plane | Contract |
| --- | --- |
| Logger | sparse operator diagnostics; no prompts, source, capability payloads, credentials, or transport secrets |
| Telemetry | bounded low-cardinality measurements and closed metadata |
| EventSink/TraceLog | sanitized bounded canonical events and queries |
| InspectionSink/InspectionArtifact | explicit bounded private model, source, and capability evidence |

Do not copy a private field into canonical events merely because it helps
debugging. Add correlation metadata to the canonical plane and retain exact
payloads only under explicit private authority.

`PtcRunner.Kernel.EventSink` owns sequence, identity, bounds, loss policy,
terminal finalization, and the immutable terminal batch.
`PtcRunner.Kernel.TraceLog` owns canonical validation, persistence, discovery,
and queries. `PtcRunner.Kernel.InspectionArtifact` owns the exact private
artifact grammar, exclusive persistence, loading, and correlation checks.
Inspection V1 covers provider-neutral capability, source, and model evidence;
V2 additionally admits paired decoded MCP request/response bodies correlated
to an existing capability attempt. MCP inspection records never include
rendered headers or subprocess environment values.
`PtcRunner.Kernel.SafeMetadata` owns the closed labels and annotation
vocabulary.

The Viewer and `PtcRunner.Kernel.TraceCapability` delegate to TraceLog rather
than defining another event model. Custom `Inspect` implementations and
redacted owner status are defense-in-depth; runtime code must still avoid
logging payload-bearing structures directly.

## Providers and interactive frontends

The registry has no implicit providers. CLI runs receive exactly the aliases
declared by a strict host installation; trusted Elixir embedding may construct
an explicit registry of custom builders. Host installations provide workflow
LLM plus mission MCP and native snapshot sources.

Provider builders return capabilities plus optional safe connector metadata
and an idempotent closer. Staged builders may also exchange bounded code-owned
acquisition services after the global preflight and credential barrier; these
opaque values never enter environments or artifacts. `RunBuilder` resolves
those dependencies, owns construction cleanup, and transfers successful
resources into the run lifecycle. Exact selection grammar and transport
behavior belong in `ProviderRegistry`, each provider module, and the manifest
guide.

The current MCP adapter is one host-installed read-only source with typed
Streamable HTTP and stdio transports. Endpoints or process launch details,
credentials, upstream mapping, and installed ceilings are host authority; a
manifest may only select mapped names and narrow visibility or limits.
`PtcRunner.Kernel.MCPSource` owns common discovery and capability assembly,
`PtcRunner.Kernel.MCPProtocol` owns pure protocol validation and normalization,
and the transport owners bound and correlate each request. Their module docs
define the exact behavior. MCP tool errors are closed by default; a host
mapping may opt into exact validated feedback bounded to 1,024 bytes. Runtime
calls propagate only a derived W3C `traceparent`, with no baggage or
operator-supplied trace value crossing the provider boundary.

PtcRunner-owned canonical traces remain native rather than passing through
MCP. A host-installed `ptc_trace_snapshot` uses `TraceSnapshot` to capture one
directory and `TraceCapability` to expose the same four canonical `TraceLog`
queries used by `log-analysis-v1`. A paired private
`ptc_inspection_snapshot` receives that already captured trace through the
provider acquisition service, validates all artifacts and correlations before
publication, and exposes the shared `InspectionQuery` layer through
`InspectionCapability`.

Local analysis profiles are fixed, code-owned recipes selected through the
closed `AnalysisProfileRegistry`. `AnalysisSessionBuilder` is the host entry;
`AnalysisSession`, `SessionTrace`, and `AnalysisResources` share continuation,
publication, and cleanup without letting a caller supply modules,
capabilities, limits, or sink policy. `log-analysis-v1` remains the Viewer and
ordinary terminal profile. `inspection-analysis-v1` adds correlated
`TraceSnapshot` and `InspectionSnapshot` captures behind a private
interactive-terminal gate. Browser or Lisp input does not supply profile
internals or paths.

## Code map

| Responsibility | Primary owners |
| --- | --- |
| Public run boundary | `Kernel`, `RunConfig`, `Result`, `Error` |
| Components and libraries | `Component`, `FrozenBundle`, `Library`, `BundleCompiler` |
| Environment authority | `Capability`, `WorkflowEnvironment`, `MissionEnvironment`, `Environment` |
| Host/manifest assembly | `HostConfig`, `HostInstallation`, `Manifest`, `ValueContract`, `ResultArtifact`, `ProviderRegistry`, `RunBuilder`, `MissionInventory` |
| Mutable resources | `Limits`, `RunState`, `BoundedWorker`, `Dispatcher` |
| Subordinate execution | `Runner`, `Evaluation`, `RuntimeTools` |
| Lisp internals | `Lisp.Eval`, `Lisp.Eval.Effects`, `Lisp.Eval.Capture`, `Lisp.Eval.Parallel`, `Lisp.Eval.ParallelRunner` |
| Providers | `HostConfig`, `HostInstallation`, `LLMCapability`, `MCPSource`, `MCPProtocol`, `TraceCapability`, `InspectionCapability` |
| Canonical/private evidence | `EventSink`, `TraceLog`, `TraceSnapshot`, `InspectionSink`, `InspectionArtifact`, `InspectionSnapshot`, `InspectionQuery`, `SafeMetadata` |
| Interactive evaluation | `ReplSession`, `AnalysisProfileRegistry`, `AnalysisSessionBuilder`, `AnalysisSession`, `SessionTrace` |

Modules grouped as Kernel internals in ExDoc remain documented for maintenance
and review. They are not alternative supported entry points.

## Change checklists

### Capability or provider

1. Put commands, endpoints, credentials, effects, and outer ceilings under
   host authority.
2. Freeze schemas and safe metadata before execution.
3. Grant the capability only through the intended environment.
4. Bound callback execution and normalize every public result/error.
5. Prove timeout, owner death, late result, cleanup, redaction, and denied
   destination behavior through an integration path.

### Lisp runtime or agent behavior

1. Keep policy in shipped/local PTC-Lisp unless the Kernel must enforce it.
2. Update the single evaluator effect/outcome owner rather than adding a
   parallel transport.
3. Preserve transactional continuation and public projection.
4. Test direct, higher-order, parallel, and agent consumers when applicable.
5. Update the language specification only for language semantics.

### Manifest or frontend

1. Reuse `Manifest` and `RunBuilder`.
2. Keep manifest data non-executable and paths confined.
3. Preserve workflow/mission authority and installed-ceiling precedence.
4. Keep stdout/stderr and canonical/private artifacts unambiguous.
5. Exercise the same configuration through normal run and REPL paths where
   their contracts overlap.

### Events or private inspection

1. Choose the correct observability plane before adding a field.
2. Keep canonical metadata bounded, sanitized, and queryable.
3. Keep private payload capture explicit, correlated, no-clobber, and
   independently bounded.
4. Update TraceLog/Viewer consumers from the authoritative schema owner.

### Java interop

Update the authoritative Java manifest and structured oracle cases together.
Use the generated Java documentation and the pinned JVM/Babashka/PTC
conformance tasks as the behavior and overload-selection evidence. Do not add
fallback dispatch through the ordinary Lisp environment.

## Verification map

Prefer contract-level integration tests over tests that mirror implementation:

- `core_contract_test.exs` — authority, outcomes, limits, continuation, and
  dispatch;
- manifest and Mix task tests — assembly and frontend behavior;
- provider-specific tests — schema, transport, timeout, cleanup, and
  redaction;
- event/trace/inspection tests — canonical and private boundaries;
- `agent_library_test.exs` — shipped workflow policy;
- Java oracle/conformance tests — admitted Java behavior; and
- tutorial/E2E tests — real user and provider flows.

Run `mix precommit` before every commit. For an ordinary push, let the tracked
pre-push hook run the full root/Viewer tests and the canonical `mix prepush`
checks once. Invoke `mix prepush` directly only for diagnosis or when hooks are
unavailable.

Credential-free interoperability tests may run as focused push and
pull-request jobs even when tagged `:e2e`. Secret-dependent and model-driven
`:e2e` tests remain excluded from those pipelines and run through the
scheduled/manual Integration Tests workflow. Tagged tests must skip cleanly
when required credentials or network are absent, avoid fixture-only
assumptions, and assert clean instrumentation for agent flows. Live providers
are nondeterministic; deterministic tests remain the authority for confinement,
ownership, accounting, rollback, and cleanup.
