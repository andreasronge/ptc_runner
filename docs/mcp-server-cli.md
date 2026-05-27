# MCP Server CLI

`ptc_runner_mcp` is the standalone MCP server release for coding
agents and other MCP clients. The release binary remains
`ptc_runner_mcp`; the MCP `initialize` server name is `ptc_lisp`. It
exposes PTC-Lisp as a bounded code mode, plus optional aggregator,
session, diagnostic, agentic, and HTTP deployment modes.

For the architecture and security model, start with
[MCP Server](mcp-server.md). For every flag and environment variable,
see [MCP Server Configuration](mcp-server-configuration.md).

## Install

Current packaged support is macOS. Download the `ptc_runner_mcp`
archive for your Mac from the project release artifacts, unpack it,
and use the executable inside the release directory.

Smoke test:

```bash
/absolute/path/to/ptc_runner_mcp/bin/ptc_runner_mcp version
```

If macOS blocks an unsigned local binary, right-click it once and
choose Open, or remove the quarantine attribute:

```bash
xattr -d com.apple.quarantine /absolute/path/to/ptc_runner_mcp/bin/ptc_runner_mcp
```

To build from source:

```bash
git clone https://github.com/andreasronge/ptc_runner
cd ptc_runner/mcp_server
mix deps.get
MIX_ENV=prod mix release
```

The release binary is:

```text
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp
```

## Stdio Client Config

Most local MCP clients should run the server in stdio mode:

```json
{
  "mcpServers": {
    "ptc-runner": {
      "command": "/absolute/path/to/ptc_runner_mcp/bin/ptc_runner_mcp",
      "args": ["start"],
      "env": {}
    }
  }
}
```

Use the same shape for Claude Desktop, Cursor, Cline, and other clients
that accept MCP JSON config.

For Claude Code:

```bash
claude mcp add ptc-runner \
  /absolute/path/to/ptc_runner_mcp/bin/ptc_runner_mcp \
  start
```

To pass options, append them after `start`:

```json
{
  "args": ["start", "--sessions", "--trace-dir", "/tmp/ptc-traces"]
}
```

The release defaults `RELEASE_DISTRIBUTION=none`, so multiple clients
or health probes can launch independent stdio subprocesses without
colliding on an Erlang node name.

## Aggregator Example

Create an upstream config:

```json
{
  "upstreams": {
    "fs": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/sandbox"]
    }
  }
}
```

Start the MCP server with:

```json
{
  "args": ["start", "--upstreams-config", "/absolute/path/to/upstreams.json"]
}
```

`lisp_eval` can now use `(tool/call ...)` to call the configured
`fs` server from inside one bounded PTC-Lisp program. See
[Aggregator Mode](aggregator-mode.md) for the authoring model,
REPL discovery, error semantics, credentials, and HTTP upstreams.

## HTTP Mode

HTTP mode is opt-in and intended for private-network deployments behind
a trusted TLS edge or load balancer:

```bash
export PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$(openssl rand -base64 32)"

/absolute/path/to/ptc_runner_mcp/bin/ptc_runner_mcp start \
  --http \
  --http-auth-token "$PTC_RUNNER_MCP_HTTP_AUTH_TOKEN"
```

Defaults:

- MCP endpoint: `POST /mcp`
- Bind address: `127.0.0.1:7332`
- Liveness: `GET /health`
- Readiness: `GET /ready`

For non-loopback binds, auth is required unless you explicitly opt into
unsafe networking. Use [HTTP Deployment](mcp-server-http-deployment.md)
as the deployment runbook.

## More

- [MCP Getting Started](guides/mcp-getting-started.md) walks through a
  raw JSON-RPC call.
- [MCP Debug](mcp-debug.md) covers `lisp_debug` and trace inspection.
- [Agentic Mode](agentic-mode.md) covers the experimental `lisp_task`
  tool.
- [PTC-Lisp Specification](ptc-lisp-specification.md) documents the
  language accepted by `lisp_eval`.
