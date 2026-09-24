---
program: prelude-search
experiment: prelude-search/002
issue: 1996
tag: research/prelude-search/002
kinds: [measure]
hypotheses: [H1]
model: openrouter:deepseek/deepseek-v4-flash
replay: research-artifacts/prelude-search/002/live/fixtures/
tags: [sampling, untouched-final-check, deepseek, stopped]
---

# Corrective E1/E2 pilot: stopped on a request deadline

The run stopped after one completed case and one model-request timeout. The
remaining 238 cases were not started. There are no paired comparisons and no
evidence for or against H1. This report preserves the stop and the usable
prefix; it does not replace report 001 with a successful corrected experiment.

## Conditions and execution

The unchanged harness at `8f2e50b9090d095090e5fc3b0c6760e90ceddb50`
ran on 2026-09-19, from 15:06:31 to 15:10:13 UTC. The planned matrix had twenty
seeds per subject, starting at 20260930, across intervals, normalisation, and
reconciliation. Each instance would run one-turn E1, three-turn E1, K=2, and
K=4: 240 condition-cases in total. Three-turn E1 was the primary comparator.

Each case retained the declared 320,000-token and USD 0.10 ceilings. The data
split was 40 visible, 20 selection, and 20 untouched final inputs, disjoint by
value. The recorded checker chooses the first selection-passing candidate;
only that winner can reach final evaluation. No prompt, deadline, model,
output limit, or stop rule was changed after observing results.

Prior validation used or reserved USD 0.209881. The run therefore received
USD 4.790119 of the USD 5 corrective allowance. The historical issue work was
reported below USD 1; reserving that upper bound still keeps this authorization
within the whole-issue USD 10 cap. A separate supervisor enforced a six-hour
wall-clock limit. It did not restart the process.

## Observations and denominators

The machine-readable [result](002.json) was generated from retained rows,
envelopes, and reservation records using the existing harness's reporting and
comparison functions. The artifact branch retains the summarization script.

| Condition | Completed / planned | Generated / checked | Selected winners | Final success per completed case | Reported input / output tokens | Known USD |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| E1 one-turn | 1 / 60 | 1 / 1 | 0 | 0 / 1 | 5,161 / 5,614 | 0.000693 |
| E1 three-turn | 0 / 60; one stopped | 0 / 0 in stopped case | not evaluated | unavailable | unknown | unknown |
| E2 K=2 | 0 / 60 | not started | not evaluated | unavailable | not measured | not measured |
| E2 K=4 | 0 / 60 | not started | not evaluated | unavailable | not measured | not measured |

Only intervals, seed 20260930, was attempted. Normalisation and reconciliation
have no observations. The completed one-turn case took 87,925 ms, including
command startup and model execution but excluding the subsequent checker.
Its function accuracy was 1/1, exact-fragment accuracy 0/1, and citation-value
validity 1/1. No candidate reached the untouched final set: the reported 0/1
is case-level final success, not a final-test execution failure. Cost and
attempts per solved instance are undefined because there were no solved cases.

Both K comparisons report `incomplete_pairs`. There is no confidence interval,
sampling-baseline calculation, independence claim, or equivalence claim.

## Verbatim diagnosis and observed failures

Only one diagnosis exists; the request for three examples cannot be met from
this stopped run without inventing or importing observations. Its exact function
and form fields were:

```json
{
  "function": "touches?",
  "form": "(< (get next \"start\") (+ (get current \"end\") tolerance))"
}
```

One of its three verbatim citations was:

```json
{"index":14,"observed_json":"{\"intervals\":[{\"end\":20261213,\"start\":20261210},{\"end\":20261218,\"start\":20261213}]}"}
```

The function was correctly localized, and all three cited values matched the
visible evidence. Exact-fragment scoring remained zero because the planted
fragment was `(< (get next "start")`, whereas the answer quoted the larger
expression. This metric is strict text equality, not semantic localization.

Failure modes were:

- **One selection failure:** the candidate compiled and repaired the comparison,
  but removed the entry function's explicit `return`. The private analysis
  profile shows all twenty selection mission evaluations ended as `continued`,
  while the checker requires `returned`. No winner was selected.
- **One Kernel request timeout:** the three-turn baseline's first request ended
  with `provider-failure`, reason `llm_request_timeout`, and no generated program.
  Its model spend is `incomplete`. The fixture exporter refused to represent
  that deadline as an ordinary provider error and terminated the experiment.

The timeout reservation remains USD 0.10; its actual provider cost is unknown.
Known spend plus reservation for this run is USD 0.100693. Including earlier
validation, the corrective allowance has USD 0.310574 consumed or reserved and
USD 4.689426 unspent. This accounting is not a claim that the timeout cost ten
cents. The runtime's internal pessimistic budget charge is likewise not a
provider-reported bill.

## Replay and retained evidence

With no OpenRouter credential, the unchanged harness replayed the completed
prefix. Candidate content, diagnosis, selection, winner, final-success flag,
and reported model usage matched exactly. Run identifiers and elapsed time
were excluded. Replay then reached the missing timeout fixture and stopped;
only one case is verified, and the full matrix was not replayed.

Raw model-run inspections, command envelopes, outputs, completed selection
trace/inspection, protocol, reservation, fixture, and comparison evidence are
retained under `research-artifacts/prelude-search/002/` on the experiment
branch. The artifact-only summarizer indexed the existing successful fixture;
it did not create a fixture or a scored row for the timeout. The selected
canonical trace was inspected through `private-run-analysis-v2`.

## Runtime wants and next decision

[Issue #2008](https://github.com/andreasronge/ptc_runner/issues/2008) tracks the
observability and stop-finalization gaps exposed here:

- Model cases request inspection but omit canonical traces. Their envelopes say
  `trace: not_requested`; the private analysis profile refuses the timed-out
  run with `selected_trace_missing`.
- Fixture export raises before writing a partial summary and fixture index.
  The completed row and reservation survive, but this report needed an
  artifact-only summarizer and an explicit partial-replay verification.

The timeout is an operational observation, not evidence that the repair
hypothesis failed. Any new attempt needs a separately declared protocol and
budget ledger, including an explicit decision about deadlines and timeout
handling. This run was not silently retried.
