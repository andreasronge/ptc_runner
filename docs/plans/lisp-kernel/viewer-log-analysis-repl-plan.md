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
- The Viewer store rejects overlapping evaluate/template/reset/close operations
  with `409`; rejected requests are never queued for later execution.
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
  separate trace recorder that survives the evaluation owner long enough for
  one attempt, then stops. Retry retention requires a still-live session.
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
| Continuation memory/history, quotas, and canonical event buffer | one combined `RunState`/`EventSinkState` process lifecycle-owned by `SessionTrace` | `Evaluation` reserves and atomically commits/releases; event-token operations share the same owner |
| Frozen trace data | tokenized `TraceSnapshot` owner | snapshot-backed `TraceCapability` callbacks |
| Finalized canonical event batch and persistence state | `SessionTrace` | `LogAnalysisSession` and close/reset lifecycle |
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

Core `info/1` is serialized behind an already accepted evaluation and waits for
that bounded operation rather than applying a shorter call timeout that could
falsely report the live session as closed. Viewer background refreshes may use
their own discardable outer watchdog as specified below.

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
mission environment, limits, trace, and snapshot. Attestation is not sufficient
authority: startup independently reconstructs the fixed profile from that
snapshot and trace sink and requires exact config, bundle, snapshot-bound
capabilities, inventory, limits, and profile equality. It must reject
independently assembled environments, substituted callbacks, or mismatched
profile metadata. No public session API accepts a browser-selected path or an
already assembled arbitrary capability set.

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

`LogAnalysisSession` also owns a token-correlated timer for the fixed run deadline. Expiry
atomically rejects new work, waits for any already accepted bounded evaluation
to finish, and runs the normal close-and-persist path. The owner remains able
to report safe closed information and accept idempotent `close` after successful
publication. If automatic persistence fails, it retains only the finalized
batch and closed trace owner required for retry, releases the continuation and
snapshot owners, and reports the normal retryable persistence state.

Treat both `SessionTrace` and the combined continuation/event owner as
fail-closed dependencies. The `RunState` GenServer embeds the session's
`EventSinkState`, so recorder readiness validation and continuation commit are
one callback in one owner rather than a cross-process check followed by a
commit. The session and `SessionTrace` monitor that combined runtime. If either
owner dies, no in-flight continuation can commit without its corresponding
event authority, later work is refused or the opaque handle closes, and the
snapshot is released; normal-policy capacity loss must never be confused with
recorder death. During construction, `SessionTrace` monitors the builder as
well as any attached partial session. Builder death or an exception after any
owner is acquired kills and observes that session and cleans every owner.
Session death while the builder guard remains active is construction cleanup,
not an operational abort, and must not publish a terminal trace. Any failed
post-start handoff explicitly stops the retained partial session even if the
trace owner is already unavailable. If the trace owner dies before ownership
of the combined runtime is transferred, the builder explicitly cleans that
still-builder-owned runtime rather than relying on the builder process to exit.
Attach the sole session owner before emitting `run-started`, so replay of an
already-attached assembly is rejected without mutating the canonical batch.
Invoke the builder from the root adapter's long-lived connected backend owner,
not its disposable callback wrapper. After snapshot transfer and safe info
capture, mark construction complete but retain that lifecycle-owner monitor.
Owner death during the final call/reply window can then neither lose the only
handle nor orphan the session; later backend-owner death aborts and best-effort
persists the completed session.

After every evaluation, inspect the authoritative `RunState` terminal status
before replying. A terminal budget such as the protocol-error ceiling returns
the triggering bounded domain result and marks the session
`:terminal_unpersisted`; it does not automatically persist. Later evaluation is
rejected, while `info`, `close`, and the close phase of Reset remain available.
Retain the authoritative terminal reason and use error outcome plus that reason
for the eventual `run-stopped`; close, abort, and deadline expiry succeeding as
operations must not rewrite budget exhaustion into another terminal result.
Transfer the first authoritative reason to `SessionTrace` before replying so an
unexpected owner death while terminal-but-unpersisted cannot replace it with a
generic owner-failure reason.

### Evaluation result projection

The root adapter returns a strict, encoded-size-checked JSON projection:

```elixir
%{
  status: :ok | :error,
  outcome: atom(),
  continuation_effect: :committed_with_history | :committed_without_history | :preserved,
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
    trace_calls: %{
      "trace-list-runs" => %{used: non_neg_integer(), limit: pos_integer(), remaining: non_neg_integer()},
      "trace-get-run" => %{used: non_neg_integer(), limit: pos_integer(), remaining: non_neg_integer()},
      "trace-list-turns" => %{used: non_neg_integer(), limit: pos_integer(), remaining: non_neg_integer()},
      "trace-counters" => %{used: non_neg_integer(), limit: pos_integer(), remaining: non_neg_integer()}
    },
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

`trace_calls` is a closed projection of exactly the four explicitly granted
trace capabilities. Derive its used counts from authoritative
`RunState.usage/1` mission call accounting and its limits from the fixed
per-name profile limit; missing names report zero. For each entry, effective
`remaining` is
`min(per_name_limit - per_name_used, mission_call_limit - mission_calls_used)`,
clamped at zero, so aggregate exhaustion can never be presented as available
capacity. Do not expose arbitrary runtime route names or allow the browser to
select counters. Include the same closed projection in session `info/1`,
adapter/store state, and transcript usage summaries so the session details
panel never derives accounting locally.

Projection rules:

- continued and returned outcomes have `status: :ok`;
- failed, evaluator-error, timeout, quota, memory/history, and result-limit
  outcomes have `status: :error`;
- all accepted evaluation outcomes are successful HTTP operations and return
  HTTP `200` with the domain status above;
- derive `continuation_effect` authoritatively at the shared evaluation
  boundary only after `RunState.commit_evaluation/4` returns `:ok`: ordinary
  success is then `:committed_with_history`, and explicit return is then
  `:committed_without_history`. Explicit fail, every pre-commit error, and every
  rejected commit including memory, history, deadline/run-closed, or stale-state
  rejection is `:preserved`. Preserve a committed effect if later public
  projection or result-size enforcement changes the exposed status to an error;
  the adapter, store, and browser must never infer the effect from `status` or
  `outcome`;
- use the native result internally for continuation and only
  `Lisp.externalize_value/1` at the public boundary;
- normalize the externalized value through a bounded JSON encode/decode step;
- if a value is inert but not JSON-encodable, return `value: nil`,
  `value_available?: false`, and retain its bounded Clojure rendering;
- cap the complete formatted output, not only strings nested inside it, and
  return an explicit truncation marker and flag;
- preserve bounded evaluator prints for every outcome for which the detailed
  evaluator result has them; terminal returned/failed forms should remain
  useful to a human even though the model loop does not need terminal prints.
  Project them in one pass under a fixed 128-entry ceiling and a 65,536-byte
  encoded JSON-array ceiling, returning the truncation flag from that pass so
  empty strings cannot evade the bound;
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
11. Start the combined tokenized `RunState`/normal-event owner, then start
    `SessionTrace` with that handle and the persistence destination. Transfer
    the combined owner's lifecycle to `SessionTrace` before session startup.
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

- the lifecycle of the combined `RunState`/normal-event owner and its handles;
- the unique run/trace identity;
- the validated destination beneath the configured trace directory;
- terminal-event state;
- the retained final event batch;
- persistence state: `:open`, `:terminal_unpersisted`, `:persisted`, or
  `{:persistence_failed, reason}`;
- the last successfully persisted sequence.

Construction accepts only an empty, unfinalized combined recorder with open
RunState and the exact reserve for one dropped summary plus one stopped event.
A zero-reserve, already-finalized, or closed runtime is rejected before session
attachment.

`SessionTrace` owns the combined runtime lifecycle, then monitors the attached
analysis session. This allows it to atomically take possession of a finalized
event batch if the evaluation owner exits.

### Orderly close

1. Reject new evaluations.
2. Wait for an accepted evaluation to finish; the Viewer normally prevents
   overlapping close before this reaches core.
3. Close `RunState` against new reservations.
4. Construct the bounded terminal usage/outcome payload.
5. Ask the combined owner's atomic finalization-and-handoff operation to emit
   the bounded dropped summary when needed, emit exactly one reserved
   `run-stopped`, and return the complete frozen batch in the same callback.
6. Ask `SessionTrace`, which lifecycle-owns the combined runtime and snapshot,
   to stop and observe those resources exactly once before clearing their
   handles. A session-owner death during this synchronous handoff leaves the
   trace owner able to finish cleanup; `SessionTrace` and its frozen batch are
   then the sole retry authority. If an otherwise open runtime died before
   orderly `RunState.close/1` was accepted, mark the recorder `backend_failed`
   before flushing its monitor. Failure before the batch is frozen makes
   finalization fail without a retry batch; failure after handoff preserves the
   frozen batch and terminal result.
7. Ask `SessionTrace` to persist the complete batch to a new, no-clobber normal
   JSONL file.
8. On persistence failure, keep only the closed session and retained trace
   owner alive so repeated `close` can retry without appending duplicates.

Persistence failure is returned separately and never rewrites the final
evaluation outcome or the already emitted run terminal outcome.

### Abort or unexpected owner death

- Explicit abort emits one error `run-stopped` when possible, closes
  continuation/provider resources, and attempts persistence.
- When the session process dies unexpectedly, `SessionTrace` observes `:DOWN`,
  emits an aborted terminal event if none exists, and attempts best-effort
  persistence independently exactly once before stopping. It does not retain an
  unreachable retry owner after the only caller-visible session authority died.
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
   can replace an existing destination. Sync the containing directory after
   installing the final link and again after removing the temporary link before
   reporting success. Compare device/inode identity between the still-open
   temporary descriptor, the temporary pathname immediately before linking,
   and the destination immediately after linking; pathname replacement is a
   collision and must never be acknowledged as success.
4. If the final path already exists after a retry or process interruption,
   validate that it is a complete byte-identical publication of this exact
   run. Sync its containing directory before treating that retry as success; a
   partial or different file is a collision and must not be appended or
   overwritten.
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
@callback prepare_operation(
            opaque_backend,
            opaque_session_or_nil,
            :start | :evaluation | :close,
            binary()
          ) :: :ok | {:error, atom()}
@callback start(opaque_backend, binary(), binary()) ::
            {:ok, opaque_session, map()} | {:error, atom()}
@callback reconcile_start(opaque_backend, binary()) ::
            {:ok, opaque_session, map()} | {:error, atom()}
@callback evaluate(opaque_backend, opaque_session, binary(), binary()) ::
            {:ok, map()} | {:error, atom()}
@callback reconcile_evaluate(opaque_backend, opaque_session, binary()) ::
            {:ok, map()} | {:error, atom()}
@callback template(opaque_backend, opaque_session, :run | :turns, binary()) ::
            {:ok, %{source: binary()}} | {:error, atom()}
@callback info(opaque_backend, opaque_session) :: {:ok, map()} | {:error, atom()}
@callback close(opaque_backend, opaque_session, binary()) :: {:ok, map()} | {:error, atom()}
@callback reconcile_close(opaque_backend, opaque_session, binary()) ::
            {:ok, map()} | {:error, atom()}
@callback acknowledge_operation(opaque_backend, :start | :evaluation | :close, binary()) ::
            :ok | {:error, atom()}
@callback abort(opaque_backend, opaque_session, atom()) ::
            {:ok, map()} | {:error, atom()}
```

The evaluate arguments after the session are a store-generated operation ID and
source. Before launching any start, evaluation, or close callback wrapper, the
store invokes the typed, idempotent `prepare_operation/4` under a short watchdog.
Preparation creates the only ledger record from which the corresponding initial
callback may transition to accepted; an initial callback never creates a missing
record itself. `prepare_operation/4` is idempotent for the same typed ID. If its
wrapper exits or times out, the store terminates and observes that wrapper and
repeats preparation once with the same ID to distinguish a committed reservation
from a definitive failure; a second ambiguous result enters `:backend_failed`.
No initial callback is launched until preparation is confirmed. This
pre-registration makes an absent record after acknowledgement reject a late
initial callback rather than recreate work.

The behaviour documents fixed callback deadlines. The production root backend
must enforce shorter internal deadlines for preparation, start, and
reconciliation, including snapshot filesystem work, and must clean or retain
every partially constructed resource under its connected backend owner before
returning. `ReplStore` also runs adapter callbacks beneath a Viewer-owned task
supervisor and watchdog. A start watchdog first terminates and observes the
adapter wrapper task, then transitions to reconciliation by operation ID rather
than claiming no session exists. The backend operation ledger atomically seals
that ID during
`reconcile_start/2`: it either returns the already committed handle or changes
`:prepared`/`:starting` to `:sealed_not_started`. A late worker can commit only
from `:starting`; rejection after sealing makes it clean every candidate
resource.
Sealing alone is not a terminal answer. The backend then waits, within its
fixed reconciliation deadline, until the start worker is observed down and its
candidate cleanup barrier is confirmed by the backend owner. Only then may it
return definitive `:not_started` or acknowledge that operation. Until that
barrier completes, the operation stays ambiguous and the connected backend
rejects every fresh start ID. Thus `:not_started` proves both that no late
commit can occur and that no rejected candidate coexists with a replacement.
A reconciliation watchdog transitions to
`:backend_failed`, returns fixed `adapter_failure`, rejects new work, and leaves
the connected backend owner responsible for terminating any committed session
on Viewer shutdown. It never retries with a fresh operation ID after an
ambiguous start. The root backend's internal deadline must expire before the
store watchdog, so the production path normally returns a proved committed or
uncommitted result. A test adapter that never returns cannot leave the store in
`:starting`, `:reconciling_start`, or an occupied task slot forever.

Evaluation uses the same idempotent operation-ledger principle. The backend
atomically changes the pre-registered ID from `:prepared` to `:accepted` before
running Core and stores its single eventual public result. Reusing the ID never
evaluates again. If reconciliation reaches the backend owner first, it changes
`:prepared` to `:sealed_not_accepted`; the late initial callback is then rejected
without running Core. Sealing is followed by a backend-owner cleanup barrier:
only after the original wrapper is observed down and the backend has confirmed
that no worker or candidate resource for the ID remains may reconciliation
return definitive `:not_accepted`. The sealed record remains until Viewer
installation/acknowledgement, and a missing acknowledged record is never valid
initial admission. After a definitive `:not_accepted` result is acknowledged,
the store restores the predecessor open/terminal state, returns fixed
`adapter_failure` for that request, and permits only an explicit new user action;
it appends no transcript entry. `reconcile_evaluate/3` otherwise returns the committed result
or waits within the backend's fixed whole-operation deadline. The Viewer
watchdog is longer than the profile's
maximum Core evaluation plus bounded projection overhead; if it fires, the
store terminates and observes only the adapter wrapper, then reconciles the same
operation ID. It never reports a timeout while forgetting an evaluation that
can still commit. A reconciliation watchdog moves the store to
`:backend_failed`, prevents new work, and leaves the backend ledger/session to
be closed by the Viewer-owned backend tree. It also retains the one pending
evaluation operation ID and schedules at most one short, watchdog-bounded
background reconciliation attempt per second. These retries never occupy the
mutation slot or accept new work. If the result later becomes queryable, the
store installs it exactly once in the transcript, acknowledges the operation,
and retains the safe backend-failed lifecycle for explicit close/shutdown. This
path handles a defective never-returning adapter without permanently occupying
the mutation slot or losing a result that committed after the initial timeout.

The store's pending evaluation record also retains the bounded source preview,
source byte count, source-truncation flag, session ID, and operation ID needed
to build the transcript entry; it never retains a second unbounded source copy.
Recovered result installation is one atomic store transition that verifies the
pending operation/session, appends at most once, refreshes cached usage, and
acknowledges only after installation. It never moves lifecycle backward: a
newer `:closing`, `:closed`, `:persistence_failed`, or `:backend_failed` state is
preserved. Close may reconcile concurrently because Core waits for an accepted
evaluation, but Reset cannot install a replacement until every predecessor
evaluation result is installed and acknowledged.

Close is also an idempotent pre-registered operation with a store-generated ID
and backend result ledger. `close/3` changes `:prepared` to `:accepted` before
persistence; `reconcile_close/3` returns the single result without repeating
terminal events or publication. If reconciliation wins the race, it seals
`:prepared` as `:sealed_not_accepted`; a late initial close cannot persist, and
the backend returns definitive `:not_accepted` only after the wrapper-down and
backend cleanup barrier. After acknowledgement, the store restores the exact
pre-close lifecycle, returns fixed `adapter_failure`, and permits an explicit
retry with a fresh prepared ID; a Reset whose close phase was not accepted does
not begin capture/start. On a whole-close watchdog, the store terminates and
observes the wrapper and reconciles the same ID. If reconciliation also times
out, it
returns fixed `adapter_failure`, enters `:backend_failed`, accepts no evaluation
or Reset, and performs the same one-at-a-time bounded background reconciliation.
A later recovered close result installs `:closed` or `:persistence_failed` and
is acknowledged. Reset never begins a replacement until close reconciliation
has definitively succeeded.

Backend operation ledgers are bounded. They retain only unacknowledged start,
evaluation, and close records. After `ReplStore` atomically installs the handle,
transcript result, or close result and observes the wrapper task down, it sends
the typed idempotent acknowledgement; the backend then prunes that operation.
The same rule applies when start reconciliation proves `:sealed_not_started`,
evaluation/close reconciliation proves `:sealed_not_accepted`, or any operation
returns another definitive terminal result: after observing the wrapper and
backend cleanup barriers, the store acknowledges that operation before accepting
a dependent fresh ID.
While that acknowledgement is pending, `:never_started` bootstrap or
predecessor-authorized Reset returns `409 operation_active`; acknowledgement
failure follows the bounded retry/backend-failed policy below. Repeated failed
starts therefore cannot accumulate sealed backend records.
The store never invokes an acknowledged ID again. At most the current operation
and one result being installed exist per kind, and backend/Viewer termination
cleans all unacknowledged records and their resources. No lifetime tombstone or
closed session handle accumulates across successful Resets.

`acknowledge_operation/3` performs a synchronous call to the adapter-owned
backend owner and returns `:ok` only after that owner has deleted the operation
record. It never mutates the ledger inline in `ReplStore`. The store invokes it
from a separately supervised short-watchdog task, so backend latency does not
block the store, and keeps a bounded acknowledgement record until confirmed
`:ok`. Error, crash, or timeout marks the backend failed, stops new operations,
and retries at most one acknowledgement task at a time on the bounded
reconciliation cadence. Only confirmed backend deletion lets the store prune
its side or accept the next operation whose bound depends on that pruning.
Viewer/backend termination clears any remaining bounded records, so a
defective acknowledgement cannot freeze the store or create an unbounded
task/ledger leak.

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
session info contains a stable, store-generated `session_id`, profile ID, and
profile digest. Generate the ID from 32 random bytes encoded as unpadded
base64url and accept exactly the 43-character grammar `[A-Za-z0-9_-]{43}`.
Generate separate page-bootstrap and mutation nonces with the same entropy and
grammar. None of these values is accepted from an adapter. The adapter's opaque session reference may remain an
in-process term; no PID or reference crosses the HTTP boundary. A later remote
adapter can use its remote session ID as that separate opaque reference without
changing Viewer store or browser semantics.

Treat `session_id` as the public session-generation token as well as an
identifier. Every Viewer mutation carries the exact expected session ID, and
`ReplStore` compares it with the current ID inside the same owner operation that
checks lifecycle state and starts the transition. A stale caller can therefore
never evaluate, format a template, close, or reset a replacement session. The
adapter still sees only the store-selected opaque handle; the browser token
does not become Core authority.

`start/3` receives a store-generated random operation ID and is idempotent for
that connected backend. The backend context atomically records operation ID to
committed session before replying. If the monitored task exits without a
result, the store calls `reconcile_start/2`: it either recovers the one
committed handle and info or proves no session was committed. Reusing an
operation ID never constructs another session, and backend/Viewer termination
closes every committed session even when handle delivery failed.

After a definitive sealed `:not_started`, the initiating first bootstrap returns
fixed `repl_start_failed` and the store returns to `:never_started`; a later
`GET /api/repl` may create a fresh operation without a session precondition. If
the same outcome occurs during Reset after the predecessor was persisted, the
store retains that closed predecessor's public generation and transcript, so a
later Reset remains authorized by its existing header. Neither path invents a
generation token for a session that does not exist. In both cases, the store
first completes the terminal start-operation acknowledgement described above;
it rejects another start while that bounded acknowledgement is pending.

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

`template/4` is a typed inert-source formatter, not evaluation or trace query.
The root adapter accepts only `:run` or `:turns` plus one bounded run ID and
constructs the whole form with `PtcRunner.Lisp.Formatter.format/1` applied to the
string AST. The exact forms are `(log/run "<run-id>")` for `:run` and
`(log/turns "<run-id>" {})` for `:turns`; the quoted placeholder describes one
AST string node and is never textual interpolation. It returns only bounded
source text and never invokes the session, queries the snapshot, or changes
authority. This keeps the security-sensitive
literal encoding canonical instead of maintaining a parallel JavaScript
formatter. The opaque session argument lets a future remote backend enforce the
same session-generation precondition.

Add `PtcViewer.ReplStore`. It owns only:

- the opaque adapter handle;
- the opaque connected-backend context and safe feature descriptor;
- lifecycle state: `:never_started`, `:starting`, `:open`, `:evaluating`,
  `:templating`, `:resetting`, `:reconciling_start`, `:terminal`, `:closing`,
  `:closed`, `:persistence_failed`, or `:backend_failed`;
- the per-server mutation nonce;
- one monitored in-flight mutation task and pending caller, plus at most one
  side-effect-free background info task with its captured revision;
- at most one pending evaluation-reconciliation record/task/timer and one
  pending close-reconciliation record/task/timer, keyed by their operation IDs;
- at most one pending acknowledgement record/task/timer across all operation
  kinds;
- the bounded presentation transcript;
- a monitor on the Viewer/Bandit owner.

It does not own continuation memory, capabilities, snapshot contents, or event
persistence.

These are closed concurrency ceilings, not examples. Start reconciliation uses
the foreground mutation slot. Evaluation and close recovery may overlap only in
their two named background slots; each slot has at most one monitored task and
one scheduled retry, and each retry consumes and replaces its timer before
starting. The global acknowledgement slot serializes acknowledgement across
operation kinds. Therefore the store has at most one foreground callback plus
four background callbacks (`info`, evaluation reconciliation, close
reconciliation, and acknowledgement). Every result validates its captured
session/operation/revision before installation. Success, definitive failure,
generation replacement, store death, and Viewer shutdown cancel and flush the
corresponding timer/monitor refs. The connected backend owner, not `ReplStore`,
owns backend workers, ledger entries, and candidate-cleanup barriers.

`ReplStore` is not independently restartable. A private Viewer lifecycle owner
starts the connected backend tree, store, callback task supervisor, and Bandit
as one fail-closed unit. Unexpected store death and normal shutdown deliberately
use different bounded sequences.

For an unexpected `ReplStore` exit, the lifecycle owner immediately stops
accepting HTTP traffic, terminates Bandit and all Viewer callback tasks, then
terminates the connected backend tree. The backend cleanup contract aborts or
best-effort closes every committed session and removes prepared/accepted ledger
records without trusting vanished store state. The lifecycle owner exits and
does not restart a blank store beside a possibly live backend.

For normal `PtcViewer.stop/1`, the lifecycle owner first stops new HTTP traffic
and asks the live store to shut down while the callback supervisor and backend
remain alive. The store drains or reconciles every already accepted evaluation,
installs and acknowledges its result, cancels side-effect-free template/info
work, and completes the current reset phase without starting an otherwise
uncommitted replacement. If a reset already committed a replacement start, it
reconciles and installs that handle. It then performs one idempotent orderly
close/reconciliation and persistence for the resulting committed session. Only
after the close result is installed and acknowledged, or the single bounded
shutdown deadline expires, does the lifecycle owner terminate remaining callback
tasks and the backend tree. Deadline expiry falls back to backend-owned abort
cleanup and never reports orderly persistence. This keeps the backend alive for
accepted-work persistence while making isolated store death fail closed.

To remain responsive while an evaluation or template formatter runs, start one
monitored task that performs the synchronous adapter call, retain its caller,
and reply when the task finishes. Evaluation uses the operation ID, long
whole-callback watchdog, and reconciliation contract above; it is never killed
or forgotten merely because an HTTP caller disconnects or a default five-second
call expires. The side-effect-free template formatter uses a short outer
timeout. Represent template work as `:templating`; while either mutation task is
active, reject further evaluate/template/reset/close calls immediately rather
than queueing them in the owner mailbox. Normalize template timeout and all task
exceptions/exits without leaking exception terms. Reset and close use the same
single in-flight transition slot.

After initial session creation, `GET /api/repl` never calls synchronous adapter
`info/1` inside the store owner and never waits behind an active mutation.
`ReplStore` returns its cached safe session projection immediately, overlays its
authoritative busy/lifecycle state, and derives only the countdown from a cached
monotonic deadline. When no mutation is active, it may start one separately
monitored, side-effect-free background `info/1` refresh; an in-flight mutation
does not wait for that task. Give info and template tasks safe short outer
timeouts; timeout clears their task slots and discards their side-effect-free
results. Capture `{session_id, state_revision}` with the
refresh and install its result only if both still match when it returns.
Otherwise discard it. This lets a deadline-driven Core close converge without
allowing old info to overwrite a new evaluation or replacement session.

`state_revision` is store-owned, starts at zero, and changes only when semantic
server state changes: accepting or completing a lifecycle transition,
installing a session, transcript/result change, terminal/persistence change, or
installing a background info result. Allocating or returning a read-only
projection, deriving the countdown, starting/clearing the bookkeeping for an
info task, and browser polling do not increment it. Therefore multiple polls do
not invalidate one slow refresh, while any intervening mutation does.

Every bootstrap and successful mutation projection also carries a
store-generated `server_instance_id` using the same 32-byte unpadded-base64url
grammar, plus two server-owned counters allocated by `ReplStore`:
`generation_sequence`, which starts at one and increments only when a
replacement session is installed, and `projection_revision`, which is scoped
to that generation and increments atomically whenever a response snapshot is
taken. For one server instance, the browser orders state envelopes
lexicographically by `{generation_sequence, projection_revision}` and applies
only a strictly newer pair. There is no Reset exception.

The browser also numbers locally initiated requests. A response from a new
server instance replaces cached server state only when its local request number
is newer than the last applied response; accepting it retires the former
instance ID for the page lifetime. Responses from retired instances and older
local requests are discarded. Because a restarted Viewer intentionally rejects
the old page bootstrap nonce, the client can learn a new instance only through
a fresh nonce-bearing HTML document. On `403 forbidden_request` from an
otherwise same-origin bootstrap or poll, it sets one `sessionStorage`
rebootstrap-attempt marker and performs one hard page reload. The fresh HTML
supplies the new page nonce; the first successful bootstrap clears the marker.
If the reloaded page is also forbidden, it stops and shows a Reload action
instead of looping. The new response can then retire the former instance ID,
while delayed pre-restart responses remain unable to switch the page back.
Thus a delayed poll or Reset response from a predecessor, an older same-session
poll, or an old Viewer process cannot overwrite newer state. Unsent drafts are
outside this ordering mechanism and, like any reload, are intentionally lost.

The presentation transcript is capped at 64 entries and 256 KiB encoded. It
also has a 128 KiB encoded per-entry ceiling. Each entry contains the source
byte count, a bounded encoded source preview with an explicit truncation flag,
and a transcript projection of the already bounded public result. Preserve at
least evaluation ID, status/outcome, `continuation_effect`, duration, usage, and
explicit omission markers when value, formatted output, or prints do not fit.
The transcript projection is presentation-only and cannot change the direct
HTTP evaluation response or continuation state.

Measure actual JSON encoding, including escaping. If a newest entry still does
not fit, replace optional fields with a fixed metadata-only omission record;
never drop the accepted newest evaluation silently. Then evict complete oldest
entries until the aggregate cap fits and expose an omitted-count marker. Clear
the transcript on successful reset. It must be redacted from OTP
`format_status`, Logger, Telemetry, crash reports, and adapter failures.

On normal Viewer termination, an accepted Core evaluation finishes or
reconciles within its installed deadline before orderly close; it is not killed
and left as an ambiguous continuation lease. Unexpected store death instead
uses the fail-closed backend cleanup sequence above because no live presentation
owner remains to install or acknowledge its result.

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
POST   /api/repl/templates
POST   /api/repl/reset
DELETE /api/repl
```

After these exact method/path routes, add path-aware fallbacks for the four
known REPL paths underlying the five endpoint pairs. Any other method, including
`OPTIONS`, returns exact `405 method_not_allowed` JSON after loopback Host
validation and performs no store or adapter call. The response includes no
permissive CORS headers. Unknown paths under `/api/*` retain the existing
fallback behavior; the closed REPL catalog claim applies to those four known
paths and their method fallbacks, not arbitrary unknown API paths.

`GET /api/repl` lazily starts the first session and returns its safe info,
bounded transcript, and mutation nonce. After explicit close it returns the
closed state without silently creating another session; Reset starts the next
one. A terminal-but-unpersisted session is returned as terminal with its
bounded reason and retained transcript; bootstrap does not close, persist, or
replace it. Safe info includes the stable session ID, `log-analysis-v1` profile
ID, profile digest, and `log` namespace. No route in this increment accepts a
profile ID or logical resource selector. When no REPL adapter was configured,
all five routes return fixed `404` JSON without starting any owner.

Serve every entry-document and SPA-fallback HTML response dynamically with
`Cache-Control: no-store` and no reusable ETag, whether REPL is enabled or
disabled. `Plug.Static` must never serve `index.html`; it serves only the
cacheable JS/CSS assets. This prevents a cached Runs-only entry document from
masking a later REPL-enabled Viewer on the same origin.

When REPL is enabled, the same-origin HTML response contains only
`repl_enabled` and a random `page_bootstrap_nonce` in one fixed
CSP-compatible, header-safe meta/config field. The browser sends it as
`X-PTC-Viewer-Page-Nonce` on every `GET /api/repl`; it is never placed in a URL,
Logger metadata, Telemetry, crash output, or reusable static asset. Validate the
actual loopback Host/port on all five REPL routes. Bootstrap additionally
requires exactly one valid page nonce and `Sec-Fetch-Site: same-origin`; reject
missing, cross-site, or invalid values with fixed `403 forbidden_request`
before lazy start. The custom request header also forces a cross-origin script
through preflight, for which no permissive CORS response is installed. These
checks prevent hostile navigation, cross-site fetch, and DNS-rebinding Host
names from reading bootstrap data or starting a session. Disabled-mode HTML
contains only `repl_enabled = false` and no nonce. Static JS/CSS assets remain
cacheable because they contain no per-server configuration.

The first bootstrap is the sole exception to immediate cached GET: the request
that atomically moves `:never_started` to `:starting` owns the monitored
start/reconciliation operation and waits through the store watchdog and any
required reconciliation for its bounded result; the HTTP/request call adds no
shorter default timeout. Client disconnect does not cancel it. Concurrent bootstrap
requests while `:starting` or `:reconciling_start` return exact
`409 operation_active` and are never queued. Once the session is installed,
later GETs use the nonblocking cached-info behavior above.

Every successful bootstrap and mutation response carries the dedicated
generation header `X-PTC-Viewer-Session: <session_id>`. Evaluation, template,
Reset, and Close require the exact unquoted value in the same request header
from the last bootstrap or successful mutation. This header is an application
precondition, not an HTTP cache validator: `GET /api/repl` remains
`Cache-Control: no-store`, and its changing transcript, countdown, usage, and
lifecycle representation does not claim a stable ETag. Missing or malformed
preconditions return `428`; a superseded session returns `412`. `ReplStore`
performs the comparison atomically with its lifecycle transition, not as a
router read followed by a store mutation. A successful Reset returns the
replacement session's new generation header; Close and terminal transitions
retain the closed session's generation.

The JSON body of every successful bootstrap and mutation includes the same
`session_id`, `server_instance_id`, positive `generation_sequence`, and
non-negative `projection_revision`. These are response ordering fields, not
authority; only the request header participates in the atomic store
precondition.

Header parsing requires exactly one `X-PTC-Viewer-Session` value matching the
fixed 43-character base64url grammar. Reject duplicate values, comma-joined
values, padding, control characters or whitespace remaining in the parsed field
value, and any other length or alphabet as a malformed precondition before
entering the store. HTTP optional whitespace discarded by the server parser is
not part of the field value. Validate the
store-generated value again before placing it in a response header so an
internal contract violation becomes a fixed adapter failure rather than a Plug
header exception.

Evaluation accepts exactly:

```json
{"source":"(log/counters {})"}
```

Template formatting accepts exactly one of:

```json
{"kind":"run","run_id":"selected-run"}
{"kind":"turns","run_id":"selected-run"}
```

This is the sole exception to REPL bodies rejecting a run selector. It returns
inert editor source formatted by the root adapter's canonical PTC-Lisp formatter;
it does not select the snapshot, query a run, or mutate evaluator state.

Reset accepts exactly `{}`. Close accepts no body.

Mutation security:

- require `application/json` for POST routes;
- reject unknown or missing body keys;
- install a small Plug body limit before JSON decoding and retain the Kernel
  subordinate-source limit as authoritative;
- require `X-PTC-Viewer-Nonce` equal to the random per-server nonce returned by
  the same-origin bootstrap;
- require the current `X-PTC-Viewer-Session` generation precondition on every
  POST and DELETE route and validate it atomically in `ReplStore`;
- never place the nonce in a URL or log metadata;
- require an `Origin` whose scheme, loopback host, and actual bound port match
  the validated `Host` header;
- validate the loopback Host and actual bound port before every REPL route,
  including bootstrap GET, and apply the page-nonce/Fetch-Metadata bootstrap
  checks before any lazy-start side effect;
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
| wrong method on one of the four known REPL paths | `405` |
| invalid JSON, content type, or body shape | `400` / `415` |
| invalid nonce, Host, or Origin | `403` |
| evaluation/template/reset/close already active; evaluate/template after terminal or explicit close | `409` |
| trace source changed during bootstrap/reset capture | `409` |
| session generation changed | `412` |
| request body, PTC-Lisp source, or trace capture too large | `413` |
| malformed/unsupported trace capture during bootstrap/reset | `422` |
| missing/malformed session precondition | `428` |
| trace source unavailable | `503` |
| bounded adapter or persistence failure | `500` |

The `backend_failed` mapping follows the recovery state machine below: a
no-handle bootstrap and Evaluate/Template/Reset with an installed failed handle
return `500 adapter_failure`; installed-handle bootstrap remains `200`; Close
is accepted, or returns `409 operation_active` while reconciliation of that same
close is already active. No route maps ambiguity to a successful close.
A definitive cleaned `:not_started` bootstrap instead returns `500
repl_start_failed`, which tells the browser a fresh user-initiated bootstrap is
safe. The two no-handle recovery paths are never represented by the same code.

Do not put adapter values, paths, source, exceptions, or stack traces in error
bodies. Keep bounded stable reason atoms internally and return fixed public
messages.

Every REPL-route error response is strict fixed JSON with shape
`{"error":{"code": code, "message": message}}`. Centralize this closed REPL
catalog in one Viewer module and use it from every branch of the five REPL
routes. Existing read-only trace, inspection, and API-fallback error bodies do
not migrate in this increment:

| HTTP | Code | Exact message |
| --- | --- | --- |
| `400` | `invalid_json` | `Request body must be valid JSON.` |
| `400` | `invalid_request` | `Request body does not match this operation.` |
| `400` | `delete_body_not_allowed` | `Close does not accept a request body.` |
| `403` | `forbidden_request` | `Viewer request security context is invalid.` |
| `404` | `repl_not_configured` | `REPL is not configured.` |
| `405` | `method_not_allowed` | `Method is not allowed for this REPL endpoint.` |
| `409` | `operation_active` | `Another operation is active.` |
| `409` | `session_terminal` | `The session is terminal; close or reset it.` |
| `409` | `session_closed` | `The session is closed; reset it to continue.` |
| `409` | `trace_changed` | `The trace source changed during capture.` |
| `412` | `session_changed` | `The session changed; refresh before retrying.` |
| `413` | `body_too_large` | `Request body is too large.` |
| `413` | `source_too_large` | `PTC-Lisp source is too large.` |
| `413` | `trace_source_too_large` | `The trace source is too large.` |
| `415` | `unsupported_media_type` | `Content-Type must be application/json.` |
| `422` | `unsupported_trace` | `The trace source is malformed or unsupported.` |
| `428` | `session_precondition_required` | `A current session precondition is required.` |
| `500` | `adapter_failure` | `The REPL backend failed.` |
| `500` | `repl_start_failed` | `The REPL session could not be started; retry.` |
| `500` | `persistence_failed` | `The session trace could not be persisted.` |
| `503` | `trace_unavailable` | `The trace source is unavailable.` |

No REPL endpoint invents another public code or message in this increment.
Internal reason atoms may be more specific but remain server-side. The browser
branches on code plus refreshed bootstrap state; it does not infer the cause
from status or message text.

Every definitive bootstrap/capture error has an explicit non-polling browser
state. With no installed handle, `trace_changed`, `trace_source_too_large`,
`unsupported_trace`, and `trace_unavailable` preserve the local draft and any
pending selected-run template action, stop the one-second refresh loop, render
the catalog message, and expose `Retry capture`. `repl_start_failed` does the
same but labels the action `Retry session start`. A retry is always an explicit
user action and creates exactly one newly prepared start ID; no error timer or
generic `409` handler retries it. `adapter_failure` remains the distinct
non-retryable no-handle state that requires Viewer restart.

When the same four capture errors occur after Reset has successfully persisted
the predecessor, the store retains that closed session's provenance,
transcript, and generation. The UI renders the exact capture error and offers
`Retry reset`; it does not clear the transcript, poll for a replacement, submit
a pending template, or imply that a new session exists. Explicit retry starts
capture again only after the predecessor remains definitively closed. A
successful retry installs the replacement and only then may one still-current
pending template action continue once.

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
independently. Project only a fixed `repl_enabled` boolean and random
`page_bootstrap_nonce` into the initial CSP-compatible page response; do not
expose the adapter feature descriptor or backend context. A standalone Viewer without a configured REPL
adapter renders the existing Runs-only interface and makes no REPL bootstrap
request. The enabled page receives only `repl_enabled` and the header-safe page
bootstrap nonce needed for its guarded same-origin GET; backend features,
authority, and the later mutation nonce remain absent.

### Concrete interaction model

Keep the existing compact dark visual language and use progressive disclosure
rather than presenting all profile and budget metadata at equal weight:

1. The header contains `Runs` and `REPL` tabs. Switching tabs preserves the
   selected run, the unsent editor draft, and the REPL scroll position within
   that browser tab. An unsent draft is browser-local, is never sent before
   Evaluate, and is not persisted across a page reload.
2. The top of REPL shows one compact session strip: state, snapshot capture
   time, visible run count, and remaining evaluations/time. Profile ID, digest,
   source bytes, continuation bytes, and per-capability usage are available in
   an expandable `Session details` panel.
3. On a wide viewport, the editor and an `Examples & help` panel share the
   workspace row; on a narrow viewport they stack with the editor first. The
   editor is never reduced below a usable multiline height.
4. Evaluate is the primary action. Reset/Refresh and Close are visually
   secondary and are separated from Evaluate. Inline text explains that Reset
   first persists the current analysis trace, then captures and installs a new
   session; only successful installation clears the old presentation transcript
   and replaces its definitions with a fresh continuation. A capture/start
   failure retains the old transcript and closed-session provenance. Require
   confirmation before Reset. Close persists and ends evaluation but retains
   the transcript for reading. Neither action is presented as rollback.
5. The first empty state explains, in one paragraph, that this is PTC-Lisp over
   a frozen trace snapshot and offers four one-click examples. Selecting an
   example inserts editable source but never executes it automatically.
6. Accepted evaluations append transcript cards in execution order. Keep the
   latest card visible without forcibly stealing scroll position when the user
   is reading an older card; offer a `Jump to latest` control when needed.
7. Each card shows source preview, outcome badge, duration, evaluation ID, and
   the most relevant budget delta or remaining count in its collapsed header.
   Its expanded body separates formatted value, JSON value when available,
   prints, error/continuation explanation, truncation markers, and the complete
   bounded usage snapshot. Gate source and result actions independently. Show
   `Copy source` and `Edit and rerun` only when the complete source is retained;
   a truncated source instead offers `Copy source preview`, includes the visible
   source-truncation marker in the copied text, and cannot rerun. Show `Copy
   result` only when the complete rendered result is retained; a truncated
   result instead offers `Copy result preview` with its own visible marker.
8. Explain continuation consequences in plain language beside each relevant
   outcome using the response's closed `continuation_effect`, never by deriving
   it from status. `committed_with_history` means candidate definitions were
   committed and `*1/*2/*3` advanced; `committed_without_history` means candidate
   definitions were committed without advancing history; `preserved` means all
   previously committed definitions and history remain and candidate changes
   from that evaluation were discarded. This remains accurate when a later
   public-result limit exposes an error after continuation already committed.
9. A selected run in Runs exposes `Analyze in REPL`. It switches tabs and
   inserts a `log/run` template, with an adjacent choice for `log/turns`; it
   never evaluates or changes authority automatically. Capture the decoded run
   ID, template kind, action ID, and current draft revision before switching.
   If the REPL has not bootstrapped, start or join the browser tab's one in-flight
   bootstrap request and do not send the template POST yet. Only a successful
   bootstrap may supply the exact mutation nonce and session generation used by
   the subsequent template request. `repl_start_failed` and the four definitive
   trace-capture codes preserve the pending action and present the exact retry
   control defined above; `adapter_failure` preserves it but presents only the
   Viewer-restart recovery. None polls or submits a template automatically. An
   explicit successful retry performs a fresh bootstrap, then sends the one
   still-current pending template action once.
   Request the inert source through typed `template/4`; the root adapter uses
   `PtcRunner.Lisp.Formatter.format/1`. Do not encode or interpolate run IDs in
   JavaScript. Keep HTML text rendering as a separate later step. Treat returned
   template source as an operation payload, not cached server state: state-
   envelope ordering may discard an older projection without discarding the
   source. Insert automatically only when the response still matches the
   captured session generation, template action ID, and browser-local draft
   revision. If the user edited the draft while formatting was pending, retain
   the source in a visible `Template ready` action and require explicit Insert
   or Replace; never overwrite the newer draft or silently lose the result.
   Refactor the existing Runs picker at the same time: never serialize a run ID
   through `data-run-id`, `innerHTML`, or `dataset`. Build interactive rows with
   DOM APIs/text nodes and capture the decoded JSON run ID in the event-listener
   closure, or use an opaque numeric index into the in-memory response. The
   exact selected string must reach the typed template request without HTML
   parser normalization.
10. Multiple browser tabs share the server transcript and busy/terminal state,
    but each keeps its own unsent editor draft. Every immediate action captures
    and sends the session generation rendered when that action begins. Reset
    confirmation additionally captures its generation when the dialog opens and
    retains that value even if polling renders a replacement session before the
    user confirms; Confirm therefore receives `412` instead of resetting the
    replacement. On `409 operation_active`, refresh session state and render the
    active lifecycle conflict; `409 trace_changed` instead enters its explicit
    stopped retry state above. On the other lifecycle conflict codes, render the
    authoritative returned state without replay. On `412`, preserve the unsent draft, refresh bootstrap
    state, and require an explicit retry against the replacement session. Never
    automatically replay a stale mutation or invent user identity in this
    local-only increment. While the REPL tab and document are visible, run at
    most one bounded `GET /api/repl` refresh every second; pause when hidden and
    refresh immediately on tab activation, `visibilitychange`, mutation
    completion, `409`, or `412`. The server response and
    `X-PTC-Viewer-Session` generation are authoritative; browser broadcasts or
    local storage are not.

Desktop hierarchy:

```text
PTC Kernel Viewer                      [Runs] [REPL]
---------------------------------------------------------------
Open | snapshot 12:41 | 18 runs | 61 evals left | 28:14 left
[Session details ▸]

┌─ PTC-Lisp editor ───────────────────┐ ┌─ Examples & help ───┐
│ (log/counters {})                   │ │ Runs   Run          │
│                                     │ │ Turns  Counters     │
└─────────────────────────────────────┘ └─────────────────────┘
[Evaluate]                              [Reset/Refresh] [Close]
Reset persists, installs a new session, then clears definitions/transcript.

Transcript                                      [Jump to latest]
┌─ continued · 42 ms · 61 evals left ─────────────────────────┐
│ Source · Value · Prints · Usage                    [Expand] │
└─────────────────────────────────────────────────────────────┘
```

At narrow widths the examples panel moves below the editor, actions wrap without
changing their order, and transcript cards keep source/output horizontally
scrollable rather than shrinking code to unreadable columns.

All state changes use a visible status region with `aria-live`, every control
has a programmatic label and visible keyboard focus, tabs implement normal tab
keyboard semantics, and outcome meaning never relies on color alone. Implement
Cmd/Ctrl+Enter submission while keeping Evaluate reachable without a keyboard
shortcut.

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

`backend_failed` is a fail-closed recovery state, not another spelling of
terminal evaluation:

- If start failed ambiguously before an opaque session handle was installed,
  bootstrap returns fixed `500 adapter_failure` with no session header. No
  browser mutation is available; the REPL panel shows a bounded “restart the
  Viewer” recovery notice and preserves any browser-local draft. The connected
  backend tree remains responsible for cleanup when the fail-closed Viewer
  runtime terminates.
- If a handle was already installed, bootstrap remains a successful `200`
  safe-state projection with `state = backend_failed`, the current session
  header, transcript, and a fixed `recovery_action = close`. Evaluate, Template,
  and Reset return fixed `500 adapter_failure` without adapter delegation.
  Close is the only accepted browser mutation.
- When no close operation exists, Close creates one idempotent close ID; Core
  waits for any accepted evaluation before persisting. When a close operation
  is already ambiguous, Close reconciles that same ID and never creates a new
  one. If the bounded background reconciliation task is currently active, the
  request returns `409 operation_active` rather than queueing another task.
- A recovered evaluation result is still installed and acknowledged exactly
  once without leaving `backend_failed`. A recovered close result transitions
  to `:closed` or `:persistence_failed`; the latter exposes the normal `Retry
  persistence` Close action. Reset becomes available only after a definitive
  closed/persistence-retry outcome has eliminated every ambiguous predecessor
  operation.
- If Close cannot be reconciled, the store remains `backend_failed`, continues
  its one-at-a-time bounded reconciliation, and shutdown is the final recovery
  path. It never claims persistence or starts a replacement speculatively.

The UI renders `backend_failed` as a non-color critical status with the precise
allowed action above. It disables the editor submission, selected-run template
actions, and Reset; it disables Close while a close-reconciliation task is
active and labels it `Close and preserve trace` otherwise. A no-handle start
failure shows no inert Close control. Bootstrap polling continues only for an
installed handle so a recovered result/close can converge; no-handle failure
stops polling until the Viewer is restarted.

By contrast, a confirmed-clean start failure returns
`500 repl_start_failed`, leaves the store in `:never_started`, stops automatic
polling, and renders `Retry session start`. Only that explicit action issues a
fresh bootstrap operation ID. This distinction also governs a pending `Analyze
in REPL` handoff, which remains inert until bootstrap succeeds.

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
An unavailable backend keeps the store in `:reconciling_start` only until the
fixed reconciliation watchdog expires, then moves it to `:backend_failed`. It
must not guess that no session exists or start again with a fresh operation ID.

## Likely Files

Core additions/refactors:

- `lib/ptc_runner/kernel/log_analysis_profile.ex`
- `lib/ptc_runner/kernel/log_analysis_assembly.ex`
- `lib/ptc_runner/kernel/log_analysis_session.ex`
- `lib/ptc_runner/kernel/log_analysis_session_builder.ex`
- `lib/ptc_runner/kernel/session_trace.ex`
- `lib/ptc_runner/kernel/event_sink.ex`
- `lib/ptc_runner/kernel/event_sink_state.ex`
- `lib/ptc_runner/kernel/trace_snapshot.ex`
- `lib/ptc_runner/kernel/trace_log.ex`
- `lib/ptc_runner/kernel/trace_capability.ex`
- `lib/ptc_runner/kernel/evaluation.ex`
- `lib/ptc_runner/kernel/run_state.ex`
- `lib/ptc_runner/kernel/run_config.ex`
- `lib/ptc_runner/kernel/runtime_tools.ex`
- `lib/ptc_runner/kernel/viewer_repl_adapter.ex`
- `lib/ptc_runner/kernel/safe_metadata.ex` only if a new finite UI-visible tag
  is justified; `mode = repl` requires no change
- Kernel public/module docs and `docs/guides/kernel-maintainer.md`

`RunState` changes to co-host session event state because focused ownership and
race review required recorder readiness and continuation commit to occur in one
atomic owner callback. No production change is expected in `repl_session.ex`
or `mix ptc.repl` unless a focused regression exposes another shared-boundary
defect.

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
5. Ordinary success advances `*1/*2/*3`; return does not; fail/error preserve
   prior committed continuation and discard only candidate changes.
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
   projections respect their independent limits and expose truncation,
   including more than 128 zero-length prints without unbounded cardinality.
13. A public result-limit failure retains the shared evaluation boundary's
    closed `continuation_effect`, including committed-with-history and
    committed-without-history cases, rather than being misreported as preserved.
    Ordinary and explicit-return commit rejection for memory, history, and
    run-closed/deadline limits instead reports `:preserved` and retains the prior
    continuation.
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
23. Public trace-call accounting contains exactly the four granted trace names,
    uses authoritative `RunState` aggregate/per-name counts and fixed limits,
    reports effective remaining as the lower remaining quota, increments across
    forms, and agrees across evaluation results and session info. Aggregate
    exhaustion makes every trace capability report zero remaining.

### Viewer store and API tests

1. Viewer startup without a REPL adapter preserves Runs and inspection behavior,
   starts no `ReplStore`, projects `repl_enabled = false`, and returns fixed
   `404` JSON from REPL routes.
2. Viewer startup rejects a supplied invalid adapter/backend context without
   eagerly constructing a session or silently downgrading to Runs-only mode.
3. Adapter connection advertises only a bounded JSON-compatible
   `log-analysis-v1` feature descriptor; backend configuration remains private.
4. The store starts the server-selected profile. Evaluation and lifecycle
   bodies reject profile/resource fields; only the typed inert-template route
   accepts one bounded run ID and fixed template kind.
5. Start operation IDs are idempotent; a task exit before handle delivery is
   reconciled to exactly one committed session or a proven no-session result.
   The initiating first bootstrap waits for that result even after client
   disconnect; concurrent bootstrap during `:starting` or `:reconciling_start`
   receives exact `409 operation_active` and is never queued.
   Production start/reconciliation deadlines return before the store watchdog.
   Never-returning test callbacks trigger reconciliation then bounded
   `:backend_failed`/`adapter_failure`, occupy no task slot forever, start no new
   operation ID, and are terminated with the Viewer-owned task/backend tree.
   A delayed start worker racing the watchdog cannot commit after atomic
   `:sealed_not_started`; hold its cleanup barrier deliberately and prove a
   later bootstrap/Reset cannot start a replacement until the worker is down
   and cleanup is confirmed. The rejected worker cleans its candidate, and a
   later first-bootstrap GET or predecessor-authorized Reset creates at most one
   live session. First-bootstrap `:not_started` returns to `:never_started` without
   requiring a nonexistent session header; Reset retains the closed predecessor
   generation. Every definitive terminal start result is acknowledged after its
   wrapper exits and before another start is accepted; repeated failed
   bootstrap/Reset attempts keep both store and backend ledgers bounded. A
   definitive cleaned failure returns `repl_start_failed` and permits explicit
   retry; ambiguous no-handle failure returns `adapter_failure` and never
   accepts a fresh start under that Viewer runtime.
6. First bootstrap surfaces bounded snapshot/session initialization failures.
   Concurrent source change returns exact `409 trace_changed`; encoded or
   retained trace capture overflow returns exact `413 trace_source_too_large`.
7. Public session info carries a stable 43-character unpadded base64url session
   ID, profile ID, and digest but no opaque local session reference. Session IDs
   and mutation nonces are store-generated with 32 bytes of entropy; invalid
   adapter-supplied identity fields cannot replace them.
8. Opaque adapter/session values never appear in Plug config responses,
   Logger, Telemetry, or OTP status.
9. Evaluation accepts only exact JSON and delegates once.
10. A second evaluation/template/reset/close during active evaluation or
    template work returns `409` and is never executed later. Template work uses
    the explicit `:templating` monitored-task transition and its bounded timeout.
    Evaluation operation IDs and reconciliation ensure request death or the long
    whole-callback watchdog cannot rerun or lose the eventual authoritative
    result/transcript entry. A never-returning evaluation adapter reaches bounded
    `:backend_failed`, clears the mutation slot, accepts no new work, and is
    terminated with the backend tree. If evaluation commits and both its initial
    callback and first reconciliation hang, bounded background reconciliation
    eventually installs and acknowledges the one result without accepting
    another evaluation. The pending record supplies exact bounded source
    byte/preview metadata. Reordering recovery against Close appends once while
    preserving the newer closing/closed lifecycle; Reset remains unavailable
    until the predecessor result is acknowledged. Deliberately hold the initial
    evaluation callback behind reconciliation: pre-registration is already
    visible, reconciliation seals it as `:sealed_not_accepted`, the late callback
    never runs Core, the cleanup barrier completes before acknowledgement, and a
    fresh explicit evaluation is accepted only afterward.
11. An accepted evaluation completes after HTTP client disconnect.
12. Body/source limits reject work before evaluation.
13. Missing/wrong nonce and invalid Host/Origin fail before delegation for
    POST and DELETE; DELETE rejects a request body but does not require a JSON
    content type. Session precondition parsing rejects missing, duplicate,
    comma-joined, parsed-whitespace-containing, padded, control-character,
    wrong-alphabet, and wrong-length values without calling the store; response
    header generation rejects any impossible unsafe internal value without
    raising. Tests account for normal HTTP optional-whitespace normalization.
    Every REPL route rejects a hostile/non-loopback Host. Bootstrap GET also
    rejects missing/wrong page nonce and missing/cross-site Fetch Metadata before
    start; a cross-origin preflight receives exact `405 method_not_allowed` on
    each known REPL path, no permissive CORS headers, and no delegation. Cover
    every other wrong-method/known-path pair with the same path-aware JSON
    fallback while unknown `/api/*` paths retain their existing behavior.
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
    Never-returning and commit-then-hang close callbacks reconcile by one close
    operation ID; ambiguous timeout enters `:backend_failed`, bounded background
    reconciliation eventually installs the result, and Reset never advances
    during ambiguity. Also reorder an initial close behind reconciliation and
    prove `:sealed_not_accepted` performs no terminal event/publication, restores
    the predecessor lifecycle only after cleanup and acknowledgement, and allows
    only an explicit later retry.
    Cover `:backend_failed` separately with and without an installed handle:
    no-handle bootstrap returns fixed `500` and offers only Viewer restart;
    installed-handle bootstrap returns `200`, Evaluate/Template/Reset return
    fixed `500`, and Close either starts once, reconciles its existing ID, or
    returns `409` while that reconciliation task is active. Recovered evaluation
    and close results install once and enable only the documented next action.
21. Normal Viewer termination stops new traffic but keeps the store, callback
    supervisor, and backend alive long enough to drain/reconcile an accepted
    evaluation, install and acknowledge its result, and close/persist exactly
    once. A barrier-based `PtcViewer.stop/1` test holds an active evaluation and
    proves persistence contains its result before backend termination; bounded
    shutdown expiry falls back to abort without claiming success.
    Killing only `ReplStore` makes the fail-closed lifecycle owner terminate
    Bandit, callback tasks, and the connected backend tree; the port stops
    accepting traffic, the committed session is cleaned, and no replacement
    store or second session is started.
22. Transcript projection handles one maximum source/result with hostile JSON
    escaping inside its per-entry ceiling, preserves a metadata-only newest
    entry when needed, retains `continuation_effect`, and enforces aggregate
    eviction and omitted count.
23. Existing read-only trace and inspection routes remain unchanged except for
    shared security/no-store headers where deliberately adopted.
24. Strict result, bootstrap, transcript, and session-info projections carry
    identical closed per-name accounting for exactly the four trace
    capabilities and cannot expose implicit or unexpected mission-call names.
25. Every `409` returns exactly one stable conflict code; UI handling
    distinguishes active work, terminal session, and explicitly closed session.
26. Every mutation validates `X-PTC-Viewer-Session` atomically with the store
    transition. Missing preconditions return `428`;
    evaluate/template/reset/close against a superseded session return `412` and
    never touch the replacement session. Bootstrap responses remain
    `Cache-Control: no-store` and do not expose an ETag that conflates session
    generation with representation revision.
    All enabled- and disabled-mode entry HTML and SPA fallbacks are dynamic,
    `Cache-Control: no-store`, and not served by the public `Plug.Static`
    `index.html` path. Restarting the same origin from Runs-only to enabled
    cannot reuse a cached disabled document; only JS/CSS remain cacheable.
27. Every REPL-route error path uses the centralized closed code/message
    catalog; tests assert exact JSON for each table entry and reject
    uncatalogued REPL codes. Existing read-only API errors remain unchanged.
28. Template formatting delegates once to the typed adapter and returns bounded
    inert source. Root integration proves adversarial valid UTF-8 run IDs are
    rendered through `PtcRunner.Lisp.Formatter.format/1` as one string value and
    no JavaScript literal encoder exists. Parse and execute both exact generated
    forms against a fixture snapshot, including the required empty options map
    in `(log/turns "<run-id>" {})`.
29. Bootstrap returns cached state immediately during active evaluation. A
    background `info/1` result is installed only for its captured session and
    state revision. Deliberately reorder info, evaluation, Reset, and bootstrap
    responses to prove stale results are discarded and mutation calls still
    receive immediate lifecycle decisions. Multiple read-only polls do not
    increment `state_revision` or invalidate one slow info refresh; each listed
    semantic transition does increment it. A never-returning info callback times
    out, clears the refresh slot, and allows a later refresh to converge.
30. Repeated successful evaluation/close/reset cycles acknowledge and prune
    backend operation records. Backend ledger size remains bounded independent
    of server-lifetime Reset count; unacknowledged records are cleaned with the
    Viewer backend tree. Never-returning/crashing acknowledgement uses one
    watchdog-bounded retry, never blocks the store, marks the backend failed
    against new operations, and leaves only bounded records for shutdown cleanup.
    A returned `:ok` is observed only after backend-owner deletion; hold that
    deletion barrier to prove the store neither forgets the record nor accepts
    a dependent next operation early.
    Preparation is idempotent and precedes every initial callback. A preparation
    timeout retries only the same typed ID; repeated ambiguity enters
    `:backend_failed`, launches no initial work, and leaves only one bounded
    reservation for backend-tree cleanup.
31. Instrument the task supervisor to prove the closed concurrency ceiling:
    one foreground callback, at most one info task, one evaluation
    reconciliation, one close reconciliation, and one acknowledgement. Repeated
    timer messages cannot duplicate a slot; successful recovery, replacement,
    store death, and shutdown cancel stale timers/tasks and stale results cannot
    install into another session.

### Browser/render tests

1. Runs-only mode omits the REPL tab and makes no REPL bootstrap request; the
   enabled mode projects only the fixed feature boolean plus header-safe page
   bootstrap nonce and renders both tabs.
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
12. Example and selected-run templates never alter authority. Selected run IDs
    are sent as data to the typed template route and canonical root formatter,
    with cases for quotes, backslashes, NUL, newline, tab, carriage return,
    Unicode, and text containing closing delimiters/additional forms; inserting
    returned source never executes it. Exercise the actual Runs-picker click to
    template request and prove the decoded JSON ID is captured by closure/index,
    never normalized through an HTML attribute or dataset.
    On a fresh page, `Analyze in REPL` captures the action, waits for the single
    lazy bootstrap, then sends exactly one template request with the returned
    nonce/generation. It never races a `428`. Definitive start or capture failure
    preserves the inert action behind its documented explicit retry; ambiguous
    backend failure preserves it behind Viewer-restart guidance, and none
    automatically submits the template.
    Reordered poll/template responses still deliver the operation source. An
    edit while formatting is pending preserves the newer draft and exposes an
    explicit `Template ready` Insert/Replace action instead of silently
    discarding or overwriting text.
13. The empty state and example palette insert source without issuing an
    evaluation request.
14. Reset states exactly what will be cleared; Cancel performs no mutation and
    Confirm delegates exactly once.
15. Transcript cards expose source, outcome, duration, prints, value/error,
    aggregate/per-trace-capability usage, truncation, and continuation meaning
    from the explicit `continuation_effect`, with escaped, copyable text. A
    result-limit error after commit renders the committed effect rather than
    inferring preservation from error status.
16. `Copy source` and `Edit and rerun` are available only for complete source
    and never submit automatically. A truncated source exposes `Copy source
    preview` including its marker and cannot rerun. Independently, a complete
    result exposes `Copy result` while a truncated result exposes `Copy result
    preview` including its result marker. Cover complete-source/truncated-result
    and truncated-source/complete-result combinations.
17. Tab switching preserves the local unsent draft; reload restores server
    transcript but not an unsent draft; separate tabs keep separate drafts.
18. Tabs, editor, disclosures, confirmation, transcript cards, and status
    updates are keyboard operable with visible focus, correct accessible names,
    an `aria-live` status region, and non-color outcome labels.
19. A stale-tab `412` preserves its draft, refreshes session/transcript state,
    and never automatically replays Evaluate, Reset, Close, or template insertion
    against the replacement session. A Reset dialog captures its generation on
    open; a poll that observes a replacement before Confirm does not retarget the
    dialog, and Confirm sends the captured generation and receives `412`.
20. Visible-tab refresh has at most one request in flight, stops when the REPL
    or document is hidden, resumes immediately on activation, and converges
    transcript, session generation, busy, terminal, and closed state without
    persisting drafts.
21. Delayed poll responses cannot overwrite a newer evaluation or Reset
    response. The browser compares every response's
    `{generation_sequence, projection_revision}` with no Reset exception. Cover
    two reordered Reset responses where delayed S1 -> S2 arrives only after the
    browser has rendered S3, plus lower-revision same-generation polls.
22. Restarting the Viewer makes the old page nonce fail closed. The first
    same-origin bootstrap/poll `403` sets the one-attempt `sessionStorage`
    marker and performs one hard reload; fresh nonce-bearing HTML then accepts
    the new `server_instance_id` and session, clears the marker, retires the old
    instance, and rejects delayed responses from the old server process. A
    second `403` stops instead of reload-looping and presents an explicit Reload
    action. The restart reload's loss of an unsent draft is visible and
    consistent with the ordinary reload contract.
23. `backend_failed` with an installed handle renders the critical status,
    preserves transcript/draft, disables Evaluate/templates/Reset, and exposes
    only `Close and preserve trace` when no close reconciliation is active.
    No-handle start failure renders only the restart guidance and stops polling;
    neither state exposes a misleading recoverable control.
24. Confirmed-clean `repl_start_failed` instead renders `Retry session start`,
    performs no timer-driven retry, and starts exactly one new bootstrap only
    after activation. Its presentation is not conflated with no-handle
    `adapter_failure`.
25. No-handle `trace_changed`, `trace_source_too_large`, `unsupported_trace`,
    and `trace_unavailable` each render their exact message, preserve draft and
    pending Analyze action, stop polling, and issue no request until explicit
    `Retry capture`. The corresponding post-persistence Reset failures retain
    the closed predecessor transcript/generation and expose `Retry reset`.
    Success continues one still-current pending template once; repeated failure
    never creates a polling or retry loop. Generic `409` handling cannot swallow
    the `trace_changed` branch.

### Codex-controlled real Chrome acceptance

Automated router, store, and render tests are necessary but do not replace one
real-browser acceptance pass. After Slice 4 is implemented, launch the actual
local Bandit Viewer over a credential-free trace fixture and use Codex's Chrome
browser-control integration against real Google Chrome. Do not substitute a DOM
emulator or an HTTP-only script for this gate.

Exercise and record this journey:

1. Launch once without a REPL adapter and confirm the existing Runs-only UI has
   no REPL tab, makes no `/api/repl` request, serves dynamic `no-store` entry
   HTML, and has no console or CSP errors.
2. Launch through root `mix ptc.viewer` with the local adapter, navigate in
   Chrome, and confirm the REPL tab is visible while the Runs experience still
   works. Reuse the first launch's exact origin and confirm Chrome does not reuse
   the cached Runs-only document; the fresh dynamic HTML advertises the enabled
   UI and supplies its page nonce.
3. Inspect the initial layout at a normal desktop viewport and a narrow mobile-
   width viewport. Capture review screenshots of the empty state, one result
   card, and the narrow layout.
4. Use mouse and keyboard separately: switch tabs, select an example, edit a
   multiline form, submit with Cmd/Ctrl+Enter, expand/collapse details, copy
   source/result, and traverse every action with visible focus.
5. Evaluate the four `log.core` examples, then define and reuse a helper and
   `*1`, produce prints, trigger a recoverable error, and verify the rendered
   continuation explanation and budget changes match the returned response.
6. Reload and confirm the bounded server transcript and session provenance
   return while an unsent local draft does not. Open a second Chrome tab and
   confirm both observe the shared transcript and busy/terminal state without
   sharing unsent drafts. Open Reset confirmation in one tab, complete Reset in
   the other, wait for the first tab's polling refresh to render the replacement,
   then confirm the stale dialog still sends its captured old generation,
   returns `412`, preserves its draft, refreshes to the replacement session, and
   performs no second Reset.
7. From Runs, select real and adversarially encoded run IDs and use
   `Analyze in REPL`; verify the server-formatted PTC-Lisp source contains one
   inert run-ID string, does not execute, and can be edited before submission.
8. Start Reset, verify Cancel changes nothing, then confirm Reset. Verify the
   old analysis run appears in Runs, the new transcript is empty, and the new
   snapshot can query the predecessor.
9. With the REPL page still open, restart the local Viewer. Verify the old page
   nonce receives one fixed `403`, exactly one automatic hard reload obtains
   fresh nonce-bearing no-store HTML, the new session converges, and the browser
   neither enters a reload loop nor accepts a delayed old-instance response.
10. Close the session and verify Evaluate stays disabled, transcript reading and
   Reset remain understandable, and reload does not silently create a session.
11. Inspect Chrome console and network activity throughout for uncaught errors,
    failed requests, duplicate evaluation submissions, leaked source/nonce in
    URLs, unexpected caching, mixed content, or CSP violations.

Use a deliberately slow bounded evaluation during the two-tab step to observe
the busy state and `409` recovery in the actual UI. Persistence fault injection,
deadline expiry, event saturation, and protocol exhaustion remain deterministic
automated integration tests; use real Chrome for them only when a stable
test-only adapter can expose the state without weakening production routes.
Summarize the Chrome version, viewport sizes, journey results, console/network
findings, and screenshot locations in the implementation handoff or review.

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
  typed operation pre-registration, sealed start/evaluation/close
  reconciliation, bounded feature descriptor, root adapter, redacted fail-fast
  store, per-entry transcript projection, and lifecycle attachment.
- Preserve Runs-only startup when the REPL adapter is absent; fail startup when
  an explicitly configured adapter or backend is invalid.
- Add terminal, automatic-expiry convergence, and idempotent persistence-retry
  transitions without implicit session recreation.
- Add secured bounded routes and exact status mapping.
- Separate orderly Viewer shutdown/drain from unexpected store-death cleanup,
  with barrier-based accepted-evaluation persistence coverage.
- Wire the root Mix task and verify startup/teardown failures.

Exit gate: one local browser client can safely execute bounded log-analysis
programs without `ptc_viewer` depending directly on `ptc_runner`.

### Slice 4: REPL UI and journey

- Add tabs, editor, transcript, examples, selected-run templates, budgets,
  result states, close, and reset.
- Complete render/browser tests, accessibility checks, the credential-free
  journey, and the Codex-controlled real Chrome acceptance pass.
- Update Viewer README and relevant Kernel guides.

Exit gate: the human workflow is complete, keyboard-usable, responsive,
reload-safe, verified in real Chrome, and the persisted analysis run renders
and is queryable through the normal Viewer path.

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
- Every browser mutation is atomically preconditioned on the rendered session
  generation; a stale tab cannot evaluate, close, reset, or format a template
  against a replacement session and no stale operation is replayed implicitly.
- Terminal Kernel budgets retain the final result, reject later Evaluate, and
  preserve Close/Reset; idle deadline expiry automatically closes and persists
  without relying on a browser request.
- Start, evaluation, and close IDs are prepared before execution; reconciliation
  can seal not-yet-accepted work, and no late callback can create work after its
  cleanup barrier and acknowledgement. Start/reset failure cannot lose a
  committed handle or create a second live session.
- Event saturation retains bounded loss evidence and exactly one terminal
  event; retryable persistence publishes either one complete trace or none.
- Every REPL HTTP response is strict JSON, bounded, escaped in the UI, and free
  of native terms, paths, callbacks, source leaks, and stack traces.
- REPL-route public errors come only from one closed exact code/message catalog,
  and selected-run templates use the root canonical PTC-Lisp formatter rather
  than a browser-side escaping implementation.
- Normal close/reset and orderly Viewer shutdown drain accepted work and persist
  exactly one reloadable canonical trace while the backend remains alive;
  unexpected owner failure instead receives fail-closed backend cleanup and a
  best-effort aborted persistence attempt.
- Persistence failure is retryable and never rewrites evaluation outcomes or
  appends duplicate sequences. Repeated Close retries it, and Reset cannot
  construct a replacement until the retry succeeds.
- Reload and multiple tabs show a consistent bounded presentation transcript.
- The interaction hierarchy, empty state, examples, result cards, lifecycle
  explanations, reset confirmation, copy/rerun actions, and selected-run handoff
  are usable with mouse and keyboard at desktop and narrow viewports.
- A Codex-controlled real Chrome pass against the actual local Viewer completes
  without duplicate submissions, console/CSP errors, authority-changing UI
  behavior, or unexpected source/nonce disclosure.
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
