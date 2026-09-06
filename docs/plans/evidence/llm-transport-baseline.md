# Initial ReqLLM baseline observations

Date: 2026-09-06. Milestone 1 is in progress; this is the first local
characterization, not its exit evidence. The
[pilot plan](../llm-transport-pilot.md) owns the remaining scope.

## Reproduction and scope

```bash
mix run scripts/labs/llm-transport/run.exs /tmp/ptc-llm-baseline.json
```

The [probe](../../../scripts/labs/llm-transport/README.md) uses real loopback
HTTP/1 sockets, the prepared OpenRouter adapter, and one explicit pool with
`count: 1, size: 2`. The selector and output cap come from the support-triage
host shape; this probe does not execute its agent workflow or tools.
It additionally requests token and cost reservations. No credentials or live
provider requests are involved, and no runtime implementation changed.

The [captured report](llm-transport-baseline-2026-09-06.json) records the
application revision, probe/lock/catalog hashes, runtime, dependency versions,
configuration, outcomes, and resource snapshots. Its base revision is the
pushed planning commit `d5dcb0898`; the probe source is identified separately
by hash because it was added after that commit.

## Observed behavior

| Scenario | Observation | Interpretation |
| --- | --- | --- |
| Normal direct calls | All ten succeeded; local median 2 ms. | Positive control for prepared encoding and response handling; not a public endpoint latency estimate. |
| Normal Dispatcher call with budgets | Succeeded; settled 12 tokens and 5 USD microunits, with no outstanding reservation. | This fixture's reported cost and usage reach the operational ledger correctly. |
| Dispatcher call queued behind two occupied connections | Returned retryable `timeout/llm_request_timeout` in 254 ms for a 250 ms cutoff; the fixture never received its request. | The Kernel-owned deadline bounds pool waiting. |
| Direct adapter call against the same full pool | Raised `RuntimeError` after approximately 5 seconds despite a 250 ms invocation deadline; no request reached the fixture. | The adapter alone is not the whole-call deadline owner. Direct callers need an ownership/admission contract; this does not reproduce a Kernel deadline failure. |
| Kill both holding adapter callers | Both peer sockets closed within the shared 1-second observation window; this capture measured less than 1 ms. | Real socket cancellation worked in this case. Sub-millisecond timing is not a production guarantee. |
| Recovery | All ten subsequent calls succeeded; process/port snapshots returned to their pre-contention counts. | No stuck pool slot was observed; this is not a sustained leak test. |

The queued Kernel call conservatively charged its full reservation and marked
accounting incomplete, even though the fixture observed no wire dispatch.
That preserves current uncertain-outcome policy. The fixture's external
knowledge is not authenticated adapter dispatch provenance; it cannot justify
changing the ledger to charge zero.

Source history explains the timeout distinction:
`52cce8bd1` deliberately sets ReqLLM's total timeout to infinity for
Kernel-owned requests, keeping execution in the provider process so caller
death terminates its work. Dispatcher supplies the outer cutoff. Re-enabling
a dependency timeout task without checking ownership would risk undoing that
fix. No failing runtime regression or timeout fix was added on the strength
of the direct-call result.

## Next evidence

- Execute the selected support-triage workflow and record its actual tool and
  transcript shapes; test independent concurrent runs and per-run ledgers.
- Compare aggregate host admission aligned with the pool against the current
  per-run-only demand described in #1290. Distinguish bounded rejection from
  requests that consume deadlines waiting inside Finch.
- Add active-response deadline, provider failure, and repeated cancellation
  scenarios; measure sustained resource trends and connection reuse.
- Establish deployment load and performance criteria, then run bounded live
  HTTPS checks against verified model overrides and a pinned catalog.

The focused adapter, provider-application, Dispatcher deadline, and budget
dispatcher/ledger test files passed. This evidence does not establish a need
to replace ReqLLM. Milestones 2 and 3 remain gated on the broader baseline and
the pilot's benefit decision.
