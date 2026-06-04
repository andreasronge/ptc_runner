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
can call other MCP servers through `(tool/call ...)`. One
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

## Use The Docker Image

When published, the MCP Docker image is available from GitHub Container
Registry:

```bash
docker pull ghcr.io/andreasronge/ptc-runner-mcp:TAG
```

Docker defaults to HTTP mode and binds inside the container on
`0.0.0.0:7332`:

```bash
export PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$(openssl rand -base64 32)"

docker run --rm -p 7332:7332 \
  -e PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$PTC_RUNNER_MCP_HTTP_AUTH_TOKEN" \
  ghcr.io/andreasronge/ptc-runner-mcp:TAG
```

Health checks:

```bash
curl http://127.0.0.1:7332/health
curl http://127.0.0.1:7332/ready
```

For local MCP clients that launch a stdio subprocess through Docker:

```bash
docker run --rm -i \
  ghcr.io/andreasronge/ptc-runner-mcp:TAG \
  start
```

To run as an HTTP aggregator with a mounted upstream config:

```bash
docker run --rm -p 7332:7332 \
  -e PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$PTC_RUNNER_MCP_HTTP_AUTH_TOKEN" \
  -v "$PWD/upstreams.json:/etc/ptc-runner/upstreams.json:ro" \
  ghcr.io/andreasronge/ptc-runner-mcp:TAG \
  start --http --http-host 0.0.0.0 \
  --upstreams-config /etc/ptc-runner/upstreams.json
```

The base image does not include Node, npm, Python, or uv. Stdio
upstreams that depend on those runtimes should use a derived image.

### Snapshot REPL Quick Start

This is for human testing and debugging of the MCP server, agentic
workflows, and upstream server wiring. It is not the normal agent
integration path.

```bash
docker pull ghcr.io/andreasronge/ptc-runner-mcp:snapshot

export RELEASE_COOKIE="$(openssl rand -base64 48)"
export PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$(openssl rand -base64 32)"

docker run --rm -it \
  --name ptc-mcp-debug \
  -p 7332:7332 \
  -e RELEASE_DISTRIBUTION=name \
  -e RELEASE_NODE=ptc_runner_mcp@127.0.0.1 \
  -e RELEASE_COOKIE="$RELEASE_COOKIE" \
  -e PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$PTC_RUNNER_MCP_HTTP_AUTH_TOKEN" \
  ghcr.io/andreasronge/ptc-runner-mcp:snapshot
```

In another terminal, open the bundled PTC-Lisp REPL inside the same
container:

```bash
docker exec -it ptc-mcp-debug \
  /opt/ptc_runner_mcp/bin/ptc_lisp_repl --display envelope
```

Try:

```clojure
(+ 1 2)
(apropos "mcp")
:tools
:quit
```

Use `--display envelope` while debugging because it shows the full MCP
tool response envelope that clients receive. The `docker exec` approach
does not publish EPMD or BEAM distribution ports; keep the Erlang cookie
private because it grants full VM RPC access inside the node.

## Remote PTC-Lisp REPL

For human debugging without installing Erlang or Elixir on the host,
run the bundled REPL wrapper from the release:

```bash
/absolute/path/to/ptc_runner_mcp/bin/ptc_lisp_repl
```

The REPL evaluates through the same MCP tool facade as clients. In
aggregator mode it can call configured upstream MCP tools from
PTC-Lisp programs, and its success/error text is the same feedback
shape the LLM sees, adjusted for an interactive terminal.
Use `--display envelope` to show the full pretty JSON MCP tool response
envelope, or switch while running with `:display envelope`. `--display
json` emits the same envelope as compact JSON.

The running server must have distributed Erlang enabled. The wrapper
uses the Erlang/Elixir runtime bundled inside the release. The Erlang
distribution cookie grants full VM RPC access, not only PTC-Lisp access,
so use a high-entropy cookie and do not expose EPMD or BEAM distribution
ports publicly.

For Docker, use the same bundled wrapper inside the container:

```bash
docker exec -it ptc-mcp-debug \
  /opt/ptc_runner_mcp/bin/ptc_lisp_repl --display envelope
```

Advanced users can still attach remote IEx and start the REPL manually:

```elixir
PtcRunnerMcp.Repl.start(display: :envelope)
```

For local development from this repository, the same REPL is also
available as a Mix task from `mcp_server/`:

```bash
mix mcp.repl --display envelope
mix mcp.repl --upstreams-config ./upstreams.json --display envelope
mix mcp.repl --stateless --eval "(+ 1 2)"
```

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

`lisp_eval` can now use `(tool/call ...)` to call the configured
`fs` server from inside one bounded PTC-Lisp program. See
[`docs/aggregator-mode.md`](../docs/aggregator-mode.md) for the
authoring model, catalog discovery, error semantics, credentials, and
HTTP / OpenAPI upstreams. For a coding-agent setup where PtcRunner
talks HTTPS to a JSON API described by OpenAPI, see
[HTTPS OpenAPI Upstream For Coding Agents](../docs/mcp-server-cli.md#https-openapi-upstream-for-coding-agents).

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

Non-loopback binds always require a bearer token. Use
[`docs/mcp-server-http-deployment.md`](../docs/mcp-server-http-deployment.md)
as the deployment runbook.

## More Docs

- Conceptual overview and security model: [`docs/mcp-server.md`](../docs/mcp-server.md)
- Full configuration reference: [`docs/mcp-server-configuration.md`](../docs/mcp-server-configuration.md)
- Aggregator mode: [`docs/aggregator-mode.md`](../docs/aggregator-mode.md)
- Root upstream runtime: [`docs/upstream-runtime.md`](../docs/upstream-runtime.md)
- Agentic mode: [`docs/agentic-mode.md`](../docs/agentic-mode.md)
- HTTP deployment: [`docs/mcp-server-http-deployment.md`](../docs/mcp-server-http-deployment.md)
- Diagnostics: [`docs/mcp-debug.md`](../docs/mcp-debug.md)
- First raw JSON-RPC call: [`docs/guides/mcp-getting-started.md`](../docs/guides/mcp-getting-started.md)
- PTC-Lisp language reference: [`docs/ptc-lisp-specification.md`](../docs/ptc-lisp-specification.md)
- Developer/build/debug notes: [DEVELOPMENT.md](DEVELOPMENT.md)

## License

MIT. See [LICENSE](../LICENSE) at the repo root.
