# PtcRunner MCP Server (Future Discussion Draft)

## Status

PtcRunner today is a hex library called from Elixir. This plan describes an
opt-in MCP (Model Context Protocol) server that exposes PTC-Lisp execution
to any MCP client (Claude Desktop, Cursor, Cline, Claude Code, etc.) over
stdio JSON-RPC.

This plan is a **sibling** to `text-mode-ptc-compute-tool.md`. Both answer
the same underlying question — "how does an LLM-driven agent gain
deterministic-compute affordances via PTC-Lisp?" — and differ only in
process boundary:

- **Text-mode**: in-process, Elixir LLM client, native tool exposure of
  `ptc_lisp_execute`.
- **MCP**: out-of-process, any-language LLM client, native MCP tool exposure
  of `ptc_lisp_execute`.

Both surfaces share a **response contract** (success/error JSON shape,
error reason enum, `feedback` rendering) but have **per-surface request
contracts** and **per-surface capability profiles**. The shared protocol
lives in a new public module `PtcRunner.PtcToolProtocol` (see "Shared
Protocol Module" below) — extracting it is a prerequisite of both this
plan and `text-mode-ptc-compute-tool.md`.

## Summary

Ship a standalone MCP server (`ptc_runner_mcp`) that exposes one tool:
`ptc_lisp_execute`. The tool accepts a PTC-Lisp program (plus optional
context and signature), runs it through PtcRunner's existing sandbox, and
returns a structured result using the shared response contract.

The MCP server has no LLM of its own. The MCP client's LLM does the
reasoning; PtcRunner is invoked only when deterministic computation is
useful. Each invocation is independent — no shared state across calls in
v1.

## Motivation

PtcRunner's deterministic-compute affordance is too valuable to keep behind
an Elixir-only API. MCP is the standard interop protocol for the agentic
ecosystem: a PtcRunner MCP server makes PTC-Lisp callable from Claude
Desktop, Cursor, Cline, Claude Code, and any future MCP-compatible client
without an Elixir SDK in the loop.

The pitch over existing code-execution MCP servers (Python, JS) is:

- **Deterministic and sandboxed**: 1s timeout, 10MB memory limit, no I/O
  except `println`, no network, no filesystem.
- **Designed for LLM authoring**: no import or setup tax, every program is
  a self-contained expression.
- **Schemas as types**: optional `signature:` validates and coerces return
  values.
- **Stable wire format**: shared response contract with the in-process
  text-mode feature, so the same tool-call protocol works in both surfaces.

The cross-language adoption forces an honest test of the architecture:
whatever cannot cross the JSON-RPC boundary cleanly is something to
question.

## MCP v1 vs Text-Mode v1: Scope Comparison

| Concern | Text-Mode v1 | MCP v1 |
|---|---|---|
| App tools | `:both` exposure opt-in per tool | None |
| Tool cache across calls | Shared with PTC layer | Stateless per call |
| Sessions / state | Within `run/2` | Single tool-call only |
| Multi-call rule | `ptc_lisp_execute` exclusive in turn | N/A (one call per JSON-RPC request) |
| System prompt | Compact PTC reference card | N/A (no system prompt) |
| Preview-and-cache | Default for `:both` tools with `cacheable: true` | N/A (no native tools to preview) |
| LLM client | PtcRunner's loop calls the LLM | Caller's LLM (Claude Desktop, etc.); PtcRunner has no LLM |

The asymmetry is intentional. MCP v1 is the pure primitive — execute a
program, return the result. Anything that creeps from the text-mode column
into MCP v1 has to argue against this table.

## Non-Goals

- Do not expose `SubAgent.run/2` over MCP in v1. That is "Feature B" — has
  cross-cutting concerns (whose LLM creds, cost model, app tools as
  reverse-MCP callbacks). Defer until Feature A usage demands it.
- Do not expose app tools to the MCP client in v1. The MCP-exposed
  `ptc_lisp_execute` runs programs against built-in PTC-Lisp functions only
  (`filter`, `map`, `reduce`, math, string ops, datetime ops). If a caller
  needs tool orchestration, they call other MCP servers (or their own
  tools) and thread the data into the next `ptc_lisp_execute` call as
  context.
- Do not introduce stateful sessions in v1. Each MCP tool call is
  independent: fresh memory, journal, tool_cache, child_steps. Multi-step
  workflows happen by the client threading state via `context` arg, not by
  PtcRunner remembering anything.
- Do not stream `println` output during execution. Programs are fast (1s
  cap); streaming is complexity for marginal gain. Defer.
- Do not flip any defaults in `ptc_runner` itself. The MCP server is a
  separate package that depends on `ptc_runner`.
- Do not let the MCP package reach into `Loop.PtcToolCall`, `TurnFeedback`,
  or `JsonHandler` internals. Use `PtcRunner.PtcToolProtocol` only.

## Shared Protocol Module

The wire-format pieces today live scattered inside v1 internals:

- `Loop.PtcToolCall.tool_description/0` — canonical description string
- `Loop.PtcToolCall` private functions — success/error JSON renderers
- `TurnFeedback.execution_feedback/3` — `feedback` field renderer
- `JsonHandler.atomize_value/2`, `validate_return/2`,
  `format_validation_errors/1` — signature coercion
- `Signature.parse/1` — already module-public

Two new consumers (text-mode work and MCP server) cannot reach into these
internals long-term. Extract a public module **before either feature starts
implementation**:

```elixir
defmodule PtcRunner.PtcToolProtocol do
  @moduledoc """
  Public protocol for surfaces that expose PTC-Lisp execution as a tool.

  Owns: canonical tool description (parameterized by capability profile),
  success/error JSON renderers, shared error reason enum, signature
  validation entry points.

  Consumers: in-process v1 PTC :tool_call (via Loop.PtcToolCall),
  text-mode-ptc-compute-tool combined mode (via Loop.TextMode),
  ptc_runner_mcp server.
  """
end
```

The module exports:

- `tool_description(profile)` — returns the canonical description for a
  capability profile.
- `render_success(lisp_step, opts)` — returns the R22 success JSON.
- `render_error(reason, message, opts)` — returns the R23 error JSON.
- `error_reason()` typespec covering the shared enum.
- Re-exports of `Lisp.run/2`, `Signature.parse/1`, `atomize_value/2`,
  `validate_return/2` if their current paths are awkward to consume from
  outside the SubAgent loop.

Effects on existing code:

- `Loop.PtcToolCall.tool_description/0` becomes a thin caller of
  `PtcToolProtocol.tool_description(:in_process_with_app_tools)`.
- `Loop.PtcToolCall`'s private renderers become thin callers of
  `PtcToolProtocol.render_success/2` and `render_error/3`.
- All three plans (v1, text-mode, MCP) reference `PtcToolProtocol` as the
  source of truth for the response contract.

This refactor is small — mostly `defp` → `def` plus the description split.
**It is a prerequisite** of both the text-mode and MCP plans. Land it as a
standalone PR before either feature begins.

## Tool Description Capability Profiles

> **Locked per text-mode Addendum #10/#11 (2026-05-06).** Each profile
> is a single canonical string constant. `tool_description/1` returns
> the constant directly — no runtime concatenation of base + capability
> note. The "base + capability note" framing below is spec-level prose,
> not an implementation directive.
>
> **`:in_process_with_app_tools` MUST match the existing v1 string in
> `lib/ptc_runner/sub_agent/loop/ptc_tool_call.ex:53` byte-for-byte.**
> Tier 0's byte-for-byte invariant on existing v1 PTC `:tool_call`
> behavior wins over any reworded base/capability framing.

Conceptual structure (informational):

- **Base notion** (used to describe what the profiles share, NOT a
  runtime-concatenated constant): "Execute a PTC-Lisp program in
  PtcRunner's sandbox. Use this for deterministic computation..."
- **Capability note per profile** (folded into the canonical string):

| Profile | Canonical string |
|---|---|
| `:in_process_with_app_tools` | **Locked to existing v1**: "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation and tool orchestration. Call app tools as `(tool/name ...)` from inside the program — do not attempt to call app tools as native function calls; only `ptc_lisp_execute` is available natively." |
| `:in_process_text_mode` | "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation, filtering, aggregation, or multi-step data transformation. Call `:both`-exposed app tools as `(tool/name ...)` from inside the program. The same tools are also callable natively in this assistant turn, but not in the same turn as `ptc_lisp_execute`." |
| `:mcp_no_tools` | "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation, filtering, aggregation, or multi-step data transformation. No app tools are available inside the program. Pass external data via the `context` argument; each invocation is independent — there is no memory of prior calls." |

The exact wording is the canonical constant per profile in
`PtcRunner.PtcToolProtocol`. Tests assert stable substrings per
profile, plus a byte-for-byte equality test for
`:in_process_with_app_tools` against the existing v1 string (this is
the regression guard for Tier 0's byte-for-byte invariant).

## Proposed Shape

The MCP server is a standalone process speaking JSON-RPC over stdio. After
the standard `initialize` handshake, it advertises one tool:

```json
{
  "name": "ptc_lisp_execute",
  "description": "<PtcToolProtocol.tool_description(:mcp_no_tools)>",
  "inputSchema": {
    "type": "object",
    "properties": {
      "program": {
        "type": "string",
        "description": "PTC-Lisp source code. Must be non-empty."
      },
      "context": {
        "type": "object",
        "description": "Optional map of named values bound under data/ in the program. Keys are strings; values are JSON-encodable.",
        "additionalProperties": true
      },
      "signature": {
        "type": "string",
        "description": "Optional PTC signature for return validation, e.g. '(records [{id :int}]) -> {count :int}'."
      }
    },
    "required": ["program"]
  }
}
```

A `tools/call` invocation runs the program in a fresh sandbox process and
returns a response in the shared response contract below.

## Shared Response Contract

The response shape is **identical** across v1 in-process PTC `:tool_call`,
the future text-mode-ptc-compute-tool combined mode, and this MCP server.
`PtcRunner.PtcToolProtocol.render_success/2` and `render_error/3` are the
single source of truth.

**Success** (R22 shape, with optional `validated` field for MCP):

```json
{
  "status": "ok",
  "result": "<final expression preview, EDN/Clojure-rendered>",
  "prints": ["..."],
  "feedback": "user=> ...\n\n;; items = [...]\n",
  "memory": {
    "changed": {"items": "[{:id 1 ...}]"},
    "stored_keys": ["items"],
    "truncated": false
  },
  "truncated": false,
  "validated": <signature-coerced JSON value, only present when signature is supplied and valid>
}
```

The `validated` field is **MCP-specific** in v1 — see "Per-Surface Request
Contract" and "Phase 3" below. Other surfaces do not emit it today.

**Error** (R23 shape, with one new reason — see Error Reason Enum below):

```json
{
  "status": "error",
  "reason": "parse_error | runtime_error | timeout | memory_limit | args_error | fail | validation_error",
  "message": "<short error string>",
  "feedback": "<execution error feedback only>",
  "result": "<failed-value preview, only present when reason: \"fail\">"
}
```

## Error Reason Enum (Shared)

The shared enum is **owned by `PtcRunner.PtcToolProtocol`**:

| Reason | When emitted | Surfaces |
|---|---|---|
| `parse_error` | PTC-Lisp parse failed | All |
| `runtime_error` | Program executed but raised | All |
| `timeout` | Program exceeded sandbox time cap | All |
| `memory_limit` | Program exceeded sandbox memory cap | All |
| `args_error` | Tool args malformed (missing `program`, non-string, wrong shape, oversized) | All |
| `fail` | Program called `(fail v)` | All — only reason that includes a `result` field |
| `validation_error` | Signature was supplied; return value did not match | **MCP v1 only.** Other surfaces handle validation failure by consuming a retry turn instead of terminating. |

`validation_error` is **added** to the shared enum as part of this plan.
The text-mode plan and v1 in-process do not emit it today (they retry);
they may adopt it later if a non-retry validation path is added. The enum
stays consistent across surfaces even when not all surfaces emit every
reason.

The text-mode plan's protocol-error reasons (`unknown_tool`,
`multiple_tool_calls`, `mixed_with_ptc_lisp_execute`) are **not** part of
the response contract — they are surface-specific transport concerns and
live in the text-mode plan only. Native tool-call protocol errors don't
apply to MCP v1 (one tool exposed, one call per JSON-RPC request).

## Per-Surface Request Contract

Request shapes differ by surface. Source of truth is the surface's plan,
not `PtcToolProtocol`.

| Surface | Args |
|---|---|
| In-process v1 PTC `:tool_call` | `{program: string}` — context flows from `SubAgent.run/2` opts, not the request |
| Text-mode combined `:tool_call` | `{program: string}` — same as above |
| MCP v1 | `{program: string, context: optional object, signature: optional string}` |

MCP v1's `context` and `signature` are the cross-language equivalents of
what the in-process surfaces get from the SubAgent caller. They're not in
the in-process `:tool_call` request because the in-process surface already
has them in scope.

## Tool Surface (v1, Feature A only)

One tool: `ptc_lisp_execute`. No app tools, no SubAgent loop, no LLM-side
state. Each call is:

1. JSON-RPC `tools/call` arrives with `program` (required), `context`
   (optional), `signature` (optional).
2. Server decodes args, validates `program` is a non-empty string within
   the size limit, parses `signature` if provided, validates `context`
   size.
3. Server builds a fresh `Loop.State` with empty
   memory/journal/tool_cache.
4. Server calls `Lisp.run/2` (re-exported from `PtcToolProtocol`) in a
   one-shot sandbox process.
5. Server renders success or error JSON via `PtcToolProtocol.render_success/2`
   / `render_error/3`.
6. Server returns the JSON as the tool-call response.

## Wire-Format Decisions Needed Before Implementation

These are the JSON serialization gaps that the in-process surface dodges
by staying in Elixir but the MCP surface must answer.

| PTC-Lisp value | Wire form |
|---|---|
| Integer | JSON number (preserved as integer) |
| Float | JSON number |
| String | JSON string |
| Boolean | JSON boolean |
| Nil | JSON null |
| Map (string-keyed) | JSON object |
| List | JSON array |
| Atom | **Open**: stringify `:foo` → `"foo"` (recommended), or EDN-shaped `":foo"` |
| Tuple | **Open**: JSON array (recommended; loses tuple-ness) or tagged `{"__tuple__": [...]}` |
| DateTime | ISO-8601 string (already normalized — free) |
| Date / Time | ISO-8601 strings (consistent with DateTime handling) |
| Var (unresolved) | Error in v1 |
| Regex (`:re_mp`) | EDN-shaped `"#\"pattern\""` string |

**v1 approach**: keep the `result` and `prints` fields in the tool-result
JSON as **EDN/Clojure-rendered preview strings** (which is what
`Format.to_clojure/2` already produces today). The MCP client gets exactly
what an in-process LLM gets — a textual preview of the value.

When `signature` is supplied, additionally return `validated` as a
JSON-decoded Elixir-side value coerced through
`JsonHandler.atomize_value/2`. Atoms become strings; tuples become arrays;
DateTime becomes ISO-8601. This is the structured data path for clients
that want to consume the value programmatically.

The dual approach (EDN preview + optional structured `validated`) means
the wire format never has to make a hard "which JSON shape?" decision —
the caller gets to pick.

## Resource Limits

PtcRunner's existing sandbox (1s timeout, 10MB memory, restricted Java
interop, no I/O except `println`) is the safety boundary inside a program.
The MCP server adds a new boundary: across requests.

| Limit | Default | Configurable | Reason on exceed |
|---|---|---|---|
| `max_program_bytes` | 64 KB | flag / env | `args_error` |
| `max_context_bytes` | 4 MB | flag / env | `args_error` |
| `max_concurrent_calls` | `min(8, :erlang.system_info(:logical_processors))` | flag / env | JSON-RPC `-32603` "server busy"; client should retry with backoff |
| `program_timeout` | 1 s (existing sandbox) | not configurable in v1 | `timeout` |
| `program_memory_limit` | 10 MB (existing sandbox) | not configurable in v1 | `memory_limit` |

**Required**:

- One BEAM process per `tools/call` request. No process reuse.
- No shared state across requests. Fresh `Loop.State` each call.
- Existing sandbox guarantees (no filesystem, no network) verified to hold
  when called from the MCP server context.

**Out of scope for v1** (deferred):

- Per-session quotas across requests.
- Tool-cache reuse across calls (would require sessions).
- Audit logging of submitted programs.
- Configurable timeouts / memory limits.

## Error Mapping

PtcRunner errors map to the shared response contract's R23 error shape.
MCP / JSON-RPC level errors are reserved for protocol-level problems:

- Invalid JSON-RPC request → standard `-32600 Invalid Request`.
- Unknown method → `-32601 Method not found`.
- `max_concurrent_calls` exceeded → `-32603` with "server busy" message;
  client should retry with backoff.
- Invalid `tools/call` args (missing `program`, wrong type, exceeds
  `max_program_bytes` / `max_context_bytes`, etc.) → return R23 error JSON
  with `reason: "args_error"` as the tool result, NOT a JSON-RPC error.
- Server-internal errors (sandbox didn't start, BEAM-level OOM, etc.) →
  `-32603 Internal error` with a sanitized message.

## Packaging

- New hex package: `ptc_runner_mcp`. Depends on `ptc_runner`.
- The MCP server is the package's main `mix run` target.
- Distribution as a Burrito-bundled single binary so non-Elixir users can
  install without touching the BEAM.
- Configuration: minimal. The server reads stdio; no flags required for
  the default. Optional flags / env vars for the four configurable limits
  in the Resource Limits table, plus log destination.
- Document the `claude_desktop_config.json` and `cline_mcp_settings.json`
  snippets users need to wire it into popular clients.

## Phases

### Phase 0 — Extract `PtcRunner.PtcToolProtocol`

**Prerequisite of both this plan and `text-mode-ptc-compute-tool.md`.**
Land as a standalone PR in `ptc_runner` before either feature begins.

- Promote `Loop.PtcToolCall.tool_description/0` to
  `PtcToolProtocol.tool_description(profile)` with the three capability
  profiles defined above.
- Promote `Loop.PtcToolCall`'s private success/error renderers to
  `PtcToolProtocol.render_success/2` and `render_error/3`.
- Define `PtcToolProtocol.error_reason()` typespec covering the shared
  enum (including the new `validation_error`).
- Re-export `Lisp.run/2`, `Signature.parse/1`, `atomize_value/2`,
  `validate_return/2` from `PtcToolProtocol` if call sites are awkward.
- Update `Loop.PtcToolCall` to delegate; existing v1 behavior must be
  byte-for-byte unchanged (v1 currently uses
  `:in_process_with_app_tools`).

**DoD**: existing v1 tests pass unchanged; new tests assert each
capability profile's substring; `PtcToolProtocol` is documented as the
public protocol home.

### Phase 1 — MCP server skeleton

- New `ptc_runner_mcp` package, depends on `ptc_runner`.
- stdio JSON-RPC handler.
- Implements `initialize`, `tools/list`, and `tools/call` — last as a
  no-op that echoes its args.
- `tools/list` advertises one tool, description from
  `PtcToolProtocol.tool_description(:mcp_no_tools)`.

**DoD**: a manual test using the official MCP inspector tool can list the
single advertised `ptc_lisp_execute` tool with the `:mcp_no_tools`
capability note.

### Phase 2 — Wire `ptc_lisp_execute` (no context, no signature)

- `tools/call` calls `Lisp.run/2` against a fresh `Loop.State`.
- Renders success / error JSON via `PtcToolProtocol.render_success/2` and
  `render_error/3`.
- Stateless: each call is independent.
- `max_program_bytes` enforced; oversized programs return `args_error`.
- `max_concurrent_calls` enforced; over-cap requests return JSON-RPC
  `-32603` "server busy."

**DoD**: a program like `(+ 1 2)` returns `result: "user=> 3"`. A program
with parse errors returns `reason: "parse_error"`. A program exceeding
`max_program_bytes` returns `reason: "args_error"`. Concurrent over-cap
requests return JSON-RPC `-32603`.

### Phase 3 — Context + signature args

- Accept `context` (map) on tool calls. Bind under `data/` in the program.
  Enforce `max_context_bytes`; oversized → `args_error`.
- Accept `signature` (string) on tool calls. Parse via
  `Signature.parse/1`.
- When signature is supplied:
  - Validate the return value via `JsonHandler.validate_return/2`
    (re-exported through `PtcToolProtocol`).
  - On validation failure: return R23 error JSON with
    `reason: "validation_error"` and the failure detail in `message` /
    `feedback`.
  - On success: include `validated` field in the success JSON, carrying
    the JSON-coerced value (atoms → strings, tuples → arrays, DateTime →
    ISO-8601, via `JsonHandler.atomize_value/2`).

**DoD**: cross-language smoke test — Claude Desktop submits a program
with context + signature, server returns coerced JSON. Signature mismatch
returns `reason: "validation_error"`. Oversized context returns
`reason: "args_error"`.

### Phase 4 — Packaging and distribution

- Mix release configuration.
- Burrito binary build for macOS / Linux / Windows.
- README documenting `claude_desktop_config.json` snippets.
- Optional: `mix ptc_runner.mcp` task that runs the server inline for
  developers iterating in Elixir.

**DoD**: a single binary installable via Homebrew tap or GitHub release;
README walks a non-Elixir user through wiring it into Claude Desktop.

### Phase 5 — Integration tests, docs, benchmarks

- Live tests against at least one MCP client (Claude Desktop, MCP
  Inspector, or a bespoke test harness).
- Docs explaining the deterministic-compute use case and how it differs
  from Python / JS execution servers.
- Benchmark: native-only LLM math vs PtcRunner-MCP-assisted math on a
  representative problem class.

## Tests Required

- `tools/list` advertises exactly one tool, name `ptc_lisp_execute`.
- The advertised description equals
  `PtcToolProtocol.tool_description(:mcp_no_tools)` verbatim.
- The advertised description contains the substring
  "No app tools are available inside the program."
- The advertised description does NOT contain "Call app tools as
  `(tool/name ...)`" (negative assertion — proves capability profile is
  correct).
- `tools/call` with a valid program returns success JSON in shared R22
  shape.
- `tools/call` with a malformed program returns error JSON in shared R23
  shape with `reason: "parse_error"`.
- `tools/call` with `program` missing returns `reason: "args_error"`.
- `tools/call` with `program` non-string returns `reason: "args_error"`.
- `tools/call` with a program exceeding `max_program_bytes` (default
  64 KB) returns `reason: "args_error"` with a clear "program too large"
  message.
- `tools/call` with `context` exceeding `max_context_bytes` (default
  4 MB) returns `reason: "args_error"` with a clear "context too large"
  message.
- `tools/call` with a runtime error (e.g. `(/ 1 0)`) returns
  `reason: "runtime_error"`.
- `tools/call` with `(fail {:reason :nope})` returns `reason: "fail"` and
  the error JSON includes a `result` field.
- `tools/call` with a 2s sleep returns `reason: "timeout"`.
- `tools/call` allocating > 10 MB returns `reason: "memory_limit"`.
- `tools/call` with `context: {"records": [...]}` makes the data
  accessible inside the program as `data/records`.
- `tools/call` with `signature: "() -> {total :int}"` and a return value
  that matches the signature includes a `validated` field with the
  JSON-coerced value.
- `tools/call` with a signature mismatch returns
  `reason: "validation_error"`.
- Concurrent over-cap requests return JSON-RPC `-32603`.
- Concurrent under-cap requests are isolated: one program's memory state
  does not leak into another's.
- After a program completes, no per-process state persists into the next
  request.
- The wire-format atom serialization survives round-trip through
  `JSON.decode/encode`.

## Deferred From v1

- **Feature B — SubAgent over MCP.** Exposing `SubAgent.run/2` so the MCP
  client delegates a sub-task to a PtcRunner agent that does its own LLM
  calls. Cross-cutting concerns (LLM creds, cost model, app-tools as
  reverse-MCP callbacks). Land Feature A first and let real usage shape
  the design.
- **Stateful sessions.** Per-session memory / journal / tool_cache that
  persist across calls. Useful for iterative refinement workflows.
  Currently solved by client-threaded `context`.
- **Streaming `println` output.** MCP supports streaming via
  notifications. Defer until programs are long enough to benefit.
- **App tools exposed to the MCP-side `ptc_lisp_execute`.** Would require
  a tool registration API and either reverse-MCP callbacks or built-in
  tool catalogs. Significant new design surface.
- **MCP resources / prompts.** This plan exposes only the tools surface.
  Adding resources (e.g., browseable PTC-Lisp documentation) or prompts
  (e.g., scaffolds for common analytical tasks) is opt-in expansion.
- **Configurable timeouts / memory limits.** v1 hard-codes 1s / 10MB
  inherited from the sandbox. When configurability is added, decide
  whether limits are per-server (operator config) or per-request (client
  option).

## Open Questions

- **Atom serialization**: stringify (`:foo` → `"foo"`) or EDN-shaped
  (`":foo"`)? The choice affects round-tripping for clients that want to
  reproduce values. Recommend `"foo"` for ergonomics; document the
  one-way mapping.
- **Tuple serialization**: JSON array (loses tuple-ness, easier client
  consumption) or tagged map (preserves type, awkward for naive clients)?
  Recommend JSON array for v1; clients that need to distinguish use
  signatures.
- **MCP server version vs `ptc_runner` library version**: standard MCP
  `initialize` exchanges `protocolVersion` and `serverInfo.version`. Pick
  a versioning policy.
