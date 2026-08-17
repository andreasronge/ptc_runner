# PTC Gateway

Stdio MCP server that exposes compiled PtcRunner applications as tools.

The gateway is a companion of the root `ptc_runner` project rather than a
separately published package. It ships inside the standalone release; the
published Hex package does not carry it. Start it from the root command:

```bash
ptc serve gateway.json
```

There are no web dependencies in this application. Streamable HTTP is a later
slice. The pinned protocol is MCP `2026-07-28` over newline-delimited JSON.
