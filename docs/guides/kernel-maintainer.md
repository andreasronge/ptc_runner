# Kernel maintainer guide

This guide is the architectural map for the implemented Kernel. It explains
ownership and responsibility boundaries without duplicating field-level API
reference. Exact options, return values, limits, state transitions, and error
atoms belong in the owning `PtcRunner.Kernel.*` or `PtcRunner.Lisp.*` module
documentation.

For application authoring, start with
[Getting started](getting-started.md), the
[manifest guide](manifests-and-capabilities.md),
[Host configuration](host-configuration.md),
[Building agents](building-agents.md), and the
[Kernel REPL guide](kernel-repl.md). PTC-Lisp semantics live in the
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
`PtcRunner.Kernel.ApplicationPackage` and a sealed
`PtcRunner.Kernel.RunRequest`. The closed command pipeline uses
`PtcRunner.Kernel.CommandEngine`; the existing Mix command remains on its
transitional `RunBuilder` adapter until frontend integration is complete.
Embedding frontends pass their sealed request to the path-free
`PtcRunner.Kernel.RunCoordinator`, then pass its sealed `PreparedRun` to
`PtcRunner.Kernel.RunBuilder.build_prepared/3`. Frontends must not create
another manifest parser, provider registry, event model, or evaluator; once
integrated, command frontends must also share the engine's argv parser and
diagnostic vocabulary.

When placing new behavior, prefer the lowest layer that must own it:

- containment or authority belongs in the Kernel;
- replaceable orchestration belongs in PTC-Lisp;
- external effects become explicit capabilities;
- frontend-only interaction remains above `RunBuilder`.

## Run lifecycle

The normal path is:

```text
directory or memory documents + host-owned registry
          |
          v
ApplicationSource -> Manifest -> ApplicationPackage
                                  + ExecutionInput
                                  + ExecutionPolicy
                                          |
                                          v
                                   sealed RunRequest
                                          |
                                          v
                  RunCoordinator.prepare (path-free phases 4-5)
                                          |
                                          v
                         RunBuilder -> immutable RunConfig
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

`PtcRunner.Kernel.ApplicationSource` is the bounded, caching byte-acquisition
boundary. Directory and memory sources feed the same
`PtcRunner.Kernel.Manifest` decoder. The manifest decoder never creates
executable host callbacks. `PtcRunner.Kernel.ApplicationPackage` retains the
captured path-free source closure and semantic application identity;
`PtcRunner.Kernel.ExecutionInput` separately retains the selected input and
its authority class. A destination-free `PtcRunner.Kernel.ExecutionPolicy`
fixes event identities, inspection capture, and result projection before the
three values are sealed as one `PtcRunner.Kernel.RunRequest`.
`PtcRunner.Kernel.ProviderRegistry` maps selected names to trusted builders.
`PtcRunner.Kernel.RunCoordinator.prepare/2` compiles the captured workflow and
mission component graphs, validates the public workflow entry, and performs
provider-inert declaration checks without accepting a path or invoking a
builder. The returned `PreparedRun` owns its monotonic activity-marker process;
construction atomically claims a fresh false marker, so an active or previously
claimed marker cannot be shared by another prepared run. Its creating process
must retain the marker link through construction. Consuming the prepared run
atomically transfers that link and the marker's creator monitor to the
consuming process; cross-process construction and unlinked markers are
rejected. The current owner must call `PreparedRun.close/1`, which is
idempotent, and owner death closes the marker even after a normal exit. Marker
calls carry a five-second server-clock deadline and a short reply grace: a
backlogged call fails boundedly, and processing it after the deadline cannot
apply the queued transition. An expired close still checks the caller against
the current controller, so a delayed creator cannot terminate the marker after
ownership transfers.
Until inert provider descriptors land, `PreparedRun` itself admits only
provider-free requests; provider-bearing preparation stops at the closed
`selection_unverifiable` diagnostic and cannot bypass that boundary by calling
the constructor directly.
Construction binds each frozen bundle's component IDs, source hashes,
dependency edges, mission presence, and exported entry back to the sealed
request. `RunBuilder.build_prepared/3` atomically consumes the prepared run
before assembly; sequential or concurrent reuse is rejected. Keyword shape,
duplicate and unknown keys, pure option types, and mutually exclusive option
pairs are rejected before acquisition, artifact anchoring, or that consumption,
so a caller may correct a side-effect-free option error and use the same
prepared run. Input, component-override, and result-projection options belong
only to document acquisition; `build/3` and `build_prepared/3` reject them
instead of silently competing with the sealed request. They consume the sealed
request, entry expression, and correlated frozen bundles without reconstructing
coordinator-owned fields. The provider-free
`RunBuilder.build/3` convenience path crosses that same boundary and closes its
temporary prepared run after assembly.
`PtcRunner.Kernel.RunBuilder` remains the shared environment assembly and
cleanup boundary.

The staged `PtcRunner.Kernel.CommandEngine` core allocates a command reference
before strict argv parsing, consumes host/application paths through acquisition
adapters, and projects failures into `PtcRunner.Kernel.CommandOutcome`. It is
not yet the public Mix or standalone adapter. After frontend integration, only
an outer standalone wrapper may turn the outcome's status into a process exit.
Successful `validate` and `run` preparations return a sealed
`PtcRunner.Kernel.CommandPreparation`, not a bare `PreparedRun`. That wrapper
retains the original command reference, inert registry, and only the artifact
destinations needed by phase 6 alongside the separately sealed path-free
prepared run; acquisition paths do not survive into it. Construction validates
the complete registry, requires its installed limits to match the captured
package, requires JSON result projection, binds inspection presence to the
sealed policy, and binds a requested trace directory to policy IDs equal to the
command reference. Relative artifact destinations are anchored once against the
invocation working directory immediately after strict parsing, before host or
application acquisition, so later continuation work and VM-global cwd changes
cannot reinterpret them. The sealed wrapper accepts only absolute destination
paths and its exact field set. If the invocation cwd is unavailable, the engine
seals the ordered keys it could not anchor alongside every absolute destination.
Phase 6 can therefore preflight earlier absolute classes before projecting an
`invalid_destination` for a later unanchored class, preserving the fixed
trace/inspection/result precedence. A failed or exceptional wrapper
construction releases the prepared run's activity owner before the engine
projects its closed internal diagnostic. Long switch names use their documented
dashed spellings, and underscore spellings before the `--` option terminator
are rejected before `OptionParser` normalization can create an alias; positional
values after the terminator remain opaque to both spelling and duplicate
checks. The exact `--version` token is resolved across the option-bearing
prefix before command dispatch; combining it with any other token is therefore
a version-mode argument failure even when the preceding command token is
unknown.
The renderer accepts closed `CommandDiagnostic`, `CommandSource`, and
`CommandSubject` values; it never inspects an arbitrary exception or rejected
value. The authoritative phase/code/exit/retryability/message rows live in
`PtcRunner.Kernel.DiagnosticCatalog`, and `mix ptc.gen_docs` projects them into
`priv/schemas/ptc-command-envelope-v1.schema.json`.
`CommandOutcome` is itself sealed over its exact command mode, validated
envelope, and exit status. Frontends render only through
`CommandOutcome.to_map/1`; direct or nested mutation invalidates the
attestation. Non-run outcomes admit only the phase/code rows reachable by that
command, as exact pairs rather than whole phases. Static command modes require
`provider_activity: false`; the private `{:doctor, :connect}` mode admits only
active doctor and provider-cleanup rows while retaining the public `"doctor"`
command value. Successful default doctor outcomes require activity false and
only local/declarative/skipped provider checks. Successful connect outcomes
preserve the marker's actual activity value and admit only completed
local/declarative-or-active provider checks; an active pass requires activity
true, while a provider-free connect can remain false. Default doctor also binds
provider rows to application presence: host-only groups require
`application_required` and omit selection, while application-backed groups
cannot use that skip. Because V1 has no public connect-mode field, the generated
doctor branches are the union of default and connect outcomes; the sealed
outcome is the boundary that distinguishes the two modes.
Every attested command/coordinator value validates its exact declared field set
before validating its payload attestation. An otherwise authentic nested value
with an undeclared field is therefore invalid at its own boundary and cannot be
re-attested by an outer continuation.
The catalog also owns the phase/code-specific source kinds, provider-subject
operations, operation-specific occurrence policy, and activity policy used by
both constructors and the generated schema. Provider diagnostics cannot carry
document provenance and non-provider diagnostics cannot carry provider
subjects. Activity is fixed false through local preflight and fixed true for
active preflight and provider acquisition. Provider execution and provider
cleanup codes also require true, while other later codes admit the marker's
actual monotonic value. Occurrence indices use the manifest's closed `0..31`
bound in both the typed subject constructor and the generated envelope schema.
Installation-declaration `dependency_invalid` diagnostics use operation
`declaration` with a null occurrence; selection-specific declaration failures
retain their workflow or mission occurrence.
A non-null byte span is admitted only when its
`CommandSource` was constructed with the exact trusted source bytes and the
exclusive end offset is within that retained byte bound.
The command-specific host loader preserves closed phase-2 causes instead of
projecting every failure to `host_invalid`: inaccessible files are
`host_unavailable`, invalid bytes/JSON are `host_invalid`, structural failures
are `host_schema_invalid`, and invalid installed limits are
`installed_limit_invalid`. Structural and limit diagnostics carry only a path
authorized by the generated host schema. Duplicate properties are structural
host failures. The command loader retains
their schema-authorized parent pointer (the empty pointer for a root duplicate)
instead of collapsing them into an unlocated JSON failure.
Non-null diagnostic paths require a non-null source and are admitted only for
the catalog's phase/code/source-kind combinations; source-less provider
diagnostics therefore cannot carry a path. Finished execution records have two
disjoint schema branches: `ok` requires a null diagnostic and `error` requires
a non-null closed diagnostic. Unclassified run failures admit only
`execution.state: "not_started"`; successful run branches bind normal/private
result projection to the same artifact class. Successful trace and inspection
artifacts are only `not_requested` or `written`; a normal result has the same
choice, while a private result must be `written`. Recovery-only publication
states are confined to the result field of a failed envelope. The generated
schema additionally requires a compatible publication diagnostic as either
the primary or a secondary before it admits
`recovery_written` or `finalization_uncertain`; an unrelated execution,
phase-6 destination, or cleanup failure cannot claim a recovery artifact by
itself.
Trace/inspection publication failure or a late destination collision can
justify only `recovery_written`. `finalization_uncertain` requires result
publication failure, because only final-link processing can make the remaining
name set ambiguous. A generic caught `internal_error` carries no publication
stage evidence and therefore cannot justify either recovery state.
Compound outcomes validate the catalog-owned precedence before rendering: the
primary and up to six secondaries must be in order, no phase/code/subject
identity may repeat, and only one diagnostic may come from each cleanup,
internal-catch, result-guard, Kernel-or-session-opening, event-sink,
inspection-sink, or publication category.
Commands that stop before compound work require `secondary_errors: []` in both
their sealed outcome constructor and generated envelope branch.

Help, version, and doctor success values are closed data contracts, not merely
shape-compatible maps. Help usage/notices and the packaged version are exact
compile-time constants. Doctor check names and status/code pairs come from the
closed runtime/application/viewer/provider vocabulary. The generated schema
requires the runtime/application/viewer prefix. Consumers must additionally
call `CommandContract.valid_success_semantics?/2` after schema validation for
the byte-order and per-provider-local ordering rules that JSON Schema cannot
express; the same predicate owns `models` ordering. A lone successful `local`
provider check admits either activity value because its public row deliberately
does not reveal whether the implementation was audited-local or unverified.
Each `models` row preserves the host contract's free-form, non-NUL
`installation_revision` of 1 to 256 UTF-8 bytes; it is not constrained by the
provider-alias grammar. The semantic success predicate enforces the byte bound
that JSON Schema `maxLength` cannot express.
Any successful active selection, credential, authorization, or connectivity
check still requires `provider_activity: true`, and no provider check requires
false.

Public diagnostic paths originate as typed property/index segments.
`PtcRunner.Kernel.ValueContract` is sealed at bounded compilation and retains a
segment only while walking the exact local schema node that declares it,
stopping at the first unknown segment.
Manifest structural validation likewise retains each known section, list
index, declared field with an invalid value, and declared missing property
while stopping before an unknown key. Directory and in-memory acquisition use
the same typed manifest path.
Host structural paths are independently admitted against the generated host
schema.
Strict JSON decoding can retain a duplicate property's raw parent location for
the manifest loader, but only the prefix authorized by the generated manifest
schema crosses into the typed diagnostic path.
The applicable host, manifest, or contract schema walker seals those segments
as an attested `CommandPath`;
`CommandDiagnostic` rejects raw segment lists and performs only RFC 6901
escaping of the sealed path. Contract paths additionally carry their compiled
contract's sealed classification authority and are authorized only against the
selected tagged-union branch that produced the classification. The public
classification map omits the internal branch selector; separate attested
evidence supplies the exact branch schema used to construct the authority.
`ExecutionInput` carries that authority with the bounded rejection
classification;
`CommandEngine` binds that authority to the diagnostic source independently of
the selected path. Diagnostic construction then requires the path authority to
match the source binding, so a path minted from another contract is rejected
even when both are contract-authorized. The same check rejects recombining a
path and source from different classified branches of one contract, while a
path declared only by another union branch cannot be minted. It does not parse
flattened strings or retain the rejected input. Manifest contract-load failures
retain their
portable logical contract name, and bundle failures attributed to one
component retain its portable origin (falling back to its safe component ID);
directory and memory acquisition therefore produce the same public provenance.
External override records that cross aggregate acquisition limits retain the
fixed override source role instead of being attributed to the manifest.

Assembly compiles components, builds providers, constructs workflow and mission
environments, freezes limits and inventories, and returns one
`PtcRunner.Kernel.RunConfig`. A configuration is one-shot. The Runner owns its
state and attached provider work until terminal publication; provider resources
close only after in-flight work is cancelled and observed.

Construction failures close already-built resources in reverse order.
Frontends that build but do not execute a configuration must call the
documented `RunBuilder` close operation.

Directory acquisition opens each referenced logical document at most once and
compilation uses only the retained bytes. This prevents a single captured path
from changing between validation and compilation. It is not a transactional
snapshot across independent files: trusted deployments must keep an
application directory quiescent during closure acquisition or publish an
immutable versioned directory. Memory acquisition rejects unused supplied
documents, so its map is the exact referenced closure. A multi-segment memory
manifest name establishes the same logical root as the directory containing a
filesystem manifest: component, input, contract, and selected-input names are
resolved relative to it, and the transport prefix does not consume their
logical-name byte or segment limits. Aggregate memory bytes are capped before
document UTF-8 scans.
Acquisition failures originating in an explicit input or component override
retain only a closed `{:source_role, role, reason}` tag. Command projection
uses that tag to select the fixed public `input.json` or
`component-override.json` provenance; it never retains the caller's path.
Descriptor decoding may additionally retain a typed path authorized by the
closed four-field override schema. Duplicate and unknown fields expose only
their safe parent; an invalid declared field may expose that declared field.
Descriptor/source byte ceilings and descriptor JSON depth/node ceilings remain
structural `document_limit_exceeded` failures through both captured and
external override acquisition; they are not collapsed into an override-schema
failure.
Manifest-declared input failures remain attributed to `ptc.json`.

## Application and semantic identity

`application_content_digest` is input-independent identity for captured
application content. It uses the versioned
`ptc.application-content.v1\0` framing documented by
`PtcRunner.Kernel.ApplicationPackage`: a sorted record stream covers the
projected manifest, environment-qualified local and shipped component source,
direct dependency lists, exact contract bytes, and verified override
identities. The complete manifest input declaration is replaced by the fixed
`{"$ptc_input":"excluded"}` marker. Input form, logical name, bytes, value, and
digest therefore cannot perturb content identity.

Identity-bearing semantic JSON uses
`PtcRunner.Kernel.TypedCanonicalJSON` (TJCS). It tags every node before
canonical encoding, so integers and binary64 floats retain different
identities, negative zero is preserved, and arbitrarily large JSON integers
never collapse through IEEE-754. `PtcRunner.Kernel.StrictJSON` supplies the
shared duplicate-key, UTF-8, finite-number, depth-64, and node-100,000
admission boundary in a time- and heap-bounded worker.

Contract behavior identity is computed from the compiled normalized schema.
Its schema-aware traversal removes `title` and `description` only at admitted
schema positions and preserves application property names with those literal
spellings. Exact raw contract bytes remain part of content identity, while the
`ptc.contract-behavior.v1\0` hash represents normalized behavior.

`ptc_semantic_revision` is `sem1-` plus lowercase SHA-256 over the generated
semantic-build projection and the exact Elixir, OTP, ERTS, BEAM architecture,
compiled scheduler-derived pmap default, conditionally compiled semantic-module
presence, and consuming-build dependency-artifact projection. Dependency
presence, regular-file identity, the complete owner/group/other execute mask,
and the bytes under each present dependency's compiled `ebin` and `priv`
directories are captured once under the trusted immutable-build assumption.
Artifact bytes are hashed in bounded chunks, so runtime revision construction
does not retain the complete dependency closure in memory.
Starting from audited runtime roots, the projection traverses required,
included, and optional `.app` metadata, records absent optional applications,
and follows the required closure of every application that is present.
Compatible downstream resolutions, scheduler-dependent compiled defaults,
conditional-compilation outcomes, optional-dependency presence, and
execute-mask changes therefore cannot reuse the publisher's revision.
`priv/semantic_build_inventory.exs` owns the classified source boundaries,
code-owned Mix application defaults, explicit semantic files, conditionally
compiled semantic modules, runtime roots, publisher dependency closure, and
local path-dependency content.
The command parser, outcome/envelope/diagnostic/path types, sealed contract
classification evidence, help/version data, and diagnostic catalog are
explicitly classified as frontend contracts and excluded from this
execution-semantics closure. `RunCoordinator`,
`PreparedRun`, and `ProviderActivity` remain included because they participate
in execution preparation and ownership. A frontend wording or argv-only change
therefore does not invalidate application identity, while a coordinator change
does.
Regenerate with
`mix ptc.gen_semantic_revision`; `mix precommit` runs the `--check` form and
fails on dependency inventory drift, missing classified paths, changed
semantic bytes, or a stale projection. This revision is conservative:
comments, refactors, dependency changes, or runtime patch changes may produce a
new value even when observed behavior is unchanged.

## Bundles, environments, and capabilities

`PtcRunner.Kernel.compile_bundle/1` compiles a closed component dependency
graph into one `PtcRunner.Kernel.FrozenBundle`. Compilation validates code and
records requirements; it grants no authority.

`FrozenBundle.hash` is the canonical V2 identity of the complete component
graph. It covers each component ID, source hash, and sorted unique direct
dependency list in a domain-separated, length-framed byte format. Rewiring an
edge therefore changes bundle identity even when every component ID and source
byte remains unchanged.

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

Components may compose other components through declared acyclic dependencies.
Edges should point toward lower-level reusable behavior: capability facades may
reuse pure support components, while policy and ergonomics layers compose the
facades. The bundle compiler admits only public exports from direct dependency
namespaces and derives capability requirements through those calls. Evaluated
source can call every public export in the resolved bundle, including
`:discoverable` exports omitted from model prompts, so every new edge is also a
callable-surface review. Those exports are reachable in practice as well as in
principle: `dir`, `apropos`, `doc`, and `export-meta` read the attached
prelude's public exports at runtime, filtered to what the calling program may
invoke, so what a program can discover matches what it can call.

Installed-library selections expand transitively in manifests and through
`Library.resolve_components/1`; raw `compile_bundle/1` callers still provide a
closed set. Fixed analysis profiles go further: their declared component,
namespace, and capability sets must equal the resolved environment exactly.
Declaration order is not significant. Runtime identity records components in
the bundle compiler's canonical dependency order and namespaces and
capabilities in lexical order, so harmless recipe reordering does not change
the digest. The bundle hash still identifies the exact compiled build, and a
source-only bug fix changes the digest. Change the profile ID when the declared
callable surface, authority, limits, persistence policy, result policy, or
other published behavioral contract changes.

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

Limits are host-enforced ceilings. `PtcRunner.Kernel.LimitCatalog` is the
checked-in authority for every field's public name, scope, compiled and
installed defaults, inclusive range, and effective-identity participation.
Every complete installed-limits struct is checked against those rows before an
application source or provider builder is opened. Manifests may narrow only
`:manifest_narrowable` rows; installed-only operational timeouts pass through
unchanged. Host and manifest schemas are generated from the same scoped rows,
and documentation generation fails when the catalog and `Limits` struct
diverge. `PtcRunner.Kernel.Limits`, `RunState`, `BoundedWorker`, and
`Dispatcher` document exact counters, deadlines, byte accounting, and cleanup
ordering.

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

Builder selection context is path-free. It carries
`application_content_digest`, target environment, construction owner,
effective limits, and installed ceilings. Application directories and reader
callbacks never cross the package/selection boundary. Any provider-owned
filesystem roots come from the trusted host installation instead.

The MCP adapter is one host-installed source with typed Streamable HTTP and
stdio transports. Endpoints or process launch details, credentials, upstream
mapping, read/write effects, and installed ceilings are host authority; server
annotations are not. A manifest may only select mapped names and narrow
visibility or limits. Every write-bearing installation requires an explicit
non-empty manifest `allow`, while an all-read installation retains the omitted
`allow` convenience.
`PtcRunner.Kernel.MCPSource` owns common discovery and capability assembly,
`PtcRunner.Kernel.MCPProtocol` owns pure protocol validation and normalization,
and the transport owners bound and correlate each request. Their module docs
define the exact behavior. MCP tool errors are closed by default; a host
mapping may opt into validated feedback bounded to 1,024 bytes, with terminal
control characters replaced before exposure. Runtime
calls propagate only a derived W3C `traceparent`, with no baggage or
operator-supplied trace value crossing the provider boundary. Immutable MCP
sources may freeze a host-installed content identity during assembly; this is
provider provenance, not a mission capability grant.

`MCPSource` labels deterministic local call failures `:not_dispatched` and
anything after the HTTP operation begins or a stdio write may have been accepted
`:possibly_dispatched`. Dispatcher consumes that internal evidence: a possible
write becomes non-retryable with indeterminate mutation state, while the
transport provenance never reaches Lisp.

Streamable HTTP and MCP OAuth use the shared direct-Mint
`MCPHTTPAdapter` HTTP/1 boundary. Each request owns one non-pooled connection,
enforces cumulative response-header and body ceilings, and carries one absolute
deadline across bounded DNS resolution, peer pinning, connection, and response
streaming. Returning `:halt` after a complete SSE response, response-size
rejection, or SSE parser rejection closes the response stream. Killing the
request task on deadline expiry, caller death, provider close, or source-owner
death closes it as well. HTTP cancellation never sends
`notifications/cancelled`; stdio retains its protocol notification.
Cancellation remains advisory and cannot make a possibly dispatched write
retryable.

OAuth authority and grant state stays behind `MCPOAuth.Store`.
`MCPOAuth.Authorization` owns explicit, callback-agnostic authorization-code
flows, while a principal-scoped `MCPOAuth.TokenManager` coordinates only local
single-flight refresh leadership. Discovery, store round-trips, credential
resolution, and network I/O run in bounded non-owner tasks rather than either
owner callback. The store atomically fences bearer admissions, refresh/code
dispatch, generation commits, requirements, and retirement. A worker death
after token dispatch is positive process fencing: the in-memory adapter
terminalizes the exact authorization flow or poisons the refresh generation;
lease expiry by itself never restores a possibly spent credential.
Request completion uses a separate bounded cleanup budget and acknowledges its
admission release before removing owner state. If an admitted worker exits
without that acknowledgement, the request context retains the opaque release
operation and retries it asynchronously; durable adapters cannot depend on
BEAM process monitors to drain an admission. An unacknowledged ordinary
release irreversibly terminates the admitted worker before that detached
cleanup begins. OAuth admission runs in context-owned asynchronous work. If the
request caller exits before receiving its header, the context adopts and
releases any admission created by that work. Provider close returns an error
and leaves that cleanup owner running while a release remains unacknowledged;
it never reports success by killing the retry state.
Likewise, `401` rejection and valid `403 insufficient_scope` handling install a
runtime-shared local generation/requirement fence before durable persistence,
using a fresh bounded post-response transition budget rather than the exhausted
HTTP request deadline. A definitive `401` status line ends processing
immediately, even if the remaining header block is oversized, malformed, or
stalled. A `403` ends processing after its complete bounded challenge headers
and before its body. The HTTP response callback contacts the token manager
before returning a result to the bounded provider task. The manager starts the
bounded persistence worker atomically with the shared fence, so a Dispatcher
timeout cannot skip the durable transition.
A store failure is a transport failure and cannot make that manager—or a
replacement manager for the same local store and grant key—reissue the rejected
authority; only a strictly newer sufficient grant clears the local fallback.
Each secret-free fallback transition has its own process-independent
`:persistent_term` entry. Admission reads and clears satisfied entries in one
operation, so there is no fence-owner restart window within the running VM.
Manager shutdown drains in-flight response persistence before discarding that
fallback. Failed persistence is retained and retried once per close attempt;
continued failure makes transport shutdown fail while the runtime keeps the
shared fence. When provider acquisition fails before it can return a close
handle, the supervised OAuth cleanup owner adopts the token manager and retries
that bounded shutdown, so the retained fence cannot become an orphaned process.
An ordinary or malformed dynamic `403` that is not one valid satisfiable
`insufficient_scope` challenge is a non-retryable authentication or
authorization result; it is not mislabeled as a retryable transport failure.

Concurrent managers may observe an active refresh mutation lease. Followers
reload and wait outside all owner processes, bounded by their request deadline,
until the winner commits a usable generation, safely releases an undispatched
lease that a follower can acquire, or the grant becomes authorization-required.

The client advertises no MCP elicitation, sampling, or roots capabilities and
never retries an `input_required` result. On `tools/call`, `prompts/get`, or
`resources/read`, a structurally valid state-only result, including an empty
load-shedding request map accompanied by `requestState`, is a closed denied
policy refusal; a schema-valid non-empty request map is a
capability-negotiation error. Malformed request entries and
`input_required` on any other method are protocol errors. Provider denial is
terminal at the agent correction boundary, as are the capability-negotiation
and protocol classifications. The provider owner records that terminal
classification before publishing the result, so a later evaluator error,
timeout, or heap kill cannot trigger a correction turn. Once a tool call may
have been dispatched, all three causes preserve the operator-declared effect,
so a write remains indeterminate.

PtcRunner-owned canonical traces remain native rather than passing through
MCP. A host-installed `ptc_trace_snapshot` uses `TraceSnapshot` to capture one
directory and `TraceCapability` to expose the same four canonical `TraceLog`
queries used by `log-analysis-v2`. A paired private
`ptc_inspection_snapshot` receives that already captured trace through the
provider acquisition service, validates all artifacts and correlations before
publication, and exposes the shared `InspectionQuery` layer through
`InspectionCapability`.

Local analysis profiles are fixed, code-owned recipes selected through the
closed `AnalysisProfileRegistry`. `AnalysisSessionBuilder` is the host entry;
`AnalysisSession`, `SessionTrace`, and `AnalysisResources` share continuation,
publication, and cleanup without letting a caller supply modules,
capabilities, limits, or sink policy. `log-analysis-v2` remains the Viewer and
ordinary terminal profile. `inspection-analysis-v2` adds correlated
`TraceSnapshot` and `InspectionSnapshot` captures behind a private
interactive-terminal gate. Browser or Lisp input does not supply profile
internals or paths.

## Code map

| Responsibility | Primary owners |
| --- | --- |
| Public run boundary | `Kernel`, `RunConfig`, `Result`, `Error` |
| Components and libraries | `Component`, `FrozenBundle`, `Library`, `BundleCompiler` |
| Environment authority | `Capability`, `WorkflowEnvironment`, `MissionEnvironment`, `Environment` |
| Host/application assembly | `HostConfig`, `HostInstallation`, `ApplicationSource`, `Manifest`, `ApplicationPackage`, `ExecutionInput`, `ExecutionPolicy`, `RunRequest`, `ValueContract`, `ResultArtifact`, `ProviderRegistry`, `RunBuilder`, `MissionInventory` |
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

1. Reuse `ApplicationSource`, `ApplicationPackage`, `RunRequest`, and
   `RunBuilder`.
2. Keep manifest data non-executable, logical names portable, and directory
   acquisition confined.
3. Preserve workflow/mission authority and installed-ceiling precedence.
4. Keep input outside application content identity and destinations outside
   the sealed execution policy.
5. Keep stdout/stderr and canonical/private artifacts unambiguous.
6. Exercise the same configuration through normal run and REPL paths where
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
