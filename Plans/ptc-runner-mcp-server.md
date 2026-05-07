# PtcRunner MCP Server — v1 Specification

## Status

**Implementation spec.** The shared protocol module
(`PtcRunner.PtcToolProtocol`, formerly Phase 0 of this plan) shipped on
main and is the wire-format source of truth. This document specifies a
new hex package `ptc_runner_mcp` that exposes one MCP tool —
`ptc_lisp_execute` — over stdio JSON-RPC.

Sibling plans:

- `text-mode-ptc-compute-tool.md` — in-process counterpart; same
  response contract, different request contract and capability profile.
- `ptc-runner-mcp-aggregator.md` — opt-in extension that lets PTC-Lisp
  programs call upstream MCP servers; depends on this plan.

## Targets pinned for v1

| Concern | Value |
|---|---|
| MCP protocol version (primary) | `2025-11-25` |
| MCP protocol version (compatibility floor) | `2025-06-18` |
| JSON-RPC version | `2.0` |
| Transport | stdio, NDJSON-framed |
| Server package | `ptc_runner_mcp` (depends on `ptc_runner`) |
| Repository layout | Same git repo, two top-level Mix projects (§ 5.2) |
| Server-package versioning | Independent semver, published to Hex separately |
| Server tool count | 1 (`ptc_lisp_execute`) |
| Capability profile | `:mcp_no_tools` |
| State across calls | None |

## 1. Summary

`ptc_runner_mcp` is a long-running process speaking JSON-RPC over stdio.
It advertises one tool, `ptc_lisp_execute`, accepting a PTC-Lisp program
plus optional `context` and `signature`, and returns a structured
result. Each invocation runs in a fresh sandbox (1s wall-clock execution timeout, 10MB
memory cap, no I/O except `println`, no filesystem, no network). No
state persists between calls.

The server has no LLM. The MCP client's LLM does the reasoning;
PtcRunner is invoked only when deterministic computation is useful.

## 2. Motivation and positioning

PtcRunner's deterministic-compute affordance has so far been Elixir-only.
MCP makes the same primitive callable from Claude Desktop, Cursor,
Cline, Claude Code, and any other MCP client.

The pitch over Python/JS execution servers:

- **Sandboxed by construction.** No filesystem, no network, no
  arbitrary process exec; only PTC-Lisp built-ins and `println`.
- **Designed for LLM authoring.** No imports, no setup, every program
  is a self-contained expression.
- **Schemas as types.** Optional `signature:` validates and coerces the
  return value; programmatic clients consume the validated value.
- **Stable wire format.** Same response contract as in-process
  PtcRunner surfaces, so logs and tests carry over.

This is **Feature A** — a stateless one-tool server. Two follow-ups
referenced throughout but explicitly deferred:

- **Feature B** — `SubAgent.run/2` over MCP (delegated PtcRunner
  agents). Cross-cutting LLM-cred and cost concerns; defer until A
  proves demand.
- **MCP Aggregator** — upstream MCP tools callable from inside
  PTC-Lisp programs. Specified in `ptc-runner-mcp-aggregator.md`.

## 3. Scope comparison: MCP v1 vs sibling surfaces

| Concern | In-process PTC `:tool_call` (v1) | Text-mode combined (v1) | MCP v1 |
|---|---|---|---|
| App tools inside programs | All registered | `:both`-tagged only | None |
| Tool cache across calls | Within a `run/2` | Within a `run/2` | Stateless |
| Sessions / state | Loop-scoped | Loop-scoped | Per call |
| Multi-call rule | exclusive in turn | exclusive vs native | one tool per `tools/call` |
| System prompt | Caller-supplied | Caller-supplied + compact card | None — caller's LLM owns prompt |
| LLM client | PtcRunner | PtcRunner | Caller's MCP client |
| Capability profile | `:in_process_with_app_tools` | `:in_process_text_mode` | `:mcp_no_tools` |

The asymmetry is intentional. MCP v1 is the pure primitive: execute a
program, return the result. Anything that creeps from the in-process
columns into MCP v1 has to argue against this table.

## 4. Non-goals

- No exposure of `SubAgent.run/2` over MCP (Feature B; deferred).
- No app tools inside programs (Aggregator plan; deferred).
- No stateful sessions. Each `tools/call` is independent.
- No streaming `println` output. Programs are fast (1s cap).
- No flipping of any defaults in the `ptc_runner` library.
- No reaching into `Loop.PtcToolCall`, `TurnFeedback`, or `JsonHandler`
  internals — `PtcRunner.PtcToolProtocol` is the only consumed
  surface.
- No widening of `PtcRunner.PtcToolProtocol.error_reason()` or
  `render_error/3` to admit `:busy` / `:unknown_tool`. MCP-only
  reasons stay inside the MCP package (see § 10.3).

## 5. Shared protocol module — status

**Shipped.** `lib/ptc_runner/ptc_tool_protocol.ex` exists and is the
single source of truth for:

- `tool_description/1` — capability-profile constants
  (`:in_process_with_app_tools`, `:in_process_text_mode`,
  `:mcp_no_tools`).
- `render_success/2`, `render_error/3` — R22/R23 JSON renderers.
- `error_reason()` typespec — the closed union.
- `lisp_run/2`, `atomize_value/2`, `validate_return/2` — re-exports.

This package consumes the module as-is. It does **not** add new
capability profiles in v1 (the aggregator plan adds `:mcp_aggregator`).

## 5.2 Repository layout

`ptc_runner_mcp` lives in the same git repo as `ptc_runner`, as a
second top-level Mix project. Both packages publish to Hex
independently with their own versions.

```
ptc_runner/                             # existing library project root
├── mix.exs                             # :ptc_runner package (existing)
├── mix.lock
├── lib/                                # existing :ptc_runner source
├── test/                               # existing :ptc_runner tests
├── config/
├── priv/
├── Plans/
├── docs/
├── demo/
└── mcp_server/                         # NEW: :ptc_runner_mcp project root
    ├── mix.exs                         # :ptc_runner_mcp package
    ├── mix.lock                        # independent lockfile
    ├── lib/
    │   └── ptc_runner_mcp/
    │       ├── application.ex          # OTP app, supervisor, CLI entry
    │       ├── stdio.ex                # NDJSON line reader / writer
    │       ├── json_rpc.ex             # request/notification dispatch
    │       ├── lifecycle.ex            # initialize, shutdown, exit
    │       ├── tools.ex                # tools/list, tools/call
    │       ├── envelope.ex             # MCP result envelope (§ 10)
    │       ├── limits.ex               # frame/program/context size, semaphore
    │       ├── log.ex                  # JSON-Lines stderr logger
    │       └── version.ex              # MCP protocol version negotiation
    ├── test/
    ├── config/
    └── .credo.exs                      # may inherit or override root config
```

### Mix project shape

`mcp_server/mix.exs`:

```elixir
defmodule PtcRunnerMcp.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ptc_runner_mcp,
      version: @version,
      elixir: "~> 1.15",
      deps: deps(),
      package: package(),
      aliases: aliases(),
      description: "MCP server exposing PtcRunner's PTC-Lisp sandbox over stdio JSON-RPC.",
      source_url: "https://github.com/andreasronge/ptc_runner",
      ...
    ]
  end

  def application do
    [
      mod: {PtcRunnerMcp.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Path dep for in-tree dev; replaced by hex range when published.
      {:ptc_runner, path: "..", override: true},
      {:jason, "~> 1.4"},

      # Dev-only
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Andreas Ronge"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/andreasronge/ptc_runner"},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp aliases do
    [
      precommit: ["format --check-formatted", "compile --warnings-as-errors",
                  "credo --strict", "dialyzer", "test"],
      "mcp.start": ["run --no-halt"],
      "mcp.run":   ["run --no-halt"]
    ]
  end
end
```

### Path-dep vs Hex-dep wiring

Two reasonable strategies; pick one and document in `CONTRIBUTING.md`:

**Strategy A — path dep in dev, Hex dep on publish (recommended).**
The repo's working tree always has `{:ptc_runner, path: ".."}`.
Releases of `ptc_runner_mcp` swap to `{:ptc_runner, "~> X.Y"}` at
publish time via a release script. CI runs against the path dep so
in-flight changes to `ptc_runner` are exercised by `ptc_runner_mcp`
tests.

**Strategy B — Hex dep always.** `mcp_server/` always points at a
published `ptc_runner` version; cross-cutting changes require a
two-stage release (publish `ptc_runner` first, then bump the dep in
`mcp_server`). Cleaner but adds friction during 0.x churn.

Strategy A wins for now because the protocol module is still settling.

### Independent start/stop

`ptc_runner_mcp` defines its own OTP application (`PtcRunnerMcp.Application`)
with a supervision tree that owns the stdio reader, writer, and
sandbox semaphore. Lifecycle commands available from the project root:

| Command (run from `mcp_server/`) | Effect |
|---|---|
| `mix mcp.start` / `mix mcp.run` | Start the server in the foreground (stdio attached). |
| `mix release` | Build a Mix release for distribution. |
| `_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp start` | Start a release. |
| `… stop`, `… restart`, `… remote` | Standard Mix release lifecycle. |
| Burrito-bundled binary (Phase 5) | Single-file invocation for non-Elixir users. |

The `:ptc_runner` library project does NOT start the MCP server in
its supervision tree. The library remains usable without the MCP
package installed.

### Third-party dependencies

`ptc_runner_mcp` MAY depend on third-party libraries that
`ptc_runner` itself avoids (e.g., a CLI argument parser, structured
logger formatter, or an MCP framework if one is adopted later — see
§ 5.4). Its dep list is independent.

## 5.3 Tooling and quality gates

Both projects MUST pass the same gates: `format --check-formatted`,
`compile --warnings-as-errors`, `credo --strict`, `dialyzer`, and
`test`. Each project owns its own `.formatter.exs`, `.credo.exs`
(may inherit from root), and Dialyzer PLT.

### Git hooks

The existing `.git/hooks/pre-commit` and `.git/hooks/pre-push` run
the gates from the repo root. They MUST be extended so any change
under `mcp_server/` triggers the same gates inside that directory.

The repo now has **three** top-level Mix projects: `:ptc_runner`
(root), `:ptc_runner_mcp` (`mcp_server/`), and `:ptc_viewer`
(`ptc_viewer/`). Hooks run a per-project loop:

```bash
PROJECTS=("." "mcp_server" "ptc_viewer")
for proj in "${PROJECTS[@]}"; do
  if git diff --cached --name-only | grep -qE "^${proj#./}/"; then
    (cd "$proj" && mix format --check-formatted && \
                   mix compile --warnings-as-errors && \
                   mix credo --strict)
  fi
done
```

with the same scoping rules as the existing hook (Elixir/config/mix
file detection, deleted-module rebuild, scoped test runs). The
pre-push hook runs the full test suite and Dialyzer in **both**
projects.

The DoD for Phase 1 includes: hooks updated, both projects pass on
clean main, and a sentinel test in `mcp_server/test/` is exercised
by pre-push.

### CI

CI matrix runs `mix precommit` in `.`, `mcp_server/`, and
`ptc_viewer/` independently. Failures in any project fail the build.

### Release flow

Each package publishes to Hex independently:

1. Bump version in `<package>/mix.exs`.
2. Update `<package>/CHANGELOG.md`.
3. `cd <package>/ && mix hex.publish`.
4. Tag the repo as `ptc_runner-vX.Y.Z` or `ptc_runner_mcp-vX.Y.Z`.

Cross-cutting changes that touch `PtcRunner.PtcToolProtocol` (the
shared wire surface) follow this order: publish `ptc_runner` first,
bump the Hex dep range in `mcp_server/mix.exs`, then publish
`ptc_runner_mcp`.

## 5.4 Implementation: hand-roll vs MCP framework

v1 hand-rolls the JSON-RPC transport and dispatcher. The spec's wire
decisions (structured + mirrored text envelope; `isError` for
`(fail v)`; `busy` and `unknown_tool` as tool-result errors;
`max_frame_bytes` enforced pre-parse) are precise enough that
adopting an MCP framework would require either matching it against
the spec line-by-line or bending the spec around the framework's
defaults.

The transport is small: NDJSON line reader, JSON-RPC dispatcher, ~5
method handlers — probably 300–500 lines of Elixir.

**Reconsider adopting an MCP framework when any of the following
becomes true** (none are v1 scope):

- Streamable HTTP / SSE transport.
- OAuth / OIDC authentication.
- Multi-tenant session management.
- `resources` or `prompts` surfaces with non-trivial routing.

At that point, evaluate then-current Elixir MCP libraries against the
locked spec. The hand-rolled v1 code is small enough to retire if a
framework matches.

## 6. Transport

### 6.1 Framing

NDJSON over stdio: one UTF-8 JSON-RPC 2.0 message per line, terminated
by `\n`. No `Content-Length` headers. Stdout MUST contain only MCP
messages; the server MUST NOT print anything else to stdout (no banners,
no startup text). Logs go to stderr only.

### 6.2 Frame size limit

`max_frame_bytes` (default **8 MB**) is enforced at the line reader
**before** JSON parsing. Lines exceeding the cap are rejected with
JSON-RPC error `-32700 Parse error`; the offending bytes are discarded
and the reader resyncs at the next newline. This is the first line of
defense against allocation-bomb requests.

`max_frame_bytes` MUST be at least
`max_program_bytes + max_context_bytes + 64 KB` of envelope overhead.

### 6.3 Concurrency and ordering

JSON-RPC allows out-of-order responses paired by request ID. The server
MAY dispatch incoming `tools/call` requests in parallel up to
`max_concurrent_calls` (§ 11). Responses are emitted as soon as each
program completes; ordering is not preserved.

### 6.4 Lifecycle

| Event | Server behavior |
|---|---|
| stdin EOF | Cancel all in-flight sandboxes; emit no further responses; exit 0. |
| `shutdown` request (if sent) | Reply `null`; transition to drain; on subsequent `exit` notification, exit 0. |
| `notifications/cancelled` for in-flight ID | Kill the sandbox process; emit no response for that ID. |
| `notifications/cancelled` for unknown/already-completed ID | Ignore silently. |
| Unhandled BEAM crash in request handler | Log to stderr; emit `-32603 Internal error` referencing the request ID; continue serving. |

### 6.5 Logging

Logs go to **stderr** as **JSON Lines** (one event per line). Minimum
fields per event:

```json
{"ts": "2026-05-07T12:34:56.789Z", "level": "info", "event": "tools_call_start", "request_id": "42", "fields": {...}}
```

Log levels: `debug`, `info`, `warn`, `error`. Default level: `info`.
Configurable via `--log-level` flag and `PTC_RUNNER_MCP_LOG_LEVEL` env
var.

The server MUST NOT log full program source or full `context` payloads
at `info` level (avoid leaking client data into operator logs); these
are `debug`-level only.

### 6.6 Per-call execution traces (opt-in)

Stderr operational logs (§ 6.5) are for operators tailing service
output. Per-call **execution traces** are a separate, opt-in stream
that lands as JSONL files browseable by `ptc_viewer`. Default: off.
Enable with `--trace-dir <dir>` or `PTC_RUNNER_MCP_TRACE_DIR=<dir>`.

When enabled, each `tools/call` is wrapped in
`PtcRunner.TraceLog.with_trace/2`. The trace file contains the events
defined in § 6.7, written by a handler living in
`:ptc_runner_mcp` (see § 6.8). The handler emits **truthful events
only** — no synthetic SubAgent `run`/`turn`/`llm` events. The
trace_kind, producer, and model fields on the header line are pinned
so consumers (including `ptc_viewer`) can distinguish MCP traces
from SubAgent traces:

```json
{"event": "trace.start",
 "trace_kind": "mcp_call",
 "producer": "ptc_runner_mcp",
 "trace_label": "<request_id>",
 "model": null,
 "query": "<program preview per § 6.9>"}
```

`ptc_viewer` panes that depend on LLM/turn events will be empty for
MCP traces in v1; this is accepted (a flat MCP-execution view in
`ptc_viewer` is deferred — see § 18).

### 6.7 Telemetry event taxonomy

Two new prefixes are introduced. Both use the standard
`:telemetry.span` shape (matching what `TraceLog.Handler` already
expects).

**MCP-server lifecycle (lives in `:ptc_runner_mcp`):**

| Event | Emitted | Measurements | Metadata |
|---|---|---|---|
| `[:ptc_runner_mcp, :call, :start]` | On `tools/call` arrival, after arg validation | `system_time` | `request_id`, `tool_name`, `program_bytes`, `context_bytes`, `signature_present?`, `protocol_version` |
| `[:ptc_runner_mcp, :call, :stop]` | On `tools/call` completion | `duration` | `request_id`, `status` (`ok` \| `error`), `reason` (when `status: error`), `is_error` (envelope flag), `validated_present?` |
| `[:ptc_runner_mcp, :call, :exception]` | On uncaught error in the request handler | `duration` | `request_id`, `kind`, `reason`, `stacktrace` |

**Lisp execution (lives in `:ptc_runner`, additive):**

| Event | Emitted | Measurements | Metadata |
|---|---|---|---|
| `[:ptc_runner, :lisp, :execute, :start]` | At `Lisp.run/2` entry | `system_time` | `program_bytes`, `signature_supplied?`, `caller` (`:in_process_v1` \| `:text_mode` \| `:mcp`) |
| `[:ptc_runner, :lisp, :execute, :stop]` | At `Lisp.run/2` exit | `duration` | `status` (`ok` \| `error`), `reason` (when `error`), `prints_count`, `result_bytes` |
| `[:ptc_runner, :lisp, :execute, :exception]` | On uncaught error inside `Lisp.run/2` | `duration` | `kind`, `reason`, `stacktrace` |

**`caller` metadata mechanism.** `Lisp.run/2` gains a new keyword
option `:caller` accepting an atom in
`#{:in_process_v1, :text_mode, :mcp}`. The option is opaque to
`Lisp.run/2`'s execution semantics — it is read once at entry and
attached to the `start` / `stop` / `exception` event metadata, then
discarded. Default value when the option is omitted: `:in_process_v1`.
This default is intentionally lossy — call sites that care about
distinguishing themselves in traces MUST pass `:caller` explicitly.

Call-site responsibilities:

| Call site | Owns passing `caller:` |
|---|---|
| In-process `:tool_call` surface | no — relies on `:in_process_v1` default |
| `PtcRunner.SubAgent` / `Loop` | no — relies on default |
| Text-mode combined-mode surface | yes (`caller: :text_mode`); coordinated with the text-mode plan |
| `:ptc_runner_mcp` request handler | yes (`caller: :mcp`) |
| Tests calling `Lisp.run/2` directly | no — default is fine |

The atom set is **closed**: any value outside the three listed atoms
raises `ArgumentError` at `Lisp.run/2` entry. Adding a fourth caller
(e.g., a future HTTP transport) requires extending this atom set in
`:ptc_runner` and updating this section.

These `:ptc_runner` events benefit every caller (in-process v1,
text-mode, MCP) and are added as a small additive change to
`:ptc_runner` (§ 15 Phase 0.5).

The MCP server MUST NOT emit events under
`[:ptc_runner, :sub_agent, ...]`. That namespace belongs to
SubAgent runs and using it would lie about the execution model.

### 6.8 Trace handler placement

The trace handler that converts MCP and Lisp events into JSONL lives
in `:ptc_runner_mcp` (e.g., `PtcRunnerMcp.TraceHandler`). It attaches
to the events in § 6.7 and writes through `PtcRunner.TraceLog`'s
public surface — never through writer internals.

Required additive surface on `:ptc_runner` (one function):

```elixir
PtcRunner.TraceLog.write_to_active(event_map :: map()) :: :ok | :no_collector
```

Writes a serialized event line to the **innermost active collector**
in the calling process's collector stack (set up by
`TraceLog.with_trace/2` or `TraceLog.start/1`). Returns `:no_collector`
when called outside a `with_trace` scope, never raises. This is the
only `:ptc_runner` change required to support the MCP handler;
storage and rotation stay in `:ptc_runner`, event taxonomy stays in
`:ptc_runner_mcp`.

### 6.9 Payload policy

Trace files MAY contain user data, programs, and `context` payloads.
The `--trace-payloads` flag (also `PTC_RUNNER_MCP_TRACE_PAYLOADS`)
controls capture. Three levels:

| Level | Program | Context | Validated value | Prints |
|---|---|---|---|---|
| `none` | SHA-256 + byte count | byte count only | shape (JSON-Schema-ish skeleton, no values) | count only |
| `summary` (**default**) | SHA-256 + first 256 chars + byte count | keys with type and element-count per key (no values) | shape + top-level types | count + truncated first line per print |
| `full` | full source | full JSON | full JSON value | full strings |

Default is `summary`, not `full`. `--trace-dir` is opt-in already;
defaulting `summary` keeps a developer-enabled trace folder from
silently capturing prompts and contextual data they didn't mean to
persist.

Pinned summary semantics (do not handler-define):

- **Program**: `{"sha256": "<hex>", "preview": "<first 256 utf-8 chars>", "bytes": <int>}`.
- **Context**: `{"<key>": {"type": "object|array|string|number|boolean|null", "count": <int|null>}}` per top-level key. `count` populated for arrays (length) and objects (key count); `null` otherwise.
- **Validated shape**: `{"type": "object", "keys": ["a","b","c"]}` for objects; `{"type": "array", "length": N, "element_type": "<inferred>"}` for arrays; `{"type": "<scalar>"}` for primitives.
- **Error reasons and messages**: ALWAYS captured in full at every payload level (debug requires it).

Stderr operational logs (§ 6.5) are independent of this policy.
`info`-level logs follow § 6.5's "no full programs / no full
contexts" rule regardless of `--trace-payloads`.

### 6.10 Trace file naming and rotation

**File naming**: `<iso8601-utc>-<request_id_hash8>-<status>.jsonl`,
e.g.
`2026-05-07T12:34:56.789Z-a1b2c3d4-ok.jsonl` /
`2026-05-07T12:34:56.789Z-a1b2c3d4-error.jsonl`.

- ISO-8601 timestamp keeps directory listings sorted by call time.
- 8-hex-char request-ID hash disambiguates same-millisecond calls
  without leaking full IDs into filenames.
- Trailing `-ok` / `-error` enables `ls *-error.jsonl` for triage.

**Rotation**: `--trace-max-files <N>` (default **1000**) caps the
number of files in the trace dir. On overflow, the oldest file by
mtime is deleted before the new one is written. The cap is FIFO
only — no compression, no archival. Operators wanting longer retention
should rotate the directory externally (cron, log shipper).

**Disk pressure**: when file creation fails (disk full, permission
denied), the server logs an error to stderr (§ 6.5) and continues
serving without tracing for that call. The `tools/call` response is
unaffected. A failed trace MUST NOT fail the underlying tool call.

## 7. MCP handshake

### 7.1 `initialize` request

The server supports two MCP protocol revisions for v1:

- **`2025-11-25`** (primary). The latest official revision at the time
  of v1.
- **`2025-06-18`** (compatibility floor). The first revision that
  supports `structuredContent`, `outputSchema`, and tool annotations;
  the wire surface this server depends on.

Negotiation rules (per MCP `basic/lifecycle`):

| Client `protocolVersion` in request | Server reply `protocolVersion` |
|---|---|
| `2025-11-25` | `2025-11-25` |
| `2025-06-18` | `2025-06-18` |
| Any other value | `2025-11-25` (server's latest supported) |

The server replies:

```json
{
  "protocolVersion": "<negotiated version>",
  "serverInfo": {
    "name": "ptc_runner_mcp",
    "version": "<package-semver>"
  },
  "capabilities": {
    "tools": { "listChanged": false }
  }
}
```

The implementation MUST NOT emit revision-specific fields unless they
are valid for the negotiated version. v1 deliberately scopes the wire
surface to the **stable subset both revisions share**: stdio transport,
`tools/list`, `tools/call`, `inputSchema`, `outputSchema`,
`annotations`, `structuredContent`, `isError`. The server does NOT use:

- Streamable HTTP / HTTP transports (stdio only).
- OAuth / OIDC (HTTP-only per the 2025-11-25 spec; stdio servers
  inherit credentials from the environment).
- Experimental `tasks`.
- `resources` / `prompts` surfaces.
- `elicitation`.
- `sampling` tool-calling.
- Icons metadata.
- Incremental OAuth scope consent.

`resources` and `prompts` capabilities are **omitted**, not set to
`false`. Adding them is a future, opt-in change.

### 7.2 `notifications/initialized`

Logged at `debug`; no other behavior. The server is ready to serve
`tools/*` from the moment it replies to `initialize`.

### 7.3 Versioning policy

- **`ptc_runner_mcp` package**: independent semver, published to Hex
  separately. Source lives in the same git repo under `mcp_server/`
  (§ 5.2).
- **`ptc_runner` dependency**: path dep (`{:ptc_runner, path: ".."}`)
  in development; swapped to a Hex range (`{:ptc_runner, "~> X.Y"}`)
  at publish time. CI runs against the path dep so cross-cutting
  protocol changes are exercised by `ptc_runner_mcp` tests in the
  same PR.
- **MCP `protocolVersion`**: each release declares a primary revision
  and a compatibility floor. v1 ships primary `2025-11-25`, floor
  `2025-06-18`. Dropping the floor (i.e., no longer accepting
  `2025-06-18` from clients) is a major version change for
  `ptc_runner_mcp`. Adding a newer primary while keeping the same
  floor is a minor version change. Adopting a newer revision's
  features that are NOT in the floor (e.g., experimental tasks)
  requires a new release with the floor raised accordingly.

### 7.4 Compatibility deviations

This section enumerates spots where v1 deliberately diverges from
common interpretations of the MCP 2025-11-25 / 2025-06-18 server
guidance. Each deviation has a rationale and a verification gate.

**D1 — Unknown tool names return a tool result, not a JSON-RPC
error.**

The MCP spec's `tools/call` example for an unknown tool name uses
JSON-RPC `-32602 Invalid params`. v1 instead returns an MCP tool
result with `isError: true` and `reason: "unknown_tool"` (§ 10.5).
Rationale: a single failure surface keeps clients on one branch —
they always get a tool-result envelope from `tools/call` regardless
of why the call failed. Pairs cleanly with `:busy`, which has no
JSON-RPC analog.

*Verification gate:* MCP Inspector (latest) accepts the tool result
without complaint, AND at least one production MCP client (Claude
Desktop or Cursor, whichever is reachable) renders the call
gracefully (no panic, no UI breakage, error visible to the user).
If either fails, v1 falls back to `-32602`. This gate is part of
Phase 1 DoD (handshake + tool-list smoke test) and Phase 6 (live
client integration test).

**D2 — Programs that return `nil` and emit no `prints` produce
success payloads without `"result"`.**

`PtcToolProtocol.render_success/2` elides `"result"` when both the
final-expression value and `lisp_step.return` are `nil`. The
`outputSchema` (§ 10.4) accordingly omits `"result"` from the
success branch's `required` list. MCP allows `outputSchema` to mark
fields optional, so this is spec-compliant — but it's a deviation
from "always include the same keys" payload designs.

*Verification gate:* an Inspector run against a `(println "hi")`
program (no return value) reports a clean success with `isError:
false` and no schema-validation error.

Future deviations land in this section; do not scatter them across
the doc.

## 8. Tool surface

### 8.1 `tools/list` response

Exactly one tool. The full JSON-RPC frame:

**Request (from client):**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list"
}
```

The server ignores any `params.cursor` from the client (no
pagination — there is only one tool).

**Response (from server):**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      {
        "name": "ptc_lisp_execute",
        "description": "<PtcToolProtocol.tool_description(:mcp_no_tools) + \"\\n\\n\" + authoring_card() per § 8.4>",
        "inputSchema": {
          "type": "object",
          "properties": {
            "program": {
              "type": "string",
              "description": "PTC-Lisp source code. Must be non-empty after trimming whitespace."
            },
            "context": {
              "type": "object",
              "description": "Optional map of named values bound under data/ in the program. Keys are strings; values are JSON-encodable.",
              "additionalProperties": true
            },
            "signature": {
              "type": "string",
              "description": "Optional PTC signature for return validation, e.g. '() -> {count :int}'."
            }
          },
          "required": ["program"]
        },
        "outputSchema": "<see § 10.4>",
        "annotations": {
          "readOnlyHint": true,
          "destructiveHint": false,
          "idempotentHint": true,
          "openWorldHint": false
        }
      }
    ]
  }
}
```

The response MUST omit `nextCursor` (single-page result).
`result.tools` always has length 1 in v1.

### 8.2 `notifications/tools/list_changed`

Never emitted. `listChanged: false` in capabilities.

### 8.3 Tool annotations rationale

- `readOnlyHint: true` — programs cannot perform side effects. This
  flips to `false` in the aggregator profile, where upstream MCP tools
  may write.
- `destructiveHint: false` — no destructive operations possible.
- `idempotentHint: true` — same `(program, context, signature)` →
  same response (modulo runtime resource exhaustion).
- `openWorldHint: false` — no network or filesystem; the world is
  closed.

### 8.4 Authoring guidance card

Unlike the in-process surfaces, MCP has no system prompt — the tool
`description` field is the only authoring surface the client's LLM
ever reads. `PtcToolProtocol.tool_description(:mcp_no_tools)` is
deliberately a two-sentence capability statement (per Convention #4
in `PtcToolProtocol`); it carries no PTC-Lisp authoring guidance.

To close that gap, `:ptc_runner_mcp` ships its own compact authoring
card and concatenates it onto the protocol-owned description when
advertising the tool.

**File path (verbatim):** `mcp_server/priv/mcp_authoring_card.md`.

**Loading:** read at compile time via `@external_resource` and
`File.read!/1`, exposed as a string constant on
`PtcRunnerMcp.Tools.authoring_card/0 :: String.t()`. Edits to the
file trigger recompile (BEAM `@external_resource` semantics).

**Concatenation rule:** the advertised `description` in the
`tools/list` response is

```elixir
PtcToolProtocol.tool_description(:mcp_no_tools) <> "\n\n" <> PtcRunnerMcp.Tools.authoring_card()
```

The protocol-owned capability statement comes first; the
package-owned authoring card follows.

**Versioning:** the card is versioned with the `:ptc_runner_mcp`
package. Material wording changes are a minor-version bump on the
MCP package — not a `:ptc_runner` release concern.

**Card content (verbatim).** The file `mcp_server/priv/mcp_authoring_card.md`
ships with this content exactly:

````markdown
# PTC-Lisp authoring

PTC-Lisp is a deterministic, sandboxed subset of Clojure with a small Java-interop surface (Date/Time + String methods). A program is one or more top-level expressions; the last expression's value is the result.

## Non-obvious bits

- **`context` keys are bound under the `data/` namespace.** Pass `{"records": [...]}`, reference as `data/records` inside the program. There is no `context` binding.
- **`signature`** is a return-type schema, e.g. `() -> {count :int}` or `() -> [{name :string, score :int}]`. Supplying it makes the response carry a structured `validated` JSON value — the only path for a caller to receive programmatic data. Without it, the response only contains an LLM-readable preview.
- **`(fail v)`** terminates with an error value when you want to surface a domain failure to the caller.

## Restrictions

- No mutable state: `atom`, `swap!`, `reset!`, `@deref` are absent — use `reduce` / `map` / `filter`.
- No I/O except `println`. No filesystem, no network. No general Java interop.
- No state across calls — each invocation is independent.
- 1 s wall-clock, 10 MB memory, 64 KB program, 4 MB context.

If you reach for something that isn't there, the response will say so clearly — adjust and retry.

## Example

```
;; context:   {"orders": [{"total": 12}, {"total": 7}, {"total": 33}]}
;; signature: "() -> {count :int, sum :int}"
(let [big (filter #(> (get % "total") 10) data/orders)]
  {:count (count big)
   :sum   (reduce + (map #(get % "total") big))})
```

Full reference: https://hexdocs.pm/ptc_runner.
````

**Design rationale (from the LLM's perspective).** The card is
deliberately *not* a function reference. The five audit docs in
`docs/` (clojure-core-audit, clojure-string-audit, clojure-set-audit,
java-interop, java-math-audit) total ~770 lines; any compact
summary of "available forms" would drift and under-represent
simultaneously. Instead the card:

1. Anchors the LLM to "subset of Clojure" so it uses its Clojure
   priors (`map`/`filter`/`reduce`, `clojure.string/*`, `(.contains
   s "x")`, etc.) without being told.
2. Tells it only the things it can't guess from priors — the
   `data/` namespace, `signature` syntax, `(fail v)`.
3. Tells it the hard NOs that contradict Clojure priors: no
   `atom`/`swap!`, no I/O, no general Java interop. These are the
   things an LLM *will* reach for and *will* be wrong about.
4. Explicitly tells it to rely on retry: *"If you reach for
   something that isn't there, the response will say so clearly —
   adjust and retry."*

**Per-turn cost tradeoff.** Tool `description` strings are sent to
the model on every turn that includes the tool, not just session
start. The card adds ~1.1 KB / ~400 tokens to that overhead per
turn. For a single-tool server this is bounded and acceptable.
A `prompts`-based version (deferred — § 18) would let clients
fetch the card on-demand instead.

**Feedback quality is now load-bearing.** Because the card
explicitly directs the LLM to rely on retry, the quality of the
`feedback` strings in error responses (§ 10.3) is part of the MCP
authoring contract — not just a convenience. Common authoring
mistakes (`(slurp …)`, `(swap! …)`, `(get context "k")`,
`(http-get …)`) MUST produce `feedback` strings actionable enough
for an LLM to self-correct. Phase 2 and Phase 3 DoDs include a
smoke test asserting this.

**Test discipline.** The advertised `description` from `tools/list`
MUST contain the following substring anchors (assert byte-for-byte
in tests; same discipline as `tool_description/1`):

- `"subset of Clojure"`
- `"data/"`
- `"signature"`
- `"(fail"`
- `"adjust and retry"`

The pre-card portion (the `tool_description(:mcp_no_tools)` string)
retains its existing substring assertions from `:ptc_runner` tests.

## 9. Request contract

### 9.1 Argument shape

A `tools/call` request lives inside the standard JSON-RPC envelope.
The MCP-defined wrapper is `params: { name, arguments }`; the
`arguments` object is what this section specifies.

**Full request frame:**

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "ptc_lisp_execute",
    "arguments": {
      "program":  "<string, required, non-empty after trim, ≤ max_program_bytes>",
      "context":  { "<key>": "<JSON value>" },
      "signature": "() -> {count :int}"
    }
  }
}
```

`params.name` is the tool name (always `"ptc_lisp_execute"` in v1;
any other value yields the `unknown_tool` tool result per § 10.5).
`params.arguments` is the object whose keys are described below.

**Argument keys:**

```json
{
  "program":  "<string, required, non-empty after trim, ≤ max_program_bytes>",
  "context":  { "<key>": "<JSON value>" },
  "signature": "() -> {count :int}"
}
```

`context` and `signature` are optional. The successful response
follows the envelope in § 10.1.

### 9.2 `program` validation

| Condition | Reason |
|---|---|
| Missing | `args_error` |
| Not a string | `args_error` |
| Empty after trim | `args_error` |
| > `max_program_bytes` (default 64 KB) | `args_error` |

### 9.3 `context` validation and coercion

| Condition | Reason |
|---|---|
| Present and not a JSON object | `args_error` |
| Encoded JSON byte size > `max_context_bytes` (default 4 MB) | `args_error` |
| Key is not a JSON string | `args_error` |
| Key contains a `/` character | `args_error` (would shadow PTC-Lisp namespace) |
| Key is empty string | `args_error` |
| Absent | Treated as `{}` |

Coercion of accepted JSON values into PTC-Lisp values bound under
`data/`:

| JSON shape | PTC-Lisp value |
|---|---|
| `string` | binary, no parsing (no auto ISO-8601 coercion) |
| `integer` | integer |
| `non-integer number` | float |
| `true` / `false` | boolean |
| `null` | `nil` |
| `array` | PTC-Lisp list |
| `object` | string-keyed map |

**No atom creation.** All map keys remain binaries. Programs that need
keyword keys must construct them explicitly with `(keyword ...)`.

A program referencing `data/foo` when `foo` is absent emits
`reason: "runtime_error"` with a message naming the missing binding.

### 9.4 `signature` validation

| Condition | Reason |
|---|---|
| Present and not a string | `args_error` |
| Present and parse fails via `PtcToolProtocol.parse_signature/1` (§ 13.1) | `args_error` |
| Present and parses successfully | Used for return validation only |

The signature's **input** parameter list is documentation-only in v1
and is **not** used to validate the `context` argument. Input
validation is deferred. Document this explicitly in user-facing docs
to prevent surprise.

## 10. Response contract

### 10.1 MCP envelope

Tool results are returned in the standard MCP `tools/call` envelope
with both `structuredContent` (machine path) and a mirrored `content`
text block (LLM path):

**Success:**

```json
{
  "isError": false,
  "structuredContent": <R22 success object, see § 10.2>,
  "content": [
    { "type": "text", "text": "<R22 success object as JSON string>" }
  ]
}
```

**Error (any reason emitted by `render_error/3`, plus `busy`):**

```json
{
  "isError": true,
  "structuredContent": <R23 error object, see § 10.3>,
  "content": [
    { "type": "text", "text": "<R23 error object as JSON string>" }
  ]
}
```

The `text` block carries the same JSON the LLM would consume; the
`structuredContent` block carries the same payload as a parsed object
for clients that read it. Clients that switch on `content[0].type`
will only ever see `"text"` — no other content types are emitted in
v1.

### 10.2 Success payload (R22)

```json
{
  "status": "ok",
  "result":   "<final-expression preview, EDN/Clojure-rendered>",
  "prints":   ["<println output>", "..."],
  "feedback": "<LLM-readable rendering, same as in-process surfaces>",
  "memory": {
    "changed":     {"<key>": "<EDN-rendered preview>"},
    "stored_keys": ["<key>", "..."],
    "truncated":   false
  },
  "truncated": false,
  "validated": <signature-coerced JSON value; only present when signature was supplied and validation passed>
}
```

`memory.changed`, `memory.stored_keys`, and `memory.truncated`
describe **in-program** state mutations and are not persisted across
`tools/call` requests. They exist so the LLM can see what its program
set, which often informs the next program.

`feedback` is the same LLM-readable rendering produced by in-process
surfaces. MCP clients with their own retry loop MAY ignore it; clients
forwarding tool results to an LLM SHOULD include it.

### 10.3 Error payload (R23)

```json
{
  "status":   "error",
  "reason":   "parse_error | runtime_error | timeout | memory_limit | args_error | fail | validation_error | busy | unknown_tool",
  "message":  "<short error string, safe for display>",
  "feedback": "<LLM-readable execution-error feedback>",
  "result":   "<failed-value preview; only present when reason: \"fail\">"
}
```

Reasons emitted by MCP v1:

| Reason | Source |
|---|---|
| `parse_error` | PTC-Lisp parse failed |
| `runtime_error` | program raised at runtime |
| `timeout` | sandbox wall-clock execution timeout exceeded |
| `memory_limit` | sandbox memory cap exceeded |
| `args_error` | argument shape, type, or size invalid; signature parse failed |
| `fail` | program called `(fail v)`; carries `result` |
| `validation_error` | signature supplied; return value did not match |
| `busy` | `max_concurrent_calls` exceeded; client should retry |
| `unknown_tool` | `tools/call` for any name other than `ptc_lisp_execute` |

`busy` and `unknown_tool` are **MCP-only reasons**. They are not in
the shared `error_reason()` enum (which other surfaces also consume),
and `PtcRunner.PtcToolProtocol.render_error/3` is NOT widened to
accept them — its `@spec` and `@type error_reason()` remain
byte-for-byte unchanged.

Instead, `:ptc_runner_mcp` owns its own renderer:

```elixir
PtcRunnerMcp.Envelope.render_error(reason, message, opts)
  when reason in [:busy, :unknown_tool]
```

For the seven shared reasons, `PtcRunnerMcp.Envelope.render_error/3`
delegates to `PtcToolProtocol.render_error/3` unchanged. For `:busy`
and `:unknown_tool` it constructs the R23 payload locally using the
same shape (`status`, `reason`, `message`, `feedback`; no `result`
field — neither carries a failed value). The `feedback` string for
these two reasons is owned by the MCP package and is not shared with
other surfaces.

Only `PtcRunnerMcp.Envelope.render_error/3` is permitted to emit
`:busy` or `:unknown_tool`. Any code path inside `:ptc_runner` that
attempts to emit them is a bug — those reasons cannot reach the
shared module.

### 10.4 `outputSchema`

A `oneOf` discriminated by `status`:

```json
{
  "type": "object",
  "oneOf": [
    {
      "type": "object",
      "required": ["status", "prints", "feedback", "memory", "truncated"],
      "properties": {
        "status":    { "const": "ok" },
        "result":    { "type": "string" },
        "prints":    { "type": "array", "items": { "type": "string" } },
        "feedback":  { "type": "string" },
        "memory": {
          "type": "object",
          "required": ["changed", "stored_keys", "truncated"],
          "properties": {
            "changed":     { "type": "object", "additionalProperties": { "type": "string" } },
            "stored_keys": { "type": "array", "items": { "type": "string" } },
            "truncated":   { "type": "boolean" }
          }
        },
        "truncated": { "type": "boolean" },
        "validated": {}
      }
    },
    {
      "type": "object",
      "required": ["status", "reason", "message", "feedback"],
      "properties": {
        "status":   { "const": "error" },
        "reason": {
          "type": "string",
          "enum": ["parse_error", "runtime_error", "timeout", "memory_limit",
                   "args_error", "fail", "validation_error", "busy", "unknown_tool"]
        },
        "message":  { "type": "string" },
        "feedback": { "type": "string" },
        "result":   { "type": "string" }
      }
    }
  ]
}
```

`"result"` is intentionally **not** in the success branch's `required`
list. `PtcToolProtocol.render_success/2` elides the field when both
the program's final expression and `lisp_step.return` are `nil` (e.g.
a program that only calls `(println …)` and returns nothing). MCP
clients with strict `outputSchema` validation (including the official
Inspector) MUST accept success payloads without `"result"`. All other
keys in the `required` list are always emitted.

### 10.5 `isError` discipline

- `isError: false` ↔ R22 success.
- `isError: true` ↔ R23 error, **including `reason: "fail"`**. A
  program calling `(fail v)` is communicating a domain failure that
  the caller's LLM should treat as a problem signal; mapping it to
  `isError: true` routes it correctly.
- `isError: true` ↔ `busy`, `unknown_tool`.

The server emits **no JSON-RPC-level error responses for tool-call
failures**. Tool-originated errors (including unknown tool name and
busy state) come back as MCP tool results with `isError: true`.
JSON-RPC error responses are reserved for transport/protocol
violations only (§ 12).

## 11. Resource limits

PtcRunner's existing sandbox provides per-program isolation. The MCP
server adds across-request limits.

| Limit | Default | Configurable | On exceed |
|---|---|---|---|
| `max_frame_bytes` | 8 MB | `--max-frame-bytes`, `PTC_RUNNER_MCP_MAX_FRAME_BYTES` | JSON-RPC `-32700` |
| `max_program_bytes` | 64 KB | `--max-program-bytes`, env | tool result `args_error` |
| `max_context_bytes` | 4 MB | `--max-context-bytes`, env | tool result `args_error` |
| `max_concurrent_calls` | `min(8, :erlang.system_info(:logical_processors))` | `--max-concurrent-calls`, env | tool result `busy` |
| `program_timeout` | 1 s wall-clock (sandbox `receive…after`) | not configurable in v1 | tool result `timeout` |
| `program_memory_limit` | 10 MB (sandbox) | not configurable in v1 | tool result `memory_limit` |

`max_concurrent_calls` is enforced as a counting semaphore around
`Lisp.run/2`. When the cap is hit, additional `tools/call` requests
return immediately with `reason: "busy"` (no queueing). The cap exists
primarily as a memory ceiling — at default values, eight concurrent
sandboxes can hold up to ~80 MB.

**Required invariants:**

- One BEAM process per `tools/call` request. No process reuse across
  requests.
- No shared state across requests. Each `Lisp.run/2` call uses
  fresh opts: empty `memory: %{}`, empty `tool_cache: %{}`, no
  `journal` (or a fresh per-request journal), and no reuse of any
  prior call's turn history. The MCP package never holds a
  cross-request reference to memory, tool cache, or journal.
- The existing sandbox guarantees (no filesystem, no network) MUST
  hold when invoked from the MCP server context (asserted by test).

## 12. Protocol-level errors

Reserved for transport violations only:

| Condition | JSON-RPC code |
|---|---|
| Frame > `max_frame_bytes` | `-32700 Parse error` |
| Malformed JSON | `-32700 Parse error` |
| Missing `jsonrpc: "2.0"`, missing `method`, etc. | `-32600 Invalid Request` |
| Unknown JSON-RPC method (e.g., `foo/bar`) | `-32601 Method not found` |
| Invalid params shape on a known method | `-32602 Invalid params` |
| Server-internal crash (sandbox failed to start, BEAM-level error) | `-32603 Internal error` |

`tools/call` for an unknown tool name does NOT use `-32601`; it
returns an `unknown_tool` tool result with `isError: true` (§ 10.5).
The protocol-level codes are for malformed or unrecognized
**transport** events, not for tool-level outcomes.

## 13. JSON normalization for `validated`

The `validated` field in the success payload requires a typed
Elixir → JSON-encodable conversion. `JsonHandler.atomize_value/2`
goes the **opposite** direction (JSON-decoded → typed Elixir, used
during return-value validation), so it cannot be reused for this
path.

This package adds a new helper:

```elixir
PtcRunner.PtcToolProtocol.to_json_value/1
```

Conversion rules:

| Elixir term | JSON form |
|---|---|
| Integer | number |
| Float | number |
| Binary (string) | string |
| Boolean | boolean |
| `nil` | null |
| Map with binary or atom keys | object with string keys (atom keys converted via `Atom.to_string/1`) |
| List | array |
| Atom (non-key) | string (`:foo` → `"foo"`, no leading colon) |
| Tuple | array |
| `%DateTime{}` | ISO-8601 string |
| `%Date{}`, `%Time{}` | ISO-8601 string |
| Anything else | error → `validation_error` with a "non-JSON-encodable value at <path>" message |

The helper lives in `PtcRunner.PtcToolProtocol` so the in-process
surfaces can adopt it later if they ever expose `validated` directly.
For v1 only the MCP server consumes it.

## 13.1 Additional shared-surface widenings

`render_success/2` requires an `:execution` map shaped like the
output of `TurnFeedback.execution_feedback/3`. The MCP server cannot
build that map without reaching into `TurnFeedback` internals, which
the § 4 non-goal forbids. To keep the non-goal honest,
`PtcRunner.PtcToolProtocol` gains two additional public helpers:

```elixir
PtcRunner.PtcToolProtocol.render_success_from_step(lisp_step, opts)
  :: String.t()
PtcRunner.PtcToolProtocol.parse_signature(signature_string)
  :: {:ok, parsed} | {:error, reason}
```

- **`render_success_from_step/2`** is the high-level entry point the
  MCP server uses. It accepts a `Lisp.run/2` result map and the same
  `:validated` opt as `render_success/2`. Internally it builds the
  `:execution` map via `TurnFeedback.execution_feedback/3` and
  delegates to `render_success/2`. Callers never construct the
  `:execution` map themselves. `render_success/2` remains public for
  callers (in-process v1) that already build the execution map.

- **`parse_signature/1`** is a thin wrapper over
  `PtcRunner.SubAgent.Signature.parse/1`. The MCP server uses it to
  validate the `signature` argument; `:ptc_runner_mcp` does NOT
  call `PtcRunner.SubAgent.Signature.parse/1` directly. The wrapper
  exists so the signature-parser implementation can move out of the
  `SubAgent` namespace later without breaking the MCP package.

With these two additions, the consumed surface for `:ptc_runner_mcp`
is exactly: `tool_description/1`, `lisp_run/2`,
`render_success_from_step/2`, `render_success/2` (rare),
`render_error/3`, `parse_signature/1`, `validate_return/2`,
`atomize_value/2`, `to_json_value/1`. The § 4 non-goal stands
unchanged.

## 14. Wire format for `result` and `prints`

`result` and entries in `prints` remain **EDN/Clojure-rendered preview
strings** as produced by `PtcRunner.Lisp.Format.to_clojure/2`. They
are LLM-facing previews, not programmatic data.

The boundary is sharp:

- **LLM-facing path**: `result`, `prints`, `feedback`,
  `memory.changed` values. EDN/Clojure preview strings.
- **Programmatic path**: `validated`. Only emitted when a signature is
  supplied; structured JSON via `to_json_value/1`.

Clients that want programmatic data MUST supply a signature.

## 15. Phases

Phase 0 (shared protocol module) is **shipped**. The phases below are
new work in the `ptc_runner_mcp` package.

### Phase 0.5 — `:ptc_runner` instrumentation (prerequisite)

Small additive change inside `:ptc_runner` itself. Sequenced before
the MCP package's tracing work (§ 6.6–6.10) but useful independently
to all callers (in-process v1, text-mode, MCP).

- Add `[:ptc_runner, :lisp, :execute, :start | :stop | :exception]`
  telemetry around `Lisp.run/2` per the taxonomy in § 6.7.
- Add the `:caller` keyword option to `Lisp.run/2` per § 6.7 with
  default `:in_process_v1` and a closed atom set
  `#{:in_process_v1, :text_mode, :mcp}`. Out-of-set values raise
  `ArgumentError` at entry. The option is read once and forwarded
  only into telemetry metadata.
- Add `PtcRunner.TraceLog.write_to_active/1` per § 6.8.
- No behavior change for existing callers; pure instrumentation.
  `Lisp.run/2`'s default of `:in_process_v1` means all current call
  sites remain correct without edits.

**DoD:** `Lisp.run/2` calls emit the three events with the metadata
defined in § 6.7, including `caller`. The default value is
`:in_process_v1` (asserted by test). `Lisp.run("…", caller: :mcp)`
attaches `caller: :mcp` to all three events (asserted by test).
`Lisp.run("…", caller: :bogus)` raises `ArgumentError` at entry
(asserted by test). `write_to_active/1` returns `:no_collector`
outside a `with_trace` scope (test) and writes a parseable JSONL
line inside one (test). No regressions in existing `:ptc_runner`
tests; no existing call site is modified in this phase.

### Phase 1 — Project scaffold + JSON-RPC skeleton

- Create `mcp_server/` as a second top-level Mix project per § 5.2
  (`mix.exs`, `lib/`, `test/`, OTP application module).
- Wire `ptc_runner` as a path dep; verify both projects compile from
  a clean clone.
- Extend `.git/hooks/pre-commit` and `.git/hooks/pre-push` per § 5.3
  to run gates in both projects.
- Stdio NDJSON line reader with `max_frame_bytes` enforcement.
- Implements `initialize`, `notifications/initialized`, `shutdown`,
  `exit`, `notifications/cancelled`, `tools/list`, `tools/call`.
- `tools/call` is a stub returning a fixed `runtime_error` result;
  proves the envelope and `isError` plumbing.
- stderr JSON-Lines logger.
- Ship `mcp_server/priv/mcp_authoring_card.md` per § 8.4 (verbatim
  card text from § 8.4). Wire `PtcRunnerMcp.Tools.authoring_card/0`
  via `@external_resource` + `File.read!/1`. The `tools/list`
  response advertises `description = tool_description(:mcp_no_tools)
  <> "\n\n" <> authoring_card()`.

**DoD:** MCP Inspector connects, completes the handshake, lists one
tool, and receives a structured `isError: true` stub from
`tools/call`. stdin EOF causes clean exit. Pre-commit and pre-push
hooks run gates in both projects on a sentinel change. The
advertised tool `description` contains all five substring anchors
from § 8.4 (`"subset of Clojure"`, `"data/"`, `"signature"`,
`"(fail"`, `"adjust and retry"`) **and** the `:mcp_no_tools`
anchors already asserted by `:ptc_runner` tests.

**Compatibility deviation gates (per § 7.4):**

- D1 (unknown tool → tool result): a `tools/call` with
  `name: "nope"` against the stub server returns a tool result with
  `isError: true` and `reason: "unknown_tool"`. MCP Inspector
  displays it without surfacing a protocol error.
- If Inspector flags the unknown-tool tool result as a protocol
  violation, the deviation is rejected: flip the implementation to
  `-32602` and update § 7.4 + § 10.5 accordingly before Phase 2
  spawns.

### Phase 2 — Wire `ptc_lisp_execute`, no `context`/`signature`

- `tools/call` accepts `program`, validates per § 9.2, runs via
  `PtcToolProtocol.lisp_run/2` with fresh opts: empty `memory`,
  empty `tool_cache`, no journal reuse (per § 11). The MCP package
  never reaches into `Loop.State` or any other loop-internal struct.
- Renders R22 via `PtcToolProtocol.render_success_from_step/2`
  (§ 13.1) and R23 via `PtcToolProtocol.render_error/3`. The MCP
  package never builds an `:execution` map directly.
- Wraps the JSON in the MCP envelope per § 10.1.
- Enforces `max_program_bytes` and `max_concurrent_calls`.
- Implements `unknown_tool` for non-`ptc_lisp_execute` calls.

**DoD:** `(+ 1 2)` returns `result: "user=> 3"` with `isError:
false`. Parse errors return `parse_error` with `isError: true`.
Oversized programs return `args_error`. Concurrent over-cap requests
return `busy` (not `-32603`). Sandbox timeouts and memory limits map
to `timeout` / `memory_limit`. `(fail {:reason :nope})` returns
`reason: "fail"` with `isError: true` and a `result` field.

**Feedback-quality smoke test (per § 8.4).** The card directs the
LLM to rely on retry, so error `feedback` strings must be actionable.
For each of these common authoring mistakes, assert the response
`feedback` field contains a substring naming the actual misuse (not
just a generic "error"):

- `(slurp "x.txt")` — feedback names `slurp` or "function not found".
- `(swap! a inc)` — feedback names `swap!` / `atom` / "mutable state".
- `(http-get "https://…")` — feedback names `http-get` or "function not found".

These assertions stay in Phase 2 even though `context` is unwired —
the missing-binding case `(get context "k")` deferred to Phase 3.

### Phase 3 — `context` and `signature`

- Accept `context`; validate per § 9.3; bind values under `data/` per
  the coercion table.
- Accept `signature`; parse via `PtcToolProtocol.parse_signature/1`
  (§ 13.1); on parse failure emit `args_error`.
- On signature success, validate the return value via
  `PtcToolProtocol.validate_return/2`. On mismatch emit
  `validation_error`. On match include `validated:` in the success
  payload, computed via `PtcToolProtocol.to_json_value/1`.
- Build success payloads via `PtcToolProtocol.render_success_from_step/2`
  (§ 13.1). Do NOT construct an `:execution` map by hand; do NOT
  call `TurnFeedback.execution_feedback/3` directly.
- Add `outputSchema` (§ 10.4) to the `tools/list` advertisement.

**DoD:** Cross-language smoke test: a program with `context` +
`signature` returns a structured `validated` value. Signature mismatch
returns `validation_error`. Oversized `context` returns `args_error`.
Missing `data/foo` reference inside a program returns `runtime_error`.

**Feedback-quality smoke test (per § 8.4), context edition.** Assert
that `(get context "k")` (the LLM-instinctive but wrong way to read
context) produces a `feedback` string naming `context` or pointing at
`data/`. This closes the most common first-program mistake the card
warns against.

### Phase 3.5 — Per-call tracing (opt-in)

Implements § 6.6–6.10. Depends on Phase 0.5 instrumentation.

- Add `--trace-dir` and `--trace-payloads` flags + env vars; wire
  through to the request handler.
- Wrap each `tools/call` in `TraceLog.with_trace/2` when tracing is
  enabled.
- Implement `PtcRunnerMcp.TraceHandler` that subscribes to
  `[:ptc_runner_mcp, :call, ...]` and `[:ptc_runner, :lisp, :execute, ...]`
  and writes through `PtcRunner.TraceLog.write_to_active/1`.
- Apply payload policy per § 6.9 (default `summary`).
- Implement file naming and rotation per § 6.10.
- Disk-pressure handling: trace failure does NOT fail the tool call.

**DoD:** With `--trace-dir traces/`, a `tools/call` produces one
JSONL file matching § 6.10's naming convention. The file contains a
`trace.start` header, an MCP `call.start`, a Lisp `execute.start`,
matching `stop` events, and a `trace.stop` (in chronological order
modulo concurrency). `--trace-payloads summary` redacts program/
context per § 6.9; `full` keeps everything; `none` keeps only counts.
`--trace-max-files 3` evicts oldest files in FIFO order. `ptc_viewer
--trace-dir traces/` lists the file with `trace_kind: "mcp_call"`.

### Phase 4 — Cancellation and lifecycle hardening

- Wire `notifications/cancelled` to kill in-flight sandbox processes.
- Ensure stdin EOF cancels in-flight calls and exits 0.
- Drain semantics for `shutdown` + `exit`.
- Sandbox isolation regression test (no shared state between
  back-to-back `tools/call` requests).

**DoD:** A long-running program is killed on
`notifications/cancelled` and emits no response. stdin EOF cancels
all in-flight programs cleanly. Two sequential calls cannot see each
other's `(memory/put ...)` state.

### Phase 5 — Packaging and distribution

- Mix release configuration.
- Burrito-bundled binaries for macOS (signed/notarized note in README),
  Linux, and Windows.
- README documenting `claude_desktop_config.json` and
  `cline_mcp_settings.json` snippets.
- Optional `mix ptc_runner_mcp.run` task for in-tree iteration.

**DoD:** A non-Elixir user installs from a Homebrew tap or GitHub
release artifact and wires the server into Claude Desktop using only
the README.

### Phase 6 — Integration tests, docs, benchmarks

- Live tests against MCP Inspector and at least one production MCP
  client.
- Documentation: deterministic-compute use case, comparison with
  Python/JS execution servers, security model.
- Benchmark: native-only LLM math vs PtcRunner-MCP-assisted math
  using the existing `count r in raspberry` baseline (extended
  cross-process) plus one larger workload.

## 16. Tests required

### Handshake and capabilities

- `initialize` with client `protocolVersion: "2025-11-25"` → reply
  `protocolVersion: "2025-11-25"`.
- `initialize` with client `protocolVersion: "2025-06-18"` → reply
  `protocolVersion: "2025-06-18"`.
- `initialize` with an unrecognized `protocolVersion` → reply
  `protocolVersion: "2025-11-25"` (latest supported).
- `initialize` reply contains `capabilities.tools.listChanged: false`
  and **no** `resources`, `prompts`, `experimental.tasks`,
  `elicitation`, or `sampling` keys, regardless of negotiated version.
- `serverInfo.version` matches the package version.
- The server emits no revision-specific fields invalid for the
  negotiated version (e.g., no icons metadata when negotiated
  `2025-06-18`).

### Tool advertisement

- `tools/list` advertises exactly one tool, name `ptc_lisp_execute`.
- The advertised description has
  `PtcToolProtocol.tool_description(:mcp_no_tools)` as a
  byte-for-byte **prefix**, followed by exactly `"\n\n"`, followed by
  `PtcRunnerMcp.Tools.authoring_card()` as a byte-for-byte
  **suffix** (per § 8.4's concatenation rule).
- The protocol-prefix portion contains the substring "No app tools
  are available inside the program."
- The protocol-prefix portion does NOT contain "Call app tools as
  `(tool/name ...)`" (negative; proves correct profile).
- The full advertised description contains all five § 8.4 anchors:
  `"subset of Clojure"`, `"data/"`, `"signature"`, `"(fail"`,
  `"adjust and retry"`.
- `annotations.readOnlyHint`, `idempotentHint` are `true`;
  `destructiveHint`, `openWorldHint` are `false`.
- `outputSchema` validates against an example R22 and R23 payload.

### Envelope

- Successful `tools/call` returns `isError: false`,
  non-empty `structuredContent`, a single `text` content block whose
  `text` parses to the same object as `structuredContent`.
- Every R23 reason returns `isError: true` with the same envelope
  shape, **including `reason: "fail"`**.
- No content block has `type` other than `"text"`.

### Argument validation

- `program` missing → `args_error`.
- `program` non-string → `args_error`.
- `program` whitespace-only → `args_error`.
- `program` exceeding `max_program_bytes` → `args_error`.
- `context` not an object → `args_error`.
- `context` exceeding `max_context_bytes` → `args_error`.
- `context` key containing `/` → `args_error`.
- `context` key empty string → `args_error`.
- `signature` not a string → `args_error`.
- `signature` malformed → `args_error`.

### Execution outcomes

- `(+ 1 2)` returns `result: "user=> 3"`.
- Parse error → `parse_error`.
- `(/ 1 0)` → `runtime_error`.
- 2-second busy loop (PTC-Lisp `loop`/`recur` form, since the sandbox
  bans I/O sleeps) → `timeout`.
- Allocation > 10 MB → `memory_limit`.
- `(fail {:reason :nope})` → `reason: "fail"` with `result` field
  and `isError: true`.

### Context binding

- `context: {"records": [...]}` makes `data/records` accessible inside
  the program.
- Reference to `data/missing` with no such key → `runtime_error`
  whose message names the missing binding.
- JSON integer round-trips as integer (not float).
- JSON map keys remain strings inside the program (no atom creation).

### Signature and validation

- Signature `() -> {total :int}` matched by program return →
  success payload includes `validated` field with structured JSON.
- Signature mismatch → `validation_error`.
- Atom return value → `validated` contains the string form (no
  leading colon).
- Tuple return value → `validated` contains a JSON array.
- `%DateTime{}` return value → `validated` contains an ISO-8601
  string.

### Concurrency and isolation

- Concurrent over-cap requests return `busy` (tool result, not
  `-32603`).
- Concurrent under-cap requests do not interleave memory state.
- Two sequential `tools/call` requests do not share `memory`,
  `tool_cache`, or `journal`.

### Lifecycle

- `notifications/cancelled` for an in-flight ID kills the sandbox
  and emits no response for that ID.
- `notifications/cancelled` for an unknown ID is silently ignored.
- stdin EOF cancels in-flight requests and exits 0.

### Protocol errors

- Frame > `max_frame_bytes` → JSON-RPC `-32700 Parse error`.
- `tools/call` for unknown tool name → tool result with
  `isError: true`, `reason: "unknown_tool"` (NOT `-32601`).
- Unknown JSON-RPC method (e.g. `foo/bar`) → `-32601 Method not
  found`.
- Malformed JSON line → `-32700 Parse error`.

### Logging

- stderr emits one valid JSON object per line.
- `info`-level logs do NOT include full `program` source or full
  `context` payloads.
- `debug`-level logs MAY include them.

### Tracing

- Without `--trace-dir`, no files are written and no tracing
  telemetry handlers attach.
- With `--trace-dir <dir>`, a successful `tools/call` produces one
  JSONL file matching `<iso8601>-<reqhash8>-ok.jsonl`; a failed call
  produces `…-error.jsonl`.
- The header line is a `trace.start` event with
  `trace_kind: "mcp_call"`, `producer: "ptc_runner_mcp"`,
  `model: null`, and a non-empty `trace_label`.
- The body contains, in chronological order: an MCP
  `[:ptc_runner_mcp, :call, :start]` event, a Lisp
  `[:ptc_runner, :lisp, :execute, :start]` event, matching `:stop`
  events with `duration` measurements, and a `trace.stop` footer.
- No `[:ptc_runner, :sub_agent, ...]` events appear (negative
  assertion: MCP traces never lie about being SubAgent runs).
- `--trace-payloads summary` (default): the `program` field on
  `call.start` is `{"sha256":..., "preview":..., "bytes":...}`, NOT
  the full source.
- `--trace-payloads full`: the `program` field is the full source.
- `--trace-payloads none`: the `program` field is
  `{"sha256":..., "bytes":...}` only.
- `--trace-max-files 3` with four sequential calls: only three files
  remain, evicted by oldest mtime first.
- A trace-write failure (e.g., directory non-writable) logs an
  error to stderr and does NOT change the `tools/call` response.
- `PtcRunner.TraceLog.write_to_active/1` returns `:no_collector`
  when called outside a `with_trace` scope.

## 17. Open questions

**None.** All v1 questions are locked above:

- MCP envelope: `structuredContent` + mirrored `text` block.
- Atom serialization in `validated`: stringify without colon.
- Tuple serialization in `validated`: JSON array.
- Versioning: independent `ptc_runner_mcp` semver; primary MCP
  revision `2025-11-25`, compatibility floor `2025-06-18`, both
  negotiated via `initialize`.
- Unknown tool name handling: tool result with `isError: true`,
  not JSON-RPC `-32601`.
- `(fail v)` `isError`: `true`.
- Busy handling: tool result with `reason: "busy"`, not JSON-RPC
  `-32603`.
- Context input validation against signature inputs: deferred to v2.

## 18. Deferred from v1

| Capability | Why deferred |
|---|---|
| **Feature B — `SubAgent.run/2` over MCP** | Cross-cutting LLM-cred and cost concerns. Land Feature A and let usage shape the design. |
| **MCP Aggregator (upstream MCP tools inside programs)** | Specified separately in `ptc-runner-mcp-aggregator.md`. Independent of this plan. |
| **Stateful sessions** | Per-session `memory` / `tool_cache` across calls. Currently solved by client-threaded `context`. |
| **Streaming `println`** | Programs are short (1s cap). MCP notification-based streaming adds complexity for marginal gain. |
| **`signature` input validation** | The signature's input slot is documentation-only in v1. Add validation when usage demands. |
| **Configurable `program_timeout` / `program_memory_limit`** | Hard-coded from the sandbox in v1. Decide per-server vs per-request when adding. |
| **MCP `resources` / `prompts` surfaces** | Not advertised in v1. Adding them is opt-in expansion (PTC-Lisp doc browsing, scaffolds). |
| **Richer authoring surfaces (`prompts` carrying full reference, `resources` for `docs/function-reference.md`)** | v1 inlines a compact card into the tool description (§ 8.4). Move to a `prompts`-resource model when the per-turn description cost matters or the card outgrows ~2 KB. Defer with the rest of `prompts`/`resources`. |
| **Streamable HTTP transport** | stdio only in v1. HTTP transport pulls in OAuth/OIDC, session management, and Streamable HTTP framing — significant new surface for marginal benefit over stdio for a local compute primitive. |
| **Experimental `tasks` (2025-11-25)** | Long-running task surface. PTC-Lisp programs are 1-second-bounded; tasks add no value. |
| **`elicitation` (URL-mode in 2025-11-25)** | Server cannot elicit from the user. Programs run end-to-end with the args provided. |
| **`sampling` tool-calling** | The server is the callee, not the caller. Sampling makes sense for agentic servers; this one is a primitive. |
| **Icons metadata, OAuth scope consent, OIDC discovery (2025-11-25)** | HTTP-transport-relevant or branding features; not applicable to a stdio compute server. |
| **Audit logging of submitted programs** | Out of scope; operators that need it can wrap stderr. |
| **Native MCP-shaped trace view in `ptc_viewer`** | v1 MCP traces render in `ptc_viewer` with empty LLM/turn panes (since they aren't SubAgent runs). A flat MCP-execution view in `ptc_viewer` is justified once UX pain is real; v1 keeps trace files honest and structured so the viewer can grow into it. |
| **Trace subscription / live tail** | `ptc_viewer` reads files. Live `resources/subscribe` over MCP would couple this surface to the resources capability; defer with the rest of resources. |

## 19. Security model summary

- **Trust boundary.** stdio MCP servers run under the user's auth
  context. Anyone with stdio access can submit arbitrary PTC-Lisp.
  The sandbox is the protection against that program; the operator
  is responsible for not exposing the server to untrusted callers.
- **Resource exhaustion.** Bounded by `max_frame_bytes`,
  `max_program_bytes`, `max_context_bytes`, `max_concurrent_calls`,
  `program_timeout`, `program_memory_limit`. All enforced in v1.
- **Data exfiltration.** PTC-Lisp programs cannot read the
  filesystem or open network connections. The only data that crosses
  back is the program's return value (and `println` output, captured
  in `prints`). The MCP Aggregator plan widens this surface — it
  must re-state its own security model.
- **Operator log hygiene.** Full program source and full `context`
  are `debug`-level only by default to avoid leaking client data
  into operator logs.

## 20. Implementation orchestration

This section pins how the work is split across subagents, what runs
in parallel, when reviews happen, and how requirements trace to
phases. Inherits the text-mode plan's Addendum 20 (workflow) and
Addendum 21 (Codex policy) verbatim where applicable.

### 20.1 Phase → subagent map

| Phase | Subagent | Worktree | Parallel with | Touches |
|---|---|---|---|---|
| 0.5 — `:ptc_runner` instrumentation | Engineer | yes | — (must land first) | `:ptc_runner` only |
| 1 — Project scaffold + JSON-RPC skeleton | Engineer | yes | — (gates infra) | `mcp_server/` (new), `.git/hooks/*` |
| 2 — Wire `ptc_lisp_execute` (no context/signature) | Engineer | yes | — (depends on 1's envelope) | `mcp_server/` |
| 3 — Context + signature | Engineer | yes | — (depends on 2) | `mcp_server/`, `:ptc_runner` (`to_json_value/1` lives in `PtcToolProtocol`) |
| 3.5 — Per-call tracing | Engineer | yes | Phase 4 | `mcp_server/` only (consumes 0.5's surface) |
| 4 — Cancellation + lifecycle | Engineer | yes | Phase 3.5 | `mcp_server/` |
| 5 — Packaging + distribution | Engineer | no | — | repo root, `mcp_server/`, README |
| 6a — Integration tests | Engineer | yes | 6b, 6c | `mcp_server/test/` |
| 6b — Docs | Engineer | yes | 6a, 6c | `docs/`, READMEs |
| 6c — Benchmark | Engineer | yes | 6a, 6b | `demo/`, `mcp_server/` |

Pre-Phase-1: a tiny PR adding hook scaffolding (§ 5.3 loop skeleton)
so Phase 1 doesn't collide with the hook update — see § 20.5.

The main agent spawns at most one Engineer per worktree. Concurrent
Engineers on the same worktree are forbidden (lockfile churn,
formatter conflicts). Spawn shape per phase:

```
0.5 → 1 → 2 → 3 → { 3.5 ‖ 4 } → 5 → { 6a ‖ 6b ‖ 6c }
```

`‖` denotes parallel; `→` denotes strict sequencing.

### 20.2 Codex review checkpoints

Inherits text-mode Addendum 21:

- The **main agent** runs `/codex review` between phases.
- Engineer subagents MUST NOT invoke `/codex review` or
  `/codex challenge`. If an Engineer feels review is warranted, it
  flags the recommendation in its final note; the main agent decides.

Recommended checkpoints (main agent runs review after each):

- After Phase 0.5 (telemetry surface lands in `:ptc_runner`).
- After Phase 1 (transport + scaffold lock-in).
- After Phase 2 (envelope wiring is the highest-blast-radius change).
- After Phase 3 (signature + `to_json_value/1` semantics).
- After Phase 3.5 (tracing payload policy is data-hygiene-sensitive).
- After Phase 4 (cancellation correctness is hard to test exhaustively).

Skip review after Phase 5 (release machinery) and Phase 6 (docs,
tests, bench — ground truth is the artifact, not the diff).

### 20.3 Cross-package sequencing rule

Phase 0.5 lands on main before Phase 3.5 starts. The `mcp_server/`
path dep is always live, but no MCP code may reference the new Lisp
telemetry events until 0.5 has merged.

If parallelism between 0.5 and any later MCP phase is ever attempted
(not recommended), the later phase's worktree rebases onto 0.5's
commit before its DoD is asserted. The DoD MUST run against the
rebased state, not against the worktree's pre-rebase state.

Phase 3 introduces `PtcRunner.PtcToolProtocol.to_json_value/1`
(§ 13). Although this lives in `:ptc_runner`, it ships in the same
phase as the MCP code that consumes it: a single commit (or pair of
commits in lockstep) on main. Treat it as part of the MCP request
contract for sequencing purposes — it does NOT need a separate
Phase 0.5-style standalone landing.

Same lockstep rule applies to the § 13.1 surface widenings:

- `PtcRunner.PtcToolProtocol.render_success_from_step/2` ships with
  Phase 2 (the first phase that builds success payloads).
- `PtcRunner.PtcToolProtocol.parse_signature/1` ships with Phase 3
  (the first phase that consumes signature input).

Both are additive `:ptc_runner` changes that land in the same commit
(or paired commits) as the MCP code consuming them. No standalone
phase.

### 20.4 Requirements traceability

Source-of-truth mapping from spec sections to phases. Engineer
subagents include this mapping in commit messages: every commit
lists the section IDs it satisfies (per § 20.6 workflow rule).

| Spec section | Phase |
|---|---|
| § 5.2 (repository layout) | 1 |
| § 5.3 (tooling/hooks) | pre-1 (hook scaffold) + 1 (full extension) |
| § 5.4 (hand-roll vs framework) | informational; no phase |
| § 6.1–6.4 (transport: framing, frame size, concurrency, lifecycle) | 1 |
| § 6.5 (stderr logging) | 1 |
| § 6.6 (per-call traces, opt-in) | 3.5 |
| § 6.7 row `[:ptc_runner_mcp, :call, …]` | 3.5 |
| § 6.7 row `[:ptc_runner, :lisp, :execute, …]` | 0.5 |
| § 6.8 (`TraceLog.write_to_active/1`) | 0.5 |
| § 6.8 (`PtcRunnerMcp.TraceHandler`) | 3.5 |
| § 6.9 (`--trace-payloads` policy) | 3.5 |
| § 6.10 (file naming, rotation, disk pressure) | 3.5 |
| § 7.1 (handshake, version negotiation) | 1 |
| § 7.2 (`notifications/initialized`) | 1 |
| § 7.3 (versioning policy) | informational; release-time discipline |
| § 7.4 D1 (unknown_tool deviation) | 1 (Inspector gate) + 6a (production-client gate) |
| § 7.4 D2 (`result` elision) | 3 (outputSchema) |
| § 8.1 (`tools/list` shape, annotations) | 1 (stub) + 2 (description, annotations) + 3 (`outputSchema`) |
| § 8.2 (`listChanged: false`) | 1 |
| § 8.3 (annotations rationale) | informational |
| § 8.4 (authoring guidance card) | 1 (ship file + wiring + substring anchors) + 2 (feedback-quality smoke test for `slurp`/`swap!`/`http-get`) + 3 (feedback-quality smoke test for `(get context "k")`) |
| § 9.1 (argument shape) | 2 (program) + 3 (context, signature) |
| § 9.2 (program validation) | 2 |
| § 9.3 (context validation + coercion) | 3 |
| § 9.4 (signature validation) | 3 |
| § 10.1 (envelope) | 1 (stub envelope) + 2 (real wiring) |
| § 10.2 (R22 success payload) | 2 (no validated) + 3 (validated) |
| § 10.3 (R23 error payload) | 2 (six core reasons + busy + unknown_tool) + 3 (validation_error) |
| § 10.4 (`outputSchema`) | 3 |
| § 10.5 (`isError` discipline) | 2 |
| § 11 (resource limits — table rows) | 1 (frame) + 2 (program, concurrent_calls) + 3 (context) + sandbox-inherent (timeout, memory) |
| § 12 (protocol-level errors) | 1 (parse, invalid request, method not found) + 2 (internal error path) |
| § 13 (`to_json_value/1`) | 3 |
| § 13.1 (`render_success_from_step/2`) | 2 |
| § 13.1 (`parse_signature/1`) | 3 |
| § 14 (wire format for result/prints) | 2 |
| § 15 (phases) | meta — not implemented |
| § 16 test rows | per phase that introduces the surface (each phase's DoD lists the rows it covers) |
| § 17 (open questions) | none — all locked |
| § 18 (deferred) | none — informational |
| § 19 (security model) | documented in Phase 6b |

### 20.5 Risks and pre-phase work

**Risk 1: Phase 1 + hook update collision.** Phase 1 includes the
hook extensions (§ 5.3). Two Engineers working on Phase 1 in
sibling worktrees would each modify `.git/hooks/*` and collide.
Mitigation: a **pre-Phase-1 PR** lands the hook scaffold (the
project-loop skeleton over `["." "mcp_server" "ptc_viewer"]`) before
Phase 1 spawns. Phase 1 then fills in only what's specific to the
new `mcp_server/` directory (none, since the loop covers it).

**Risk 2: Phase 6 docs/test/bench drift.** Engineers commonly notice
adjacent issues outside their nominal scope ("I see a doc bug in
Phase 6a's range"). For Phase 6 specifically, pin scope per Engineer
in the spawn instruction:

- 6a (tests) MAY edit `mcp_server/test/`, MUST NOT edit `docs/` or `demo/`.
- 6b (docs) MAY edit `docs/`, top-level `README.md`, `mcp_server/README.md`, MUST NOT edit `mcp_server/test/` or `demo/`.
- 6c (bench) MAY edit `demo/` and add benchmark code under `mcp_server/`, MUST NOT edit `docs/` or test files outside benchmark scope.

Drift between Engineers is resolved by the main agent in a
post-Phase-6 reconciliation pass, not by any single Engineer.

**Risk 3: `:ptc_runner` Phase 0.5 vs unrelated `:ptc_runner` work.**
Phase 0.5 touches `:ptc_runner` modules that are also evolving for
the text-mode plan (which has its own active tier work). Before
spawning Phase 0.5, the main agent verifies no in-flight text-mode
tier modifies `Lisp.run/2`'s entry/exit path; if one does, sequence
Phase 0.5 after that text-mode tier lands.

### 20.6 Workflow rule

Inherits text-mode Addendum 20:

- **Direct commits to main, no PRs.** Each phase lands as one or
  more commits directly on `main`.
- **Commit messages reference spec section IDs** the change
  satisfies, plus the § 16 test row IDs it covers. Format:

  ```
  <short summary>

  Satisfies: § 6.7 (lisp.execute.* events), § 6.8 (write_to_active/1)
  Tests: § 16 Tracing rows 1, 3, 5
  ```

- **`mix precommit` runs in every Mix project the commit touches**
  before push. A commit that edits both `:ptc_runner` and
  `:ptc_runner_mcp` runs `mix precommit` in `.` and `mcp_server/`.
- Where the body of this plan says "PR," read it as "commit." Where
  it says "PR description," read it as "commit message."

### 20.7 Subagent spawn template

When the main agent spawns an Engineer for a phase, the prompt MUST
include:

1. **Phase identifier** (e.g., "Phase 3 — Context + signature").
2. **Spec sections in scope** (from § 20.4 traceability table).
3. **DoD verbatim** from the relevant § 15 phase.
4. **§ 16 test rows the phase covers** (explicit list).
5. **Workflow rule pointer** ("Follow § 20.6").
6. **Codex prohibition** ("Do not invoke `/codex review` or
   `/codex challenge`. Flag a recommendation in your final note if
   you believe one is warranted.").
7. **Worktree path** (when isolation is `worktree`).
8. **Out-of-scope guards** (e.g., "Do not edit `docs/` in this
   phase").

When the main agent reports phase completion to the user, it
verifies each section ID listed in § 20.4 for that phase appears in
at least one of the phase's commit messages, and runs Codex review
per § 20.2 before announcing the phase complete.
