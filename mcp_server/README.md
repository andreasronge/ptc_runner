# ptc_runner_mcp

[![Hex.pm](https://img.shields.io/hexpm/v/ptc_runner_mcp.svg)](https://hex.pm/packages/ptc_runner_mcp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ptc_runner_mcp)

An [MCP](https://modelcontextprotocol.io/) server that exposes
[PtcRunner](https://hex.pm/packages/ptc_runner)'s PTC-Lisp sandbox
to any MCP client (Claude Desktop, Cursor, Cline, Claude Code, …)
over stdio JSON-RPC. In default mode the server advertises
`ptc_lisp_execute`, which accepts a PTC-Lisp program plus optional
`context` and `signature`, runs it in an isolated BEAM process
(1 s wall-clock, 10 MB memory, no I/O except `println`, no
filesystem, no network — see [aggregator mode](#aggregator-mode)
for an opt-in way to call other MCP servers from inside the
sandbox), and returns a structured result. In aggregator mode, the
experimental [agentic mode](#agentic-mode) can also expose
`ptc_task`, a natural-language task tool backed by a configured
planner model.

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
| `--aggregator-read-only` | `PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY` | `false` | Aggregator-mode annotation override for upstream configs that are read-only by construction. |
| `--agentic` | `PTC_RUNNER_MCP_AGENTIC` | `false` | Expose the experimental `ptc_task` tool when aggregator mode is active. |
| `--agentic-model` | `PTC_RUNNER_MCP_AGENTIC_MODEL` | `gemini-flash-lite` | Planner model alias or provider-qualified model id. |
| `--agentic-task-timeout-ms` | `PTC_RUNNER_MCP_AGENTIC_TASK_TIMEOUT_MS` | `45000` | Wall-clock cap for one `ptc_task` request. |
| `--agentic-planner-timeout-ms` | `PTC_RUNNER_MCP_AGENTIC_PLANNER_TIMEOUT_MS` | `15000` | Per-planner-call timeout. |
| `--agentic-max-output-tokens` | `PTC_RUNNER_MCP_AGENTIC_MAX_OUTPUT_TOKENS` | `1200` | Planner output token cap. |
| `--agentic-max-result-bytes` | `PTC_RUNNER_MCP_AGENTIC_MAX_RESULT_BYTES` | `4096` | Maximum rendered answer bytes in the `ptc_task` response. |
| `--agentic-include-program` | `PTC_RUNNER_MCP_AGENTIC_INCLUDE_PROGRAM` | `true` | Include the generated PTC-Lisp program in `ptc_task` responses. |
| `--agentic-trace-prompts` | `PTC_RUNNER_MCP_AGENTIC_TRACE_PROMPTS` | `false` | Include agentic prompt snapshots in traces. Use only for local debugging. |
| `--agentic-max-turns` | `PTC_RUNNER_MCP_AGENTIC_MAX_TURNS` | `1` | Maximum SubAgent planner turns per `ptc_task`. |
| `--agentic-retry-turns` | `PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS` | `0` | Additional retry turns after parser/runtime/validation feedback. |
| `--agentic-allow-writes` | `PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES` | `false` | Permit `ptc_task` in write-capable or unknown-effect aggregator configurations. |
| `--agentic-subagent-config` | `PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG` | unset | JSON config file for `max_turns`, `retry_turns`, and prompt prefix/suffix. |
| `--agentic-capability-summary-max-bytes` | `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY_MAX_BYTES` | `800` | Byte cap for the auto-generated `ptc_task` capability summary. |
| `--agentic-capability-summary` | `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY` | unset | Path to an operator-supplied capability summary for `ptc_task`. |

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

The `${VAR}` placeholders inside stdio `env` are resolved from the
parent process at startup (e.g., `"GITHUB_TOKEN": "${GITHUB_TOKEN}"`).
Unset variables fail-fast with a clear startup error.

**HTTP upstreams** (Streamable HTTP rev 2025-06-18) plug in the same
way alongside stdio entries, with a top-level `credentials:` block
for bearer / basic / custom-header auth:

```json
{
  "credentials": {
    "github-pat": { "source": "env", "var": "GITHUB_PAT" }
  },
  "upstreams": {
    "github": {
      "transport": "http",
      "url": "https://api.githubcopilot.com/mcp/",
      "auth": [{ "scheme": "bearer", "binding": "github-pat" }],
      "static_headers": { "X-MCP-Readonly": "true" }
    },
    "fs": { "command": "npx", "args": ["--yes", "@modelcontextprotocol/server-filesystem", "/tmp"] }
  }
}
```

Mixed transports work transparently; from a PTC-Lisp program's
view, `(tool/mcp-call {:server "github" ...})` and
`(tool/mcp-call {:server "fs" ...})` are indistinguishable. Full
config + auth-emitter + redaction reference in
[`docs/aggregator-mode.md`](../docs/aggregator-mode.md).

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

### Codex configuration

Codex reads MCP servers from `~/.codex/config.toml` and can be
configured with `codex mcp add`. For aggregator setups where all
upstreams are read-only by construction, set
`PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY=true` (or pass
`--aggregator-read-only`) so Codex sees `ptc_lisp_execute` as
non-destructive. Without this setting, aggregator mode advertises the
conservative worst case (`destructiveHint: true`) because arbitrary
upstreams may mutate or delete data; noninteractive Codex runs may
cancel such tool calls.

Example read-only GitHub upstream config:

```json
{
  "upstreams": {
    "github": {
      "command": "docker",
      "args": [
        "run", "-i", "--rm",
        "-e", "GITHUB_PERSONAL_ACCESS_TOKEN",
        "-e", "GITHUB_READ_ONLY=1",
        "-e", "GITHUB_TOOLSETS=repos,issues,pull_requests",
        "ghcr.io/github/github-mcp-server"
      ],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}"
      },
      "handshake_timeout_ms": 60000
    }
  }
}
```

Example wrapper:

```bash
cat > ~/ptc-mcp-sandbox/run-codex.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token)"
export PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY=true

exec 2>>"$HOME/ptc-mcp-sandbox/server.stderr.log"
cd /absolute/path/to/ptc_runner/mcp_server
exec /opt/homebrew/bin/mix run --no-halt --no-compile -- \
  --upstreams-config "$HOME/ptc-mcp-sandbox/upstreams.json"
EOF
chmod +x ~/ptc-mcp-sandbox/run-codex.sh
codex mcp add ptc-runner -- ~/ptc-mcp-sandbox/run-codex.sh
```

`--aggregator-read-only` is an operator assertion, not a policy
engine. It changes MCP annotations only. Upstream servers still need
to enforce read-only behavior themselves (for example,
`GITHUB_READ_ONLY=1`, narrow GitHub toolsets, scoped filesystem
directories, or upstream-specific read-only modes).

### What the LLM sees

Even with N upstreams configured, the client's `tools/list` returns
**exactly one tool**, `ptc_lisp_execute`. Upstream tools are not
re-advertised individually — they're folded into that tool's
`description` field as a compact, deterministic catalog rendered
once at server boot from each upstream's own `tools/list` response
(cached in `:persistent_term`; rebuilt only on PtcRunner restart).

The `description` string concatenates three sections:

1. A one-paragraph capability statement.
2. The aggregator authoring card (calling convention, `nil` /
   `:json-null` semantics, sandbox restrictions).
3. The **upstream catalog** — one block per upstream, in the shape:

   ```
   <server>:
     <tool>(<arg>: <type>, <optional>: <type>?) - <description, ≤80 chars>
   ```

Catalog rendering rules (from `Upstream.Catalog`):

- Required args first in schema order; optional args alphabetically with a trailing `?`.
- Complex types collapse to bare names — `array`, `object`. Item shapes are not shown.
- `enum` constraints render as `enum<string>` (or bare `enum` for heterogeneous values); `const` as `const<"value">`.
- Descriptions are whitespace-collapsed and hard-truncated at 80 codepoints with `...`.
- Upstreams that failed to start at boot render as `(unavailable at startup)`.

Example slice from a config with the official `server-filesystem`
and `server-memory` upstreams:

```
fs:
  read_text_file(path: string, head: number?, tail: number?) - Read the complete contents of a file from the file system as text. Handles va...
  write_file(path: string, content: string) - Create a new file or completely overwrite an existing file with new content. ...
  list_directory_with_sizes(path: string, sortBy: enum<string>?) - Get a detailed listing of all files and directories in a specified path, incl...
  search_files(path: string, pattern: string, excludePatterns: array?) - Recursively search for files and directories matching a pattern. The patterns...

mem:
  read_graph() - Read the entire knowledge graph
  search_nodes(query: string) - Search for nodes in the knowledge graph based on a query
  open_nodes(names: array) - Open specific nodes in the knowledge graph by their names
```

For a 2-upstream / 23-tool config the full `description` is around
6 KB (~1,500 tokens) — that's the entire upstream API surface the
LLM has to work from. It then writes calls like:

```clojure
(tool/mcp-call {:server "fs" :tool "read_text_file"
                :args {:path "/tmp/notes.txt" :head 20}})
```

At call time, `:server` and `:tool` are validated against the
same cached `tools/list` data — unknown server / tool on a healthy
upstream raises a programmer-fault `runtime_error` so the LLM can
self-correct against the catalog it was given.

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
| `--aggregator-read-only` | `PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY` | `false` | Advertise aggregator mode as read-only/non-destructive for clients like Codex when upstreams enforce read-only behavior. |

CLI flag wins over env var; aggregator-mode defaults only apply
when no explicit value is given.

### Failure model in 30 seconds

`(tool/mcp-call ...)` returns one of three things:

- **A value** when the upstream's `tools/call` succeeded. The
  returned shape is the upstream's full MCP envelope —
  `%{"content" => [%{"type" => "text", "text" => "..."}], ...}`
  for most upstreams. Use `(mcp/text r)` to extract the first
  text item, `(mcp/json r)` to get parsed JSON (it prefers the
  typed `structuredContent` channel — populated natively by some
  upstreams, or via aggregator auto-decode when the upstream
  declares `mimeType: application/json`/`+json`). The classic
  `(get-in result [:content 0 :text])` still works (PTC-Lisp's
  `get-in` accepts keyword or string keys interchangeably) but
  the helpers are the preferred path. See
  [`docs/aggregator-mode.md`](../docs/aggregator-mode.md) §"JSON
  helpers" for the full table.
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

Common LLM authoring mistake: upstream calls return the upstream's
MCP tool-result envelope, not always the direct business value. Prefer
`(mcp/text result)` for text content and `(mcp/json result)` for JSON
payloads instead of hand-rolled `get-in` chains.

## Agentic mode

Agentic mode is an experimental layer on top of aggregator mode. It
adds a second MCP tool, `ptc_task`, for clients that want to ask for a
natural-language task instead of authoring PTC-Lisp directly. The
server uses the configured planner model to run a SubAgent in explicit
completion mode, with one MCP-owned tool available inside the planner:
`tool/mcp-call`. The planner may call upstream MCP servers, inspect the
tagged result, and must finish with `(return ...)` or `(fail ...)`.

`ptc_task` does not replace `ptc_lisp_execute`. Both tools are
advertised when all of these are true:

- at least one upstream MCP server is configured;
- `--agentic` or `PTC_RUNNER_MCP_AGENTIC=true` is set;
- the aggregator posture is read-only, or
  `--agentic-allow-writes` / `PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES=true`
  is set explicitly.

### Quick start

Use the same upstream config as [aggregator mode](#aggregator-mode),
then enable agentic mode and provide an LLM key for the planner
provider. The default `gemini-flash-lite` alias resolves inside
PtcRunner to `openrouter:google/gemini-3.1-flash-lite`.

```bash
export OPENROUTER_API_KEY=...
export PTC_RUNNER_MCP_UPSTREAMS="$HOME/ptc-mcp-sandbox/upstreams.json"
export PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY=true
export PTC_RUNNER_MCP_AGENTIC=true
export PTC_RUNNER_MCP_AGENTIC_MODEL=gemini-flash-lite

cd /absolute/path/to/ptc_runner/mcp_server
mix run --no-halt --no-compile
```

Equivalent release-binary args:

```json
"args": [
  "start",
  "--upstreams-config", "/absolute/path/to/upstreams.json",
  "--aggregator-read-only",
  "--agentic",
  "--agentic-model", "gemini-flash-lite"
]
```

Once enabled, clients call:

```json
{
  "name": "ptc_task",
  "arguments": {
    "task": "Read README.md and return the first 5 non-empty lines.",
    "constraints": {
      "output_format": "text",
      "max_items": 5
    }
  }
}
```

The response includes:

- `status`: `"ok"` or `"error"`;
- `answer` and, when applicable, `structured_result`;
- `program`, unless `--agentic-include-program=false`;
- `upstream_calls`, the ledger of MCP calls made by the planner;
- `planner` metadata, including model, turn count, duration, and token
  fields when the provider reports them.

### Turns and write safety

By default `ptc_task` runs with `max_turns: 1` and `retry_turns: 0`.
That keeps the planner cheap and predictable, but a model may fail if
it needs feedback to correct a generated program. Raise
`--agentic-max-turns` for multi-turn planner repair. Read-only
continuations may use parser/runtime/validation feedback. After any
write-capable or unknown-effect upstream call, `ptc_task` blocks
further continuation unless the planner returns or fails in the same
turn; this avoids retrying after partial side effects.

`--agentic-allow-writes` is intentionally separate from
`--aggregator-read-only`. If the aggregator is not asserted read-only,
agentic boot fails unless writes are explicitly allowed. Upstream
servers still own the real permission boundary.

### SubAgent config file

For deployment-specific prompt guidance, use a small JSON file:

```json
{
  "max_turns": 2,
  "retry_turns": 1,
  "system_prompt": {
    "prefix": "Prefer read-only tools and keep answers concise.",
    "suffix": "Return JSON only when the task asks for JSON."
  }
}
```

Pass it with `--agentic-subagent-config /path/to/agentic.json` or
`PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG=/path/to/agentic.json`.
Allowed keys are `max_turns`, `retry_turns`, and `system_prompt`
with `prefix` / `suffix`. Reserved keys such as `tools`,
`completion_mode`, `signature`, and `ptc_transport` fail boot because
the MCP server owns those parts of the SubAgent contract. See
[`priv/agentic.example.json`](priv/agentic.example.json) and
[`priv/agentic.example.md`](priv/agentic.example.md).

### Capability summary

`ptc_task` advertises a compact capability summary instead of the full
aggregator authoring card. By default this is generated from the frozen
upstream catalog at boot, capped by
`--agentic-capability-summary-max-bytes`, and logged only as byte count
plus SHA-256 hash. To provide your own wording, set
`--agentic-capability-summary /path/to/summary.md`.

### Real-provider smoke

From `mcp_server/`, with `OPENROUTER_API_KEY` available:

```bash
mix run --no-start bench/agentic_real_provider_smoke.exs \
  --model=gemini-flash-lite \
  --runs=1 \
  --fail-on-skip
```

The smoke starts a local filesystem upstream and exercises `ptc_task`
through the real planner provider. It exits non-zero on failures and
prints the generated program for failed cases.

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

For local evaluation of aggregator benefits, run with:

```bash
--trace-dir /tmp/ptc-traces --trace-payloads full
```

Then inspect the JSONL trace file to see the generated PTC-Lisp
program, `program_bytes`, total call duration, and result size. The
MCP response's `upstream_calls` array records each upstream call's
server, tool, status, reason on failure, and duration. To estimate
token savings, compare:

- aggregator `tools/list` bytes vs the sum of native upstream
  `tools/list` bytes;
- aggregator final result bytes vs the sum of native upstream raw
  result bytes.

Use `--trace-payloads full` only for local debugging or measurement;
it records source programs and payload values. Use `summary` or
`none` for normal operation.

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
