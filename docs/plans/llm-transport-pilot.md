# Bounded LLM transport pilot

**Status:** milestone 1 in progress, 2026-09-06. The
[initial loopback baseline](evidence/llm-transport-baseline.md) measures
prepared adapter calls, Dispatcher deadlines/accounting, socket cancellation,
and pool recovery. Complete concurrent workflows and deployment criteria
remain outstanding. Milestones 2 and 3 have not started. ReqLLM remains the
default; dependency removal and broad migration remain deferred.

Related work: [aggregate concurrency #1290](https://github.com/andreasronge/ptc_runner/issues/1290)
and [MCP gateway #1465](https://github.com/andreasronge/ptc_runner/issues/1465).
This plan stages transport evaluation within that work; it does not close
either issue or replace the gateway's release requirements.

## Decision to make

Does `ptc_llm_http` give concurrent hosted PtcRunner runs a meaningful,
demonstrable improvement in request ownership or reliability over configured
ReqLLM/Finch, at an acceptable connection and maintenance cost?

The [feature inventory and eventual removal plan](future/reqllm-removal.md)
owns the broader compatibility matrix and source checkpoints. This pilot owns
the immediate sequence and its stopping criteria. Complete one milestone and
review its evidence before expanding scope.

## Fixed scope

- Keep ReqLLM as the default and LLMDB as the metadata/pricing source.
- Select one OpenRouter installation and one representative existing
  workload. The [support-triage example](../../examples/support-triage/README.md)
  is a candidate: its checked-in host requires token and USD cost usage,
  disables explicit caching, and specifies an output cap. Confirm the chosen
  workflow's actual call shapes before committing the pilot matrix.
- Use the current prepared-model, requirements, invocation, and budget
  contracts. Adapter selection is explicit before a run; there is no
  automatic fallback or dual dispatch to paid providers.
- Support exactly the features needed by that workload. Refuse unsupported
  installation requirements before credentials or remote work. Narrow scope
  cannot be achieved by silently removing controls or budget guarantees.
- Leave native-provider migration, embedding support, a Kernel streaming API,
  dependency removal, and broad host-source redesign outside this pilot.

## Milestone 1: establish the ReqLLM baseline

Record the exact application/library revisions, effective model selector,
request shapes, inference controls, pricing snapshot, usage guarantees, and
budgets. Inspect relevant model overrides without recording credentials;
verify the model and endpoint when live testing begins.

Use existing admission and pool configuration as the starting point. The
current command-owned provider gate already sizes Finch from
`live_provider_tasks`; distinguish that configuration from a long-lived
host's ownership and aggregate admission. If a small configuration or
admission fix resolves the problem, measure that corrected control too.

Build a repeatable boundary workload covering normal traffic, saturation,
deadline expiry, caller death, slow or failed providers, and recovery. Use
deterministic local provider fixtures for causal checks and bounded live
requests for public HTTPS and provider behavior. Compare the same workload,
limits, and offered concurrency across transports.

Record completion/error outcomes, physical in-flight attempts, queue or
rejection behavior, latency distribution, throughput, and resource trends
through cancellation and readmission. Check usage and ledger settlement.
Define the deployment's acceptable latency, connection overhead, resource
bounds, and test duration before evaluating the replacement; do not select
thresholds after seeing its results.

**Exit evidence:** reproducible baseline, a concrete remaining ownership or
reliability problem, and agreed acceptance criteria. If the corrected ReqLLM
path meets the serving need, stop transport work and continue gateway work
using that path. A new library is not a prerequisite for the gateway.

## Milestone 2: opt-in adapter with preparation and accounting parity

Recover useful fixtures from closed [PR #1575](https://github.com/andreasronge/ptc_runner/pull/1575)
and adapt them to today's boundary. Follow the inventory's upstream-fix and
release checkpoints; the existing `ptc_llm_http 0.1.0` pin is insufficient
evidence of readiness. Pin a tested published release before the consumer
pilot is accepted.

Implement the smallest explicit adapter integration, including shared runtime
ownership and lifecycle plumbing required to make it usable. Keep changes
reviewable in this order:

1. Local preparation and rejection: exact controls, model identity,
   output caps, structured/tool modes required by the workload, credentials,
   and deadline propagation.
2. Accounting: retain LLMDB lookup and request-specific token/cost reservation
   attestation. Preserve missing versus zero usage and distinguish reported
   charges from calculated estimates. Resolve how estimates interact with
   cost guarantees before they can satisfy a required USD observation.
3. Request and response integration: content, tool-result round trips where
   used, finish reasons, authenticated truncation attribution, usage, and
   closed errors. Keep unused convenience APIs out of the first slice.

Accounting fixtures must cover cache observations and precision even if the
chosen installation disables explicit caching: providers can still report
cached input. Add reservation-required boundary cases if the representative
example does not exercise them. Preserve refusal of unknown pricing and
unsupported billables, uncertain settlement, and actual-usage overruns.

**Exit evidence:** the pilot installation passes the same relevant Kernel
boundary checks through both adapters, and succeeds in a fresh process over
public HTTPS. Unsupported installations fail locally with useful diagnostics.
No default changes. A successful response alone does not satisfy this gate.

## Milestone 3: shared hosting under contention

Run multiple independent Kernel runs through one host-owned HTTP runtime,
with explicit global/group physical-attempt capacity. Bound workflow
admission separately and document any queue. A new runtime per request cannot
demonstrate aggregate control.

Repeat the baseline, including cancellation storms, provider failures,
runtime-owner failure, cleanup, and readmission. Demonstrate that abandoned
physical work is drained or fenced before capacity can be reused. Measure
the cost of HTTP/1 connection establishment without connection reuse; do not
assume greater throughput from tighter ownership.

After the direct host comparison passes, recover the smallest request-owner
and serving slice from closed [PR #1482](https://github.com/andreasronge/ptc_runner/pull/1482).
Reconcile its Finch-specific admission/lifecycle assumptions with the selected
runtime. Prove client disconnect reaches the request owner and its provider
work. This experiment does not establish gateway deployment readiness;
packaging, protocol conformance, authentication, and release checks remain
owned by the gateway work.

**Exit evidence:** repeatable comparison against milestone 1, passing safety
and accounting invariants, and an explicit benefit/tradeoff assessment.

## Outcomes and stopping criteria

| Evidence | Next action |
| --- | --- |
| Configured ReqLLM meets the deployment requirements | Keep it; continue useful admission/gateway improvements. Close or defer the pilot with its evidence. |
| Replacement loses accounting, exact controls, cleanup, or other required semantics | Stop expansion; fix the bounded gap or retain ReqLLM. Do not waive a guarantee to complete the pilot. |
| Replacement meets invariants but offers no meaningful operational benefit, or exceeds agreed overhead | Keep ReqLLM as default; record findings and defer further transport investment. |
| Replacement demonstrates a worthwhile benefit for the selected workload | Keep the opt-in path and propose the next explicit supported workload/provider. A default switch requires a separate decision. |

Rollback selects ReqLLM for subsequent runs after pilot work has drained.
Never replay an uncertain in-flight request automatically: it may already have
incurred a provider charge or produced tool calls.

Record results against pinned revisions with repeatable commands, sanitized
fixtures, and a supported/refused installation matrix. Run applicable tracked
hooks and focused boundary checks for each implementation slice. Move durable
contracts into their owning references before deleting the completed plan.
