# Diagnostics: ptc_debug

Opt-in, read-only MCP tool for inspecting recent `tools/call` activity.

`ptc_debug` lets the client LLM ask "how is this server doing?" without filesystem access and without grepping JSONL traces. It is off by default; enable it with `--debug-tool` (or `PTC_RUNNER_MCP_DEBUG_TOOL=true`). When disabled there is no extra process, no ring buffer, and the tool does not appear in `tools/list`.

For the broader MCP server overview see [mcp-server.md](mcp-server.md). For the full configuration flag reference see [mcp-server-configuration.md](mcp-server-configuration.md). For the `ptc_runner_mcp` release itself see [`mcp_server/README.md`](../mcp_server/README.md).

## What gets recorded

`ptc_debug` records every recognized-tool `tools/call` — `ptc_lisp_execute`, `ptc_task`, and all `ptc_session_*` tools when sessions are enabled — into a bounded in-memory ring (`--debug-ring-size`, default 500, FIFO eviction). Successes, `args_error` validation failures, and `busy` concurrency-gate rejections are all captured. `ptc_debug`'s own calls and unknown-tool requests are not recorded.

The ring lives in process memory: it is lost on restart, and in a multi-client process it mixes records from all clients. Both facts are surfaced in every `stats` response (`debug_source`, `window`, `ring_count`).

## Operations

`op` is required. The three operations are:

| `op` | What it returns |
|---|---|
| `stats` | Aggregate health: per-tool call counts / success-error rates / latency percentiles, an error-reason histogram, upstream-call outcomes (`total` / `ok` / `by_reason` / `by_server`), agentic planner stats, a `payload_reduction` aggregate (totals, p50/p95/max/weighted ratio, top-N reducers, planner-token sub-block — see [aggregator-mode.md](aggregator-mode.md)), plus a self-description (`ring_size`, `ring_count`, `trace_dir_enabled`, `payload_policy`, time `window`). |
| `recent` | The last `limit` (≤ 200, default 20) call records, newest first. `errors_only: true` restricts to failures; `since_seconds` windows by age. |
| `get` | The full redacted record for one `request_id`. When `--trace-dir` is set, returns the on-disk JSONL trace (`source: "trace_file"`); otherwise the ring record (`source: "ring_buffer"`). |

## Example

```jsonc
// tools/call
{ "name": "ptc_debug", "arguments": { "op": "stats" } }

// → structuredContent (abridged)
{
  "op": "stats", "payload_policy": "summary", "redaction_applied": true,
  "debug_source": "ring_buffer", "ring_size": 500, "ring_count": 137,
  "trace_dir_enabled": false,
  "window": { "from": "…", "to": "…", "calls": 137 },
  "by_tool": { "ptc_lisp_execute": { "calls": 120, "ok": 110, "error": 10,
                                     "error_rate": 0.083,
                                     "duration_ms": { "p50": 12, "p95": 210, "max": 1400 } } },
  "errors": { "by_reason": { "timeout": 4, "runtime_error": 3, "args_error": 6, "busy": 1 } }
}
```

## Configuration flags

The full flag reference lives in [mcp-server-configuration.md](mcp-server-configuration.md). The flags directly relevant to `ptc_debug` are:

| Flag | Env var | Default | Purpose |
|---|---|---|---|
| `--debug-tool` | `PTC_RUNNER_MCP_DEBUG_TOOL` | `false` | Expose the `ptc_debug` tool. Also flips the response profile to `debug` unless `--response-profile` is set explicitly. |
| `--debug-ring-size` | `PTC_RUNNER_MCP_DEBUG_RING_SIZE` | `500` | In-memory ring-buffer capacity (clamped to `[10, 5000]`). |
| `--max-debug-response-bytes` | `PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES` | `65536` (64 KiB) | Hard cap on a single `ptc_debug` response (raised to a 4 KiB floor if set lower); oversized responses are truncated and flagged. |

## Interaction with response profiles

`--debug-tool` implies `--response-profile debug` unless a profile is set explicitly. Combine `--debug-tool --response-profile slim` to keep client-facing responses slim while the `ptc_debug` recorder still receives the full pre-slim payload internally. See the response-profile section of [mcp-server-configuration.md](mcp-server-configuration.md) for the full profile matrix.

## Redaction

`ptc_debug` reuses the trace redaction stack: the active `--trace-payloads` policy (`none` / `summary` / `full`, default `summary`) plus `Credentials.Redactor.scrub/1`. It never emits data at a level higher than `--trace-payloads` allows; every response echoes `payload_policy` and carries `redaction_applied: true`. At `none`, the `program` field is just a SHA-256 plus byte count and `context` is byte counts only.

Residual leakage is still possible even after redaction — error messages (always captured in full), upstream tool/server names, upstream-call reasons, agentic planner outcomes, and (at `summary`) program previews. Do not enable `ptc_debug` on a server that handles sensitive prompts or data unless you also set `--trace-payloads none`, and run one server process per trust boundary (v1 does not partition the ring per client).
