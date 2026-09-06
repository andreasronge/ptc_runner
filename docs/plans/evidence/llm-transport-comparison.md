# LLM transport pilot comparison — 2026-09-06

## Decision

Keep ReqLLM as the default. Retain the explicit maintainer lab for the selected
OpenRouter workload. The replacement demonstrates fail-fast physical admission
and direct-call deadlines, but these observations do not justify a transport
switch or dependency removal. Both adapters pass the tested workflow-owner
and HTTP-disconnect cancellation chain.

The implementation slices of all three milestones now have local evidence.
The pilot's acceptance gates are **not complete**: there is no corrected
published pin, agreed deployment performance envelope, sustained TLS/reuse
comparison, or consistently successful live control. Gateway conformance and
release are separate work. Do not promote this lab by treating those gaps as
optional.

## Reproduce and identify

See the [lab instructions](../../../scripts/labs/llm-transport/README.md).
Use a fresh Mix VM and an isolated checkout of upstream branch
`codex/ptc-runner-pilot-parity` at
`9272decf5580c2ea1f28bed48d88e1e58ac127a1`. Its transport code is unchanged from
`afa5f115a0987903dc7578744dae491362733f8b`; the last commit adds release notes.
The original upstream checkout is untouched. Root defaults still select the
published dev/test-only `ptc_llm_http 0.1.0`. `PTC_LLM_HTTP_PATH` is an explicit
dev/test override, ignored in production.

The [local JSON report](llm-transport-comparison-2026-09-06.json) records the
root base, exact lab source hashes, upstream commit, samples, and process/port
observations. The [final paired live outcomes](llm-transport-live-2026-09-06.json)
retain the failed control as well as successful calls. These files contain no
credentials, provider text, generated programs, or ticket content.

ReqLLM is `1.21.1`; LLMDB is `2026.8.4`, also the named reservation tariff
snapshot. The selected manifest is `support-triage/01-one-question`, using
`openrouter:deepseek/deepseek-v4-flash`, `cache: false`, a 4096-token output cap,
and required input/output and USD cost observations. Its operational token
and cost ledgers are disabled; separate Dispatcher tests enable both budgets.
The fixture executes a count followed by an actual refund-subject filter,
including tool-result replay. The live run retains the manifest's original
three-turn limit and uses its generated programs.

The explicitly loaded maintainer environment selected
`PTC_TEST_MODEL=openrouter:google/gemini-3.1-flash-lite`; the lab deliberately
uses the manifest's DeepSeek selector instead. Current OpenRouter model and
usage documentation were checked before live calls. This does not certify
other models, routes, or current catalog prices.

## Implemented boundary

| Surface | Supported in the lab | Refused or deferred |
| --- | --- | --- |
| Preparation | Explicit OpenRouter selector; inert target; ReqLLM metadata and reservation attestation | Other providers; missing explicit output cap; exact top-p, penalties, or reasoning controls |
| Requests | Max tokens, temperature, seed; explicit credential; absolute deadline; text and tool-result history | Explicit cache enablement; automatic fallback or retries; streaming |
| Responses | Text; schema-validated tools; structured object; finish reason and authenticated output-limit attribution | Unsupported schema dialects and malformed/unknown wire shapes |
| Accounting | Present input/output, cache reads/writes, exact reported cost; zero distinct from missing; LLMDB-backed reservations | Missing required usage is an error; catalog estimates never substitute for required reported cost |
| Ownership | One host-owned runtime; global/group physical capacity two; cleanup before physical reuse | Runtime per request; implicit application startup or production adapter selection |
| HTTP serving experiment | One-workflow admission owner, no queue, 503 on excess, disconnect cancellation | MCP protocol, authentication, packaging, compile-once serving template, public deployment |

The adapter remains under `scripts/labs/`, not `lib/`. It intentionally keeps
ReqLLM preparation and pricing in place. Missing/unsupported pricing refusal
is delegated to the existing reservation implementation, whose boundary tests
were rerun; it is not reimplemented in the transport library.

## Findings

- The baseline Dispatcher enforces its 250 ms deadline under Finch saturation.
  A direct ReqLLM adapter call with the same deadline instead waits for Finch's
  approximately five-second checkout timeout. This is not a Dispatcher bug;
  its caller-owned HTTP execution is intentional for cancellation.
- The replacement immediately refuses an excess physical attempt as
  `not_dispatched`. Active-response deadlines close sockets and return its
  capacity. Runtime-owner death closes active sockets and later calls refuse
  locally instead of silently starting another capacity domain.
- Both adapters complete concurrent deterministic support-triage workflows.
  The batch records 20 workflows and exactly 40 provider attempts per adapter,
  at concurrency two. Short batch results vary in ordering between runs;
  they do not support a throughput claim. Both cohorts start and end with
  the same process and port counts in the captured sample.
- Both adapters settle the fixture's `0.0000051` USD charge as six integer
  microunits and 120 total tokens at the real Dispatcher boundary. Replacement
  tests preserve zero charges, conservatively settle missing usage as
  incomplete, and retain actual usage above a reservation as an overrun.
- Twenty-five two-caller cancellation/readmission cycles per adapter observe
  every held socket close. Replacement capacity returns to zero between
  cycles. This finite stress check is not a sustained leak test.
- The minimal serving handoff was recovered from PR #1482 at `d752a5fd9`,
  using current workflow construction. Closing a real incoming HTTP socket
  kills the admitted workflow and closes its provider socket for both adapters.
  A second workflow receives 503 without provider dispatch. Workflow admission
  releases on owner death; the transport's separate admission still fences
  physical reuse until its cleanup completes.
- Replacement provider 503, peer-close, and malformed-JSON cases each create
  one observed request, release capacity, and permit later recovery.

## Upstream fixes and live evidence

The experiment found and fixed three concrete codec gaps:

1. Non-stream finish reasons were discarded, preventing truncation attribution.
2. Cache-write observations and exact bounded decimal-string charges were
   missing from the public usage projection.
3. A real OpenRouter tool response carried an optional positional `index`.
   The strict codec rejected it. The fix validates that index against its
   array position before applying the existing strict tool/schema validation.

Wire regressions were committed before their fixes in the upstream branch.
The indexed-response diagnosis emitted only a closed reason and a boolean
shape check; temporary instrumentation was removed. No provider payload was
retained. Upstream protocol evidence and release notes describe the changes.

Fresh-process HTTPS text calls succeeded for both adapters. The replacement's
first live tool workflow failed at decode, exposed the index issue, then
succeeded after the fix (14.216 seconds). A later fresh process also returned
the correct ticket IDs through the replacement (10.781 seconds). ReqLLM had
successful earlier control workflows, including one at 20.055 seconds, but
failed in the final paired run (9.116 seconds). That first failure summary did
not retain a closed Kernel reason, so its cause is **unclassified**, not
attributed to transport or model variability. The live probe now emits closed
Kernel kind/reason on later failures and exits non-zero on any failed or
incorrect workflow. No automatic retry or cherry-picked all-green paired
result is reported.

These timings include different live generations and cannot isolate TLS
setup cost. Both local servers close connections; a controlled sustained
comparison with real connection reuse is still required.

## Verification and continuation

- The deterministic comparison suite passes, including accounting and
  ownership fault paths. The final report belongs to a passing command.
- Root `mix precommit` passes; focused adapter, model/host installation,
  Dispatcher deadline, and budget ledger/settlement tests pass.
- Upstream `mix check` and `mix full_check` pass, including runtime-only
  dependency compilation, Dialyzer, docs, release smoke, and package contents.
  Its final release-notes-only commit also passes `mix check`.
- The final paired live command exits unsuccessfully because of the ReqLLM
  control outcome, retained above. Local fixtures are not presented as
  compensation for that live acceptance gap.

Before promotion: review and merge the upstream fixes, publish a corrected
release through its main-only release workflow, and replace the path override
with a tested exact published pin. Agree deployment concurrency, request
lengths, latency/connection budget, and sustained duration before running the
TLS/reuse acceptance comparison. Diagnose the live control with closed
failure evidence before making a reliability comparison. Then decide whether
physical admission belongs around ReqLLM or merits adopting the new transport
for this one installation. Native providers, cache routing, streaming,
ReqLLM removal, and the gateway release remain outside this change.
