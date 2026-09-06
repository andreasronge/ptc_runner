# LLM transport migration and ReqLLM removal

**Status:** feature inventory and deferred migration options. The
[bounded transport pilot](../llm-transport-pilot.md) owns the immediate work;
default switching, broad migration, and dependency removal are deferred.
The [pilot comparison](../evidence/llm-transport-comparison.md) now records a
working lab adapter and upstream fixes, including a successful live tool
workflow. These are unpublished source fixes, not a replacement for the
consumer release checkpoint.
Inventory refreshed on 2026-09-06 against
PtcRunner `fe88b0fb3`, whose lockfile selects `req_llm 1.21.1`,
`llm_db 2026.8.4`, and dev/test-only `ptc_llm_http 0.1.0`.

The pilot evaluates `ptc_llm_http` for bounded HTTP execution while retaining
LLMDB as a host-side metadata and pricing source. Adoption depends on measured
benefit over configured ReqLLM/Finch. Keeping ReqLLM is a valid outcome.
Replacing transport and removing ReqLLM are separate decisions; neither implies
discarding the catalog or recreating every feature ReqLLM offers.

Related work: [MCP gateway #1465](https://github.com/andreasronge/ptc_runner/issues/1465),
[aggregate concurrency #1290](https://github.com/andreasronge/ptc_runner/issues/1290),
and [model contracts #1649](https://github.com/andreasronge/ptc_runner/issues/1649).
This plan records integration requirements; those issues' remaining work is
not assumed complete.

## Why migrate

The useful trigger is ownership of request semantics: one explicit attempt,
bounded incoming bytes, one absolute deadline, cancellation and cleanup before
capacity reuse, and aggregate admission for concurrent hosted runs. These are
the transport guarantees a serving deployment needs to demonstrate.

Pool contention alone does not require a new HTTP implementation. Admission
can also be implemented above ReqLLM/Finch. The separate transport is justified
by the combined ownership and resource contract, not an unmeasured throughput
claim. Its HTTP/1.1 `Connection: close` policy gives up connection reuse;
measure connection establishment, sustained traffic, and cancellation costs
before claiming a performance advantage.

## Current execution boundary

The authoritative implemented contracts are
[`PtcRunner.LLM`](../../../lib/ptc_runner/llm.ex),
[`Requirements`](../../../lib/ptc_runner/llm/requirements.ex),
[`Invocation`](../../../lib/ptc_runner/llm/invocation.ex), and the
[host installation reference](../../reference/host-installation.md).

- `LLM.prepare/2` seals the selector and exact requirements through the
  adapter's `prepare_model/2`. It produces a `PreparedModel`, containing
  an adapter-owned target and its attested requirements.
- `LLM.callback/2` binds a credential and cache flag and returns an
  **arity-two** requester. `call/2` receives the adapter target and a closed
  `Invocation`, including the per-call deadline.
- `reservation_bound/3` is optional on the behaviour, but required when the
  selected operational budgets need an attested reservation.
- `ensure_ready/0`, `provider_application/1`, and `public_model/1`
  cover metadata warmup, dependency lifecycle, and safe public identity.
- There is **no current streaming callback or Kernel streaming path**.
  The remaining chunk type and `build_stream_done_chunk/1` helper do not
  constitute one.

The old plan's arity-one requester, stream migration, internal `ReqAdapter`,
and mandatory new tagged-target API are not the current implementation.
Use the existing prepared-target boundary first. A host-source redesign needs
its own concrete requirement and migration decision.

## Inventory of actual use

This is a source and checked-in caller inventory, not a measurement of
downstream deployments. An exposed native-provider path cannot be deleted
merely because the runnable examples prefer OpenRouter. Test coverage proves
the stated boundary, not live availability or complete provider support.

The main implementation is
[`ReqLLMAdapter`](../../../lib/ptc_runner/llm/req_llm_adapter.ex).
Primary verification sources are the
[adapter tests](../../../test/ptc_runner/llm/req_llm_adapter_test.exs),
[request tests](../../../test/ptc_runner/llm/req_llm_adapter_request_test.exs),
[model-contract tests](../../../test/ptc_runner/kernel/model_contract_test.exs),
and [host-installation tests](../../../test/ptc_runner/kernel/host_installation_test.exs).

| Feature | Current PtcRunner use and evidence | Migration requirement |
| --- | --- | --- |
| Text completions | Kernel `llm/request` and model-backed examples use adapter `call/2`; `generate_text` implements the text route. | Preserve normalized content, usage, errors, and deadlines. |
| Function tools and conversation history | Agent loops send tools and consume tool calls. The adapter translates schemas, assistant tool calls, ordered tool results, IDs, and argument maps. PtcRunner owns tool execution; ReqLLM tool callbacks are placeholders. | Preserve complete round trips, multiple calls, and closed outcomes for malformed or unsupported tool calling. Compare schema dialects rather than assuming codec parity. |
| Structured output | Installed `json_schema`, `json_object`, or `unsupported` mode is attested before execution; schema plus non-empty tools is rejected. Kernel returns validated `structured_output`. | Preserve mode and result semantics without prompt-and-parse fallback or duplicated encoded content. Direct Ollama/compat routes currently refuse these modes; broader replacement support is an addition, not existing parity. |
| Exact inference controls | `Requirements.exact_options` admits max tokens, temperature, seed, top-p, presence/frequency penalties, and reasoning effort. Preparation checks provider translations and rejects known lossy mappings. | Implement every retained control exactly or reject the installation before dispatch; never silently omit it. |
| Output and context limits | The ReqLLM path consults model metadata and a conservative serialized-byte input estimate to derive default output limits; configured limits are attested. Tool-response truncation carries authenticated output-limit attribution. No tokenizer integration is used. | Preserve sealed caps, default narrowing, and truncation attribution. Verify the codec cannot drop or increase the installed output cap. |
| Model resolution and capabilities | ReqLLM resolves LLMDB models and uncataloged provider selectors. PtcRunner uses metadata for reasoning/structured-mode checks, context limits, reservation pricing, and catalog warnings. | Retain catalog lookup and safe uncataloged behavior. Catalog presence alone does not prove codec support, permissions, or current endpoint availability. |
| Prompt caching and routing | `apply_caching/3` handles direct Anthropic, Anthropic through OpenRouter, and Bedrock cache options. OpenRouter cache handling pins Anthropic and disables fallback. Other models can treat the flag as a no-op. Adapter fixtures exercise these branches. | Preserve both cache encoding and required routing for retained installations. Cache policy is distinct from receiving a cached-token count. |
| Token and cache observations | Responses normalize input/output, cache reads, and cache creation, including provider-specific nested fields. The closed Kernel usage map has no independent reasoning-token counter. | Preserve existing observations and missing-usage rules; explicitly decide any richer usage projection. Do not invent cache-write counts or double-count cached/reasoning tokens. |
| Prices and calculated cost | LLMDB supplies simple rates and pricing components; ReqLLM billing combines metadata with normalized usage. PtcRunner can consume ReqLLM's calculated `total_cost`. | Retain a versioned catalog and an explicit calculation owner. Keep estimates distinguishable from provider-reported charges. |
| Reported cost | PtcRunner specially preserves OpenRouter's raw `usage.cost` before ReqLLM normalization. Kernel accepts bounded decimal values and converts cost to integer USD microunits. | Preserve reported charges, currency, precision policy, optional absence, and guaranteed-usage failures. |
| Pre-dispatch token/cost reservations | Adapter `reservation_bound/3` uses conservative request/output bounds and LLMDB pricing; Kernel owns the operational ledger, overrun, and incomplete accounting. | Retain request-specific attestation and tariff identity. An eventual response charge cannot substitute for a reservation. |
| Provider protocols and credentials | The documented surface includes OpenRouter, native Anthropic/OpenAI/Google/Groq/Bedrock; provider-specific options and authentication flow through ReqLLM. Preparation/request fixtures cover native paths. | Retain ReqLLM for unmigrated paths until there is tested replacement support, an explicit endpoint migration, or an approved removal decision. |
| Direct local/compatible routes | `ollama:` text uses native `/api/generate`; `openai-compat:` uses chat completions. These already use `Req.post` instead of ReqLLM and have distinct limits/support. | Include both direct paths in the transport audit. OpenAI-compatible Ollama is not automatically equivalent to the current native route. |
| Errors, retry policy, and diagnostics | PtcRunner normalizes ReqLLM/provider errors, quota/refusal versus transport failures, usage warnings, and token-limit metadata. Hidden Req/ReqLLM retries are explicitly disabled for budgeted prepared targets, not universally. | Map closed transport facts to current Kernel vocabulary without hidden retries, provider-text leaks, or heuristic success salvage. Universal single-attempt execution is a stronger transport contract. |
| Preparation, doctor, and application ownership | Local preparation and connectivity checks use the adapter; `ProviderApplicationGate` manages command-owned versus host-owned startup and dotenv rules. Catalog warmup avoids loading metadata inside a small request heap. | Preserve inert preparation, explicit credentials, probe contracts, redaction, and lifecycle. Retaining LLMDB means warmup remains relevant. |
| Embeddings | `embed/3` and `embed!/3` are adapter convenience APIs; no library workflow, example, or benchmark consumer was found. An error-format test calls the helper. | No new embedding codec is required for the first Kernel migration. Decide removal of the convenience API explicitly at adapter retirement; external use is unknown. |
| Availability and generation helpers | `available?/1`, `requires_api_key?/1`, and generation/bang helpers are adapter-specific surfaces. Generation helpers also implement the live adapter routes. | Move required internals/callers to the selected adapter; retire convenience exports deliberately. Preserve doctor rather than substituting environment-reading helpers. |
| Streaming | No execution API uses it on current main. The separate HTTP compatibility smoke exercises callback streaming; closed PR #1575 proposed a new streaming surface. | Treat streaming as separate integration scope, justified by a concrete consumer. Do not restore an obsolete API as a supposed parity requirement. |
| Other ReqLLM products | No current Kernel paths were found for image/audio generation, transcription, reranking, OCR, batch jobs, or provider-hosted search/code-execution tools. | Do not recreate these features for this migration. Caller-supplied function tools remain in scope. |

Checked-in model-backed examples use OpenRouter and `cache: false`.
The Viewer lab sets `cache: true` with a DeepSeek selector, for which the
current explicit cache policy is a no-op; that is not live evidence for
Anthropic cache writes. Neither private deployment configuration nor live
provider/model availability was audited here. At implementation checkpoints,
inspect relevant model overrides without exposing credentials, and verify the
exact selected provider/model with its intended call shape.

## Keep metadata and accounting outside the HTTP library

LLMDB's packaged `priv/llm_db/snapshot.json` supplies model data.
`LLMDB.Model.cost` contains per-million-token input, output, cache-read,
cache-write, and reasoning rates; `pricing.components` describes richer
billable units. See the
[locked LLMDB pricing source](https://hex.pm/packages/llm_db/2026.8.4/files/lib/llm_db/pricing.ex).
ReqLLM's `Usage.Cost` and `Billing` own calculated cost; LLMDB alone
does not replace that calculation.

The proposed ownership is:

| Owner | Planned responsibility |
| --- | --- |
| `ptc_llm_http` | Bounded transport, supported request/response codecs, reported usage facts, physical-attempt admission |
| Host-side metadata integration | Pinned LLMDB snapshot, selected model/capability data, pricing provenance and any reviewed host override |
| PtcRunner adapter/accounting | Exact option mapping, usage normalization, separately identified estimates, reservation attestation, trace projection |
| Kernel and hosting layer | Run budgets, workflow admission, cancellation, immutable identity, credential authority |

Retain LLMDB outside `ptc_llm_http`. If ReqLLM is eventually removed,
declare LLMDB as an explicit dependency or select a reviewed, versioned
metadata export. Do not maintain an ad hoc price table or assume a model
alias's rates are identical across providers. Do not claim removing ReqLLM
also removes Req/Finch/Mint from PtcRunner: other consumers and the catalog's
dependency closure require a separate audit.

Retirement also touches the default adapter and optional dependency in
[`mix.exs`](../../../mix.exs), release application loading, Dialyzer apps,
[`ProviderApplicationGate`](../../../lib/ptc_runner/kernel/provider_application_gate.ex),
host/catalog validation of `:req_llm` application ownership, and the
[standalone release assertion](../../../scripts/verify_standalone_release.sh).
The current gate already sizes a command-owned Finch pool from installed
`live_provider_tasks`. Replacing the adapter module alone would leave these
lifecycle and packaging assumptions behind.

Before accounting cutover, settle these contracts:

- **Reported versus estimated:** preserve a provider-reported charge when
  available. Catalog-derived cost is an estimate with its own provenance,
  never relabeled as an observed invoice amount. Current ReqLLM-derived
  `total_cost` can be calculated; the migration must explicitly resolve how
  estimates interact with `usage_guarantees.cost_currency` and the ledger.
- **Reservation versus settlement:** `reservation_tariff.id` identifies a
  tariff but supplies no rates. Preserve conservative reservation bounds,
  missing-pricing refusal, full-reservation charging on uncertain outcomes,
  and actual-usage overrun behavior. Unknown rates must not become zero.
- **Cache and reasoning arithmetic:** establish whether each provider includes
  cached/created tokens in input and reasoning in output. Apply read/write
  rates and any supported TTL/tier conditions without double-counting.
  The pilot adds separate cache-write observations upstream; the published
  `0.1.0` pin still lacks them.
- **Reproducible prices:** bind the selected rate snapshot and override
  identity during preparation. Do not refresh rates halfway through a run.
  Define host refresh and stale/absent metadata policy before promising cost
  ceilings from those rates.
- **Supported billables:** preserve refusal of unsupported pricing rather
  than under-reserving. Today's reservation implementation handles supported
  token components and request fees; positive image or unknown billables can
  prevent attestation. It is not a general provider billing engine.

## Replacement readiness and existing work

Library source was inspected at
[`ptc_llm_http 3830a93`](https://github.com/andreasronge/ptc_llm_http/tree/3830a93db2214b7f46844dcf3f026f4edc7b54fa).
That source is newer than PtcRunner's published `0.1.0` compatibility pin.
The package has bounded HTTP/1 execution, OpenAI-compatible text, function
tools, structured output, and synchronous text streaming. This is not evidence
that the current PtcRunner contracts have all been integrated.

Concrete gaps at that original source checkpoint (the pilot fixes finish
reasons, cache-write observations, bounded decimal cost, and indexed
non-stream OpenRouter tools on an isolated upstream branch; the evidence
record pins that branch):

- Request controls expose `max_tokens`, `temperature`, and `seed`;
  top-p, penalties, and reasoning effort need implementation or explicit
  installation rejection.
- `cache: true` and `upstream_routing: :single_provider` are rejected.
  That cannot preserve the existing explicit Anthropic/OpenRouter cache route.
- Usage has prompt/completion/total/cached tokens and optional numeric cost;
  it lacks separate cache-write usage and bounded decimal-string cost parity.
- The library owns no catalog, price calculation, or Kernel reservation
  attestation. Those remain integration work.
- It has only an OpenAI-compatible codec. Native providers and their
  authentication are not replaced.
- Tools and structured schemas have their own strict dialect and size bounds.
  Compare them with the Kernel's accepted surface and error classifications.
- Streaming is text-only. It is independently available but is not a reason
  to expand the current Kernel API during transport integration.

Recover useful assets from the two PRs closed unmerged on 2026-09-01:

| Asset | Reuse and revision |
| --- | --- |
| [Adapter #1575](https://github.com/andreasronge/ptc_runner/pull/1575) | Recover normalization and deterministic/live fixtures from remote head `8da0265b9`; the local trial branch lacks its last two regression commits. Rework against `Requirements`, `Invocation`, and reservations. Do not blindly restore its streaming API, hardcoded eight-slot single group, or old usage contract. |
| [Gateway #1482](https://github.com/andreasronge/ptc_runner/pull/1482) | Recover compile-once `ServingTemplate`, package acquisition, request ownership, stdio/HTTP companion, and cancellation tests from `d752a5fd9`. Reconcile with current preparation, evidence, and identity. |
| #1482 hosting admission | Replace ReqLLM/Finch pool-geometry coupling when using the new transport. Review the old permanent VM-poisoning policy against the HTTP runtime's generation fencing. Keep workflow admission distinct from physical LLM attempts; justify any additional non-LLM provider-task gate. |
| [HTTP fixes #17](https://github.com/andreasronge/ptc_llm_http/pull/17), [#18](https://github.com/andreasronge/ptc_llm_http/pull/18), [#19](https://github.com/andreasronge/ptc_llm_http/pull/19) | Public error facts, OpenRouter terminal-usage acceptance, and cold DNS process-budget fixes are on library main after `0.1.0`. Publish and pin a tested release before consumer cutover. |

The gateway PR still listed packaging, official SDK conformance, provider
integration, and live release-smoke gaps. Historical green checks do not
establish current readiness. The relevant transport
[implementation plan](https://github.com/andreasronge/ptc_llm_http/blob/3830a93db2214b7f46844dcf3f026f4edc7b54fa/docs/plans/implementation.md)
owns parser/TLS hardening; do not duplicate that implementation in PtcRunner.

## Delivery checkpoints

These are conditional expansion and retirement checkpoints, not the next
implementation sequence. First complete the
[pilot's baseline, opt-in integration, and contention evaluation](../llm-transport-pilot.md).
Proceed here only after its evidence supports a further migration decision.
Pilot work may satisfy parts of these checkpoints for its selected installation;
record that evidence rather than repeating work or assuming broader parity.

1. **Agree the migration matrix.** For each active provider/installation,
   record retained protocol, exact controls, cache/routing policy, structured
   mode, usage guarantees, and budget requirements. Decide the estimate
   policy above. Catalog retention is the proposed default; native-provider
   removal, new streaming, and host-source redesign remain separate choices.
2. **Publish the corrected transport and prepare the adapter.** Reuse #1575
   fixtures, pin an exact release containing the three upstream fixes, and
   implement the current prepared-model/Invocation boundary. Ensure probes,
   ordinary calls, and direct-adapter use share the configured capacity
   domain. Resolve credentials only during authorized activation.
3. **Preserve metadata, accounting, and retained request features.** Wire
   LLMDB independently of transport, implement the chosen calculation and
   provenance contract, and satisfy exact controls, tools, structured output,
   cache, usage, output attribution, and reservation tests. Retain ReqLLM for
   unmigrated targets; no silent fallback or option dropping.
4. **Prove serving under contention.** Recover the smallest useful #1482
   hosting slice. Use one host-owned HTTP runtime across runs, with explicit
   total/group capacity. Bound whole-workflow admission and any queue
   separately. Do not create a fresh capacity domain per request. Prove
   caller/connection death drains work before admission permits reuse.
5. **Switch an explicit supported subset.** Run the same representative
   manifests through both adapters, including fresh-process public HTTPS.
   Record supported and refused installations. Complete the gateway's
   conformance and release checks before presenting it as deployable.
6. **Retire ReqLLM only after a separate decision.** Every used feature above
   must have a replacement, an explicit installation migration, or an approved
   removal. Migrate convenience callers; delete obsolete code and shims.
   Update dependency/lifecycle/package contracts without deleting catalog
   warmup or metadata merely because transport changed.

## Acceptance evidence

Use existing boundary tests as the baseline, including model/host contracts,
[`llm_budget_dispatcher_test.exs`](../../../test/ptc_runner/kernel/llm_budget_dispatcher_test.exs),
[`llm_budget_ledger_test.exs`](../../../test/ptc_runner/kernel/llm_budget_ledger_test.exs),
and [deadline tests](../../../test/ptc_runner/kernel/dispatcher_llm_deadline_test.exs).
Implementation slices need evidence for:

- Text, multi-turn tools, strict structured output, exact control rejection,
  output truncation attribution, unknown models, and missing pricing.
- Reported and estimated cost provenance; input/output/cache-read/cache-write
  fixtures; decimal precision; bounded reservations and uncertain settlement.
- Credential/private-target redaction and no remote work during preparation.
  Retain explicit host environment loading; do not use adapter conveniences
  that discover credentials themselves.
- Over-capacity concurrent Kernel runs and groups, bounded saturation,
  deadlines, caller death, provider failure, owner restart, and readmission.
  Physical concurrency is not requests-per-minute/token-rate enforcement;
  add rate policy only for a concrete deployment requirement.
- Fresh-process cold DNS and the exact terminal-usage regression against the
  published pin. Live non-streaming success is required for the current
  Kernel path; live streaming evidence is required only when that separate
  integration is selected.
- Measured short/long request latency, throughput, connection setup overhead,
  and sustained cancellation/resource trends against the ReqLLM control.
  Do not infer production capacity from a single successful request.
- Current hooks/CI, relevant documentation/schema regeneration, exact-package
  checks, and the standalone/gateway release routes changed by each slice.
  Old PR test results and local unpublished fixes do not satisfy these gates.

The inventory itself is read-only evidence, not a claim that these migration
checks have run. Once implemented, move durable contracts to owning module
docs and retained references and delete completed planning material.
