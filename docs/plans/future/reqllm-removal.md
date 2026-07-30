# ReqLLM removal and direct HTTP model adapter

**Status:** future, trigger-gated. Audited 2026-07-30 against
`req_llm 1.8` and the current `PtcRunner.LLM` adapter boundary.

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
never to the stdout envelope, and the shipped fix for the one known warning is
to pass a structured model value instead of a string spec.

The packaged output audit is deliberately not a trigger. If the standalone
wrapper adopts the separate-descriptor envelope design under evaluation in
[`../lisp-kernel/stable-cli-contract.md`](../lisp-kernel/stable-cli-contract.md),
stdout framing stops depending on dependency-closure behavior and that
motivation disappears. Secret-bearing stderr paths still need auditing either
way, and that audit is not dominated by this dependency.

## Current evidence

Dependency closure size, in lines of `lib/**/*.ex`:

| Dependency | Lines | Optional | Real `IO.warn` sites |
| --- | ---: | --- | ---: |
| `req_llm` | 60,564 | yes | 5 |
| `llm_db` | 15,857 | via `req_llm` | 0 |
| `req` | 8,498 | no | 3 |
| `jsv` | 12,339 | no | 6 |
| `jason` | 2,549 | no | 0 |
| `nimble_parsec` | 3,556 | no | 0 |

`req_llm` plus `llm_db` is roughly 76,000 lines, more than the library itself.
That is the dependency-review and artifact-size surface the third trigger
refers to. It is not an argument about stdout framing, which the separate
descriptor design addresses independently.

The request and response formats crossing the adapter seam are already
OpenAI's wire format:

- `LLMCapability` accepts `system`, `messages`, `tools`, and `cache`;
- `ProviderRegistry.adapter_request/1` forwards exactly those keys and
  normalizes messages to `role`, `content`, `tool_calls`, and `tool_call_id`;
- `to_req_llm_tool/1` destructures `%{"type" => "function", "function" => _}`;
  and
- `normalize_tool_calls/1` reads `function.arguments` as a JSON string and
  emits `%{id:, name:, args:}`.

Against an OpenAI-compatible endpoint those conversions are pure overhead. A
direct adapter forwards the maps and deletes both.

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
- `GET /v1/models` is a standard OpenAI-compatible metadata endpoint, so the
  doctor connectivity probe can declare `probe_effect: metadata` for every
  shipped source. `probe_effect: completion` and
  `active_preflight/connectivity_outcome_unknown` become custom-provider-only
  or leave V1 entirely; and
- single-attempt, no-redirect, response-capped requests become properties of
  code this repository owns rather than assertions about an SDK's behavior
  across version bumps.

## Required shape

Removal must preserve the existing capability contract exactly:

- the adapter implements the current behaviour: `call/2` required, `stream/2`
  optional with the documented `{:error, :streaming_not_supported}` fallback;
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
  Enforceable ceilings are therefore token-denominated always and
  cost-denominated only where the provider reports cost; an installation
  requesting a cost ceiling against a provider that reports none must fail
  closed at validation rather than silently not enforcing it;
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
  never reads an environment variable or a file itself.

Restructure the host model source in the same change. Replace the
`openai-compat:base_url|model` single-string selector with separate
`base_url`, `model`, and `credential_ref` fields. If compat becomes the primary
route, every installation carries a base URL in its selector, and the CLI
plan's selector-redaction rule becomes structural instead of a rule enforced at
each rendering site.

## Future slices

1. Build `PtcRunner.LLM.ReqAdapter` over `Req` for OpenAI-compatible endpoints
   and Ollama, implementing text, tools, and streaming. Keep `ReqLLMAdapter`
   selectable so both can run against the same fixtures. Tool coverage is a
   full round trip, not request-side only: assistant messages carrying
   `tool_calls`, subsequent `role: "tool"` messages with `tool_call_id`,
   parallel calls in one response, absent or `null` `arguments`, arguments
   that are not valid JSON, and a `tool_calls` entry naming a tool the request
   never declared. Each has a defined closed outcome; none may raise out of
   the adapter.
2. Decide and implement the structured-output capability modes above. This
   slice carries the behavioral risk and should gate the rest.
3. Split the host model source into `base_url`, `model`, and `credential_ref`,
   regenerate `priv/schemas/ptc-host-config.schema.json`, and update the
   retained host-configuration guide.
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
  contract. This work replaces one adapter, nothing above it.
