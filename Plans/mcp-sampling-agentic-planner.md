# MCP Sampling Planner Spec

| Field | Value |
|---|---|
| Status | Draft |
| Date | 2026-05-12 |
| Related | `Plans/agentic-mcp-aggregator.md`, `Plans/ptc-runner-mcp-server.md`, `Plans/ptc-runner-mcp-aggregator.md`, `Plans/ptc-lisp-tool-call-transport.md` |

## Summary

Add an opt-in MCP sampling planner backend for `ptc_runner_mcp`
agentic mode. When enabled, `lisp_task` uses the MCP client's language
model through `sampling/createMessage` to generate the same PTC-Lisp
program that the current server-side planner generates today. The
generated program is still validated, executed, traced, and rendered
through the existing PTC-Lisp sandbox and aggregator path.

This does not replace `lisp_eval`, does not expose upstream MCP
tools directly through sampling, and does not make ordinary
`lisp_eval` calls agentic. It is a planner-provider option for
the existing `lisp_task` tool.

## Motivation

The current `lisp_task` implementation depends on a server-side LLM
adapter and provider credentials. That is useful for reproducible
operator-controlled deployments, but it is awkward for editor MCP
clients that already have a user-approved model, subscription, and
model picker.

MCP sampling lets an MCP server ask the client to perform an LLM
generation during an originating request such as `tools/call`. For
VS Code/Copilot users, this means:

- no OpenRouter/OpenAI/Anthropic key is required in `ptc_runner_mcp`;
- the user controls which models the server may access;
- the first-use approval and sampling-request inspection happen in
  the MCP client UI;
- the server can keep all deterministic execution, tracing, and
  upstream-call governance exactly where it already lives.

This is especially attractive for `lisp_task`, whose planner output is
small PTC-Lisp source. The expensive/large-data work remains in the
sandboxed program and upstream aggregator calls rather than in hidden
client context.

## Background

Relevant MCP sampling constraints:

- Sampling requests are server-to-client JSON-RPC requests named
  `sampling/createMessage`.
- A server must send sampling requests only while processing an
  originating client request, for example a `tools/call`.
- `maxTokens` is required.
- `modelPreferences`, `temperature`, `stopSequences`, `metadata`, and
  `systemPrompt` are advisory to varying degrees. The client may
  modify or ignore some of them.
- Clients advertise support through client capabilities. Tool-enabled
  sampling requires the client to advertise `sampling.tools`.
- Context inclusion values other than `none` are soft-deprecated in
  the draft spec and should be avoided unless explicitly needed.

Current repo constraints:

- `PtcRunnerMcp.Stdio` currently handles client requests and writes
  server replies. It does not maintain server-originated request IDs
  or route inbound JSON-RPC responses to waiting workers.
- `PtcRunnerMcp.JsonRpc` currently treats inbound frames as requests
  or notifications; a JSON-RPC response frame with only `id` and
  `result` / `error` is not part of the dispatch model.
- `PtcRunnerMcp.Lifecycle.initialize_reply/1` negotiates protocol
  version and advertises server capabilities, but does not retain
  client capabilities.
- `PtcRunnerMcp.Agentic.Planner` already provides a narrow planner
  contract: `call(model, prompt, opts)`.
- Tests already use alternate planner modules via
  `Application.put_env(:ptc_runner_mcp, :agentic_planner, StubPlanner)`.

## Goals

- Add client-LLM planning for `lisp_task` without requiring server-side
  provider credentials.
- Preserve the existing `lisp_task` input/output contract as much as
  possible.
- Keep sampling isolated behind a planner backend and a transport
  request service.
- Detect and fail cleanly when the MCP client does not advertise
  sampling support.
- Keep `lisp_eval` no-LLM and deterministic.
- Preserve cancellation, shutdown, concurrency limits, telemetry, and
  `lisp_debug` behavior.
- Keep v1 sampling text-only and tool-free. Upstream MCP tool
  orchestration remains inside generated PTC-Lisp through
  `(tool/mcp-call ...)`.

## Non-Goals

- No tool-enabled sampling in v1.
- No `includeContext: "thisServer"` or `"allServers"` in v1.
- No server-initiated sampling outside a `tools/call`.
- No sampling for raw `lisp_eval`.
- No automatic fallback from sampling planner to server-side planner
  unless explicitly configured later.
- No adoption of modern stateless MCP lifecycle in this change. The
  current initialize-based stdio server remains the baseline.
- No hard dependency on VS Code-specific behavior. VS Code is the
  primary target client, but the implementation must speak standard
  MCP sampling.

## Configuration

Extend agentic configuration with a planner backend selector.

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `--agentic-planner` | `PTC_RUNNER_MCP_AGENTIC_PLANNER` | `server` | Planner backend. Accepted values: `server`, `sampling`. |
| `--agentic-sampling-model-hint` | `PTC_RUNNER_MCP_AGENTIC_SAMPLING_MODEL_HINT` | value of `--agentic-model` | Optional model hint sent in `modelPreferences.hints`. |

Existing flags keep their meaning:

- `--agentic-planner-timeout-ms` is the timeout for the
  `sampling/createMessage` response.
- `--agentic-max-output-tokens` becomes the sampling `maxTokens`.
- `--agentic-model` remains the server-side planner model when
  `--agentic-planner=server`; in sampling mode it is only used as the
  default model hint.

Invalid planner backend values are boot-time config errors.

Do not add CLI/env flags for sampling cost/speed/intelligence
priorities in v1. Most clients treat these values as advisory and may
ignore them. Hardcode the request-builder defaults as internal
constants:

- `costPriority: 0.3`
- `speedPriority: 0.7`
- `intelligencePriority: 0.5`

Add public tuning flags later only if real users need them.

## Client Capability Tracking

The server must record relevant client capabilities from
`initialize.params.capabilities`.

Capability state is connection/session state. Store it on
`PtcRunnerMcp.Stdio.State`, not in a global `:persistent_term`. This
keeps the semantics correct for the transport and prevents a previous
client's capability advertisement from leaking into a later client.

Add a small state holder, for example `PtcRunnerMcp.ClientCapabilities`,
as an embedded struct or pure helper over `Stdio.State`, with:

- `sampling_supported?(caps_or_state)`
- `sampling_tools_supported?(caps_or_state)`
- `sampling_context_supported?(caps_or_state)`
- `from_initialize_params(params)`
- test helpers that can construct/reset the embedded state without
  touching process-global storage

For initialize-based clients, look for:

```json
{
  "capabilities": {
    "sampling": {}
  }
}
```

Tool-enabled sampling is recognized as:

```json
{
  "capabilities": {
    "sampling": {
      "tools": {}
    }
  }
}
```

V1 requires only basic `sampling`. If `--agentic-planner=sampling` and
the current client does not advertise sampling support, `lisp_task`
returns a tool error:

```json
{
  "status": "error",
  "reason": "sampling_unavailable",
  "message": "MCP client did not advertise sampling support"
}
```

This is a tool result error, not a JSON-RPC transport error and not a
server crash.

## Transport Design

### New bidirectional request service

Add a module such as `PtcRunnerMcp.ClientRequests` or
`PtcRunnerMcp.Sampling.Client`.

Responsibilities:

- allocate server-originated JSON-RPC request IDs;
- gate on client sampling capability before registration;
- register a waiting process/ref before the request is written;
- ask `Stdio` to write the outbound request frame;
- receive the matching inbound response frame in the caller's process
  mailbox;
- return `{:ok, result}` or `{:error, error}` to the caller;
- enforce timeout;
- clean up pending entries on timeout, cancellation, shutdown, and
  worker crash.

Suggested API:

```elixir
@spec request(GenServer.server(), String.t(), map(), keyword()) ::
        {:ok, map()}
        | {:error,
           :sampling_unavailable
           | :timeout
           | :cancelled
           | :shutdown
           | {:jsonrpc_error, map()}
           | {:malformed_response, String.t()}}
def request(stdio_server, method, params, opts)
```

`stdio_server` is the current `PtcRunnerMcp.Stdio` session process or
registered name. It is required because client capabilities and
pending server-originated requests live in `Stdio.State`. Direct
in-process callers that do not have an MCP stdio session target must
return `{:error, :sampling_unavailable}` without trying to sample.

`request/4` must not make `Stdio` wait for the final client response.
Any `GenServer.call` into `Stdio` is limited to synchronous
registration plus writing the outbound frame, and must return
immediately after the frame is written. The caller then waits in its
own process mailbox for a message from `Stdio`, for example
`{:client_response, request_id, response}`. If `Stdio` waits for the
client response inside the call handler, the server can deadlock:
`Stdio` cannot read the very response frame it is waiting for.

The capability gate lives inside `ClientRequests.request/4`. If the
current `Stdio.State` says the client did not advertise basic
sampling, the registration call returns `{:error,
:sampling_unavailable}` immediately, without writing an outbound
frame or creating a pending entry. `Agentic.call_planner/4` maps this
to the public `sampling_unavailable` `lisp_task` reason. No separate
"read capabilities first" path is required in the sampling planner.

For v1, only `method == "sampling/createMessage"` is needed. Keep the
module generic enough to avoid baking sampling concerns into stdio
line handling.

### Session target threading

Thread the current stdio session target alongside the outer
`tools/call` request id:

1. `Stdio` receives a `tools/call` and passes `stdio_server: self()`
   into `JsonRpc.dispatch/2`.
2. `JsonRpc.async_tools_call/2` includes that target in the work
   closure options for `Tools.call_agentic_validated/2`.
3. `Tools.call_agentic_validated/2` forwards it to
   `Agentic.run_validated/2`.
4. `Agentic.call_planner/4` passes it into `SamplingPlanner.call/3`
   as `opts[:stdio_server]`.
5. `SamplingPlanner.call/3` calls
   `ClientRequests.request(stdio_server, "sampling/createMessage",
   params, opts)`.

If `opts[:stdio_server]` is missing or invalid in sampling mode,
`SamplingPlanner.call/3` returns `{:error, :sampling_unavailable,
message, meta}`. This preserves a useful behavior for direct
in-process tests and callers: sampling mode requires an MCP client
session.

### Stdio state changes

Extend `PtcRunnerMcp.Stdio.State` with:

- `pending_client_requests :: %{request_id => pending_entry}`
- `server_request_seq :: non_neg_integer`

Each pending entry should include:

- waiting pid;
- monitor ref for the waiting process or worker;
- originating client request id if known;
- method;
- started timestamp.

`Stdio` must monitor the waiting pid. The sampling planner currently
runs inside the existing `Task.async` created by the per-call worker.
That task may be killed by the outer `Task.yield/2` plus
`Task.shutdown(:brutal_kill)` timeout path. If the waiting task dies,
`Stdio` must automatically remove its pending sampling entry so the
later client response is treated as an unknown response and ignored.

There are intentionally two timeout layers:

- inner timeout: `ClientRequests.request/4`, shorter or equal to the
  remaining planner timeout, returning `{:error, :timeout}`;
- outer timeout: existing `Agentic.call_planner/4` task yield/shutdown
  around the planner call.

The inner timeout should normally fire first. The outer timeout is a
hard stop for stuck planner code and must not leak pending
server-originated requests.

### Writing server-originated requests

The `Stdio` GenServer is the only process that writes JSON-RPC frames
to stdout today. Preserve that invariant.

Workers must not write directly to the IO device. A worker calls the
request service, which sends a GenServer call/cast to `Stdio`; `Stdio`
registers the pending entry, writes the outbound frame, and returns
without waiting for the client's response:

```json
{
  "jsonrpc": "2.0",
  "id": "ptc-sampling-1",
  "method": "sampling/createMessage",
  "params": {}
}
```

### Reading client responses

Before passing decoded frames to `JsonRpc.dispatch/2`, `Stdio` must
inspect JSON-RPC response-like frames:

- map has `"jsonrpc" => "2.0"`;
- map has `"id"`;
- map has at least one of `"result"` or `"error"`;
- map does not have `"method"`.

A valid response has exactly one of `"result"` or `"error"`. If `id`
matches `pending_client_requests`, route the response to the waiting
process and do not call `JsonRpc.dispatch/2`.

If `id` does not match a pending server-originated request, log a
warning and ignore the frame. Do not reply to a response.

Malformed response frames with both `"result"` and `"error"` are
treated as errors for the pending request when the id matches. Route
`{:error, {:malformed_response, "response contains both result and error"}}`
to the waiting process, remove the pending entry, and log a warning.
Never treat such a frame as success.

### Cancellation and shutdown

If the original client sends `notifications/cancelled` for an
in-flight `lisp_task`, current behavior kills the worker. Pending
sampling requests owned by that worker must be removed and the waiting
process must receive `{:error, :cancelled}` or simply die with the
worker. No response is emitted for the original cancelled `tools/call`,
matching current cancellation behavior.

When `shutdown` enters drain:

- no new `tools/call` work starts;
- already in-flight sampling requests may finish until their worker
  deadline;
- `exit` grace behavior remains authoritative.

When EOF or `exit` kills workers, pending sampling entries for those
workers must be removed.

### Duplicate IDs

Server-originated request IDs must not collide with client request IDs
or each other. Use a string prefix, for example:

```text
ptc_sampling_<monotonic_integer>
```

Client request IDs may be strings or numbers. The prefix makes
accidental collision very unlikely, but still check both
`pending_client_requests` and ordinary `in_flight` before allocating.

Reserve the server-originated prefix for outbound server requests. If
an inbound client request uses an `id` string with that prefix while
any server-originated request is pending, reject it as an invalid
request (`-32600`) rather than starting work under an ambiguous ID.
Inbound responses with the reserved prefix are routed only through the
pending-response path described above.

## Sampling Planner

Add `PtcRunnerMcp.Agentic.SamplingPlanner` implementing the same shape
as `PtcRunnerMcp.Agentic.Planner.call/3`:

```elixir
@spec call(String.t(), String.t(), keyword()) ::
        {:ok, String.t(), map()}
        | {:error, :config | :planner | :sampling_unavailable, String.t(), map()}
```

Inputs:

- `model` is treated as a model hint, not a hard model.
- `prompt` is the sanitized rendered subagent prompt from
  `Agentic.call_planner/4`.
- `opts[:timeout_ms]` is the sampling timeout.
- `opts[:max_output_tokens]` is sent as `maxTokens`.
- `opts[:request_id]` is the originating outer `tools/call` request id.
  `Agentic.call_planner/4` must pass this through to
  `SamplingPlanner.call/3` so sampling telemetry and pending-request
  entries can be correlated with the parent MCP call.
- `opts[:stdio_server]` is the current `PtcRunnerMcp.Stdio` session
  target. It is required in sampling mode; when missing, return
  `{:error, :sampling_unavailable, ...}`.

`--agentic-model` defaults the sampling model hint when
`--agentic-sampling-model-hint` is not set. In sampling mode this is
advisory only; the MCP client chooses the actual model.

Sampling request params:

```json
{
  "messages": [
    {
      "role": "user",
      "content": {
        "type": "text",
        "text": "<rendered prompt>"
      }
    }
  ],
  "systemPrompt": "You generate only PTC-Lisp programs.",
  "includeContext": "none",
  "modelPreferences": {
    "hints": [{"name": "<model hint>"}],
    "costPriority": 0.3,
    "speedPriority": 0.7,
    "intelligencePriority": 0.5
  },
  "temperature": 0.1,
  "maxTokens": 1200
}
```

The system prompt should reuse
`PtcRunnerMcp.Agentic.Planner.system_message/0` so server-side and
sampling planners stay behaviorally aligned.

Response handling:

- Require `result.role == "assistant"`. Any other role returns a
  planner error with a message that includes the unexpected role.
- Accept `result.content` as either a single text content block or an
  array containing exactly one text block.
- If content contains text plus non-text blocks, return
  `{:error, :planner, "sampling returned unsupported content blocks", meta}`.
- If `stopReason == "toolUse"` or any `tool_use` block appears,
  return a planner error. Tool-enabled sampling is explicitly out of
  scope for v1.
- If `stopReason == "maxTokens"`, return a planner error before
  execution. A max-token stop likely means the generated PTC-Lisp is
  truncated; failing at the planner boundary is clearer than executing
  partial source and surfacing a parse/runtime error.
- Record `result.model` in planner metadata when present.
- Record `stopReason` in planner metadata when present.
- Token counts are usually unavailable from MCP sampling. Set
  `"tokens" => %{}` and rely on existing byte estimates in
  `ptc_metrics`.

Success metadata:

```elixir
%{
  "model" => result_model_or_hint,
  "duration_ms" => duration,
  "prompt_bytes" => prompt_bytes,
  "output_bytes" => byte_size(content),
  "completion_bytes" => byte_size(content),
  "tokens" => %{},
  "planner_backend" => "sampling",
  "stop_reason" => stop_reason
}
```

Errors map to existing agentic reasons where possible:

| Sampling failure | Planner return | Final `lisp_task` reason |
|---|---|---|
| client lacks sampling capability | `{:error, :sampling_unavailable, ...}` | `sampling_unavailable` |
| request timeout | `{:error, :planner, ...}` | `planner_timeout` |
| client JSON-RPC error | `{:error, :planner, ...}` | `planner_error` |
| unsupported content shape | `{:error, :planner, ...}` | `planner_error` |
| tool-use response | `{:error, :planner, ...}` | `planner_error` |

Add `:sampling_unavailable` to the planner error contract instead of
returning it as `:config`. `Agentic.call_planner/4` must map
`{:error, :sampling_unavailable, message, meta}` to
`{:error, :sampling_unavailable, message, meta}`, and
`map_step_reason/3` must preserve that reason as
`sampling_unavailable` rather than collapsing it into
`agentic_config_error`, `planner_error`, or `ptc_llm_error`. This is a
public `lisp_task` error reason because the operator may have
configured sampling correctly while the current client simply does
not support it.

## Agentic Integration

Change `PtcRunnerMcp.Agentic.call_planner/4` planner selection:

- `cfg.planner == :server` uses current
  `Application.get_env(:ptc_runner_mcp, :agentic_planner, Planner)`.
- `cfg.planner == :sampling` uses
  `Application.get_env(:ptc_runner_mcp, :agentic_sampling_planner, SamplingPlanner)`.

Keep the test injection seam for both planner types.

Do not change prompt assembly, SubAgent construction, continuation
guard, ledger behavior, renderer behavior, or upstream MCP call
execution.

`planner_payload/1` should include `"backend" => "sampling"` when the
sampling planner is used.

## Security and Privacy

- Sampling prompt content must pass through the existing
  `Planner.sanitize_prompt/1` redaction path before being sent to the
  client.
- Do not request `includeContext` beyond `"none"` in v1.
- Do not include raw upstream credentials, auth headers, or full
  upstream payloads in sampling metadata.
- Sampling request and response previews must obey existing trace
  payload policy. By default, do not write full prompts or full model
  outputs to traces.
- The client may show sampling prompts to the user. Treat every
  sampling prompt as user-visible.
- The server must cap prompt and completion bytes through existing
  task and output limits.

## Observability

Add telemetry span:

```elixir
[:ptc_runner_mcp, :sampling, :request]
```

Start metadata:

- `request_id` of the originating `tools/call`;
- `sampling_request_id`;
- `method`;
- `planner_backend: :sampling`;
- `model_hint`;
- `max_tokens`;
- `prompt_bytes`.

Stop metadata:

- `status: :ok | :error`;
- `duration_ms`;
- `model` when returned by client;
- `stop_reason` when returned by client;
- `output_bytes` on success;
- `reason` on error.

No raw prompt or raw completion text in telemetry metadata.

`lisp_debug` should continue recording only the outer `tools/call`
outcome. Do not add sampling prompt/response bodies to debug records.
It is acceptable to include counts and backend metadata inside the
existing planner block.

If sampling telemetry should appear in JSONL trace files, update
`PtcRunnerMcp.TraceHandler.events/0` to subscribe to
`[:ptc_runner_mcp, :sampling, :request]` in addition to the existing
agentic planner events. The trace handler must apply the same payload
redaction policy as telemetry: counts and metadata only by default,
no raw prompt or completion text.

## Output Schema Changes

Extend `lisp_task` error reasons with:

- `sampling_unavailable`

Optionally add:

- `sampling_error`

But prefer reusing `planner_error` for JSON-RPC errors and unsupported
sampling response shapes unless user-facing distinction proves useful.

Successful `planner` object may include:

```json
{
  "backend": "sampling",
  "model": "client-selected-model",
  "model_hint": "gemini-flash-lite",
  "stop_reason": "endTurn",
  "calls": 1
}
```

`ptc_metrics.server_side_llm.provider_reported` should remain `false`
unless a future MCP sampling result exposes real token usage.

## Phases

Delivery is split into two PRs:

- PR 1: phases 1-2, covering config/capabilities and bidirectional
  stdio request/response routing.
- PR 2: phases 3-4, covering the sampling planner, automated fake
  client smoke, and docs.

Phase 2 is the risky change because it touches `Stdio` cancellation,
EOF, shutdown, and exit grace-timer invariants. Give the Phase 2
commit its own independent Codex review round before building planner
behavior on top of it.

### Phase 1 - Capability and config plumbing

- Add `AgenticConfig.planner`.
- Parse CLI/env for `--agentic-planner`.
- Add `--agentic-sampling-model-hint`.
- Add internal sampling priority constants, but no public priority
  flags.
- Capture client capabilities from `initialize.params.capabilities`.
- Add tests for config precedence and capability detection.

DoD:

- Existing tests pass.
- Sampling planner can be selected in config but returns
  `sampling_unavailable` until the transport service exists.

### Phase 2 - Bidirectional stdio request/response routing

- Add pending server-originated request state to `Stdio`.
- Add request ID allocation.
- Add outbound request write path owned by `Stdio`.
- Add inbound response-frame routing before `JsonRpc.dispatch/2`.
- Add timeout and cleanup behavior.
- Add cancellation/worker-death cleanup.
- Thread `stdio_server` from `Stdio` through `JsonRpc`, `Tools`, and
  `Agentic` into sampling planner opts.

DoD:

- Unit tests prove a worker can send `sampling/createMessage`, receive
  a matching client response, and continue the outer `tools/call`.
- Unknown response IDs are ignored without reply.
- Timeout removes pending state.
- Cancellation removes pending state and emits no outer reply.
- A killed waiting pid removes its pending entry.
- `ClientRequests.request/4` returns `{:error, :sampling_unavailable}`
  without writing a frame when the current client did not advertise
  sampling.
- Direct in-process sampling calls with no `stdio_server` target return
  `sampling_unavailable`.

### Phase 3 - Sampling planner

- Implement `PtcRunnerMcp.Agentic.SamplingPlanner`.
- Build standards-compliant text-only sampling request params.
- Parse text-only sampling results.
- Reject tool-use and unsupported content blocks.
- Reject `stopReason: "maxTokens"` before executing generated source.
- Add telemetry span.
- Update `TraceHandler.events/0` when sampling events are intended to
  appear in JSONL traces.
- Wire planner backend selection.

DoD:

- `lisp_task` can use a fake sampling response to generate and execute
  a PTC-Lisp program.
- Planner metadata includes backend/model/bytes/duration.
- No raw prompt/completion appears in telemetry metadata.

### Phase 4 - End-to-end client smoke and docs

- Add a stdio harness test that simulates a sampling-capable MCP
  client.
- Add docs to `mcp_server/README.md` and
  `docs/guides/mcp-getting-started.md`.
- Add a troubleshooting note for clients that return
  `Method not found: sampling/createMessage` or omit sampling
  capability.
- Add a VS Code configuration note explaining model access and first
  sampling approval.

DoD:

- Full mcp server tests pass.
- Automated fake-client smoke passes: a test client sends
  `initialize` with `sampling: {}`, captures the outbound
  `sampling/createMessage` frame, sends a canned sampling response,
  and observes the original outer `tools/call` complete.
- Manual smoke instructions exist for VS Code/Copilot.
- Sampling mode remains opt-in and server-side planner remains
  available.

The real VS Code/Copilot smoke is documented-manual-only. Do not make
CI depend on a local editor install, user subscription, or interactive
model-access approval prompt.

### Phase 5 - Optional tool-enabled sampling spike

Only consider after text-only sampling ships.

Questions:

- Can tool-enabled sampling simplify `lisp_task`, or does it duplicate
  the PTC-Lisp aggregator?
- Can client support be detected reliably across VS Code, Copilot
  variants, and other MCP clients?
- How should tool-use transcripts map back to the existing ledger and
  partial-side-effect guard?

Default answer for v1: do not implement.

## Tests

Add focused tests under `mcp_server/test/ptc_runner_mcp/`.

Suggested files:

- `client_capabilities_test.exs`
- `sampling_transport_test.exs`
- `sampling_planner_test.exs`
- `agentic_sampling_test.exs`

Coverage:

- initialize with no capabilities => sampling unsupported;
- initialize with `%{"sampling" => %{}}` => supported;
- initialize with `%{"sampling" => %{"tools" => %{}}}` => tools
  supported but unused;
- sampling planner unavailable produces `sampling_unavailable`;
- outbound request frame shape matches MCP sampling requirements;
- response with matching id wakes the correct worker;
- JSON-RPC error response maps to planner error;
- timeout cleans pending request;
- cancellation during sampling emits no outer tool reply;
- missing `stdio_server` target returns `sampling_unavailable`;
- malformed response with both `result` and `error` is routed as an
  error, not success;
- response with array content containing one text block succeeds;
- response with `tool_use` fails;
- response with `stopReason: "maxTokens"` fails before source
  execution;
- response with non-text content fails;
- successful sampling-generated `(return 42)` executes through
  existing sandbox and renderer;
- fake sampling-capable stdio client completes the full nested flow:
  outer `tools/call` -> outbound `sampling/createMessage` -> inbound
  sampling response -> outer tool result;
- telemetry excludes raw prompt and completion.

## Open Questions

- Should sampling request visibility be tied to
  `--agentic-trace-prompts`, or should there be a separate
  `--agentic-trace-sampling` switch? This spec recommends using the
  existing trace payload policy rather than a new flag.
- Should HTTP transport support server-to-client sampling requests at
  the same time as stdio? This spec targets the current stdio server
  first. HTTP can follow once the generic request service is proven.
