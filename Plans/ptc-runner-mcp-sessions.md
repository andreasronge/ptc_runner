# PtcRunner MCP Sessions — Draft Specification

| Field | Value |
|---|---|
| Status | Draft |
| Target package | `:ptc_runner_mcp` |
| Depends on | `ptc-runner-mcp-server.md`, `ptc-runner-mcp-aggregator.md` |
| Last revised | 2026-05-13 |

This document specifies an opt-in stateful session layer for
PtcRunner MCP. A session is a supervised, bounded PTC-Lisp REPL
environment exposed over MCP. It reuses the existing PTC-Lisp memory
contract, turn history, `println` capture, and SubAgent feedback
renderers instead of adding a second artifact/notebook memory model.

Sections using **MUST** / **SHOULD** / **MAY** carry RFC 2119
normative weight.

## 1. Motivation

Current `ptc_runner_mcp` is intentionally stateless: each
`ptc_lisp_execute` call receives a complete program, fresh memory, and
fresh tool cache, then returns a structured result. This is the right
default for deterministic compute and one-shot aggregation.

Exploration has a different shape. A client LLM often wants to:

1. Fetch data once, bind it with `(def issues ...)`, then filter it in
   later turns.
2. Define helper functions with `(defn interesting? [x] ...)` and
   reuse them.
3. Inspect values with `println` and continue based on the output.
4. Use REPL-style result history (`*1`, `*2`, `*3`) for quick
   iteration.
5. Ask "what is currently defined?" without forcing the model to
   remember every prior turn in prompt text.

The in-process SubAgent loop and `mix ptc.repl` already implement
most of this model. MCP sessions should reuse it.

## 2. Positioning

The session feature should be positioned as:

> PtcRunner MCP supports stateful, supervised PTC-Lisp REPL sessions:
> define data and helper functions once, keep exploring across turns,
> and inspect the session environment under BEAM resource limits.

This is distinct from generic code-mode tools that expose arbitrary
Python/JavaScript notebook state. PTC-Lisp sessions persist only the
language's explicit user namespace (`def` / `defn`) plus bounded REPL
history and execution traces.

## 3. Scope and Goals

Goals:

1. Keep `ptc_lisp_execute` stateless and unchanged.
2. Add explicit opt-in stateful sessions.
3. Reuse `PtcRunner.Lisp.run/2` with `memory:` and `turn_history:`.
4. Reuse existing renderers where possible:
   `PtcRunner.SubAgent.Loop.TurnFeedback`,
   `PtcRunner.SubAgent.Namespace.User`, and
   `PtcRunner.SubAgent.Namespace.ExecutionHistory`.
5. Support stdio first: one MCP client normally owns one
   `ptc_runner_mcp` OS process.
6. Design owner checks so a future HTTP transport can support many
   clients concurrently.
7. Enforce session TTL, idle timeout, memory limits, binding limits,
   print-history limits, and tool-call-history limits.
8. Preserve the existing safety claim: PTC-Lisp itself has no file,
   network, or shell access; upstream MCP tools still own their
   effects.

## 4. Non-Goals

The following are out of scope for the first implementation:

- A separate artifact/note/summarization memory system.
- Durable cross-process persistence by default.
- Global memory shared across clients.
- A Python/JavaScript notebook runtime.
- Automatic semantic summarization of session state.
- HTTP transport implementation itself.
- Vector search or embeddings over session memory.
- Persisting raw upstream payloads outside the PTC-Lisp user
  namespace.
- Authorizing write-capable upstream calls based on session state.

## 5. Existing Mechanisms To Reuse

### 5.1 PTC-Lisp Memory

`PtcRunner.Lisp.run/2` accepts `memory:` and returns `step.memory`.
The current memory contract is explicit:

- `(def name value)` stores or replaces a user namespace binding.
- `(defn name [args] body)` stores a closure binding.
- `let` bindings and ordinary intermediate values do not persist.
- Failed executions return an error step and MUST NOT update session
  memory.

Session evaluation should therefore be a thin wrapper around:

```elixir
PtcRunner.Lisp.run(program,
  memory: session.memory,
  turn_history: session.turn_history,
  tools: session_tools,
  tool_cache: %{},
  caller: :mcp,
  profile: :mcp_session
)
```

Phase 1 does **not** persist `tool_cache` across session evals. Each
eval starts with an empty tool cache. This keeps REPL state visible and
explicit: only `def` / `defn`, last-three results, prints, and call
history persist.

### 5.2 REPL Turn History

`mix ptc.repl` already passes `turn_history:` and keeps the last three
results so PTC-Lisp can resolve `*1`, `*2`, and `*3`.

MCP sessions SHOULD use the same rule:

- after a successful eval, append `step.return`;
- keep only the last three results;
- expose them to the next eval through `turn_history:`.

### 5.3 Print Output

`println` output is captured in `step.prints`; it is not written to
stdout. Sessions SHOULD keep a bounded recent-print history for
inspection and return the current eval's prints in the eval response.

### 5.4 Environment Orientation

The SubAgent UI already has compact renderers:

- `Namespace.User.render/2` shows defined functions and values with
  type/sample information.
- `ExecutionHistory.render_output/3` renders recent `println` output.
- `ExecutionHistory.render_tool_calls/2` renders recent tool calls.
- `TurnFeedback.execution_feedback/3` renders result previews, changed
  memory previews, stored keys, prints, and truncation flags.

Session inspect/eval responses SHOULD reuse these renderers or extract
shared helpers rather than duplicating formatting logic.

## 6. Definitions

| Term | Meaning |
|---|---|
| Transport session | The client/server connection identity. In stdio v1 this is the running `ptc_runner_mcp` process. In future Streamable HTTP this is the MCP `Mcp-Session-Id` plus authenticated client/user identity. |
| PTC session | A logical stateful PTC-Lisp REPL with a `session_id`, owner, persistent `memory`, last-three `turn_history`, bounded print history, and bounded tool-call history. |
| Session owner | The identity allowed to eval, inspect, forget, or close a session. |
| Session memory | The PTC-Lisp user namespace map returned as `step.memory`; contains explicit `def` and `defn` bindings. |
| Binding | One entry in session memory. |

## 7. Transport Model

### 7.1 Stdio v1

With stdio, each MCP client typically starts its own server process.
Therefore:

- the process MAY be treated as the transport session;
- in-memory PTC sessions are naturally isolated per client process;
- multiple clients can use PTC Runner concurrently by running separate
  OS processes;
- concurrent requests from the same client remain bounded by
  `max_concurrent_calls`.

### 7.2 Future HTTP

The session model MUST NOT assume stdio forever. Every PTC session
MUST carry an owner field.

For stdio v1:

```elixir
%{transport: :stdio, instance_id: String.t()}
```

For future HTTP:

```elixir
%{
  transport: :http,
  mcp_session_id: String.t(),
  client_id: String.t() | nil,
  user_id: String.t() | nil
}
```

The owner check MUST happen before eval, inspect, forget, or close.

## 8. Tool Surface

Session tools are advertised only when enabled:

```text
--sessions
PTC_RUNNER_MCP_SESSIONS=true
```

Recommended tool set:

1. `ptc_session_start`
2. `ptc_session_eval`
3. `ptc_session_inspect`
4. `ptc_session_forget`
5. `ptc_session_close`

`ptc_lisp_execute` remains the stateless baseline.

If sessions are disabled, session tools SHOULD NOT be advertised. If
an implementation reserves the names anyway, calls MUST return
`sessions_disabled`; this behavior must be consistent within a build.

### 8.1 `ptc_session_start`

Creates a new empty PTC-Lisp REPL session.

Input:

```json
{
  "title": "Investigate recent GitHub MCP issues",
  "ttl_ms": 1800000
}
```

Optional fields:

- `title`
- `ttl_ms`; capped by server config.

Output:

```json
{
  "status": "ok",
  "session_id": "ptcs_...",
  "expires_at": "2026-05-13T14:30:00Z",
  "limits": {
    "max_memory_bytes": 1048576,
    "max_binding_bytes": 262144,
    "max_bindings": 200,
    "max_idle_ms": 900000
  }
}
```

### 8.2 `ptc_session_eval`

Evaluates a PTC-Lisp program against persistent session memory.

Input:

```json
{
  "session_id": "ptcs_...",
  "program": "(def bugs (filter bug? issues)) (println \"bugs\" (count bugs))",
  "context": {}
}
```

Semantics:

- Pass `session.memory` to `Lisp.run/2` as `memory:`.
- Pass `session.turn_history` as `turn_history:`.
- When aggregator mode is configured, session eval exposes
  `(tool/mcp-call ...)` using the existing aggregator tool registry.
- Pass `tool_cache: %{}` in Phase 1. Cacheable tool results do not
  persist across session evals.
- `context` remains per-call input and does not persist.
- On success, replace `session.memory` with `step.memory`.
- On success, update `session.turn_history` with `step.return`,
  keeping only the last three results.
- On success, append `step.prints`, `step.tool_calls`, and any compact
  upstream-call entries to bounded histories.
- On error, do not update memory or result history. The implementation
  MAY append an error entry to bounded execution history.

Output SHOULD include:

```json
{
  "status": "ok",
  "result": "user=> ...",
  "prints": ["bugs 12"],
  "feedback": ";; bugs = [...]",
  "memory": {
    "changed": {"bugs": "[...]"},
    "stored_keys": ["bug?", "bugs", "issues"],
    "truncated": false
  },
  "session": {
    "session_id": "ptcs_...",
    "turn": 3,
    "memory_bytes": 123456,
    "binding_count": 3
  },
  "truncated": false
}
```

The `feedback`, `result`, and `memory` fields SHOULD come from
`TurnFeedback.execution_feedback/3` or a shared equivalent. MCP
response-profile work may choose slim/structured/debug variants, but
the session state update semantics are independent of the response
shape.

`signature` / `return_schema` / `output_contract` inputs are
deliberately omitted from `ptc_session_eval` in Phase 1. Session eval
is an exploratory REPL operation; typed programmatic extraction
remains the job of stateless `ptc_lisp_execute`. A later phase may add
typed validation, but must define exact validation timing and rollback
behavior before doing so.

This does **not** refer to MCP tool `outputSchema`. Session tools may
still advertise MCP `outputSchema` for their own response envelopes
when the active response profile allows it.

### 8.3 `ptc_session_inspect`

Returns a compact orientation view of the session.

Input:

```json
{
  "session_id": "ptcs_...",
  "view": "overview"
}
```

Views:

| View | Meaning |
|---|---|
| `"overview"` | Defined functions/values, recent prints, recent tool calls, last result previews. |
| `"memory"` | Defined functions and values only. |
| `"prints"` | Recent `println` output. |
| `"tool_calls"` | Recent tool/upstream call summaries. |
| `"history"` | `*1`, `*2`, `*3` previews. |
| `"limits"` | Current memory/binding/history usage. |

`overview` SHOULD reuse:

- `Namespace.User.render(session.memory, has_println: has_recent_prints?)`
- `ExecutionHistory.render_output(session.prints, limit, has_println?)`
- `ExecutionHistory.render_tool_calls(session.tool_calls, limit)`

### 8.4 `ptc_session_forget`

Removes bindings or clears bounded histories.

Input:

```json
{
  "session_id": "ptcs_...",
  "bindings": ["issues", "bugs"],
  "clear": ["prints", "tool_calls"]
}
```

Semantics:

- `bindings` removes named user namespace entries.
- `clear` may contain `"memory"`, `"history"`, `"prints"`, or
  `"tool_calls"` in Phase 1.
- Forgetting `"memory"` clears all `def` / `defn` bindings.
- The response returns the remaining stored keys and usage.

`"tool_cache"` is not accepted in Phase 1 because session evals do not
persist tool cache. If a later phase adds persistent tool cache, it may
add `"tool_cache"` as a clear target with explicit cache limits.

This is the explicit cleanup mechanism for stale or large values.

### 8.5 `ptc_session_close`

Closes a session and deletes its state.

Input:

```json
{
  "session_id": "ptcs_...",
  "reason": "done"
}
```

After close, session tools MUST return `session_not_found` or
`session_closed` for that id. A short tombstone MAY be retained so
clients can distinguish closed from unknown sessions.

### 8.6 Session Authoring Card

When sessions are enabled, the server SHOULD ship a short
session-specific authoring card, separate from the stateless
`mcp_authoring_card.md`.

Recommended file:

```text
mcp_server/priv/mcp_session_authoring_card.md
```

This card MUST only be included in:

- session tool descriptions; and/or
- `ptc_session_inspect view: "overview"` orientation output when
  useful.

It MUST NOT be appended to the stateless `ptc_lisp_execute`
description, because that tool remains independent per invocation and
its existing "No state across calls" rule remains true.

The card should be short enough that it can stay in `tools/list`
without crowding the catalog. Recommended text:

```markdown
# PTC-Lisp sessions

This tool evaluates PTC-Lisp inside a stateful session. Values defined
with `(def name value)` and functions defined with `(defn name [args]
body)` are available in later `ptc_session_eval` calls for the same
session.

Use `println` to inspect values between calls. Printed lines are
captured and returned; they are not stdout.

`*1`, `*2`, and `*3` reference the last three successful eval results.

Use `let` for temporary values. Use `ptc_session_forget` to remove
stale or large bindings.

Keep programs short and store only values you need again.
```

Session tool descriptions MAY include only the card plus a one-line
tool-specific contract. Detailed language/reference text should remain
in existing docs, not in every tool description.

## 9. Session State Shape

Recommended internal state:

```elixir
%Session{
  id: String.t(),
  owner: map(),
  title: String.t() | nil,
  mode: :read_only | :write_capable, # internal metadata, not public schema
  created_at: DateTime.t(),
  updated_at: DateTime.t(),
  expires_at: DateTime.t(),
  turn: non_neg_integer(),
  memory: map(),
  turn_history: [term()],
  prints: [String.t()],
  tool_calls: [map()],
  upstream_calls: [map()],
  eval: nil | %{request_id: term(), worker: pid(), monitor: reference()},
  limits: %{
    max_memory_bytes: pos_integer(),
    max_binding_bytes: pos_integer(),
    max_bindings: pos_integer(),
    max_history_entry_bytes: pos_integer(),
    max_print_entries: pos_integer(),
    max_print_bytes: pos_integer(),
    max_tool_call_entries: pos_integer(),
    max_tool_call_bytes: pos_integer(),
    max_upstream_call_entries: pos_integer(),
    max_upstream_call_bytes: pos_integer(),
    max_idle_ms: pos_integer()
  }
}
```

`memory` is the same map returned by `Lisp.run/2`. It is not a new
storage abstraction.

## 10. Limits

Add session-specific limits:

| Limit | Default | Configurable |
|---|---:|---|
| `max_sessions` | 64 per process | env/CLI |
| `max_sessions_per_owner` | 16 | env/CLI |
| `session_ttl_ms` | 30 min | env/CLI |
| `session_idle_timeout_ms` | 15 min | env/CLI |
| `max_session_memory_bytes` | 1 MiB | env/CLI |
| `max_session_binding_bytes` | 256 KiB | env/CLI |
| `max_session_bindings` | 200 | env/CLI |
| `max_session_history_entry_bytes` | 64 KiB | env/CLI |
| `max_session_print_entries` | 50 | env/CLI |
| `max_session_print_bytes` | 64 KiB | env/CLI |
| `max_session_tool_call_entries` | 50 | env/CLI |
| `max_session_tool_call_bytes` | 128 KiB | env/CLI |
| `max_session_upstream_call_entries` | 50 | env/CLI |
| `max_session_upstream_call_bytes` | 128 KiB | env/CLI |

After a successful eval, the session process MUST validate:

1. total `:erlang.external_size(step.memory)`;
2. binding count;
3. per-binding external size;
4. each new `turn_history` entry after truncation/capping;
5. total bounded print history bytes;
6. total bounded tool-call history bytes;
7. total bounded upstream-call history bytes.

If any candidate persisted session field exceeds limits, the eval MUST
return `session_limit_exceeded` and MUST NOT commit the candidate
memory, history, prints, or call-history changes. This gives
transactional session semantics: either the eval succeeds and commits
all session updates, or the session remains as it was before the call.

History and trace fields are bounded before commit:

- `turn_history` stores at most three entries. Each entry is stored as
  the raw term only if its external size is within
  `max_session_history_entry_bytes`; otherwise the entry is replaced
  by a capped preview marker. This prevents a huge final result from
  living indefinitely in `*1`.
- `*1`, `*2`, and `*3` therefore preserve raw values only while those
  values fit the history-entry cap. If a value is replaced by a
  preview marker, later code sees that marker, not the original value.
  The eval response MUST make this explicit, e.g. `"*1 stored as
  preview; original value exceeded max_session_history_entry_bytes"`.
- `prints` stores recent print lines only. Lines are already capped by
  `Lisp.run/2`'s `max_print_length`; the session also enforces total
  print-history byte and count caps.
- `tool_calls` and `upstream_calls` store compact, redacted metadata
  only, not full large results. They are capped by count and total
  external size.
- Phase 1 has no persistent `tool_cache`, so no cache-size limit is
  needed. If a later phase persists tool cache, it MUST add explicit
  byte limits and invalidation semantics first.

## 11. Safety Model

### 11.1 Persistent Data Is Explicit

Only explicit `def` and `defn` bindings persist. Ordinary expression
results persist only in bounded `*1`, `*2`, `*3` history.

### 11.2 Hidden Bindings

Existing renderers hide samples for names starting with `_`. Sessions
SHOULD preserve that convention:

```clojure
(def _token "...") ; inspect shows type and [Hidden], not sample
```

This is only display hygiene, not a secret vault. Session tools MUST
still run configured redaction before storing print/tool-call history.

### 11.3 Session Access Policy

Session access mode is not part of the public tool schema. Upstream
tool permissions are controlled by MCP server configuration and the
upstream tools themselves, not by a client-selected per-session flag.

If a future version exposes enforced per-session modes, the schema and
tool descriptions must document the concrete enforcement behavior at
the `(tool/mcp-call ...)` boundary before `Upstream.call/4`.

### 11.4 Prompt Injection

Session memory and previous prints are untrusted data. If rendered into
LLM-facing prompts, they MUST be labeled as prior data/output, not
instructions.

### 11.5 Staleness

Bindings can become stale. The server SHOULD expose `updated_at`,
turn number, and optional eval metadata in inspect responses. It
SHOULD NOT silently summarize or rewrite stale bindings.

Implementation note: Phase 1 inspect output SHOULD include session
`updated_at`, current `turn`, `eval_status`, `memory_bytes`, and
`binding_count` in every overview/limits response. A later phase
SHOULD add per-binding metadata outside executable Lisp memory:
`bound_at_turn`, `updated_at`, `approx_bytes`, and optionally
`source`. This metadata is for inspect/debug only and MUST NOT become
implicitly executable Lisp state.

### 11.6 Product Risk Guidance

The main product risks are stale state, accidental memory bloat,
history truncation surprises, and assuming sessions are durable.

- Stale state: inspect output should make age visible. Tool
  descriptions should encourage intentional refresh patterns, e.g.
  storing `(defn fetch-issues [] ...)` separately from `(def issues
  (fetch-issues))` so the model can refresh explicitly.
- Memory bloat: `ptc_session_forget` must be easy for the LLM to
  discover. Inspect `view: "limits"` SHOULD show top bindings by
  approximate byte size when cheap to compute, plus print/tool-call
  history counts.
- History truncation: when `*1`, `*2`, or `*3` is stored as a preview
  marker, eval feedback MUST say so plainly.
- Cancellation/close: tests MUST cover cancelled evals not committing,
  busy flags being cleared on worker death, and close cancelling any
  running worker.
- Access expectations: do not expose advisory access-mode controls in
  client-facing schemas unless they enforce behavior.

## 12. OTP Architecture

Recommended modules:

```text
mcp_server/lib/ptc_runner_mcp/
  sessions.ex                  # public facade
  sessions/
    config.ex                  # feature flag and limits
    owner.ex                   # stdio/http owner derivation and checks
    registry.ex                # lookup/index, quotas
    supervisor.ex              # DynamicSupervisor over Session processes
    session.ex                 # GenServer per PTC-Lisp REPL session
    projection.ex              # inspect/eval response shaping
    limits.ex                  # memory/binding/history validation
```

Supervision tree addition:

```text
PtcRunnerMcp.Supervisor
  Credentials
  Upstream.Supervisor
  Sessions.Registry
  Sessions.Supervisor
  Stdio
```

Each PTC session process owns its memory and histories, but it MUST
NOT execute PTC-Lisp inside the GenServer callback. Eval runs in a
cancellable worker process owned by the stdio request path.

`ptc_session_eval` lifecycle:

1. `JsonRpc` validates the tool name and basic argument shape.
2. `Stdio` treats `ptc_session_eval` as an async gated tool, same
   class as `ptc_lisp_execute`: it acquires a `max_concurrent_calls`
   permit, spawns a per-request worker, monitors it, and records it in
   the in-flight table.
3. The worker asks `Sessions.Session` to begin eval. The session
   GenServer atomically checks owner, checks that no eval is already
   running, snapshots memory/history, records the worker pid/request
   id in `state.eval`, and returns the snapshot.
4. The worker runs `Lisp.run/2` with the snapshot, linked/cancellable
   sandbox behavior matching `ptc_lisp_execute`.
5. The worker sends the eval result back to the session GenServer for
   commit. The session validates all limits against the candidate new
   state, then either commits or rejects with `session_limit_exceeded`.
6. The worker returns the final MCP envelope to `Stdio`; `Stdio`
   releases the concurrency permit on worker `:DOWN`.

Per-session concurrency rule for Phase 1: at most one eval may run per
session. A second `ptc_session_eval` for a session with `state.eval !=
nil` MUST return `session_busy`; it MUST NOT queue. `ptc_session_inspect`
MAY run during an eval and returns the last committed state plus
`eval_status: "running"`. `ptc_session_forget` MUST return
`session_busy` while an eval is running. `ptc_session_close` MUST cancel
the running worker, clear the session state, and close/tombstone the
session.

Cancellation:

- MCP `notifications/cancelled` kills the stdio worker for the matching
  request id, as today.
- Because the sandbox child is linked to that worker, killing the
  worker terminates the in-flight eval promptly.
- The session GenServer monitors the worker recorded in `state.eval`.
  If it receives `:DOWN` before a commit message, it clears
  `state.eval` and leaves memory/history unchanged.
- A late commit from a dead or superseded worker MUST be ignored by
  matching the stored request id/monitor reference.

The registry owns indexes and quotas. Session processes terminate on
close, TTL, idle timeout, owner shutdown, or supervisor shutdown.

## 13. Error Model

Add session-specific reasons to MCP tool envelopes:

| Reason | Meaning |
|---|---|
| `sessions_disabled` | Server started without session support. |
| `session_not_found` | Unknown or expired session id. |
| `session_closed` | Session was explicitly closed. |
| `session_owner_mismatch` | Caller does not own the session. |
| `session_busy` | An eval is already running for this session. |
| `session_limit_exceeded` | Count/byte/binding/history quota exceeded. |
| `session_policy_violation` | Operation rejected by read-only/write policy. |
| `session_args_error` | Malformed session tool arguments. |

These are MCP-only reasons unless later promoted to shared PTC
protocol reasons.

## 14. Telemetry

Emit telemetry events:

```elixir
[:ptc_runner_mcp, :session, :start]
[:ptc_runner_mcp, :session, :eval, :start]
[:ptc_runner_mcp, :session, :eval, :stop]
[:ptc_runner_mcp, :session, :inspect]
[:ptc_runner_mcp, :session, :forget]
[:ptc_runner_mcp, :session, :close]
[:ptc_runner_mcp, :session, :evict]
```

Metadata SHOULD include:

- `session_id`
- `owner_hash`
- `mode`
- `turn`
- `binding_count`
- `memory_bytes`
- `prints_count`
- `tool_calls_count`
- `reason` for close/evict/error

Do not emit raw binding values, print lines, or tool results in
telemetry metadata.

## 15. Interaction With Existing Features

### 15.1 `ptc_lisp_execute`

No behavior change. It remains stateless.

### 15.2 Aggregator Mode

`ptc_session_eval` MAY use aggregator mode. Upstream-call entries
produced inside a session eval SHOULD be appended to the session's
bounded upstream-call history.

### 15.3 Agentic `ptc_task`

Agentic `ptc_task` may later use sessions as its working environment,
but Phase 1 should not require agentic mode. Sessions should be useful
for client-authored PTC-Lisp first.

### 15.4 Debug Tool

`ptc_debug` SHOULD include session events when enabled, capped by the
existing debug response limits.

### 15.5 JSON-RPC and Tool Integration

Session tools extend the existing `tools/list` and `tools/call`
handling:

- `ptc_session_start`, `ptc_session_inspect`, `ptc_session_forget`,
  and `ptc_session_close` are synchronous tool calls. They do not
  acquire the global `max_concurrent_calls` execution permit because
  they do not run the sandbox, but they must still validate frame and
  argument sizes.
- `ptc_session_eval` is an async gated tool, like
  `ptc_lisp_execute`. It acquires the global execution permit, runs in
  a per-request worker, supports `notifications/cancelled`, records
  debug outcomes, and releases the permit on worker `:DOWN`.
- `tools/list` advertises session tools only when sessions are enabled.
  Each advertised session tool MUST include an `inputSchema` and, when
  the active response profile supports schemas, an `outputSchema` that
  includes the session-specific error reasons.
- Argument validation happens before acquiring the global execution
  permit when possible. Owner checks and per-session busy checks happen
  before sandbox execution.
- Session tools SHOULD follow the active
  `slim|structured|debug` response profile where practical, but their
  core `status`, `reason`, `message`, and `session_id` fields must
  remain stable.
- `ptc_debug` recording must include session tool calls when enabled,
  but must not record raw binding values, raw prints, or large tool
  results beyond existing debug limits.

## 16. Related Tools and Future Additions

Other stateful MCP REPL tools point at useful directions, but also
clarify what PtcRunner should not become.

### 16.1 External Reference Points

- Posit `mcptools` separates MCP server and live language sessions:
  the server brokers access, while `mcp_session()` registers an
  interactive R process. PtcRunner should borrow the server/session
  split, but keep the session language PTC-Lisp.
- `hdresearch/mcp-python` offers a minimal persistent Python REPL:
  execute code, list variables, reset. PtcRunner should borrow the
  simple eval/inspect/forget shape, not arbitrary Python execution or
  package installation.
- `takafu/repl-mcp` manages many generic REPL and shell processes,
  with session URLs, signal handling, timeout recovery, and prompt
  learning. PtcRunner should borrow lifecycle and observability ideas,
  not expose arbitrary shells as its core capability.

The PtcRunner differentiator remains: stateful exploration in a
constrained, deterministic PTC-Lisp runtime with BEAM supervision,
resource limits, typed outputs, and optional MCP aggregation.

### 16.2 Candidate Future Tools

The following tools are intentionally out of Phase 1 but should remain
compatible with the session architecture:

| Tool | Purpose |
|---|---|
| `ptc_session_list` | List active sessions for the current owner/process. |
| `ptc_session_details` | Return metadata, limits, usage, last activity, and status for one session. |
| `ptc_session_interrupt` | Cancel an in-flight session eval, mirroring `notifications/cancelled` behavior. |
| `ptc_session_reset` | Clear memory, history, prints, tool calls, and tool cache in one operation. May be sugar over `ptc_session_forget`. |
| `ptc_session_export` | Return a redacted, bounded snapshot for debugging or transfer. Disabled by default. |

`ptc_session_list` is a strong Phase 1.5 candidate because users and
LLMs will quickly ask which sessions exist. A minimal version only
needs `session_id`, `title`, `turn`, `updated_at`, `memory_bytes`, and
`eval_status`.

`ptc_session_details` can initially be covered by
`ptc_session_inspect view: "limits"`, but a separate tool may become
useful if clients want metadata without rendered memory previews.

`ptc_session_reset` is ergonomic sugar over
`ptc_session_forget clear: ["memory", "history", "prints",
"tool_calls"]`. It should remain optional until real usage shows the
extra tool is worth the surface area.

### 16.3 Candidate Future UX

- Browser/session trace viewer similar in spirit to `repl-mcp`, but
  backed by PTC trace data rather than a raw terminal.
- Session timeline in `ptc_debug`: evals, changed bindings, prints,
  tool calls, errors, limit events.
- Optional initial prelude on `ptc_session_start`, useful for loading
  helper functions.
- Optional persistence backend for explicit operator-managed session
  continuity across server restarts.
- HTTP transport ownership support using MCP `Mcp-Session-Id`.

### 16.4 Explicit Non-Direction

PtcRunner sessions SHOULD NOT grow into a generic shell/PTY manager.
That space is covered by tools like `repl-mcp`, and adopting it would
weaken PtcRunner's safety and positioning. If users need arbitrary
Python, R, Ruby, or shell REPL access, they should use a purpose-built
REPL MCP server with appropriate OS/container isolation.

## 17. Phasing

### Phase 0 — Contract and Shared Helpers

- Replace artifact-memory design with this REPL-session contract.
- Identify renderer helpers that should be shared rather than
  SubAgent-private.
- Add tests for memory commit/rollback semantics using `Lisp.run/2`.

### Phase 1 — Stdio-Local Sessions

- Add session config, registry, supervisor, owner derivation, and
  session GenServer.
- Implement `ptc_session_start`, `ptc_session_eval`,
  `ptc_session_inspect`, `ptc_session_forget`, and
  `ptc_session_close`.
- Feature flag off by default.
- Support no-upstream PTC-Lisp first.

### Phase 2 — Aggregator Integration

- Add `(tool/mcp-call ...)` support inside `ptc_session_eval`.
- Persist bounded tool/upstream call histories.
- Apply read-only policy where metadata/allowlists exist.

### Phase 3 — HTTP-Ready Ownership

- Refactor owner derivation to accept future HTTP `Mcp-Session-Id`.
- Add owner mismatch and multi-owner isolation tests.
- Do not implement HTTP transport in this phase.

### Phase 4 — Optional Persistence

- Optional, explicitly configured persistence backend.
- Preserve owner binding and expiration.
- Disabled by default.

## 18. Implementation and Review Workflow

Implementation should proceed phase-by-phase. A fresh Codex session
should start by reading this specification and then implement only the
requested phase or sub-phase. Do not broaden Phase 1 into Phase 2
aggregator support unless explicitly requested.

Each phase or substantial sub-phase should end with:

- focused tests for the new behavior;
- `mix format`;
- targeted `mix test ...`;
- `mix check` when practical;
- an independent high-effort Codex review before merging or starting
  the next substantial phase.

Use the `codex-review` skill in review mode for the independent pass.
The review request should name this specification and the implemented
scope, for example:

```text
Review the current diff against Plans/ptc-runner-mcp-sessions.md.
Scope: Phase 1b, ptc_session_eval worker/cancellation/busy/rollback.
Focus on behavioral bugs, missing tests, and scope creep into Phase 2.
```

Suggested review checkpoints:

1. Phase 0: shared renderer extraction and rollback/limit tests.
2. Phase 1a: session config, owner, registry, supervisor, and session
   lifecycle.
3. Phase 1b: `ptc_session_eval` worker, cancellation, `session_busy`,
   rollback, and persisted-state limits.
4. Phase 1c: MCP tool surface, `tools/list`, JSON-RPC routing,
   schemas, response profiles, and debug recording.
5. Phase 1d: `ptc_session_inspect`, `ptc_session_forget`,
   `ptc_session_close`, disabled-by-default behavior, and full Phase 1
   integration.

Recommended fresh-session handoff:

```text
Read Plans/ptc-runner-mcp-sessions.md first. Implement only <phase>.
Do not implement Phase 2 aggregator support. After tests pass, run the
codex-review skill in high-effort review mode on the diff and address
valid findings.
```

When subagents are used, split work by file ownership to avoid merge
conflicts. `tools.ex`, `json_rpc.ex`, `stdio.ex`, `application.ex`,
and shared test helpers are collision-prone and should have a single
owner per sub-phase.

## 19. Open Questions

1. Should `tool_cache` persist across session evals after Phase 1?
   This improves repeated pure/cacheable tool use, but can surprise
   users when upstream data changes. Phase 1 answer: no persistent
   tool cache.
2. Should `ptc_session_eval` allow a typed return contract after
   Phase 1, and if so should validation failure roll back memory?
   Phase 1 answer: no `signature` / `return_schema` /
   `output_contract` on `ptc_session_eval`.
3. How much of `TurnFeedback` should move to a shared non-SubAgent
   module?
4. Should `ptc_session_inspect view: "memory"` return only rendered
   text, structured entries, or both?
5. Should closed sessions keep tombstones briefly?
6. Should `ptc_session_forget` support wildcard/prefix deletion?
7. Should session start support loading an initial prelude program?
8. Should `ptc_session_list` be Phase 1.5 for usability, or Phase 2
   to keep the initial surface minimal?
9. Should `ptc_session_interrupt` be implemented as a separate tool,
   or should MCP `notifications/cancelled` be the only cancellation
   path for Phase 1?

## 20. Initial Acceptance Criteria

The first shippable version is acceptable when:

1. Sessions are disabled by default.
2. Enabling sessions adds explicit session tools to `tools/list`.
3. Multiple sessions can exist concurrently in one stdio server
   process.
4. Session state is isolated by owner.
5. `def` and `defn` persist across `ptc_session_eval` calls.
6. `let` bindings and ordinary intermediate values do not persist.
7. `*1`, `*2`, `*3` work across eval calls.
8. `println` output is returned and available via inspect.
9. Memory limit violations roll back the eval.
10. `ptc_session_forget` removes selected bindings and histories.
11. Cancelled evals do not commit memory/history.
12. A concurrent eval on the same session returns `session_busy`.
13. Persisted `turn_history`, prints, tool-call history, and
    upstream-call history are all bounded by count and bytes.
14. `ptc_session_eval` has no `signature` / `return_schema` /
    `output_contract` in Phase 1.
15. `tool_cache` does not persist across session evals in Phase 1.
16. Oversized `*1` / `*2` / `*3` entries become explicit preview
    markers and eval feedback reports that truncation.
17. `ptc_session_start` does not advertise advisory/non-enforced
    access-mode fields.
18. `ptc_lisp_execute` remains stateless and all existing tests pass.
