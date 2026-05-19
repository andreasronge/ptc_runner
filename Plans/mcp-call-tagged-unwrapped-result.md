# MCP Call Tagged Unwrapped Result - Specification

| Field | Value |
|---|---|
| Status | Draft |
| Date | 2026-05-19 |
| Target packages | `:ptc_runner`, `:ptc_runner_mcp` |
| Related | `Plans/ptc-runner-mcp-aggregator.md`, `Plans/json-support.md`, `Plans/prompt-contracts-and-profiles.md`, `docs/aggregator-mode.md`, `priv/prompts/README.md` |

This document specifies a breaking cleanup of the PTC-Lisp
`tool/mcp-call` contract used by the MCP aggregator. The goal is to
make the common path explicit and safe: programs should receive a
tagged result whose success value is already unwrapped from the MCP
tool-result envelope.

Sections using **MUST** / **SHOULD** / **MAY** carry RFC 2119 normative
weight.

## 1. Motivation

The current direct aggregator contract returns the raw upstream MCP
result envelope on success and `nil` on world-fault failure. That
creates a silent failure mode:

```clojure
(def r (tool/mcp-call {:server "observatory"
                       :tool "list_traces"
                       :args {}}))

(count (get r "traces"))
;; => 0, when r is actually {"content" [...]} and "traces" is inside
;;    structuredContent or JSON text.
```

The program does not raise. It can run to completion and return a
confident wrong answer such as `{:fetched 0}`. This is worse than a
programmer fault because the caller may interpret it as "no data."

The existing `mcp/text` and `mcp/json` helpers mitigate the problem,
but only if the model discovers and applies them correctly. The
default points at the rare path: raw envelope inspection. The common
path is domain data access, so the runtime contract should make that
the default.

## 2. Goals

1. Make `tool/mcp-call` return one tagged value shape in aggregator
   contexts.
2. Put unwrapped domain payload under `:value` on success.
3. Put recoverable upstream failures under explicit `:ok false`
   results instead of collapsing them to `nil`.
4. Remove `mcp/text` and `mcp/json` from code, docs, function
   reference, prompt cards, and analyzer guidance.
5. Keep raw MCP envelope access possible through a server-side
   per-upstream/tool policy, without adding a second call shape.
6. Align direct `ptc_lisp_execute` aggregator mode and agentic
   `ptc_task` around the same `tool/mcp-call` return contract.
7. Keep MCP tool descriptions short and self-contained according to
   `priv/prompts/README.md`.
8. Remove duplicated MCP description prose while changing the
   `tool/mcp-call` contract.

## 3. Non-Goals

- No second public function such as `tool/mcp-result`,
  `tool/mcp-envelope`, or `tool/mcp-call-raw`.
- No call-time raw flag such as `:raw true` or
  `:include_envelope true`.
- No compatibility shim that preserves envelope-by-default behavior.
- No requirement that upstreams declare `outputSchema` or JSON
  `mimeType`; the unwrap rule must work for sparse upstream metadata.
- No change to the public JSON helpers `json/parse-string` or
  `json/generate-string`.
- No attempt to expose every MCP content block in the default success
  value.
- No change to `json/parse-string` in this spec. It remains the
  public nil-on-failure PTC-Lisp helper unless a separate JSON API
  spec changes it.

## 4. New Contract

`tool/mcp-call` **MUST** return a tagged map.

### 4.1 Success

```clojure
{:ok true
 :value payload
 :value_kind :json | :text | :none}
```

`payload` is the unwrapped upstream payload per Section 5.

`value_kind` is a keyword describing how `:value` was produced:

| Kind | Meaning |
|---|---|
| `:json` | `:value` came from `structuredContent` or parsed JSON text. |
| `:text` | `:value` came from `content[0].text` without JSON parsing. |
| `:none` | The upstream call succeeded, but no default payload could be extracted. |

### 4.2 Failure

```clojure
{:ok false
 :reason :tool_error | :upstream_unavailable | :upstream_error | :timeout | :response_too_large | :cap_exhausted
 :message "..."}
```

World faults **MUST** return `:ok false` data. They **MUST NOT** return
plain `nil`.

Programmer faults still raise. Examples: malformed `tool/mcp-call`
arguments, unknown configured server, unknown upstream tool, duplicate
argument keys, and sandbox limit failures.

### 4.3 Conditional Raw Envelope

Raw envelope access stays in the same result shape, not a second
function and not a call-time mode flag.

```clojure
{:ok true
 :value payload
 :value_kind :json
 :raw raw-mcp-result-envelope}
```

`:raw` is conditionally present according to server configuration
described in Section 4.4. It **MUST NOT** trigger a second upstream
request. It only retains the envelope already received by the call.

The field is needed because the default `:value` intentionally hides
MCP protocol structure, while some legitimate programs need envelope
metadata: `mimeType`, multiple `content[]` items, resource/image
content, debug inspection, or exact upstream protocol shape. Keeping
the escape hatch as a result field avoids a second API surface and
avoids making the LLM decide before the call whether it will need raw
metadata.

For `isError: true` tool errors, `:raw` follows the same policy and may
be included on the `:ok false` result because the full upstream
envelope exists. Transport/world failures that did not receive an
envelope do not include `:raw`.

### 4.4 Raw Envelope Policy

Raw envelope inclusion is controlled by server-side upstream config,
not by PTC-Lisp call arguments. Policy is resolved per upstream tool:

1. tool-level override
2. upstream-level default
3. global default

Recommended config shape:

```json
{
  "raw_envelope": false,
  "upstreams": {
    "observatory": {
      "raw_envelope": false,
      "tools": {
        "get_trace": {
          "raw_envelope": true
        },
        "list_traces": {
          "raw_envelope": false
        }
      }
    }
  }
}
```

Normalized storage should preserve the same three-level policy in a
single config struct/map, for example:

```elixir
%{
  raw_envelope_default: false,
  upstreams: %{
    "observatory" => %{
      raw_envelope: false,
      tools: %{
        "get_trace" => %{raw_envelope: true},
        "list_traces" => %{raw_envelope: false}
      }
    }
  }
}
```

The top-level `raw_envelope` key is the global default. This spec does
not add CLI or env flags for per-tool policy; JSON upstream config is
the source of truth because the setting is tool-specific.

Direct aggregator and agentic runtimes **MUST** use one shared resolver
API for the effective policy. Preferred target:

```elixir
PtcRunnerMcp.RawEnvelopePolicy.enabled?(server, tool)
```

The resolver owns the precedence rule:

```text
tool override > upstream default > global default > false
```

If implemented inside an existing config module instead, expose the
same single call shape, for example
`PtcRunnerMcp.AggregatorConfig.raw_envelope_enabled?(server, tool)`.
Tests should target the resolver API rather than reimplementing the
precedence logic in direct and agentic call paths.

`raw_envelope` **SHOULD** default to `false` for payload discipline.
Operators can enable it for small tools, debugging-heavy tools, or
tools whose envelope metadata is part of the intended workflow.

## 5. Unwrap Rule

The success `:value` **MUST** be computed from the upstream MCP result
envelope only after pre-unwrap error classification.

### 5.1 Pre-Unwrap Error Classification

Before any value extraction, the runtime **MUST** preserve the current
MCP tool-level error behavior:

```elixir
%{"isError" => true}
```

is a world fault and returns:

```clojure
{:ok false :reason :tool_error :message "..."}
```

The error detail should continue to come from the bounded
`content[0].text` extraction used today. An `isError: true` envelope
**MUST NOT** be unwrapped into a successful `:text` or `:json` value.
It is not a programmer fault: the generated call was well-formed and
the upstream tool reported an application-level failure.

`:tool_error` is the canonical observable reason for this case. The
Lisp-visible result, `upstream_calls[].reason`, MCP output schemas,
agentic ledger reason, debug summaries, and tests **MUST** use
`tool_error` rather than the previous `upstream_error` bucket. This is
intentional breaking cleanup: previous diagnostics classified
`isError: true` as an upstream error, but the new contract distinguishes
tool-level application failure from JSON-RPC/transport upstream
failure.

Payload metric field names that are already generic aggregate failure
counters, such as `upstream_error_count` and `upstream_error_bytes`,
**MAY** keep their existing names if they continue to mean "failed
upstream/tool call payloads that reached the aggregator." This spec
does not require splitting metrics into `tool_error_count` /
`tool_error_bytes`. If a later metrics cleanup adds reason-specific
fields, `tool_error` should be one of the explicit buckets.

### 5.2 Success Unwrap Order

For non-error envelopes, the success `:value` **MUST** be computed in
this order:

1. If the envelope has non-`nil` `"structuredContent"`, return it as
   `:value` with `:value_kind :json`.
2. Else if `content[0]` is a text item and its `"text"` parses as JSON
   with an internal tuple-preserving decoder, return the parsed value
   with `:value_kind :json`.
3. Else if `content[0]` is a text item with binary `"text"`, return
   that string with `:value_kind :text`.
4. Else return `nil` with `:value_kind :none`.

This is intentionally the behavior previously taught as
`mcp/json`/`mcp/text`, but moved into `tool/mcp-call`.

`:value_kind :none` does not necessarily mean the upstream returned no
content. It means the runtime selected no default domain payload.
Programs that need protocol-level content inspection should rely on
the configured `:raw` escape hatch.

The internal decoder **MUST NOT** call public `json/parse-string` to
decide whether text parsed successfully. `json/parse-string` returns
`nil` for both valid JSON `null` and parse failure. The unwrap path
needs a result-preserving API such as `Jason.decode/1` so it can
distinguish:

```elixir
{:ok, nil}
{:error, _reason}
```

This distinction is required for JSON `null` to produce
`{:ok true :value nil :value_kind :json}` instead of falling through to
plain text.

This internal decoder requirement does not imply that public
`json/parse-string` should become tagged as part of this change.
Changing public `json/parse-string` from `value | nil` to a tagged map
would be a broader language change that affects all JSON callers, not
only MCP aggregation. It may be worth adding later as a sibling such as
`json/parse` or `json/parse-result`, but this spec only needs a private
tuple-preserving decoder at the MCP unwrap boundary.

### 5.3 `structuredContent` and the Problem

`structuredContent` is MCP's typed-data channel. Many upstream tools
return an envelope like:

```json
{
  "content": [
    {"type": "text", "text": "{\"traces\":[...]}"}
  ],
  "structuredContent": {
    "traces": [...]
  }
}
```

The current envelope-by-default contract exposes the outer map. Domain
keys such as `"traces"` are not on that map, so `(get r "traces")`
silently returns `nil`. The new contract makes the typed data channel
the default by putting `structuredContent`, or JSON parsed from text,
under `(:value r)`.

### 5.4 JSON `null`

With tagged results, top-level JSON `null` no longer needs to stand in
for a failure. The preferred representation is:

```clojure
{:ok true :value nil :value_kind :json}
```

This separates successful JSON null from:

```clojure
{:ok false :reason :timeout :message "..."}
```

The existing `:json-null` sentinel should be removed from the
`tool/mcp-call` top-level success path. Existing lower-level JSON
parsing behavior remains unchanged unless a separate JSON spec updates
it.

## 6. PTC-Lisp Type Surface

The analyzer and prompt-rendered tool surface **SHOULD** expose the
shape as a tagged result contract. Prompt text and formal signatures
serve different purposes and should not use identical notation.

Recommended prompt-facing shape:

```text
tool/mcp-call(...) ->
  success {:ok true :value payload :value_kind :json|:text|:none}
  failure {:ok false :reason kw :message text}
```

The prompt-facing shape **SHOULD** use `:json|:text|:none` for
`value_kind`. It is shorter and clearer for LLM authoring than a
generic `:keyword?`, even though the formal signature parser does not
support union or enum types.

The prompt-facing shape **SHOULD NOT** enumerate every possible
failure reason. Use `kw` / keyword in the compact description and keep
the stable reason vocabulary in reference docs and tests.

If a parser-validated signature is needed, use supported PTC-Lisp
signature syntax:

```text
tool/mcp-call({server :string, tool :string, args :map}) ->
  {:ok :bool, :value :any?, :value_kind :keyword?, :reason :keyword?, :message :string?, :raw :map?}
```

PTC-Lisp signatures support optional nullable fields with the `?`
suffix, but do not currently support union or enum return types. Only
machine-parsed signatures need to avoid `:json|:text|:none`.

The prompt examples **MUST** show branching on `:ok` before reading
`:value`:

```clojure
(let [r (tool/mcp-call {:server "observatory"
                        :tool "list_traces"
                        :args {}})]
  (if (:ok r)
    (count (get-in (:value r) ["traces"]))
    (fail (:message r))))
```

## 7. Prompt Updates

Prompt edits **MUST** follow `priv/prompts/README.md`:

- MCP descriptions prioritize purpose, call shape, result shape, and
  failure convention first.
- Runtime prompt content is self-contained.
- Keep the first 800 to 1000 bytes useful on their own.
- Keep operational cards terse; do not turn prompt cards into
  reference docs.

### 7.1 Direct Aggregator Description

Collapse the current duplicate aggregator description blocks into one
authoritative static contract. Today the profile composes both a
hardcoded "Aggregator contract" block and a file-backed "Aggregator
authoring" block, and they repeat the same facts: call shape, return
shape, fault behavior, JSON null, unwrap helpers, and catalog
discovery. The tagged-result migration **MUST NOT** preserve two
independent phrasings of the same contract.

Preferred implementation: move the complete static aggregator contract
into `mcp_server/priv/prompts/mcp_aggregator_authoring_card.md` and
remove `:mcp_aggregator_quick_contract` from the
`mcp_aggregator_description` profile. Keep `:mcp_dynamic_catalog` as a
separate dynamic part because it is runtime data, not prompt prose.

The single static aggregator card should be shaped like:

```text
Run one stateless PTC-Lisp program for compute plus upstream MCP calls.

Aggregator contract:
- Call upstreams: `(tool/mcp-call {:server s :tool t :args {...}})`.
- It returns tagged data; inspect `:ok` before using `:value`.
- Success: `{:ok true :value payload :value_kind :json|:text|:none}`.
- Failure: `{:ok false :reason kw :message text}`; handle or `(fail ...)`.
- `:value` is already unwrapped domain data, not an MCP envelope.
- `:raw` may be present when server config enables raw envelopes.
- Use catalog/search-tools, catalog/list-tools, catalog/describe-tool as needed.
- Return compact maps, vectors, or strings.
- Wrap `tool/mcp-call` in `fn` or `#(...)` before higher-order use.
- Use `output_schema` for typed final results.
- No mutable state, filesystem, general network, or general Java interop.
```

This intentionally does **not** mention `mcp/text`, `mcp/json`,
`structuredContent`, auto-promotion, or `:json-null`.

### 7.2 Aggregator Authoring Card

Update `mcp_server/priv/prompts/mcp_aggregator_authoring_card.md` to be
the single static aggregator prompt card. Keep metadata current:

- increment `version`
- set `date: 2026-05-19` or the implementation date
- update `priority` to tagged result, `:ok`, `:value`, and catalog

The extracted prompt should stay under the existing hard budget and
avoid restating facts already present in the same card. If the dynamic
catalog section renders a discovery snippet, do not repeat the same
catalog examples multiple times in the static card.

### 7.3 Session Description Duplication

The session tools currently duplicate a full "PTC-Lisp sessions"
preamble across both `ptc_session_start` and `ptc_session_eval`. Some
duplication is defensible because MCP clients may load tool
descriptions individually, but the duplicated preamble should be
trimmed:

- `ptc_session_eval` may keep the standalone session authoring model
  because it is where generated code is evaluated.
- `ptc_session_start` should be reduced to the minimal standalone
  facts needed to create an empty session.
- `ptc_session_inspect`, `ptc_session_list`, `ptc_session_forget`, and
  `ptc_session_close` should stay short unless a concrete client
  failure shows they need more context.

This cleanup can happen in the same prompt pass because it shares the
same goal: lower MCP `tools/list` payload and reduce drift between
duplicated prompt facts.

### 7.4 Agentic `ptc_task` Prompt

Update the agentic MCP-call card in `PromptRegistry` so `ptc_task`
uses the same result contract:

- remove instructions to apply `mcp/text` or `mcp/json` to `(:value r)`
- state that `(:value r)` is unwrapped payload
- keep the existing instruction to inspect `:ok`
- keep side-effect guidance unchanged

### 7.5 Other Prompt Surfaces

Remove `mcp/text` and `mcp/json` mentions from:

- `priv/prompts/reference.md`
- `docs/agentic-mode.md` prompt examples, if still prompt-adjacent
- analyzer or error-repair messages that currently recommend MCP
  helpers

Do not replace them with a long explanation of MCP envelopes. The new
runtime contract should make that unnecessary.

## 8. Code Removal and Runtime Changes

### 8.1 Remove MCP Helper Builtins

Remove the public PTC-Lisp builtins:

- `mcp/text`
- `mcp/json`

Required code cleanup:

- remove bindings from `PtcRunner.Lisp.Env.initial/0`
- remove `PtcRunner.Lisp.Runtime.Mcp` unless no private code still uses
  it
- remove entries from `priv/functions.exs`
- remove or rewrite tests in `test/ptc_runner/lisp/eval_mcp_test.exs`
  and `test/ptc_runner/lisp/runtime/mcp_test.exs`
- update unknown-symbol/analyzer tests that expect suggestions for
  `mcp/text` or `mcp/json`

### 8.2 Aggregator Runtime

Change `PtcRunnerMcp.AggregatorTools` so its PTC-Lisp-visible closure
returns tagged maps.

Direct aggregator argument validation **MUST** be tightened to match
agentic validation:

- accept only `:server`, `:tool`, and `:args` top-level keys, plus
  their string-key equivalents
- reject unknown top-level keys as programmer faults
- reject duplicate normalized keys, for example both `"server"` and
  `:server`
- reject forbidden raw-mode keys such as `:raw`, `"raw"`,
  `:include_envelope`, and `"include_envelope"` as unknown keys
- continue to allow `{}` or omitted/nil `:args` as an empty args map

This prevents models from cargo-culting old or rejected raw-envelope
call-time flags that silently do nothing.

Current success path:

```elixir
{:ok, upstream_envelope_or_value, durations}
```

New program-visible success:

```elixir
%{
  ok: true,
  value: unwrapped_value,
  value_kind: value_kind
  # raw: envelope, when raw envelope policy enables it
}
```

New program-visible failure:

```elixir
%{
  ok: false,
  reason: reason,
  message: detail
  # raw: envelope, for tool errors when raw envelope policy enables it
}
```

The implementation may use atom keys internally so PTC-Lisp can write
`(:ok r)` and `(:value r)`.

`upstream_calls` recording remains the diagnostic side channel for MCP
response envelopes and should not be replaced by large failure maps.

### 8.3 Agentic Runtime

`PtcRunnerMcp.Agentic.McpCall` already returns a tagged map. Update it
so success `:value` is the unwrapped payload per Section 5, not the raw
envelope. Raw metadata is included as `:raw` only when the resolved raw
envelope policy enables it for that upstream tool.

Agentic parity requirements:

- `normalize_args/1` **MUST** continue to reject unknown top-level keys
  and duplicate normalized keys.
- failure `:reason` **MUST** be a PTC-Lisp keyword/atom, matching the
  direct aggregator contract; it must not be stringified in the
  Lisp-visible result.
- ledger/internal rendering may still stringify reasons where existing
  ledger schemas require strings.
- `isError: true` classification **MUST** match direct aggregator
  behavior and return `:ok false, :reason :tool_error`.

## 9. Documentation Updates

Update docs to describe the new tagged contract and remove MCP helper
references:

- `docs/aggregator-mode.md`
- `docs/function-reference.md`
- `docs/ptc-lisp-specification.md`
- `docs/clojure-conformance-gaps.md`
- `docs/agentic-mode.md`
- `docs/mcp-server.md`
- `docs/mcp-server-configuration.md` if it mentions failure behavior
- `mcp_server/CHANGELOG.md`
- root `CHANGELOG.md` if public package release notes require it

Specific changes:

- replace "world faults return nil" with tagged `:ok false`
- replace "unwrap with mcp/text or mcp/json" with "read `:value`"
- update MCP output schemas to allow `tool_error` anywhere
  `upstream_calls[].reason` or equivalent diagnostic reasons are
  enumerated
- explain `structuredContent` in reference docs only, as part of the
  internal unwrap rule
- remove `mcp/text` and `mcp/json` from generated function reference
  tables

## 10. Tests

Add or update tests for:

1. Successful upstream `structuredContent` returns
   `{:ok true :value structured :value_kind :json}`.
2. Upstream JSON text returns parsed `:value` and `:value_kind :json`
   even without `mimeType`.
3. Plain text returns `:value_kind :text`.
4. Empty or non-text content returns `:value nil :value_kind :none`.
5. JSON `null` returns `:ok true :value nil :value_kind :json`.
6. World faults return `:ok false` with stable `:reason` and
   `:message`.
7. Programmer faults still raise.
8. Raw envelope policy includes `:raw` without a second upstream
   request when enabled, and omits it when disabled.
9. Tool-level raw policy overrides upstream-level raw policy; upstream
   policy overrides global default.
10. Top-level `raw_envelope` config supplies the global default and is
    reflected in normalized config storage.
11. Shared raw envelope policy resolver applies tool > upstream >
    global > false precedence for both direct and agentic runtimes.
12. Direct aggregator mode rejects unknown top-level keys, forbidden
    raw-mode keys, and duplicate normalized keys as programmer faults.
13. `isError: true` envelopes return `:ok false :reason :tool_error`
   in both direct aggregator mode and agentic `ptc_task`.
14. MCP output schemas allow `tool_error` for diagnostic reason enums.
15. `isError: true` diagnostics use `tool_error` in `upstream_calls`,
    agentic ledger output, debug summaries, and tests.
16. Existing aggregate payload metric field names may remain unchanged;
    tests should assert their semantics still include tool errors if
    the fields remain generic.
17. Agentic `tool/mcp-call` rejects unknown/duplicate top-level args
    and returns keyword reasons in Lisp-visible failures.
18. Prompt tests assert:
   - tagged shape appears early
   - `mcp/text` and `mcp/json` are absent from MCP descriptions
   - metadata markers are excluded
   - MCP description byte budgets still pass
19. Function reference/tests assert `mcp/text` and `mcp/json` are no
    longer exposed builtins.

## 11. Migration Notes

Old:

```clojure
(let [r (tool/mcp-call {:server "observatory"
                        :tool "list_traces"
                        :args {}})]
  (get (mcp/json r) "traces"))
```

New:

```clojure
(let [r (tool/mcp-call {:server "observatory"
                        :tool "list_traces"
                        :args {}})]
  (if (:ok r)
    (get (:value r) "traces")
    (fail (:message r))))
```

Old:

```clojure
(nil? (tool/mcp-call {:server "github" :tool "search" :args {:q "x"}}))
```

New:

```clojure
(let [r (tool/mcp-call {:server "github" :tool "search" :args {:q "x"}})]
  (not (:ok r)))
```

Old raw envelope inspection:

```clojure
(get-in (tool/mcp-call {:server "x" :tool "y" :args {}})
        ["content" 0 "mimeType"])
```

New raw envelope inspection, when server config enables `raw_envelope`
for that upstream tool:

```clojure
(let [r (tool/mcp-call {:server "x"
                        :tool "y"
                        :args {}})]
  (when (:ok r)
    (get-in (:raw r) ["content" 0 "mimeType"])))
```

## 12. Implementation Order

1. Add shared unwrap helper in `:ptc_runner_mcp` for MCP envelopes.
2. Add raw envelope policy parsing/resolution to upstream config.
3. Change direct aggregator `tool/mcp-call` to tagged results.
4. Change agentic `tool/mcp-call` to the same success `:value`.
5. Update prompt cards and prompt tests.
6. Remove `mcp/text` and `mcp/json` builtins and function reference
   entries.
7. Update docs and examples.
8. Run focused tests, then full suite:
   - `mix test test/ptc_runner/lisp`
   - `mix test mcp_server/test/ptc_runner_mcp`
   - full `mix test` from repo root if practical

## 13. Resolved Questions

1. `:value_kind :json` covers both native `structuredContent` and
   parsed JSON text. Do not split the prompt-facing contract into
   `:structured` / `:json_text`. The common branch is "treat `:value`
   as data"; provenance belongs in `:raw` or in a future optional
   field only if a real caller needs it.
2. Multi-content, image/resource, or non-first-text responses that do
   not produce a default domain payload return
   `{:ok true :value nil :value_kind :none}`. Do not return compact
   content descriptors as the default `:value`; protocol-aware
   inspection belongs behind configured `:raw`.
