# ptc_runner_mcp

`ptc_runner_mcp` is a standalone MCP server release for coding agents
and other MCP clients. In the MCP `initialize` handshake it advertises
the server name `ptc_lisp`. It gives the client a safe **code mode**
backed by PTC-Lisp, plus optional modes for aggregating upstream MCP
tools, stateful Lisp sessions, diagnostics, and private-network HTTP
deployment.

The server does not contain an LLM. Your MCP client or agent does the
reasoning; the `ptc_lisp` MCP server runs bounded, deterministic work
when the model needs help with counting, filtering, reshaping JSON,
validating schemas, or composing MCP tool results.

For the deeper rationale, architecture, and security model, see
[`docs/mcp-server.md`](../docs/mcp-server.md).

## Why Use It

PTC-Lisp is intentionally smaller than Python or JavaScript execution
servers:

- no filesystem, network, or process execution from the program;
- per-call resource limits and bounded concurrency;
- structured errors that an LLM can repair from;
- optional JSON Schema validation for machine-readable results;
- no cross-call state unless explicit session tools are enabled;
- upstream MCP access only through configured, mediated calls in
  aggregator mode.

The practical advantage is that the sandbox is part of the language
surface, not something you have to recreate with containers around a
general-purpose interpreter.

Each program runs in its own lightweight BEAM process. If a program is
slow, too large, or crashes, the server can kill just that worker and
keep serving other requests. This gives PtcRunner process-level
isolation without the startup cost of a container or Python sandbox per
call, and lets the server handle concurrent calls while keeping MCP and
upstream connections warm.

## Core Ideas

**Code mode.** The default tool, `lisp_eval`, accepts a PTC-Lisp
program plus optional JSON `context` and `output_schema`. The program
runs in an isolated BEAM process and returns a compact MCP tool result.
Use it for deterministic computation that LLMs often do unreliably:
counts, sums, filters, schema-shaped extraction, and data reshaping.

**MCP aggregation.** With an upstream config file, PTC-Lisp programs
can call other MCP servers through `(tool/mcp-call ...)`. One
sandboxed program can search, filter, join, and reduce upstream tool
results before the final answer reaches the LLM. This reduces
round-trips and context size without exposing arbitrary I/O to the
program.

**Server deployment.** The same executable can run as a local stdio MCP
server for desktop/coding agents, or as a Streamable HTTP MCP endpoint
for private-network deployments.

## Modes

| Mode | Enable with | What it adds |
|---|---|---|
| Stdio | default `start` | Local MCP subprocess for Claude Desktop, Cursor, Cline, Claude Code, and similar clients. |
| HTTP | `--http` | Streamable HTTP endpoint with bearer auth, health/readiness endpoints, and session ids. |
| Aggregator | `--upstreams-config <path>` | Lets `lisp_eval` programs call configured upstream MCP servers. |
| Sessions | `--sessions` | Adds `lisp_session_*` tools with explicit persisted Lisp bindings and bounded history. |
| Agentic | `--agentic` | Adds experimental `lisp_task`, a natural-language task tool backed by a planner LLM. Requires aggregator mode. |
| Diagnostics | `--debug-tool`, `--trace-dir` | Adds `lisp_debug` and/or per-call JSONL traces for troubleshooting. |

Full flag reference: [`docs/mcp-server-configuration.md`](../docs/mcp-server-configuration.md).

## Install on macOS

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

Building from source, release internals, and remote IEx debugging are
covered in [DEVELOPMENT.md](DEVELOPMENT.md).

## Use From A Coding Agent

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
that accept MCP JSON config. For Claude Code:

```bash
claude mcp add ptc-runner \
  /absolute/path/to/ptc_runner_mcp/bin/ptc_runner_mcp \
  start
```

To pass options, append them after `start`:

```json
"args": ["start", "--sessions", "--trace-dir", "/tmp/ptc-traces"]
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
"args": ["start", "--upstreams-config", "/absolute/path/to/upstreams.json"]
```

`lisp_eval` can now use `(tool/mcp-call ...)` to call the configured
`fs` server from inside one bounded PTC-Lisp program. See
[`docs/aggregator-mode.md`](../docs/aggregator-mode.md) for the
authoring model, catalog discovery, error semantics, credentials, and
HTTP upstreams.

## Deploy As A Server

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
- bind: `127.0.0.1:7332`
- liveness: `GET /health`
- readiness: `GET /ready`

For non-loopback binds, auth is required unless you explicitly opt into
unsafe networking. Use
[`docs/mcp-server-http-deployment.md`](../docs/mcp-server-http-deployment.md)
as the deployment runbook.

## More Docs

- Conceptual overview and security model: [`docs/mcp-server.md`](../docs/mcp-server.md)
- Full configuration reference: [`docs/mcp-server-configuration.md`](../docs/mcp-server-configuration.md)
- Aggregator mode: [`docs/aggregator-mode.md`](../docs/aggregator-mode.md)
- Agentic mode: [`docs/agentic-mode.md`](../docs/agentic-mode.md)
- HTTP deployment: [`docs/mcp-server-http-deployment.md`](../docs/mcp-server-http-deployment.md)
- Diagnostics: [`docs/mcp-debug.md`](../docs/mcp-debug.md)
- First raw JSON-RPC call: [`docs/guides/mcp-getting-started.md`](../docs/guides/mcp-getting-started.md)
- PTC-Lisp language reference: [`docs/ptc-lisp-specification.md`](../docs/ptc-lisp-specification.md)
- Developer/build/debug notes: [DEVELOPMENT.md](DEVELOPMENT.md)

## License

Apache-2.0. See [LICENSE](../LICENSE) at the repo root.
