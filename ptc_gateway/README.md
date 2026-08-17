# PTC Gateway

Stdio and streamable HTTP MCP server that exposes compiled PtcRunner
applications as tools.

The gateway is a companion of the root `ptc_runner` project rather than a
separately published package. It ships inside the standalone release; the
published Hex package does not carry it. Start it from the root command:

```bash
ptc serve gateway.json
```

Bandit and Plug live only in this companion. Stdio is the default. When the
gateway document names `http`, the host loads a private token file and
`PtcGateway.start_http/1` binds loopback unless `listen` is `0.0.0.0`. A
wildcard bind requires an explicit Host name. The pinned protocol is MCP
`2026-07-28`. Stdio uses newline-delimited JSON; HTTP POST `/mcp` uses JSON
bodies. `notifications/cancelled` is stdio-only. Rotation of the bearer
  token is restart, not reload. The gateway never puts the token in plug
  options, child specs, or process status. Bandit `:start`/`:exception`
  telemetry still include the raw `Authorization` header; `:stop` does not.
  HTTP `tools/call` with `Accept: text/event-stream` is SSE: heartbeat
  comments detect disconnect and the first failed write kills the request
  owner. JSON `tools/call` runs to completion or deadline.
