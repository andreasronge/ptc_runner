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

Bounded Java values follow the same native-versus-observable split. Native
continuation state may retain validated Java primitive provenance, admitted
Java callables, and LocalDate, Instant, Duration, or Date wrappers. Identity,
closures, and collection transforms retain primitive
provenance; ordinary numeric consumers deliberately erase it, including integer
index/count arguments, collection aggregation, and numeric sort/min/max keys,
whether invoked directly, through a higher-order call, or as a comparator
result. Index/count positions are keyed by builtin arity so collection-bearing
positions retain native values. Native formatting
keeps distinct primitive kinds tagged with identity-preserving display wrappers,
so equal payloads and literal strings cannot collapse map keys or set members.
Every admitted reference uses closed dispatch, with no Java fallback through
the ordinary Lisp environment; each overload names a code-owned implementation.
Only manifest references may become native Java callables. Java-looking aliases
that are not actual admitted members are rejected and remain available, where
applicable, only under their ordinary PTC names.
Java numeric parsers, Double fields, selected `java.lang.Math` overloads,
`System/currentTimeMillis`, the complete admitted temporal profile, and the
admitted Java String methods use this path, preserving exact primitive or class
identity natively while mapping declared Java failures to bounded conditions.
Temporal instance selection is
receiver-owned: LocalDate and Instant comparisons, Duration accessors, and Date
methods cannot cross classes or accept ordinary host temporal structs. Math overload families
select exact primitive profiles; only references with one declared double
overload apply bounded numeric-to-double conversion. Qualified Math semantics
remain separate from the ordinary bare PTC math helpers. Unqualified Clojure
parsing counterparts likewise remain separate safe signal-value helpers.
System time is available only through its qualified Java spelling and returns
a native Java `long` before ordinary public projection.
Callable application derives the invocation kind from that reference: instance
callables consume the receiver as their first application argument. Java class
constructor heads and direct-dot member families resolve from source spellings
through the manifest and enter Java CoreAST only through closed dispatch.
Direct-dot spellings are reserved Java syntax
and the analyzer rejects attempts to introduce them as local or user-namespace
bindings. Java values and recursively projected BEAM structs
must have exactly their declared fields; projection never fills missing fields
from struct defaults. Java class
spellings are host-owned namespaces and cannot be
declared by a capability prelude. Public
projection recursively traverses collections and struct fields, erases valid
primitive tags to inert numeric payloads, projects temporal wrappers to
class-canonical strings, and labels a callable by its fixed manifest
class/member identity. Tool-argument projection additionally follows
the declared signature through nested maps and lists before invoking the callback
when a Java value needs contract-aware projection. Exact, host-representable
Instant and Date values may enter declared datetime fields; LocalDate, Duration,
and nanosecond Instants that would lose precision are rejected. Java-free arguments
do not make Java projection parse otherwise-unused tool metadata.
Return-signature validation observes that same public projection.
Direct capability and Kernel JSON boundaries reject callable
authority, forged Java values, incompatible declared leaves, and projection
collisions before publication or callback invocation.

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
capture. The internal outcome representation carries expected success, error,
and `return`/`fail`/`recur` control with one normalized context. When such an
outcome must cross a value-only host callback, the private abort carrier is the
only transport. Callable dispatch restores caller lexical,
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
than on each result. A valid remote JSON-RPC error is a closed
`:mcp_remote_error` during discovery and a non-retryable `:domain_error` at an
installed capability boundary; it is never reclassified as a transport retry.

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

The internal trace-snapshot owner is available to log-analysis session builders
for validating and retaining one immutable normal-directory capture. Its
tokenized owner keeps no path, exits with its owner, and serves the same four
TraceLog query operations from the captured digest. Capture
applies bounded pre/post file inventories, identity and byte verification, the
existing 8 MB source ceiling, and a separate 32 MB decoded retained-size ceiling
before snapshot-backed capabilities are constructed.

The local log-analysis path is a separate, profile-specific mission session
shared by the Viewer and `mix ptc.repl` frontends.
`PtcRunner.Kernel.LogAnalysisSessionBuilder` is its only host entry:
it selects the code-owned `log-analysis-v1` recipe, compiles the shipped
`log.core` component, grants exactly the four snapshot-backed trace
capabilities, builds empty workflow/mission data, and creates fresh limits and
owners. The builder accepts one host-selected normal source directory and one
host-selected normal output directory; it does not accept profile internals.
The Viewer supplies its configured trace directory for both so a refreshed
session can inspect its predecessor. The terminal validates a physically
separate output tree before construction. The trace owner requires the
directory-bound publication helper's working-directory identity to match the
builder-bound output identity before sending trace bytes, so later pathname
replacement cannot redirect the write. Browser or Lisp input cannot supply a
path, profile, component, capability, or limit. The profile digest covers the
bundle, authoritative mission inventory, complete implicit mission-runtime
contract, effective limits, and result/persistence policies. Only the profile
ID and digest enter
canonical metadata. Session startup does not trust the assembly attestation by
itself: it independently reconstructs the fixed profile from the snapshot and
trace sink, then requires exact config, bundle, capability callback, inventory,
limit, and profile equality. A host-created sealed assembly with a substituted
mission callback is therefore rejected.
The trace owner is additionally bound to the exact combined runtime/sink,
limits, sink run/trace identity, and `<run-id>.jsonl` destination at
construction, and assembly validation rechecks that binding. Construction also
requires the exact two-event terminal reserve, an unfinalized empty recorder,
and an open `RunState`. The sole session attaches before `run-started` is
emitted, so replaying a previously attached assembly cannot append a duplicate
start event.

`PtcRunner.Kernel.LogAnalysisSession` serializes forms through the same detailed
`Evaluation` operation used by `kernel-eval`; it does not reconstruct Lisp
options. The result projection reports the committed continuation effect,
bounded JSON value when available, bounded Clojure rendering, prints, error,
evaluation identity, duration, and authoritative usage. Prints are bounded in
one pass to 128 entries and a 65,536-byte encoded JSON array, so zero-length
prints cannot evade the cardinality limit. JSON projection rejects maps whose
distinct Lisp keys would collapse to the same JSON object key; their bounded
Clojure rendering remains available instead of returning a corrupted value.
Return and fail remain per-form outcomes and leave the local session open. A terminal RunState budget
rejects later forms but leaves explicit close available; close persists an error
terminal event with the authoritative exhausted-budget reason. Abort and
deadline expiry preserve that prior terminal result rather than replacing it.
The owner deadline uses a private correlation token, so an arbitrary mailbox
message cannot close the session. Its `RunState` GenServer also embeds the
tokenized normal-event state. Recorder readiness validation and continuation
commit therefore occur atomically in one owner callback, and both the session
and `SessionTrace` monitor that combined runtime. Runtime or trace-owner death
cannot leave a committed continuation without its event authority; the handle
closes or reports backend failure and releases the snapshot rather than
silently evaluating without canonical events.

`PtcRunner.Kernel.SessionTrace` lifecycle-owns the combined runtime and monitors
the session. The event state's opt-in terminal reserve keeps capacity for one
bounded `events-dropped` summary and exactly one `run-stopped` event inside the
normal hard count/byte ceilings. One owner call finalizes and returns the
complete batch before the runtime is stopped; `SessionTrace` then publishes it
through TraceLog's atomic no-clobber operation. Persistence failure keeps the
same terminal batch for an idempotent close retry, while the already closed
runtime and snapshot owners are released immediately. The trace owner itself
stops and observes those resources before it clears their handles or begins
publication, so session death during close cannot orphan a continuation.
If the runtime is already dead before orderly close is accepted, resource
handoff marks an open recorder `backend_failed` before flushing its monitor.
Failure before the terminal batch is frozen makes finalization fail and never
creates a retryable nil batch. Runtime loss after the batch is frozen preserves
that batch and its terminal result for persistence or retry.
Unexpected session-owner death is independently finalized and best-effort
persisted once by `SessionTrace`, which then stops. Because no caller-visible
session authority survives that death, a failed unexpected-death publication
does not retain an unreachable retry owner.
If the session had already reached a terminal Kernel budget, it transfers that
first authoritative reason to `SessionTrace` before replying; unexpected death
before explicit close therefore persists the budget reason rather than a
generic owner-failure reason.
During construction, `SessionTrace` monitors the calling process as the stable
lifecycle owner while the session and snapshot are attached. Builder
cancellation kills and observes the partial session and cleans every constructed
owner before stopping. Successful construction marks the guard complete but
retains the monitor: owner death before the result can be installed therefore
cannot orphan a session, while later owner death aborts and best-effort persists
the completed session. The Viewer root backend invokes the builder from its
long-lived connected backend owner, and the Mix task itself remains the stable
owner for the complete terminal command; neither may construct a session in a
disposable callback task.
Exceptions after snapshot or trace-owner acquisition run the same owner cleanup
path. Session death while that construction guard is incomplete is a
construction failure and never publishes a terminal trace. Read-only session
information is serialized behind an accepted evaluation without a shorter
owner-call timeout, so a busy live owner is not reported as closed. Close and
abort intentionally leave the session owner alive for idempotent retry and
information reads; each frontend explicitly stops it when that authority is no
longer needed. Exact entered source, values, continuation state, snapshot
contents, and paths never enter canonical events or redacted owner status.

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
`file-read` provider likewise accepts optional boolean `model_visible`. It
freezes the granted directory into a bounded immutable snapshot during provider
assembly; callbacks never reopen host paths. Visibility affects discovery and
prompt context, not the authority granted by the environment.

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

To change the admitted Java-shaped Lisp surface, update the authoritative
`priv/java_interop.exs` manifest and the structured cases in
`priv/java_interop_oracle_cases.exs` together. Every admitted overload has at
least one case; case IDs are unique while overload and divergence identities
remain stable. JVM-attested
cases resolve and invoke the exact manifest descriptor through Clojure 1.12.5
on Temurin 21.0.11+10; the checked-in typed outcomes live in
`priv/java_interop_oracle_baseline.json`. Install the checksum-pinned Clojure
jars with `mix ptc.install_clojure`, then run:

```console
mix ptc.java_conformance --oracle jvm --subset implemented
mix ptc.java_fixtures --oracle jvm --check
mix ptc.java_conformance --oracle babashka --subset fast
mix ptc.java_conformance --oracle ptc --subset closed-dispatch
```

Use `mix ptc.java_fixtures --oracle jvm --write` only after reviewing an
intentional behavior change on the pinned toolchain. The JVM run is the
descriptor and behavior authority. Babashka covers only cases marked `fast`
and cannot attest overload selection. Both runners use bounded source, output,
and runtime limits with an `en_US` process locale and UTC timezone. The JVM
must observe `en_US`; platform-specific Babashka native images may report the
equivalent language-only `en`. Locale-sensitive operations are excluded from
Babashka's non-authoritative fast subset. The PTC closed-dispatch run also
attests the selected overload identity so equal return values cannot conceal a
dispatch mismatch.

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
- `java/oracle_fixtures_test.exs` — Java overload fixture completeness,
  descriptor identity, typed outcomes, and toolchain pin drift;
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
