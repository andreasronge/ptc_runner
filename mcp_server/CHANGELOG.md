# Changelog

All notable changes to `ptc_runner_mcp` are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this package adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `Plans/ptc-runner-mcp-server.md` § 7.3 for the versioning
policy that governs MCP `protocolVersion` floor and primary
revisions.

## Unreleased

### Added

- PTC payload-reduction metrics
  (`Plans/ptc-runner-mcp-payload-reduction.md`). Aggregator-mode
  responses (`ptc_lisp_execute` with ≥ 1 upstream call, and every
  `ptc_task`) now carry a `ptc_metrics` block on `structuredContent`,
  and each `upstream_calls[]` entry gains `result_bytes` (the byte
  size of the upstream response *as received* — pre-redaction,
  pre-ring, pre-envelope-cap; `null` when not cheaply known) and
  `oversize` (`true` iff the response exceeded
  `--max-upstream-response-bytes`). `ptc_metrics` reports
  `final_result_bytes`, `prints_bytes`, the upstream-call byte tally
  split by ok/error/oversize (`upstream_result_bytes` /
  `upstream_error_bytes` / `upstream_oversize_bytes` — only successful
  non-oversize bytes count toward the denominator), the
  `payload_reduction_ratio = round(upstream_result_bytes /
  max(final_result_bytes, 1), 2)` (JSON `null` — never `0` or `∞` —
  when either side is `0`, e.g. a pure-compute or errored program),
  `utf8_bytes_div_4` token estimates, and `baseline.conservative` /
  `baseline.optimistic` blocks (`optimistic.available: false` always —
  the no-PTC counterfactual is not measurable by the server). For
  `ptc_task` the block also carries `server_side_llm` — the planner
  LLM's prompt/completion byte sizes (always present, with the fixed
  system message included in `prompt_bytes`) and provider token counts
  (`provider_reported: true` with real numbers when the LLM adapter
  surfaces `usage`, else `null` + byte estimates) — and an
  `efficiency_note` stating the ratio excludes the planner cost.
  `ptc_metrics` is additive and never appears on the `:mcp_no_tools`
  `ptc_lisp_execute` profile or on a 0-upstream-call aggregator
  program; the aggregator and `ptc_task` `outputSchema`s advertise the
  new optional fields. When `--debug-tool` is enabled, `ptc_debug
  op=stats` gains a `payload_reduction` aggregate (totals,
  p50/p95/max/weighted ratio skipping `null`s, `top_reducers` (≤ 10 by
  per-call ratio, newest tie-break), `estimated_tokens`, and — for
  windows containing `ptc_task` calls — an `agentic_planner` sub-block
  with the summed planner tokens/bytes), `ptc_debug recent` / `get`
  records carry the per-call `ptc_metrics`, and the size-cap shrink
  drops `payload_reduction.top_reducers` first, then the
  `payload_reduction` block, before touching `by_server` / `by_tool`.
  No new CLI flags, no new telemetry events.
- Opt-in `ptc_debug` diagnostics tool
  (`Plans/ptc-runner-mcp-debug-tool.md`). Disabled by default; enable
  with `--debug-tool` / `PTC_RUNNER_MCP_DEBUG_TOOL`. Read-only
  (`readOnlyHint: true, idempotentHint: true`); exposes three ops over
  a bounded in-memory ring buffer of recent `tools/call` records —
  `stats` (per-tool counts / error-rates / latency percentiles,
  error-reason histogram, `upstream_calls` outcomes, agentic planner
  stats, plus a self-description: `ring_size`, `ring_count`,
  `trace_dir_enabled`, `payload_policy`, time `window`), `recent`
  (last N records, newest-first, `errors_only` / `limit` /
  `since_seconds` filters), and `get` (one record by `request_id`;
  upgraded to the full on-disk JSONL trace when `--trace-dir` is set
  via a single bounded directory glob, else the ring record). Records
  every recognized-tool call that produced an envelope — successes,
  `args_error` validation failures, and `busy` gate rejections —
  except `ptc_debug`'s own calls. Reuses the `--trace-payloads`
  redaction policy + `Credentials.Redactor.scrub/1`; every response
  echoes `payload_policy` and `redaction_applied: true`. Responses are
  hard-capped by `--max-debug-response-bytes` (default 64 KiB) with
  graceful truncation. The ring buffer (`DebugBuffer` GenServer + ETS)
  and the per-call recording hook exist only when `--debug-tool` is
  set; `ptc_debug` is dispatched synchronously with no concurrency
  permit and is never written to the ring. The recorder is fully
  fault-isolated — a dead/overloaded `DebugBuffer` degrades to "no
  diagnostics", never to "tool call failed".
- New flags: `--debug-tool` / `PTC_RUNNER_MCP_DEBUG_TOOL` (bool,
  default `false`); `--debug-ring-size` / `PTC_RUNNER_MCP_DEBUG_RING_SIZE`
  (int, default `500`, clamped to `[10, 5000]` with a warn-log on
  clamp); `--max-debug-response-bytes` /
  `PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES` (int, default `65536`).
- `mcp/text` and `mcp/json` are part of the base PTC-Lisp surface
  (`:ptc_runner`'s `Env.initial/0`) and are available unconditionally
  in both default and aggregator modes. `(mcp/text r)` returns
  `r["content"][0]["text"]` or `nil`. `(mcp/json r)` returns
  `r["structuredContent"]` when present (preserving the `:json-null`
  sentinel as a valid sub-field value), otherwise falls back to
  `(json/parse-string (mcp/text r))`. Both helpers are pure shape
  inspectors and never raise. Aggregator and default authoring cards
  list the helpers; non-aggregator clients can still use them, they
  just return `nil` against unrelated map shapes. See
  `Plans/json-support.md` §5.
- Aggregator auto-decode of JSON-as-text upstream payloads
  (`Plans/json-support.md` §6 / Phase C). When a successful
  `tools/call` envelope's `content[0]` is a text item with mimeType
  `application/json` or any `+json` suffix (RFC 6839 — covers
  `application/ld+json`, `application/vnd.foo+json`, etc.) and
  `structuredContent` is absent or `nil`, the aggregator decodes the
  text and adds it under `structuredContent` *additively* —
  `content[]` is preserved verbatim. A decoded bare `nil` (the JSON
  literal `"null"`) is substituted with the `:"json-null"` keyword
  sentinel at the sub-field level so it's distinguishable from
  "field absent"; `false` / `0` / `""` / `[]` are legitimate JSON
  payloads and promote verbatim. Pipeline ordering is
  `classify_value` → auto-decode → §7.3 top-level `:json-null`
  rewrite, so `isError: true` envelopes never reach auto-decode and
  never trigger a spurious telemetry event. Malformed JSON with
  matching mimeType passes through unchanged: the upstream call
  itself succeeded, so a normal `status: "ok"` entry is still
  recorded in `upstream_calls`, but **no** `reason` / `error`
  fields are added for the soft decode failure — that side-channel
  is reserved for world-faults. The new telemetry event is the only
  operator-visible signal for the decode-failure outcome.
- New telemetry event
  `[:ptc_runner_mcp, :upstream, :auto_decode, :stop]` per
  `Plans/json-support.md` §7. Metadata: `server`, `tool`,
  `mime_type`, `outcome` (one of `:promoted`, `:already_structured`,
  `:decode_failed`). Measurements vary by outcome —
  `:promoted` carries `decoded_bytes` (best-effort:
  `byte_size(Jason.encode!(value))`; round-trip encode failure
  suppresses the field but not the event), `:already_structured`
  carries `decoded_bytes: 0`, `:decode_failed` carries
  `decoded_bytes: 0` and `text_bytes` (size of the rejected text
  for cap correlation). No event fires when no text-content item is
  present or when the mimeType doesn't match.

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
