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

## HTTPS OpenAPI Upstream For Coding Agents

For services that expose a read-only JSON API and an OpenAPI document,
configure PtcRunner as the MCP server seen by the coding agent, then
configure the HTTPS API as an OpenAPI upstream. The agent sees
PtcRunner's `lisp_eval` / `lisp_session_*` tools; PTC-Lisp programs
call the API through `(tool/call ...)`.

Create an upstream config:

```json
{
  "credentials": {
    "api-token": {
      "source": "env",
      "var": "API_SERVICE_TOKEN",
      "scheme_hint": "bearer"
    }
  },
  "upstreams": {
    "api": {
      "transport": "openapi",
      "base_url": "https://api.example.com",
      "schema_file": "/absolute/path/to/api.openapi.json",
      "auth": [
        { "scheme": "bearer", "binding": "api-token" }
      ],
      "include_operations": [
        "list_items",
        "get_item"
      ],
      "request_timeout_ms": 5000,
      "max_response_bytes": 1048576,
      "schema_max_bytes": 1048576
    }
  }
}
```

Use `schema_file` when possible so PtcRunner boot does not depend on
the upstream service. Use `schema_url` only when the service hosts a
stable OpenAPI document and boot-time schema fetching is acceptable.
The OpenAPI v1 adapter intentionally exposes only explicitly included
`GET` operations with JSON or empty `204` success responses.

Wire the coding agent to PtcRunner:

```json
{
  "mcpServers": {
    "ptc-runner": {
      "command": "/absolute/path/to/ptc_runner_mcp/bin/ptc_runner_mcp",
      "args": [
        "start",
        "--sessions",
        "--upstreams-config",
        "/absolute/path/to/upstreams.json",
        "--prelude",
        "/absolute/path/to/analysis-prelude.clj",
        "--turn-log-dir",
        "/absolute/path/to/turn-log"
      ],
      "env": {
        "API_SERVICE_TOKEN": "..."
      }
    }
  }
}
```

`--prelude` is optional. When supplied, the file is read once at server boot
and attached to every `lisp_eval`, `lisp_session_eval`, and agentic `lisp_task`
run. This is the recommended way to run a verified analysis prelude in
Codex/Claude Code: start a fresh MCP server process with the prelude attached,
record the run with `--turn-log-dir`, and analyze those logs in a later session.

Ask the agent, or use the REPL, to smoke-test discovery and one call:

```clojure
(tool/servers)
(dir 'api)
(tool/call {:server "api" :tool "list-items" :args {:limit 3}})
```

If the HTTPS service is not under the same team's control, keep
`include_operations` narrow and prefer operation overrides or
`x-ptc-*` schema extensions for clearer names, descriptions, and
defaults. See [Aggregator Mode](aggregator-mode.md#format--openapi-upstream)
for the full OpenAPI upstream format.

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
