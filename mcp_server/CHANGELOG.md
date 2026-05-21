# Changelog

All notable changes to `ptc_runner_mcp` are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this package adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `Plans/ptc-runner-mcp-server.md` § 7.3 for the versioning
policy that governs MCP `protocolVersion` floor and primary
revisions.

## Unreleased

### Removed

- Removed the MCP-facing `signature` argument from `lisp_eval`
  and `lisp_session_eval`. Clients should use `output_schema` for
  return validation. A present `signature` argument now returns
  `args_error`.

### Added

- Agentic prompt-size benchmark
  (`bench/agentic_prompt_bench.exs`). The deterministic tier-1 harness
  freezes synthetic upstream catalogs and measures server-side
  `lisp_task` planner system-prompt bytes, client-visible `lisp_task`
  tool-entry bytes, and `lisp_eval` tool-entry bytes across
  `--catalog-mode auto|inline|lazy`, small/medium/large fleet shapes,
  and `--agentic-capability-summary-max-bytes` sensitivity rows. It
  makes zero LLM/provider calls, supports `--runs` stability checks and
  `--out` JSON output, and is documented in README "Agentic mode".
- Agentic real-provider eval harness (`bench/agentic_real_eval.exs`) for
  issue #931. The tier-2 script runs `lisp_task` through OpenRouter
  against a local filesystem MCP upstream, covers single-read,
  multi-file aggregation, lazy catalog discovery, error recovery, and
  negative-capability cases, and writes JSON plus Markdown findings.
  The initial Gemini Flash Lite findings are documented in
  `bench/agentic_real_eval_findings.md`.
- PTC payload-reduction metrics
  (`Plans/ptc-runner-mcp-payload-reduction.md`). Aggregator-mode
  responses (`lisp_eval` with ≥ 1 upstream call, and every
  `lisp_task`) now carry a `ptc_metrics` block on `structuredContent`,
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
  `lisp_task` the block also carries `server_side_llm` — the planner
  LLM's prompt/completion byte sizes (always present, with the fixed
  system message included in `prompt_bytes`) and provider token counts
  (`provider_reported: true` with real numbers when the LLM adapter
  surfaces `usage`, else `null` + byte estimates) — and an
  `efficiency_note` stating the ratio excludes the planner cost.
  `ptc_metrics` is additive and never appears on the `:mcp_no_tools`
  `lisp_eval` profile or on a 0-upstream-call aggregator
  program; the aggregator and `lisp_task` `outputSchema`s advertise the
  new optional fields. When `--debug-tool` is enabled, `lisp_debug
  op=stats` gains a `payload_reduction` aggregate (totals,
  p50/p95/max/weighted ratio skipping `null`s, `top_reducers` (≤ 10 by
  per-call ratio, newest tie-break), `estimated_tokens`, and — for
  windows containing `lisp_task` calls — an `agentic_planner` sub-block
  with the summed planner tokens/bytes), `lisp_debug recent` / `get`
  records carry the per-call `ptc_metrics`, and the size-cap shrink
  drops `payload_reduction.top_reducers` first, then the
  `payload_reduction` block, before touching `by_server` / `by_tool`.
  No new CLI flags, no new telemetry events.
- Opt-in `lisp_debug` diagnostics tool
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
  except `lisp_debug`'s own calls. Reuses the `--trace-payloads`
  redaction policy + `Credentials.Redactor.scrub/1`; every response
  echoes `payload_policy` and `redaction_applied: true`. Responses are
  hard-capped by `--max-debug-response-bytes` (default 64 KiB) with
  graceful truncation. The ring buffer (`DebugBuffer` GenServer + ETS)
  and the per-call recording hook exist only when `--debug-tool` is
  set; `lisp_debug` is dispatched synchronously with no concurrency
  permit and is never written to the ring. The recorder is fully
  fault-isolated — a dead/overloaded `DebugBuffer` degrades to "no
  diagnostics", never to "tool call failed".
- New flags: `--debug-tool` / `PTC_RUNNER_MCP_DEBUG_TOOL` (bool,
  default `false`); `--debug-ring-size` / `PTC_RUNNER_MCP_DEBUG_RING_SIZE`
  (int, default `500`, clamped to `[10, 5000]` with a warn-log on
  clamp); `--max-debug-response-bytes` /
  `PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES` (int, default `65536`).
- `(tool/mcp-call ...)` now returns tagged data directly:
  `{:ok true :value payload :value_kind :json|:text|:none}` on success,
  or `{:ok false :reason kw :message text}` for recoverable
  upstream/tool failures. `mcp/text` and `mcp/json` are no longer part
  of the public PTC-Lisp surface; inspect `:ok` and use `:value`.
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
- Response profiles for `lisp_eval` and `lisp_session_eval`
  (`Plans/ptc-runner-mcp-slim-responses.md`). New `--response-profile`
  / `PTC_RUNNER_MCP_RESPONSE_PROFILE` flag selects `slim` (the new
  default for eval tools — concise text in `content[0].text`, no
  `structuredContent`, no advertised `outputSchema`, with
  `ptc_metrics` / `upstream_calls` / empty `prints`/`feedback` /
  default `truncated` omitted),
  `structured` (compact `structuredContent` + concise text,
  observability fields still omitted; compact `outputSchema`
  advertised), or `debug` (the pre-existing verbose shape: mirrored
  full payload, `ptc_metrics`, `upstream_calls`, full `outputSchema`).
  `--debug-tool` infers `debug` unless the profile is set explicitly;
  `--debug-tool --response-profile slim` keeps the client response
  slim while still feeding the full pre-slim payload to the `lisp_debug`
  recorder internally (the private `__lisp_debug_structured` carrier is
  stripped before the JSON-RPC frame is written). For session evals,
  normal slim/structured responses expose changed binding names rather
  than stored binding values; full memory previews and per-eval
  `ptc_metrics` / `upstream_calls` remain available through
  `lisp_debug`. The tool description advertises the active profile.
  See README "Response profiles" and
  `bench/local_payload_bench.py` for the wire-cost comparison
  (`slim` is roughly 13-28x smaller per call than `debug`).
- Catalog discovery from inside PTC-Lisp, aggregator mode
  (`Plans/ptc-runner-mcp-catalog-exposure.md`). New `catalog/`
  namespace with five builtins — `catalog/summary`,
  `catalog/list-servers`, `catalog/list-tools` (paginated via
  `:limit` / `:offset`), `catalog/describe-tool`, and
  `catalog/search-tools` (deterministic lexical ranking with
  `{server, tool}` tie-breaking; `:limit` / `:load` opts). World-fault
  → `nil` / programmer-fault → raise, same split as `tool/mcp-call`;
  results size-capped at `--max-catalog-result-bytes`; catalog ops run
  on a separate per-program budget (`--max-catalog-ops-per-program`)
  that never consumes the upstream-call quota. Unavailable outside
  aggregator mode.
- Catalog-exposure config and upstream metadata. New flags
  `--catalog-mode`, `--catalog-inline-max-chars`,
  `--catalog-inline-max-tools`, `--max-catalog-ops-per-program`,
  `--max-catalog-result-bytes` (with `PTC_RUNNER_MCP_*` equivalents,
  CLI > env > default). Each upstream entry in the upstreams config may
  carry optional `description` (string) and `capabilities` (array)
  fields; they are extracted before transport normalization (so they
  never reach the stdio `command`/`env` or HTTP `url`/headers paths and
  never trip the "unknown config key" warning), type-validated
  (invalid → warn + dropped), and surfaced through `catalog/summary` /
  `catalog/list-servers` / `catalog/search-tools` (`description` falls
  back to the server name when absent).

### Breaking changes

- The default `lisp_eval` and `lisp_session_eval` response shape is now `slim`
  (`Plans/ptc-runner-mcp-slim-responses.md`): `content[0].text` carries
  concise human-readable text (the value, or `<prints>…</prints>` +
  `<result>…` when the program printed), there is no
  `structuredContent`, and no `outputSchema` is advertised even when
  `output_schema` is present. `ptc_metrics`, `upstream_calls`,
  empty `prints`/`feedback`, and a default `truncated: false` are
  omitted. Clients that parsed `structuredContent` from eval tools
  (or relied on the advertised `outputSchema`) must
  start the server with `--response-profile structured` (compact
  machine-readable shape) or `--debug-tool` / `--response-profile
  debug` (the pre-existing verbose shape). The MCP v1 response contract
  in `Plans/ptc-runner-mcp-server.md` §10 is now the `debug` profile.

- `outputSchema` for stateless `lisp_eval` no longer includes the
  `memory` field on success responses, and stateless `tools/call`
  responses no longer surface `memory.{changed, stored_keys,
  truncated}`. Each stateless MCP call is one-shot — `defn`'d names
  never persist across calls — so the field misled callers into
  expecting state. Stateful `lisp_session_eval` structured responses
  do expose compact memory metadata (`changed_keys`, `stored_keys`) but
  do not echo stored binding values. Clients that read stateless
  `lisp_eval` `structuredContent["memory"]` should remove that path.
  Issue #879.

### Documentation

- `tools/list` and the public docs now point clients at
  `output_schema` for return validation instead of the removed
  MCP-facing `signature` argument.

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

- Single tool advertised: `lisp_eval`. Description is
  `PtcToolProtocol.tool_description(:mcp_no_tools)` followed by
  `\n\n` followed by the verbatim authoring card at
  `priv/prompts/mcp_authoring_card.md` (loaded via `@external_resource`).
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
