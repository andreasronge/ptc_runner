# PtcRunner MCP Aggregator — Specification

| Field | Value |
|---|---|
| Status | Draft |
| Target package | `:ptc_runner_mcp` |
| Depends on | `ptc-runner-mcp-server.md` (v1) |
| Last revised | 2026-05-08 |

This document is the build specification for the PtcRunner MCP
Aggregator. It defines configuration, contracts, error model, wire
format, resource limits, and an implementation phase plan. Sections
using **MUST** / **SHOULD** / **MAY** carry RFC 2119 normative weight.

## 1. Scope and Goals

The aggregator extends the PtcRunner MCP server (v1) so a single
`ptc_lisp_execute` call can invoke configured upstream MCP servers from
inside the PTC-Lisp sandbox, compose their results deterministically,
and return only the final value to the calling LLM.

Goals:

1. Compose multiple MCP servers in one PTC-Lisp program without
   pushing intermediate results back to the calling LLM's context.
2. Reuse the existing PTC-Lisp tool registry (`tool/<name>` form). No
   new analyzer or formatter work in v1.
3. Keep MCP v1's no-upstream behavior unchanged when no upstreams are
   configured.
4. Validate the integration shape (tools registry, side-channel
   collection, envelope, schema) **before** investing in stdio MCP
   client lifecycle.

Non-goals are listed in §3.

### 1.1 Target workflow

```clojure
(def repos (tool/mcp-call {:server "github"
                           :tool "search_repos"
                           :args {:query "infra" :limit 50}}))

(def tickets (tool/mcp-call {:server "linear"
                             :tool "list_tickets"
                             :args {:status "open"}}))

(def repo-names (set (map :name repos)))
(def matches (filter #(contains? repo-names (:repo %)) tickets))

(return {:count (count matches)
         :titles (map :title matches)})
```

The large `repos` and `tickets` values stay inside the sandbox unless
the program explicitly returns them.

## 2. Definitions

| Term | Meaning |
|---|---|
| Upstream | An MCP server PtcRunner connects to as a client. |
| Configured upstream | An entry in the upstreams config file. |
| Started upstream | A configured upstream that is currently healthy with a valid cached `tools/list`. The set grows when `ensure_started/1` succeeds and shrinks when an upstream crashes; it does **not** record historical health. A previously-started upstream that is currently in its recovery window is **not** in `started_upstreams`. |
| `ensure_started/1` | Synchronous helper: if the named upstream is already in `started_upstreams`, returns `:ok`; otherwise attempts `start_link/2`, `notifications/initialized`, and `tools/list`. On success, adds the upstream to `started_upstreams` and returns `:ok`. On any failure, returns `{:error, reason, detail}` where `reason :: :upstream_unavailable`. |
| Aggregator mode | The MCP server's static, config-derived operating mode. See §4.1. |
| Worker process | The BEAM process handling a single `tools/call` request, owning the sandbox for that call. |
| Collector | The same worker process, in its role as receiver of `upstream_calls` records. See §6.4. |
| Upstream behaviour | The Elixir behaviour `PtcRunnerMcp.Upstream`. See §6.3. |
| World-fault | A failure caused by external conditions. Returns `nil`. See §7.1. |
| Programmer-fault | A failure caused by a defect in the generated program. Raises a PTC-Lisp runtime error. See §7.2. |

## 3. Non-Goals

The following are explicitly **out of scope** for this specification:

- Native re-exposure of upstream tools in PtcRunner's `tools/list`.
- Auto-import of Claude Desktop config.
- MCP resource publishing for the upstream catalog.
- Forwarding upstream MCP resources or prompts.
- OAuth, credential vault, `.env` loading.
- Dynamic upstream schema refresh on `tools/list_changed`.
- Multi-hop cycle detection across separate PtcRunner processes.
- A new `mcp/<server>` PTC-Lisp namespace syntax.
- Upstream-side cancellation propagation (`notifications/cancelled`
  forwarded to the upstream).
- Server-side upstream response caching.
- Streaming upstream responses to PTC-Lisp.
- A claim that upstream **effects** are sandboxed. PtcRunner's
  generated code is sandboxed; configured upstream tools may still
  read files, hit networks, or mutate external systems.

These features may be revisited after the Phase 2 decision point (§14).

## 4. Architecture

### 4.1 Aggregator-mode predicates

The implementation **MUST** distinguish two predicates:

- **`configured_aggregator_mode?/0 :: boolean`** — static, derived from
  the config file at startup. Returns true iff the config contains at
  least one upstream entry. Used for: profile selection, capability
  description, advertised `outputSchema`, tool annotations, sandbox
  default limits, telemetry `profile:` metadata.
- **`started_upstreams/0 :: MapSet.t(String.t())`** — runtime set of
  upstream names that have completed `start_link/2` and `tools/list`
  successfully at least once. Mutated as lazy spawns succeed and as
  upstreams crash/recover. Used for: programmer-fault classification of
  unknown tools (§7.4) and diagnostics.

Conflating the two is a specification bug; lazy spawn means
`started_upstreams` is empty at startup. The static predicate **MUST**
drive descriptions, schemas, limits, and annotations regardless of
runtime upstream health.

**Per-name serialization.** `ensure_started/1` **MUST** be serialized
per upstream name by the `Upstream.Registry` GenServer. Concurrent
`(tool/mcp-call ...)` invocations from `pmap` branches that target the
same not-yet-started upstream **MUST** observe exactly one spawn
attempt; the second arrival waits on the first's result and either
sees `:ok` (and proceeds) or sees the same
`{:error, :upstream_unavailable, detail}` (and returns `nil` per
§7.1). Calls targeting *different* upstreams proceed in parallel.
Implementation note: a single `GenServer.call(Registry, {:ensure_started,
name})` per branch satisfies both properties — the GenServer's serial
mailbox is the per-name lock, and Erlang's natural per-name dispatch
across `:counters`-protected entries gives concurrency across names.

### 4.2 Component map

```text
mcp_server/lib/ptc_runner_mcp/
  upstream.ex                  # behaviour (§6.3)
  upstream/
    fake.ex                    # in-process impl (Phase 1a)
    stdio.ex                   # subprocess impl (Phase 1b)
    registry.ex                # name -> {impl, pid} routing
    supervisor.ex              # one_for_one over Connection processes
  tools.ex                     # advertised_description/2, tool_entry/0
  envelope.ex                  # success/error wrapping, structured payload
  upstream_calls.ex            # collector helpers (§6.4)
  application.ex               # supervision tree, predicates
```

### 4.3 Connection lifecycle

Upstreams are **lazy-spawned**: an upstream subprocess (or Fake
instance) **MUST** start on the first `(tool/mcp-call ...)` invocation
that targets it, not at MCP server startup. Cold-start cost surfaces
as the first call's latency, not as a pre-warm cost for unused
upstreams.

The `tool/mcp-call` executor's first action **MUST** be
`ensure_started/1` (see §2). Subsequent steps depend on its result:

- `:ok` → proceed with `Upstream.call/4`.
- `{:error, :upstream_unavailable, detail}` → return `nil` to the
  program, record an `upstream_calls` entry with reason
  `upstream_unavailable` and `error: detail`. Do **not** retry within
  the same program.

Additional rules:

- No automatic retry of `ensure_started/1` within a single program;
  one failed call to an unhealthy upstream produces one
  `upstream_unavailable` entry. The next program is a fresh attempt.
- A started upstream that crashes is removed from `started_upstreams`.
  The supervisor restarts the underlying process with exponential
  backoff (cap 30 s). Calls during the recovery window observe the
  upstream as not-started and route through `ensure_started/1`,
  which fails until recovery completes.
- On graceful PtcRunner shutdown, all upstream processes **MUST** be
  terminated cleanly via stdin EOF (Stdio impl) or `stop/1` callback
  (Fake impl).

## 5. Configuration

### 5.1 Resolution order

The MCP server resolves the upstreams config from the first match in:

1. `--upstreams-config <path>` flag.
2. `PTC_RUNNER_MCP_UPSTREAMS` env var.
3. `~/.config/ptc_runner_mcp/upstreams.json` (XDG default).

If no source is found, the server runs in MCP v1 mode
(`:mcp_no_tools` profile). Aggregator mode is opt-in.

### 5.2 Format

```json
{
  "upstreams": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    "linear": {
      "command": "linear-mcp",
      "args": []
    }
  }
}
```

`${VAR}` placeholders **MUST** be resolved from the parent process
environment at startup. Unset variables **MUST** produce a clear
startup error and abort.

### 5.3 Self-as-upstream rejection

If the config loader detects PtcRunner configured as an upstream of
itself (by command path match), the server **MUST** fail fast with an
error pointing at the offending entry.

Multi-hop cycles across separate PtcRunner processes are unsafeguarded;
programs that loop will eventually hit
`max_upstream_calls_per_program` or `program_timeout`.

### 5.4 Test fake-upstream registration

`Upstream.Fake` instances **MUST NOT** be registrable via the JSON
config file. A `"fake": "ModName"` field (or any equivalent) would
pollute production config with test-only behavior and create a path
where a misconfigured deploy silently bypasses real upstreams.

The `Upstream.Registry` GenServer **MUST** instead expose a direct
test API:

```elixir
# Either: bootstrap fakes at start
Upstream.Registry.start_link(
  upstreams: [%{name: "fake-x", impl: PtcRunnerMcp.Upstream.Fake, config: %{...}}]
)

# Or: install a fake at runtime (test setup only)
Upstream.Registry.put_fake("fake-x", impl_or_config)
```

Production `Application.start/2` **MUST NOT** call `put_fake/2` and
**MUST NOT** read fake configuration from `Application.get_env/3`. The
production Registry reads exclusively from the JSON config resolved
per §5.1.

Tests MAY use either the constructor option or `put_fake/2`. The
constructor form is preferred when the fake set is known up front;
`put_fake/2` is the seam for tests that mutate the upstream set
mid-test (e.g., simulating a newly-configured upstream).

## 6. Interfaces

### 6.1 Tool advertisement

The MCP server advertises **exactly one** tool (`ptc_lisp_execute`) in
both `:mcp_no_tools` and aggregator mode. Native re-exposure of
upstream tools is out of scope (§3).

`tools/list` differences in aggregator mode:

- Description: includes the aggregator authoring card and (Phase 3)
  inline upstream catalog.
- Annotations: per §8.2.
- `outputSchema`: per §8.4.

### 6.2 `tool/mcp-call` surface

Aggregator mode registers one PTC-Lisp tool, named `mcp-call`, callable
as `(tool/mcp-call {...})`. The argument **MUST** be a map with the
following keys:

| Key | PTC-Lisp type | Required | Description |
|---|---|---|---|
| `:server` | string | yes | Configured upstream name. |
| `:tool` | string | yes | Tool name within that upstream. |
| `:args` | map | yes | Argument map sent as the upstream's `tools/call` `arguments` object. |

The PTC-Lisp keyword keys (`:server`, `:tool`, `:args`) become string
keys when crossing into JSON. The `:args` map's keys (which may be
PTC-Lisp keywords or strings) likewise serialize to JSON string keys
per the existing PTC-Lisp → JSON convention. Values inside `:args`
**MUST** be JSON-encodable PTC-Lisp data; non-encodable values raise
a programmer-fault runtime error before the upstream call is
attempted.

Example:

```clojure
(def repos
  (tool/mcp-call {:server "github"
                  :tool "search_repos"
                  :args {:query "infra" :limit 50}}))

(def all-prs
  (pmap #(tool/mcp-call {:server "github"
                         :tool "get_pr"
                         :args {:number %}})
        pr-numbers))

(def good-prs (remove nil? all-prs))
```

`(tool/mcp-call ...)` is not a first-class function value;
higher-order use **MUST** wrap it in a closure (`#(tool/mcp-call ...)`
or `(fn [x] (tool/mcp-call ...))`).

### 6.3 `PtcRunnerMcp.Upstream` behaviour

Both the Phase 1a in-process Fake and the Phase 1b stdio implementation
**MUST** conform to this behaviour:

```elixir
defmodule PtcRunnerMcp.Upstream do
  @type server_name :: String.t()
  @type tool_name :: String.t()
  @type json :: nil | boolean() | number() | binary() | [json] | %{optional(binary()) => json}

  @type reason :: :upstream_unavailable
                | :upstream_error
                | :timeout
                | :response_too_large

  @type tool_schema :: %{
          required(:name) => String.t(),
          required(:input_schema) => map(),
          optional(:description) => String.t()
        }

  @type call_opts :: [
          timeout: pos_integer(),
          max_response_bytes: pos_integer()
        ]

  @callback start_link(server_name, config :: map()) :: GenServer.on_start()
  @callback list_tools(server_name) :: {:ok, [tool_schema]} | {:error, reason, String.t()}
  @callback call(server_name, tool_name, args :: map(), call_opts) ::
              {:ok, json} | {:error, reason, String.t()}
  @callback stop(server_name) :: :ok
end
```

Invariants:

- `start_link/2` **MUST** complete the MCP handshake (`initialize`,
  `notifications/initialized`, `tools/list`) before returning `:ok`,
  or return `:error` with reason `:upstream_unavailable` and a detail
  string suitable for envelope reporting.
- `call/4` **MUST** enforce both `:timeout` and `:max_response_bytes`,
  rejecting oversized responses **before** JSON decode where the wire
  format permits.
- `call/4` **MUST NOT** raise; all failures are `{:error, reason, detail}`.
- `stop/1` **MUST** be idempotent.

### 6.4 `upstream_calls` collector

The MCP request handler is also the collector. Per `tools/call` request,
the worker process:

1. Constructs a `call_context` map at request start:

   ```elixir
   call_context = %{
     collector_pid: self(),
     collector_ref: make_ref(),
     call_counter: :counters.new(1, []),
     max_calls: Limits.max_upstream_calls_per_program(),
     call_timeout_ms: Limits.upstream_call_timeout_ms(),
     max_response_bytes: Limits.max_upstream_response_bytes()
   }
   ```

2. Registers `tool/mcp-call` in the tools registry passed to
   `Sandbox.execute/4`. The registration **MUST** capture the entire
   `call_context` in the closure — not the process dictionary, not
   ETS. `:counters` is concurrency-safe (`pmap` children incrementing
   in parallel never lose a count) and shares the worker's lifetime.
   The closure pseudocode:

   ```elixir
   fn args ->
     n = :counters.add(call_context.call_counter, 1, 1)
     if :counters.get(call_context.call_counter, 1) > call_context.max_calls do
       record_and_return_nil(call_context, args, :cap_exhausted, 0)
     else
       dispatch_upstream_call(call_context, args)
     end
   end
   ```

   Process dictionary is forbidden because `pmap` spawns child
   processes with empty dictionaries; ETS is forbidden because its
   lifetime exceeds the call and would require teardown bookkeeping.
3. The tool's executor, after each upstream call completes (success,
   error, timeout, or detach-on-cancel), sends:

   ```elixir
   send(collector_pid, {:upstream_call_recorded, collector_ref, entry})
   ```

   where `entry` is the map defined in §8.5.
4. When `Sandbox.execute/4` returns **with a value** (a successful
   program result, a `(fail v)`, or a caught Lisp/runtime error
   producing a normal error envelope), the worker drains its mailbox:

   ```elixir
   defp drain(ref, acc) do
     receive do
       {:upstream_call_recorded, ^ref, entry} -> drain(ref, [entry | acc])
     after
       0 -> Enum.reverse(acc)
     end
   end
   ```

   The unique ref **MUST** be matched explicitly; this prevents
   accidental drains of unrelated mailbox traffic and isolates each
   request even if process reuse is introduced later.
5. The worker decorates the structured payload (§8.3) with the
   drained list as `upstream_calls` before passing to
   `Envelope.success/1` or `Envelope.error_envelope/1`.

Drain ordering is mailbox arrival order, which equals upstream call
**completion order** because each call sends exactly once at
completion. With `pmap`, this gives the caller LLM enough timing
signal — combined with `duration_ms` — to reconstruct concurrency
behavior without an additional `started_at_ms` field.

**Cancellation is a separate path.** The collector is the worker
itself; on `notifications/cancelled` (or any other forced
termination), the worker is killed before it can drain or render an
envelope. Per MCP semantics no response is sent for a cancelled
request, so the absence of an envelope — and therefore the absence
of any final `upstream_calls` reporting — is correct. In-flight
upstream calls owned by the dying worker are detached at the
`Connection` level (§8.6); their late responses are dropped, no slot
leaks. Detached calls **MUST NOT** record `upstream_calls` entries
because no envelope exists to put them in.

Worker crash (an uncaught error in the request handler itself, not
a Lisp runtime error) follows the same cancellation path: no
envelope, no drain, JSON-RPC `-32603 Internal error` raised by the
top-level supervisor as in MCP v1.

## 7. Error Model

### 7.1 World-fault failures (return `nil`)

A world-fault failure **MUST**:

- Cause `(tool/mcp-call ...)` to evaluate to `nil` inside the program.
- Add an entry to `upstream_calls` with `status: "error"` and the
  documented reason.

| Failure | Reason |
|---|---|
| `ensure_started/1` failed (subprocess spawn error, `initialize` error, `notifications/initialized` rejected, or `tools/list` failure), or the upstream is currently in its post-crash recovery window | `upstream_unavailable` |
| Upstream returned a JSON-RPC error to a `tools/call` | `upstream_error` |
| Upstream call exceeded `upstream_call_timeout` | `timeout` |
| Upstream response exceeded `max_upstream_response_bytes` | `response_too_large` |
| Per-program upstream call cap exceeded | `cap_exhausted` |

`cap_exhausted` is world-fault, not programmer-fault. The LLM may
write `(pmap #(tool/mcp-call ...) urls)` over a runtime-sized list;
overshooting is a runtime condition, not a coding error. Crashing the
program would lose partial work. Calls past the cap return `nil`,
record `cap_exhausted`, and the calling LLM sees the saturation and
can retry with a smaller batch on the next turn.

### 7.2 Programmer-fault failures (raise)

A programmer-fault failure **MUST** raise a PTC-Lisp runtime error,
terminating the program. The runtime error message **MUST** identify
the call site.

| Failure | Error message |
|---|---|
| `:server` value is not present in the upstreams config | `no upstream '<name>' configured` |
| Unknown tool in known upstream (per §7.4) | `no tool '<tool>' in upstream '<server>'` |
| Args not JSON-encodable / wrong shape | `tool '<server>.<tool>' rejected args: <reason>` |

These are real defects the LLM should fix in the program rather than
work around. Programmer-fault failures **SHOULD** still be recorded in
`upstream_calls` if an upstream call was actually attempted (e.g., the
upstream rejected the args after PtcRunner sent them).

### 7.3 `nil` vs upstream JSON `null`

`[]` and `nil` are distinct in PTC-Lisp; an empty result list is
unambiguous. The genuine collision is an upstream that legitimately
returns JSON `null` as a successful payload — bare `nil` would be
indistinguishable from a world-fault.

Resolution:

- World-fault failures return Elixir `nil`.
- An upstream that returns JSON `null` as a **successful** payload
  comes back as the keyword sentinel `:json-null`.

The sentinel uses a hyphen, not a slash, because PTC-Lisp's keyword
parser disallows `/` in keyword names. Choosing `:json-null` keeps
the sentinel a plain valid keyword literal and avoids any analyzer
or parser changes — consistent with this spec's "no analyzer work in
v1" goal (§1).

Programs that don't care about the distinction treat the sentinel as
truthy and continue. Programs that care can compare `(= result
:json-null)`. The invariant `nil` ⇒ "this call did not succeed" is
preserved.

**Depth: top-level only.** The `:json-null` rewrite **MUST** apply
exclusively to the top-level value of an `{:ok, json}` upstream
response. Nested JSON `null`s inside maps or arrays — `{"a": null}`,
`[1, null, 3]` — remain Elixir `nil`. Once execution is inside a
successful payload, `nil` is just data; the only ambiguity worth
resolving is "did the call succeed" vs "did the call return null,"
and that ambiguity exists only at the top level.

Implementation rule for the executor: after `Upstream.call/4` returns
`{:ok, value}`, if `value === nil`, substitute `:json-null` before
handing the result back to the program. Do not walk the value.

### 7.4 Unknown-tool classification

Programmer-fault `no tool '<tool>' in upstream '<server>'` is raised
**only when both** of the following hold:

1. `<server>` is in `started_upstreams`.
2. `<server>`'s cached `tools/list` lacks `<tool>`.

Otherwise the call is classified as world-fault `upstream_unavailable`.
This is the only honest classification when the upstream cache cannot
prove the tool's absence. It naturally handles the lazy-spawn cold
start: the first call to an upstream that fails to spawn returns nil +
`upstream_unavailable`; subsequent calls to a known-bad tool on a
healthy upstream raise.

## 8. Wire Format

### 8.1 Tool advertisement description

In aggregator mode, `tools/list` advertises `ptc_lisp_execute` with a
description equal to:

```elixir
PtcRunnerMcp.Tools.advertised_description(:mcp_aggregator, catalog: catalog_string_or_nil)
```

For Phases 1a–2, `catalog: nil` is acceptable; the inline upstream
catalog is added in Phase 3 (§13.5).

The advertised description **MUST** include the authoring card text
documenting:

- The `(tool/mcp-call {:server :tool :args})` shape.
- The `nil` failure convention and the `:json-null` sentinel.
- The existence of `upstream_calls` in the response envelope.

### 8.2 Tool annotations

| Hint | `:mcp_no_tools` | aggregator mode |
|---|---|---|
| `readOnlyHint` | `true` | `false` |
| `destructiveHint` | `false` | `true` |
| `idempotentHint` | `true` | `false` |
| `openWorldHint` | `false` | `true` |

`destructiveHint` is `true` (not `false`, not omitted) in aggregator
mode. `false` would falsely claim safety when configured upstreams may
delete or mutate. `true` is the conservative worst-case advertisement
that lets clients gate destructive-action UX appropriately.

The annotation set is determined by `configured_aggregator_mode?/0`,
not by `started_upstreams/0`. A misconfigured run with zero healthy
upstreams **MUST** still advertise the aggregator annotations, because
the static contract — "this server can call upstream MCP tools" — has
not changed.

### 8.3 Response payload (structured)

The structured payload returned to the calling client **MUST** have
the v1 shape, plus an optional `upstream_calls` array:

```json
{
  "result": ...,
  "prints": [...],
  "validated": ...,
  "upstream_calls": [...]
}
```

`upstream_calls` **MUST** be omitted when empty.

The MCP request handler, not `PtcRunnerMcp.Envelope`, owns the
decoration. The decoration runs **after**
`PtcToolProtocol.render_success/2` (or `render_error/3`) builds the
v1 payload and **before** `Envelope.success/1` (or
`Envelope.error_envelope/1`) wraps it into `structuredContent` and the
mirrored text content. This keeps `PtcToolProtocol` and `Envelope`
unchanged in their function surface; the decoration is implemented
entirely in the request handler.

### 8.4 `outputSchema`

The advertised `outputSchema` is selected by
`configured_aggregator_mode?/0`:

- `:mcp_no_tools`: existing v1 schema, unchanged.
- aggregator mode: extends the v1 schema with an optional
  `upstream_calls` field, an array of objects matching §8.5.

A schema change is required so strict `structuredContent` validators
do not reject the new field.

### 8.5 `upstream_calls` entry shape

```json
{
  "server": "github",
  "tool": "search_repos",
  "status": "ok" | "error",
  "duration_ms": 420,
  "reason": "upstream_error" | "timeout" | "response_too_large" | "upstream_unavailable" | "cap_exhausted",
  "error": "404 Not Found"
}
```

Required fields: `server`, `tool`, `status`, `duration_ms`. `reason`
and `error` **MUST** be present iff `status: "error"`.

Ordering: completion order, per §6.4.

**`duration_ms` for non-call entries.** `duration_ms` **MUST** be a
non-negative integer (never `null`):

| Origin | `duration_ms` value |
|---|---|
| Successful upstream call | wall-clock `tools/call` duration |
| `upstream_error`, `timeout`, `response_too_large` | wall-clock `tools/call` duration up to the failure |
| `upstream_unavailable` from a failed `ensure_started/1` | wall-clock duration of the spawn + `initialize` + `notifications/initialized` + `tools/list` attempt |
| `upstream_unavailable` during recovery/backoff window with no attempt made | `0` |
| `cap_exhausted` | `0` |

The honest semantics are "time spent attempting the operation,"
including ensure-started overhead the caller paid for. Calls rejected
without any attempt (cap, recovery window) report `0`.

### 8.6 Cancellation propagation

When the outer `tools/call` is cancelled via `notifications/cancelled`
or the worker is killed for any other reason:

- The PTC-Lisp worker process is terminated.
- In-flight upstream requests owned by that worker are **detached**:
  the `Connection` cancels the pending caller, frees its slot, and
  drops the upstream's response on arrival.
- v1 **MUST NOT** send `notifications/cancelled` upstream. Most
  upstreams ignore it; detach-and-drop already solves the slot-leak
  concern. Forwarding cancellation upstream is deferred (§3).

## 9. Resource Limits

| Limit | Default (v1) | Default (aggregator) | CLI flag | Env var |
|---|---:|---:|---|---|
| `program_timeout` | 1 s | 10 s | `--program-timeout-ms` | `PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS` |
| `program_memory_limit` | 10 MB | 100 MB | `--program-memory-limit-bytes` | `PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES` |
| `upstream_call_timeout` | n/a | 5 s | `--upstream-call-timeout-ms` | `PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS` |
| `max_upstream_response_bytes` | n/a | 2 MB | `--max-upstream-response-bytes` | `PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES` |
| `max_upstream_calls_per_program` | n/a | 50 | `--max-upstream-calls-per-program` | `PTC_RUNNER_MCP_MAX_UPSTREAM_CALLS_PER_PROGRAM` |

| Limit | On exceed |
|---|---|
| `program_timeout` | tool result `timeout` |
| `program_memory_limit` | tool result `memory_limit` |
| `upstream_call_timeout` | nil + `timeout` |
| `max_upstream_response_bytes` | nil + `response_too_large` |
| `max_upstream_calls_per_program` | nil + `cap_exhausted` |

**Precedence (highest first):**

1. CLI flag (e.g., `--program-timeout-ms 5000`).
2. Environment variable (e.g., `PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS=5000`).
3. **Mode default** — aggregator default when
   `configured_aggregator_mode?/0` is true *and* no explicit value
   was provided; otherwise the v1 default.

Aggregator defaults **MUST NOT** override an explicit flag or env var.
A user who configures aggregator mode but sets `--program-timeout-ms
1000` gets 1 s, not the 10 s aggregator default.

Plain MCP v1 (no upstreams configured) remains fast and small by
default.

`max_upstream_response_bytes` **MUST** be enforced outside the
sandbox, before JSON-decoding the response into BEAM terms. A
program that holds many upstream results simultaneously must still
fit within `program_memory_limit`, but the runtime cannot be OOM'd
by an upstream returning a 100 MB blob.

## 10. Telemetry

Aggregator mode adds one event prefix to the v1 set:

| Event | Measurements | Metadata |
|---|---|---|
| `[:ptc_runner_mcp, :upstream, :call, :start]` | `system_time` | `request_id`, `server`, `tool`, `caller: :mcp`, `profile: :mcp_aggregator` |
| `[:ptc_runner_mcp, :upstream, :call, :stop]` | `duration` | `request_id`, `server`, `tool`, `status`, `reason?`, `caller: :mcp`, `profile: :mcp_aggregator` |
| `[:ptc_runner_mcp, :upstream, :call, :exception]` | `duration` | `request_id`, `server`, `tool`, `kind`, `reason`, `stacktrace`, `caller: :mcp`, `profile: :mcp_aggregator` |

`profile` is a metadata field, not a measurement. `caller:` **MUST
NOT** be widened beyond `:in_process_v1 | :text_mode | :mcp`; the
aggregator distinction lives entirely in `profile`.

Default metadata **MUST NOT** include raw upstream tool arguments or
raw upstream results. Operators who need to debug a broken upstream
opt in via the existing `trace_handler` / `trace_file` surfaces; the
default-off behavior protects production logs from client-data leakage.

## 11. MCP v1 Seams (Phase 0)

These changes land in MCP v1. They are option-preserving and have no
behavior change for non-aggregator users.

### 11.1 Description builder

`PtcRunnerMcp.Tools.advertised_description/0` already exists at
`mcp_server/lib/ptc_runner_mcp/tools.ex:115` and returns:

```elixir
PtcToolProtocol.tool_description(:mcp_no_tools) <> "\n\n" <> authoring_card()
```

Phase 0 **refactors** this to a profile-aware form:

```elixir
@spec advertised_description(profile :: atom(), opts :: keyword()) :: String.t()
def advertised_description(profile, opts \\ [])
```

For MCP v1, `tool_entry/0` calls
`advertised_description(:mcp_no_tools, catalog: nil)` and the output is
unchanged. The `opts` keyword is the seam aggregator mode will use
to inject runtime catalog text in Phase 3.

This **MUST NOT** require `PtcToolProtocol.tool_description/2` in
Phase 0; the profile-aware builder lives entirely in
`PtcRunnerMcp.Tools`. Promote to `PtcToolProtocol` only if a future
profile needs canonical-string-level catalog injection.

### 11.2 Tools registry plumbing

`PtcRunnerMcp.Sandbox.execute/4` already takes an `opts` keyword (it
currently carries `:link`). Phase 0 **MUST** add `:tools` (default
`[]`) to that same `opts` keyword and forward it to
`PtcToolProtocol.lisp_run/2`. **Do not introduce a fifth positional
argument.** The MCP request handler **MUST** thread the option through.

In MCP v1, the handler always passes `tools: []`. In aggregator mode,
the handler builds a registry containing the `mcp-call` virtual tool
(§6.2) with the collector closure (§6.4) before calling
`Sandbox.execute/4`.

### 11.3 Structured-payload decoration point

The MCP request handler is the decoration point for
`upstream_calls` (§8.3). Phase 0 **MUST** make the handler's
structured-payload construction visibly two-step:

1. Build v1 payload via `PtcToolProtocol.render_success/2` /
   `render_error/3`.
2. Wrap via `Envelope.success/1` / `Envelope.error_envelope/1`.

In Phase 0 the two steps run back-to-back with no decoration. In
Phase 1a the handler inserts the `upstream_calls` decoration between
them.

`PtcRunnerMcp.Envelope` and `PtcRunner.PtcToolProtocol` **MUST NOT**
gain new options for `upstream_calls` in Phase 0.

### 11.4 `outputSchema` extension point

`tool_entry/0` selects `outputSchema` by profile so aggregator mode
can advertise the extended schema (§8.4) without conditional logic
scattered through the codebase.

### 11.5 Telemetry profile metadata

v1 emits `caller: :mcp` in telemetry metadata; Phase 0 **MUST** also
emit `profile: :mcp_no_tools` in the metadata map (not measurements).
Aggregator mode flips `profile` to `:mcp_aggregator`. `caller:` stays
fixed.

### 11.6 Configurable program limits, defaults unchanged

v1 plumbs `--program-timeout-ms` and `--program-memory-limit-bytes`
flags (and their env-var equivalents per §9) with the existing 1 s /
10 MB defaults. Aggregator mode (Phase 1a) overrides the defaults
when `configured_aggregator_mode?/0` is true *and* no explicit value
was provided.

Phase 0 **MUST** wire only the v1 flags
(`--program-timeout-ms`, `--program-memory-limit-bytes`) and their env
vars; the aggregator-only limits (`--upstream-call-timeout-ms`,
`--max-upstream-response-bytes`, `--max-upstream-calls-per-program`)
land in Phase 1a where they are actually consumed.

### 11.7 Codex review gates

Each phase **MUST** pass an independent `codex review` check on its
diff before merge. The gate is a hard fail/pass; do not proceed to the
next phase on a failing review without resolving the findings.

| Gate | Trigger | Reviewer asks |
|---|---|---|
| Phase 0 | Pre-merge of the v1 seams diff | Are the seams option-preserving? Does `tools/list` byte-equal v1? Does telemetry now carry `profile: :mcp_no_tools`? Are flag/env names exactly as §11.6 specifies? |
| Phase 1a | Pre-merge of `Upstream.Fake` + integration | Is the `:counters`-based per-program cap correct under `pmap`? Is `ensure_started/1` actually serialized per name? Is `:json-null` rewrite top-level only? Are non-call `duration_ms` values per §8.5? Does cancellation detach without slot leaks? Aggregator annotations per §8.2? |
| Phase 1b | Pre-merge of `Upstream.Stdio` | Handshake order (`initialize` → `notifications/initialized` → `tools/list`)? Pre-decode size enforcement? Subprocess crash → supervisor restart with backoff? Behaviour conformance suite passing on both Fake and Stdio? |
| Phase 2 | Pre-merge of swap + live integration | Real upstream test passes; full file content does not appear in MCP response; cancellation detaches real in-flight upstream requests. |

Invocation (from the repo root):

```
/codex review
```

The reviewer is intentionally not given the spec; it works from the
diff and the codebase only, providing an independent read on whether
the implementation matches what a careful engineer would expect.

## 12. Implementation Phases

The phase plan **separates the integration surface from the protocol
mechanics**. The integration surface (tools registry, collector,
envelope, schema, error model) is the novel work and lands first
against an in-process fake. The stdio MCP client lifecycle, which is
well-understood protocol mechanics, lands next against mock subprocess
upstreams. Phase 2 is then a swap with no shape changes.

### 12.1 Phase 0 — MCP v1 seams

Per §11. Lands in v1.

DoD:

- Existing MCP `tools/list` and `ptc_lisp_execute` calls remain
  byte-for-byte unchanged.
- `Sandbox.execute(..., tools: [])` behaves identically to current MCP
  execution.
- Telemetry emits `caller: :mcp, profile: :mcp_no_tools`.
- `tool_entry/0` sources `outputSchema` and description via
  profile-aware functions (with v1 profile values).

### 12.2 Phase 1a — Upstream behaviour + Fake + integration

This phase validates the integration surface end to end **without**
stdio subprocess management.

Scope:

- Define the `PtcRunnerMcp.Upstream` behaviour (§6.3).
- Implement `PtcRunnerMcp.Upstream.Fake` — an in-process implementation
  whose `call/4` runs configured Elixir functions returning
  `{:ok, json}` / `{:error, reason, detail}`. Used in tests and in the
  Phase 1a wiring path.
- Add `PtcRunnerMcp.Upstream.Registry` and `Supervisor`.
- Implement `configured_aggregator_mode?/0` and `started_upstreams/0`.
- Wire `tool/mcp-call` (§6.2) into the tools registry the MCP handler
  passes to `Sandbox.execute/4`.
- Implement the collector contract (§6.4): unique ref, send/drain,
  decoration of structured payload (§8.3), extended `outputSchema`
  (§8.4) when in aggregator mode.
- Implement the world-fault / programmer-fault error split (§7),
  including `:json-null`, `cap_exhausted`, and the unknown-tool rule
  (§7.4).
- Apply aggregator-mode resource limits (§9) and tool annotations
  (§8.2).
- Emit `[:ptc_runner_mcp, :upstream, :call, :*]` telemetry (§10) with
  default-off payload capture.
- Cancellation: detach in-flight upstream calls owned by a dying
  worker; drop late responses; no slot leaks (§8.6). For
  `Upstream.Fake`, "detach-equivalent" semantics are sufficient:
  fake calls run in spawned tasks/processes with caller refs; when
  the worker dies, the registry/connection drops ownership and any
  late fake reply is ignored. **Fake call functions need not be
  forcibly killed in Phase 1a.** The invariants that **MUST** hold:
  no slot leak, no stale `upstream_calls` entry written, and no
  effect on a subsequent request (the unique `collector_ref` check
  in §6.4 step 4 enforces the last point).
- Registry serialization: per §4.1, `Upstream.Registry` **MUST**
  serialize `ensure_started/1` per upstream name. Concurrent `pmap`
  branches targeting the same not-yet-started upstream observe
  exactly one spawn attempt; subsequent waiters reuse its result.

DoD:

- A PTC-Lisp program calling `(tool/mcp-call {:server "fake-x" :tool
  "search" :args {...}})` runs end-to-end through the MCP server,
  using `Upstream.Fake`. The result is returned to the calling client
  as a v1 payload decorated with `upstream_calls`.
- All §13 Phase 1a tests pass against `Upstream.Fake`.
- `tools/list` output (description, annotations, `outputSchema`)
  matches §8 in aggregator mode.
- `:mcp_no_tools` mode produces output byte-for-byte identical to v1.

### 12.3 Phase 1b — Stdio implementation

This phase implements `PtcRunnerMcp.Upstream.Stdio` against the same
behaviour, validating MCP client protocol mechanics in isolation.

Scope:

- Spawn one configured upstream subprocess via `Port`.
- JSON-RPC framing/codec — reuse `PtcRunnerMcp.JsonRpc` helpers where
  they fall out naturally; do **not** block on a JSON-RPC refactor.
- MCP handshake: `initialize`, `notifications/initialized`,
  `tools/list`. The `notifications/initialized` step is normative; some
  upstreams reject calls until they receive it.
- `tools/call` request/response correlation by JSON-RPC id.
- Per-call timeout and `max_response_bytes` enforcement (latter
  pre-decode where the wire format permits).
- Subprocess crash detection and supervisor-mediated restart with
  exponential backoff (cap 30 s).
- Clean shutdown via stdin EOF.
- A `MockServer` test fixture that speaks MCP for unit tests.

DoD:

- Mock upstream initialize → notifications/initialized → list → call
  happy path passes.
- Timeout, oversized response, JSON-RPC error, subprocess crash, and
  shutdown paths each have a test.
- `Upstream.Stdio` passes the same suite of behaviour conformance
  tests as `Upstream.Fake`.

### 12.4 Phase 2 — Swap and integrate

Scope:

- The MCP server selects between `Upstream.Fake` (in tests) and
  `Upstream.Stdio` (in production) at the `Registry` level, based on
  config or test setup.
- Live integration tests against at least two real upstream MCP
  servers (e.g., `@modelcontextprotocol/server-filesystem` plus one
  other).
- No shape changes to the integration surface; the swap is mechanical
  if both impls honor the behaviour contract.

DoD:

- Real-upstream end-to-end test: a PTC-Lisp program reads a file via
  filesystem-mcp, transforms the result, returns the transformed
  value. The full file content does not appear in the MCP response.
- Phase 2 decision-point inputs (§14) are collected.

### 12.5 Phase 3 — Config ergonomics + catalog (post-decision)

Conditional on Phase 2 decision-point results.

Scope (subject to revision):

- Inline upstream catalog in the `ptc_lisp_execute` description.
  Catalog format: one entry per upstream tool, one line each, in the
  shape `tool_name(arg: type, arg: type?) - description`. Args are
  rendered from the upstream's JSON Schema with optional fields
  marked `?` and complex types abbreviated. Descriptions are
  truncated at 80 characters. Example:

  ```
  github:
    search_repos(query: string, limit: integer?) - Search repositories
    get_pr(owner: string, repo: string, number: integer) - Get a pull request

  linear:
    list_tickets(status: string?, project: string?) - List Linear tickets
  ```

  The catalog is generated at startup from each upstream's
  `tools/list` response (cached per §6.3) and rebuilt only on
  PtcRunner restart.
- Improved error messages, examples, docs.

Out of scope until evidence justifies them:

- MCP resource publishing for the catalog.
- `expose_natively: true` per-upstream flag (native exposure).
- `mcp/<server>` PTC-Lisp namespace syntax.
- Claude Desktop config auto-import.

## 13. Testing Requirements

### 13.1 Phase 0

- Existing MCP `tools/list` output unchanged.
- Existing `ptc_lisp_execute` calls unchanged.
- `Sandbox.execute(..., tools: [])` behaves identically to current MCP
  execution.
- Telemetry metadata contains `caller: :mcp, profile: :mcp_no_tools`.
- `advertised_description(:mcp_no_tools, catalog: nil)` returns the
  same string as the current `advertised_description/0`.

### 13.2 Phase 1a (against `Upstream.Fake`)

- `(tool/mcp-call ...)` dispatches to the right fake upstream.
- First call to a configured upstream invokes `ensure_started/1`,
  which adds the upstream to `started_upstreams` on success;
  subsequent calls in the same program skip `ensure_started/1`.
- `:server` not in the upstreams config → programmer-fault runtime
  error (raised before `ensure_started/1` is attempted).
- Unknown tool on a started upstream (cache hit but tool absent) →
  programmer-fault runtime error.
- Unknown tool on an upstream whose `ensure_started/1` fails →
  world-fault `nil` + `upstream_unavailable` (per §7.4); the tool's
  absence is unverifiable and **MUST NOT** be classified as
  programmer-fault.
- Subsequent call to an upstream whose `ensure_started/1` already
  failed in this program → world-fault `nil` + `upstream_unavailable`
  with the same detail message; no retry within the same program.
- JSON-non-encodable args raise programmer-fault before upstream call.
- Fake upstream `:upstream_error` → `nil` + entry with reason
  `upstream_error`.
- Fake `:timeout` → `nil` + reason `timeout`.
- Fake `:response_too_large` → `nil` + reason `response_too_large`.
- Successful return of JSON `null` → `:json-null` (not `nil`); entry
  with `status: "ok"`.
- Per-program upstream call cap: pre-budget calls succeed; over-budget
  calls return `nil` + reason `cap_exhausted`.
- `pmap` over delayed fake calls completes concurrently at the
  upstream-behaviour call layer (the Fake's `call/4` runs in parallel
  worker processes); entries appear in completion order. "Transport
  layer" wording is reserved for Phase 1b/Stdio.
- Outer `tools/call` cancellation detaches in-flight fake calls; no
  slot leak; messages received after cancellation do not affect a
  subsequent call (unique ref check).
- `upstream_calls` field appears in `structuredContent` and in the
  mirrored text content; advertised `outputSchema` accepts it.
- Aggregator-mode tool annotations match §8.2.
- `configured_aggregator_mode?/0` is true with at least one upstream
  configured, regardless of `started_upstreams/0`.
- Non-aggregator (no config) mode behaves as Phase 0.

### 13.3 Phase 1b (against `Upstream.Stdio` + mock subprocess)

- Initialize → notifications/initialized → tools/list → tools/call
  happy path.
- Subprocess that does not accept calls until
  notifications/initialized is sent: PtcRunner's handshake satisfies
  it.
- JSON-RPC error from upstream → `{:error, :upstream_error, _}`.
- Per-call timeout enforced; oversized response rejected before
  decode where wire format permits.
- Subprocess crash mid-call → caller receives
  `{:error, :upstream_unavailable, _}`; supervisor restarts with
  backoff; subsequent call succeeds.
- Graceful shutdown closes subprocess via stdin EOF.
- `Upstream.Stdio` passes the same behaviour conformance suite as
  `Upstream.Fake`.

### 13.4 Phase 2 (integration)

- Real upstream end-to-end test (filesystem-mcp + one other).
- Cancellation of outer `tools/call` detaches real in-flight upstream
  requests.
- Token-cost benchmark vs naive multi-call orchestration.

## 14. Decision Point After Phase 2

Before continuing to Phase 3 or revisiting deferred features (§3),
collect:

1. **Token comparison**: native multi-call MCP workflow vs single
   `ptc_lisp_execute` aggregator call on a representative cross-server
   workload.
2. **Program success rate**: can the calling LLM reliably write
   correct `(tool/mcp-call ...)` programs from the catalog?
3. **Latency**: sequential vs `pmap` upstream calls.
4. **Failure clarity**: does `upstream_calls` give the calling LLM
   enough information to recover (retry, narrow, surface)?
5. **`nil` ergonomics (hypothesis under test)**: did the calling LLM
   reliably write `(when result ...)` and `(remove nil? ...)`
   patterns, or did programs misinterpret `nil` as "empty result" and
   proceed incorrectly? The `nil`-signal model is a chosen tradeoff
   for v1; if misinterpretation rates are material, revisit
   `{:ok/:error}` maps or per-call sentinel values **before**
   broadening the feature.
6. **Client behavior**: do target MCP clients handle the inline
   catalog (Phase 3) and `upstream_calls` envelope without rejecting
   the `outputSchema`?

Promote the aggregator to broader implementation only if these
results show a meaningful advantage.

## 15. Positioning

The aggregator is not an agent framework. It is a programmatic
tool-calling primitive: one LLM-authored, sandboxed PTC-Lisp program
calls upstream MCP tools and deterministically composes their results.

Best fit:

- ad-hoc cross-server joins,
- filtering large tool outputs,
- reducing context pressure,
- deterministic transforms over upstream results.

Poor fit:

- workflows requiring model judgment between tool calls,
- mature repeated workflows better written as maintained application
  code,
- setups needing broad MCP gateway features from day one.

Honest weaknesses:

- Workflows requiring model judgment between tool calls force
  multi-turn use of `ptc_lisp_execute`.
- Reliability for high-volume production workflows: a hand-written
  orchestrator beats LLM-generated PTC-Lisp at the 1000th run.
- Tool catalog token cost when configured with many upstreams; the
  inline format (Phase 3) bounds it but does not eliminate it.

## 16. Open Questions

- Catalog inline vs as MCP resource: defer to Phase 3. The decision
  hinges on which production clients meaningfully expose resources to
  the model; data lives in §14.6.
- Upstream tool description filtering: truncate at 80 chars; otherwise
  pass through. Revisit if upstream descriptions degrade prompt
  quality.
- Schema cache vs upstream restart: log a warning if `tools/list` on
  reconnect differs from cache; keep the original cache to avoid
  mid-flight schema drift. Schema changes require PtcRunner restart.
- Per-upstream in-flight concurrency cap: not in v1. `pmap` over many
  calls to one upstream may overwhelm it; document as the user's
  concern (narrower queries, sequential `map`).
- Schema-to-PTC-Lisp signature mapping for upstream tools: not in v1;
  upstream schemas are passed through as opaque description text.

## 17. Document History

- 2026-05-08: Promoted from discussion draft to specification.
  Integrated review items: aggregator-mode predicate split, collector
  protocol with unique ref, structured-payload decoration owned by
  handler, completion-order ordering, `cap_exhausted` as world-fault,
  JSON-null sentinel, unknown-tool rule against healthy cache,
  `notifications/initialized` in handshake, aggregator-mode tool
  annotations (`destructiveHint: true`), `nil` ergonomics as
  measurable hypothesis. Restructured phases as 0 / 1a / 1b / 2 / 3
  with `PtcRunnerMcp.Upstream` behaviour as the integration contract.
- 2026-05-08 (post-review): Tightened lazy-spawn classification — a
  configured-but-not-yet-started upstream attempts `ensure_started/1`
  rather than returning `upstream_unavailable` on sight. Defined
  `ensure_started/1` and re-cast §7.1 around it. Scoped the collector
  drain to normal completion and caught Lisp errors only; cancelled
  or crashed workers send no envelope and record no
  `upstream_calls`. Renamed sentinel `:json/null` → `:json-null` to
  satisfy the PTC-Lisp keyword parser without analyzer changes.
  Aligned `Envelope.error/1` references to the actual
  `Envelope.error_envelope/1`. Replaced the tautological "unknown
  configured upstream" wording. Redefined "started upstream" as
  *currently* healthy (not "succeeded at least once"). Replaced
  Phase 1a "transport layer" framing with "upstream-behaviour call
  layer." Inlined the Phase 3 catalog format example so the
  specification is self-contained.
- 2026-05-08 (impl-prep): Pinned the implementation contract for
  Phase 0/1a so a subagent can execute without further questions.
  Added: per-name serialization of `ensure_started/1` by
  `Upstream.Registry` (§4.1); test-only fake registration via the
  Registry API — JSON `"fake"` field forbidden (§5.4); explicit
  `call_context` map with closure-captured `:counters.new(1, [])`
  for the per-program cap (§6.4); top-level-only `:json-null` rewrite
  with no value walking (§7.3); pinned `duration_ms` values for
  non-call entries — measured for `ensure_started` failures, `0` for
  cap and recovery-window rejections (§8.5); pinned CLI-flag and
  env-var names with explicit precedence (CLI > env > mode default)
  and a "no override of explicit values" rule (§9, §11.6); reaffirmed
  `:tools` lives in the existing `Sandbox.execute/4` opts keyword,
  not a new positional (§11.2); added §11.7 codex-review gates per
  phase; spelled out Phase 1a Fake cancellation as detach-equivalent
  with no requirement to kill the fake function (§12.2); added §18
  pasteable subagent briefs.

## 18. Subagent Implementation Notes

This section exists so each phase can be handed to an Engineer
subagent as a single self-contained brief. Each block lists files
to touch, the behavioral contract, the verification commands, and
the codex gate. Subagents **MUST** treat the linked sections as
authoritative; this section does not redefine semantics.

### 18.1 Phase 0 brief

**Goal:** land MCP v1 seams (no behavior change, no upstream
machinery).

**Files to modify:**

- `mcp_server/lib/ptc_runner_mcp/tools.ex` — refactor
  `advertised_description/0` to `advertised_description(profile,
  opts \\ [])` per §11.1; route `tool_entry/0` through it. Make
  `outputSchema` profile-selectable (§11.4); for `:mcp_no_tools`,
  return the existing schema unchanged.
- `mcp_server/lib/ptc_runner_mcp/sandbox.ex` — accept `:tools` in
  the existing opts keyword (default `[]`) and forward to
  `PtcToolProtocol.lisp_run/2` via `lisp_run_opts/2` (§11.2). Do
  **not** add a fifth positional arg.
- `mcp_server/lib/ptc_runner_mcp/limits.ex` — add
  `program_timeout_ms` and `program_memory_limit_bytes` storage
  (defaults: 1000 / 10 \* 1024 \* 1024), readable via convenience
  getters.
- The MCP startup path (CLI parser / `Application.start/2`) — wire
  `--program-timeout-ms` / `--program-memory-limit-bytes` flags and
  the matching env vars into `Limits.set/1`. Precedence per §9.
- The MCP request handler (in `tools.ex` or wherever the
  structured payload is built) — make the construction visibly
  two-step per §11.3: build v1 payload via
  `PtcToolProtocol.render_success/2` / `render_error/3`, then wrap
  via `Envelope.success/1` / `Envelope.error_envelope/1`. No
  decoration in Phase 0.
- Telemetry call sites that currently emit `caller: :mcp` — also
  emit `profile: :mcp_no_tools` in the metadata map (§11.5). Do
  **not** widen `caller:`.

**Files to add:** none. Phase 0 is purely additive within existing
modules.

**DoD (verbatim §12.1):**

- Existing MCP `tools/list` and `ptc_lisp_execute` calls remain
  byte-for-byte unchanged.
- `Sandbox.execute(..., tools: [])` behaves identically to current
  MCP execution.
- Telemetry emits `caller: :mcp, profile: :mcp_no_tools`.
- `tool_entry/0` sources `outputSchema` and description via
  profile-aware functions (with v1 profile values).

**Verify:**

```
cd mcp_server && mix format --check-formatted && mix compile --warnings-as-errors && mix test
```

Plus a snapshot test: assert
`Tools.advertised_description(:mcp_no_tools, catalog: nil)` equals
the string the existing `advertised_description/0` returns
pre-refactor (capture the string in a fixture before editing).

**Codex gate:** §11.7 row "Phase 0".

### 18.2 Phase 1a brief

**Goal:** integration surface against `Upstream.Fake` — collector,
envelope decoration, error model, limits, telemetry, cancellation.
No stdio.

**Files to add:**

- `mcp_server/lib/ptc_runner_mcp/upstream.ex` — behaviour per §6.3.
- `mcp_server/lib/ptc_runner_mcp/upstream/fake.ex` — in-process
  impl. Configurable `call/4` returning `{:ok, json}` /
  `{:error, reason, detail}` per test setup.
- `mcp_server/lib/ptc_runner_mcp/upstream/registry.ex` — GenServer
  routing `name -> {impl, pid}`. **Serializes `ensure_started/1`
  per name** (§4.1). Test API: `put_fake/2` and an `upstreams:`
  start option (§5.4). **No JSON pollution.**
- `mcp_server/lib/ptc_runner_mcp/upstream/supervisor.ex` —
  `one_for_one` over Connection processes; exponential backoff cap
  30 s on restart.
- `mcp_server/lib/ptc_runner_mcp/upstream_calls.ex` — collector
  helpers per §6.4.
- A `tool/mcp-call` virtual-tool builder — closure capturing the
  `call_context` from §6.4 (`:counters.new(1, [])`, collector ref,
  limits). Lives wherever the request handler builds the tools
  registry.

**Files to modify:**

- `tools.ex` — when `configured_aggregator_mode?/0` is true:
  switch description, annotations (§8.2: `destructiveHint: true`),
  and `outputSchema` (§8.4) to the aggregator profile; build the
  `mcp-call` tools registry and pass it through `Sandbox.execute`'s
  `:tools` opt.
- The MCP request handler — between `PtcToolProtocol.render_*` and
  `Envelope.*`, drain `{:upstream_call_recorded, ^ref, entry}`
  messages (§6.4 step 4) and decorate the structured payload with
  `upstream_calls` (§8.3). Drain only on normal completion or a
  caught Lisp/runtime error producing an envelope; cancellation /
  worker crash skips the drain (§6.4).
- `application.ex` — start the new `Upstream.Supervisor` /
  `Upstream.Registry` only when `configured_aggregator_mode?/0` is
  true.
- `limits.ex` — add `upstream_call_timeout_ms`,
  `max_upstream_response_bytes`, `max_upstream_calls_per_program`
  with their flags/env vars per §9. Aggregator-mode defaults apply
  only when no explicit value was provided.
- Telemetry — emit `[:ptc_runner_mcp, :upstream, :call, :*]` per
  §10. **Default-off payload capture:** raw upstream args / results
  **MUST NOT** appear in default metadata.

**Behavioral musts:**

- §7 error split exactly as written (world vs programmer fault).
- §7.4 unknown-tool rule (cache-prove only, lazy-spawn-friendly).
- `:json-null` substitution **top-level only** (§7.3): if and only
  if the upstream's `{:ok, value}` has `value === nil`, return
  `:json-null` to the program. Do not recurse.
- Per-program cap via `:counters` captured in the closure, not
  process dictionary, not ETS (§6.4).
- `duration_ms` values per §8.5 table for every entry kind.
- Aggregator tool annotations per §8.2 (driven by
  `configured_aggregator_mode?/0`, **not** `started_upstreams/0`).
- Cancellation: detach in-flight fakes; no slot leaks; no stale
  `upstream_calls`. Killing the fake function itself is **not**
  required in Phase 1a (§12.2).

**DoD (verbatim §12.2):**

- A PTC-Lisp program calling `(tool/mcp-call {...})` runs E2E
  through the MCP server using `Upstream.Fake`; the calling client
  sees a v1 payload decorated with `upstream_calls`.
- All §13.2 tests pass.
- `tools/list` (description, annotations, `outputSchema`) matches
  §8 in aggregator mode.
- `:mcp_no_tools` mode produces output byte-for-byte identical to
  Phase 0.

**Verify:**

```
cd mcp_server && mix format --check-formatted && mix compile --warnings-as-errors && mix test
```

**Codex gate:** §11.7 row "Phase 1a".

### 18.3 Phase 1b brief

**Goal:** `Upstream.Stdio` against the same behaviour, validated
against `MockServer`. Scope per §12.3; verify per §13.3.

**Codex gate:** §11.7 row "Phase 1b".

### 18.4 Phase 2 brief

**Goal:** swap Fake → Stdio at Registry level for production; live
integration tests against ≥ 2 real upstream MCP servers. Scope per
§12.4; verify per §13.4. Collect §14 decision-point inputs.

**Codex gate:** §11.7 row "Phase 2".

### 18.5 General subagent rules

- **Stay inside the spec.** If the spec is ambiguous, stop and ask;
  do not invent semantics.
- **Tests first for new behavior.** Per
  `docs/guidelines/testing-guidelines.md`, write a failing
  integration test before fixing or implementing a behavior the
  spec mandates.
- **`mix precommit` before push.** Format + compile + credo +
  dialyzer + test must all pass.
- **Backward compatibility is not a goal** (per `CLAUDE.md`).
  Delete superseded code rather than deprecate.
- **No analyzer/parser changes in v1.** The spec is calibrated to
  avoid them; if the implementation seems to need one, that is a
  signal to re-read the spec, not to add the change.
