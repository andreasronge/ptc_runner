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

Binding to a non-loopback address requires a token unless both
`--http-disable-auth` and `--http-allow-unsafe-network` are set. That
pair is for controlled tests only.

The v1 auth model has one static token. All token holders are the same
owner, so an `MCP-Session-Id` is a bearer capability inside that trust
boundary. Session ids are random and are never logged raw.

## Observability

HTTP request logs are JSON lines on stderr. Each request log includes an
instance label, `X-Request-Id`, method, path, status, duration, and
hashed owner/session ids when known.

The server emits sanitized telemetry under `[:ptc_runner_mcp, :http, ...]`
for request start/stop, session create/close, auth failures, limit
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
| `--http-session-ttl-ms` | `3600000` | Absolute protocol-session lifetime. |
| `--http-session-idle-timeout-ms` | `900000` | Idle protocol-session timeout. |
| `--http-instance-label` | hostname | Label stamped into HTTP logs/telemetry/traces. |

For loopback binds, the MCP endpoint rejects requests whose
`Host`/authority is not loopback. Missing `Origin` remains valid for
non-browser clients, but invalid browser `Origin` values are rejected.
POST requests with a present `Content-Type` must be JSON
(`application/json` or a `+json` media type).
