# PtcRunner MCP Server

`ptc_runner_mcp` is a long-running process that speaks
[Model Context Protocol](https://modelcontextprotocol.io/) over stdio
JSON-RPC by default, with an opt-in Streamable HTTP listener for
private-network deployments. It exposes `lisp_eval` to MCP
clients (Claude Desktop, Cursor, Cline, Claude Code, MCP Inspector,
agentic applications, …). The tool
accepts a PTC-Lisp program plus optional `context` and `output_schema`,
runs it in an isolated BEAM sandbox, and
returns a structured result.

The server has no LLM of its own. The MCP client's LLM does the
reasoning; PtcRunner is invoked only when deterministic computation is
useful — counting, filtering, JSON shape validation, schema-driven
extraction. State does not persist between calls; each `tools/call` is
independent unless the server is started with the optional session
tools enabled.

Several capabilities are opt-in and add their own top-level tools:

- [Aggregator mode](aggregator-mode.md) lets PTC-Lisp programs call
  configured upstream MCP servers via `(tool/mcp-call ...)`.
- [Agentic mode](agentic-mode.md) adds `lisp_task`, a
  natural-language task tool backed by a planner LLM (requires
  aggregator mode).
- [Stateful sessions](#stateful-sessions) add `lisp_session_*` tools
  that persist `(def ...)` bindings, the last three results, and
  bounded history.
- [`lisp_debug`](mcp-debug.md) exposes in-process telemetry rollups
  for diagnostics.

`lisp_eval` itself is rendered through one of three
[response profiles](mcp-server-configuration.md#response-profiles)
(`slim` / `structured` / `debug`), defaulting to `slim`.
Those profiles also control client-facing output limits for prints,
feedback, schema-validated values, and final envelope size. Oversized
validated values are exact-or-absent: the server omits `validated` and
returns `validated_preview`, `validated_bytes`, and
`output_truncated` metadata instead of putting a partial value under
`validated`.

This document is the conceptual overview. For install + client
configuration, see [`mcp_server/README.md`](../mcp_server/README.md);
for every flag and environment variable, see
[`docs/mcp-server-configuration.md`](mcp-server-configuration.md). For
HTTP deployment, see
[`docs/mcp-server-http-deployment.md`](mcp-server-http-deployment.md). For
the PTC-Lisp language itself, see
[`docs/ptc-lisp-specification.md`](ptc-lisp-specification.md).

## When to use it

Reach for the MCP server when the calling LLM needs deterministic
compute and you want that capability available across MCP clients —
not just from Elixir.

Concrete cases:

- **Counting that LLMs get wrong.** The classic "how many `r`s in
  `raspberry`" failure mode. A two-line PTC-Lisp program counts
  reliably; the LLM consumes the result.
- **Arithmetic over data the LLM has already seen.** Sum a list of
  order totals, average a column, compute a percentile — without
  trusting the model's mental math.
- **JSON shape validation.** Pass an `output_schema` to assert the
  result is `{count :int, sum :int}`; on mismatch the response
  carries a `validation_error` the model can self-correct from.
- **Schema-validated extraction.** Filter a JSON array down to
  records matching some condition and return them as a typed,
  programmatic value the calling client can consume directly.
- **Cross-server orchestration.** With [aggregator
  mode](aggregator-mode.md) on, one PTC-Lisp program can fan out to
  several configured upstream MCP servers, reduce the results, and
  return the collapsed answer — typically an order of magnitude fewer
  bytes than the LLM doing the same work N round-trips at a time.
- **Filtering or reshaping a structured payload** that already lives
  in the conversation. A small PTC-Lisp program is cheaper and more
  reliable than a long natural-language transformation.

It is **not** the right fit when the work needs filesystem access or
direct network access. PTC-Lisp programs have none of those, by
construction. If the work needs REPL-like memory across calls, the MCP
server can optionally expose stateful PTC-Lisp session tools.

## Comparison with Python / JS execution servers

Other "code interpreter" MCP servers exist. Most run Python or
JavaScript inside a container or a process sandbox. The trade-offs
look like this:

| Concern | `ptc_runner_mcp` | Python-exec server | JS-exec server |
|---|---|---|---|
| Sandboxing | BEAM process, no I/O, no FS, no net (by construction) | Container or `seccomp` (operator-configured) | Container, VM2, or `vm` module (operator-configured) |
| Authoring overhead for the LLM | Zero — every program is a self-contained expression | Imports, virtualenv awareness, library knowledge | `require`, `import`, package availability |
| Schema validation of the return value | First-class — `output_schema` JSON Schema, structured `validated` payload | None (server returns raw stdout / repr) | None (server returns raw value or `JSON.stringify`) |
| Stable wire format | Yes — same R22/R23 contract as in-process PtcRunner | None standardized | None standardized |
| Network access from the program | None directly — opt-in only via configured upstream MCP servers in [aggregator mode](aggregator-mode.md) | Often available unless the operator sandboxes harder | Often available unless the operator sandboxes harder |
| Filesystem access from the program | None directly — opt-in only via filesystem-MCP upstreams in [aggregator mode](aggregator-mode.md) | Often available unless the operator sandboxes harder | Often available unless the operator sandboxes harder |
| Install footprint | Single Mix release (BEAM + ERTS bundled) | Python + interpreter + libs + sandbox tooling | Node + sandbox tooling |
| Concurrency model | Per-call BEAM process, semaphore-bounded | Process-per-call (typical) or threadpool | Worker-per-call or single-loop |
| Default resource caps | 1 s wall-clock, 10 MB memory, 64 KB program, 4 MB context, 8 concurrent (aggregator mode raises the per-program caps to 10 s / 100 MB) | Operator-defined | Operator-defined |

The PtcRunner pitch in one line: **the sandbox is the language, not
the deployment**. Other servers ship a general-purpose interpreter and
ask the operator to lock it down. PtcRunner ships an interpreter that
cannot leak in the first place.

## Architecture

```
                       MCP client (Claude Desktop, Cursor, Cline, …)
                       or trusted private-network HTTP client
                                    │  stdio NDJSON or Streamable HTTP
                                    ▼
                  ┌─────────────────────────────────────────┐
                  │              ptc_runner_mcp             │
                  │                                         │
                  │   Stdio transport or HTTP session        │
                  │              │                          │
                  │              ▼                          │
                  │   JSON-RPC dispatcher                   │
                  │   (initialize, tools/list,              │
                  │    tools/call, notifications/cancelled, │
                  │    shutdown, exit)                      │
                  │              │                          │
                  │              ▼                          │
                  │   Per-call worker  ◄── concurrency      │
                  │   process              semaphore        │
                  │              │                          │
                  │              ▼                          │
                  │   PtcToolProtocol.lisp_run/2            │
                  │              │                          │
                  └──────────────┼──────────────────────────┘
                                 ▼
                       :ptc_runner library
                       │
                       ▼
              PtcRunner.Sandbox
              (isolated BEAM process,
               1 s wall-clock, 10 MB heap)
                       │
                       ▼
              PtcRunner.Lisp.Eval
              (PTC-Lisp interpreter:
               Clojure subset + java.time +
               clojure.string, clojure.set,
               clojure.walk)
```

Each `tools/call` request flows top-to-bottom:

1. The transport frames one JSON-RPC message and hands it to the
   dispatcher. In stdio mode that is one NDJSON line; in HTTP mode it
   is one `POST /mcp` body scoped by `MCP-Session-Id`.
2. The dispatcher routes `tools/call` to a per-call worker after
   passing the concurrency semaphore (`max_concurrent_calls`,
   default 8). Excess calls return immediately with `reason: "busy"`
   instead of queuing.
3. The worker validates `program` / `context` / `output_schema`, builds fresh `Lisp.run/2` opts (empty memory,
   empty tool cache, no journal reuse), and invokes
   `PtcToolProtocol.lisp_run/2`.
4. `:ptc_runner` runs the program in an isolated BEAM process with a
   1 s wall-clock cap and a 10 MB heap cap (10 s / 100 MB in
   aggregator mode). Filesystem and network APIs are not exposed to
   the program; aggregator-mode programs reach out only through the
   mediated `(tool/mcp-call …)` builtin.
5. The result flows back up: `PtcToolProtocol.render_success_from_step/2`
   builds the R22 success payload, or `render_error/3` builds the R23
   error payload. The MCP envelope (`isError`, `structuredContent`,
   `content`) wraps it. The transport writes one response frame back.

`notifications/cancelled` from the client kills the in-flight sandbox
process. stdin EOF cancels every stdio in-flight call and exits
cleanly; HTTP `DELETE /mcp` closes one protocol session and cancels its
in-flight work.

## Streamable HTTP

Start with `--http` to serve MCP over Streamable HTTP at `/mcp`
(`127.0.0.1:7332` by default). `POST /mcp` accepts one JSON-RPC
message. `GET /mcp` returns `405` until SSE/resumability support is
added. `DELETE /mcp` terminates the protocol session named by
`MCP-Session-Id`.

HTTP mode is designed for private-network service deployment behind a
TLS edge or load balancer. It requires a bearer token for non-loopback
binds, validates browser `Origin` headers, exposes unauthenticated
`/health` and `/ready`, and stamps request logs/telemetry/traces with
hashed owner/session ids. See
[`mcp-server-http-deployment.md`](mcp-server-http-deployment.md).

## Stateful Sessions

By default, `lisp_eval` is stateless: every call starts with
empty Lisp memory and an empty tool cache. Starting the server with
`--sessions` or `PTC_RUNNER_MCP_SESSIONS=true` adds explicit session
tools:

- `lisp_session_start`
- `lisp_session_eval`
- `lisp_session_inspect`
- `lisp_session_list`
- `lisp_session_forget`
- `lisp_session_close`

Session evals persist explicit `(def ...)` and `(defn ...)` bindings,
the last three successful eval results (`*1`, `*2`, `*3`), captured
`println` output, and bounded/redacted tool-call history. `let`
bindings and ordinary intermediate values do not persist. Use
`lisp_session_forget` to remove stale or large bindings and clear
bounded histories.

`lisp_session_list` returns metadata-only live sessions for the current
owner. It does not render stored binding values or refresh session idle
timers.

Sessions are in-memory, owner-scoped, disabled by default, TTL/idle
bounded, and allow at most one eval in a given session at a time.
`lisp_session_eval` uses the same global concurrency gate as
`lisp_eval`; a second eval on the same session returns
`session_busy` rather than queueing.

## Security model

`ptc_runner_mcp` is a **stdio MCP server**. That has implications the
operator must own; the package cannot enforce them.

### Trust boundary

The server runs under the user's auth context — the same as every
other stdio MCP server. Anyone with stdio access can submit arbitrary
PTC-Lisp. The sandbox is the protection against that program; the
operator is responsible for not exposing the server to untrusted
callers.

### What the sandbox protects against

- **Filesystem reads / writes.** PTC-Lisp has no `slurp`, no `spit`,
  no file I/O at all.
- **Network access.** No `http-get`, no socket primitives. The
  closed-world assumption is asserted by the `openWorldHint: false`
  tool annotation.
- **Process exec.** No shell-out, no `:os.cmd`, no port spawn.
- **Resource exhaustion.** Five distinct caps:
  `max_frame_bytes` (8 MB), `max_program_bytes` (64 KB),
  `max_context_bytes` (4 MB), `max_concurrent_calls` (8 by default),
  plus the per-program 1 s wall-clock and 10 MB memory limits.
  Crossing a cap returns a structured error result, not a server
  crash.
- **Cross-call leakage.** Each `tools/call` runs in a fresh BEAM
  process with empty user namespace, empty tool cache, and no journal
  reuse. Two sequential calls cannot see each other's `(def …)`
  bindings — asserted by an isolation regression test.

### What the sandbox does NOT protect against

- **A malicious operator with stdio access.** The server trusts the
  bytes on its stdin. If an attacker controls the calling MCP client
  or the spawning process, no in-server check helps.
- **The operator's own log files.** If the operator runs the server
  with `--log-level debug`, `program` and `context` bodies land in
  stderr logs. That is intentional for debugging but means the
  operator owns that data's hygiene. Defaults are conservative:
  full payloads are debug-level only.
- **Trace files.** With `--trace-dir` set, per-call JSONL traces are
  written to disk. `--trace-payloads summary` (the default when
  tracing is on) records sizes and SHA-256 digests only;
  `--trace-payloads full` includes verbatim bytes. The choice is the
  operator's; the package does not exfiltrate.
- **Side channels in the calling LLM.** The server returns whatever
  the program returns. If the program is constructed to encode
  caller-supplied secrets in its result, those bytes flow back to
  the client. PtcRunner has nothing to say about what the calling
  LLM does with its inputs.

### Operator log hygiene

Default log levels are conservative. `info` and above never include
verbatim `program` or `context`. Traces are off unless `--trace-dir`
is set. If you do enable tracing, prefer `--trace-payloads summary`
unless you are actively debugging a specific reproduction.

## Limits

| Limit | Default | Configurable |
|---|---|---|
| `max_frame_bytes` | 8 MiB | `--max-frame-bytes` / env |
| `max_program_bytes` | 64 KiB | `--max-program-bytes` / env |
| `max_context_bytes` | 4 MiB | `--max-context-bytes` / env |
| `max_concurrent_calls` | `min(8, logical_processors)` | `--max-concurrent-calls` / env |
| Program wall-clock | 1 s (10 s in aggregator mode) | `--program-timeout-ms` / env |
| Program memory | 10 MB (100 MB in aggregator mode) | `--program-memory-limit-bytes` / env |

Frame overflow surfaces as a JSON-RPC `-32700`. The other caps surface
as structured tool-result errors (`args_error`, `busy`, `timeout`,
`memory_limit`). Aggregator mode adds its own per-call caps
(`upstream_call_timeout_ms`, `max_upstream_response_bytes`,
`max_upstream_calls_per_program`); see
[`docs/mcp-server-configuration.md`](mcp-server-configuration.md) for
the full set.

## Links

- [`mcp_server/README.md`](../mcp_server/README.md) — install and
  client configuration.
- [`docs/mcp-server-configuration.md`](mcp-server-configuration.md) —
  every flag, environment variable, response profile, catalog mode,
  tracing setup, and lifecycle command.
- [`docs/aggregator-mode.md`](aggregator-mode.md) — calling configured
  upstream MCP servers from inside the sandbox via `(tool/mcp-call …)`,
  plus the payload-reduction metrics emitted on every aggregator
  response.
- [`docs/agentic-mode.md`](agentic-mode.md) — `lisp_task`, the
  natural-language planner tool layered on top of aggregator mode.
- [`docs/mcp-debug.md`](mcp-debug.md) — the opt-in `lisp_debug`
  diagnostics tool.
- [Getting started guide](guides/mcp-getting-started.md) — short
  walkthrough from install to first schema-validated call.
- [`docs/ptc-lisp-specification.md`](ptc-lisp-specification.md) — the
  PTC-Lisp language reference.
- [`docs/function-reference.md`](function-reference.md) — every
  built-in function with its signature.
- [`docs/signature-syntax.md`](signature-syntax.md) — internal PTC
  return-type grammar used behind `output_schema` validation.
- [Model Context Protocol](https://modelcontextprotocol.io/) — the
  upstream protocol spec.
