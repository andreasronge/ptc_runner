# PTC Gateway

Stdio and streamable HTTP MCP server that exposes compiled PtcRunner
applications as tools.

The gateway is a companion of the root `ptc_runner` project rather than a
separately published package. It ships inside the standalone release; the
published Hex package does not carry it. Start it from the root command:

```bash
ptc serve gateway.json
```

Bandit and Plug live only in this companion. `ptc serve` is still stdio;
`PtcGateway.start_http/1` binds loopback by default (`{0, 0, 0, 0}` is an
explicit operator choice). The pinned protocol is MCP `2026-07-28`. Stdio
uses newline-delimited JSON; HTTP POST `/mcp` uses JSON bodies.
`notifications/cancelled` is stdio-only.
