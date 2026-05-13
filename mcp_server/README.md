# ptc_runner_mcp

[![Hex.pm](https://img.shields.io/hexpm/v/ptc_runner_mcp.svg)](https://hex.pm/packages/ptc_runner_mcp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ptc_runner_mcp)

An [MCP](https://modelcontextprotocol.io/) server that exposes
[PtcRunner](https://hex.pm/packages/ptc_runner)'s PTC-Lisp sandbox to any
MCP client (Claude Desktop, Cursor, Cline, Claude Code, …) over stdio
JSON-RPC. The default tool, `ptc_lisp_execute`, accepts a PTC-Lisp
program plus optional `context` and `output_schema` (or legacy
`signature`), runs it in an isolated BEAM process (1 s wall-clock,
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

Restart Claude Desktop. The `ptc_lisp_execute` tool appears in the
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

## Features

The server is one binary with several opt-in capabilities. Each links
to its own doc.

| Feature | Default | Doc |
|---|---|---|
| `ptc_lisp_execute` (sealed sandbox) | on | [`docs/mcp-server.md`](../docs/mcp-server.md) |
| **Aggregator mode** — call configured upstream MCP servers from inside the sandbox via `(tool/mcp-call ...)` | off; enabled by `--upstreams-config` | [`docs/aggregator-mode.md`](../docs/aggregator-mode.md) |
| **Agentic mode** — `ptc_task`, a natural-language task tool backed by a planner LLM (requires aggregator mode) | off; `--agentic` | [`docs/agentic-mode.md`](../docs/agentic-mode.md) |
| **Stateful sessions** — `ptc_session_*` tools that persist `(def ...)` bindings, `*1`/`*2`/`*3`, and history | off; `--sessions` | [`docs/mcp-server.md`](../docs/mcp-server.md#stateful-sessions) |
| **Diagnostics** — `ptc_debug` for in-process telemetry rollups | off; `--debug-tool` | [`docs/mcp-debug.md`](../docs/mcp-debug.md) |
| **Response profiles** — `slim` / `structured` / `debug` | `slim` | [`docs/mcp-server-configuration.md#response-profiles`](../docs/mcp-server-configuration.md#response-profiles) |
| **Tracing** — per-call JSONL traces, viewable via `mix ptc.viewer` | off; `--trace-dir` | [`docs/mcp-server-configuration.md#tracing`](../docs/mcp-server-configuration.md#tracing) |

For every flag and environment variable, see
[`docs/mcp-server-configuration.md`](../docs/mcp-server-configuration.md).

## Lifecycle commands

The release binary supports the standard Mix release lifecycle:

```bash
ptc_runner_mcp start      # foreground, stdio attached (what MCP clients use)
ptc_runner_mcp daemon     # background
ptc_runner_mcp stop
ptc_runner_mcp restart
ptc_runner_mcp remote     # IEx attached to a running node
ptc_runner_mcp version    # print "ptc_runner_mcp <version>"
```

## Links

- Conceptual overview: [`docs/mcp-server.md`](../docs/mcp-server.md)
- Configuration reference: [`docs/mcp-server-configuration.md`](../docs/mcp-server-configuration.md)
- Aggregator mode: [`docs/aggregator-mode.md`](../docs/aggregator-mode.md)
- Agentic mode (`ptc_task`): [`docs/agentic-mode.md`](../docs/agentic-mode.md)
- Diagnostics (`ptc_debug`): [`docs/mcp-debug.md`](../docs/mcp-debug.md)
- Getting-started walkthrough: [`docs/guides/mcp-getting-started.md`](../docs/guides/mcp-getting-started.md)
- PTC-Lisp language reference: <https://hexdocs.pm/ptc_runner>
- PtcRunner repo: <https://github.com/andreasronge/ptc_runner>
- Model Context Protocol: <https://modelcontextprotocol.io/>

## License

Apache-2.0. See [LICENSE](../LICENSE) at the repo root.
