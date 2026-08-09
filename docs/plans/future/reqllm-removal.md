# ReqLLM removal and direct HTTP model adapter

**Status:** future, trigger-gated. Audited 2026-07-30 against the locked
`req_llm 1.17.1` and the current `PtcRunner.LLM` adapter boundary.

PtcRunner reaches language models through one arity-1 `requester` function.
`PtcRunner.Kernel.LLMCapability` documents that the supplied requester owns
transport and credential handling, and `PtcRunner.LLM.callback/2` dispatches
through an adapter behaviour with `call/2`, optional `stream/2`, and optional
`ensure_ready/0`. `ReqLLM` is therefore one implementation behind a stable
seam, not an architectural commitment.

The current adapter already bypasses it for two of its three routes:
`ollama:model` and `openai-compat:base_url|model` call `Req.post` directly,
and only the catch-all `provider:model` route reaches ReqLLM.

## Trigger

Start this work when any condition holds:

- a deployment needs an OpenAI-compatible endpoint ReqLLM does not model, or
  needs request construction the SDK does not expose;
- ownership of request semantics becomes a requirement — single-attempt
  dispatch, no redirects, exact response caps, and exact timeout accounting
  must be properties of code this repository owns rather than assertions about
  an SDK across version bumps; or
- packaged artifact size or dependency-review surface becomes a release
  constraint.

Do not start it to suppress dependency warnings. `IO.warn` writes to stderr,
never to the command envelope, and the shipped fix for the one known warning is
to pass a structured model value instead of a string spec.

The packaged output audit is deliberately not a trigger, though the reason
changed when
[`../lisp-kernel/stable-cli-contract.md`](../lisp-kernel/stable-cli-contract.md)
withdrew the outer standalone wrapper. It no longer holds because a wrapper
isolates dependency stdout behind a private descriptor; it holds because the
command envelope is written to a caller-named file and never travels on stdout
at all. Dependency stdout noise therefore cannot reach the envelope under any
dependency closure, and the conclusion survives the withdrawal with a simpler
argument. Secret-bearing stderr remains worth watching on its own merits, but
the descriptor-bypass sentinel matrix went with the wrapper.

## Current evidence

Dependency closure size, counted as physical lines in the locked
`deps/<name>/lib/**/*.ex` tree:

| Dependency | Locked version | Lines | Optional |
| --- | --- | ---: | --- |
| `req_llm` | `1.17.1` | 60,564 | yes |
| `llm_db` | `2026.7.2` | 15,857 | via `req_llm` |
| `req` | `0.6.3` | 8,498 | no |
| `jsv` | `0.21.2` | 12,339 | no |
| `jason` | `1.4.5` | 2,549 | no |
| `nimble_parsec` | `1.4.2` | 3,556 | no |

`req_llm` plus `llm_db` is roughly 76,000 lines, more than the library itself.
That is the dependency-review and artifact-size surface the third trigger
refers to. It is not an argument about command output, which no longer depends
on any dependency's stream behavior now that the envelope is written to a
caller-named file. This table is a size inventory, not a warning-reachability
inventory; secret-bearing stderr remains worth watching on its own merits,
without a dependency-version-pinned inventory of every reachable call site.

The request and response formats crossing the adapter seam are deliberately
close to OpenAI's wire format:

- `LLMCapability` accepts `system`, `messages`, `tools`, and `cache`;
- `ProviderRegistry.adapter_request/1` forwards exactly those keys and
  normalizes messages to `role`, `content`, `tool_calls`, and `tool_call_id`;
- `to_req_llm_tool/1` destructures `%{"type" => "function", "function" => _}`;
  and
- `normalize_tool_calls/1` reads `function.arguments` as a JSON string and
  emits `%{id:, name:, args:}`.

They are not wire-identical. The direct adapter owns explicit bounded codecs:
on request, it inserts `system` into the message sequence, converts internal
role atoms to wire strings, translates or consumes the internal `cache` policy,
and JSON-encodes internal tool-call argument maps; on response, it validates
the assistant/tool-call shape and boundedly decodes each
`function.arguments` JSON string into the existing normalized
`%{id:, name:, args:}` form. Missing, `null`, malformed, oversized, or
non-object arguments have closed error outcomes. Removing ReqLLM deletes its
conversion layer, but does not delete the required wire boundary.

## What removal buys

These are consequences for the stable CLI plan, not independent goals:

- the `ProviderRuntime` gate loses its entire ReqLLM-specific branch:
  serialized manager, instance-bound safe-start record, monitored
  `ReqLLM.Supervisor` PID, `DOWN` invalidation, and atomic registered-PID
  re-verification all exist because `req_llm` is an optional OTP application
  that loads dotenv at startup. `req` is already a required dependency with no
  dotenv and no credential access at boot, and Finch pools are lazy, so no
  shipped provider needs a post-marker application start.

  The generic gate does not disappear. A custom embedded provider kind may
  still declare an OTP application dependency, so the `:standalone_vm` /
  `:mix_cli` / `:host_owned` ownership distinction and
  `active_preflight/provider_application_unavailable` remain. What is removed
  is the dotenv-safety machinery and the shipped-provider path through it;
- the `req_llm`/`llm_db` `load_dotenv` configuration requirement and its
  sentinel `.env` regressions collapse to the project's own
  `PtcRunner.Dotenv`;
- the ReqLLM structured-resolution requirement and its dependency-version
  audit disappear;
- `ensure_ready/0`, which exists only to pre-decode the `llm_db` catalog
  outside a bounded worker so it does not exceed a heap ceiling, is no longer
  needed;
- a reviewed shipped descriptor may use an authenticated, model-specific
  metadata endpoint for `probe_effect: metadata`. A public model list, an
  endpoint that ignores the supplied credential, or a response that does not
  establish access to the selected model is not sufficient. Shipped sources
  without a qualifying metadata operation retain the stable plan's one-token
  `probe_effect: completion` and ambiguous
  `active_preflight/connectivity_outcome_unknown`; removal of ReqLLM alone does
  not change the probe effect; and
- single-attempt, no-redirect, response-capped requests become properties of
  code this repository owns rather than assertions about an SDK's behavior
  across version bumps.

## Required shape

Removal must preserve the existing capability contract exactly:

- the adapter implements the current behaviour: `call/2` required, `stream/2`
  optional with the documented `{:error, :streaming_not_supported}` fallback;
- probe, `call/2`, and `stream/2` share one code-owned bounded HTTP transport.
  It owns the stable plan's single-attempt, no-redirect, identity-encoding,
  compressed-transfer rejection, and response-cap rules. The V1 primitive is a
  small code-owned passive HTTP/1 client; Req may build the JSON body and run
  codecs, but Req/Finch/Mint execution, retry, redirect, decompression, pooling,
  and body-collection steps do not run. Its socket backend must implement
  `recv_up_to(max_bytes, deadline)`, returning promptly after one or more bytes
  are available, never returning more than the positive maximum, and preserving
  the single monotonic deadline. Plain TCP uses OTP `:socket.recv/4` in
  nowait/select mode so partial data is delivered without an exact-length wait.
  The packaged TLS backend must prove the same semantics while performing peer
  and hostname verification, SNI, the packaged in-memory CA trust source, and
  ALPN restricted to `http/1.1`. If OTP `:ssl` cannot provide that proven bound,
  the standalone package uses a small code-owned length-framed port helper whose
  frames are capped before entering BEAM; a host-owned/cloud embedding may
  inject an equivalent in-memory backend. The helper's captured stderr,
  lifecycle, and cleanup follow the stable provider-resource contract. Failure
  of both packaged implementations blocks the route; falling back to
  `recv(..., 0)`, an exact positive-length read, or an unbounded library executor
  is not allowed. The request asks the server to close the connection after one
  response. Before connect/send, its serializer applies the stable plan's three
  distinct bounded grammars: the closed method enum, a generated origin-form
  target starting with `/` whose validated path segments receive required
  percent-encoding and contain no raw space/control/fragment delimiter, HTTP
  token header names, and visible-ASCII header values that permit spaces such as
  the one in `Authorization: Bearer <credential>` but reject CR/LF, NUL, other
  controls, obs-fold, and non-ASCII bytes. The target constructor splits an
  endpoint's raw path only on literal `/`, validates and percent-decodes within
  each segment exactly once, rejects a decoded slash, backslash, NUL, or control,
  retains empty segments, and appends only the adapter's fixed operation
  segments; the serializer then encodes every segment once. Credentials that do
  not fit the header-value grammar fail closed. Individual component and
  aggregate header count/byte caps apply.

  The strict incremental parser consumes only `recv_up_to` chunks. Status,
  header, informational-response, chunk-size, and trailer lines each have a
  line-size ceiling; separate aggregate
  head/trailer byte, field-count, and informational-response-count ceilings
  reject an unterminated line or repeated `1xx` sequence before unbounded
  accumulation. After validating the final response headers, it admits only a
  valid `Content-Length` or ordinary chunked body; close-delimited bodies are
  unsupported. For either admitted framing, ask the backend for at most the
  lesser of the unread framed payload, fixed quantum, and remaining payload
  budget plus one. The parser may receive less and carries bounded partial
  framing state across calls, so a large HTTP chunk delivered as many small SSE
  writes produces prompt deltas. Count each identity payload piece before
  retaining or decoding it and close on cap-plus-one overflow. This gives an
  exact decoded payload bound without a pool or library-owned redispatch.
  HTTP/2 is unsupported until a packaged spike proves the same bounded
  delivery/backpressure and ownership of every transparent retry layer. Probes
  use the standalone plan's identity-excluded
  `doctor_connectivity_timeout_ms`; ordinary calls and streams use the
  identity-bearing provider timeout defined by the model-boundary roadmap. Its
  completed LimitCatalog/schema/effective-digest contract and ReqLLM
  enforcement are a hard prerequisite for this removal plan; this plan does
  not define or opportunistically add that timeout. Streaming enforces both
  per-chunk and cumulative response bounds;
- `llm-request` keeps `system`, `messages`, `tools`, and `cache`. Provider
  function calling is part of the public capability, not an extra: workflow
  code may pass `tools` and receive `tool_calls`, and messages may carry
  `tool_calls` and `tool_call_id`;
- token usage continues to come from the response body, and so does cost
  wherever the provider reports it. This aligns with the model-boundary
  requirement in
  [`../lisp-kernel/product-readiness.md`](../lisp-kernel/product-readiness.md)
  that token and cost metadata be normalized *when a provider supplies it* and
  that provider-dependent missing metadata stay explicit rather than inferred.
  A local pricing catalog is exactly the inference that requirement excludes,
  so dropping `llm_db` moves toward the roadmap rather than against it.
  Every tagged source has a required, exact `usage_guarantees` object with
  boolean `tokens` and `cost` fields. Token- and cost-denominated ceilings are
  each available only when the corresponding field is true. An installation
  requesting a ceiling without that declaration fails closed at validation,
  and a response missing metadata that was declared guaranteed is a
  non-retryable protocol error rather than zero usage. Missing optional metadata
  remains explicitly absent;
- structured output is the one genuine gap. The compat route currently returns
  `{:error, :structured_output_not_supported}`. `response_format` is unevenly
  implemented across vLLM, llama.cpp, and Ollama's OpenAI shim, so the
  installation declares a closed capability mode — `json_schema`,
  `json_object`, or `unsupported` — and the adapter fails closed on a request
  the declared mode cannot satisfy. Prompt-and-parse is not a default
  fallback; it is a separate opt-in mode with its own bounded parser, because
  silent degradation from schema enforcement to text parsing produces failures
  that surface as bad model output rather than as configuration errors; and
- credentials continue to arrive through the existing resolver. The adapter
  never reads an environment variable or a file itself; and
- the stable seam being preserved is the `PtcRunner.LLM` adapter behaviour and
  Kernel `llm-request` capability, not the current
  `ReqLLMAdapter.generate_*`, `embed/3`, `embed!/3`, `available?/1`, or
  `requires_api_key?/1` convenience surface. Delete those adapter-specific
  helpers and migrate their test/support callers. There is no provider-neutral
  embedding behaviour today; adding one is separate work. Provider readiness
  belongs to the installed local/credential/connectivity checks above, not a
  boolean helper that reads environment variables or calls a public model list.

Restructure the host model source before making the direct adapter selectable.
Replace string-encoded routing with a closed tagged source: `openai_compat`
carries separate `base_url`, `model`, and `credential_ref`; `ollama` carries
its endpoint, model, and optional credential reference; and the transitional
`req_llm` kind carries separate provider, model, and credential reference
fields. Every kind also carries the required closed `usage_guarantees` object
above. The last kind is deleted with ReqLLM. No route reconstructs or passes a
combined selector string.

The parsed source is still secret-bearing configuration, not a safe diagnostic
value. Validate an HTTP endpoint as `http` or `https` with a nonempty host and
reject URL userinfo, query, and fragment components. A credential-bearing
target requires `https`; plain `http` is allowed only for a loopback target with
no credential. Authorization is legal only through `credential_ref`. Compile
the source into an opaque
`PtcRunner.LLM.Target` whose private fields contain the endpoint, model,
provider, credential reference, and usage guarantees, but never the resolved
credential bytes.
The type has a code-owned constructor, a fully redacted `Inspect`
implementation, and no JSON/Enumerable implementation. Only the adapter and
credential resolver receive the raw target. All diagnostics, traces, provider
snapshots, model listings, and effective-identity inputs continue to receive
exactly the stable plan's existing bounded safe provider projection: installed
alias, generic descriptor source `llm`, public `installation_revision`, data
policy, destinations, and normalized selection where applicable. Target kind,
endpoint, model, credential reference, usage guarantees, and structured-output
mode remain private and are represented publicly and in effective identity only
through the host-maintained `installation_revision`; changing any of them
requires a new revision. They are not added to the closed V1 `models` shape.
Thus field separation prevents selector reconstruction, while the
opaque/raw-versus-safe split enforces the CLI plan's broader redaction rule.

## Future slices

**Prerequisite:** the product-readiness model-boundary slice has fully defined
and implemented the ordinary provider timeout, including its default, range,
host/manifest narrowing, total streaming semantics, interaction with remaining
run time, LimitCatalog/schema/effective-identity participation, usage ceilings
and missing-usage outcomes, and enforcement through the existing ReqLLM path.

1. Introduce `PtcRunner.LLM.Target` and the closed tagged host model source
   above. Change the `PtcRunner.LLM` adapter behaviour so `call/2` and
   `stream/2` accept that target, and migrate `PtcRunner.LLM.call/2`,
   `stream/2`, and `callback/2`; `PtcRunner.LLM.Registry`,
   `DefaultRegistry`, and any configured custom registry contract;
   `ProviderRegistry`; both existing direct routes; the still-selectable
   `ReqLLMAdapter`; configured custom adapters; and their callers.
   Registry alias resolution now returns a target rather than a combined
   provider/model string, and custom adapters receive the same opaque type.
   Regenerate `priv/schemas/ptc-host-config.schema.json` and update the retained
   LLM and host-configuration guides. Because this is a 0.x library, delete the
   string selector rather than adding a compatibility parser. Migrate
   generation callers to the behaviour seam and delete the adapter-specific
   embedding/availability/credential helper calls and tests described above.
   Add exact-key/type tests for `usage_guarantees`, ceiling/guarantee
   compatibility and missing promised metadata; URL/auth rejection tests; plus
   `Inspect`, diagnostics, model-list, snapshot, trace, and effective-identity
   leak sentinels. Existing
   Ollama/OpenAI-compatible/ReqLLM E2E, custom-adapter, registry, and
   adapter-parity fixtures must pass at the end of this independently releasable
   slice.
2. Build `PtcRunner.LLM.ReqAdapter` over `Req` for OpenAI-compatible endpoints
   and Ollama, implementing text, tools, and streaming through the explicit
   request/response codecs and shared bounded HTTP transport above. Keep
   `ReqLLMAdapter` selectable so both can run against the same fixtures. Tool
   coverage is a full round trip, not request-side only:
   system-message and cache-policy translation; atom/string role conversion;
   internal argument-map encoding; assistant messages carrying `tool_calls`;
   subsequent `role: "tool"` messages with `tool_call_id`; parallel calls in one
   response; absent, `null`, oversized, non-object, or invalid-JSON `arguments`;
   and a `tool_calls` entry naming a tool the request never declared. Each has a
   defined closed outcome; none may raise out of the adapter. Probe, ordinary
   calls, and streams receive parity fixtures for redirects, content and
   transfer compression, their distinct installed deadlines, missing promised
   usage, and cumulative response caps. Dedicated transport tests exercise
   unterminated/oversized status and header lines, repeated informational
   responses, coalesced headers and an oversized body, a short keep-alive
   content-length response, a final short chunk, one large announced chunk
   delivered through many small SSE writes, and a server that floods beyond the
   cap. TCP and TLS/backend conformance prove `recv_up_to` never exceeds its
   request, returns available partial data without waiting for the maximum, and
   obeys the total deadline; helper frames over the limit fail before body
   parsing. Request-serialization fixtures accept `/v1/chat/completions` and a
   canonical `Authorization: Bearer <credential>` field, verify exact-once
   percent-encoding of admitted path segments—including a base-path `%20`
   fixture that must not become `%2520`—reject invalid percent triplets, decoded
   slash/backslash, raw spaces, CR/LF, NUL, other controls, or fragments in the
   origin-form target, and reject invalid header-name or header-value
   bytes—including resolved authorization—before connect/send while enforcing
   request header count/byte caps. Together these prove one
   connection/attempt, bounded framing state, injection-safe serialization, and
   no unbounded buffering.
3. Define and implement the private structured-output capability modes above,
   extending the target and host schema without changing the V1 public provider
   projection. This slice carries the behavioral risk and should gate the rest.
4. Run the existing E2E suite against the new adapter through an
   OpenAI-compatible endpoint, then move `req_llm` and `llm_db` to
   `only: [:dev, :test]` before removing them.

Each slice updates generated schemas and durable module/guide documentation,
passes `mix precommit`, and receives a clean independent review.

## Non-goals

- reimplementing provider-native APIs that are not OpenAI-compatible, including
  Bedrock SigV4 signing and Anthropic's native message format. Endpoints that
  front those models behind a compatible surface remain the supported path;
- a model catalog, pricing table, or capability-detection database; and
- changing `LLMCapability`, the `requester` seam, or the `llm-request` public
  contract. The target-type migration changes the transport-facing
  `PtcRunner.LLM` and registry APIs, but not the Kernel capability boundary
  above them.
