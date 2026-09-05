# Verified completion evidence

The verification callback compares the reviewer's measurements with both
blind derivations. One correction is allowed only when the blind derivations
agree. The reviewer keeps its original turn and resource budgets.

## Constructed replay cases

`replay.jsonl` remains the immediate-acceptance case. The additional
`verification-replay.jsonl` reuses those recorded programs, but deliberately
adds one euro to each country’s fraudulent volume in the first reviewer
response. The correction response runs the original unmodified aggregation.
Exact request hashes were obtained through the private run-analysis profile
on fixture misses; there is no wildcard matching.

With `inputs/luna.json`, the reviewer has four turns and returns `B. BE`
after rejection and correction. With `inputs/verification-exhausted.json`,
it has one turn and returns `Not Applicable` after rejection. These are
scripted protocol regressions over the real dataset, not evidence of live
model correction quality. The nightly command-boundary test exercises both.

## Live probe, 2026-09-05

Run `cmd-1n9j4atfp3kj3j2p0d7emg3ew7` used the normal live project and
`inputs/luna.json`, with `openrouter:openai/gpt-5.6-luna` in all three stages.
It returned `B. BE` with all three measurements agreeing. The reviewer
completed in one evaluation, so this live probe demonstrates acceptance,
not verification-driven correction.

Counters queried through `analysis/counters` reported 15 model calls,
217 mission capability calls, and USD 0.009516. Run duration was 297,349 ms.
Evaluations by mission were analysis 2, recheck 12, and review 1. The run
also encountered a heap stop before recovering. These are observations of
one run, not a reliability or performance benchmark.
