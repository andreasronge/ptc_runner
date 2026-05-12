# PtcRunner MCP Sessions — Draft Specification

| Field | Value |
|---|---|
| Status | Draft |
| Target package | `:ptc_runner_mcp` |
| Depends on | `ptc-runner-mcp-server.md`, `ptc-runner-mcp-aggregator.md`, `agentic-ptc-task-subagent-spec.md` |
| Last revised | 2026-05-12 |

This document specifies an opt-in session layer for PtcRunner MCP. The
goal is to support multi-turn exploration and bounded working memory
without weakening the current stateless `ptc_lisp_execute` contract.
Sections using **MUST** / **SHOULD** / **MAY** carry RFC 2119
normative weight.

## 1. Motivation

Current `ptc_runner_mcp` is intentionally stateless: each
`tools/call` receives a program, context, and optional signature, runs
with fresh PTC-Lisp execution memory, and returns a structured result.
Aggregator connection and catalog caches remain server-owned and are
not user-visible working memory. This is excellent for deterministic
compute and single-shot aggregation, but it is inefficient for
exploratory workflows:

1. The LLM repeatedly rediscovering the same upstream catalog.
2. Large intermediate results flowing back into the model context only
   to be filtered or summarized in a later call.
3. Multi-step investigations losing local facts, open questions, and
   prior upstream-call diagnostics between turns.
4. No first-class way to continue a bounded investigation without
   asking the client model to carry all state in prompt text.

The BEAM is a good fit for this problem: one lightweight supervised
process per exploration session, per-session quotas, TTL, cancellation,
telemetry, and clean crash isolation.

## 2. Product Positioning

The session feature should be positioned as:

> PtcRunner is a BEAM-native stateful MCP/code-mode aggregator:
> deterministic PTC-Lisp execution plus supervised, bounded,
> inspectable per-session exploration state.

This is distinct from generic code-mode tools that provide only
one-shot Python/JavaScript execution or opaque persistent notebooks.
PtcRunner sessions are structured working memory for investigation,
not arbitrary hidden interpreter state.

## 3. Scope and Goals

Goals:

1. Keep `ptc_lisp_execute` stateless and unchanged by default.
2. Add explicit opt-in exploration sessions for multi-turn MCP use.
3. Support the current stdio deployment model first: one MCP client
   normally owns one `ptc_runner_mcp` OS process.
4. Design ownership boundaries so a future HTTP transport with
   multiple concurrent MCP clients can reuse the same session model.
5. Store structured, bounded artifacts: notes, facts, catalog
   snapshots, selected result handles, upstream-call summaries, and
   open questions.
6. Never store credentials or unredacted auth material.
7. Provide operator-visible telemetry and debugging hooks.
8. Preserve deterministic execution: PTC-Lisp programs run in the
   existing sandbox with resource limits; session state is an explicit
   input/output side channel managed by the MCP server.

## 4. Non-Goals

The following are out of scope for the first implementation:

- Durable cross-process memory by default.
- Global memory shared across clients.
- A general Python/JavaScript notebook runtime.
- Automatic authorization of write-capable upstream tools based on
  session memory.
- Replacing `ptc_lisp_execute`.
- HTTP transport implementation itself.
- Vector search or embeddings over session memory.
- Persisting raw upstream payloads without explicit operator opt-in.
- A claim that upstream effects are sandboxed. PtcRunner can mediate,
  log, and cap calls, but upstream MCP servers still own their effects.

## 5. Definitions

| Term | Meaning |
|---|---|
| Transport session | The client/server connection identity. In stdio v1 this is the running `ptc_runner_mcp` process. In future Streamable HTTP this is the MCP `Mcp-Session-Id` plus any authenticated user/client identity. |
| Exploration session | A logical PtcRunner investigation with a `session_id`, owned by one transport session, backed by one supervised BEAM process. |
| Session owner | The identity allowed to read, update, or close an exploration session. In stdio v1, this is the local server instance. |
| Session artifact | A bounded structured value stored in a session: note, fact, open question, catalog snapshot, result summary, result handle, or upstream-call summary. |
| Session projection | The bounded JSON-compatible view of session state injected into a `ptc_session_call` context or returned from `ptc_session_read`. |
| Raw payload | Full upstream result body or full PTC-Lisp result beyond configured preview limits. Raw payload storage is disabled by default. |

## 6. Transport Model

### 6.1 Stdio v1

With stdio, each MCP client typically starts its own server process and
communicates over that process's stdin/stdout. Therefore:

- The implementation **MAY** treat the process as the transport
  session.
- In-memory sessions are naturally isolated per client process.
- Multiple clients can use PtcRunner concurrently by running separate
  OS processes.
- Concurrent requests from the same client remain bounded by
  `max_concurrent_calls`.

This is an acceptable Phase 1 deployment model. It gives strong
default isolation without needing a multi-tenant registry.

### 6.2 Future HTTP

The data model **MUST NOT** assume stdio forever. Every exploration
session **MUST** carry an owner field so HTTP can later bind sessions
to:

```elixir
%{
  transport: :http,
  mcp_session_id: String.t(),
  client_id: String.t() | nil,
  user_id: String.t() | nil
}
```

For stdio v1 the owner can be:

```elixir
%{
  transport: :stdio,
  instance_id: String.t()
}
```

The owner check **MUST** happen before reading, updating, executing
against, or closing a session.

## 7. Tool Surface

The initial session layer SHOULD expose a small explicit tool surface.
Exact names may change during implementation, but the recommended
shape is:

1. `ptc_session_start`
2. `ptc_session_call`
3. `ptc_session_read`
4. `ptc_session_update`
5. `ptc_session_close`

`ptc_lisp_execute` remains available and stateless.

If sessions are disabled, the session tools SHOULD NOT be advertised.
A non-advertised session tool call MAY return `unknown_tool`; if an
implementation reserves the names even while disabled, it MUST return
`sessions_disabled`. The behavior MUST be covered by tests so clients
do not see both responses from the same server build.

### 7.1 `ptc_session_start`

Creates a new exploration session.

Input:

```json
{
  "title": "Investigate recent GitHub MCP issues",
  "purpose": "Find likely bug clusters and summarize evidence",
  "mode": "read_only",
  "memory_policy": "summaries_only",
  "ttl_ms": 1800000
}
```

Required fields:

- `purpose`

Optional fields:

- `title`
- `mode`: `"read_only" | "write_capable"`; default `"read_only"`.
- `memory_policy`: `"summaries_only" | "handles_and_summaries" |
  "raw_payloads"`; default `"summaries_only"`.
- `ttl_ms`; capped by server config.

Output:

```json
{
  "status": "ok",
  "session_id": "ptcs_...",
  "expires_at": "2026-05-12T14:30:00Z",
  "limits": {
    "max_bytes": 1048576,
    "max_artifacts": 200,
    "max_idle_ms": 900000
  }
}
```

### 7.2 `ptc_session_call`

Runs a PTC-Lisp program with access to the session's selected state and
optionally stores a bounded artifact from the result.

Input:

```json
{
  "session_id": "ptcs_...",
  "program": "(return {:count 3})",
  "context": {},
  "signature": "{count :int}",
  "store": {
    "kind": "fact",
    "title": "Open issue count",
    "from": "validated",
    "path": ["count"]
  }
}
```

Semantics:

- The PTC-Lisp runtime still gets fresh execution memory per call.
  Any upstream connection or tool-list cache remains server-owned and
  is not mutable session state.
- The server injects a bounded, read-only projection of session memory
  under `context` as `data/session`.
- Caller-provided `context` **MUST NOT** contain a top-level
  `"session"` key. This key is reserved for the server projection;
  conflicting input returns `session_args_error`.
- The merged context (`context` plus server session projection)
  **MUST** be validated against the existing context key and byte
  limits before execution. If the projection makes the merged context
  too large, the call returns `session_limit_exceeded` before acquiring
  a worker permit.
- The program may call configured upstreams through aggregator mode
  when available.
- Storing is controlled by the MCP server after execution, not by
  arbitrary mutation from inside PTC-Lisp.
- The server **MUST NOT** invent semantic summaries of arbitrary PTC
  results. Stored content must come from an explicit caller body, a
  deterministic selected validated value, a capped result preview, or
  the compact upstream ledger.

`store` is optional. If omitted, the call returns the PTC result and
updates only session bookkeeping such as `updated_at` and, in
aggregator mode, the compact upstream ledger.

Allowed `store.from` values:

| Value | Meaning |
|---|---|
| `"validated"` | Store the whole validated value, or the subvalue at `path`, only after signature validation succeeds. |
| `"result_preview"` | Store the rendered result preview after response-profile truncation. |
| `"caller_body"` | Store the explicit `body` supplied inside `store`; this is appropriate for model-authored notes or summaries. |
| `"upstream_ledger"` | Store a compact summary of upstream-call records from this call. |

Every stored value is redacted and checked against `max_artifact_bytes`
and remaining session quota. If execution succeeds but the requested
artifact cannot be stored, the server SHOULD return the PTC result with
`session.store_status: "skipped"` and a structured reason instead of
failing the entire successful computation.

Output includes the normal PTC result plus session metadata:

```json
{
  "status": "ok",
  "result": "...",
  "validated": {},
  "session": {
    "session_id": "ptcs_...",
    "stored_artifact_id": "a_...",
    "store_status": "stored",
    "bytes_used": 12345,
    "artifact_count": 12
  }
}
```

#### 7.2.1 `ptc_session_call` lifecycle

The session process **MUST NOT** run PTC-Lisp directly. Execution uses
the same worker, cancellation, sandbox, aggregator, and concurrency
paths as `ptc_lisp_execute`.

Recommended lifecycle:

1. Validate tool arguments.
2. Derive and check owner.
3. Ask the session process for a bounded immutable projection.
4. Merge projection into context as `session` and validate merged
   context size.
5. Acquire the normal `max_concurrent_calls` permit through the stdio
   worker path.
6. Execute PTC-Lisp through the existing sandbox/aggregator path.
7. After execution, append requested artifacts and upstream summaries
   with one atomic session update.
8. Return the normal PTC envelope plus session metadata.

Concurrent calls against the same session may run in parallel after
they receive their projections. Append-time quota checks are
authoritative. If two successful calls race and only one artifact fits,
the losing append is reported with `store_status: "skipped"` and
`reason: "session_limit_exceeded"` while preserving that call's PTC
result.

### 7.3 `ptc_session_read`

Reads a compact projection of session state. This is for client/model
orientation, not bulk export.

Input:

```json
{
  "session_id": "ptcs_...",
  "view": "summary",
  "limit": 20
}
```

Views:

- `"summary"` — title, purpose, status, artifact counts, recent facts,
  open questions.
- `"facts"` — stored fact artifacts.
- `"notes"` — notes and model-authored summaries.
- `"upstream_calls"` — compact call ledger.
- `"catalog"` — cached catalog snapshot summaries.

### 7.4 `ptc_session_update`

Adds or supersedes explicit artifacts without running PTC-Lisp.

Input:

```json
{
  "session_id": "ptcs_...",
  "append": [
    {
      "kind": "open_question",
      "title": "Check whether issue cluster is new",
      "body": "Need to compare with older closed issues."
    }
  ],
  "supersede": ["a_old"]
}
```

The server **MUST** validate size, allowed artifact kinds, and owner
before applying changes.

### 7.5 `ptc_session_close`

Closes a session and deletes active in-memory state.

Input:

```json
{
  "session_id": "ptcs_...",
  "reason": "done"
}
```

After close, the implementation **SHOULD** keep a small tombstone until
`closed_tombstone_ttl_ms` expires so later calls can return
`session_closed`. Tombstones contain only `session_id`, `owner_hash`,
`closed_at`, and `reason`; they do not contain artifacts, raw payloads,
or projections. After the tombstone expires, the same id returns
`session_not_found`.

## 8. Session State Shape

Internal state SHOULD be atom-keyed Elixir structs or maps. JSON
projection happens only at MCP boundaries.

Recommended internal state:

```elixir
%Session{
  id: String.t(),
  owner: map(),
  title: String.t() | nil,
  purpose: String.t(),
  mode: :read_only | :write_capable,
  memory_policy: :summaries_only | :handles_and_summaries | :raw_payloads,
  created_at: DateTime.t(),
  updated_at: DateTime.t(),
  expires_at: DateTime.t(),
  status: :active,
  limits: %{
    max_bytes: pos_integer(),
    max_artifacts: pos_integer(),
    max_idle_ms: pos_integer(),
    max_projection_bytes: pos_integer(),
    max_raw_payload_bytes: non_neg_integer()
  },
  artifacts: [artifact()],
  bytes_used: non_neg_integer(),
  upstream_ledger: [map()],
  catalog_snapshot: [map()] | nil
}
```

Artifact shape:

```elixir
%{
  id: String.t(),
  kind:
    :note
    | :fact
    | :open_question
    | :decision
    | :result_summary
    | :result_handle
    | :catalog_snapshot
    | :upstream_call_summary,
  title: String.t() | nil,
  body: String.t() | map() | list(),
  source: :model | :ptc_result | :upstream_call | :operator,
  created_at: DateTime.t(),
  supersedes: [String.t()],
  redacted: boolean(),
  bytes: non_neg_integer()
}
```

## 9. Memory Policy

### 9.1 `summaries_only`

Default. The server stores only compact summaries, facts, notes, and
upstream-call metadata. Full upstream payloads are not stored.

### 9.2 `handles_and_summaries`

Stores summaries plus opaque result handles. Handles may refer to
server-side capped previews or recomputable upstream calls. The handle
format is internal and **MUST NOT** grant access across owners.

### 9.3 `raw_payloads`

Disabled unless explicitly enabled by operator config. Even when
enabled:

- raw payloads **MUST** be capped by `max_raw_payload_bytes`;
- credentials and configured secret patterns **MUST** be redacted;
- payloads **MUST** count against session `max_bytes`;
- `ptc_session_read` **MUST NOT** return raw payloads by default.

## 10. Safety Model

### 10.1 Authority

Session memory is not authority. A later write-capable operation
**MUST NOT** be authorized solely because a session note says it is
allowed. Write-capable upstream calls still need the normal upstream
configuration, write policy, and any future approval gates.

### 10.2 Read-only Mode

`mode: "read_only"` is a session policy. In this mode, the server
SHOULD reject upstream calls known to be write-capable before the
upstream request is sent. Enforcement belongs at the `(tool/mcp-call
...)` boundary inside `ptc_session_call`, after the target
`server/tool` is known and before `Upstream.call/4`.

Because MCP tool annotations are not universal, the reliable Phase 3
mechanism is an explicit allowlist in upstream configuration. In
`read_only` sessions:

- if `allowed_tools` is configured for the upstream, any tool not in
  the allowlist **MUST** be rejected with `session_policy_violation`;
- if upstream tool metadata declares a destructive or non-read-only
  operation, the call **MUST** be rejected;
- if neither allowlist nor useful metadata exists, enforcement is
  best-effort and the tool description/debug output SHOULD make that
  limitation visible.

Recommended upstream allowlist:

```json
{
  "server": "github",
  "allowed_tools": ["search_issues", "get_issue", "list_pull_requests"]
}
```

### 10.3 Redaction

The session write boundary **MUST** run the same redaction strategy as
trace/debug payloads. Credentials, auth headers, and configured secret
bindings must never be persisted in session artifacts.

### 10.4 Prompt Injection

Stored artifacts are untrusted data. When injecting session memory
into a future PTC-Lisp call or agentic prompt, the renderer **MUST**
label it as data from prior tool results, not instructions.

### 10.5 Staleness

Every artifact projection **SHOULD** include timestamps. Summaries
SHOULD mention when they were derived. The server **MAY** mark old
artifacts as stale after a configurable age.

## 11. Resource Limits

Add session-specific limits:

| Limit | Default | Configurable |
|---|---:|---|
| `max_sessions` | 64 per process | env/CLI |
| `max_sessions_per_owner` | 16 | env/CLI |
| `session_ttl_ms` | 30 min | env/CLI |
| `session_idle_timeout_ms` | 15 min | env/CLI |
| `max_session_bytes` | 1 MiB | env/CLI |
| `max_session_artifacts` | 200 | env/CLI |
| `max_artifact_bytes` | 64 KiB | env/CLI |
| `max_session_projection_bytes` | 128 KiB | env/CLI |
| `max_raw_payload_bytes` | 0 | env/CLI |
| `closed_tombstone_ttl_ms` | 5 min | env/CLI |

Crossing a limit **MUST** produce structured tool errors, not server
crashes.

## 12. OTP Architecture

Recommended modules:

```text
mcp_server/lib/ptc_runner_mcp/
  sessions.ex                  # public facade
  sessions/
    config.ex                  # limits and feature flag
    owner.ex                   # stdio/http owner derivation and checks
    registry.ex                # lookup/index, quotas
    supervisor.ex              # DynamicSupervisor over session processes
    session.ex                 # GenServer per exploration session
    artifact.ex                # validation/projection helpers
    projection.ex              # compact JSON views
    redactor.ex                # storage-boundary redaction wrapper
```

Supervision tree addition:

```text
PtcRunnerMcp.Supervisor
  Credentials
  Upstream.Supervisor
  Sessions.Registry
  Sessions.Supervisor
  Stdio
```

`Sessions.Registry` should start before `Stdio` so tools can create
sessions during request handling. The placement after
`Upstream.Supervisor` means a crash of `Credentials` or
`Upstream.Supervisor` under the current `:rest_for_one` tree will also
restart session processes and lose in-memory sessions. That is
acceptable for the first in-memory implementation, but it **MUST** be
covered by a test or documented operator note. If preserving sessions
across upstream restarts becomes a goal, sessions need a different
supervision boundary or a persistence backend.

Each exploration session process owns its state. The registry owns
indexes, tombstones, and session-count quotas. Session processes
terminate on close, TTL, idle timeout, owner shutdown, or supervisor
shutdown.

## 13. Error Model

Add session-specific reasons to MCP tool envelopes:

| Reason | Meaning |
|---|---|
| `sessions_disabled` | Server started without session support. |
| `session_not_found` | Unknown or expired session id. |
| `session_closed` | Session was explicitly closed. |
| `session_owner_mismatch` | Caller does not own the session. |
| `session_limit_exceeded` | Count/byte/artifact quota exceeded. |
| `session_policy_violation` | Operation rejected by read-only/write policy. |
| `session_args_error` | Malformed session tool arguments. |

These should be MCP-only error reasons unless promoted to a shared PTC
protocol reason later.

Each advertised session tool **MUST** include an `outputSchema` for
success and error responses, unless the active response profile omits
schemas globally. The schema must include the session-specific reasons
above so strict structured-content clients accept server-generated
errors. Session tools should follow the active
`slim|structured|debug` response profile where practical, but their
core `status`, `reason`, and `message` fields must remain stable.

## 14. Telemetry

Emit telemetry events:

```elixir
[:ptc_runner_mcp, :session, :start]
[:ptc_runner_mcp, :session, :stop]
[:ptc_runner_mcp, :session, :close]
[:ptc_runner_mcp, :session, :artifact, :append]
[:ptc_runner_mcp, :session, :call, :start]
[:ptc_runner_mcp, :session, :call, :stop]
[:ptc_runner_mcp, :session, :evict]
```

Metadata SHOULD include:

- `session_id`
- `owner_hash`
- `mode`
- `memory_policy`
- `artifact_count`
- `bytes_used`
- `reason` for close/evict/error

Do not emit raw artifact bodies in telemetry metadata.

## 15. Interaction With Existing Features

### 15.1 `ptc_lisp_execute`

No behavior change. It remains stateless and should continue to be
the default safe baseline.

### 15.2 Aggregator Mode

Session calls MAY use aggregator mode. Upstream-call entries produced
inside `ptc_session_call` SHOULD be appended to the session's compact
upstream ledger, subject to limits.

The upstream ledger append is separate from raw payload storage. It
stores compact metadata compatible with the existing `upstream_calls`
envelope and never stores full upstream bodies unless `raw_payloads`
is enabled and an explicit store request selects them.

### 15.3 Agentic `ptc_task`

`ptc_task` may later use sessions as working memory. Phase 1 should
not require agentic mode. Sessions should be useful for deterministic
client-authored PTC-Lisp first.

### 15.4 Debug Tool

`ptc_debug` SHOULD include session events when the debug tool is
enabled, capped by the existing debug response limits.

## 16. MCP Advertisement

Session tools SHOULD be hidden unless enabled by config:

```text
--sessions
PTC_RUNNER_MCP_SESSIONS=true
```

When enabled, `tools/list` advertises the session tools alongside
`ptc_lisp_execute` and any enabled `ptc_task` / `ptc_debug` tools.

Tool descriptions MUST state:

- sessions are per-client/process in stdio mode;
- state is bounded and expires;
- credentials are not stored;
- session memory is not authorization for writes;
- `ptc_lisp_execute` remains stateless.

## 17. Phasing

### Phase 0 — Contract and Tests

- Add this specification.
- Add unit tests for owner model, artifact validation, projections,
  quotas, TTL/idle calculations, and error envelopes.
- No public tools yet.

### Phase 1 — Stdio-Local Sessions

- Add `Sessions.Supervisor`, `Sessions.Registry`, and `Sessions.Session`.
- Add `ptc_session_start`, `ptc_session_read`,
  `ptc_session_update`, and `ptc_session_close`.
- Store only summaries/facts/notes/open questions.
- Accept `mode` and `memory_policy` fields, but only enforce the
  portions implemented in Phase 1. `raw_payloads` MUST be rejected
  unless operator config enables it.
- Add closed-session tombstones.
- Feature flag off by default.

### Phase 2 — `ptc_session_call`

- Run PTC-Lisp with a bounded session projection.
- Support optional post-call artifact storage.
- Append compact upstream-call summaries.
- Enforce per-session quotas under concurrent calls.

### Phase 3 — Read-only Policy

- Support configured upstream allowlists.
- Reject known write-capable tools in read-only sessions when metadata
  is available.

### Phase 4 — HTTP-Ready Ownership

- Refactor owner derivation to accept future HTTP `Mcp-Session-Id`.
- Add tests for owner mismatch and multi-owner isolation.
- Do not implement HTTP transport here; only make the session model
  transport-neutral.

### Phase 5 — Optional Persistence

- Optional, explicitly configured persistence backend.
- Preserve owner binding and expiration.
- Raw payload persistence remains disabled by default.

## 18. Open Questions

1. Should session tools be separate MCP tools or folded into
   `ptc_task`? This spec recommends separate tools for clarity.
2. How should read-only upstream allowlists be configured alongside
   existing upstream config?
3. Should session ids be opaque random strings only, or include a
   short process/owner prefix for debugging?
4. Should `ptc_session_read` support server-side filtering/search in
   Phase 1, or only simple views?
5. What exact fields should be injected into PTC-Lisp as
   `data/session`?

## 19. Initial Acceptance Criteria

The first shippable version is acceptable when:

1. Sessions are disabled by default.
2. Enabling sessions adds explicit session tools to `tools/list`.
3. Multiple sessions can exist concurrently in one stdio server
   process.
4. Session state is isolated by owner.
5. TTL, idle timeout, byte limit, artifact limit, and max-session
   limits are enforced.
6. `ptc_lisp_execute` remains stateless and all existing tests pass.
7. Stored artifacts are redacted and capped.
8. `ptc_session_close` deletes active state and leaves only a capped
   tombstone for `session_closed`.
9. Debug/telemetry expose counts and ids, never raw secret-bearing
   payloads.
