# ptc_runner_mcp

[![Hex.pm](https://img.shields.io/hexpm/v/ptc_runner_mcp.svg)](https://hex.pm/packages/ptc_runner_mcp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ptc_runner_mcp)

An [MCP](https://modelcontextprotocol.io/) server that exposes
[PtcRunner](https://hex.pm/packages/ptc_runner)'s PTC-Lisp sandbox
to any MCP client (Claude Desktop, Cursor, Cline, Claude Code, …)
over stdio JSON-RPC. The server advertises a single tool,
`ptc_lisp_execute`, which accepts a PTC-Lisp program plus optional
`context` and `signature`, runs it in an isolated BEAM process
(1 s wall-clock, 10 MB memory, no I/O except `println`, no
filesystem, no network), and returns a structured result.

The pitch over Python/JS execution servers:

- **Sandboxed by construction** — no filesystem, no network, no
  arbitrary process exec; only PTC-Lisp built-ins and `println`.
- **Designed for LLM authoring** — no imports, no setup, every
  program is a self-contained expression.
- **Schemas as types** — optional `signature` validates and
  coerces the return value; programmatic clients consume the
  validated value.
- **Stable wire format** — same response contract as in-process
  PtcRunner surfaces, so logs and tests carry over.

The server has no LLM. The MCP client's LLM does the reasoning;
PtcRunner is invoked only when deterministic computation is
useful.

> See [`docs/mcp-server.md`](../docs/mcp-server.md) for the conceptual
> overview (when to use it, comparison with Python / JS execution
> servers, security model, architecture diagram), and
> [`docs/guides/mcp-getting-started.md`](../docs/guides/mcp-getting-started.md)
> for a short walkthrough. See
> [`Plans/ptc-runner-mcp-server.md`](../Plans/ptc-runner-mcp-server.md)
> for the full v1 specification, and
> [the PtcRunner HexDocs](https://hexdocs.pm/ptc_runner) for the
> PTC-Lisp language reference.

## Install

### Option 1 — Source build (Elixir 1.15+ / OTP 26+)

```bash
git clone https://github.com/andreasronge/ptc_runner
cd ptc_runner/mcp_server
mix deps.get
MIX_ENV=prod mix release
```

The release binary lands at:

```
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp
```

Smoke-test it:

```bash
_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp version
# → ptc_runner_mcp 0.1.0
```

### Option 2 — In-tree development

From `mcp_server/`:

```bash
mix deps.get
mix mcp.run        # foreground, stdio attached
```

This is equivalent to `mix run --no-halt` and is convenient for
local iteration before cutting a release.

### Option 3 — Single-file binary (Burrito)

Single-file binaries via [Burrito](https://github.com/burrito-elixir/burrito)
are tracked for a follow-up release; they require Zig 0.11+ and
target-specific cross-build tooling that is not yet wired into
this repo. For now, build the Mix release (Option 1) and copy the
`_build/prod/rel/ptc_runner_mcp/` directory wherever it needs to
run — the BEAM and ERTS are bundled, so the host machine only
needs a compatible glibc / libSystem.

> macOS note: unsigned binaries built locally will trigger
> Gatekeeper on first launch ("cannot be opened because the
> developer cannot be verified"). Right-click → Open, or
> `xattr -d com.apple.quarantine <path>`.

## Wire it into an MCP client

The server speaks NDJSON-framed JSON-RPC 2.0 on stdio. Point any
MCP client at the release binary (or a wrapper that runs
`mix mcp.run` from the source tree).

### Claude Desktop — `claude_desktop_config.json`

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`
on macOS or the Windows / Linux equivalent, and add an entry under
`mcpServers`:

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

Restart Claude Desktop. The `ptc_lisp_execute` tool will appear
in the tool palette.

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

Place at `~/.cursor/mcp.json` (or `<project>/.cursor/mcp.json` for
a project-scoped server):

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

## Configuration

All configuration is read once at boot, either from CLI flags or
the equivalent environment variable. CLI flags win when both are
set. To pass flags through Claude Desktop / Cline / Cursor, append
them to the `args` array, e.g.:

```json
"args": ["start", "--max-frame-bytes", "8388608"]
```

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--max-frame-bytes` | `PTC_RUNNER_MCP_MAX_FRAME_BYTES` | `8388608` (8 MiB) | Hard cap on a single NDJSON frame. |
| `--max-program-bytes` | `PTC_RUNNER_MCP_MAX_PROGRAM_BYTES` | `65536` (64 KiB) | Hard cap on the `program` argument. |
| `--max-context-bytes` | `PTC_RUNNER_MCP_MAX_CONTEXT_BYTES` | `4194304` (4 MiB) | Hard cap on the `context` argument. |
| `--max-concurrent-calls` | `PTC_RUNNER_MCP_MAX_CONCURRENT_CALLS` | `8` | Concurrency gate; excess calls return `:busy`. |
| `--log-level` | `PTC_RUNNER_MCP_LOG_LEVEL` | `info` | One of `debug`, `info`, `warn`, `error`. |
| `--trace-dir` | `PTC_RUNNER_MCP_TRACE_DIR` | unset | Directory for per-call JSONL trace files. Tracing is OFF unless this is set. |
| `--trace-payloads` | `PTC_RUNNER_MCP_TRACE_PAYLOADS` | `summary` | One of `none`, `summary`, `full`. Controls program / context / result inclusion in traces. |
| `--trace-max-files` | `PTC_RUNNER_MCP_TRACE_MAX_FILES` | `1000` | Rolling-deletion cap on `--trace-dir`. |

### Tracing for power users

Setting `--trace-dir /tmp/ptc-traces` writes one JSONL file per
`tools/call` invocation under that directory. Each file contains
the lifecycle telemetry events
(`lisp.execute.start`, `lisp.execute.success` / `lisp.execute.fail`,
plus per-tool-call rows when relevant) emitted by `:ptc_runner`.
Tracing is opt-in and OFF by default — there is zero overhead
when `--trace-dir` is unset.

`--trace-payloads full` includes the verbatim `program`,
`context`, and rendered `result` bytes; `summary` (the default
when tracing is on) records sizes and SHA-256 digests only.
Pick `summary` unless you are actively debugging a specific call.

## Lifecycle commands

The release binary supports the standard Mix release lifecycle:

```bash
ptc_runner_mcp start      # foreground, stdio attached (what MCP clients use)
ptc_runner_mcp daemon     # background
ptc_runner_mcp stop
ptc_runner_mcp restart
ptc_runner_mcp remote     # IEx attached to a running node
ptc_runner_mcp version    # print "ptc_runner_mcp <version>"
ptc_runner_mcp eval "..."  # run an expression in a one-shot VM
```

## Links

- Full spec: [`Plans/ptc-runner-mcp-server.md`](../Plans/ptc-runner-mcp-server.md)
- Aggregator mode (calls configured upstream MCP servers from inside the sandbox): [`docs/aggregator-mode.md`](../docs/aggregator-mode.md)
- PTC-Lisp language reference: <https://hexdocs.pm/ptc_runner>
- PtcRunner repo: <https://github.com/andreasronge/ptc_runner>
- Model Context Protocol: <https://modelcontextprotocol.io/>

## License

Apache-2.0. See [LICENSE](../LICENSE) at the repo root.
