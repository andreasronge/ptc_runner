# MCP Streamable HTTP Deployment

`ptc_runner_mcp` can run as an opt-in Streamable HTTP MCP server for
private-network deployments. The HTTP mode is intended for a trusted
agentic application or load balancer talking to one BEAM node over a
small network boundary; stdio remains the default local-client mode.

## Quick Start

Generate a strong bearer token:

```bash
export PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$(openssl rand -base64 32)"
```

Start the release on loopback:

```bash
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp start \
  --http \
  --http-auth-token "$PTC_RUNNER_MCP_HTTP_AUTH_TOKEN"
```

The MCP endpoint is `POST /mcp` on `127.0.0.1:7332` by default. In
HTTP mode stdio is not attached.

## Required Headers

Every `/mcp` request needs:

```http
Authorization: Bearer <token>
```

The first request is `initialize` without an `MCP-Session-Id`. The
response includes:

```http
MCP-Session-Id: <opaque id>
```

Subsequent POST and DELETE requests send that session id. Clients should
also send `MCP-Protocol-Version`; if it is absent the server falls back
to the version stored on the HTTP session.

## Health And Readiness

`GET /health` is liveness: it returns `200` while the process and
listener are alive.

`GET /ready` is load-balancer readiness: it returns `200` when the
session registry is accepting work, and `503` when the node is draining
or saturated.

Both endpoints are unauthenticated and expose only process status. Keep
them on a private network or restrict them at the load balancer.

## Security Posture

Use a private subnet, security group, firewall, or equivalent network
boundary. The bearer token is the inner boundary, not the only boundary.

TLS should terminate at the load balancer or edge proxy. If traffic from
the proxy to the BEAM node is plaintext, anything able to observe that
link can see the bearer token.

Binding to a non-loopback address always requires a token.
`--http-disable-auth` is only permitted on loopback binds and cannot be
combined with `--http-allow-unsafe-network`.

The v1 auth model has one static token. All token holders are the same
owner, so an `MCP-Session-Id` is a bearer capability inside that trust
boundary. Session ids are random and are never logged raw.

### Failed-auth rate limiting

Repeated failed bearer authentications from the same source are rate
limited to reduce brute-force risk (`OPLANE_REQ-00080322`). Both missing
and invalid bearer failures count. Once a source exceeds
`--http-auth-rate-limit-max-failures` within
`--http-auth-rate-limit-window-ms`, it is temporarily blocked for
`--http-auth-rate-limit-block-ms`; blocked requests receive `429` with a
`Retry-After` header and no `www-authenticate` challenge (so a blocked
caller is not told whether its token was missing or invalid). A
successful authentication immediately resets the source's failure state.
A misconfigured-but-legitimate client can briefly be blocked; it
self-heals after the block window. The limiter is on by default and is a
no-op when no token is configured or when `--http-auth-rate-limit` is
`false`; if the limiter process is unavailable it fails open.

The source is keyed by the peer IP (`conn.remote_ip`). `X-Forwarded-For`
/ `Forwarded` headers are **not** trusted — behind a reverse proxy every
request appears to originate from the proxy, so deploy per-source
limiting at the proxy too (or in addition). `Host`/`Origin` rejections
are not bearer-auth failures and never count toward the limit. Block
decisions log a JSON line (`http_auth_rate_limited`) with the raw source
IP, which is operationally useful for acting on abuse; the bearer token
itself is never logged.

### Token generation

The server requires a minimum of 32 bytes but does not programmatically
verify entropy quality. Generate tokens with a cryptographically secure
source:

```bash
# Recommended — 32 random bytes, base64-encoded (44 characters)
openssl rand -base64 32

# Alternative
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Do not use low-entropy strings (repeated characters, dictionary words,
predictable patterns). Entropy quality is the caller's responsibility.

### Redaction

The bearer token is registered with the credential redaction system at
startup. If the raw token value accidentally appears in a log line or
trace payload, the redactor replaces it with `[REDACTED]`. This is a
defense-in-depth measure — the primary protection is that request logs
and traces use hashed owner identifiers, never the raw token.

## Observability

HTTP request logs are JSON lines on stderr. Each request log includes an
instance label, `X-Request-Id`, method, path, status, duration, and
hashed owner/session ids when known.

The server emits sanitized telemetry under `[:ptc_lisp, :http, ...]`
for request start/stop, session create/close, auth failures, failed-auth
rate-limit blocks (`[:ptc_lisp, :http, :auth, :rate_limited]`), limit
rejections, and cancellations.

When `--trace-dir` is enabled, HTTP tool-call trace events include
`owner_hash`, `mcp_session_hash`, and `transport_request_id` metadata.
Trace payload policy is still controlled by `--trace-payloads`.

Prometheus `/metrics` is not shipped in this PR. The config flags are
reserved, but scraping support remains a follow-up.

## Rolling Deploy Drain

On application shutdown the registry enters drain mode, so `/ready`
returns `503` and new `/mcp` POSTs receive a JSON-RPC `server draining`
error. The process waits `--http-shutdown-grace-ms`, then cancels any
remaining in-flight HTTP workers before exit.

`DELETE /mcp` closes one protocol session immediately. Reaped or deleted
sessions return `404` on later use.

## Important Flags

| Flag | Default | Meaning |
|---|---:|---|
| `--http` | `false` | Enable the HTTP listener. |
| `--http-host` | `127.0.0.1` | Bind IP address or `localhost`. |
| `--http-port` | `7332` | Bind port. |
| `--http-path` | `/mcp` | MCP endpoint path. |
| `--http-auth-token` | unset | Static bearer token; minimum 32 characters. |
| `--http-allowed-origin` | unset | Exact allowed browser `Origin`; repeatable or comma-separated. |
| `--http-max-sessions` | `256` | Global HTTP protocol-session cap. |
| `--http-max-sessions-per-owner` | `32` | Per-owner protocol-session cap. |
| `--http-max-in-flight-per-session` | `4` | Per-session executing request cap. |
| `--http-auth-rate-limit` | `true` | Rate limit failed bearer auth per source. |
| `--http-auth-rate-limit-window-ms` | `60000` | Window over which failures accumulate. |
| `--http-auth-rate-limit-max-failures` | `5` | Failures per window before a source is blocked. |
| `--http-auth-rate-limit-block-ms` | `60000` | Block duration after the threshold is exceeded (`429` + `Retry-After`). |
| `--http-session-ttl-ms` | `3600000` | Absolute protocol-session lifetime. |
| `--http-session-idle-timeout-ms` | `900000` | Idle protocol-session timeout. |
| `--http-instance-label` | hostname | Label stamped into HTTP logs/telemetry/traces. |

For loopback binds, the MCP endpoint rejects requests whose
`Host`/authority is not loopback. Missing `Origin` remains valid for
non-browser clients, but invalid browser `Origin` values are rejected.
POST requests with a present `Content-Type` must be JSON
(`application/json` or a `+json` media type).
