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
filesystem, no network — see [aggregator mode](#aggregator-mode)
for an opt-in way to call other MCP servers from inside the
sandbox), and returns a structured result.

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

## Aggregator mode

In default mode the sandbox is sealed: programs do deterministic
computation, no external I/O. **Aggregator mode** opt-in lets a
PTC-Lisp program call configured upstream MCP servers via
`(tool/mcp-call ...)` and compose their results inside the sandbox.
The calling LLM sees only the final transformed value, plus a
machine-readable `upstream_calls` audit trail in the response.

Use it when you'd otherwise have an LLM orchestrate N native MCP
calls and reduce the results client-side. Empirically, on a 3-call
cross-server filter workflow this gives ~11× token savings and
~3× wall-clock speedup with `pmap`. See
[`docs/aggregator-mode.md`](../docs/aggregator-mode.md) for the
full reference (PTC-Lisp authoring against `tool/mcp-call`,
catalog format, error model, three example programs).

### Quick start

**1. Write an upstreams config** (JSON). Example —
`~/ptc-mcp-sandbox/upstreams.json`:

```json
{
  "upstreams": {
    "fs": {
      "command": "npx",
      "args": [
        "--yes",
        "@modelcontextprotocol/server-filesystem@2026.1.14",
        "/Users/you/ptc-mcp-sandbox"
      ],
      "handshake_timeout_ms": 60000
    },
    "mem": {
      "command": "npx",
      "args": ["--yes", "@modelcontextprotocol/server-memory"],
      "handshake_timeout_ms": 60000
    }
  }
}
```

The `${VAR}` placeholders inside `env` are resolved from the
parent process at startup (e.g., `"GITHUB_TOKEN": "${GITHUB_TOKEN}"`).
Unset variables fail-fast with a clear startup error.

**2. Point the server at the config.** One of, in priority order
(highest wins):

```bash
# CLI flag (passed via the client's `args`)
--upstreams-config /Users/you/ptc-mcp-sandbox/upstreams.json

# Environment variable
PTC_RUNNER_MCP_UPSTREAMS=/Users/you/ptc-mcp-sandbox/upstreams.json

# XDG default
~/.config/ptc_runner_mcp/upstreams.json
```

**3. Wire into your MCP client.** For Claude Code with a wrapper
script (works around `mix run` PATH inheritance from any client):

```bash
cat > ~/ptc-mcp-sandbox/run.sh <<'EOF'
#!/bin/bash
set -euo pipefail
exec 2>>"$HOME/ptc-mcp-sandbox/server.stderr.log"
cd /absolute/path/to/ptc_runner/mcp_server
exec /opt/homebrew/bin/mix run --no-halt --no-compile -- \
  --upstreams-config "$HOME/ptc-mcp-sandbox/upstreams.json"
EOF
chmod +x ~/ptc-mcp-sandbox/run.sh
claude mcp add ptc-runner ~/ptc-mcp-sandbox/run.sh
```

For Claude Desktop / Cursor / Cline, add `--upstreams-config` to
the `args` array of an existing release-binary entry:

```json
"args": ["start", "--upstreams-config", "/absolute/path/to/upstreams.json"]
```

Restart the client. The `tools/list` description will now include
an inline catalog of every tool advertised by every configured
upstream — that's what the LLM uses to know which `(tool/mcp-call
...)` shapes are valid.

### Aggregator-mode flags

These come into effect when at least one upstream is configured.
The first two override the v1 1 s / 10 MB defaults to be more
realistic for programs that orchestrate real subprocess upstreams.

| Flag | Env var | Default (aggregator) | Meaning |
|---|---|---|---|
| `--upstreams-config` | `PTC_RUNNER_MCP_UPSTREAMS` | (XDG default) | Path to upstreams JSON. Aggregator mode is enabled iff at least one upstream is configured. |
| `--program-timeout-ms` | `PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS` | `10_000` (10 s) | Outer wall-clock cap on the PTC-Lisp program (replaces v1's 1 s). |
| `--program-memory-limit-bytes` | `PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES` | `100 * 1024 * 1024` (100 MB) | Sandbox heap cap (replaces v1's 10 MB). |
| `--upstream-call-timeout-ms` | `PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS` | `5_000` (5 s) | Per-upstream-call wall-clock cap. Exceeded → call returns `nil` + entry with reason `timeout`. |
| `--max-upstream-response-bytes` | `PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES` | `2 * 1024 * 1024` (2 MB) | Per-response size cap, enforced pre-decode. Exceeded → `nil` + `response_too_large`. |
| `--max-upstream-calls-per-program` | `PTC_RUNNER_MCP_MAX_UPSTREAM_CALLS_PER_PROGRAM` | `50` | Total `tool/mcp-call` budget per program. Exceeded → `nil` + `cap_exhausted`. Stops `pmap` over an unbounded list from runaway-firing. |

CLI flag wins over env var; aggregator-mode defaults only apply
when no explicit value is given.

### Failure model in 30 seconds

`(tool/mcp-call ...)` returns one of three things:

- **A value** when the upstream's `tools/call` succeeded. The
  returned shape is the upstream's full MCP envelope —
  `%{"content" => [%{"type" => "text", "text" => "..."}], ...}`
  for most upstreams. Drill in with `(get-in result [:content 0
  :text])` (PTC-Lisp's `get-in` accepts keyword or string keys
  interchangeably).
- **`nil`** for *world-fault* failures — upstream unavailable,
  timeout, response oversize, per-program cap exhausted. The
  `upstream_calls` array on the response carries the reason.
- **A runtime error envelope** for *programmer-fault* failures —
  unknown server, unknown tool on a started upstream, args that
  aren't JSON-encodable. The program terminates with a `runtime_error`
  reason; the LLM should fix the program rather than retry.

Programs that don't care about the distinction can write
`(remove nil? results)` to discard world-faults and `(when result
...)` to skip individual `nil`s.

## Tracing for power users

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
