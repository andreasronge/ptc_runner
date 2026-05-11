# PtcRunner MCP Server

`ptc_runner_mcp` is a long-running process that speaks
[Model Context Protocol](https://modelcontextprotocol.io/) over stdio
JSON-RPC and exposes one tool — `ptc_lisp_execute` — to any MCP client
(Claude Desktop, Cursor, Cline, Claude Code, MCP Inspector, …). The
tool accepts a PTC-Lisp program plus optional `context` and
`signature`, runs it in an isolated BEAM sandbox, and returns a
structured result.

The server has no LLM of its own. The MCP client's LLM does the
reasoning; PtcRunner is invoked only when deterministic computation is
useful — counting, filtering, JSON shape validation, signature-driven
extraction. State does not persist between calls; each `tools/call` is
independent.

This document is the conceptual overview. For install + client
configuration, see
[`mcp_server/README.md`](../mcp_server/README.md). For the full v1
contract, see
[`Plans/ptc-runner-mcp-server.md`](../Plans/ptc-runner-mcp-server.md).
For the PTC-Lisp language itself, see
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
- **JSON shape validation.** Pass a `signature` to assert the result
  is `{count :int, sum :int}`; on mismatch the response carries a
  `validation_error` the model can self-correct from.
- **Signature-validated extraction.** Filter a JSON array down to
  records matching some condition and return them as a typed,
  programmatic value the calling client can consume directly.
- **Filtering or reshaping a structured payload** that already lives
  in the conversation. A small PTC-Lisp program is cheaper and more
  reliable than a long natural-language transformation.

It is **not** the right fit when the work needs filesystem access,
network access, or stateful sessions across calls. PTC-Lisp programs
have none of those, by construction.

## Comparison with Python / JS execution servers

Other "code interpreter" MCP servers exist. Most run Python or
JavaScript inside a container or a process sandbox. The trade-offs
look like this:

| Concern | `ptc_runner_mcp` | Python-exec server | JS-exec server |
|---|---|---|---|
| Sandboxing | BEAM process, no I/O, no FS, no net (by construction) | Container or `seccomp` (operator-configured) | Container, VM2, or `vm` module (operator-configured) |
| Authoring overhead for the LLM | Zero — every program is a self-contained expression | Imports, virtualenv awareness, library knowledge | `require`, `import`, package availability |
| Schema validation of the return value | First-class — `signature` field, structured `validated` payload | None (server returns raw stdout / repr) | None (server returns raw value or `JSON.stringify`) |
| Stable wire format | Yes — same R22/R23 contract as in-process PtcRunner | None standardized | None standardized |
| Network access from the program | None — sandbox blocks it | Often available unless the operator sandboxes harder | Often available unless the operator sandboxes harder |
| Filesystem access from the program | None — sandbox blocks it | Often available unless the operator sandboxes harder | Often available unless the operator sandboxes harder |
| Install footprint | Single Mix release (BEAM + ERTS bundled) | Python + interpreter + libs + sandbox tooling | Node + sandbox tooling |
| Concurrency model | Per-call BEAM process, semaphore-bounded | Process-per-call (typical) or threadpool | Worker-per-call or single-loop |
| Default resource caps | 1 s wall-clock, 10 MB memory, 64 KB program, 4 MB context, 8 concurrent | Operator-defined | Operator-defined |

The PtcRunner pitch in one line: **the sandbox is the language, not
the deployment**. Other servers ship a general-purpose interpreter and
ask the operator to lock it down. PtcRunner ships an interpreter that
cannot leak in the first place.

## Architecture

```
                       MCP client (Claude Desktop, Cursor, Cline, …)
                                    │  stdio (NDJSON-framed JSON-RPC 2.0)
                                    ▼
                  ┌─────────────────────────────────────────┐
                  │              ptc_runner_mcp             │
                  │                                         │
                  │   Stdio reader / writer                 │
                  │              │                          │
                  │              ▼                          │
                  │   JSON-RPC dispatcher                   │
                  │   (initialize, tools/list,              │
                  │    tools/call, notifications/cancelled, │
                  │    shutdown, exit)                      │
                  │              │                          │
                  │              ▼                          │
                  │   Per-call worker  ◄── concurrency      │
                  │   (Phase 4)            semaphore        │
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
               clojure.string, clojure.set)
```

Each `tools/call` request flows top-to-bottom:

1. The stdio reader frames one NDJSON line and hands it to the JSON-RPC
   dispatcher.
2. The dispatcher routes `tools/call` to a per-call worker after
   passing the concurrency semaphore (`max_concurrent_calls`,
   default 8). Excess calls return immediately with `reason: "busy"`
   instead of queuing.
3. The worker validates `program` / `context` / `signature`, builds
   fresh `Lisp.run/2` opts (empty memory, empty tool cache, no journal
   reuse), and invokes `PtcToolProtocol.lisp_run/2`.
4. `:ptc_runner` runs the program in an isolated BEAM process with a
   1 s wall-clock cap and a 10 MB heap cap. Filesystem and network
   APIs are not exposed to the program.
5. The result flows back up: `PtcToolProtocol.render_success_from_step/2`
   builds the R22 success payload, or `render_error/3` builds the R23
   error payload. The MCP envelope (`isError`, `structuredContent`,
   `content`) wraps it. The stdio writer ships one NDJSON frame back.

`notifications/cancelled` from the client kills the in-flight sandbox
process. stdin EOF cancels every in-flight call and exits cleanly.

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
| Program wall-clock | 1 s | not configurable in v1 |
| Program memory | 10 MB | not configurable in v1 |

Frame overflow surfaces as a JSON-RPC `-32700`. The other caps surface
as structured tool-result errors (`args_error`, `busy`, `timeout`,
`memory_limit`).

## Links

- [`mcp_server/README.md`](../mcp_server/README.md) — install,
  client configuration, configuration flags.
- [Getting started guide](guides/mcp-getting-started.md) — short
  walkthrough from install to first signature-validated call.
- [`Plans/ptc-runner-mcp-server.md`](../Plans/ptc-runner-mcp-server.md)
  — the full v1 specification (handshake, request / response
  contracts, phase plan).
- [`docs/ptc-lisp-specification.md`](ptc-lisp-specification.md) — the
  PTC-Lisp language reference.
- [`docs/function-reference.md`](function-reference.md) — every
  built-in function with its signature.
- [`docs/signature-syntax.md`](signature-syntax.md) — the signature
  grammar used by the `signature` argument.
- [Model Context Protocol](https://modelcontextprotocol.io/) — the
  upstream protocol spec.
