# PtcRunner MCP — Slim Default Tool Responses

| Field | Value |
|---|---|
| Status | Draft |
| Date | 2026-05-12 |
| Related | `Plans/ptc-runner-mcp-server.md` §10 response contract, `Plans/ptc-runner-mcp-aggregator.md`, `Plans/ptc-runner-mcp-debug-tool.md`, `Plans/ptc-runner-mcp-payload-reduction.md`, `mcp_server/bench/real_mcp_payload_bench.exs`, GitHub issue #905 |
| Decision basis | Real Gmail MCP benchmark on 2026-05-12 showed that bad-fit PTC cases are dominated by verbose observability and mirrored `structuredContent`, not by PTC-Lisp execution itself. User preference: normal `ptc_lisp_execute` should return concise human-readable text; diagnostics belong behind `--debug-tool`. |

## 1. Summary

Change `ptc_runner_mcp` from "structured and observable by default" to
**human-readable and slim by default**.

Default `ptc_lisp_execute` responses should be optimized for the model
consuming the tool result:

- return concise text in `content[0].text`;
- omit `structuredContent` in the `slim` profile, even when a legacy
  PTC `signature` argument is present;
- omit `ptc_metrics`, `upstream_calls`, empty `prints`, empty
  `feedback`, and default `truncated: false` from normal success
  responses;
- keep enough text on errors for the model to repair the program.

When `--debug-tool` is enabled without an explicit response profile,
keep the existing verbose behavior: `structuredContent`,
`upstream_calls`, `ptc_metrics`, mirrored text, and `ptc_debug` all
remain available. Debug mode is the operator's explicit signal that
observability is worth response-size overhead.

If an operator explicitly combines `--debug-tool` with
`--response-profile slim`, the external `ptc_lisp_execute` response
stays slim, while the debug recorder receives the pre-slim structured
payload internally. This keeps diagnostics useful without forcing
normal model-facing tool results to carry observability payloads.

This spec intentionally changes the original MCP v1 response contract
in `Plans/ptc-runner-mcp-server.md` §10. The old contract is still
available as the debug/verbose profile.

## 2. MCP Spec Grounding

The MCP tools specification allows tool results to contain
unstructured `content` and/or `structuredContent`.

Important distinctions:

- `content` is the model/human-readable content channel. Text results
  live at `content[]` items with `{type: "text", text: "..."}`.
- `structuredContent` is the typed JSON channel for tools that return
  machine-readable results.
- `structuredContent` is not required for every tool result.
- If a tool declares `outputSchema`, structured results must conform to
  it.
- The spec says a tool returning structured content **SHOULD** also
  return serialized JSON in a text block for backward compatibility.
  `SHOULD` is not `MUST`.

Therefore a text-first `ptc_lisp_execute` can legally return:

```json
{
  "isError": false,
  "content": [
    { "type": "text", "text": "user=> 3" }
  ]
}
```

without `structuredContent`, as long as the tool does not advertise an
`outputSchema` that requires structured output for that response
profile.

## 3. Motivation

The current response envelope is excellent for debugging and
programmatic clients, but wasteful for normal model-facing use.

Observed sources of overhead:

| Field | Current behavior | Normal-client value | Cost profile |
|---|---|---|---|
| `structuredContent` | Always present | Often unnecessary when the model only needs text | Adds full structured payload |
| `content[0].text` mirror | Always JSON-encodes all `structuredContent` | Useful only for clients that ignore `structuredContent` | Doubles payload |
| `ptc_metrics` | Added for every aggregator response with upstream calls | Pure observability | Large; prose notes dominate |
| `upstream_calls` | Added for every aggregator response with upstream calls | Useful for debugging/world-fault diagnosis | Grows with call count |
| `prints`, `feedback`, `truncated` | Always present in success schema | Empty/default most of the time | Small but noisy |

The benchmark result that triggered this spec:

- tiny/verbatim tasks lose badly under PTC because envelope overhead
  dominates;
- reduction-heavy tasks still win, but would win harder with a slim
  response profile;
- `ptc_metrics.payload_reduction_ratio` measures internal collapse, not
  literal MCP wire savings, because the response currently ships the
  observability block and then mirrors it into text.

## 4. Response Profiles

Introduce a server-wide default response profile:

```text
--response-profile slim|debug|structured
PTC_RUNNER_MCP_RESPONSE_PROFILE=slim|debug|structured
```

Default resolution:

1. CLI `--response-profile` wins.
2. Env `PTC_RUNNER_MCP_RESPONSE_PROFILE` wins over inferred default.
3. If `--debug-tool` / `PTC_RUNNER_MCP_DEBUG_TOOL=true` is enabled,
   default to `debug`.
4. Otherwise default to `slim`.

Response profile semantics:

| Profile | Purpose | Response shape |
|---|---|---|
| `slim` | Default production/model-facing mode | Text-only success; compact text errors; no per-call observability on success |
| `debug` | Current verbose behavior | Existing `structuredContent` + mirrored JSON text + `ptc_metrics` + `upstream_calls` |
| `structured` | Programmatic client mode without debug prose | `structuredContent` present; `content[0].text` is concise; `ptc_metrics` numeric-only optional |

`debug` is backwards-compatible with today's behavior. `slim` is the
new default.

This response profile is a separate axis from the existing
`capability_profile` used by the server today (`:mcp_no_tools` vs
`:mcp_aggregator`). Do not reuse the ambiguous name `profile` in new
code. Use:

- `capability_profile`: what the tool can do and what authoring
  instructions it needs (`:mcp_no_tools`, `:mcp_aggregator`, future
  modes).
- `response_profile`: how a given tool result is rendered externally
  (`:slim`, `:structured`, `:debug`).

The active tool contract is the composition of both axes:

| Capability profile | Response profile | `ptc_lisp_execute` description | `outputSchema` |
|---|---|---|---|
| `:mcp_no_tools` | `:slim` | Text-only PTC-Lisp execution; no upstream tool-call fields promised | Omitted |
| `:mcp_no_tools` | `:structured` | PTC-Lisp execution with compact typed result | Compact `structuredContent` schema |
| `:mcp_no_tools` | `:debug` | Current verbose PTC-Lisp response contract | Current schema |
| `:mcp_aggregator` | `:slim` | Text-only final result; upstream failure details are exposed only as compact error text when repairable | Omitted |
| `:mcp_aggregator` | `:structured` | Compact typed result; may include compact upstream error summaries on errors | Compact `structuredContent` schema |
| `:mcp_aggregator` | `:debug` | Current verbose aggregator response contract with `upstream_calls` and `ptc_metrics` | Current schema |

Profile-specific descriptions and authoring cards must match this
matrix. In particular, slim aggregator descriptions must not promise
that `upstream_calls` is present on successful response envelopes.

## 4.1 MCP Typed Output Direction

Do not use this slim-response work to make PTC signature syntax a more
prominent MCP-facing contract. PTC signatures are an internal
PtcRunner DSL. They are useful for Elixir APIs and internal
validation, but arbitrary MCP client LLMs only understand the syntax
when the tool description spends tokens teaching it, and probing has
shown predictable malformed attempts such as `signature: "any"`.

Typed MCP output should move toward a small JSON Schema argument that
is translated internally into a PTC return signature for validation.
That work is tracked separately in
https://github.com/andreasronge/ptc_runner/issues/905.

For this spec:

- `slim` never emits `structuredContent`.
- A legacy PTC `signature` may still validate/coerce internally if
  supported by the implementation, but successful slim responses
  return text only.
- Signature validation failures remain errors in every response
  profile.
- Programmatic callers that need typed `structuredContent` must use
  `--response-profile structured` or `debug` until the JSON Schema
  typed-output issue lands.
- Tool descriptions for slim mode should avoid teaching full PTC
  signature syntax as the normal MCP path.

## 5. Slim Success Shape

For ordinary successful `ptc_lisp_execute` calls:

```json
{
  "isError": false,
  "content": [
    { "type": "text", "text": "user=> 3" }
  ]
}
```

Rules:

1. `content[0].text` is the human-readable result string currently
   stored in `structuredContent.result`.
2. If legacy validation produced only a typed value and no result
   string, render a concise JSON or EDN-like text preview of that
   value. Do not expose it as `structuredContent` in slim mode.
3. If `println` produced output, append it in a compact form:

   ```text
   <prints>
   line 1
   line 2

   <result>
   user=> 3
   ```

4. Omit empty/default fields:
   - no `prints: []`;
   - no `feedback: ""`;
   - no `truncated: false`;
   - no `upstream_calls`;
   - no `ptc_metrics`;
   - no `structuredContent`.
5. If the result was truncated, include a short textual marker:

   ```text
   user=> "...truncated..."

   [truncated]
   ```

6. No `outputSchema` should be advertised for the `slim` profile,
   because the result is text-first and does not guarantee
   `structuredContent`.

## 6. Slim Error Shape

Errors must remain repairable by the model. Slim errors should keep
text concise but specific:

```json
{
  "isError": true,
  "content": [
    {
      "type": "text",
      "text": "runtime_error: no tool 'search' in upstream 'gmail'"
    }
  ]
}
```

Rules:

1. Include the reason prefix when known:
   `parse_error`, `runtime_error`, `validation_error`, `timeout`,
   `memory_limit`, `args_error`, `fail`, `busy`, `unknown_tool`,
   `shutting_down`.
2. Include the primary message.
3. Include feedback only when it is non-empty and materially helps
   repair the call.
4. Aggregator world-fault context:
   - if an upstream call failed and the program did not handle it,
     include a compact line such as:

     ```text
     upstream gmail.search_emails failed: timeout
     ```

   - do not include successful `upstream_calls` in slim errors unless
     they are needed to explain the failure.
5. In `slim`, no `structuredContent` is required for errors. If a
   client needs machine-readable errors, use `structured` or `debug`.

## 7. Structured Profile

`structured` is for clients that want typed data without debug noise.

Success:

```json
{
  "isError": false,
  "structuredContent": {
    "status": "ok",
    "result": "user=> 3",
    "validated": 3
  },
  "content": [
    { "type": "text", "text": "user=> 3" }
  ]
}
```

Rules:

1. `structuredContent` includes only semantically useful fields:
   `status`, `result`, `validated` when present, and maybe
   `truncated: true` when true.
2. Empty/default fields are omitted.
3. `content[0].text` is concise human-readable text, not serialized
   JSON.
4. `ptc_metrics` is not included by default. If added later, it must be
   numeric-only and no prose notes.
5. `upstream_calls` is omitted on success. It may be included on error
   when needed for repair, compacted to `{server, tool, status,
   reason}`.

This profile is a compatibility bridge for programmatic clients and
tests that rely on `structuredContent`.

## 8. Debug Profile

`debug` preserves today's behavior:

- `structuredContent` is present.
- `content[0].text` mirrors `structuredContent` as serialized JSON.
- `upstream_calls` is present when calls were made.
- `ptc_metrics` is present when applicable.
- `ptc_debug` is advertised when `--debug-tool` is enabled.

One change is recommended even in debug mode: move long explanatory
metric prose out of per-call `ptc_metrics` and into docs or
`ptc_debug` metadata. Per-call metrics should be numeric and compact.
However, this can be a follow-up after slim defaults land.

## 9. Tool Scope

This spec applies first to `ptc_lisp_execute`.

It must not globally change every `Envelope.success/1` or
`Envelope.error_envelope/1` caller into slim output. Other tools may
have their own advertised contracts:

- `ptc_debug` is always a diagnostics tool and should keep structured,
  machine-readable output when advertised.
- `ptc_task` has separate server-side LLM and task-result semantics; it
  should follow the same profile model later, but not as an accidental
  side effect of this change.
- Unknown-tool, busy, shutting-down, and argument-validation envelopes
  may use slim text if they are returned as `ptc_lisp_execute` tool
  results, but protocol-level JSON-RPC errors are unchanged.

Implementation must make the response profile explicit at the
tool-rendering boundary. Either:

1. add `Envelope.success(payload, tool: :ptc_lisp_execute, response_profile: ...)`
   and keep non-PTC tools on fixed structured/debug rendering; or
2. keep `Envelope.success/1` backward-compatible and add dedicated
   `Envelope.ptc_lisp_success/2` / `Envelope.ptc_lisp_error/2` helpers.

The second option is safer because existing callers keep their current
contract unless deliberately migrated.

## 10. Metrics And Observability

Slim mode does not delete observability; it moves it out of every
normal tool response.

In slim mode:

- `ptc_metrics` is not returned in `ptc_lisp_execute` responses.
- When `--debug-tool` is enabled, the server records the pre-slim
  structured payload, upstream call summaries, result sizes, and metrics
  internally before rendering the external slim response.
- When `--debug-tool` is disabled, the server does not do hidden metrics
  work for slim responses.
- `ptc_debug stats` remains the way to inspect payload reduction,
  upstream call counts, errors, latency, and top reducers.

In debug mode:

- current per-call `ptc_metrics` remains available;
- `ptc_debug recent/get` can expose full per-call details.

Important invariant:

> Normal model-facing tool responses should not carry observability
> prose. Prose belongs in docs, tool descriptions, or debug output.

## 11. Tool Description And Output Schema

The advertised `ptc_lisp_execute` tool must match the active response
profile and the active capability profile.

For `slim`:

- omit `outputSchema`;
- tool description should say the tool returns concise text by
  default;
- mention that `--response-profile structured` or `--debug-tool`
  exposes machine-readable details.
- in aggregator mode, say that upstream world faults return `nil`
  inside the PTC-Lisp program and that repairable unhandled failures are
  summarized in error text; do not promise `upstream_calls` on success.

For `structured` and `debug`:

- keep an output schema compatible with `structuredContent`;
- `debug` schema includes optional `upstream_calls` and `ptc_metrics`;
- `structured` schema excludes debug-only observability fields.

If MCP clients cache `tools/list`, the profile is fixed at server boot
and should not change per request in v1.

MCP `outputSchema` describes the structure of `structuredContent`, not
the whole `CallToolResult` and not `content[]`. Therefore slim mode must
not advertise a "text-only content" output schema unless it also returns
conforming `structuredContent`.

## 12. Implementation Plan

### Phase 1 — ResponseProfile config

Add `PtcRunnerMcp.ResponseProfile`.

Responsibilities:

- defaults: `:slim`;
- parse `slim | structured | debug`;
- resolve CLI/env/debug default precedence;
- expose `ResponseProfile.current/0`;
- test CLI > env > debug-inferred > default.
- keep this separate from the existing capability profile. Names in
  code and tests should say `response_profile` when they mean
  `:slim | :structured | :debug`.

Add CLI/env plumbing:

```text
--response-profile slim|structured|debug
PTC_RUNNER_MCP_RESPONSE_PROFILE
```

### Phase 2 — PTC-Lisp envelope rendering

Add profile-aware rendering for `ptc_lisp_execute` without changing
unrelated tools by default:

```elixir
Envelope.ptc_lisp_success(payload, response_profile: ResponseProfile.current())
Envelope.ptc_lisp_error(payload, response_profile: ResponseProfile.current())
```

Keep existing `success/1` and `error_envelope/1` backward-compatible
for `ptc_debug`, `ptc_task`, and any tests that rely on the current
structured envelope.

Add helpers:

- `render_success_text/1`;
- `render_error_text/1`;
- `compact_structured_success/1`;
- `compact_structured_error/1`.

### Phase 3 — Aggregator decorations and debug recording

In `Tools.decorate_and_wrap/2`:

- `debug`: keep `UpstreamCalls.decorate/2` and `decorate_ptc_metrics/3`;
- `structured`: include compact upstream errors only when useful;
- `slim`: do not decorate success payloads with `upstream_calls` or
  `ptc_metrics`.

If `DebugConfig.enabled?()` is true, record the pre-slim structured
payload plus upstream call summaries and metrics before rendering the
external response. This applies even when the explicit response profile
is `slim`. `ptc_debug` should inspect the recorded internal payload, not
infer diagnostics from the externally slimmed envelope.

### Phase 4 — Output schema and tools/list

Make tool listing composition-aware:

- `slim`: no `outputSchema`.
- `structured`: compact schema.
- `debug`: current schema.

Implementation should avoid ambiguous function names such as
`output_schema_for(profile)`. Prefer a signature that names both axes,
for example:

```elixir
Tools.output_schema_for(capability_profile, response_profile)
Tools.description_for(capability_profile, response_profile)
```

Update `tools/list` tests accordingly.

### Phase 5 — Benchmark variants

Update `mcp_server/bench/real_mcp_payload_bench.exs` to run:

```text
native
ptc_slim
ptc_structured
ptc_debug
```

Report:

- cold/warm bytes;
- estimated tokens;
- latency;
- whether PTC wins;
- debug metrics when available.

This confirms the default profile is not unfairly penalized by
diagnostic overhead.

## 13. Tests

Add focused tests:

1. Slim success emits `content` text and no `structuredContent`.
2. Slim success omits `ptc_metrics`, `upstream_calls`, empty `prints`,
   empty `feedback`, and `truncated: false`.
3. Slim error emits useful text and `isError: true`.
4. Slim aggregator success with upstream calls still omits
   observability.
5. Debug profile preserves current verbose response shape.
6. Structured profile includes compact `structuredContent` and concise
   `content`.
7. `--debug-tool` infers `debug` profile when no explicit profile is
   set.
8. Explicit `--response-profile slim --debug-tool` exposes `ptc_debug`
   but keeps `ptc_lisp_execute` slim. This is important: diagnostics
   tooling and response verbosity should be separable when explicitly
   requested.
9. `tools/list` output schema matches the active profile.
10. Release stdio integration covers at least `slim` and `debug`.
11. `ptc_debug` still returns structured diagnostics when
    `--response-profile slim --debug-tool` is used.
12. `ptc_task` and `ptc_debug` do not accidentally inherit slim
    rendering from `ptc_lisp_execute`.
13. `tools/list` descriptions and authoring cards do not promise
    `upstream_calls` in slim aggregator mode.
14. `outputSchema` is omitted in slim mode, because slim mode omits
    `structuredContent`.
15. A legacy PTC `signature` argument in slim mode validates/coerces
    when supported, but successful responses remain text-only and do
    not include `structuredContent`.
16. Slim-mode `tools/list` descriptions do not teach full PTC
    signature syntax as the normal typed-output path; they point
    programmatic callers to `structured`/`debug` and the future JSON
    Schema typed-output work instead.

Existing tests that assert mirrored text equals `structuredContent`
must be moved under the debug profile.

## 14. Compatibility Risks

### Text-only clients

Slim mode is best for text-only clients because `content[0].text` is
human-readable.

### Structured clients

Clients that currently read `structuredContent.validated` by default
will need `--response-profile structured` or `--debug-tool`.

### MCP outputSchema validators

Do not advertise a structured output schema in slim mode unless the
server actually returns `structuredContent` conforming to it.

### Tool contract drift

The existing codebase uses one shared envelope helper for multiple MCP
tools. A global change to that helper can silently alter `ptc_debug` or
`ptc_task`. The implementation must keep each advertised tool's output
contract aligned with its `tools/list` entry.

### Authoring-card drift

Aggregator authoring text currently describes `upstream_calls` as a
response-envelope field. Slim mode changes that for normal success
responses, so the authoring card must be selected or rendered according
to the active response profile.

### Backward compatibility

`debug` profile is the backward-compatible path.

Operators who depend on today's envelope can start the server with:

```bash
ptc_runner_mcp start --response-profile debug
```

or:

```bash
PTC_RUNNER_MCP_RESPONSE_PROFILE=debug ptc_runner_mcp start
```

## 15. Open Questions

1. Should `ptc_metrics` be computed internally in slim mode when
   `--debug-tool` is disabled?

   Recommendation: no. Avoid hidden work. Compute metrics only when
   they will be exposed via debug or structured observability.

2. Should `content[0].text` in structured/debug mode be JSON or human
   text?

   Recommendation: `structured` uses human text; `debug` keeps JSON
   mirror for compatibility with existing tests and clients.

3. Should `ptc_task` follow the same profiles?

   Recommendation: yes, but implement after `ptc_lisp_execute`. The
   same problem exists there, plus server-side LLM metrics. Until then,
   `ptc_task` should keep its existing structured contract.

4. Should `--debug-tool` always force debug profile?

   Recommendation: it should infer debug only when no explicit
   `--response-profile` was set. Explicit profile wins.

## 16. Success Criteria

The feature is successful when:

- default `ptc_lisp_execute` response size for tiny successful calls is
  close to the text result size plus minimal MCP framing;
- bad-fit benchmark cases show dramatically smaller PTC overhead than
  current verbose defaults, while still losing honestly when native is
  better;
- favorable benchmark cases improve further versus native;
- debug mode preserves current diagnostic detail;
- MCP clients that consume text output get more readable results, not
  JSON blobs.
