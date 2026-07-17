# Kernel maintainer guide

This guide explains how the implemented Kernel fits together. It is a map of
the runtime rather than a second API reference: exact fields, options, return
types, and defaults live beside the implementation in the
`PtcRunner.Kernel.*` module documentation.

For a workflow author's introduction, start with the
[Kernel tutorial](kernel-tutorial.md). The language itself is specified in the
[PTC-Lisp specification](../ptc-lisp-specification.md).

## Responsibility boundary

The Kernel is deliberately smaller than an agent framework.

BEAM code owns authority, resource enforcement, process containment, provider
boundaries, mutable run accounting, and unavoidable runtime events. PTC-Lisp
owns workflow behavior such as model protocols, messages, retries, feedback,
planning, and completion policy.

That split is the first test for new functionality:

- put unavoidable authority or containment in the Kernel;
- put replaceable workflow policy in a shipped or application-owned PTC-Lisp
  component;
- expose external effects as explicit capabilities;
- keep frontend concerns above `PtcRunner.Kernel.RunBuilder`.

## From manifest to result

The normal construction and execution path is:

```text
JSON manifest
    |
    v
Kernel.Manifest ---------- strict schema and confined paths
    |
    v
Kernel.RunBuilder -------- provider selection and environment assembly
    |                 \
    |                  +-- Kernel.ProviderRegistry --> Kernel.Capability
    v
Kernel.compile_bundle/1 -- component DAG, namespaces, exports, requirements
    |
    v
WorkflowEnvironment + MissionEnvironment + Limits + EventSink
    |
    v
RunConfig
    |
    v
Kernel.run/2 ------------ Runner / RunState / Dispatcher / Evaluation
    |
    +--> Kernel.Result | Kernel.Error
    +--> canonical EventSink events --> TraceLog --> viewer or log capabilities
    +--> optional InspectionSink records --> fixed local Viewer artifact
```

`PtcRunner.Kernel.Manifest` parses untrusted manifest data but never creates
executable host code. `PtcRunner.Kernel.ProviderRegistry` is the host-owned map
from manifest provider names to trusted builders. `PtcRunner.Kernel.RunBuilder`
is the shared assembly path used by `mix ptc.run` and other manifest-backed
frontends.

Direct Elixir embedders may construct the same objects without a manifest, but
they still pass one complete `PtcRunner.Kernel.RunConfig` to
`PtcRunner.Kernel.run/2`.

## Bundles and environment assembly

Bundle compilation and authority assembly are separate operations.

`PtcRunner.Kernel.compile_bundle/1` accepts an explicit closed set of
`PtcRunner.Kernel.Component` values. The internal
`PtcRunner.Kernel.BundleCompiler` validates the component dependency graph,
compiles namespaces and exports deterministically, records capability
requirements, and produces an attested `PtcRunner.Kernel.FrozenBundle`.
Compilation does not grant authority.

Every model-visible capability freezes a bounded input schema, an optional
successful-output schema, and a `read`, `write`, or `unknown` effect alongside
its public name and description. The Kernel normalizes the supported JSON
Schema profile, compiles it once with JSV, and projects only safe metadata;
callbacks and compiled validators remain host-owned. Schema validation and any
semantic validator must both pass before dispatch.

The host then places the frozen bundle, capabilities, and JSON-like data into
one of two structurally distinct environments:

| Environment | Purpose | Typical authority |
| --- | --- | --- |
| `WorkflowEnvironment` | Trusted application orchestration | model requests, annotations, subordinate evaluation |
| `MissionEnvironment` | Confined subordinate programs | narrowly granted files, databases, HTTP, or trace queries |

Environment construction verifies that the bundle's recorded tool
requirements are satisfied by that environment. Capability metadata is useful
for discovery, but membership in the environment is what grants authority.

## The subordinate evaluation boundary

Workflow Lisp can invoke the reserved `kernel-eval` route with either dynamic
source or an opaque static `program` value. Both paths enter the internal
`PtcRunner.Kernel.Evaluation` module and execute against the mission bundle,
mission data, mission capabilities, and current evaluation memory.

The central confinement invariant is:

> Subordinate evaluation is constructed exclusively from the mission
> environment. It never inherits, merges, or falls back to the workflow
> environment.

Consequently mission code cannot acquire the workflow's model provider,
recursively invoke `kernel-eval`, or emit workflow-only annotations. Preserve
this structurally in function inputs and environment construction; symbol
filtering alone is not an adequate boundary.

Definitions created by successful subordinate evaluations can persist for the
rest of the run. Commit is transactional: parse, analysis, runtime, timeout,
memory, capability, result-size, or explicit-failure outcomes preserve the
previous evaluation memory.

## Ownership, limits, and concurrency

`PtcRunner.Kernel.RunState` is the single owner of mutable per-run accounting.
It owns the deadline, open/closed state, capability counters, protocol-error
count, subordinate-evaluation lease, and committed evaluation memory.

Every reservation or commit that depends on current state must happen in one
owner operation. Do not introduce an `Agent.get`/`Agent.update` or equivalent
read-then-write sequence around run state.

`PtcRunner.Kernel.Dispatcher` validates arguments, atomically reserves call and
provider-task budgets, runs each trusted provider callback in a monitored
heap-limited process, normalizes its result, and prevents a late result from
re-entering Lisp after timeout or run closure. Each reservation monitors the
dispatching process: if that process is killed mid-call (heap or timeout kill
of its sandbox), `RunState` kills the attached provider and retains its
reservation until the provider's `:DOWN` is observed. Run termination likewise
kills and drains all attached providers before connector resources close, so
abandoned dispatches cannot exhaust the slot pool, leave callbacks running as
orphans, or race connector cleanup. Provider code is a trusted host
extension: the Kernel contains ordinary faults and bounded results, but it is
not an isolation boundary against deliberately hostile BEAM code.

`PtcRunner.Kernel.MCPSource` treats the selected `timeout_ms` as an end-to-end
deadline for pool checkout, connection establishment, response receipt, and
elapsed request work. Its lease drains active requests before a bounded
session DELETE. MCP JSON rejects duplicate object keys before protocol
validation, and discovered schemas are compiled once during assembly rather
than on each result.

Subordinate evaluation is serialized because it owns transactional evaluation
memory. A concurrent attempt receives a recoverable busy result rather than
waiting in an unbounded queue.

The complete current limits are documented by `PtcRunner.Kernel.Limits`.
`defaults/0` supplies ordinary effective runtime values, while
`installed_defaults/0` supplies larger host-controlled manifest ceilings.
`Manifest.load/2` accepts a complete host ceiling and allows the manifest only
to narrow it. Workflow turn counts, retries, and other policy budgets belong in
Lisp below those enforced host ceilings.

## Results and events

The public result algebra is `{:ok, %PtcRunner.Kernel.Result{}}` or
`{:error, %PtcRunner.Kernel.Error{}}`. Capability failures are normally bounded
values returned to Lisp; the workflow decides whether they are terminal.

Runtime observability has separate planes with separate data contracts:

- OTP Logger carries sparse operator diagnostics and never transcripts,
  prompts, source, capability payloads, credentials, endpoints, headers, or
  session identifiers. Owners retaining those values reject unknown callbacks
  without crashing and expose only constant redacted OTP status.
- Telemetry carries low-cardinality measurements. Lisp execution uses the
  `[:ptc_runner, :lisp, :execute]` prefix, the closed `:direct | :kernel |
  :repl` caller taxonomy, and `:ok | :error` semantic outcomes. Exception
  events identify only the exception class.
- `PtcRunner.Kernel.EventSink` and `PtcRunner.Kernel.TraceLog` own sanitized,
  bounded canonical run events.
- Exact sensitive development payloads belong only to an explicitly enabled
  run-owned inspection sink; Logger, Telemetry, and canonical events never
  receive them.

`PtcRunner.Kernel.EventSink` owns canonical event sequence numbers, timestamps,
queue bounds, and loss accounting. Normal policy is lossy and reports dropped
events. Private policy fails closed when it cannot retain the required event.
Run labels and workflow annotations use `PtcRunner.Kernel.SafeMetadata`.
Caller-supplied `name`, `model`, and `provider` label strings become one-way
SHA-256 fingerprints. Tags use fixed `environment`, `mode`, `stage`, and
`suite` keys with finite enumerated values. Annotations likewise accept only a
finite semantic type/key/value vocabulary. Arbitrary JSON, free-form text,
generated source, credentials, and failure values are never copied into
canonical events or ordinary Kernel error details.

`PtcRunner.Kernel.TraceLog` validates and queries completed canonical events
from an in-memory sink, one JSONL file, or a directory. The viewer and
`PtcRunner.Kernel.TraceCapability` delegate to this same query layer rather
than maintaining another event model. The detailed storage and authorization
contract remains in the retained [TraceLog contract](../trace-log-contract.md).

Host callers enable sensitive capture only through `RunBuilder`'s `:inspect`
option. `InspectionSink` accepts exact bounded source and capability records
before execution crosses the relevant boundary; rejection fails the run rather
than silently producing a partial capture. `InspectionArtifact` validates
correlation against canonical events and installs one previously absent
`.inspection.jsonl` sidecar at mode `0600`. Installation uses an atomic
hard-link create from an exclusive temporary sibling because `File.rename/2`
may replace an existing destination and therefore cannot uphold the no-clobber
contract. Loading enforces the same 2,000,000-byte encoded per-record ceiling
as capture as well as the 16 MB aggregate ceiling. TraceLog excludes the
inspection suffix. `PtcRunner.Kernel.ViewerAdapter.pin_inspection/2` loads the
host-selected artifact once at Viewer startup and validates its run/trace IDs
and every record correlation against the explicitly selected canonical trace
source. Private records live in a dedicated owner process; Bandit plug options,
Logger metadata, Telemetry metadata, and returned `Plug.Conn` values contain
only its PID, never the grant or response body. Replacing the original path
cannot change the inspected content. This is not a TraceLog operation or Lisp
capability.

## Code map

| Responsibility | Primary modules |
| --- | --- |
| Public execution boundary | `PtcRunner.Kernel`, `PtcRunner.Kernel.RunConfig`, `PtcRunner.Kernel.Result`, `PtcRunner.Kernel.Error` |
| Components and compiled code | `PtcRunner.Kernel.Component`, `PtcRunner.Kernel.FrozenBundle`, `PtcRunner.Kernel.Library`, internal `PtcRunner.Kernel.BundleCompiler` |
| Authority construction | `PtcRunner.Kernel.Capability`, `PtcRunner.Kernel.WorkflowEnvironment`, `PtcRunner.Kernel.MissionEnvironment`, internal `PtcRunner.Kernel.Environment` |
| Manifest-backed assembly | `PtcRunner.Kernel.Manifest`, `PtcRunner.Kernel.ProviderRegistry`, `PtcRunner.Kernel.RunBuilder`, `PtcRunner.Kernel.MissionInventory` |
| Enforced resources | `PtcRunner.Kernel.Limits`, internal `PtcRunner.Kernel.RunState` and `PtcRunner.Kernel.BoundedWorker` |
| Execution and dispatch | internal `PtcRunner.Kernel.Runner`, `PtcRunner.Kernel.Dispatcher`, `PtcRunner.Kernel.Evaluation`, `PtcRunner.Kernel.RuntimeTools` |
| Provider adapters | `PtcRunner.Kernel.FileCapability`, `PtcRunner.Kernel.LLMCapability`, `PtcRunner.Kernel.MCPSource`, `PtcRunner.Kernel.TraceCapability` |
| Events and inspection | `PtcRunner.Kernel.EventSink`, `PtcRunner.Kernel.TraceLog`, internal `PtcRunner.Kernel.Events` and `PtcRunner.Kernel.ViewerAdapter` |
| Interactive evaluation | `PtcRunner.Kernel.ReplSession` and `mix ptc.repl` |

Modules in the **Kernel internals** ExDoc group are documented to make runtime
maintenance and review easier. They are implementation seams, not alternatives
to the supported `PtcRunner.Kernel` and `PtcRunner.Kernel.RunBuilder` entry
points.

## Common changes

To add a host capability:

1. Construct a `PtcRunner.Kernel.Capability` with strict argument validation.
2. Return only JSON-like values or `PtcRunner.Kernel.ProviderError` failures.
3. Register a trusted builder in `PtcRunner.Kernel.ProviderRegistry` when the
   capability should be selectable by manifests.
4. Grant it explicitly to the workflow or mission environment.
5. Add an integration test that exercises the Lisp dispatch boundary, limits,
   and denied destination.

Provider builders may return one legacy capability or a normalized build with
`capabilities`, a safe optional `snapshot`, and an idempotent optional `close`
function. `RunBuilder` closes successful resources in reverse order on later
assembly failure and freezes successful resources into `RunConfig`. Normal
runs and REPL sessions stop run state—and therefore attached provider
workers—before closing those resources. Call `RunBuilder.close/1` for a built
configuration that will not be executed.

The only installed remote-tools adapter is `PtcRunner.Kernel.MCPSource`. Its
host builder freezes one HTTPS endpoint (or an explicitly enabled loopback HTTP
fixture), a header callback, read-only upstream-to-public mappings, and source
ceilings. Manifest configuration is exactly an `allow` list of mapped public
names plus optional lower `timeout_ms` and `max_result_bytes`; endpoints,
headers, upstream names, effects, and retries are not manifest fields.

Every build owns one monitored MCP 2025-11-25 session across initialization,
bounded paginated discovery, and calls. Discovered schemas pass the Kernel's
strict JSON Schema profile before capabilities are frozen. Structured results
must match an advertised object schema; otherwise only text blocks are
accepted. Mixed content, unsupported blocks, remote errors, oversized bodies,
session expiry, transport failures, and invalid schemas become bounded errors.
The safe `connector_snapshots` projection in `run-started` contains only the
provider alias, protocol, public names, effects, and deterministic schema and
snapshot hashes—never endpoint, upstream names, credentials, session IDs,
arguments, results, or response bodies. `TraceLog` run metadata preserves
these snapshots plus the mission inventory hash and encoded byte count, and
the canonical Viewer renders those safe fingerprints.

To add a shipped Lisp library, add its source under `priv/preludes/kernel/`,
register it in `PtcRunner.Kernel.Library`, declare component dependencies, and
recompile the shipped preludes. Agent policy should normally change here rather
than in the Kernel execution modules. Manifest `{"library": id}` selections
expand their installed dependency closure deterministically and are compiled
with local components; local IDs cannot shadow installed IDs.

`RunConfig` freezes one bounded deterministic mission inventory containing
prompt-visible exports, model-visible capability schemas, and mission limits.
Normal runs and REPL sessions expose the same inventory through the reserved
`kernel-mission-inventory` route. Keep this projection payload-free and update
its exact golden test whenever its versioned contract changes.

To add a frontend, build through `PtcRunner.Kernel.RunBuilder` or construct the
same public Kernel values directly. Do not create a second manifest parser,
provider registry, event schema, or execution path.

The credential-free end-to-end fixture in `examples/kernel-inspection-lab/`
runs the installed agent loop against file, native, and MCP read capabilities,
then produces canonical and private artifacts for local Viewer inspection.

## Verification map

The main contract-level tests are intentionally integration-oriented:

- `test/ptc_runner/kernel/core_contract_test.exs` — execution, confinement,
  limits, dispatch, outcomes, and transactional memory;
- `frozen_bundle_test.exs` — component graph and frozen bundle behavior;
- `manifest_test.exs` and `test/mix/tasks/ptc_run_test.exs` — manifest and
  frontend construction;
- `event_sink_test.exs`, `trace_capability_test.exs`, and
  `viewer_adapter_test.exs` — canonical event and query boundaries;
- `agent_library_test.exs` — shipped Lisp workflow policy;
- `tutorial_examples_test.exs` — checked-in user journeys;
- `deepseek_e2e_test.exs`, `mcp_remote_e2e_test.exs`, and
  `mcp_remote_agent_e2e_test.exs` — live provider and remote MCP
  verification.

Run `mix precommit` before every commit and `mix prepush` before pushing. Use
the optional E2E suite for provider integration changes; deterministic tests
remain the authority for confinement, ownership, limits, rollback, and cleanup.

The `:e2e` tag has a contract: tagged tests stay excluded from push/PR
pipelines and run on the scheduled Integration Tests workflow (also manually
dispatchable), which is the guard against silent rot. Anything tagged `:e2e`
must skip cleanly when its environment (provider API key) is absent, must not
depend on fixture-only state, and must assert clean instrumentation
(`usage.protocol_errors == 0` for agent flows). Because live providers are
nondeterministic, treat a single scheduled red as retry-worthy before
escalating.
