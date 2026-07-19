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

Prompt-visible component exports can add `:signature` (functions) or `:type`
(constants) metadata. These contracts are compiled once and enforced at the
public prelude boundary: inputs before function entry and successful outputs
after evaluation. Syntax validation, fixed-arity validation, and runtime value
validation are distinct checks. Clojure `^` reader metadata is unsupported;
the metadata is the ordinary map accepted by `defn` and `def`. Optional
positional types accept `nil` but do not permit an omitted argument. Runtime
prelude contracts validate internal Lisp values, so an ordinary string never
satisfies `:keyword` even when its text would be a valid keyword name.

Capability input-schema property names must survive the Lisp tool boundary's
recursive hyphen-to-underscore normalization unchanged. Assembly rejects a
hyphenated input property (and therefore any hyphen/underscore collision)
instead of advertising a direct call that cannot pass its own schema. The same
check recursively covers object keys inside `const` and `enum` values. Output
schemas are unaffected because provider results do not cross that argument
normalization boundary.

The shipped `agent.prompt` prelude renders the frozen structured projection as
one `Available API` section. When the mission has any prompt-visible prelude
function, that prelude is treated as the complete model-facing facade and raw
`tool/...` capabilities are omitted; otherwise direct capabilities are shown.
The heading remains present for an empty mission. Direct-capability field
titles and descriptions are rendered with stable argument/return paths, and
semantically unordered enum members are canonicalized before the model-context
hash is computed.
The default prompt omits numeric Kernel limits because they are enforced rather
than usefully estimated by the model. Prompt wording and omission policy can be
replaced without changing `agent.core`; the host continues to own
canonicalization, bounds, effects, and hashes. Raw capability JSON Schema
remains authoritative at dispatch even when a capability is omitted from the
prompt.

Kernel correction policy never retries any evaluation error after capability
activity. Input validation still runs before the selected wrapper body, but an
earlier top-level form or higher-order invocation may already have called a
capability; ordinary type and runtime failures can likewise occur after an
external effect. Mission-memory rollback cannot undo external reads or writes.
Every parse, analysis, contract, type, and runtime evaluation error therefore
exposes one bounded `capability_activity?` boolean. The Kernel derives it while the single
evaluation lease remains held by combining authoritative mission reservation
accounting with the unified evaluator tool-call ledger and its retained
activity marker. This covers dispatcher-backed capabilities, runtime tools,
contract failures inside `pmap`/`pcalls`, and killed workers that cannot return
a detailed ledger without allowing concurrent lease handoff to produce a false
retry classification. Pure failures remain eligible for correction under the
agent's turn policy.

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
mission data, mission capabilities, and current native evaluation continuation.

The central confinement invariant is:

> Subordinate evaluation is constructed exclusively from the mission
> environment. It never inherits, merges, or falls back to the workflow
> environment.

Consequently mission code cannot acquire the workflow's model provider,
recursively invoke `kernel-eval`, or emit workflow-only annotations. Preserve
this structurally in function inputs and environment construction; symbol
filtering alone is not an adequate boundary.

Definitions and the three most recent ordinary results from successful
subordinate evaluations persist for the rest of the run. RunState reserves
native memory and exact `*1`/`*2`/`*3` history together under one lease.
Ordinary success appends its native result and trims oldest-first history to
three; explicit `return` commits definitions without advancing history. Commit
is transactional: parse, analysis, runtime, timeout, memory, history,
capability, result-size, or explicit-failure outcomes preserve the complete
previous continuation.

The workflow-visible subordinate outcome algebra is deliberately distinct from
the evaluator's internal controls:

| Outcome | Continuation | Agent policy |
| --- | --- | --- |
| `:continued` | commit memory and advance exact history | ordinary value; append its inert value and chronological prints as one correlated tool observation, then request another turn |
| `:returned` | commit memory without advancing history | explicit `(return value)`; complete successfully |
| `:failed` | roll back memory and history | explicit `(fail value)`; terminate as workflow failure |
| evaluation or limit error | roll back memory and history | correct only when retry policy, capability activity, and turn budget permit |

Both dynamic `kernel/eval-source` and embedded `kernel/eval` enter this same
classification boundary. The agent retains each accepted public assistant tool
call together with exactly one `role: tool` observation carrying the same call
ID. Continued observations are escaped and bounded text; they do not expose
native continuation memory. An intermediate result on the final turn commits
before the agent reports that no model turn remains.

Native continuation memory and exact history never cross back into workflow Lisp. Subordinate
values and the workflow's terminal value pass through
`PtcRunner.Lisp.externalize_value/1`, which recursively replaces closures,
builtins, composed callables, runtime callables, and plain BEAM functions with
inert deterministic display values. These projections retain neither callable
implementations nor closure parameters, bodies, captured environments,
history, or metadata. Canonical events likewise carry only bounded status and
accounting metadata; exact values remain outside ordinary observability.

## Evaluator effects, outcomes, and parallel work

`PtcRunner.Lisp.Eval` recursively evaluates analyzed expressions and leaves
public result assembly to `PtcRunner.Lisp`. Its context contains one canonical
`PtcRunner.Lisp.Eval.Effects` value for tool calls, parallel-call records,
prints, public prelude counts, and the tool cache. Effect lists use an internal
newest-first representation; `Effects` alone owns merge direction, cache
precedence, deltas, and conversion to chronological output.

Plain Elixir callbacks cannot return a threaded evaluator context.
`PtcRunner.Lisp.Eval.Capture` is the single nestable process-local effect
stack, while `PtcRunner.Lisp.Eval.HostContext` is the adapter that binds an
active evaluator context around host callbacks and selects value or outcome
capture. `PtcRunner.Lisp.Eval.Outcome` represents expected success, error, and
`return`/`fail`/`recur` control with one normalized context. When such an
outcome must cross a value-only host callback, `PtcRunner.Lisp.Eval.Abort` is
the only private carrier. Callable dispatch restores caller lexical,
namespace, and prelude-authority state before capture replaces the outcome's
effects.

This arrangement preserves effects that executed before a later expected
failure. That includes earlier top-level forms, prior higher-order callback
iterations, and the retained failing callback itself. Cache entries recorded
by an earlier callback are materialized into later callbacks during the same
evaluation. Unexpected BEAM exceptions keep their native class and stacktrace,
including when they cross a parallel worker boundary; they are not converted
into an expected evaluator error transport.

Parallel responsibilities are deliberately split. `PtcRunner.Lisp.Eval.Parallel`
owns `pmap`/`pcalls` callable adaptation, worker effect capture, expected-error
classification, and outer operation records. `PtcRunner.Lisp.Eval.ParallelRunner`
owns only indexed scheduling, heap-capped process lifecycle, the shared worker
budget, deadlines, cancellation, and monitor cleanup. Every evaluator worker
returns one envelope containing its outcome, effects, and child metadata; the
runner attaches the authoritative input index.

After scheduling begins, success or failure appends one outer parallel-call
record. `count` is the input work count, `success_count` is the number of
retained successful envelopes, and `error_count` is the remainder. Retained
worker envelopes are merged in input order before the outer record is
appended. On failure, the retained set contains successful envelopes plus the
selected failing envelope; concurrently returned secondary failure envelopes
are not retained. A heap-killed or otherwise abnormal worker may be unable to
return its detailed ledger, but the shared capability-activity and quota
counters remain authoritative for retry and limit enforcement.

## Ownership, limits, and concurrency

`PtcRunner.Kernel.RunState` is the single owner of mutable per-run accounting.
It owns the deadline, open/closed state, capability counters, protocol-error
count, subordinate-evaluation lease, and committed native evaluation
continuation (definitions plus exact three-value history).

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

Subordinate evaluation is serialized because it owns the transactional
continuation. Reservation returns memory, history, and the lease token in one
owner operation; commit validates and installs the complete candidate in one
owner operation. A concurrent attempt receives a recoverable busy result rather
than waiting in an unbounded queue. ReplSession projects memory and history for
its caller but does not own a competing copy for evaluation decisions.

`evaluation_memory_bytes` continues to charge definitions only.
`evaluation_history_bytes` independently bounds every exact history value and
the three-value aggregate, so adding history cannot invalidate previously valid
definition memory. Public continuation summaries report definition count,
history count, separate memory/history bytes, and their combined retained-byte
total without exposing values.

The complete current limits are documented by `PtcRunner.Kernel.Limits`.
`defaults/0` supplies ordinary effective runtime values, while
`installed_defaults/0` supplies larger host-controlled manifest ceilings.
`Manifest.load/2` accepts a complete host ceiling and allows the manifest only
to narrow it. Workflow turn counts, retries, and other policy budgets belong in
Lisp below those enforced host ceilings.

The shipped `agent.core` normalizes its policy limits once. Before every model
call it constructs the prospective request exactly once, JSON-encodes the
complete `system`, accumulated provider-correlated `messages`, and tool schema,
then applies `max_transcript_chars`. The default is 262,144 encoded characters;
a positive override may narrow or raise it only through the hard prelude
maximum of 1,000,000. Encoding failure and an over-limit request terminate
before `llm-request`, so they consume no provider call. This deterministic
character ceiling complements rather than replaces `LLMCapability`'s final
retained-size/byte validation. The loop does not compact or discard earlier
assistant/tool pairs.

`max_turns` likewise grants no quota. A loop may stop first at the workflow
`llm-request` quota, subordinate-evaluation quota, shared run deadline, or any
other host ceiling. Runner teardown closes and stops RunState after every
terminal path, drains attached provider work, and invokes each configured
idempotent provider-resource closer once for that run.

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
| Lisp evaluation | `PtcRunner.Lisp.Eval`, `PtcRunner.Lisp.Eval.Context`, `PtcRunner.Lisp.Eval.Effects`, `PtcRunner.Lisp.Eval.Capture`, `PtcRunner.Lisp.Eval.HostContext`, `PtcRunner.Lisp.Eval.Parallel`, `PtcRunner.Lisp.Eval.ParallelRunner` |
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
ceilings. Manifest configuration is an `allow` list of mapped public names,
an optional `model_visible` subset (defaulting to all allowed names), and
optional lower `timeout_ms` and `max_result_bytes`; endpoints, headers,
upstream names, effects, and retries are not manifest fields. The built-in
`file-read` provider likewise accepts optional boolean `model_visible`.
Visibility affects discovery and prompt context, not the authority granted by
the environment.

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

`RunConfig` freezes two bounded deterministic mission projections. The
authoritative V2 inventory contains prompt-visible exports, model-visible
capability schemas, and mission limits and is exposed through
`kernel-mission-inventory`. A separate compact V2 model rendering preserves
wrapper call forms, schemas for directly visible capabilities, and limits and
is exposed through `kernel-mission-model-context`. Their hashes and byte counts
have distinct canonical metadata names. Keep both projections payload-free and
update exact golden tests whenever either versioned contract changes.

The shipped agent dependency graph keeps prompt policy in `agent.prompt`, which
depends on `kernel`, while `agent.core` owns the provider/evaluation loop.
`agent.prompt/initial-state`, `render`, and `transition` are called directly by
the frozen Lisp bundle. Changing prompt policy therefore changes the prompt
component and bundle hashes without mixing wording into the control loop.

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
