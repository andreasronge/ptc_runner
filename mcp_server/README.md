# ptc_runner_mcp

An [MCP](https://modelcontextprotocol.io/) server that exposes
[PtcRunner](../README.md)'s PTC-Lisp sandbox to any
MCP client (Claude Desktop, Cursor, Cline, Claude Code, …) over stdio
JSON-RPC, with an opt-in Streamable HTTP mode for private-network
deployments. The default tool, `lisp_eval`, accepts a PTC-Lisp
program plus optional `context` and `output_schema`, runs it in an isolated BEAM process (1 s wall-clock,
10 MB memory; 10 s / 100 MB in [aggregator mode](../docs/aggregator-mode.md)),
and returns a structured result. No filesystem, no network, no
arbitrary process exec — only PTC-Lisp built-ins and `println`.

The server has no LLM. The MCP client's LLM does the reasoning;
PtcRunner is invoked only when deterministic computation is useful.

For the conceptual overview (when to use it, comparison with Python /
JS execution servers, security model, architecture), see
[`docs/mcp-server.md`](../docs/mcp-server.md).

## Install

Requires Elixir 1.15+ / Erlang OTP 26+ (see `mcp_server/mix.exs`).

The intended distribution channel is a standalone `ptc_runner_mcp`
binary from GitHub Releases. Until those artifacts are published, build
the local Mix release from source.

### Planned GitHub releases

Release artifacts should be archives containing the Mix release output
for one OS/architecture pair. The first supported target should be
Apple Silicon macOS, with Intel macOS, Linux, and Windows added as CI
coverage and packaging are proven.

Expected channels:

- Snapshot builds from the latest `main`, published as prerelease
  artifacts for testing current work.
- Versioned releases from tags, published as stable GitHub Releases.
- `SHA256SUMS` for every archive, generated in CI after packaging and
  verified by install scripts before extraction.

### Source build (Mix release)

```bash
git clone https://github.com/andreasronge/ptc_runner
cd ptc_runner/mcp_server
mix deps.get
MIX_ENV=prod mix release
```

The release binary lands at
`_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp`. Smoke-test it:

```bash
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp version
# → ptc_runner_mcp 0.1.0
```

The MCP `initialize` response advertises the package version plus build
metadata. When built from a git checkout, `serverInfo.version` uses SemVer
build metadata such as `0.1.0+abc123def456`, and `serverInfo.build` includes
the compile-time `git_commit` and `git_dirty` fields. CI or packaging scripts
can override these with `PTC_RUNNER_MCP_GIT_COMMIT` and
`PTC_RUNNER_MCP_GIT_DIRTY`.

### In-tree development

From `mcp_server/`:

```bash
mix deps.get
mix mcp.run        # foreground, stdio attached
```

Equivalent to `mix run --no-halt` — convenient for local iteration
before cutting a release.

> macOS note: unsigned binaries built locally trigger Gatekeeper on
> first launch. Right-click → Open, or
> `xattr -d com.apple.quarantine <path>`.

## Wire it into an MCP client

The server speaks NDJSON-framed JSON-RPC 2.0 on stdio. Point any MCP
client at the release binary (or a wrapper that runs `mix mcp.run`
from the source tree).

### Claude Desktop — `claude_desktop_config.json`

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`
on macOS (Windows / Linux equivalents apply) and add:

```json
{
  "mcpServers": {
    "ptc-runner": {
      "command": "/absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp",
      "args": ["start"],
      "env": {}
    }
  }
}
```

Restart Claude Desktop. The `lisp_eval` tool appears in the
tool palette.

### Cline (VS Code) — `cline_mcp_settings.json`

Open the Cline settings file (Command Palette → "Cline: Open MCP
Settings") and add:

```json
{
  "mcpServers": {
    "ptc-runner": {
      "command": "/absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp",
      "args": ["start"],
      "env": {},
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

### Cursor — `mcp.json`

Place at `~/.cursor/mcp.json` (or `<project>/.cursor/mcp.json` for a
project-scoped server):

```json
{
  "mcpServers": {
    "ptc-runner": {
      "command": "/absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp",
      "args": ["start"],
      "env": {}
    }
  }
}
```

### Claude Code — `claude mcp add`

```bash
claude mcp add ptc-runner \
  /absolute/path/to/_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp \
  start
```

To pass configuration flags through any of these clients, append them
to the `args` array (e.g., `"args": ["start", "--max-frame-bytes", "8388608"]`).

## Streamable HTTP mode

HTTP mode is opt-in and intended for service deployments, not local
desktop MCP client configs:

```bash
export PTC_RUNNER_MCP_HTTP_AUTH_TOKEN="$(openssl rand -base64 32)"
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp start \
  --http \
  --http-auth-token "$PTC_RUNNER_MCP_HTTP_AUTH_TOKEN"
```

The default endpoint is `POST /mcp` on `127.0.0.1:7332`. The first
client request initializes an HTTP protocol session and receives an
`MCP-Session-Id`; later POST/DELETE requests send that id. `GET /health`
is liveness and `GET /ready` is load-balancer readiness.

See [`docs/mcp-server-http-deployment.md`](../docs/mcp-server-http-deployment.md)
for the private-network deployment runbook and
[`docs/mcp-server-configuration.md#streamable-http-flags`](../docs/mcp-server-configuration.md#streamable-http-flags)
for all HTTP flags.

## Features

The server is one binary with several opt-in capabilities. Each links
to its own doc.

| Feature | Default | Doc |
|---|---|---|
| `lisp_eval` (sealed sandbox) | on | [`docs/mcp-server.md`](../docs/mcp-server.md) |
| **Aggregator mode** — call configured upstream MCP servers from inside the sandbox via `(tool/mcp-call ...)` | off; enabled by `--upstreams-config` | [`docs/aggregator-mode.md`](../docs/aggregator-mode.md) |
| **Agentic mode** — `lisp_task`, a natural-language task tool backed by a planner LLM (requires aggregator mode) | off; `--agentic` | [`docs/agentic-mode.md`](../docs/agentic-mode.md) |
| **Stateful sessions** — `lisp_session_*` tools that persist `(def ...)` bindings, `*1`/`*2`/`*3`, and history | off; `--sessions` | [`docs/mcp-server.md`](../docs/mcp-server.md#stateful-sessions) |
| **Diagnostics** — `lisp_debug` for in-process telemetry rollups | off; `--debug-tool` | [`docs/mcp-debug.md`](../docs/mcp-debug.md) |
| **Response profiles** — `slim` / `structured` / `debug` | `slim` | [`docs/mcp-server-configuration.md#response-profiles`](../docs/mcp-server-configuration.md#response-profiles) |
| **Tracing** — per-call JSONL traces, viewable via `mix ptc.viewer` | off; `--trace-dir` | [`docs/mcp-server-configuration.md#tracing`](../docs/mcp-server-configuration.md#tracing) |
| **Streamable HTTP** — private-network MCP endpoint with session ids, bearer auth, health/readiness, and HTTP telemetry | off; `--http` | [`docs/mcp-server-http-deployment.md`](../docs/mcp-server-http-deployment.md) |

For every flag and environment variable, see
[`docs/mcp-server-configuration.md`](../docs/mcp-server-configuration.md).

## Lifecycle commands

The release binary defaults `RELEASE_DISTRIBUTION=none` so MCP clients
can run multiple stdio subprocesses concurrently without Erlang
node-name collisions:

```bash
ptc_runner_mcp start      # foreground, stdio attached (what MCP clients use)
ptc_runner_mcp version    # print "ptc_runner_mcp <version>"
```

For remote IEx debugging, start the process with distribution enabled
and a unique node name, then attach with the same settings:

```bash
RELEASE_DISTRIBUTION=sname RELEASE_NODE=ptc_runner_mcp_debug_1 ptc_runner_mcp start
RELEASE_DISTRIBUTION=sname RELEASE_NODE=ptc_runner_mcp_debug_1 ptc_runner_mcp remote
```

## Links

- Conceptual overview: [`docs/mcp-server.md`](../docs/mcp-server.md)
- Configuration reference: [`docs/mcp-server-configuration.md`](../docs/mcp-server-configuration.md)
- HTTP deployment: [`docs/mcp-server-http-deployment.md`](../docs/mcp-server-http-deployment.md)
- Aggregator mode: [`docs/aggregator-mode.md`](../docs/aggregator-mode.md)
- Agentic mode (`lisp_task`): [`docs/agentic-mode.md`](../docs/agentic-mode.md)
- Diagnostics (`lisp_debug`): [`docs/mcp-debug.md`](../docs/mcp-debug.md)
- Getting-started walkthrough: [`docs/guides/mcp-getting-started.md`](../docs/guides/mcp-getting-started.md)
- PTC-Lisp language reference: [`docs/ptc-lisp-specification.md`](../docs/ptc-lisp-specification.md)
- PtcRunner repo: <https://github.com/andreasronge/ptc_runner>
- Model Context Protocol: <https://modelcontextprotocol.io/>

## License

Apache-2.0. See [LICENSE](../LICENSE) at the repo root.
