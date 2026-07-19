# Viewer Log-Analysis REPL

Status: implementation-ready; large/high-risk change with lifecycle, security,
and persistence review gates

Scope: `ptc_runner` plus the standalone `ptc_viewer`

Purpose: let a human investigate a frozen capture of canonical Kernel traces
with PTC-Lisp while producing a separately persisted canonical trace for the
analysis session itself.

## Outcome

Add a local, bounded `REPL` tab to the Viewer. The tab evaluates PTC-Lisp in a
mission environment containing the shipped `log.core` component and one
explicit read-only trace grant. It uses the same
`PtcRunner.Kernel.Evaluation` implementation as `kernel/eval-source`; the
Viewer does not implement or duplicate Lisp execution, trace loading,
capability dispatch, continuation state, or authority assembly.

Core assembles that authority from one code-owned, versioned session profile,
`log-analysis-v1`. The browser never supplies profile contents. The first
increment has exactly one enabled profile, while the Viewer adapter boundary
uses an opaque backend context so a later authenticated remote backend does not
require changing the browser-facing evaluation contract.

Each analysis session receives an immutable capture of the host-selected
normal trace directory. Its canonical events are collected independently and
persisted on orderly close or reset. A refreshed session captures the directory
again and can therefore inspect the preceding session's persisted trace.
Querying the current session's mutating event sink is not supported.

The first increment is human-only. The implemented multi-turn agent continues
to run within one bounded `PtcRunner.Kernel.run/2`; human and model paths share
`Evaluation` and `RunState` semantics, not a long-lived frontend owner.

## Verified Current State

The required execution semantics now exist:

- `PtcRunner.Kernel.Evaluation` is the mission-only boundary used by
  `RuntimeTools.kernel_eval/5`.
- `PtcRunner.Kernel.RunState` owns one transactional continuation lease,
  committed native definitions, and exact bounded `*1`, `*2`, and `*3`
  history.
- ordinary success is `:continued`, explicit `return` is `:returned`, and
  explicit `fail` is `:failed`;
- successful ordinary evaluations atomically commit memory and advance exact
  turn history;
- explicit return commits memory without advancing history;
- fail and evaluator errors preserve the previously committed memory and
  history;
- `PtcRunner.Kernel.TraceCapability` exposes the four canonical operations
  required by `log.core`;
- `ptc_viewer` already delegates canonical trace queries through a host
  adapter, pins one optional inspection artifact in a redacted owner, ships a
  Clojure highlighter, and renders `continued`, `returned`, and `failed`
  evaluation states.

The workflow `PtcRunner.Kernel.ReplSession` remains intentionally different.
It reserves the continuation lease before directly evaluating the workflow
environment. Calling its nested `kernel/eval-source` then attempts to reserve
the same lease and returns `:busy`. Wrapping that REPL in HTTP would expose a
workflow scratchpad, not the model-equivalent mission boundary.

## Product Decisions

### First increment

- One local analysis session per Viewer server instance.
- One normal trace directory selected by the host at Viewer startup.
- REPL support is optional at the standalone Viewer boundary. Starting
  `PtcViewer` without a REPL adapter preserves the existing Runs-only Viewer;
  supplying an invalid adapter or invalid backend context fails startup. The
  root `mix ptc.viewer` task supplies the local Core adapter and enables the
  REPL.
- The browser cannot supply or change paths, manifests, components,
  capabilities, providers, or runtime limits.
- Session creation is lazy when the REPL tab first bootstraps.
- After explicit close, only Reset/Refresh starts another session.
- Mission-mode evaluation only.
- `log-analysis-v1` is the only enabled session profile and is selected by the
  server, not by an HTTP request.
- Shipped `log.core` is the profile's only mission component.
- Only `trace-list-runs`, `trace-get-run`, `trace-list-turns`, and
  `trace-counters` are explicitly granted. The normal implicit mission runtime
  routes remain available for bounded usage and capability introspection.
- Trace input is an immutable validated capture created once per session.
- One core owner serializes all continuation mutations.
- The Viewer store rejects overlapping evaluate/reset/close operations with
  `409`; rejected requests are never queued for later execution.
- Normal close succeeds even when earlier individual forms failed. Evaluation
  errors remain visible in evaluation events and usage; only infrastructure
  failure or abort makes the session run terminally erroneous.
- `return` and `fail` are per-evaluation outcomes in this human session. They
  do not close it. Close, Reset, expiry, shutdown, abort, or a terminal Kernel
  budget such as the protocol-error limit closes it against new evaluation.
- A terminal Kernel budget leaves the session terminal but unpersisted so the
  human can inspect the final result and then Close or Reset. Deadline expiry
  automatically closes and persists the session even when the browser is
  idle; it never depends on a later HTTP request to discover the expiry.
- A bounded server-owned presentation transcript survives page reload and is
  shared consistently across tabs. It is presentation state, not evaluator
  memory authority and not a canonical trace payload.
- The session trace is persisted on orderly close, reset, and Viewer shutdown.
- Close is idempotent and is also the persistence-retry operation. Repeating
  Close, or selecting Reset while persistence has failed, retries the retained
  batch; Reset creates a replacement only after that retry succeeds.
- Unexpected owner failure attempts best-effort aborted persistence through a
  separate trace recorder that survives the evaluation owner.
- Exact source, trace-query arguments/results, and other inspection payloads
  stay outside canonical events.

### Explicitly deferred

- Querying the active analysis session's own mutating sink.
- Arbitrary manifests, libraries, or non-read-only capabilities.
- Runtime registration of additional session profiles or a declarative
  YAML/JSON profile format.
- Browser-selected profile IDs; the only enabled local profile is fixed by the
  server in this increment.
- Authenticated remote or multi-user operation.
- Role, tenant, project, and logical trace-collection policy.
- A remote `PtcViewer` backend or a Core HTTP control plane.
- More than one independent analysis session per Viewer.
- A writable prelude editor.
- Model invocation from the Viewer.
- Giving any model the Viewer session, inspection grant, transcript, or
  ambient trace directory.
- Lisp capabilities over private inspection artifacts. Existing inspection
  pinning remains a Viewer-only feature and will receive a separate plan if
  model- or Lisp-query access is required.
- Durable per-event streaming or recovery after a BEAM/OS crash.
- Migrating `mix ptc.repl` to mission semantics.

## Authoritative Boundaries

| Concept | Authoritative owner/representation | Boundary consumer |
| --- | --- | --- |
| Analysis authority recipe | code-owned `LogAnalysisProfile` definition for `log-analysis-v1` | `LogAnalysisSessionBuilder` only |
| Mission execution | `PtcRunner.Kernel.Evaluation` | `RuntimeTools.kernel_eval/5` and `LogAnalysisSession` |
| Continuation memory/history and quotas | one `RunState` owned by `LogAnalysisSession` | `Evaluation` reserves and atomically commits/releases |
| Frozen trace data | tokenized `TraceSnapshot` owner | snapshot-backed `TraceCapability` callbacks |
| Canonical session events and persistence state | `SessionTrace` owner plus its normal `EventSink` | `Evaluation`, `LogAnalysisSession`, and close/reset lifecycle |
| Connected local backend and start-operation reconciliation | adapter-owned backend context | `PtcViewer.ReplStore` through typed callbacks |
| Browser lifecycle and presentation transcript | `PtcViewer.ReplStore` | HTTP API and REPL UI |
| Strict HTTP projection | root `ViewerReplAdapter` | standalone Viewer behavior |

No request process may read state and later update it. Every transition that
depends on current continuation, persistence, or Viewer lifecycle state occurs
as one operation in that concept's owner.

## Server-Owned Session Profile

Add one concrete code-owned recipe, provisionally
`PtcRunner.Kernel.LogAnalysisProfile`, with stable ID `log-analysis-v1`. Do not
add a generic profile behaviour, dynamic registry, or untrusted configuration
format until a second independent profile proves the required abstraction.

The recipe fixes all authority-relevant inputs:

```elixir
%{
  id: "log-analysis-v1",
  components: [{:library, "log.core"}],
  explicit_capabilities: [
    "trace-list-runs",
    "trace-get-run",
    "trace-list-turns",
    "trace-counters"
  ],
  mission_data: %{},
  limits: LogAnalysisProfile.limits(),
  persistence: :canonical_trace_on_close,
  result_policy: :bounded_json
}
```

This map illustrates the contract; callbacks are not stored in it. The builder
materializes the four explicit capabilities from the session's tokenized
`TraceSnapshot`. Selecting a component grants no capability, and selecting a
capability does not install an arbitrary prelude.

The available Lisp surface is:

- normal bounded PTC-Lisp built-ins;
- `log.core`, exporting `log/runs`, `log/run`, `log/turns`, and
  `log/counters`;
- the four snapshot-bound trace capabilities above; and
- the existing implicit mission routes `runtime-usage`, `runtime-remaining`,
  `cap-list`, and `cap-describe`.

The profile does not install `fs`, `llm`, `agent.*`, `workflow.event`, MCP,
private-inspection, host filesystem, network, or workflow-only
`kernel-eval` authority. Tests must assert both the positive inventory and
these important absences.

Compile the fixed component closure through `Kernel.Library` and
`BundleCompiler`; do not paste or separately load `log.core` source. Cache the
immutable frozen bundle only if profiling justifies it. Every session still
receives fresh capabilities, snapshot, continuation state, budgets, and trace
owners.

Return safe profile metadata from session bootstrap and `info/1`:

```json
{
  "profile_id": "log-analysis-v1",
  "profile_digest": "sha256:...",
  "namespaces": ["log"]
}
```

Derive `profile_digest` through `DeterministicJSON` from the profile ID,
frozen-bundle hash, authoritative `MissionInventory` hash, a versioned identity
for the complete implicit mission runtime-tool contract, every effective limit,
persistence policy, and result policy. The runtime identity includes the sorted
names and contract version for `runtime-usage`, `runtime-remaining`, `cap-list`,
and `cap-describe`; changing an implicit route must change that identity.
Centralize this descriptor with `RuntimeTools` rather than copying another list
into the profile.

Exclude callbacks, PIDs, paths, snapshot contents, and secrets. Record the
profile ID and digest in safe analysis-session metadata so persisted runs can
be audited. If the authority contract changes incompatibly, introduce a new
versioned ID rather than silently redefining `log-analysis-v1`.

### Configuration and authorization seam

Keep three concerns separate:

1. The profile definition is trusted application code and owns preludes,
   capabilities, limits, and policies.
2. Deployment configuration decides which compiled profiles are enabled. This
   increment enables only `log-analysis-v1`; the browser cannot change it.
3. A future authenticated Core service maps a principal's roles and logical
   resource scopes to enabled profiles. That policy must not turn roles into
   arbitrary capability lists.

A later remote request may select an authorized profile and a logical
server-owned trace collection, never a filesystem path. Its effective
authority is the intersection of the fixed profile, role permissions,
resource scope, and server policy. This plan does not implement that service,
role model, or profile selection endpoint.

## Core Log-Analysis Session

Add a dedicated internal owner, provisionally
`PtcRunner.Kernel.LogAnalysisSession`. Do not generalize it into a framework
for unrelated interactive missions in this change. The public host entry is
the profile-specific `LogAnalysisSessionBuilder`, not the owner's raw
constructor.

Suggested host API:

```elixir
LogAnalysisSessionBuilder.start({:directory, host_selected_path})

evaluate(session, source)
info(session)
close(session)
abort(session, reason)
```

The builder creates all environments and resources and returns an opaque
session handle. The internal owner's `start_link` accepts only a private,
builder-produced and attested assembly value tying together profile identity,
mission environment, limits, trace, and snapshot. It must reject independently
assembled environments or mismatched profile metadata. No public session API
accepts a browser-selected path or an already assembled arbitrary capability
set.

`evaluate/2` calls the same internal mission-evaluation operation used by
`Evaluation.evaluate_source/6`. It must not reconstruct the
`Lisp.run_native/2` options. Refactor `Evaluation` only as needed to expose one
detailed internal result while retaining one execution implementation.

Use an infinite `GenServer.call` timeout at owner boundaries where the work is
already bounded by `RunState` and `evaluation_timeout_ms`. A default five-second
GenServer timeout must not cause the HTTP request to fail while an authorized
evaluation continues invisibly. If the HTTP client disconnects, the accepted
evaluation completes, commits or rolls back normally, emits its events, and is
recorded in the bounded presentation transcript.

`LogAnalysisSession` also owns a timer for the fixed run deadline. Expiry
atomically rejects new work, waits for any already accepted bounded evaluation
to finish, and runs the normal close-and-persist path. The owner remains able
to report safe closed information and accept idempotent `close` after successful
publication. If automatic persistence fails, it retains the closed resources
required by `SessionTrace` and reports the normal retryable persistence state.

After every evaluation, inspect the authoritative `RunState` terminal status
before replying. A terminal budget such as the protocol-error ceiling returns
the triggering bounded domain result and marks the session
`:terminal_unpersisted`; it does not automatically persist. Later evaluation is
rejected, while `info`, `close`, and the close phase of Reset remain available.

### Evaluation result projection

The root adapter returns a strict, encoded-size-checked JSON projection:

```elixir
%{
  status: :ok | :error,
  outcome: atom(),
  value: json_value_or_nil,
  value_available?: boolean(),
  formatted: bounded_clojure_text_or_nil,
  formatted_truncated?: boolean(),
  prints: [bounded_binary()],
  prints_truncated?: boolean(),
  error: %{
    kind: atom(),
    reason: atom() | nil,
    message: bounded_binary() | nil,
    capability_activity?: boolean() | nil,
    retryable?: boolean() | nil
  } | nil,
  evaluation_id: binary(),
  duration_ms: non_neg_integer(),
  usage: %{
    remaining_ms: non_neg_integer(),
    evaluations: %{used: non_neg_integer(), limit: pos_integer(), remaining: non_neg_integer()},
    mission_calls: %{used: non_neg_integer(), limit: pos_integer(), remaining: non_neg_integer()},
    continuation: %{
      defined_count: non_neg_integer(),
      history_count: 0..3,
      memory_bytes: non_neg_integer(),
      history_bytes: non_neg_integer(),
      bytes: non_neg_integer()
    }
  }
}
```

Projection rules:

- continued and returned outcomes have `status: :ok`;
- failed, evaluator-error, timeout, quota, memory/history, and result-limit
  outcomes have `status: :error`;
- all accepted evaluation outcomes are successful HTTP operations and return
  HTTP `200` with the domain status above;
- use the native result internally for continuation and only
  `Lisp.externalize_value/1` at the public boundary;
- normalize the externalized value through a bounded JSON encode/decode step;
- if a value is inert but not JSON-encodable, return `value: nil`,
  `value_available?: false`, and retain its bounded Clojure rendering;
- cap the complete formatted output, not only strings nested inside it, and
  return an explicit truncation marker and flag;
- preserve bounded evaluator prints for every outcome for which the detailed
  evaluator result has them; terminal returned/failed forms should remain
  useful to a human even though the model loop does not need terminal prints;
- apply an authoritative public-result ceiling before returning through HTTP;
  a result-limit failure does not undo continuation state already committed by
  the shared evaluation boundary;
- never put source, native memory/history, callbacks, capabilities, snapshot
  contents, filesystem paths, sink handles, exception terms, or stack traces in
  the result.

The detailed evaluator operation must return `evaluation_id` and duration
directly. Do not recover them by diffing retained events, which may be dropped
under the normal event policy.

### Continuation semantics

- Ordinary success commits candidate memory and appends the exact native result
  to bounded three-value history.
- Explicit return commits candidate memory but does not advance history.
- Explicit fail rolls back candidate memory/history.
- Parse, analyze, runtime, timeout, heap, contract, and commit-limit errors
  preserve the previously committed continuation.
- Capability effects cannot be rolled back. Preserve the implemented
  `capability_activity?` marker in the error projection.
- The browser transcript never feeds values back into evaluation. `RunState`
  is the only continuation authority.

### Dedicated profile limits

`LogAnalysisProfile` installs the following values; the request cannot narrow
or expand them. Initial values:

```elixir
Limits.new(
  run_duration_ms: 1_800_000,
  evaluation_timeout_ms: 10_000,
  subordinate_evaluations: 64,
  mission_capability_calls: 512,
  mission_capability_calls_per_name: 256,
  subordinate_source_bytes: 65_536,
  protocol_errors: 32,
  normal_event_count: 1_408
)
```

All unspecified limits retain current Kernel defaults, including evaluator
heap, continuation memory/history, result, and event-byte ceilings. Snapshot
source and result ceilings remain the `TraceLog` defaults unless the builder
installs a lower fixed value. Reset creates a new `RunState` and renews the
session budget.

Review these initial numbers with focused memory and journey tests before
shipping. In this increment, changing them is a code-owned profile change, not
an application-environment or browser option.

The raw event count is not itself sufficient to protect lifecycle evidence:
512 explicit mission calls can emit 1,024 start/stop events, 64 evaluations can
emit another 128, and valid implicit runtime calls emit events without
consuming the explicit mission-call quota. Extend `EventSink` with an optional
owner-only terminal reserve used by this session. Ordinary emission stops at
the count/byte ceilings minus capacity for one bounded `events-dropped` summary
and one `run-stopped`; `SessionTrace` atomically finalizes those terminal events
through the reserved capacity. The reserve remains inside the configured hard
count and byte ceilings. Existing sinks retain their current behavior unless
they opt into this reserve.

Tests must saturate the ordinary count and byte budgets using both explicit and
implicit mission routes, then prove that the dropped summary and exactly one
terminal event remain retained and the persisted batch still validates.

## Immutable Trace Snapshot

Add an internal tokenized owner, provisionally
`PtcRunner.Kernel.TraceSnapshot`, rather than making arbitrary lists of maps a
public `TraceLog.source()`.

Requirements:

- accept only an already host-selected normal directory source;
- enumerate, load, decode, normalize, and validate it once at session creation;
- exclude `.private.jsonl` and `.inspection.jsonl` exactly as normal directory
  sources do;
- preserve the current aggregate encoded source ceiling and add a bounded
  retained-memory ceiling for the decoded representation;
- detect a directory/file change during capture with pre/post inventory and
  file identity checks and return `:source_changed` rather than constructing an
  ambiguous capture;
- retain the validated events in a separate owner so the complete snapshot is
  not copied into every evaluator worker through capability closures;
- expose only a tokenized query handle and safe snapshot metadata;
- reuse the exact `TraceLog` filter, ordering, pagination, cursor, result-limit,
  and source-identity algorithms rather than copying query behavior;
- bind cursors to the immutable capture digest and query/filter identity;
- provide safe metadata containing capture ID, `captured_at` as UTC datetime,
  visible run count, and encoded source bytes, but no path;
- terminate with the analysis session and support idempotent cleanup.

Add a private `TraceCapability.from_snapshot/1` or equivalent constructor. It
captures only the tokenized snapshot handle. The existing public filesystem and
event-sink constructors retain their current behavior.

Do not implement the earlier digest-and-reject fallback. A new trace appearing
in the directory must not invalidate pagination in an already-open session.

## Analysis Environment Assembly

Add `PtcRunner.Kernel.LogAnalysisSessionBuilder`:

1. Receive and validate the host-selected normal trace directory.
2. Select the server-owned `log-analysis-v1` recipe; accept no browser or
   request profile definition.
3. Construct the immutable `TraceSnapshot`.
4. Build the four profile capabilities from its tokenized handle.
5. Resolve the profile's installed `log.core` component through
   `Kernel.Library`.
6. Compile the mission bundle and create a `MissionEnvironment` containing only
   the profile's explicit capabilities and empty mission data.
7. Compute the safe profile descriptor and digest from the effective compiled
   recipe.
8. Create the empty workflow environment required by `RunConfig` metadata; it
   is not evaluated by the session.
9. Install the fixed profile limits.
10. Generate a unique run/trace identity and a deterministic filename derived
   only from that safe identity.
11. Start `SessionTrace`, which owns the normal `EventSink` and persistence
   destination.
12. Build `RunConfig` metadata with valid safe labels:
    `%{"name" => "ptc.viewer.repl", "tags" => %{"mode" => "repl"}}`.
    Extend `RunConfig` with one optional closed `session_profile` projection
    containing the bounded profile ID and digest. `RunConfig` remains the sole
    constructor of complete `run-started` metadata; do not create an analysis-
    specific parallel payload builder or overload fingerprinted caller labels.
13. Start `LogAnalysisSession`, attach it to `SessionTrace`, and emit the normal
    `run-started` metadata.
14. Return only an opaque session handle plus safe `info/1` metadata, including
    the profile descriptor.

Do not add a trace provider to the default manifest registry. Do not migrate
`ReplSession` or `mix ptc.repl` in this change.

## Session Trace and Persistence Lifecycle

Add `PtcRunner.Kernel.SessionTrace` as the single owner of:

- the normal `EventSink` and its token;
- the unique run/trace identity;
- the validated destination beneath the configured trace directory;
- terminal-event state;
- the retained final event batch;
- persistence state: `:open`, `:terminal_unpersisted`, `:persisted`, or
  `{:persistence_failed, reason}`;
- the last successfully persisted sequence.

`SessionTrace` owns its sink, then monitors the attached analysis session. This
allows retained events to remain available if the evaluation owner exits.

### Orderly close

1. Reject new evaluations.
2. Wait for an accepted evaluation to finish; the Viewer normally prevents
   overlapping close before this reaches core.
3. Close `RunState` against new reservations.
4. Construct the bounded terminal usage/outcome payload and read the sink's
   accumulated loss counts without publishing either yet.
5. Ask the sink's atomic owner-only finalization operation to emit the bounded
   dropped summary when needed and exactly one reserved `run-stopped` event
   with normal outcome.
6. Ask `SessionTrace` to persist the complete batch to a new, no-clobber normal
   JSONL file.
7. On success, stop continuation, snapshot, provider, and sink resources
   exactly once.
8. On persistence failure, keep the closed session and retained trace owner
   alive so repeated `close` can retry without appending duplicates.

Persistence failure is returned separately and never rewrites the final
evaluation outcome or the already emitted run terminal outcome.

### Abort or unexpected owner death

- Explicit abort emits one error `run-stopped` when possible, closes
  continuation/provider resources, and attempts persistence.
- When the session process dies unexpectedly, `SessionTrace` observes `:DOWN`,
  emits an aborted terminal event if none exists, and attempts best-effort
  persistence independently.
- An OS/BEAM crash may still lose the in-memory batch; durable per-event
  streaming remains deferred.
- Repeated close, abort, reset, Viewer shutdown, or owner-down notifications
  must never append the same event sequence twice.

Use a per-run filename such as `viewer-repl-<safe-run-id>.jsonl`. The browser
never receives the path. Add a no-clobber atomic publication operation for a
complete validated batch rather than silently appending to an unrelated
existing file:

1. Deterministically encode and validate the complete batch before opening a
   destination.
2. Write and sync an exclusive, uniquely named same-directory temporary file
   whose suffix is not discoverable as a trace.
3. Publish it with an atomic no-replace primitive, such as a same-filesystem
   hard link followed by removal of the temporary name. Never use a rename that
   can replace an existing destination.
4. If the final path already exists after a retry or process interruption,
   validate that it is a complete byte-identical publication of this exact
   run. Treat that as success; a partial or different file is a collision and
   must not be appended or overwritten.
5. Clean temporary files after every observed failure while preserving enough
   state for a safe retry.

Fault-injection tests cover failure before write, during write, after sync,
after publication but before owner acknowledgement, and during cleanup. Every
retry yields either one complete file or a stable error, never a partially
discoverable trace or duplicated sequence.

## Viewer Adapter and Store

Keep `ptc_viewer` independent of `ptc_runner`. Add a transport-neutral
`PtcViewer.ReplAdapter` contract:

```elixir
@callback connect(map()) ::
            {:ok, opaque_backend, safe_feature_descriptor} | {:error, atom()}
@callback start(opaque_backend, binary(), binary()) ::
            {:ok, opaque_session, map()} | {:error, atom()}
@callback reconcile_start(opaque_backend, binary()) ::
            {:ok, opaque_session, map()} | {:error, atom()}
@callback evaluate(opaque_backend, opaque_session, binary()) ::
            {:ok, map()} | {:error, atom()}
@callback info(opaque_backend, opaque_session) :: {:ok, map()} | {:error, atom()}
@callback close(opaque_backend, opaque_session) :: {:ok, map()} | {:error, atom()}
@callback abort(opaque_backend, opaque_session, atom()) ::
            {:ok, map()} | {:error, atom()}
```

The root implementation is the only backend in this increment and may be named
`PtcRunner.Kernel.ViewerReplAdapter` or `LocalViewerReplAdapter`. The root Mix
task supplies adapter-specific host configuration containing the expanded
trace directory and enabled profile. `connect/1` validates that configuration
and returns an opaque local backend context plus a strict JSON-compatible
feature descriptor advertising exactly `log-analysis-v1`. Neither value is
returned wholesale to the browser.

The standalone `PtcViewer.start/1` accepts an optional `:repl_adapter` plus its
opaque adapter-specific connection configuration. When the adapter is absent,
do not start `ReplStore` or render the REPL tab; REPL routes return the fixed
feature-disabled response and all existing Runs and inspection behavior remains
available. When an adapter is supplied, validate its callback contract and call
`connect/1` during Viewer startup. An invalid module, invalid feature
descriptor, or failed connection fails startup and cleans up any already-created
Viewer resources. Do not silently downgrade a requested REPL to Runs-only mode.

The Viewer store starts the one server-selected profile from that descriptor;
the HTTP bootstrap and mutation bodies do not accept a profile ID. Public
session info contains a stable random binary `session_id`, profile ID, and
profile digest. The adapter's opaque session reference may remain an
in-process term; no PID or reference crosses the HTTP boundary. A later remote
adapter can use its remote session ID as the opaque reference without changing
Viewer store or browser semantics.

`start/3` receives a store-generated random operation ID and is idempotent for
that connected backend. The backend context atomically records operation ID to
committed session before replying. If the monitored task exits without a
result, the store calls `reconcile_start/2`: it either recovers the one
committed handle and info or proves no session was committed. Reusing an
operation ID never constructs another session, and backend/Viewer termination
closes every committed session even when handle delivery failed.

Remove the adapter-level `reset` callback. `ReplStore` owns the visible reset
state machine and performs idempotent close followed by a new idempotent start
with a fresh operation ID. It retains the old handle until close is confirmed,
and does not install or expose the new handle until start or reconciliation
returns it. This keeps every irreversible transition visible to the lifecycle
owner and prevents an adapter task exit from orphaning a second live session.

All adapter returns are bounded strict JSON projections with stable reason
atoms. Do not implement a generic arbitrary-operation RPC callback. The
existing read-only trace and inspection adapters remain unchanged in this
increment; unifying every Viewer operation behind a remote backend requires a
separate control-plane design.

Add `PtcViewer.ReplStore`. It owns only:

- the opaque adapter handle;
- the opaque connected-backend context and safe feature descriptor;
- lifecycle state: `:never_started`, `:open`, `:evaluating`, `:resetting`,
  `:reconciling_start`, `:terminal`, `:closing`, `:closed`, or
  `:persistence_failed`;
- the per-server mutation nonce;
- one monitored in-flight adapter task and pending caller;
- the bounded presentation transcript;
- a monitor on the Viewer/Bandit owner.

It does not own continuation memory, capabilities, snapshot contents, or event
persistence.

To remain responsive while an evaluation runs, start one monitored task that
performs the synchronous adapter call, retain its caller, and reply when the
task finishes. While it is active, reject further evaluate/reset/close calls
immediately. Normalize task exceptions/exits without leaking exception terms.

The presentation transcript is capped at 64 entries and 256 KiB encoded. It
also has a 128 KiB encoded per-entry ceiling. Each entry contains the source
byte count, a bounded encoded source preview with an explicit truncation flag,
and a transcript projection of the already bounded public result. Preserve at
least evaluation ID, status/outcome, duration, usage, and explicit omission
markers when value, formatted output, or prints do not fit. The transcript
projection is presentation-only and cannot change the direct HTTP evaluation
response or continuation state.

Measure actual JSON encoding, including escaping. If a newest entry still does
not fit, replace optional fields with a fixed metadata-only omission record;
never drop the accepted newest evaluation silently. Then evict complete oldest
entries until the aggregate cap fits and expose an omitted-count marker. Clear
the transcript on successful reset. It must be redacted from OTP
`format_status`, Logger, Telemetry, crash reports, and adapter failures.

On Viewer termination, the store performs one bounded orderly close. If the
Viewer failed while an evaluation was active, let the accepted core evaluation
finish within its installed deadline before close; do not kill it and leave an
ambiguous continuation lease.

When an evaluation reports an authoritative terminal Kernel budget, the store
records `:terminal` plus a bounded reason, retains the handle and transcript,
and rejects further evaluation with `409`. Close and Reset remain enabled.
When `info/1` observes deadline-driven automatic close, the store converges to
`:closed` or `:persistence_failed` without constructing a new session. Repeated
Close calls delegate idempotently and therefore retry a retained failed
publication; Reset uses the same retry before starting a replacement.

## HTTP API and Security

Endpoints:

```text
GET    /api/repl
POST   /api/repl/evaluations
POST   /api/repl/reset
DELETE /api/repl
```

`GET /api/repl` lazily starts the first session and returns its safe info,
bounded transcript, and mutation nonce. After explicit close it returns the
closed state without silently creating another session; Reset starts the next
one. A terminal-but-unpersisted session is returned as terminal with its
bounded reason and retained transcript; bootstrap does not close, persist, or
replace it. Safe info includes the stable session ID, `log-analysis-v1` profile
ID, profile digest, and `log` namespace. No route in this increment accepts a
profile ID or logical resource selector. When no REPL adapter was configured,
all four routes return fixed `404` JSON without starting any owner.

Evaluation accepts exactly:

```json
{"source":"(log/counters {})"}
```

Mutation security:

- require `application/json` for POST routes;
- reject unknown or missing body keys;
- install a small Plug body limit before JSON decoding and retain the Kernel
  subordinate-source limit as authoritative;
- require `X-PTC-Viewer-Nonce` equal to the random per-server nonce returned by
  the same-origin bootstrap;
- never place the nonce in a URL or log metadata;
- require an `Origin` whose scheme, loopback host, and actual bound port match
  the validated `Host` header;
- accept only the configured loopback names (`localhost`, `127.0.0.1`, and
  `[::1]` when the listener uses it);
- add `Cache-Control: no-store` to REPL and inspection responses;
- add a restrictive CSP, `frame-ancestors 'none'`,
  `X-Content-Type-Options: nosniff`, and `Referrer-Policy: no-referrer`;
- never accept a path, filename, manifest, provider, component, capability, or
  limit in an HTTP request.

Stable status mapping:

| Condition | HTTP status |
| --- | --- |
| completed evaluation, including domain error/fail/limit | `200` |
| REPL feature not configured | `404` |
| invalid JSON, content type, or body shape | `400` / `415` |
| invalid nonce, Host, or Origin | `403` |
| evaluation/reset/close already active; evaluate after terminal or explicit close | `409` |
| body or source too large | `413` |
| malformed/unsupported trace capture during bootstrap/reset | `422` |
| trace source unavailable | `503` |
| bounded adapter or persistence failure | `500` |

Do not put adapter values, paths, source, exceptions, or stack traces in error
bodies. Keep bounded stable reason atoms internally and return fixed public
messages.

Exceeding the profile's protocol-error quota terminally closes `RunState` and
rejects later evaluations. Return and render this as a bounded domain limit
outcome, transition the Viewer store to `:terminal`, and retain Close or Reset
to persist the terminal session. Deadline expiry instead invokes automatic
orderly close and persistence; subsequent bootstrap reports the resulting
closed or persistence-failed state.

Nonce and Host/Origin checks apply to every mutation, including bodyless
`DELETE /api/repl`. Only POST routes require `application/json`; DELETE accepts
no request body. After a persistence failure, repeated DELETE retries the same
idempotent close. Reset also retries close first and never starts a replacement
until publication succeeds.

## Viewer UI

When the connected backend advertises REPL support, add top-level `Runs` and
`REPL` tabs while preserving the selected run and its existing transcript
independently. Project only a fixed `repl_enabled` boolean from server config
into the initial CSP-compatible page response; do not expose the adapter feature
descriptor or backend context. A standalone Viewer without a configured REPL
adapter renders the existing Runs-only interface and makes no REPL bootstrap
request.

The REPL tab contains:

- a provenance banner stating that execution is mission-only against an
  immutable normal-trace capture using server-owned profile
  `log-analysis-v1` and the `log.core` API;
- the safe profile digest and available `log` namespace;
- safe snapshot ID, capture time, visible run count, and source size;
- remaining session time, evaluations, trace-query calls, and continuation
  memory/history summary;
- a multiline Clojure-highlighted editor;
- Evaluate, Reset/Refresh, and Close controls;
- Cmd/Ctrl+Enter submission;
- the server-owned ordered transcript, including omitted-entry markers;
- distinct continued, returned, explicit-fail, evaluator-error, timeout,
  memory/history/result-limit, and persistence-error states;
- evaluator prints and explicit value/print truncation markers;
- disabled mutation controls while work is active;
- disabled Evaluate with a bounded explanation when the session is terminal or
  automatically closed, while Close/Reset remain available as appropriate;
- a note that reset first closes/persists the old run, then captures the trace
  directory again;
- a small copyable examples palette for `log/runs`, `log/run`, `log/turns`, and
  `log/counters`;
- when a run is selected in the Runs tab, a safe action that inserts its run ID
  into a `log/run` or `log/turns` template without changing session authority.

Reuse the shipped Clojure highlighter. Do not implement parsing, balancing, or
evaluation in JavaScript. Render every source, print, formatted result, error,
snapshot field, and run ID as escaped text.

After successful reset, refresh the run list so the closed analysis run becomes
visible without losing the user's current tab/run selection. The new session
transcript starts empty.

When persistence fails, retain the transcript and session provenance, render a
distinct retryable error, and label Close as `Retry persistence`. Reset from
that state first performs the same retry and proceeds only on success.

## Failure-State Transitions

Terminal and expiry transitions are distinct:

1. A terminal Kernel budget is observed as part of the accepted evaluation
   result.
2. The store records `:terminal`, disables Evaluate, and preserves the final
   transcript entry and opaque handle.
3. Close or Reset runs the ordinary idempotent persistence path. Until one of
   those mutations or Viewer shutdown occurs, bootstrap continues to expose
   the terminal state without side effects.
4. The fixed deadline is independently owned by `LogAnalysisSession`. On
   expiry it rejects new work and automatically runs orderly close and
   persistence, even with no connected browser.
5. The store converges through `info/1` to `:closed` after successful automatic
   persistence or `:persistence_failed` after failure. Neither result causes
   lazy session recreation; only Reset may start another session.

Reset is deliberately not rollback-atomic across persisted runs:

1. An open session transitions to closing.
2. Close and persist the old session.
3. If persistence fails, retain `:persistence_failed`, return an error, and do
   not construct a replacement session.
4. After successful persistence, capture a new snapshot.
5. Start with a fresh operation ID. If the task exits before returning, enter
   `:reconciling_start` and recover the committed session or a definitive
   `:not_started` result before permitting another Reset.
6. If capture/session construction definitively fails, remain closed with the
   previous run safely persisted; a later Reset may use a new operation ID.
7. Install the new opaque handle and clear the presentation transcript only
   after successful start or reconciliation.

From `:persistence_failed`, Close and Reset both first invoke idempotent close
again against the retained handle. A successful Close finishes in `:closed`; a
successful Reset continues with snapshot capture and start. Failure remains in
`:persistence_failed` with no duplicate terminal event, publication, or new
session.

This ordering guarantees that a refreshed snapshot includes the prior session
when persistence succeeded and avoids two live sessions after a partial reset.
An unavailable backend during reconciliation leaves the store in
`:reconciling_start`; it must not guess that no session exists and start again.

## Likely Files

Core additions/refactors:

- `lib/ptc_runner/kernel/log_analysis_profile.ex`
- `lib/ptc_runner/kernel/log_analysis_session.ex`
- `lib/ptc_runner/kernel/log_analysis_session_builder.ex`
- `lib/ptc_runner/kernel/session_trace.ex`
- `lib/ptc_runner/kernel/event_sink.ex`
- `lib/ptc_runner/kernel/trace_snapshot.ex`
- `lib/ptc_runner/kernel/trace_log.ex`
- `lib/ptc_runner/kernel/trace_capability.ex`
- `lib/ptc_runner/kernel/evaluation.ex`
- `lib/ptc_runner/kernel/run_config.ex`
- `lib/ptc_runner/kernel/runtime_tools.ex`
- `lib/ptc_runner/kernel/viewer_repl_adapter.ex`
- `lib/ptc_runner/kernel/safe_metadata.ex` only if a new finite UI-visible tag
  is justified; `mode = repl` requires no change
- Kernel public/module docs and `docs/guides/kernel-maintainer.md`

No production change is expected in `repl_session.ex`, `run_state.ex`, or
`mix ptc.repl` unless a focused regression exposes a shared-boundary defect.

Viewer additions/refactors:

- `ptc_viewer/lib/ptc_viewer.ex`
- `ptc_viewer/lib/ptc_viewer/router.ex`
- `ptc_viewer/lib/ptc_viewer/api.ex`
- `ptc_viewer/lib/ptc_viewer/repl_adapter.ex`
- `ptc_viewer/lib/ptc_viewer/repl_store.ex`
- `ptc_viewer/lib/mix/tasks/ptc_viewer.ex`
- `ptc_viewer/priv/static/index.html`
- `ptc_viewer/priv/static/js/app.js`
- `ptc_viewer/priv/static/js/repl.js`
- `ptc_viewer/priv/static/css/styles.css`
- `ptc_viewer/README.md`

Production code documentation must not link to this plan. Move durable
contracts into module docs, the Kernel maintainer guide, Viewer README, and
trace-log contract as they are implemented.

## Test Plan

### Snapshot and capability tests

1. A normal directory is loaded and validated once.
2. Private and inspection suffixes are excluded.
3. Malformed, unsupported, oversized, replaced, or concurrently changed
   sources fail with the existing stable classifications.
4. Pagination remains valid after the underlying directory changes.
5. Cursors remain bound to snapshot, operation, and filters.
6. Snapshot retained and encoded ceilings are independently enforced.
7. Evaluator workers capture only the tokenized handle, not the full event
   collection.
8. Snapshot owner death yields a bounded provider error and no path disclosure.

### Core session tests

1. `log-analysis-v1` has a deterministic descriptor and digest containing the
   frozen bundle, authoritative mission inventory, implicit runtime contract,
   every effective limit, persistence policy, and result policy, with no
   callbacks or resources.
2. Profile assembly exposes `log.core`, the four explicit trace capabilities,
   and normal implicit mission introspection, while `fs`, LLM, agent, workflow,
   MCP, private-inspection, and kernel-eval authority remain absent.
3. Characterize the current workflow-REPL nested lease conflict without
   changing `ReplSession`.
4. The same source sequence produces the same mission outcomes, memory,
   history, capability accounting, and canonical evaluation events through
   direct detailed `Evaluation` and `LogAnalysisSession`.
5. Ordinary success advances `*1/*2/*3`; return does not; fail/error rolls back.
6. Return and fail leave the human session open.
7. `log.core` queries the frozen snapshot with only the four explicit
   capabilities.
8. Workflow-only kernel-eval, LLM, annotation, and provider capabilities are
   unavailable.
9. Per-evaluation timeout and aggregate session/evaluation/capability budgets
   accumulate across forms.
10. Valid and invalid implicit runtime calls exercise their canonical events
    and protocol accounting; exceeding the protocol-error quota closes the
    session, renders a terminal limit state, and still permits persistence.
11. JSON-hostile inert values produce bounded formatted text and
   `value_available?: false` without crashing encoding.
12. Large values, prints, formatted values, error messages, and complete HTTP
   projections respect their independent limits and expose truncation.
13. A public result-limit failure documents whether continuation was already
    committed by the shared evaluation boundary.
14. Accepted evaluation continues safely after caller/request death.
15. An owner deadline timer makes idle session expiry reject new work and run
    normal close/persistence without a later HTTP call; failure retains the
    retryable batch and safe closed state.
16. Saturating ordinary event count and bytes with explicit and implicit calls
    retains one dropped summary and exactly one reserved terminal event.
17. Normal close emits exactly one terminal event and treats earlier form
    errors as evaluation facts rather than terminal session failure.
18. Explicit abort and unexpected owner death clean provider/snapshot/state
    resources exactly once.
19. Unexpected owner death leaves `SessionTrace` alive long enough to emit an
    aborted terminal event and attempt persistence.
20. Persistence fault injection before, during, and after atomic publication
    retains one retryable batch and never exposes a partial discoverable file
    or duplicates sequences across retry/reset/shutdown.
21. Persisted analysis traces reload through `TraceLog` and a new snapshot can
    query the predecessor.
22. Source, transcript, native continuation, callbacks, snapshot events,
    paths, and nonce are absent from canonical events, owner status, Logger,
    Telemetry, and error projections.

### Viewer store and API tests

1. Viewer startup without a REPL adapter preserves Runs and inspection behavior,
   starts no `ReplStore`, projects `repl_enabled = false`, and returns fixed
   `404` JSON from REPL routes.
2. Viewer startup rejects a supplied invalid adapter/backend context without
   eagerly constructing a session or silently downgrading to Runs-only mode.
3. Adapter connection advertises only a bounded JSON-compatible
   `log-analysis-v1` feature descriptor; backend configuration remains private.
4. The store starts the server-selected profile, while every HTTP body rejects
   profile and resource fields.
5. Start operation IDs are idempotent; a task exit before handle delivery is
   reconciled to exactly one committed session or a proven no-session result.
6. First bootstrap surfaces bounded snapshot/session initialization failures.
7. Public session info carries a stable binary session ID, profile ID, and
   digest but no opaque local session reference.
8. Opaque adapter/session values never appear in Plug config responses,
   Logger, Telemetry, or OTP status.
9. Evaluation accepts only exact JSON and delegates once.
10. A second evaluation/reset/close during active work returns `409` and is
    never executed later.
11. An accepted evaluation completes after HTTP client disconnect.
12. Body/source limits reject work before evaluation.
13. Missing/wrong nonce and invalid Host/Origin fail before delegation for
    POST and DELETE; DELETE rejects a request body but does not require a JSON
    content type.
14. Adapter exceptions/exits return fixed bounded failures.
15. Domain evaluation failures return HTTP `200` with `status = error`.
16. A terminal-budget evaluation returns its final HTTP `200` result, moves the
    store to `:terminal`, rejects later Evaluate with `409`, and retains Close
    and Reset.
17. Deadline-driven automatic persistence is observed through `info/1` as
    `:closed` or `:persistence_failed` and never triggers lazy replacement.
18. Reset is store-visible close -> persist -> idempotent start/reconcile ->
    install and handles task exit at each transition without two active
    sessions or a lost committed handle.
19. Explicit close prevents implicit recreation by evaluate/bootstrap; Reset
    creates the next session.
20. Repeated Close from `:persistence_failed` retries the same retained batch;
    Reset performs that retry first and starts nothing until it succeeds.
21. Viewer termination closes/persists every committed session and store.
22. Transcript projection handles one maximum source/result with hostile JSON
    escaping inside its per-entry ceiling, preserves a metadata-only newest
    entry when needed, and enforces aggregate eviction and omitted count.
23. Existing read-only trace and inspection routes remain unchanged except for
    shared security/no-store headers where deliberately adopted.

### Browser/render tests

1. Runs-only mode omits the REPL tab and makes no REPL bootstrap request; the
   enabled mode projects only the fixed feature boolean and renders both tabs.
2. Tabs preserve selected run and REPL state independently.
3. Reload restores the bounded server transcript and session info.
4. Multiple tabs observe the same server transcript and busy state.
5. Multiline source is submitted exactly once.
6. Every evaluation, terminal, closed, and persistence state renders distinctly.
7. Buttons disable during in-flight work and recover after bounded failure;
   terminal disables Evaluate but retains Close/Reset.
8. Persistence failure presents `Retry persistence`, and Reset cannot advance
   to a new session until retry succeeds.
9. Reset explains and performs snapshot refresh.
10. Source, prints, returned text, errors, run IDs, and snapshot metadata cannot
   inject markup.
11. Narrow viewport and long Lisp forms remain usable.
12. Example and selected-run templates insert escaped text only and never alter
    authority.

### End-to-end journey

1. Generate a credential-free multi-turn agent trace.
2. Start the Viewer with its trace directory.
3. Open the REPL tab and inspect snapshot provenance/budgets.
4. Evaluate `log/runs`, `log/run`, `log/turns`, and `log/counters` queries.
5. Define a helper in one form, use it and `*1` in later forms, and exercise a
   recoverable error.
6. Reload and confirm transcript plus continuation remain understandable.
7. Reset, causing orderly close and persistence.
8. Confirm the analysis run appears in the run picker.
9. Confirm the refreshed session can query the predecessor trace.
10. Run root `mix precommit`, format the nested Viewer project, and run its
    tests.

## Delivery Slices and Review Gates

### Slice 1: immutable snapshot

- Add `TraceSnapshot` and shared `TraceLog` query support.
- Add snapshot-backed trace capabilities.
- Complete source-change, cursor, ceiling, cleanup, and path-redaction tests.
- Update the durable trace contract.

Exit gate: repeated queries observe one immutable validated capture while the
directory changes underneath it.

### Slice 2: mission log-analysis session

- Add the detailed shared `Evaluation` result without duplicating execution.
- Add `log-analysis-v1`, fixed limits, builder, `SessionTrace`, and
  `LogAnalysisSession`.
- Verify the exact positive and negative authority inventory and persist safe
  profile identity.
- Add the opt-in terminal event reserve and atomic no-clobber publication with
  saturation and fault-injection coverage.
- Complete continuation, result projection, lifecycle, persistence, cleanup,
  and privacy tests.
- Leave the workflow REPL unchanged.

Exit gate: a programmatic session repeatedly evaluates through the exact
mission boundary, queries a snapshot, and persists one reloadable canonical
run.

Perform an adversarial review of owner death, result encoding, event loss,
provider cleanup, retry/no-duplicate persistence, and source confidentiality
before adding HTTP.

### Slice 3: Viewer adapter, store, and HTTP

- Add the transport-neutral standalone behavior, local connected backend,
  idempotent start reconciliation, bounded feature descriptor, root adapter,
  redacted fail-fast store, per-entry transcript projection, and lifecycle
  attachment.
- Preserve Runs-only startup when the REPL adapter is absent; fail startup when
  an explicitly configured adapter or backend is invalid.
- Add terminal, automatic-expiry convergence, and idempotent persistence-retry
  transitions without implicit session recreation.
- Add secured bounded routes and exact status mapping.
- Wire the root Mix task and verify startup/teardown failures.

Exit gate: one local browser client can safely execute bounded log-analysis
programs without `ptc_viewer` depending directly on `ptc_runner`.

### Slice 4: REPL UI and journey

- Add tabs, editor, transcript, examples, selected-run templates, budgets,
  result states, close, and reset.
- Complete render/browser tests and the credential-free journey.
- Update Viewer README and relevant Kernel guides.

Exit gate: the human workflow is complete, reload-safe, and the persisted
analysis run renders and is queryable through the normal Viewer path.

Finish with a whole-range review followed by root `mix precommit` and the
nested Viewer formatter/tests. Run `mix prepush` before pushing.

## Acceptance Criteria

- Human-entered programs execute through the same mission evaluator and
  continuation semantics as model-generated programs.
- Standalone `PtcViewer` remains Runs-only when no REPL adapter is configured;
  root `mix ptc.viewer` explicitly enables the validated local adapter, and an
  invalid requested adapter fails startup.
- Exact bounded definitions and `*1/*2/*3` behave consistently across forms.
- Server-owned `log-analysis-v1` installs only `log.core`, the four explicit
  trace capabilities, empty mission data, fixed limits, and declared policies.
- `log.core` analyzes one host-selected immutable normal trace capture, and
  persisted metadata identifies the exact profile definition.
- The browser cannot select or expand authority or limits.
- The Viewer adapter is not coupled to a filesystem source tuple, while this
  increment remains local-only and implements no remote control plane.
- Continuation, snapshot, trace persistence, and Viewer lifecycle each have one
  explicit owner with no read-modify-write races.
- Overlapping mutations fail fast and are never executed later.
- Terminal Kernel budgets retain the final result, reject later Evaluate, and
  preserve Close/Reset; idle deadline expiry automatically closes and persists
  without relying on a browser request.
- Start/reset task failure is reconciled without losing a committed handle or
  creating a second live session.
- Event saturation retains bounded loss evidence and exactly one terminal
  event; retryable persistence publishes either one complete trace or none.
- Every HTTP response is strict JSON, bounded, escaped in the UI, and free of
  native terms, paths, callbacks, source leaks, and stack traces.
- Normal close/reset and Viewer shutdown persist exactly one reloadable
  canonical trace; unexpected owner failure receives a best-effort aborted
  persistence attempt.
- Persistence failure is retryable and never rewrites evaluation outcomes or
  appends duplicate sequences. Repeated Close retries it, and Reset cannot
  construct a replacement until the retry succeeds.
- Reload and multiple tabs show a consistent bounded presentation transcript.
- A reset session captures and can query its persisted predecessor.
- Active self-query and private inspection-query Lisp remain unsupported.
- Existing workflow REPL and read-only Viewer behavior remain intact.
- Durable docs describe the implemented contracts without linking to this
  plan.
- Focused tests, root `mix precommit`, nested Viewer formatting/tests, and final
  semantic review pass before commit.

## Later Decisions Outside This Change

- Whether the local Viewer should eventually support several named analysis
  sessions.
- Whether a later authenticated Core service may expose remote or multi-user
  analysis through logical trace-collection resources, scoped roles, and a
  Viewer backend-for-frontend.
- Whether a second concrete profile justifies a general `SessionProfile`
  behaviour and trusted startup registry.
- Whether trusted deployments need constrained profile enablement and
  downward-only operational limit overrides. Arbitrary declarative preludes,
  callback modules, and browser-supplied capability lists remain prohibited.
- Whether exact inspection records need a separately granted Lisp query layer;
  any such design must build on the existing pinned/correlation-validated
  inspection grant and use sequence/correlation identity rather than inventing
  an unsupported record ID.
- Whether session traces need durable per-event streaming and restart recovery.
- Whether a separate `mix ptc.analyze` frontend should reuse the builder.
- Whether evidence justifies a generic public interactive-mission abstraction
  after this concrete session and another independent consumer exist.
