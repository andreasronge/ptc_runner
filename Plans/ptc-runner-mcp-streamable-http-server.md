# PtcRunner MCP Streamable HTTP Server - Specification

| Field | Value |
|---|---|
| Status | Build-ready. §13 open questions resolved 2026-05-16 (rev 3). |
| Target package | `:ptc_runner_mcp` |
| Depends on | `Plans/ptc-runner-mcp-server.md`, `Plans/ptc-runner-mcp-aggregator.md`, `Plans/http-transport-credentials.md`, `Plans/ptc-runner-mcp-sessions.md` |
| Protocol target | MCP Streamable HTTP, primary `2025-11-25`, compatibility floor `2025-06-18` |
| Last revised | 2026-05-16 (rev 3) |

This document specifies server-side Streamable HTTP support for
`ptc_runner_mcp`. The goal is to let one deployed PtcRunner MCP node
serve multiple independent MCP clients over the network while preserving
the existing stdio transport, sandbox limits, upstream MCP aggregation,
and stateful PTC-Lisp session machinery.

Sections using **MUST** / **SHOULD** / **MAY** carry RFC 2119 normative
weight.

## 1. Summary

`ptc_runner_mcp` currently exposes MCP over stdio. This spec adds an
optional HTTP listener implementing the MCP Streamable HTTP transport at
one endpoint, `/mcp` by default.

The first production version is intentionally narrow:

- `POST /mcp` accepts one JSON-RPC message and returns either
  `application/json` for requests or `202 Accepted` for notifications
  and responses.
- `GET /mcp` returns `405 Method Not Allowed` until server-to-client
  SSE is needed.
- `DELETE /mcp` terminates the HTTP MCP protocol session identified by
  `MCP-Session-Id`.
- Each HTTP MCP session has independent lifecycle state, negotiated
  protocol version, in-flight request table, cancellation map, owner
  identity, and limits.
- PTC-Lisp stateful sessions remain a separate abstraction. HTTP MCP
  sessions may create or use PTC-Lisp sessions, but they are not the
  same object.

The feature is opt-in. Existing stdio behavior, release invocation, and
desktop-client compatibility MUST remain unchanged.

## 2. Motivation

The intended deployment is a secure network service for agentic
applications that need code-mode execution near upstream MCP servers:

> A remote, secure, low-latency code-mode MCP tool that lets agentic
> apps execute deterministic PTC-Lisp near upstream MCP servers, without
> exposing arbitrary shell, Python, or JavaScript execution.

This is not a generic MCP gateway. The value comes from combining:

- PTC-Lisp's constrained sandbox.
- Existing global execution limits.
- Per-call worker isolation and cancellation.
- Optional stateful PTC-Lisp sessions.
- Upstream MCP aggregation, including HTTP upstreams.
- A deployable HTTP transport that supports many independent clients.

## 3. Current State

Relevant existing modules:

| Module | Current role |
|---|---|
| `PtcRunnerMcp.Stdio` | NDJSON stdio transport. Owns frame parsing, lifecycle state, in-flight workers, cancellation, drain, exit, and response writes. |
| `PtcRunnerMcp.JsonRpc` | Method dispatcher. Returns synchronous replies, async call work, cancellation directives, and lifecycle directives. |
| `PtcRunnerMcp.Lifecycle` | Stateless initialize/shutdown/cancel helpers. |
| `PtcRunnerMcp.Version` | Protocol negotiation. Currently stores the most recently negotiated version in global `:persistent_term`. |
| `PtcRunnerMcp.ConcurrencyGate` | Global non-queueing execution semaphore. |
| `PtcRunnerMcp.Sessions.*` | Stateful PTC-Lisp session registry, limits, owners, and session processes. |
| `PtcRunnerMcp.Upstream.Http.*` | Client-side Streamable HTTP support for upstream MCP servers, currently targeting `2025-06-18`. |
| `PtcRunnerMcp.Application` | CLI/env config and production supervision tree. |

The main architectural gap is that stdio is more than a byte transport:
it also owns request execution state. HTTP needs the same execution
semantics per protocol session without duplicating the JSON-RPC and
worker logic.

## 4. Goals

1. Add an opt-in production HTTP listener for MCP clients.
2. Implement one Streamable HTTP MCP endpoint with POST and DELETE in
   v1, plus GET returning 405.
3. Support many concurrent HTTP clients with isolated MCP protocol
   sessions.
4. Keep stdio stable and available.
5. Reuse the existing JSON-RPC/lifecycle/tool behavior.
6. Preserve existing sandbox, response, debug, trace, upstream, and
   PTC-Lisp session behavior unless this spec explicitly changes it.
7. Add product-grade security defaults suitable for deployment behind a
   TLS edge in AWS or an equivalent private network.
8. Add observability for session churn, request latency, limit rejections,
   auth failures, cancellation, and cleanup.

## 5. Non-Goals

- No legacy HTTP+SSE two-endpoint transport.
- No server-to-client SSE GET stream in v1.
- No POST-response SSE in v1. All JSON-RPC requests return one JSON
  response object.
- No resumability or `Last-Event-ID` replay in v1.
- No dynamic OAuth server for downstream MCP clients in v1.
- No multi-node distributed HTTP session registry in v1. A session lives
  on one BEAM node.
- No attempt to become a general-purpose MCP gateway. Upstream access is
  still mediated through PTC-Lisp and existing aggregator policies.
- No PTC-Lisp syntax, builtin, Java interop, or Clojure conformance
  changes.

## 6. CLI and Configuration

New CLI flags:

| Flag | Env var | Default | Meaning |
|---|---|---:|---|
| `--http` | `PTC_RUNNER_MCP_HTTP` | `false` | Enable HTTP listener. |
| `--http-host <host>` | `PTC_RUNNER_MCP_HTTP_HOST` | `127.0.0.1` | Bind host. Default follows MCP local-server security guidance. |
| `--http-port <int>` | `PTC_RUNNER_MCP_HTTP_PORT` | `7332` | Bind port. |
| `--http-path <path>` | `PTC_RUNNER_MCP_HTTP_PATH` | `/mcp` | MCP endpoint path. |
| `--http-auth-token <token>` | `PTC_RUNNER_MCP_HTTP_AUTH_TOKEN` | unset | Static bearer token for v1 auth. Required when binding non-localhost unless explicitly disabled. MUST be at least 32 characters; `Http.Config` rejects shorter tokens at startup (see §11.2). |
| `--http-disable-auth` | `PTC_RUNNER_MCP_HTTP_DISABLE_AUTH` | `false` | Development-only bypass. Rejected when host is not loopback unless `--http-allow-unsafe-network` is set. |
| `--http-allowed-origin <origin>` | `PTC_RUNNER_MCP_HTTP_ALLOWED_ORIGIN` | unset | May be repeated or comma-separated. Validates `Origin` when present. |
| `--http-request-timeout-ms <int>` | `PTC_RUNNER_MCP_HTTP_REQUEST_TIMEOUT_MS` | `15000` | Max time to receive request headers + body before the connection is dropped (slowloris protection). |
| `--http-shutdown-grace-ms <int>` | `PTC_RUNNER_MCP_HTTP_SHUTDOWN_GRACE_MS` | `10000` | Drain window on `SIGTERM`: how long in-flight requests may finish before remaining workers are cancelled (§7.5). |
| `--http-max-body-bytes <int>` | `PTC_RUNNER_MCP_HTTP_MAX_BODY_BYTES` | same as max frame bytes | Request body cap. |
| `--http-session-ttl-ms <int>` | `PTC_RUNNER_MCP_HTTP_SESSION_TTL_MS` | `3600000` | Absolute protocol-session TTL. |
| `--http-session-idle-timeout-ms <int>` | `PTC_RUNNER_MCP_HTTP_SESSION_IDLE_TIMEOUT_MS` | `900000` | Idle protocol-session timeout. |
| `--http-max-sessions <int>` | `PTC_RUNNER_MCP_HTTP_MAX_SESSIONS` | `256` | Global HTTP protocol-session cap. |
| `--http-max-sessions-per-owner <int>` | `PTC_RUNNER_MCP_HTTP_MAX_SESSIONS_PER_OWNER` | `32` | Per-owner protocol-session cap. |
| `--http-max-in-flight-per-session <int>` | `PTC_RUNNER_MCP_HTTP_MAX_IN_FLIGHT_PER_SESSION` | `4` | Per-session non-queueing request cap. |
| `--http-allow-unsafe-network` | `PTC_RUNNER_MCP_HTTP_ALLOW_UNSAFE_NETWORK` | `false` | Allows unauthenticated non-loopback bind for controlled tests only. |

Flag interactions:

- A non-loopback bind (`--http-host` not in `127.0.0.0/8` or `::1`)
  requires either a valid `--http-auth-token` or the explicit pair
  `--http-disable-auth --http-allow-unsafe-network`. `Http.Config`
  rejects any other non-loopback combination at startup.
- `--http-allow-unsafe-network` alone is meaningless without
  `--http-disable-auth`; an authenticated non-loopback bind does not
  need it. `Http.Config` warns if it is set without `--http-disable-auth`.
- `--http-disable-auth` on a loopback bind is permitted but logs a
  warning: on a shared host any local user or process can then reach
  `/mcp` and, through it, any configured upstream MCP server. Prefer a
  token even on loopback.
- With a single `--http-auth-token`, all clients share one owner
  identity (see §11.2), so `--http-max-sessions-per-owner` becomes the
  effective global cap. When one token is in use, set
  `--http-max-sessions-per-owner` >= `--http-max-sessions` (or rely on
  the global cap alone). `Http.Config` warns if the per-owner cap is
  lower than the global cap in single-token mode.

### 6.1 Observability flags

The HTTP listener reuses the existing process-wide observability config
(`--log-level` / `PTC_RUNNER_MCP_LOG_LEVEL`, and `--trace-dir` /
`--trace-payloads` / `--trace-max-files`); no HTTP-specific variants are
introduced for those. New flags:

| Flag | Env var | Default | Meaning |
|---|---|---:|---|
| `--http-metrics` | `PTC_RUNNER_MCP_HTTP_METRICS` | `false` | Expose `GET /metrics` (Prometheus exposition, §12.3). |
| `--http-metrics-path <path>` | `PTC_RUNNER_MCP_HTTP_METRICS_PATH` | `/metrics` | Metrics endpoint path. Must differ from `--http-path` and `/health`, `/ready`; `Http.Config` rejects collisions. |
| `--http-instance-label <str>` | `PTC_RUNNER_MCP_HTTP_INSTANCE_LABEL` | hostname | Stable label for this node, stamped on every log line, telemetry event, and trace record so a multi-instance deployment behind one load balancer is separable. |

Notes:

- `--trace-dir` works in HTTP mode unchanged, but trace records gain
  `mcp_session_hash` and `owner_hash` fields (§12.4). With many clients
  the `--trace-max-files` FIFO cap (default 1000) churns faster; raise
  it or ship traces off-box for a busy deployment.
- `/metrics` is unauthenticated like `/health` and `/ready`; this is
  safe only because the deployment target is a private network (§11.5).
  It exposes counts and hashes, never tokens, programs, or raw ids.

Dependency change:

- `:bandit` and `:plug` move from dev/test-only dependencies to runtime
  dependencies of `mcp_server`, unless a different production HTTP stack
  is chosen before implementation.
- `:telemetry_metrics` and a Prometheus reporter (e.g.
  `:telemetry_metrics_prometheus_core`) become runtime dependencies
  **only when `--http-metrics` support is built** (§12.3). If metrics
  ship in a later PR, this dependency is deferred with it.

Supervision:

- When `--http` is absent, the application MUST start exactly the
  existing stdio-oriented production tree.
- When `--http` is present, the application starts the HTTP session
  registry and Bandit/Plug listener. Whether stdio also starts is
  controlled by §7.4.

## 7. Architecture

### 7.1 Shared Transport Runner

Introduce a shared execution component that owns request execution
semantics independent of wire transport:

```
mcp_server/lib/ptc_runner_mcp/
  transport/
    connection.ex       # lifecycle state, in-flight workers, cancellation
    response.ex         # transport-neutral reply directives
    owner.ex            # owner identity derivation helpers
```

`PtcRunnerMcp.Transport.Connection` owns:

- `draining?`
- `exited?`
- negotiated MCP protocol version
- in-flight request table
- worker pid to request id index
- per-connection/session in-flight cap
- cancellation
- graceful drain/exit semantics

It consumes `PtcRunnerMcp.JsonRpc.dispatch/2` and emits
transport-neutral actions:

```elixir
{:reply, frame, connection}
{:accepted, connection}
{:no_reply, connection}
{:closed, reason, connection}
```

The stdio transport may be migrated to this component in the same PR or
in a preceding PR. HTTP MUST NOT fork its own copy of stdio's worker and
cancellation logic.

Protocol negotiation ownership. The connection layer owns negotiated
protocol-version state, not `JsonRpc.dispatch/2`:

- On `initialize`, `Transport.Connection` calls pure
  `Version.negotiate/1`, stores the chosen version on itself, and passes
  the chosen value into `Lifecycle.initialize_reply/2`.
- `Lifecycle.initialize_reply/2` builds the response from the already
  chosen version; it does not negotiate or mutate process-global state.
- `JsonRpc.dispatch/2` receives the current `:protocol_version` in opts
  for telemetry/debug metadata, but it MUST NOT own or mutate version
  state.
- If initialize reply construction proves too entangled to refactor in
  one cut, a temporary fallback may return the chosen version explicitly
  from dispatch. The implementation MUST NOT reverse-parse
  `result.protocolVersion` back out of a response map.

Async-to-synchronous bridge. The `{:accepted, connection}` directive is
only ever emitted for JSON-RPC notifications and responses. A JSON-RPC
*request* (including `tools/call`) MUST resolve to exactly one
`{:reply, frame, connection}`. For HTTP this means the POST handler
**awaits** worker completion before responding — the Plug process blocks
until the worker emits a reply, is cancelled, crashes, or hits the
sandbox timeout. The handler never returns `202` for a request. Worker
outcomes other than normal completion are mapped to a reply frame per
§8.2; the request never hangs.

**The session process MUST NOT block on worker completion.** Only the
ephemeral per-request Plug process blocks. Concretely:

- A `tools/call` POST does a short, bounded `GenServer.call` into
  `Http.Session` that registers the request, spawns the worker, and
  returns immediately. The Plug process then awaits the worker result
  as a plain message (the worker, or the session, sends it to the Plug
  pid), bounded by the per-call sandbox timeout plus a small margin.
- The session process stays responsive the whole time, so a
  `notifications/cancelled` POST, a `DELETE`, idle/TTL cleanup, and
  shutdown drain — each arriving on a *different* process — are handled
  while the original request is still in flight.
- On cancel/crash/cleanup the session sends the terminal outcome to the
  waiting Plug pid so the blocked POST always unblocks.

Await-timeout invariant. HTTP uses a central
`worker_await_timeout_ms/1` helper keyed by the specific tool's own
configured budget (`ptc_lisp_execute`, `ptc_task`, and
`ptc_session_eval` may differ). The Plug await timeout MUST strictly
exceed the worker's budget, so normal tool timeout handling wins the
race and returns the existing timeout envelope. The Plug await is only a
backstop for a wedged worker, crashed worker, missed terminal message,
or session cleanup race; a fixed margin of 1000 ms is sufficient unless
later tests show the need for a larger scheduler/rendering allowance.

Cancellation outcome model. Phase 0 keeps stdio behavior identical, so
`Transport.Connection` MUST NOT hardcode "cancel = emit no reply". It
surfaces a transport-neutral `{:cancelled, request_id, connection}`
outcome; each transport decides emission. Stdio maps `:cancelled` to no
write (current behavior, preserved). HTTP maps `:cancelled` to the
cancelled reply frame in §8.2. This is the one place the shared runner
needs a transport-specific policy hook; the spec calls it out so Phase 0
extracts the hook rather than baking in stdio's choice.

### 7.2 HTTP Modules

Add:

```
mcp_server/lib/ptc_runner_mcp/http/
  config.ex
  router.ex
  server.ex
  session.ex
  session_registry.ex
  auth.ex
  origin.ex
  telemetry.ex
```

Responsibilities:

| Module | Responsibility |
|---|---|
| `Http.Config` | Resolve CLI/env defaults, validate unsafe combinations, enforce minimum token length. |
| `Http.Server` | Build Bandit child spec, including request-read timeout and shutdown drain. |
| `Http.Router` | Plug endpoint for `/mcp` (POST, GET, DELETE) and the unauthenticated `/health` probe (§8.5). |
| `Http.Session` | One HTTP MCP protocol session process. Wraps `Transport.Connection`. |
| `Http.SessionRegistry` | Create, lookup, monitor, idle/TTL cleanup, quota enforcement. |
| `Http.Auth` | Static bearer-token validation and owner identity extraction. |
| `Http.Origin` | Origin header validation. |
| `Http.Telemetry` | Event helpers and safe metadata shaping. |

### 7.3 HTTP MCP Protocol Session

An HTTP MCP protocol session represents the relationship between one MCP
client and this MCP server. It is created by a successful
`initialize` request and is identified by `MCP-Session-Id`.

Session state includes:

- session id
- owner identity
- owner hash for logs and quotas
- negotiated protocol version
- lifecycle state
- in-flight request table
- cancellation map
- created/last-seen timestamps
- request counters
- optional associated PTC-Lisp session ids
- upstream access policy snapshot

Session ids MUST be cryptographically strong visible ASCII. Use
`crypto:strong_rand_bytes` encoded as URL-safe Base64 without padding or
an equivalently strong UUID implementation.

Two distinct "owner" concepts, do not conflate them:

- **Auth-principal owner** — derived from the bearer token (§11.2). It
  owns the *HTTP MCP protocol session* and is what §11.2 ownership
  enforcement and per-owner session quotas check.
- **PTC-Lisp session owner** — the existing `PtcRunnerMcp.Sessions.Owner`
  `:http` owner map, keyed by `mcp_session_id`. A PTC-Lisp stateful
  session created from an HTTP MCP session is owned by that
  `mcp_session_id`, so PTC-Lisp sessions are scoped to the protocol
  session that created them.

The relationship is a hierarchy: auth principal → owns → HTTP MCP
session (`mcp_session_id`) → owns → PTC-Lisp sessions. When an HTTP MCP
session is deleted or reaped, its PTC-Lisp sessions are released through
the existing `Sessions` ownership path. The HTTP MCP session stores both
the auth-principal owner and its own id; it passes
`Sessions.Owner.http/2` (with `mcp_session_id`, and `client_id`/`user_id`
when multi-token auth supplies them) when creating PTC-Lisp sessions. No
change to `Sessions.Owner` is required for v1.

Crash-safe cleanup is driven by `Http.SessionRegistry`, not by
`Http.Session.terminate/2`. The registry monitors every `Http.Session`
process and, in its `:DOWN` path, removes the protocol session, releases
its quotas, and calls a narrow `Sessions.close_owner/1` API for the
corresponding `Sessions.Owner.http/2` owner. That single monitor path
covers DELETE, idle reap, TTL reap, session crash, and shutdown
uniformly; `terminate/2` may still do best-effort local cleanup, but it
is not the correctness mechanism.

### 7.4 Stdio Coexistence Modes

Default:

- Without `--http`, stdio starts as today.
- With `--http`, HTTP starts and stdio does not attach to `:stdio`
  unless `--stdio` is later added.

Rationale: a release process running as infrastructure should not block
or terminate based on stdin EOF. Keeping the first version binary avoids
surprising deployments.

Optional future flag:

- `--stdio` can explicitly enable stdio alongside HTTP if a combined
  local/remote process is useful.

Note: Phase 0 removes the node-global `Version.negotiated/0`
`:persistent_term` state (§9). This is required before any future
`--stdio` + `--http` combined mode can be safe, because simultaneous
clients must not race on process-global negotiated protocol version.

### 7.5 Graceful Shutdown

The HTTP server runs as a long-lived network service, so it MUST drain
cleanly on `SIGTERM` / `Application.stop` for zero-downtime rolling
deploys behind a load balancer:

1. Stop accepting new TCP connections (Bandit listener drain) and stop
   creating new sessions.
2. New requests on already-open connections receive `503 Service
   Unavailable`, `Content-Type: application/json`, body
   `{"jsonrpc":"2.0","id":<request id or null>,"error":{"code":-32000,
   "message":"server draining"}}`. The `id` echoes the request's `id`
   when the body parsed far enough to read one, else `null`.
3. In-flight workers are allowed to finish within a bounded drain
   timeout (reuse `--http-request-timeout-ms` order of magnitude, or a
   dedicated shutdown-grace value).
4. After the grace period, remaining workers are cancelled and global
   permits released, mirroring §10 cleanup. Each still-blocked POST
   returns the cancelled reply mapping (§8.2) — not a `503` — because
   the request was accepted and dispatched; only its completion was
   pre-empted.
5. The process then exits.

The same `503` JSON-RPC error body shape (`-32000`, descriptive
`message`) is used for the global-session-cap rejection in §10.

This is distinct from the JSON-RPC `shutdown`/`drain` lifecycle, which
applies per HTTP MCP session and never drains the whole node (see §15
isolation tests).

## 8. HTTP Wire Semantics

### 8.1 Common Request Checks

All `/mcp` requests MUST pass, in this order. Header-only checks run
**before** the request body is read, so an unauthenticated or
bad-origin client cannot force the server to read a body up to the cap:

1. Path match.
2. Origin validation when `Origin` is present (header-only).
3. Authentication unless disabled by validated config (header-only).
4. Request body size cap and body read for methods with a body. The cap
   is enforced during the read (§10).
5. Method-specific protocol checks.

Sensitive values MUST NOT be logged:

- `Authorization`
- `MCP-Session-Id`
- cookies
- configured auth token
- upstream auth headers

Logs and telemetry may include hashes of session ids and owner ids.

### 8.2 POST `/mcp`

Client request requirements:

- Method MUST be `POST`.
- Body MUST be one JSON-RPC request, notification, or response object.
- Batch arrays are rejected as JSON-RPC invalid requests, matching
  current stdio behavior.
- `Accept` SHOULD include both `application/json` and
  `text/event-stream`. v1 accepts missing or narrow `Accept` for
  compatibility but logs a debug-level compatibility event.

Message classification. `JsonRpc.dispatch/2` today treats a decoded map
without a `"method"` key as an invalid request. The router/shared runner
MUST therefore classify the decoded body **before** dispatch:

- has `"method"` and `"id"` → JSON-RPC request → dispatched, awaits a
  reply frame.
- has `"method"`, no `"id"` → notification → dispatched, `202`.
- no `"method"`, has `"id"` and (`"result"` or `"error"`) → JSON-RPC
  response → consumed by the in-flight correlation table (not dispatched
  as a method), `202`.
- anything else → JSON-RPC invalid request, `200` with a JSON-RPC error
  body (`-32600`).

Malformed input mapping (deterministic, so tests are not guesswork):

| Condition | Response |
|---|---|
| Body absent / empty on `POST` | `400 Bad Request` |
| Body not valid UTF-8 or not valid JSON | `200 OK`, JSON-RPC parse error `-32700` |
| Body is a JSON value but not an object (array, string, number) | `200 OK`, JSON-RPC invalid request `-32600` |
| `Content-Type` present and not `application/json` | accepted with a debug-level compatibility event (same leniency as `Accept`); not rejected in v1 |
| Body over the size cap | `413 Payload Too Large` before JSON decode (§10) |

Duplicate request id. A JSON-RPC request whose `id` is already in the
session's in-flight table is rejected the same way stdio rejects it
today — the duplicate is not started as a second worker. The HTTP
response is `200 OK` with a JSON-RPC error (`-32600`, "duplicate request
id"). Ids may be reused once the prior request for that id has
completed.

Initialize:

- `initialize` without `MCP-Session-Id` creates a new HTTP MCP protocol
  session after JSON-RPC dispatch succeeds.
- The response includes `MCP-Session-Id`.
- The response `result.protocolVersion` is determined by existing
  `Version.negotiate/1`, but the chosen value is stored on the HTTP
  session, not globally.

Subsequent POST:

- MUST include `MCP-Session-Id`.
- SHOULD include `MCP-Protocol-Version`. The `2025-11-25` revision
  asks clients to send it on every non-`initialize` request, but allows
  the server to fall back to the negotiated version when it can
  identify the session. Since this server *can* (the version is stored
  on the HTTP session), v1 falls back to the session's negotiated
  version when the header is absent and logs a debug-level
  compatibility event. When the header *is* present it MUST match a
  supported version or the request is rejected (see below).
- Missing session id returns `400 Bad Request`.
- Unknown session id returns `404 Not Found`.
- A session id whose owner does not match the request's authenticated
  owner returns `404 Not Found` — not `403` — so the response does not
  confirm that the id exists (see §11.2).
- Invalid or unsupported protocol version returns `400 Bad Request`.

Re-initialize: a `POST initialize` that carries an `MCP-Session-Id`
returns `400 Bad Request`. Re-initializing an existing session is a
client error; silently creating a second session would orphan the
first (resolves §13 Q5).

Response mapping:

| Input kind | Outcome | Response |
|---|---|---|
| JSON-RPC request | worker completed | `200 OK`, `Content-Type: application/json`, one JSON-RPC response object. |
| JSON-RPC request | worker cancelled via `notifications/cancelled` | `200 OK`, JSON-RPC response whose `result` is the standard MCP error envelope for `reason: "cancelled"` (for `tools/call`), or a JSON-RPC error with code `-32800` (request cancelled) for non-tool methods. |
| JSON-RPC request | worker crashed | `200 OK`, JSON-RPC error, code `-32603` (internal error), no sandbox internals in `message`. |
| JSON-RPC request | sandbox/per-call timeout | `200 OK`, JSON-RPC response with the existing timeout error envelope. |
| JSON-RPC request | HTTP client disconnects before completion | no response written; worker is cancelled and permits released (§14 Phase 3). |
| JSON-RPC notification | accepted | `202 Accepted`, no body. |
| JSON-RPC response | accepted | `202 Accepted`, no body. |

A cancellation (`notifications/cancelled`) for an in-flight request
arrives as a *separate* POST on the same session, on a different HTTP
connection. The session process kills the named worker; the blocked POST
holding the original request then returns the cancelled mapping above.
No request is ever left hanging.

The cancelled tool envelope MUST reuse the existing `Envelope` error
shape rather than introducing a transport-specific payload. Concretely,
add a `render_error_payload(:cancelled, message, opts)` clause that
produces the same structure as `:busy`, `:unknown_tool`, and
`:shutting_down`, with `"status" => "error"` and
`"reason" => "cancelled"`, and wrap it through `Envelope.error_envelope/1`
so the JSON-RPC response has `result.isError == true` and
`result.structuredContent.reason == "cancelled"`. The `-32800` branch
exists for completeness; in v1 only `tools/call` workers are
cancellable in practice.

Deliberate non-conformance: disconnect as cancellation. The MCP
Streamable HTTP transport says a client disconnect SHOULD NOT be
interpreted as cancellation, and clients should send
`notifications/cancelled` explicitly. v1 *does* cancel the worker on
client disconnect, because v1 has no resumability or `Last-Event-ID`
replay (§5): a result that no client can ever collect is pure wasted
execution and a held permit. This is an accepted v1 non-conformance.
The conformant behavior (keep running, allow reconnect/replay) requires
the SSE/resumability work deferred to v2.

### 8.3 GET `/mcp`

v1 does not offer SSE:

- Return `405 Method Not Allowed`.
- Include `Allow: POST, DELETE` — the methods actually accepted on
  `/mcp`. GET is not listed: a method that always returns 405 is not an
  allowed method, and listing it is self-contradictory.

This keeps v1 conformant for clients that probe GET while avoiding
server-to-client streams, resumability, event ids, and replay storage.

Functional consequence: with no GET SSE stream and no POST-response SSE
(§5), the server has **no channel for server-to-client messages**. In
v1 this means no progress notifications during a long `tools/call`, no
server-initiated `ping`, and no sampling or elicitation requests. v1
`tools/call` is strictly request/response. This is an accepted v1
tradeoff; adding SSE is the natural v2 follow-up.

### 8.4 DELETE `/mcp`

DELETE terminates an HTTP MCP protocol session.

Rules:

- Requires `MCP-Session-Id`.
- Missing session id: return `400 Bad Request`.
- Existing session owned by the request's authenticated owner: stop the
  session process, cancel in-flight workers, release any global permits,
  remove the id from the registry, return `202 Accepted`.
- Unknown or expired session id: return `404 Not Found`.
- A session id whose owner does not match the request's authenticated
  owner: return `404 Not Found` (does not confirm the id exists).

There are no tombstones. A deleted, expired, or never-issued session id
are indistinguishable: all three return `404`. Session ids are
cryptographically random (§7.3), so id reuse cannot occur and a
tombstone would only ever turn one `404` into another.

### 8.5 GET `/health` — liveness

`/health` answers the question "is this process alive enough to keep,
or should the orchestrator restart it?"

- `GET /health` returns `200 OK` with body `{"status":"ok"}` whenever
  the BEAM process and HTTP listener are up. It does **not** flip to a
  failure state during shutdown drain — a draining node is still alive
  and must not be force-killed by a liveness probe.
- Unauthenticated, no origin check. Exposes only liveness — no session,
  owner, upstream, or version detail.
- Served on the same listener, distinct path from `--http-path`.

### 8.6 GET `/ready` — readiness

`/ready` answers a different question: "should the load balancer route
new traffic here right now?"

- Returns `200 OK` with `{"status":"ready"}` when the listener is bound,
  the session registry is up, and the node is **not** draining and
  **not** at the global session cap.
- Returns `503 Service Unavailable` with `{"status":"draining"}` or
  `{"status":"saturated"}` otherwise.
- Crucially, `/ready` flips to `503` the instant shutdown drain begins
  (§7.5 step 1), while `/health` stays `200` until the process exits.
  This ordering is what makes zero-downtime rolling deploys work: the
  load balancer sees `/ready` fail and stops sending new requests, the
  drain window lets in-flight work finish, then the process exits — no
  request is routed to a dying node.
- Unauthenticated, no origin check, same listener.

The path collision rule applies to `/health`, `/ready`, `/metrics`, and
`--http-path`: all four MUST be distinct or `Http.Config` rejects the
configuration at startup. The documented private-network deployment
(§16) wires the load-balancer health check to `/ready` and the
orchestrator liveness probe to `/health`.

### 8.7 GET `/metrics`

When Phase 4b metrics support is built and `--http-metrics` is set,
`GET /metrics` serves Prometheus exposition format. See §12.3 for the
metric set and the security rationale for it being unauthenticated on a
private network.

## 9. Protocol Version Handling

`PtcRunnerMcp.Version` currently stores the most recently negotiated
version in `:persistent_term`. That is acceptable for one stdio client
but incorrect for multiple independent HTTP sessions.

Concretely, the negotiation API becomes pure:

- `Version.negotiate/1` MUST become side-effect free: it takes the
  client's advertised version and returns the chosen version, with no
  `:persistent_term` write. Today it also stashes the result globally
  (`version.ex` `negotiate/1`); that write is removed.
- `Lifecycle.initialize_reply/1` becomes `Lifecycle.initialize_reply/2`.
  The second argument is the already chosen protocol version. Lifecycle
  reply construction MUST NOT call `Version.negotiate/1`.
- The chosen version is stored on the calling connection/session
  (`Transport.Connection` for stdio, `Http.Session` for HTTP) and
  passed explicitly into dispatch.
- `JsonRpc.dispatch/2` MUST accept a `:protocol_version` option and
  thread it into per-call telemetry/debug metadata. The current
  `JsonRpc.traced_tools_call/3` read of `Version.negotiated/0` is
  replaced by this passed-in value.
- `Version.negotiated/0` (the global getter) is **removed**, not kept
  as a fallback — leaving it invites exactly the cross-session bug this
  section exists to prevent. Stdio passes its own stored version like
  HTTP does. This is part of the Phase 0 refactor.

Server-side HTTP should support:

- primary `2025-11-25`
- compatibility floor `2025-06-18`

Client-side upstream HTTP upgrade from `2025-06-18` to `2025-11-25` is
related but separate. Do not require that upgrade for the first
server-side HTTP PR unless implementation discovers a shared helper must
change.

## 10. Limits and Backpressure

The HTTP path MUST enforce layered limits:

| Limit | Scope | Failure |
|---|---|---|
| request read timeout | per HTTP request | connection dropped (no body read) — slowloris protection |
| request body bytes | per HTTP request | HTTP 413; Bandit enforces the cap during body read, before the handler decodes JSON (deterministic, never a parse error) |
| protocol sessions | global | HTTP 503 with safe JSON-RPC error body when possible |
| protocol sessions per owner | owner | HTTP 429 |
| in-flight requests | per protocol session | MCP `busy` envelope for `tools/call`; HTTP 429 for pre-dispatch overload |
| PTC execution | global | existing `ConcurrencyGate` busy envelope |
| PTC-Lisp stateful sessions | existing `PtcRunnerMcp.Sessions` quotas | existing session tool errors |
| upstream calls per program | existing aggregator config | existing aggregator errors |
| upstream concurrency | upstream connection/pool config | existing upstream behavior |

Per-session in-flight limits are non-queueing. They protect a deployed
service from one client monopolizing all global execution slots. Note
the per-owner interaction: in single-token v1 all clients share one
owner, so the per-session in-flight cap (not the per-owner session cap)
is the main lever preventing one client from saturating the global
`ConcurrencyGate` (see §6 "Flag interactions").

What the per-session in-flight cap counts: it counts JSON-RPC
**requests** currently executing in a per-call worker for that session
(in practice `tools/call`, the only method that spawns a worker).
Notifications, responses, and synchronously-answered methods
(`initialize`, `ping`, `tools/list`, etc.) do not count and are not
capped. When a session is already at its cap:

- a `tools/call` is answered with the existing MCP `busy` envelope
  (`200 OK`), the same envelope `ConcurrencyGate` rejection produces, so
  clients see one consistent backpressure signal;
- `429 Too Many Requests` is reserved for overload detected *before*
  dispatch (e.g. the session GenServer mailbox is saturated) where no
  JSON-RPC envelope can be produced cleanly.

The body cap is enforced by Bandit's configured max request length
during the read; the handler never receives a partial body. The
`--http-request-timeout-ms` read timeout is applied to the combined
header + body read.

Cleanup:

- The registry MUST reap sessions on idle timeout and absolute TTL.
- "Idle" means no request activity. A session with at least one
  in-flight request is **not** idle: `last_seen` is refreshed both when
  a request arrives and when one completes, so a long-running
  `tools/call` cannot be reaped by the idle timer mid-execution.
- The absolute TTL is a hard cap and is **not** refreshed by activity.
  When the TTL elapses with requests still in flight, cleanup cancels
  those workers; each blocked POST then returns the cancelled mapping
  (§8.2). A single `tools/call` is bounded by the sandbox timeout, so in
  practice TTL only interrupts a session, not a healthy call.
- Cleanup MUST cancel in-flight workers and release any acquired global
  permits.
- There are no tombstones to bound (§8.4); a reaped session id simply
  becomes unknown and returns `404`.

## 11. Security Requirements

### 11.1 Binding and TLS

- Default host is `127.0.0.1`.
- "Loopback" means any address in `127.0.0.0/8` or `::1`. The
  `--http-disable-auth` gate and the default origin policy MUST use
  this full definition, not a literal `127.0.0.1` string match.
- Binding to `0.0.0.0` or a non-loopback address requires auth unless
  the explicit `--http-disable-auth --http-allow-unsafe-network` pair
  is set (§6 "Flag interactions").
- A loopback bind is not automatically trusted: on a shared host any
  local user or process can reach the listener. Disabling auth on
  loopback is permitted but warned (§6); a token is still recommended.
- TLS: see §11.5. The primary deployment is a private network, but
  "private" does not mean "plaintext is fine" — the bearer token
  travels on the wire on every request.

### 11.2 Authentication

v1 supports static bearer auth:

```
Authorization: Bearer <token>
```

Rules:

- The configured token MUST be at least 32 characters; `Http.Config`
  rejects shorter tokens at startup. This is a length **floor**, not an
  entropy guarantee — 32 repeated characters would pass the check. The
  server cannot measure entropy, so token strength is an operator
  responsibility: operators MUST generate it from a CSPRNG (e.g.
  `openssl rand -base64 32`). The docs (§16) state this plainly.
  Constant-time comparison does not compensate for a low-entropy token,
  and v1 adds no auth-failure rate limiting, so a strong random token
  is the only brute-force defense (a 256-bit random token is not
  brute-forceable).
- Compare tokens in constant time.
- Missing auth returns `401 Unauthorized` with `WWW-Authenticate:
  Bearer`.
- An invalid or unrecognized token also returns `401 Unauthorized` with
  `WWW-Authenticate: Bearer error="invalid_token"` (RFC 6750). `403`
  is reserved for an authenticated caller that lacks authorization;
  v1 has no such case. Using `401` for both missing and bad tokens also
  avoids a presence oracle.
- Logs contain only auth result and owner hash, never token bytes.
- Owner identity defaults to a stable hash of the accepted token unless
  a future auth provider supplies a stronger subject. In single-token
  v1 this means every client resolves to the same owner.
- Ownership enforcement: every session-scoped request (`POST` with a
  session id, `DELETE`) MUST be checked so the request's authenticated
  owner equals the session's owner. A mismatch returns `404 Not Found`
  (§8.2, §8.4) so the response does not confirm the id exists. This is
  a no-op while one shared token is in use, but it is a hard
  requirement now so a leaked session id (via a proxy log, edge
  appliance, or error report) cannot be used cross-owner once
  multi-token auth lands.
- Threat-model honesty for v1: with a single shared token, every client
  is the same owner, so the owner check above provides **no isolation
  between clients**. An `MCP-Session-Id` is effectively a bearer
  capability scoped only by the shared token — any holder of the token
  who learns another client's session id can drive or `DELETE` that
  session. The mitigations are (a) cryptographically random,
  unguessable session ids (§7.3), (b) never logging raw session ids
  (§8.1), and (c) treating the shared token as the real trust boundary.
  Deployments that need true per-client isolation MUST wait for
  multi-token auth (§13 #2) and SHOULD treat single-token v1 as
  "one trusted application, possibly many of its own sessions".

### 11.3 Origin Validation

When `Origin` is present:

- If allowed origins are configured, exact-match against them.
- If no allowed origins are configured and the bind host is loopback,
  allow only loopback origins (`http://localhost`,
  `http://127.0.0.1`, `http://[::1]`, with or without an explicit
  port).
- If no allowed origins are configured and the bind host is
  **non-loopback**, any present `Origin` is rejected with `403`. A
  browser hitting a non-loopback deployment without an explicit
  allow-list is exactly the DNS-rebinding case this check defends
  against; the operator must opt in via `--http-allowed-origin`.
- Any other present-but-unmatched `Origin` returns `403 Forbidden`.

Origin comparison MUST be normalized before matching: lowercase scheme
and host, strip a default port (`80` for `http`, `443` for `https`),
keep IPv6 brackets, and treat the literal `null` origin as unmatched
(rejected unless explicitly allow-listed). Matching is on the
scheme+host+port triple only; path and query are ignored.

This follows the MCP Streamable HTTP security guidance for DNS rebinding
protection. Non-browser clients (the primary v1 target) simply omit
`Origin`; this is expected and not rejected, because DNS rebinding is a
browser-only threat and non-loopback exposure is defended by auth, not
by `Origin`.

Browser clients are **not** a v1 target. v1 therefore does **not**
implement CORS: it sends no `Access-Control-Allow-*` headers and does
not handle `OPTIONS` preflight. `--http-allowed-origin` exists purely
for the DNS-rebinding check above, not to enable cross-origin browser
access. A browser-based MCP client is a documented v2 follow-up that
would add preflight handling and CORS response headers.

### 11.4 Upstream Access Policy

HTTP MCP sessions MUST carry an owner identity. Upstream access policy is
global in v1 unless a separate tenant-policy spec is added.

Recommended v1 posture:

- `--aggregator-read-only` remains the default safe posture for agentic
  deployments.
- Write-capable upstream configurations require explicit existing flags.
- Future tenant-scoped upstream permissions should attach to the HTTP
  session owner, not to a PTC-Lisp session id.

### 11.5 Private-Network Deployment Posture

The primary deployment target is a secure private network (VPC private
subnet or equivalent), not the public internet. That shapes the v1
security model:

- **The network is the outer boundary; the bearer token is the inner
  boundary.** The listener should be reachable only from a small set of
  peers — a load balancer, the agentic application(s), and a metrics
  scraper — enforced at the security-group / firewall layer, not by the
  application. The application contributes auth (§11.2), origin checks
  (§11.3), and limits (§10).
- **TLS is still recommended inside the private network.** "Private"
  stops outside attackers, not a compromised peer or a passive sniffer
  on the same subnet, and the bearer token travels on every request. v1
  supports TLS at the edge (load balancer terminates TLS, re-encrypts
  or runs plaintext on an isolated link). Direct TLS in Bandit
  (`--http-tls-cert` / `--http-tls-key`) MAY be added; if it is not in
  the first PR, the deployment docs (§16) MUST state plainly that
  plaintext intra-network traffic exposes the token to anything that
  can observe the subnet.
- **Unauthenticated ops endpoints (`/health`, `/ready`, `/metrics`) are
  acceptable only because of the network boundary.** They expose
  liveness and aggregate counts/hashes, never tokens, programs, raw
  ids, or upstream data. On a network where the scraper and LB cannot
  be isolated from untrusted peers, restrict these paths at the
  firewall.
- **Per-instance identity.** Behind a load balancer, several nodes look
  identical. `--http-instance-label` (§6.1) stamps every log line,
  telemetry event, metric, and trace record so an operator can attribute
  a problem to a specific node.

## 12. Observability

Observability has five layers. The first four reuse existing server
machinery (`PtcRunnerMcp.Log`, `:telemetry`, `TraceConfig`,
`DebugBuffer`); HTTP adds events and endpoints, it does not invent a new
stack. Everything is designed for a deployed multi-client node, so every
record is per-instance, per-owner, and per-session attributable.

### 12.1 Structured Logs

- HTTP events are logged through the existing `PtcRunnerMcp.Log`
  JSON-Lines logger to **stderr** (one JSON object per line, already
  passed through `Credentials.Redactor`). stdout carries MCP frames in
  stdio mode and is simply unused by the HTTP listener; keeping logs on
  stderr is consistent across both transports and works with container
  log collectors.
- Every HTTP log line carries: `ts`, `level`, `event`, `instance`
  (`--http-instance-label`), `request_id`, and a `fields` object with
  `method`, `path`, `status`, `duration_ms`, `owner_hash`,
  `session_hash` when present.
- Request correlation: the router honors an inbound `X-Request-Id`
  header when present (validated for shape/length), otherwise generates
  one. The id is echoed in the response `X-Request-Id` header, attached
  to every log line and telemetry event for that request, and written
  into the per-call trace record (§12.4).
- Log level is the existing process-wide `--log-level`; no HTTP-specific
  level. `info` logs request start/stop, session lifecycle, limit
  rejections, and auth failures; `debug` adds the compatibility events
  (§8.2).
- The §8.1 redaction rules apply: never log `Authorization`, raw
  `MCP-Session-Id`, cookies, the configured token, or upstream headers.

### 12.2 Telemetry Events

Emit `:telemetry` events with sanitized metadata. Every event also
carries `instance` and `request_id`:

| Event | Measurements | Metadata |
|---|---|---|
| `[:ptc_runner_mcp, :http, :request, :start]` | `system_time` | method, path, owner_hash, session_hash if present |
| `[:ptc_runner_mcp, :http, :request, :stop]` | `duration` | method, path, status, owner_hash, session_hash, error_class |
| `[:ptc_runner_mcp, :http, :session, :created]` | `count` | owner_hash, session_hash, protocol_version |
| `[:ptc_runner_mcp, :http, :session, :closed]` | `age_ms` | owner_hash, session_hash, reason |
| `[:ptc_runner_mcp, :http, :auth, :failure]` | `count` | reason, remote_ip_hash if available |
| `[:ptc_runner_mcp, :http, :limit, :rejected]` | `count` | limit_name, owner_hash, session_hash |
| `[:ptc_runner_mcp, :http, :cancelled]` | `count` | owner_hash, session_hash, reason (`client`, `disconnect`, `ttl`, `shutdown`) |

Do not include request bodies, programs, context, auth tokens, raw
session ids, or upstream secrets in any measurement or metadata.

These events are the single source of truth. Metrics (§12.3) are derived
from them when the optional Prometheus endpoint is built; consumers that
prefer their own collector can attach a handler without scraping
`/metrics`.

### 12.3 Metrics Endpoint

The §12.2 telemetry events ship with core HTTP and are the source of
truth. The Prometheus exposition endpoint is a cleanly separable
fast-follow: `--http-metrics`, `GET /metrics`, `:telemetry_metrics`, and
the Prometheus reporter dependencies are deferred to Phase 4b unless
they are explicitly pulled into the same implementation PR.

When `--http-metrics` is built, the §12.2 telemetry events are
aggregated via `:telemetry_metrics` and exposed as Prometheus exposition
at `GET /metrics` (§8.7). Target metric set:

| Metric | Type | Labels |
|---|---|---|
| `ptc_http_requests_total` | counter | method, status |
| `ptc_http_request_duration_ms` | histogram | method, status |
| `ptc_http_sessions_active` | gauge | — |
| `ptc_http_sessions_total` | counter | event (`created`/`closed`), reason |
| `ptc_http_in_flight` | gauge | — |
| `ptc_http_limit_rejected_total` | counter | limit_name |
| `ptc_http_auth_failures_total` | counter | reason |
| `ptc_http_cancelled_total` | counter | reason |
| `ptc_concurrency_gate_saturation` | gauge | — (acquired / capacity from `ConcurrencyGate`) |
| `ptc_lisp_execute_duration_ms` | histogram | outcome — from the existing `:ptc_runner` lifecycle events |

All series carry an `instance` label. `owner_hash` / `session_hash`
deliberately do **not** become metric labels — unbounded label
cardinality from many clients would blow up the time-series database;
they stay in logs and traces for drill-down. `/metrics` exposes no
token, program, context, or raw id.

### 12.4 Per-Call Tracing

The existing opt-in `--trace-dir` JSONL tracing works in HTTP mode
unchanged in shape, with two added fields per record so a multi-client
node's traces are separable: `mcp_session_hash` and `owner_hash` (plus
the existing `request_id`, which is now the HTTP correlation id from
§12.1). `--trace-payloads` (`none` / `summary` / `full`) and the
`--trace-max-files` FIFO cap behave as today; §6.1 notes the cap churns
faster under many clients. `ptc_viewer` reads these files as-is.

### 12.5 `ptc_debug` in HTTP Mode

`ptc_debug` exposes the recent-calls ring buffer (`DebugBuffer`). That
buffer is **per node**, not per session. In a multi-client HTTP
deployment, an unscoped `ptc_debug` would let one client read another
client's programs, contexts, and results — a cross-client data leak.
Therefore in HTTP mode:

- `ptc_debug` MUST be either owner-scoped (a caller sees only ring
  entries whose `owner_hash` matches its own authenticated owner) or
  disabled by default and enabled only by an explicit operator flag.
- v1 chooses **disabled by default in HTTP mode**; owner-scoped
  `ptc_debug` is a follow-up that depends on multi-token auth being
  meaningful (with one shared token, owner-scoping is a no-op anyway).
- This is independent of `--trace-dir`, which writes operator-only
  files and is not reachable by MCP clients.

### 12.6 Health and Readiness

Liveness (`/health`, §8.5) and readiness (`/ready`, §8.6) are the
orchestrator-facing signals. The operator monitoring stack should alert
on: `/ready` returning `503` for longer than one deploy window,
`ptc_http_auth_failures_total` rising (possible token probing),
`ptc_concurrency_gate_saturation` pinned at capacity, and
`ptc_http_sessions_active` near `--http-max-sessions`.

## 13. Resolved Decisions

The draft's open questions were resolved 2026-05-16 (rev 3):

1. **Stdio in HTTP mode** — Disabled by default when `--http` is set
   (§7.4). A network service must not depend on stdin EOF. `--stdio`
   stays an optional future flag.
2. **Multiple auth tokens** — A single `--http-auth-token` is
   sufficient for v1. Multi-token auth with explicit owner labels is a
   v2 follow-up; §11.2's ownership-enforcement requirement is in place
   now so it lands safely.
3. **Direct TLS** — Not required in the first PR. TLS at the deployment
   edge is sufficient; direct Bandit TLS may be documented if trivially
   supported (§11.1).
4. **Missing `Accept` header** — Compatibility warning, not a hard
   `406` (§8.2). v1 accepts narrow/missing `Accept` and logs a
   debug-level compatibility event.
5. **`initialize` with an existing `MCP-Session-Id`** — Reject with
   `400 Bad Request` (§8.2). Re-init is a client bug; creating a second
   session would orphan the first.
6. **Stdio migration scope** — The Phase 0 refactor (extract
   `Transport.Connection`, prove stdio unchanged) ships as its own PR
   before the HTTP PRs, to keep each diff reviewable and isolate
   regression risk (§14).
7. **Version negotiation ownership** — `Transport.Connection` owns
   negotiation state. `Version.negotiate/1` is pure,
   `Lifecycle.initialize_reply/2` receives the chosen version, and the
   implementation must not reverse-parse protocol version from a reply
   map (§7.1, §9).
8. **Cancellation envelope** — cancelled `tools/call` results reuse
   `Envelope.error_envelope/1` with a new `reason: "cancelled"` payload;
   the JSON-RPC `-32800` path remains only for non-tool completeness
   (§8.2).
9. **HTTP worker await timeout** — use a central helper keyed by the
   specific tool budget. The Plug await timeout strictly exceeds the
   worker budget, so normal tool timeout envelopes win the race (§7.1).
10. **Metrics split** — structured logs and telemetry events remain in
   core HTTP. Prometheus `/metrics` and the extra dependencies are
   Phase 4b unless deliberately included in the same PR (§12.3, §14).
11. **PTC-Lisp session cleanup trigger** — add a narrow
   `Sessions.close_owner/1` API and call it from
   `Http.SessionRegistry`'s monitored `:DOWN` path, not as a
   correctness dependency on `Http.Session.terminate/2` (§7.3).

## 14. Implementation Plan

### Phase 0 - Prep and Refactor (separate PR)

Ships as its own PR before the HTTP work (§13 #6) so the
behavior-preserving refactor is reviewed in isolation.

- Add `PtcRunnerMcp.Transport.Connection`.
- Move in-flight worker tracking, cancellation, drain, exit, and
  duplicate-request-id rejection out of `Stdio` without changing
  stdio's observable behavior.
- Expose the transport-neutral `{:cancelled, request_id, connection}`
  outcome and a per-transport emission hook (§7.1). Stdio's hook maps
  `:cancelled` to no write — identical to today.
- Make `Version.negotiate/1` pure, let `Transport.Connection` store the
  chosen version, change `Lifecycle.initialize_reply/1` to
  `Lifecycle.initialize_reply/2`, thread the negotiated version through
  dispatch metadata, and remove `Version.negotiated/0` and its
  `:persistent_term` write (§7.1, §9).
- Add the `reason: "cancelled"` envelope support to `Envelope` and keep
  stdio's cancellation emission policy unchanged (§8.2).
- Add tests proving stdio behavior is unchanged.

### Phase 1 - HTTP Skeleton

- Move `:bandit` and `:plug` to runtime dependencies.
- Add HTTP config parsing and validation, including minimum token
  length and the §6 flag-interaction checks.
- Split the supervision tree. Today `Application.start/2` only builds
  children when `attach_stdio?/0` is true. HTTP mode must start
  credentials, the upstream supervisor, `Sessions`, the debug buffer,
  any registries, and Bandit **without** stdio. Factor the shared
  children out so `--http`, `--stdio`, and stdio-default modes each
  compose the children they need (§6 Supervision).
- Add Bandit child spec (request-read timeout, shutdown drain) and Plug
  router.
- Add `/mcp` with GET 405 and DELETE placeholder behavior.
- Add `GET /health` and `GET /ready` (unauthenticated, §8.5/§8.6).
- Add auth and origin checks.
- Add request correlation: honor/generate `X-Request-Id` (§12.1).

### Phase 2 - HTTP Sessions and POST

- Add `Http.SessionRegistry` and `Http.Session`.
- Implement initialize session creation and `MCP-Session-Id` response
  header; reject `initialize` carrying a session id with `400`.
- Implement subsequent POST routing by session id, including the
  owner-match check (§11.2) returning `404` on mismatch.
- Implement notification/response `202` handling.
- Implement request `200 application/json` handling, including the
  cancelled / crashed / timeout reply mappings (§8.2).
- Add `worker_await_timeout_ms/1` and verify the await timeout strictly
  exceeds each async tool's own execution budget (§7.1).
- Implement missing/stale session id responses.

### Phase 3 - Limits, Cleanup, Cancellation

- Add max body, max sessions, max sessions per owner, per-session
  in-flight caps.
- Add idle and TTL cleanup.
- Add `Sessions.close_owner/1` and wire DELETE cleanup and cancellation
  through `Http.SessionRegistry`'s monitored session shutdown path
  (owner-checked).
- Wire HTTP server shutdown drain (§7.5).
- Verify permits release on normal completion, cancellation, worker
  crash, HTTP client disconnect, session cleanup, and shutdown drain.

### Phase 4 - Observability and Hardening

- Add the §12.2 telemetry events and §12.1 structured HTTP logs
  (instance label, request id, sanitized fields).
- Extend per-call trace records with `mcp_session_hash` / `owner_hash`
  (§12.4).
- Disable `ptc_debug` by default in HTTP mode (§12.5).
- Add redaction checks for auth token, raw session id, and upstream
  headers across logs, telemetry, metrics, and traces.
- Add soak tests for session churn and concurrent clients.

### Phase 4b - Prometheus Metrics Endpoint

- Add `GET /metrics` behind `--http-metrics`, with the §12.3 metric set.
- Pull in `:telemetry_metrics` and the Prometheus reporter as runtime
  dependencies only when this endpoint ships.
- Keep `owner_hash` and `session_hash` out of metric labels.

### Phase 5 - Deployment Documentation

- Write `docs/mcp-server-http-deployment.md` (§16) — the private-network
  deployment runbook.
- Update `docs/mcp-server.md`, `docs/mcp-server-configuration.md`,
  `docs/mcp-debug.md`, and `mcp_server/README.md` (§16).
- Add release notes distinguishing the transport/session concepts.

### 14.1 Phase Gates and Review Plan

Each phase should land with a small implementation checklist and a
requirements coverage note that lists the IDs from §18 that are complete
or intentionally deferred. Do not start the next phase until the gate
for the previous phase is green.

| Gate | Required verification | Independent Codex review |
|---|---|---|
| Phase 0 | Existing stdio lifecycle/cancellation/frame-cap/release tests pass; no HTTP listener yet. | **Required, high effort.** Review the behavior-preserving refactor because it touches worker ownership, cancellation, permit release, and version state. |
| Phase 1 | HTTP starts only with `--http`; stdio default unchanged; config/auth/origin/health/ready/router skeleton tests pass. | Recommended if supervision or config parsing is large; required if release boot behavior changes beyond child composition. |
| Phase 2 | Two HTTP sessions can initialize and run request/notification/response flows; protocol version is per session; cancelled/crash/timeout mappings are implemented. | **Required, high effort.** Review session ownership, POST await semantics, version isolation, and response mappings. |
| Phase 3 | Limit, cleanup, DELETE, disconnect, TTL/idle, shutdown drain, and permit-leak tests pass under concurrency. | **Required, high effort plus adversarial challenge if time allows.** This is the highest-risk service-hardening phase. |
| Phase 4 | Logs/telemetry/traces/redaction/`ptc_debug` tests pass; soak tests are stable enough for CI or documented manual runs. | Required if redaction or trace/debug payload paths changed; otherwise recommended. |
| Phase 4b | Prometheus endpoint tests pass; dependency footprint is accepted; no high-cardinality labels. | Recommended, focused on dependency/runtime impact and cardinality/security. |
| Phase 5 | Docs match shipped flags and behavior; quickstart works against the release. | Optional docs review unless deployment guidance changed security posture. |

Use the `codex-review` skill command from the repo root at required
gates:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review review
```

For Phase 3, run an adversarial pass after the normal review when the
diff is stable:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review challenge --effort xhigh
```

### 14.2 Subagent Work Packages

Subagents may implement or investigate bounded, disjoint slices, but the
main implementer remains responsible for integration, review findings,
and the final requirements coverage note. Good work packages:

| Package | Phase | Write scope | Notes |
|---|---:|---|---|
| Transport extraction | 0 | `transport/*`, `stdio.ex`, focused tests | Keep stdio behavior unchanged; no HTTP code. |
| Version cleanup | 0 | `version.ex`, `lifecycle.ex`, `json_rpc.ex`, tests | Can be parallel only if coordinated with transport extraction. |
| Config/auth/origin | 1 | `http/config.ex`, `http/auth.ex`, `http/origin.ex`, tests | Pure modules; low conflict with router work. |
| Router/server skeleton | 1 | `http/router.ex`, `http/server.ex`, `application.ex`, tests | Owns Plug/Bandit integration and supervision composition. |
| Session registry | 2-3 | `http/session_registry.ex`, `sessions/*`, tests | Owns quotas, monitoring, cleanup, `Sessions.close_owner/1`. |
| HTTP session execution | 2-3 | `http/session.ex`, transport hooks, tests | Owns POST await semantics, cancellation, disconnect, drain. |
| Observability | 4 | `http/telemetry.ex`, log/trace changes, tests | Keep payloads sanitized; avoid metric endpoint until Phase 4b. |
| Metrics endpoint | 4b | metrics modules, deps, router tests | Isolated fast-follow; no core HTTP behavior changes. |
| Deployment docs | 5 | docs and README only | Must be updated from actual implemented flags. |

Workers are not alone in the codebase: each package must avoid reverting
other edits and must list touched files and completed requirement IDs in
its handoff.

## 15. Test Plan

Unit tests:

- HTTP config parsing and unsafe-combination rejection.
- Minimum token length rejected at startup.
- Single-token per-owner-cap-below-global-cap warning.
- `--http-path` equal to `/health` rejected at startup.
- Loopback detection covers `127.0.0.0/8` and `::1`.
- Auth success/failure and constant-time compare behavior.
- Origin validation.
- Session id generation shape and uniqueness.
- Session registry quota, lookup, idle cleanup, TTL cleanup.
- Protocol version stored per HTTP session.

Router/integration tests:

- `GET /mcp` returns 405 with `Allow: POST, DELETE`.
- `GET /health` returns 200 without auth.
- `GET /ready` returns 200 normally and 503 while draining / saturated.
- `/health`, `/ready`, `/metrics`, `--http-path` collision rejected at
  startup.
- `POST initialize` returns JSON response and `MCP-Session-Id`.
- `POST initialize` carrying a session id returns 400.
- Subsequent POST without session id returns 400.
- POST with bad session id returns 404.
- POST with a session id owned by a different owner returns 404.
- POST with invalid protocol version returns 400.
- POST with missing `MCP-Protocol-Version` falls back to the session
  version and logs a compatibility event.
- POST with a JSON-RPC response object is consumed and returns 202
  (not dispatched as a method).
- Notification returns 202.
- Duplicate in-flight request id returns 200 with a `-32600` error.
- Invalid JSON / invalid UTF-8 body returns 200 with `-32700`; a
  non-object JSON value returns 200 with `-32600`; an empty body
  returns 400 (§8.2 malformed-input table).
- DELETE closes session and later POST returns 404.
- DELETE of another owner's session returns 404 and does not close it.
- Request body over cap is rejected with 413 before JSON decode.
- Auth/origin header checks reject before the body is read (§8.1).
- Auth missing returns 401; bad token returns 401 with
  `WWW-Authenticate: Bearer error="invalid_token"`.
- Invalid Origin returns 403; a present Origin on a non-loopback bind
  with no allow-list returns 403.
- Shutdown-draining listener returns 503 with the §7.5 JSON-RPC body.

Concurrency tests:

- Two initialized HTTP clients can call `ptc_lisp_execute` concurrently.
- Per-session in-flight cap rejects excess requests from one session
  without blocking another session.
- Global `ConcurrencyGate` still rejects above global cap.
- `notifications/cancelled` kills the correct session's worker only,
  and the blocked POST returns the cancelled reply mapping (§8.2).
- A worker crash maps the blocked POST to a `-32603` JSON-RPC error.
- HTTP client disconnect mid-call cancels the worker and releases permits.
- Session cleanup cancels only that session's in-flight workers.
- Shutdown drain lets in-flight workers finish, then cancels the rest;
  no permits leak.
- The session process answers a `notifications/cancelled` POST and a
  `DELETE` while one of its own requests is still in flight (proves the
  session GenServer never blocks on worker completion, §7.1).
- A request in flight past the idle timeout is not reaped; the same
  request is pre-empted when the absolute TTL elapses (§10 cleanup).

Isolation tests:

- Lifecycle state is independent across HTTP sessions.
- Shutdown/drain in one HTTP session does not drain another session.
- PTC-Lisp stateful sessions are not implicitly shared between HTTP
  sessions.
- Upstream call audit entries remain scoped and sanitized.

Observability tests:

- `/ready` flips to 503 before `/health` changes, when drain begins.
- An inbound `X-Request-Id` is echoed in the response and appears in
  the log line for that request; a generated one appears when absent.
- §12.2 telemetry events fire with the documented measurements and
  carry `instance` + `request_id`; no event leaks token/program/raw id.
- With `--http-metrics`, `/metrics` serves Prometheus text; counters
  and the in-flight/active-sessions gauges move under load; no
  `owner_hash`/`session_hash` label appears (cardinality guard).
- HTTP log lines and trace records are run through `Credentials.Redactor`
  and contain no `Authorization`, raw `MCP-Session-Id`, or token bytes.
- Trace records in HTTP mode carry `mcp_session_hash` + `owner_hash`.
- `ptc_debug` is disabled by default in HTTP mode (§12.5).
- A path collision among `/mcp`, `/health`, `/ready`, `/metrics` is
  rejected at startup.

Regression tests:

- Existing stdio lifecycle, cancellation, frame cap, and release tests
  pass unchanged.
- Existing upstream HTTP tests remain pinned to their current protocol
  behavior unless separately upgraded.

Soak tests:

- Session churn with thousands of initialize/DELETE cycles.
- Concurrent client load at configured caps.
- Long-running cancelled calls do not leak permits or processes.

## 16. Documentation Impact

The docs split into one new deployment runbook plus targeted updates to
existing files. The runbook is the centerpiece because the primary use
case is a deployed private-network service, not a local tool.

### 16.1 New: `docs/mcp-server-http-deployment.md`

The private-network deployment runbook. Sections:

1. **When to use HTTP mode** — one deployed node, many agentic clients,
   close to upstream MCP servers; contrast with stdio (local, one
   client). Point back to `docs/mcp-server.md`.
2. **Topology** — a diagram: clients → internal load balancer (TLS
   terminate) → one or more `ptc_runner_mcp` nodes in a private subnet;
   metrics scraper inside the network; upstream MCP servers reachable
   from the nodes. Name the trust boundaries (§11.5).
3. **Minimum secure config** — the flag set for a real deployment:
   `--http --http-host 0.0.0.0 --http-port 7332`, a CSPRNG bearer token
   from a secret manager injected as `PTC_RUNNER_MCP_HTTP_AUTH_TOKEN`,
   `--http-instance-label`, `--aggregator-read-only`, and the limit
   flags. Explicitly call out which flags are security-relevant.
4. **TLS** — edge termination vs direct Bandit TLS; the explicit warning
   that plaintext intra-network traffic exposes the bearer token
   (§11.5).
5. **Health, readiness, rolling deploys** — wire the load-balancer
   health check to `/ready` and the orchestrator liveness probe to
   `/health`; explain why (§8.5/§8.6) and walk through one zero-downtime
   rolling deploy step by step (drain → `/ready` 503 → in-flight finish
   → exit).
6. **Monitoring** — enable `--http-metrics`, scrape `/metrics`, the
   §12.3 metric set, the alert thresholds from §12.6, and how to read
   structured logs (`instance`, `request_id` correlation).
7. **Tracing** — `--trace-dir` in HTTP mode, the per-session/per-owner
   trace fields (§12.4), `ptc_viewer`, and the `--trace-max-files`
   churn caveat.
8. **Operations** — secret/token rotation procedure, capacity planning
   against `--http-max-sessions` and the global `ConcurrencyGate`, and a
   failure-mode table (auth failures climbing, sessions near cap, gate
   saturated, drain not completing).
9. **Limits reference** — the §10 layered-limits table with the flag
   that tunes each.

### 16.2 Updates to existing docs

- `docs/mcp-server.md` — extend the **Security model** section with the
  HTTP trust boundary (§11.5: network boundary + bearer token + TLS),
  and add HTTP to the transport overview; link to the new runbook.
- `docs/mcp-server-configuration.md` — new **HTTP transport** section
  for the §6 flags and a **HTTP observability** section for the §6.1
  flags; cross-link the runbook. The existing **Tracing** section gains
  the HTTP per-session/per-owner trace fields.
- `docs/mcp-debug.md` — document that `ptc_debug` is disabled by default
  in HTTP mode and why (§12.5 cross-client leak).
- `mcp_server/README.md` — a short HTTP quickstart (a few lines) plus a
  link to the runbook; keep README onboarding-only per the repo doc
  guidelines.
- Release notes — spell out the four distinct concepts so they are not
  confused: stdio transport, server-side HTTP transport, client-side
  upstream HTTP, HTTP MCP protocol sessions, and PTC-Lisp stateful
  sessions.

### 16.3 Reference deployment

The runbook includes one concrete worked example (AWS-style, but the
shape generalizes to any private network):

- private subnet, internal load balancer terminating TLS
- security group: `:7332` reachable only from the LB and the
  application hosts; `/metrics` reachable only from the scraper host
- bearer token from a secret manager, injected as an env var, never on
  the command line
- `--http --http-host 0.0.0.0 --http-port 7332 --http-metrics
  --http-instance-label $TASK_ID`
- load-balancer health check → `/ready`; orchestrator liveness → `/health`
- read-only aggregator posture by default
- non-browser MCP clients only; browser clients and CORS are out of
  scope for v1 (§11.3)

## 17. Acceptance Criteria

The feature is complete when:

- Existing stdio behavior and tests are unchanged.
- A release can start with `--http` and serve `/mcp`.
- `GET /health` (liveness) and `GET /ready` (readiness) answer without
  auth; `/ready` flips to 503 on drain before `/health` changes.
- At least two independent HTTP MCP clients can initialize and call
  `ptc_lisp_execute` concurrently.
- Session ids are issued, required after initialize, and deleted by
  DELETE.
- Session-scoped requests are owner-checked; a mismatched owner gets
  `404`.
- Per-session and global limits are enforced.
- Cancellation is isolated to the correct session/request, and the
  blocked POST returns a defined reply (cancelled / crash / timeout).
- Missing and bad auth both return `401`; invalid origin returns `403`.
- The HTTP listener drains in-flight work on shutdown without leaking
  permits or processes.
- HTTP requests are correlatable end to end via `X-Request-Id` across
  logs, telemetry, and traces; every record carries the instance label.
- With `--http-metrics`, `/metrics` serves the §12.3 metric set with no
  high-cardinality owner/session labels.
- `ptc_debug` is disabled by default in HTTP mode.
- Logs, telemetry, metrics, and traces do not include bearer tokens,
  raw session ids, programs, context payloads, or upstream secrets.
- GET `/mcp` explicitly returns 405 with tests.
- The `docs/mcp-server-http-deployment.md` runbook exists and covers
  secure private-network deployment, health/readiness wiring,
  monitoring, tracing, and v1 non-goals.

## 18. Requirements Traceability

Every implementation PR MUST include a short "Requirements coverage"
section that lists completed IDs, deferred IDs, and tests or manual
checks used for each completed ID. Requirement IDs are stable; if a
requirement changes meaning, add a new ID and mark the old one
superseded rather than reusing it.

| ID | Requirement | Source | Phase | Verification |
|---|---|---|---:|---|
| REQ-HTTP-001 | HTTP transport is opt-in; stdio default behavior remains unchanged. | §1, §6, §7.4 | 1 | Release/app boot tests plus existing stdio regression tests. |
| REQ-HTTP-002 | `--http` mode starts shared MCP dependencies without attaching stdio by default. | §6, §7.4 | 1 | Supervision composition and release boot tests. |
| REQ-HTTP-003 | Runtime config supports all HTTP flags and validates unsafe combinations. | §6, §11.1 | 1 | Config unit tests. |
| REQ-HTTP-004 | `/mcp` path supports POST and DELETE; GET returns 405 with `Allow: POST, DELETE`. | §8.2, §8.3, §8.4 | 1-2 | Router tests. |
| REQ-HTTP-005 | `/health` and `/ready` are unauthenticated and distinct; readiness flips to 503 on drain or saturation. | §8.5, §8.6 | 1,3 | Router and drain/saturation tests. |
| REQ-AUTH-001 | Static bearer auth enforces 32-character token floor and constant-time validation. | §11.2 | 1 | Auth/config unit tests. |
| REQ-AUTH-002 | Missing and bad auth return 401 with RFC 6750 `WWW-Authenticate` behavior. | §11.2 | 1 | Router auth tests. |
| REQ-AUTH-003 | Session-scoped requests check authenticated owner and return 404 on owner mismatch. | §8.2, §8.4, §11.2 | 2 | Cross-owner session tests. |
| REQ-ORIGIN-001 | Origin validation follows loopback/default/non-loopback allow-list rules. | §11.3 | 1 | Origin unit and router tests. |
| REQ-TRANSPORT-001 | `Transport.Connection` owns lifecycle, in-flight workers, cancellation, duplicate ids, drain, and exit. | §7.1 | 0 | Stdio regression and transport unit tests. |
| REQ-TRANSPORT-002 | HTTP does not duplicate stdio worker/cancellation logic. | §7.1 | 0-2 | Code review plus shared runner tests. |
| REQ-TRANSPORT-003 | Transport-specific cancellation emission preserves stdio no-reply and maps HTTP to a cancelled response. | §7.1, §8.2 | 0,2 | Stdio cancellation tests and HTTP cancellation tests. |
| REQ-VERSION-001 | `Version.negotiate/1` is pure and `Version.negotiated/0` is removed. | §9 | 0 | Version/unit tests and grep/code review. |
| REQ-VERSION-002 | `Transport.Connection` stores negotiated version and passes it into `Lifecycle.initialize_reply/2` and dispatch metadata. | §7.1, §9 | 0,2 | Initialize and telemetry/debug metadata tests. |
| REQ-VERSION-003 | HTTP sessions isolate negotiated protocol versions from each other. | §9 | 2 | Multi-session protocol-version tests. |
| REQ-POST-001 | POST classifies request/notification/response before dispatch. | §8.2 | 2 | Router/session tests for all three classes. |
| REQ-POST-002 | Malformed POST inputs map deterministically to the documented HTTP/JSON-RPC statuses. | §8.2 | 2 | Router malformed-input tests. |
| REQ-POST-003 | Initialize without session id creates a session and returns `MCP-Session-Id`. | §8.2 | 2 | Initialize integration test. |
| REQ-POST-004 | Re-initialize with an existing `MCP-Session-Id` returns 400. | §8.2 | 2 | Router/session test. |
| REQ-POST-005 | Subsequent POST requires a known session id and validates `MCP-Protocol-Version`. | §8.2 | 2 | Missing/stale/bad-version tests. |
| REQ-POST-006 | JSON-RPC requests always return one JSON response; notifications and responses return 202. | §7.1, §8.2 | 2 | Request/notification/response tests. |
| REQ-POST-007 | Worker crash, timeout, and cancellation map to documented response frames. | §8.2 | 2-3 | Crash/timeout/cancel tests. |
| REQ-POST-008 | Plug await timeout is a backstop and strictly exceeds the worker's own tool budget. | §7.1 | 2 | Unit tests for helper plus long-call integration. |
| REQ-SESSION-001 | Session ids are cryptographically strong visible ASCII. | §7.3 | 2 | Shape/uniqueness tests. |
| REQ-SESSION-002 | HTTP MCP sessions are distinct from PTC-Lisp stateful sessions. | §1, §7.3 | 2-3 | Isolation tests. |
| REQ-SESSION-003 | Registry enforces global and per-owner session caps. | §10 | 3 | Registry quota tests. |
| REQ-SESSION-004 | DELETE closes only an owned session and returns 202; unknown/mismatched sessions return 404. | §8.4 | 3 | DELETE integration tests. |
| REQ-SESSION-005 | Idle and TTL cleanup reap sessions according to documented semantics. | §10 | 3 | Timer/cleanup tests. |
| REQ-SESSION-006 | `Http.SessionRegistry` monitor cleanup calls `Sessions.close_owner/1` for PTC-Lisp session owners. | §7.3 | 3 | Registry DOWN-path tests. |
| REQ-LIMIT-001 | Request body cap and read timeout protect body reads before JSON decode. | §8.1, §10 | 1,3 | Router/body-cap tests and timeout config tests. |
| REQ-LIMIT-002 | Per-session in-flight cap is non-queueing and returns consistent busy/backpressure behavior. | §10 | 3 | Concurrency tests. |
| REQ-LIMIT-003 | Global `ConcurrencyGate` behavior and permit release remain correct. | §10 | 0,3 | Existing gate tests plus cancellation/disconnect leak tests. |
| REQ-DRAIN-001 | JSON-RPC shutdown drains one HTTP session only. | §7.5, §15 | 2-3 | Isolation tests. |
| REQ-DRAIN-002 | Application shutdown flips readiness, stops new work, drains accepted work, then cancels remaining workers. | §7.5, §8.6 | 3 | Shutdown-drain integration tests. |
| REQ-DISCONNECT-001 | HTTP client disconnect cancels the worker and releases permits. | §8.2 | 3 | Disconnect integration test. |
| REQ-OBS-001 | HTTP logs include instance/request/session/owner-safe metadata and no sensitive raw values. | §12.1 | 4 | Log/redaction tests. |
| REQ-OBS-002 | HTTP telemetry events emit documented measurements and sanitized metadata. | §12.2 | 4 | Telemetry tests. |
| REQ-OBS-003 | Trace records include `mcp_session_hash` and `owner_hash`, never raw session ids or tokens. | §12.4 | 4 | Trace/redaction tests. |
| REQ-OBS-004 | `ptc_debug` is disabled by default in HTTP mode. | §12.5 | 4 | Tool listing/call tests. |
| REQ-METRICS-001 | Optional `/metrics` exposes the target Prometheus metrics with bounded labels. | §12.3 | 4b | Metrics endpoint/cardinality tests. |
| REQ-DOC-001 | Deployment runbook documents private-network topology, TLS posture, health/readiness, monitoring, tracing, operations, and limits. | §16.1 | 5 | Docs review. |
| REQ-DOC-002 | Existing docs and README distinguish stdio, server HTTP, upstream HTTP, HTTP protocol sessions, and PTC-Lisp sessions. | §16.2 | 5 | Docs review. |

### 18.1 Coverage Checklist Template

Use this template in PR descriptions and in final implementation notes:

```text
Requirements coverage:
- Completed: REQ-...
- Deferred: REQ-... (reason)
- Verification: mix test path/to/test.exs ...
- Independent review: not required / pending / completed, findings addressed in ...
```
