# Changelog

All notable changes to `ptc_runner_mcp` are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this package adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `Plans/ptc-runner-mcp-server.md` § 7.3 for the versioning
policy that governs MCP `protocolVersion` floor and primary
revisions.

## Unreleased

### Breaking changes

- `outputSchema` no longer includes the `memory` field on success
  responses, and `tools/call` responses no longer surface
  `memory.{changed, stored_keys, truncated}`. Each MCP call is
  one-shot — `defn`'d names never persist across calls — so the
  field misled callers into expecting state. Clients that read
  `structuredContent["memory"]` should remove that path. Issue #879.

### Documentation

- `tools/list` describes the optional `signature` argument as
  accepting both `() -> {...}` and the bare-type shorthand `{...}`.
  Issue #882.

## 0.1.0 — 2026-05-07

Initial release. Implements Phases 0.5 → 5 of the v1
specification at `Plans/ptc-runner-mcp-server.md`.

### Handshake and capabilities

- `initialize` / `notifications/initialized` lifecycle.
- Protocol-version negotiation: primary `2025-11-25`, compatibility
  floor `2025-06-18`. Unknown client revisions fall back to the
  primary.
- Capability profile: `tools.listChanged: false`; no `resources`,
  `prompts`, `experimental.tasks`, `elicitation`, or `sampling`
  are advertised.
- `serverInfo.version` reflects the package version.

### Transport

- stdio NDJSON-framed JSON-RPC 2.0 reader / writer with per-frame
  size cap (`--max-frame-bytes`, default 8 MiB) and oversized-line
  resync that emits a single parse-error per drop.
- Structured JSON-Lines logger on stderr (`PtcRunnerMcp.Log`).

### Request / response contract

- Single tool advertised: `ptc_lisp_execute`. Description is
  `PtcToolProtocol.tool_description(:mcp_no_tools)` followed by
  `\n\n` followed by the verbatim authoring card at
  `priv/mcp_authoring_card.md` (loaded via `@external_resource`).
- `tools/call` always returns an MCP tool-result envelope —
  including for unknown tool names (`reason: "unknown_tool"`,
  per § 7.4 deviation D1) and for capacity exhaustion
  (`reason: "busy"`).
- Argument validation: `program` (non-empty string, ≤
  `--max-program-bytes`), optional `context` (object with no
  `/`-bearing keys, ≤ `--max-context-bytes`), optional
  `signature` (string parsed via `PtcToolProtocol`).
- Result envelope: a single `text` content block whose body
  parses to the same object as `structuredContent`, plus
  `isError`. R22 success and every R23 reason share the
  envelope shape.

### Signatures and context

- Optional `signature` validates and coerces the program's return
  value via `PtcToolProtocol.validate_return/2`. Successful runs
  with a signature carry the validated value as
  `structuredContent.validated`.
- `context` keys are bound under the `data/` namespace inside
  the program (e.g. `{"records": [...]}` → `data/records`).

### Tracing

- Opt-in per-call JSONL traces via `--trace-dir`.
  `--trace-payloads` (`none` / `summary` / `full`) controls
  inclusion of `program` / `context` / `result` bytes;
  `--trace-max-files` enforces a rolling-deletion cap on the
  trace directory. Tracing is OFF and zero-overhead by default.

### Concurrency and cancellation

- Per-call worker process; `--max-concurrent-calls` (default 8)
  gates concurrency and returns `reason: "busy"` when saturated.
- JSON-RPC `notifications/cancelled` halts in-flight calls and
  emits `reason: "cancelled"` deterministically.
- Drain semantics on `shutdown` / `exit` honor in-flight workers
  before terminating the supervision tree.

### Packaging

- Mix release configuration. `MIX_ENV=prod mix release` produces
  `_build/prod/rel/ptc_runner_mcp/bin/ptc_runner_mcp` with
  standard lifecycle commands (`start`, `stop`, `restart`,
  `remote`, `version`, `eval`).
- `mcp_server/README.md` ships verbatim `claude_desktop_config.json`,
  `cline_mcp_settings.json`, and Cursor `mcp.json` snippets.
- Burrito-bundled single-file binaries are deferred to a
  follow-up release pending CI tooling (Zig 0.11+ and per-target
  cross-build infrastructure are not yet wired into this repo).
