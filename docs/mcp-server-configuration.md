# MCP Server Configuration Reference

Canonical reference for every flag, environment variable, response profile, catalog mode, tracing setting, and lifecycle command exposed by `ptc_runner_mcp`. For installation and client wiring see [`mcp-server-cli.md`](mcp-server-cli.md); for the conceptual overview (when to use the server, security model, architecture) see [`mcp-server.md`](mcp-server.md). Aggregator concepts live in [`aggregator-mode.md`](aggregator-mode.md), agentic mode in [`agentic-mode.md`](agentic-mode.md), and `lisp_debug` in [`mcp-debug.md`](mcp-debug.md).

## Boot-time configuration model

All configuration is read once at boot, either from a CLI flag or the equivalent environment variable. CLI flags win when both are set. Aggregator-mode defaults only apply when no explicit value is given. To pass flags through Claude Desktop / Cline / Cursor, append them to the `args` array, for example:

```json
"args": ["start", "--max-frame-bytes", "8388608"]
```

## Core flags

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
| `--agentic` | `PTC_RUNNER_MCP_AGENTIC` | `false` | Expose the experimental `lisp_task` tool when aggregator mode is active. |
| `--agentic-model` | `PTC_RUNNER_MCP_AGENTIC_MODEL` | `gemini-flash-lite` | Planner model alias or provider-qualified model id. |
| `--agentic-task-timeout-ms` | `PTC_RUNNER_MCP_AGENTIC_TASK_TIMEOUT_MS` | `45000` | Wall-clock cap for one `lisp_task` request. |
| `--agentic-planner-timeout-ms` | `PTC_RUNNER_MCP_AGENTIC_PLANNER_TIMEOUT_MS` | `15000` | Per-planner-call timeout. |
| `--agentic-max-output-tokens` | `PTC_RUNNER_MCP_AGENTIC_MAX_OUTPUT_TOKENS` | `1200` | Planner output token cap. |
| `--agentic-max-result-bytes` | `PTC_RUNNER_MCP_AGENTIC_MAX_RESULT_BYTES` | `4096` | Maximum rendered answer bytes in the `lisp_task` response. |
| `--agentic-include-program` | `PTC_RUNNER_MCP_AGENTIC_INCLUDE_PROGRAM` | `true` | Include the generated PTC-Lisp program in `lisp_task` responses. |
| `--agentic-trace-prompts` | `PTC_RUNNER_MCP_AGENTIC_TRACE_PROMPTS` | `false` | Include agentic prompt snapshots in traces. Use only for local debugging. |
| `--agentic-max-turns` | `PTC_RUNNER_MCP_AGENTIC_MAX_TURNS` | `1` | Maximum SubAgent planner turns per `lisp_task`. |
| `--agentic-retry-turns` | `PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS` | `0` | Additional retry turns after parser/runtime/validation feedback. |
| `--agentic-allow-writes` | `PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES` | `false` | Permit `lisp_task` in write-capable or unknown-effect aggregator configurations. |
| `--agentic-subagent-config` | `PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG` | unset | JSON config file for `max_turns`, `retry_turns`, and prompt prefix/suffix. |
| `--agentic-capability-summary-max-bytes` | `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY_MAX_BYTES` | `800` | Byte cap for the auto-generated `lisp_task` capability summary. |
| `--agentic-capability-summary` | `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY` | unset | Path to an operator-supplied capability summary for `lisp_task`. |
| `--sessions` | `PTC_RUNNER_MCP_SESSIONS` | `false` | Expose opt-in stateful PTC-Lisp session tools. |
| `--max-sessions` | `PTC_RUNNER_MCP_MAX_SESSIONS` | `64` | Maximum live sessions per MCP server process. |
| `--max-sessions-per-owner` | `PTC_RUNNER_MCP_MAX_SESSIONS_PER_OWNER` | `16` | Maximum live sessions per owner. |
| `--session-ttl-ms` | `PTC_RUNNER_MCP_SESSION_TTL_MS` | `1800000` (30 min) | Maximum lifetime for a session. |
| `--session-idle-timeout-ms` | `PTC_RUNNER_MCP_SESSION_IDLE_TIMEOUT_MS` | `900000` (15 min) | Close a session after this much idle time. |
| `--max-session-memory-bytes` | `PTC_RUNNER_MCP_MAX_SESSION_MEMORY_BYTES` | `1048576` (1 MiB) | Persisted Lisp memory cap per session. |
| `--max-session-binding-bytes` | `PTC_RUNNER_MCP_MAX_SESSION_BINDING_BYTES` | `262144` (256 KiB) | Per-binding persisted memory cap. |
| `--max-session-bindings` | `PTC_RUNNER_MCP_MAX_SESSION_BINDINGS` | `200` | Maximum persisted bindings per session. |
| `--max-session-history-entry-bytes` | `PTC_RUNNER_MCP_MAX_SESSION_HISTORY_ENTRY_BYTES` | `65536` (64 KiB) | Per-result cap for `*1` / `*2` / `*3`; oversized values become preview markers. |
| `--max-session-print-entries` | `PTC_RUNNER_MCP_MAX_SESSION_PRINT_ENTRIES` | `50` | Maximum persisted `println` entries. |
| `--max-session-print-bytes` | `PTC_RUNNER_MCP_MAX_SESSION_PRINT_BYTES` | `65536` (64 KiB) | Persisted print-history byte cap. |
| `--max-session-tool-call-entries` | `PTC_RUNNER_MCP_MAX_SESSION_TOOL_CALL_ENTRIES` | `50` | Maximum persisted tool-call history entries. |
| `--max-session-tool-call-bytes` | `PTC_RUNNER_MCP_MAX_SESSION_TOOL_CALL_BYTES` | `131072` (128 KiB) | Persisted tool-call history byte cap. |
| `--max-session-upstream-call-entries` | `PTC_RUNNER_MCP_MAX_SESSION_UPSTREAM_CALL_ENTRIES` | `50` | Maximum persisted upstream-call history entries. |
| `--max-session-upstream-call-bytes` | `PTC_RUNNER_MCP_MAX_SESSION_UPSTREAM_CALL_BYTES` | `131072` (128 KiB) | Persisted upstream-call history byte cap. |
| `--response-profile` | `PTC_RUNNER_MCP_RESPONSE_PROFILE` | `slim` (or `debug` when `--debug-tool` is set) | `lisp_eval` / `lisp_session_eval` response shape: `slim` \| `structured` \| `debug`. See [Response profiles](#response-profiles). |
| `--debug-tool` | `PTC_RUNNER_MCP_DEBUG_TOOL` | `false` | Expose the opt-in read-only `lisp_debug` diagnostics tool (see [`mcp-debug.md`](mcp-debug.md)). Also flips the response profile to `debug` unless `--response-profile` is set explicitly. |
| `--debug-ring-size` | `PTC_RUNNER_MCP_DEBUG_RING_SIZE` | `500` | In-memory ring-buffer capacity for `lisp_debug` (clamped to `[10, 5000]`). |
| `--max-debug-response-bytes` | `PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES` | `65536` (64 KiB) | Hard cap on a single `lisp_debug` response (raised to a 4 KiB floor if set lower); oversized responses are truncated and flagged. |

## Streamable HTTP flags

HTTP mode is opt-in. Without `--http`, the release starts exactly as a
stdio MCP server. With `--http`, the process starts a Streamable HTTP
listener and does not attach stdio. See
[`mcp-server-http-deployment.md`](mcp-server-http-deployment.md) for
the deployment runbook.

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--http` | `PTC_RUNNER_MCP_HTTP` | `false` | Enable the HTTP listener. |
| `--http-host` | `PTC_RUNNER_MCP_HTTP_HOST` | `127.0.0.1` | Bind IP address or `localhost`. Non-loopback binds require auth unless explicitly unsafe. |
| `--http-port` | `PTC_RUNNER_MCP_HTTP_PORT` | `7332` | Bind port. |
| `--http-path` | `PTC_RUNNER_MCP_HTTP_PATH` | `/mcp` | Streamable HTTP MCP endpoint. Must differ from `/health`, `/ready`, and `--http-metrics-path`. |
| `--http-auth-token` | `PTC_RUNNER_MCP_HTTP_AUTH_TOKEN` | unset | Static bearer token. Must be at least 32 characters; generate it from a CSPRNG. |
| `--http-disable-auth` | `PTC_RUNNER_MCP_HTTP_DISABLE_AUTH` | `false` | Disable bearer auth. Permitted on loopback with a warning; non-loopback also requires `--http-allow-unsafe-network`. |
| `--http-allowed-origin` | `PTC_RUNNER_MCP_HTTP_ALLOWED_ORIGIN` | unset | Browser `Origin` allow-list. May be repeated or comma-separated. This is a DNS-rebinding check, not full CORS support. |
| `--http-request-timeout-ms` | `PTC_RUNNER_MCP_HTTP_REQUEST_TIMEOUT_MS` | `15000` | HTTP request read timeout. |
| `--http-shutdown-grace-ms` | `PTC_RUNNER_MCP_HTTP_SHUTDOWN_GRACE_MS` | `10000` | Application-stop drain window before in-flight workers are cancelled. |
| `--http-max-body-bytes` | `PTC_RUNNER_MCP_HTTP_MAX_BODY_BYTES` | `--max-frame-bytes` | HTTP request body cap. |
| `--http-session-ttl-ms` | `PTC_RUNNER_MCP_HTTP_SESSION_TTL_MS` | `3600000` | Absolute HTTP protocol-session lifetime. |
| `--http-session-idle-timeout-ms` | `PTC_RUNNER_MCP_HTTP_SESSION_IDLE_TIMEOUT_MS` | `900000` | Idle timeout for HTTP protocol sessions. |
| `--http-max-sessions` | `PTC_RUNNER_MCP_HTTP_MAX_SESSIONS` | `256` | Global HTTP protocol-session cap. |
| `--http-max-sessions-per-owner` | `PTC_RUNNER_MCP_HTTP_MAX_SESSIONS_PER_OWNER` | `32` | Per-owner HTTP protocol-session cap. In single-token v1 every client shares one owner. |
| `--http-max-in-flight-per-session` | `PTC_RUNNER_MCP_HTTP_MAX_IN_FLIGHT_PER_SESSION` | `4` | Non-queueing cap for executing requests in one HTTP protocol session. |
| `--http-allow-unsafe-network` | `PTC_RUNNER_MCP_HTTP_ALLOW_UNSAFE_NETWORK` | `false` | Allows unauthenticated non-loopback bind only when paired with `--http-disable-auth`. |
| `--http-metrics` | `PTC_RUNNER_MCP_HTTP_METRICS` | `false` | Reserved for the Prometheus endpoint follow-up; core telemetry is emitted regardless. |
| `--http-metrics-path` | `PTC_RUNNER_MCP_HTTP_METRICS_PATH` | `/metrics` | Reserved metrics path; must not collide with HTTP control paths. |
| `--http-instance-label` | `PTC_RUNNER_MCP_HTTP_INSTANCE_LABEL` | hostname | Stable instance label stamped into HTTP logs, telemetry, and trace metadata. |

HTTP emits sanitized telemetry under `[:ptc_lisp, :http, ...]`
and logs request stop lines to stderr. Raw bearer tokens and raw
`MCP-Session-Id` values are not logged.

When the HTTP listener is bound to loopback, `/mcp` also requires a
loopback `Host`/authority value. This lets non-browser clients omit
`Origin` while still rejecting DNS-rebinding requests that arrive with a
public attacker-controlled host. POST requests with a present
`Content-Type` must use `application/json` or a `+json` media type.

## Response profiles

`lisp_eval` and `lisp_session_eval` render their eval results according to a boot-time **response profile** (`--response-profile`). The default is **`slim`**: optimized for the model consuming the tool result, not for an operator reading a trace. Session utility tools such as `lisp_session_start`, `lisp_session_inspect`, and `lisp_session_forget` keep structured responses in all profiles.

| Profile | `content[0].text` | `structuredContent` | `outputSchema` advertised | Observability fields |
|---|---|---|---|---|
| **`slim`** *(default)* | concise human-readable text / the value | — | no for eval tools | omitted everywhere — no `ptc_metrics`, no `upstream_calls`, no empty `prints`/`feedback`, no default `truncated` |
| **`structured`** | concise text | compact `{status, result, …}` (session eval also keeps `session` and `memory.changed_keys`; errors add `reason`/`message`/`feedback` and compact upstream failure summaries when useful) | yes (compact) | `ptc_metrics` omitted; full `upstream_calls` omitted, so diagnostics stay out of the model-facing path |
| **`debug`** | the result, mirrored | full payload (also mirrored as text) | yes (full) | full `ptc_metrics`, full `upstream_calls` (all entries with timings/byte counts), and the rest of the verbose payload |

For `lisp_session_eval`, normal slim/structured responses expose only the next-step contract: result text, compact session metadata, and changed binding names. Binding values, full upstream-call ledgers, and `ptc_metrics` are retained for explicit diagnostics instead of being echoed in every eval response.

`--debug-tool` implies `--response-profile debug` unless a profile is set explicitly. If you combine `--debug-tool --response-profile slim`, the client-facing response stays slim while the `lisp_debug` recorder still gets the full pre-slim payload internally for both stateless and session evals.

### Client-facing output limits

MCP tool results are additionally shaped by profile-derived output limits before they are returned to the client. These limits are not separate CLI flags yet; they are intentionally tied to `--response-profile`.

| Profile | Print output | `validated` exact value | Final envelope guard |
|---|---|---|---|
| `slim` | max 20 entries / 8 KiB encoded | always omitted; `validated_preview`, `validated_bytes`, and `output_truncated` are used when validation was requested | 32 KiB; may fall back to text-only |
| `structured` | max 50 entries / 16 KiB encoded | kept only when JSON-encoded value is ≤ 32 KiB; otherwise omitted with preview/byte metadata | 96 KiB; preserves minimal `structuredContent` on fallback |
| `debug` | max 200 entries / 64 KiB encoded | kept only when JSON-encoded value is ≤ 128 KiB; otherwise omitted with preview/byte metadata | 512 KiB; preserves minimal `structuredContent` on fallback |

`validated` is exact-or-absent. The server does not put partial values under `validated`; when the exact value is omitted, clients should look for `validated_preview`, `validated_bytes`, `validated_preview_truncated`, `truncated`, and `output_truncated`. `feedback` is also capped by profile (`8 KiB` / `16 KiB` / `64 KiB`). The final envelope guard is a last resort: it drops heavy optional fields and, for `structured` / `debug`, keeps machine-readable `structuredContent` with at least `status`, `truncated`, and `output_truncated`.

**Why `slim` by default — wire cost.** Measured by the local payload bench (drives a real `@modelcontextprotocol/server-filesystem` upstream; bytes ÷ 4 ≈ tokens; deterministic frame-byte counting, *not* LLM authoring cost):

| Per `lisp_eval` call | `slim` | `structured` | `debug` | native MCP, direct |
|---|---|---|---|---|
| read one file, return it whole | ~67 t | ~123 t | ~873 t | ~105 t |
| return the first line of 3 files (1 program vs 3 round-trips) | ~36 t | ~60 t | ~924 t | ~284 t |
| return one matched line out of a file | ~29 t | ~46 t | ~790 t | ~105 t |

`slim` is approximately 13–28x smaller than `debug` per call — debug's mirrored payload + `ptc_metrics` + `upstream_calls` is a roughly *fixed* ~800–950-token tax regardless of result size, which is exactly why it's opt-in (`--debug-tool`). Versus calling the upstream MCP tool directly, `slim` wins whenever the program collapses several calls into one and/or filters the result down (here: ~8x on the 3-file case, 1 round-trip instead of 3; ~4x on the one-line grep), and is about break-even for a single verbatim pass-through. The one-time `tools/list` ("cold") cost is comparable to a native server's (~2.7 K vs ~3.1 K tokens here); `debug` adds ~1.2 K tokens of `outputSchema` there. These ratios are illustrative — actual savings scale with payload size and how much the program reduces it; see [`aggregator-mode.md`](aggregator-mode.md) for the honest framing of what the server can and cannot measure, and re-run the bench against your own fixtures.

## Catalog modes

The `--catalog-mode` flag (env: `PTC_RUNNER_MCP_CATALOG_MODE`) controls how upstream tools are exposed. Default is `auto`.

| Mode | Description |
|---|---|
| `inline` | A synthetic discovery snapshot inlined in `lisp_eval` / `lisp_session_eval` descriptions: server summaries, compact `dir` name/description lists, and one `doc` example. Best for small fleets. |
| `lazy` | Configured server names plus front-loaded discovery guidance; tools discovered at runtime via REPL discovery forms. Best for large fleets or cost-conscious setups. |
| `auto` | Inline when ≤ `--catalog-inline-max-tools` (40) and the synthetic discovery snapshot fits within `--catalog-inline-max-chars` (12000); lazy otherwise. Optional prose is capped/dropped before switching to lazy mode. |

In **lazy** (or auto-resolved-lazy) mode, programs discover tools via PTC-Lisp REPL discovery forms that run inside `lisp_eval` — no extra MCP tool calls:

| Form | Purpose |
|---|---|
| `(tool/servers)` | All servers with tool counts and load status |
| `(apropos "query" {:limit 8})` | Cross-server lexical search returning `server.tool - description` strings |
| `(dir "server" {:limit 50})` | Tool names and descriptions for one server |
| `(doc "server/tool")` | Detailed args/result description with required args and call example |
| `(meta "server/tool")` | Structured tool metadata and schemas |

Discovery forms have a separate budget from upstream calls: `--max-catalog-ops-per-program` (default 25) and `--max-catalog-result-bytes` (default 256 KiB).

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--catalog-mode` | `PTC_RUNNER_MCP_CATALOG_MODE` | `auto` | `auto` \| `inline` \| `lazy` |
| `--catalog-inline-max-chars` | `PTC_RUNNER_MCP_CATALOG_INLINE_MAX_CHARS` | `12000` | Auto→lazy threshold for the rendered synthetic discovery snapshot |
| `--catalog-inline-max-tools` | `PTC_RUNNER_MCP_CATALOG_INLINE_MAX_TOOLS` | `40` | Auto→lazy threshold (tool count) |
| `--max-catalog-ops-per-program` | `PTC_RUNNER_MCP_MAX_CATALOG_OPS_PER_PROGRAM` | `25` | Discovery call budget per program |
| `--max-catalog-result-bytes` | `PTC_RUNNER_MCP_MAX_CATALOG_RESULT_BYTES` | `262144` (256 KiB) | Per-discovery-result cap |

## Aggregator-mode flags

These come into effect when at least one upstream is configured. The first two override the v1 1 s / 10 MB defaults to be more realistic for programs that orchestrate real subprocess upstreams. See [`aggregator-mode.md`](aggregator-mode.md) for the conceptual reference (PTC-Lisp authoring against `tool/call`, catalog format, error model, example programs).

| Flag | Env var | Default (aggregator) | Meaning |
|---|---|---|---|
| `--upstreams-config` | `PTC_RUNNER_MCP_UPSTREAMS` | (XDG default) | Path to upstreams JSON. Aggregator mode is enabled iff at least one upstream is configured. |
| `--program-timeout-ms` | `PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS` | `10_000` (10 s) | Outer wall-clock cap on the PTC-Lisp program (replaces v1's 1 s). |
| `--program-memory-limit-bytes` | `PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES` | `100 * 1024 * 1024` (100 MB) | Sandbox heap cap (replaces v1's 10 MB). |
| `--upstream-call-timeout-ms` | `PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS` | `5_000` (5 s) | Per-upstream-call wall-clock cap. Exceeded → `{:ok false :reason :timeout :message ...}` + entry with reason `timeout`. |
| `--max-upstream-response-bytes` | `PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES` | `2 * 1024 * 1024` (2 MB) | Per-response size cap, enforced pre-decode. Exceeded → `{:ok false :reason :response_too_large :message ...}` + entry with reason `response_too_large`. |
| `--max-upstream-calls-per-program` | `PTC_RUNNER_MCP_MAX_UPSTREAM_CALLS_PER_PROGRAM` | `50` | Total `tool/call` budget per program. Exceeded → `{:ok false :reason :cap_exhausted :message ...}` + entry with reason `cap_exhausted`. Stops `pmap` over an unbounded list from runaway-firing. |
| `--aggregator-read-only` | `PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY` | `false` | Advertise aggregator mode as read-only/non-destructive for clients like Codex when upstreams enforce read-only behavior. |

CLI flag wins over env var; aggregator-mode defaults only apply when no explicit value is given.

### OpenAPI Upstreams

An upstream entry with `"transport": "openapi"` exposes a curated set
of read-only JSON `GET` operations through the same `tool/call` path as
MCP upstreams. Required fields:

- `base_url`: HTTPS origin used for all operation calls.
- exactly one of `schema_file` or `schema_url`: OpenAPI schema source.
- `include_operations`: non-empty list of OpenAPI `operationId` strings
  to expose.

Optional fields include `auth`, `static_headers`,
`operation_overrides`, `request_timeout_ms`, `connect_timeout_ms`,
`max_response_bytes`, and `schema_max_bytes`. `schema_file` is the
recommended production shape; `schema_url` is fetched during upstream
startup and can delay boot up to its request timeout if the schema host
hangs.

See [`docs/examples/observatory-openapi-upstreams.json`](examples/observatory-openapi-upstreams.json)
for a production-shaped Observatory config. The matching test fixture
schema lives at
[`mcp_server/test/fixtures/openapi/observatory.openapi.json`](../mcp_server/test/fixtures/openapi/observatory.openapi.json).

## Tracing

Setting `--trace-dir /tmp/ptc-traces` writes one JSONL file per `tools/call` invocation under that directory. Each file contains the lifecycle telemetry events (`lisp.execute.start`, `lisp.execute.success` / `lisp.execute.fail`, plus per-tool-call rows when relevant) emitted by `:ptc_runner`. Tracing is opt-in and OFF by default — there is zero overhead when `--trace-dir` is unset.

`--trace-payloads full` includes the verbatim `program`, `context`, and rendered `result` bytes; `summary` (the default when tracing is on) records sizes and SHA-256 digests only. Pick `summary` unless you are actively debugging a specific call.

For local evaluation of aggregator benefits, run with:

```bash
--trace-dir /tmp/ptc-traces --trace-payloads full
```

Then inspect the JSONL trace file to see the generated PTC-Lisp program, `program_bytes`, total call duration, and result size. In `debug` responses, or through `lisp_debug` records when enabled, `upstream_calls` records each upstream call's server, tool, status, reason on failure, and duration. To estimate token savings, compare:

- aggregator `tools/list` bytes vs the sum of native upstream `tools/list` bytes;
- aggregator final result bytes vs the sum of native upstream raw result bytes.

Use `--trace-payloads full` only for local debugging or measurement; it records source programs and payload values. Use `summary` or `none` for normal operation.

### Reading traces without writing code

With `--trace-dir` set you do not need a bespoke trace reader: point a generic **filesystem MCP server** (e.g. `@modelcontextprotocol/server-filesystem`) at the trace directory and let the client read the raw per-call JSONL. The zero-code escape hatch — fine for ad-hoc digging, but `lisp_debug` (see [`mcp-debug.md`](mcp-debug.md)) is the purpose-built interface, and `ptc_viewer` (`mix ptc.viewer` in the repo) is the human-facing web UI for the same trace files.

## Lifecycle commands

The release binary defaults `RELEASE_DISTRIBUTION=none` so MCP clients
can run multiple stdio subprocesses concurrently without Erlang
node-name collisions:

```bash
ptc_runner_mcp start      # foreground, stdio attached (what MCP clients use)
ptc_runner_mcp version    # print "ptc_runner_mcp <version>"
ptc_runner_mcp eval "..."  # run an expression in a one-shot VM
```

For remote IEx debugging, start the process with distribution enabled
and a unique node name, then attach with the same settings:

```bash
RELEASE_DISTRIBUTION=sname RELEASE_NODE=ptc_runner_mcp_debug_1 ptc_runner_mcp start
RELEASE_DISTRIBUTION=sname RELEASE_NODE=ptc_runner_mcp_debug_1 ptc_runner_mcp remote
```
