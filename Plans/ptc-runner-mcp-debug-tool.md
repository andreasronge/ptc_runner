# PtcRunner MCP Server — Debug Tool Specification

| Field | Value |
|---|---|
| Status | Draft |
| Date | 2026-05-11 |
| Related | `Plans/ptc-runner-mcp-server.md` (§ 6.5–6.10 logging/tracing/telemetry, § 8 tool surface), `Plans/ptc-runner-mcp-aggregator.md` (aggregator/`upstream_calls`), `Plans/agentic-mcp-aggregator.md` + `Plans/agentic-ptc-task-subagent-spec.md` (`ptc_task`), `mcp_server/lib/ptc_runner_mcp/trace_handler.ex`, `mcp_server/lib/ptc_runner_mcp/trace_file.ex`, `mcp_server/lib/ptc_runner_mcp/json_rpc.ex` |
| Decision basis | Author preference + Codex consult (2026-05-11): build an opt-in `ptc_debug` tool, ring-buffer first / trace-dir as enrichment, off by default behind its **own independent flag** |
| Revision | rev 2 (2026-05-11), review-tightened: recording semantics pinned (the ring records every recognized-tool call that produced an envelope, incl. `args_error`/`busy`; `ptc_debug` excluded); trace-file `get` is one bounded directory glob; `ptc_debug` is dispatched synchronously with no concurrency permit; dedicated `--max-debug-response-bytes`; upstream buckets use the canonical `upstream_calls[].reason` vocabulary; Q1/Q2/Q4 resolved |

## 1. Summary

Add an opt-in MCP tool, `ptc_debug`, that lets an MCP **client LLM** investigate
how well the MCP server — including aggregator mode and agentic (`ptc_task`)
mode — is behaving, without the client needing filesystem access or having to
grep raw JSONL.

`ptc_debug` exposes three read-only operations over an in-memory ring buffer of
recent `tools/call` records:

- `stats` — aggregate health: call counts, success/error rates, latency
  percentiles, error-reason histogram, `ptc_lisp_execute` vs `ptc_task` split,
  upstream-call outcomes, agentic planner stats — plus a self-description of
  *what* the client is looking at (ring vs trace files, window, redaction).
- `recent` — the last N call records, optionally filtered to errors.
- `get` — the full (redacted) record for one `request_id`; upgraded to the full
  on-disk trace when `--trace-dir` is configured.

`ptc_debug` is **disabled by default** and advertised only when explicitly
enabled by its own switch. It never changes `ptc_lisp_execute` or `ptc_task`,
and it works regardless of whether aggregator/agentic mode is active.

## 2. Motivation

Today the only way to see "how is this server doing" is:

1. Read structured JSONL operational logs on **stderr** (`§ 6.5`,
   `lib/ptc_runner_mcp/log.ex`) — requires capturing the server's stderr.
2. Read per-call JSONL **trace files** under `--trace-dir` (`§ 6.6 / 6.10`,
   `lib/ptc_runner_mcp/trace_file.ex`) — opt-in, on disk, one file per call.
3. Open the human-facing web trace viewer (`ptc_viewer/`, `mix ptc.viewer`).

None of these are reachable by an MCP client LLM over the stdio MCP connection.
A client that wants to self-diagnose ("are my programs timing out?", "is the
GitHub upstream flaky?", "is `ptc_task` planning badly?") has to ask the human
to go dig. We want the client to be able to ask the server directly and get a
compact, structured answer.

### Why a tool and not "just expose the folder" or MCP resources

- **Expose the trace folder.** The stdio server can't serve files; the client
  would need its own filesystem MCP server pointed at `--trace-dir`, then would
  receive raw per-call JSONL it must correlate by `request_id` and aggregate
  itself. Fine as a manual/advanced escape hatch (documented in § 9), wrong as
  the product surface.
- **MCP `resources` capability.** Resources are application/client-controlled
  and meant for *raw readable data*. "Compute success rates, filter failures,
  summarize upstream behavior" is a model-controlled operation — that's a tool.
  Exposing `trace://recent` / `trace://request/{id}` as resources is a
  reasonable *future* addition (§ 11), but not the primary investigation
  interface, and the server currently advertises no `resources` capability
  (`§ 7.1`).

## 3. Core principles

- `ptc_debug` is **experimental and disabled by default**.
- It has its **own independent on/off switch** — not folded under `--agentic`
  or aggregator mode. It is orthogonal to both and useful even for a
  no-tools `ptc_lisp_execute`-only server.
- It is **read-only**: no operation mutates server state. Tool annotations:
  `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`,
  `openWorldHint: false`.
- Its primary data source is an **in-memory ring buffer** populated as a
  side effect of serving `tools/call`. No `--trace-dir` required.
- It records **every recognized-tool call that produced an MCP envelope** —
  success, application-level validation error (`args_error`), or concurrency-gate
  `busy` rejection. `ptc_debug`'s own calls, unknown-tool requests, and transport
  errors that occur before a tool name is known are *not* recorded (see § 5.1).
- It **reuses the existing redaction stack**: the `--trace-payloads` policy
  (`§ 6.9`) and `PtcRunnerMcp.Credentials.Redactor.scrub/1`. It never emits
  data at a level higher than `--trace-payloads` allows. Every response carries
  `redaction_applied: true` and echoes the active `payload_policy`.
- It is **bounded**: result sizes are hard-capped by `--max-debug-response-bytes`,
  no path input is accepted, records are addressed by `request_id` (or its hash),
  never by filename, and the only disk access is one bounded directory glob on
  `op=get` when `--trace-dir` is set.
- It is **observable about itself**: `stats` always reports `debug_source`,
  `ring_size`, `ring_count`, `trace_dir_enabled`, `payload_policy`, and the
  time `window`, so the client knows whether it is seeing "everything since
  boot" or "the last N calls in process memory".
- `ptc_debug`'s own calls are **excluded** from the ring buffer (no self-noise,
  no recursion).

## 4. Configuration

New boot-time config, parsed once at startup with the standard precedence
(CLI flag > env var > default), mirroring the existing flags in
`lib/ptc_runner_mcp/application.ex`:

| Setting | CLI flag | Env var | Type | Default |
|---|---|---|---|---|
| Enable the tool | `--debug-tool` | `PTC_RUNNER_MCP_DEBUG_TOOL` | boolean | `false` |
| Ring buffer capacity (records) | `--debug-ring-size` | `PTC_RUNNER_MCP_DEBUG_RING_SIZE` | integer | `500` |
| Max `ptc_debug` response size (bytes) | `--max-debug-response-bytes` | `PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES` | integer | `65536` |

Notes:

- `--debug-ring-size` is clamped to `[10, 5000]`; out-of-range values are
  clamped and a `warn` log line is emitted.
- `--max-debug-response-bytes` is raised to a small floor (4 KiB) if set lower —
  enough to always hold a minimal envelope — and a `warn` log line is emitted on
  clamp. This keeps the cap a *real* hard limit even for absurd operator values.
- The ring buffer (`DebugBuffer` process + ETS table) and the per-call recording
  hook exist **only when `--debug-tool` is set**. When disabled there is no
  process, no ETS table, and only a single cheap `:persistent_term` read per call
  (the `DebugConfig.enabled?()` gate); the tool is not advertised in `tools/list`.
- `ptc_debug` honors `--trace-payloads` (default `summary`). There is **no
  separate debug payload knob in v1** (§ 12 Q1, resolved). Operators who enable
  `ptc_debug` on a shared/production server should keep `--trace-payloads summary`
  (or `none`).
- New module `PtcRunnerMcp.DebugConfig` follows the `AgenticConfig` /
  `AggregatorConfig` pattern: `defaults/0`, `set/1`, `get/0`, `enabled?/0` (plus
  `ring_size/0`, `max_response_bytes/0`), stored in `:persistent_term`. New
  `apply_debug_config/1` in `PtcRunnerMcp.Application`, wired alongside
  `apply_agentic_config/1`.

## 5. Data model — the ring buffer

### 5.1 What gets recorded

**What is recorded.** The ring records one **call record** for every
*recognized-tool* `tools/call` (`ptc_lisp_execute`, `ptc_task`) that produced an
MCP envelope — successes, application-level validation errors (`args_error` —
e.g. a malformed `signature` or oversized `program`), and concurrency-gate
`busy`/overload rejections. It does **not** record: `ptc_debug`'s own calls
(successful or not); unknown-tool requests; or transport/JSON-RPC errors that
happen before a tool name is known (oversized frame, malformed JSON-RPC) — those
can't be attributed to a tool. Consequence: `args_error` and `busy` are first-
class buckets in `stats.errors.by_reason`, not phantom ones.

**Where it's captured.** At the recognized-tool dispatch boundary in
`PtcRunnerMcp.JsonRpc` — the wrapper around argument validation, the concurrency
gate, and execution (`traced_tools_call/3` sits *inside* that wrapper). That is
the only placement that sees all three of: a validation-error envelope, a gate
`busy` envelope, and the final success/error envelope. It already has the
`request_id` and the inner `arguments` (redacted at this point via the same
`--trace-payloads` machinery), and — for executed calls — the final envelope,
which already aggregates `upstream_calls` (aggregator mode) and
`planner`/`execution`/`upstream_calls` (`ptc_task`). So the recorder reads
envelope + timing; it does **not** correlate telemetry spans. (Implementation
note: the concurrency gate currently lives in `Stdio`, just outside
`traced_tools_call/3` — see the comment on `JsonRpc.traced_tools_call/3` — so the
record call lands in the `Stdio` worker around the whole recognized-tool path,
*or* the gate moves into `JsonRpc`; either is fine as long as the recorder
observes validation errors, gate rejections, and the final envelope alike.)

For records where the program never executed — `args_error` (the
`program`/`context` failed validation, so the raw input is untrusted and
unbounded) or `busy` (the args were never inspected) — `program` and `context`
are **always `nil`**, not stored even under `--trace-payloads full`: a rejected
request must not be able to fill the count-bounded ring with payloads that
exceeded the tool limits. `result_bytes`/`prints_count` are `nil`, `status` is
`:error`, `reason` is `"args_error"` / `"busy"`, and `agentic` is `nil`. (A
`runtime_error`/`timeout`/`fail` record *does* keep `program`/`context` — the
program ran, so it already passed `--max-program-bytes` / `--max-context-bytes`
and the data is bounded and useful.)

Record shape (internal, atom-keyed; redacted per `--trace-payloads` *before*
storage):

```elixir
%{
  request_id: String.t(),          # full id; surfaced as-is in `recent`/`get`
  ts: DateTime.t(),                # call start, UTC
  tool: String.t(),                # "ptc_lisp_execute" | "ptc_task"
  status: :ok | :error,
  is_error: boolean(),             # MCP envelope `isError`
  reason: String.t() | nil,        # error reason string when status == :error
  duration_ms: non_neg_integer(),
  program: map() | nil,            # redacted per policy: {sha256, preview, bytes} at `summary`
  context: map() | nil,            # redacted per policy: per-key {type, count} at `summary`
  result_bytes: non_neg_integer() | nil,
  prints_count: non_neg_integer() | nil,
  signature_present?: boolean(),
  protocol_version: String.t(),
  upstream_calls: [                # from the envelope decoration; [] when none
    %{server: String.t(), tool: String.t(), status: String.t(),
      duration_ms: non_neg_integer() | nil, reason: String.t() | nil}
  ],
  agentic: %{                      # present only for tool == "ptc_task"
    planner_status: :ok | :error,
    planner_duration_ms: non_neg_integer() | nil,
    planner_rejects: non_neg_integer(),  # validation rejects this task
    retries: non_neg_integer(),
    program_bytes: non_neg_integer() | nil
  } | nil
}
```

`error` reasons and messages are captured in full at every payload level
(consistent with `§ 6.9`'s "error reasons ALWAYS captured" rule).

### 5.2 Storage mechanics

- Module `PtcRunnerMcp.DebugBuffer` — a `GenServer` owning a private ETS table
  (`:ordered_set`, keyed by a monotonically increasing integer). Started as a
  supervised child of `PtcRunnerMcp.Supervisor` **only when `--debug-tool` is
  set**.
- Public API: `record(record_map) :: :ok` (cast — fire-and-forget, never blocks
  or fails the tool call), `stats(opts) :: map()`, `recent(opts) :: [map()]`,
  `get(request_id) :: {:ok, map()} | :not_found`.
- On `record/1`: insert, then if `:ets.info(tab, :size) > ring_size`, delete the
  lowest key(s). FIFO eviction, no compression, no archival — same philosophy as
  `--trace-max-files`.
- `record/1` is a side effect of serving the request and **must never** make a
  `tools/call` fail: wrap the cast so any error is swallowed and logged at
  `warn`. (A dead/overloaded `DebugBuffer` degrades gracefully — same contract
  as a failed trace write in `§ 6.10`.)
- The buffer is **process-local memory**: it is lost on restart, and in a
  multi-client deployment it mixes records from all clients on that process.
  Both facts are surfaced in `stats` (`debug_source: "ring_buffer"`,
  plus the `window`). See § 8 (security).

### 5.3 `--trace-dir` enrichment

When `--trace-dir` is configured, `op=get` lists the directory once (via
`File.ls/1` — not `Path.wildcard`, so a `--trace-dir` containing glob
metacharacters is treated literally) and selects files named
`*-<hash8>-*.jsonl`, where `<hash8>` is `TraceFile.request_id_hash8(request_id)`.
On a same-millisecond hash collision it picks the newest by mtime. Then:

- **Inline (`source: "trace_file"`, `record: <lines>`)** — *only* when the
  *current* `--trace-payloads` is `full`. Inlining returns a trace at `full`
  fidelity; a trace written by an earlier run (or at a more permissive policy)
  must not be served at full fidelity through a server now running at `summary`
  / `none`. The loaded lines are re-run through `Credentials.Redactor.scrub_deep/1`
  for the current credential set (defence in depth — the trace was already
  scrubbed for the credentials active when it was written).
- **Pointer (`source: "trace_file"`, no `record`, `note: "…not inlined under
  --trace-payloads=<policy>…"`)** — when a file matches but the current policy
  is `summary` / `none`. If this run's ring also has the record, that is
  returned instead (`source: "ring_buffer"`, redacted per the current policy)
  with the same note appended.
- **`{found: true, truncated: true, note: "…exceeds --max-debug-response-bytes…"}`**
  — when the matching file (at `full`) is larger than `--max-debug-response-bytes`;
  a single `File.stat` decides this, the file body is never read.
- **Ring fallback / `found: false`** — no `--trace-dir`, no match, or read
  failure.

This is the only disk access `ptc_debug` ever makes: one `File.ls` plus, when
inlining, one `File.stat` and one bounded `File.read` (the file is at most
`--max-debug-response-bytes`).

`stats` / `recent` read **only** the ring buffer in v1 — no directory scan, no
file reads — keeping them O(ring_size) and side-effect free. A capped, opt-in
trace-dir scan for `stats` is deferred (§ 12 Q3).

## 6. Tool contract

### 6.1 `tools/list`

When `--debug-tool` is set, `Tools.list/0` appends a `ptc_debug` entry (after
`ptc_lisp_execute` and, if present, `ptc_task`). When unset, nothing changes.

`description` (domain-blind, no test/benchmark hints):

> Read-only diagnostics for this MCP server. Inspect recent `tools/call`
> activity: aggregate stats (success/error rates, latency, error reasons,
> per-tool and upstream-call breakdown), the most recent calls, or one call's
> redacted record by `request_id`. Data is a bounded in-memory window since the
> server last started; payloads are redacted. Use this to investigate whether
> programs, the aggregator, or agentic tasks are behaving well.

`annotations`: `{readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false}`.

### 6.2 `inputSchema`

```json
{
  "type": "object",
  "properties": {
    "op":            { "type": "string", "enum": ["stats", "recent", "get"] },
    "limit":         { "type": "integer", "minimum": 1, "maximum": 200,
                       "description": "recent: max records to return (default 20)" },
    "since_seconds": { "type": "integer", "minimum": 1, "maximum": 86400,
                       "description": "stats/recent: only consider calls newer than this" },
    "errors_only":   { "type": "boolean",
                       "description": "stats/recent: restrict to status == error" },
    "request_id":    { "type": "string", "maxLength": 256,
                       "description": "get: the call to fetch (required for op=get)" }
  },
  "required": ["op"],
  "additionalProperties": false
}
```

Validation: unknown `op`, missing `request_id` for `op=get`, or bad types →
the same `args_error` envelope path used by the other tools. No concurrency
permit is consumed, and — per § 5.1 — `ptc_debug` calls are never written to the
ring, valid or not.

### 6.3 `outputSchema`

`structuredContent` is a `oneOf` discriminated by the echoed `op`. Common fields
on every variant: `op`, `payload_policy` (`"none"|"summary"|"full"`),
`redaction_applied: true`.

**`op: "stats"`:**

```json
{
  "op": "stats",
  "payload_policy": "summary",
  "redaction_applied": true,
  "debug_source": "ring_buffer",
  "ring_size": 500,
  "ring_count": 137,
  "trace_dir_enabled": true,
  "window": { "from": "2026-05-11T08:01:02.123Z", "to": "2026-05-11T09:14:55.901Z", "calls": 137 },
  "by_tool": {
    "ptc_lisp_execute": { "calls": 120, "ok": 110, "error": 10, "error_rate": 0.083,
                          "duration_ms": { "p50": 12, "p95": 210, "max": 1400 } },
    "ptc_task":         { "calls": 17,  "ok": 14,  "error": 3,  "error_rate": 0.176,
                          "duration_ms": { "p50": 1300, "p95": 2100, "max": 4500 } }
  },
  "errors": { "by_reason": { "timeout": 4, "runtime_error": 3, "args_error": 6, "busy": 1 } },
  "upstream_calls": {
    "total": 42, "ok": 38,
    "by_reason": { "timeout": 2, "cap_exhausted": 1, "upstream_unavailable": 1, "response_too_large": 0, "upstream_error": 0 },
    "by_server": { "github": { "total": 30, "ok": 28,
      "by_reason": { "timeout": 1, "cap_exhausted": 1, "upstream_unavailable": 0, "response_too_large": 0, "upstream_error": 0 } } }
  },
  "agentic": { "tasks": 17, "planner_calls": 17, "planner_errors": 1, "planner_rejects": 1, "retries": 2 }
}
```

`agentic` and `upstream_calls` are omitted (or `null`) when the window contains
no `ptc_task` calls / no upstream calls respectively. The keys under
`errors.by_reason` are the application-level error `reason` strings the server
already emits (`timeout`, `runtime_error`, `args_error`, `busy`, …); the keys
under `upstream_calls.by_reason` are exactly the canonical `upstream_calls[].reason`
vocabulary defined in `Plans/ptc-runner-mcp-aggregator.md` (`timeout`,
`cap_exhausted`, `upstream_unavailable`, `response_too_large`, `upstream_error`).
The implementer pulls both exact string sets from the existing code/specs rather
than re-deriving them here; `by_reason` is open-ended (unknown reasons pass
through verbatim) so a vocabulary change doesn't silently drop data.

`stats` also carries an optional `payload_reduction` aggregate (omitted / `null`
when the window has no call carrying a `ptc_metrics` block; `recent` / `get`
records carry the per-call `ptc_metrics`, and `get`'s per-entry `upstream_calls`
include `result_bytes` / `oversize`) — see
`ptc-runner-mcp-payload-reduction.md` for the `payload_reduction` stats section,
the `ptc_metrics` envelope block, and the `upstream_calls[]` byte-field
additions.

**`op: "recent"`:**

```json
{
  "op": "recent",
  "payload_policy": "summary",
  "redaction_applied": true,
  "count": 10,
  "calls": [
    { "request_id": "abc-123", "ts": "2026-05-11T09:14:55.901Z", "tool": "ptc_lisp_execute",
      "status": "error", "reason": "timeout", "duration_ms": 1001,
      "program": { "sha256": "…", "preview": "(loop …", "bytes": 312 },
      "context": { "items": { "type": "array", "count": 50 } },
      "result_bytes": null, "prints_count": 0, "upstream_calls": 2 }
  ]
}
```

(`upstream_calls` in `recent` is the count; full per-call upstream detail is in
`get`. `program`/`context` shapes follow `§ 6.9`'s pinned `summary` semantics;
at `none` they're byte counts only; at `full` they're the raw values.)

**`op: "get"`:**

```json
{
  "op": "get",
  "request_id": "abc-123",
  "payload_policy": "summary",
  "redaction_applied": true,
  "found": true,
  "source": "trace_file",
  "record": { /* trace-file JSONL lines (source=trace_file) OR the full redacted ring record (source=ring_buffer) */ }
}
```

When not found: `{ "op": "get", "request_id": "…", "found": false, "source": "ring_buffer", "redaction_applied": true }`.

### 6.4 Size cap

`--max-debug-response-bytes` (default 64 KiB; § 12 Q4, resolved — a dedicated
knob, *not* coupled to `--max-upstream-response-bytes`, which governs an
unrelated surface) bounds the **whole JSON-RPC reply frame**, not just
`structuredContent`: the `{"jsonrpc":"2.0","id":<id>,"result":<envelope>}`
wrapper — including the client-chosen `id` — counts against it, and the payload
budget is the cap net of that wrapper. On overflow: `recent` drops oldest
records until it fits and sets `"truncated": true`; `stats` drops the heaviest
optional sections — `payload_reduction.top_reducers` first, then the whole
`payload_reduction` block, then `by_server`, then per-tool `duration_ms`
detail (see `ptc-runner-mcp-payload-reduction.md`) — and sets
`"truncated": true`; `get` drops the record body and returns
`{ "found": true, "truncated": true, "note": "record exceeds --max-debug-response-bytes; set --trace-dir and read the trace file directly" }`.

Two irreducible floors the cap cannot beat (and shouldn't try to): (1) a valid
JSON-RPC reply must echo `id` verbatim, so if `byte_size(id)` alone approaches
the cap the response is dominated by the caller's own bytes — the server only
guarantees to minimize *its* contribution (`max_frame_bytes` bounds the incoming
`id`); (2) `op=get` on a trace file larger than the cap never reads the file —
it returns `{ "found": true, "source": "trace_file", "truncated": true, "note":
"trace file <name> exceeds --max-debug-response-bytes; read it directly under
--trace-dir" }` (a single `File.stat` decides this; the file is not loaded).

## 7. Where it hooks in (implementation sketch)

1. `PtcRunnerMcp.DebugConfig` — new, mirrors `AgenticConfig`.
2. `PtcRunnerMcp.Application` — parse `--debug-tool` / `--debug-ring-size` /
   `--max-debug-response-bytes` (+ env vars), `apply_debug_config/1`; when
   enabled, add `DebugBuffer` to the child list (after `Credentials`, anywhere
   among the stdio children — no ordering constraints).
3. `PtcRunnerMcp.DebugBuffer` — new GenServer + ETS ring; `record/1` (cast),
   `stats/1`, `recent/1`, `get/1`.
4. **Recognized-tool dispatch wrapper** (in `PtcRunnerMcp.JsonRpc`, or in the
   `Stdio` worker around it — wherever the concurrency gate also lives): for a
   `tools/call` whose name is `ptc_lisp_execute` or `ptc_task`, once the outcome
   envelope exists — whether from an arg-validation failure, a gate `busy`
   rejection, or `traced_tools_call/3`'s execution — and if `DebugConfig.enabled?()`,
   build the redacted call record (reusing `TracePayload.redact_program/2`, the
   `TracePayload` context summariser, and `Redactor.scrub/1`) and call
   `DebugBuffer.record/1`. The cast is wrapped so any failure is swallowed and
   `warn`-logged; it never affects the response.
5. `PtcRunnerMcp.DebugTool` — new dedicated module (§ 12 Q2, resolved; mirrors how
   `ptc_task` lives in `PtcRunnerMcp.Agentic`): `ptc_debug` arg validation +
   `call/1` dispatching `op` to `DebugBuffer`, formatting the `structuredContent`,
   enforcing `--max-debug-response-bytes`.
6. `PtcRunnerMcp.JsonRpc` dispatch — `tools/call name=ptc_debug` is special-cased
   **before the unknown-tool branch**: handled **synchronously, with no
   concurrency permit, and not through the async `Tools.call/1` path**, gated on
   `DebugConfig.enabled?()` (else `unknown_tool`, mirroring the `ptc_task` gate on
   `Tools.agentic_advertised?()`). `ptc_debug` is also excluded from the recorder
   in step 4.

No changes to `:ptc_runner`. No new telemetry events (the recorder reads the
envelope, not telemetry). The existing `TraceHandler`/`TraceFile` paths are
untouched.

## 8. Security & abuse considerations

`ptc_debug` is a diagnostics surface; treat it as attack surface. Mitigations
baked into this spec:

- **Off by default**, behind an explicit `--debug-tool` flag, advertised only
  when enabled. Operators opt in knowingly.
- **Redaction reuse.** Same `--trace-payloads` policy + `Redactor.scrub/1` as
  trace files; default `summary` never emits raw programs/contexts/results.
  `redaction_applied: true` and the active `payload_policy` are echoed so the
  client (and a human reading the transcript) can't be misled.
- **Residual leakage is still possible** even after redaction — error messages
  (always captured), upstream tool *names* and `upstream_calls` reasons,
  upstream server names, agentic planner outcomes, program SHA-256/preview at
  `summary`. Document this: do not enable `ptc_debug` on a server that handles
  sensitive prompts/data unless you also set `--trace-payloads none`.
- **Cross-client mixing.** A single server process serving multiple MCP clients
  pools all of their call records in one ring. The `debug_source: "ring_buffer"`
  + `window` fields make this visible; the real mitigation is "one server
  process per trust boundary" — call this out in docs. (v1 does not partition
  the ring by client; per-session partitioning is a future option.)
- **Recon surface.** Even with redaction, `stats` reveals which tools exist,
  failure patterns, upstream names, and model behavior. That's the point — but
  it's why it's off by default and operator-gated.
- **DoS.** No path input, no filename input; requests are addressed by
  `request_id` (or its hash). `recent` `limit` ≤ 200, `since_seconds` ≤ 24h,
  response capped at `--max-debug-response-bytes`. `stats`/`recent` are
  O(ring_size) over in-memory data and never touch disk; `op=get`'s only disk
  access is one bounded directory glob (over a `--trace-max-files`-capped
  directory) plus a single file read, and only when `--trace-dir` is set.
- **No self-amplification.** `ptc_debug` calls are excluded from the ring, so a
  client spamming `ptc_debug` can't crowd out real records or recurse.
- **`record/1` can't break a call.** It's a swallowed cast; a broken/overloaded
  `DebugBuffer` degrades to "no diagnostics", never to "tool call failed".

## 9. Documentation deltas (ship with the feature)

- `mcp_server/README.md` — new "Diagnostics" subsection: the `--debug-tool` /
  `--debug-ring-size` flags, the three `ptc_debug` ops with example
  `structuredContent`, the redaction/`--trace-payloads` interaction, the
  off-by-default + single-trust-boundary guidance, and a cross-link to
  `ptc_viewer` (the human-facing trace UI) and to `--trace-dir` for full
  on-disk traces.
- `mcp_server/CHANGELOG.md` — entry under the next version.
- `Plans/ptc-runner-mcp-server.md` — add a short § (e.g. § 8.5 "Debug tool
  (opt-in)") pointing here, and list `--debug-tool` / `--debug-ring-size` in
  the `Application` flag list (§ 5.2 / § 6).
- Mention in `mcp_server/README.md` (advanced/manual section) that with
  `--trace-dir` set you can alternatively point a filesystem MCP server at that
  directory and read the raw per-call JSONL — the zero-code escape hatch.

## 10. Testing

- **Integration over unit** (per repo testing guidelines):
  - Server booted with `--debug-tool`: drive a few `ptc_lisp_execute` calls
    (mix of `ok` / timeout / runtime error), then `tools/call ptc_debug op=stats`
    and assert counts, `error_rate`, `by_reason`, `window`, `debug_source`,
    `ring_size`, `ring_count`.
  - Validation-error and `busy` rejections **are** recorded: send a malformed
    `signature` (→ `args_error`) and saturate `--max-concurrent-calls` to force a
    `busy` envelope; assert both appear in `stats.errors.by_reason` and in
    `recent`. `ptc_debug`'s own calls do **not** appear anywhere in `stats`.
  - `op=recent` returns the calls newest-first; `errors_only=true` filters;
    `limit` caps; `since_seconds` filters.
  - `op=get` with a known `request_id` returns the redacted record:
    `source=ring_buffer` without `--trace-dir`; with `--trace-dir` the lookup is a
    single `*-<hash8>-*.jsonl` glob and returns `source=trace_file`; a glob miss
    or collision falls back to `ring_buffer`; `found=false` for an unknown id.
  - Ring eviction: with `--debug-ring-size 10`, the 11th call evicts the 1st;
    `ring_count` never exceeds the size; `--debug-ring-size` clamping.
  - Server booted **without** `--debug-tool`: `ptc_debug` is absent from
    `tools/list` and `tools/call ptc_debug` returns `unknown_tool`; verify no
    `DebugBuffer` process is started.
  - Redaction: at `--trace-payloads none` the `program` field in `recent`/`get`
    is byte-counts only and contains no source; a planted fake credential in a
    `context` value does not appear in any `ptc_debug` output.
  - Aggregator mode: `upstream_calls` aggregation in `stats` matches the
    `upstream_calls` decorations on the underlying envelopes — `total`/`ok` plus
    the canonical `by_reason` buckets (`timeout`, `cap_exhausted`,
    `upstream_unavailable`, `response_too_large`, `upstream_error`) and `by_server`.
  - Agentic mode (`--agentic` + aggregator): `agentic` block in `stats`
    (`tasks`, `planner_calls`, `planner_rejects`, `retries`); `ptc_debug` itself
    is not counted in `by_tool`.
  - `record/1` fault isolation: kill/overload `DebugBuffer`, confirm a
    concurrent `tools/call` still succeeds and returns a normal envelope.
- **No low-value unit tests** for the pure stats math beyond what the
  integration cases above already exercise; if a percentile helper is non-trivial
  enough to warrant a focused test, one is fine.

## 11. Non-goals / out of scope (v1)

- MCP `resources` capability (`trace://recent`, `trace://request/{id}`, raw file
  resources) — reasonable later, not now.
- Persisting the ring across restarts; SQLite/file-backed history.
- Per-client / per-session partitioning of the ring.
- Streaming or subscription (`notifications/...`) of debug events.
- Exposing stderr operational logs (`§ 6.5`) through MCP — explicitly out;
  `ptc_debug` only surfaces the server's own structured call records.
- A `--debug-payloads` knob separate from `--trace-payloads` (§ 12 Q1, resolved).
- Trace-dir directory scanning in `stats`/`recent` (§ 12 Q3).
- Time-series / rate-over-time output; v1 `stats` is a single window snapshot.

## 12. Open questions

- **Q1 — resolved (v1).** Reuse `--trace-payloads`; no separate `--debug-payloads`
  knob. Revisit only if someone wants on-disk `full` traces alongside a stricter
  live debug surface.
- **Q2 — resolved (v1).** Dedicated `PtcRunnerMcp.DebugTool` module (mirrors how
  `ptc_task` lives in `PtcRunnerMcp.Agentic`), not an extension of
  `PtcRunnerMcp.Tools`.
- **Q3 — open.** Should `stats` optionally (`include_trace_dir: true`, hard-capped
  file count) widen its window using on-disk trace files when `--trace-dir` is
  set? Deferred unless requested.
- **Q4 — resolved (v1).** Dedicated cap: `--max-debug-response-bytes` /
  `PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES`, default 64 KiB; not coupled to
  `--max-upstream-response-bytes`.
- **Q5 — open.** `recent`/`get` expose the **full `request_id`** vs only the
  8-hex hash. Lean: full id (the client needs it to call `get`, and it's the
  client's own correlation id) — but if `request_id`s can ever carry
  operator-meaningful/sensitive content, switch to hash8 everywhere (and accept
  hash8 in `op=get`). Decide before Phase 1.

## 13. Phasing

- **Phase 0 — config + buffer + recording.** `DebugConfig` (incl.
  `--max-debug-response-bytes`), `DebugBuffer` (GenServer + ETS ring), wiring in
  `Application`, and the `record/1` hook at the recognized-tool dispatch boundary
  (wrapping validation, the concurrency gate, and execution — see § 5.1 / § 7).
  No tool surface yet; tested via direct `DebugBuffer.stats/recent/get` calls and
  by asserting validation-error / `busy` records land in the ring.
- **Phase 1 — the tool.** `ptc_debug` `inputSchema`/`outputSchema`, dispatch +
  gate in `JsonRpc`, `Tools.list/0` advertisement, size cap, redaction wiring;
  integration tests for all three ops + the disabled-server case.
- **Phase 2 — enrichment + docs.** `get` trace-file lookup when `--trace-dir`
  set; README/CHANGELOG/`ptc-runner-mcp-server.md` updates; the manual
  filesystem-MCP escape-hatch note.

(Phases 0–2 are small and could land in one PR; split if review prefers.)
