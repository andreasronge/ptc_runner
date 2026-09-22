---
program: prelude-search
experiment: prelude-search/003
issue: 1996
tag: research/prelude-search/003
kinds: [measure]
hypotheses: []
model: openrouter:deepseek/deepseek-v4-flash
replay: research-artifacts/prelude-search/003/live/fixtures/
tags: [deadline, calibration, deepseek]
---

# Prelude-search 003: deadline calibration

Status: completed calibration, 2026-09-19. All four conditions finished with
known usage and matched network-free replay. Cost: **USD 0.005864**. This single
instance is excluded from experiment 004 and does not test H1.

The original 120-second timeout existed in both the Kernel's default request
limit and the HTTP adapter. The fix in [#2020](https://github.com/andreasronge/ptc_runner/pull/2020)
propagates the authorized deadline through provider HTTP options, retains
canonical traces and private inspection on stopped cases, finalizes their
budget reservations and completed fixtures, and supports completed-prefix
replay without inventing new spend.

## Frozen protocol

[Authorization](https://github.com/andreasronge/ptc_runner/issues/1996#issuecomment-5744271571):
one interval instance, seed 20261020; one-turn E1, three-turn E1, independent
K=2 and K=4 sampling. The model remains
`openrouter:deepseek/deepseek-v4-flash` with default routing and a 16384-token
output ceiling. Each condition retains the same 320000-token and USD 0.10
ceilings. Request timeout: 300000 ms; run/workflow: 960000 ms; parallel:
330000 ms. No automatic retries. Calibration cap: USD 0.40.

Source: `608c2a92d17a58164357d2d99f0cd201f5d8de7c`. The source was independently
reviewed and locally validated before recording; its runtime PR was not yet
merged when the run began. The existing visible/selection/final partitions,
first-passing selection rule, and diagnosis scoring were unchanged.

## Measurements

| Condition | Case wall time | Input tokens | Output tokens | USD | Final tests passed |
| --- | ---: | ---: | ---: | ---: | --- |
| E1 one-turn | 131.182 s | 5137 | 8722 | 0.000917 | yes |
| E1 three-turn | 133.420 s | 5118 | 8629 | 0.000909 | no |
| E2 K=2 | 83.486 s | 10274 | 7633 | 0.001038 | no |
| E2 K=4 | 114.577 s | 20548 | 28662 | 0.003000 | yes |

Case wall time includes command startup; the entire recording took 479.359 s,
including instance preparation and checking. These outcomes describe one
calibration instance and are not comparative performance evidence.

The private analysis profile opened the first case's retained trace and
inspection. Its model exchange lasted **125898 ms**, between recorded input
and output timestamps, and completed with known usage. That is a directly
observed completion beyond the old 120-second request limit.

All four cases replayed with identical candidates, diagnoses, selection,
chosen indices, final outcomes and reported model spend. Run identifiers,
wall time and non-model bookkeeping are excluded from equality. Replay
reported zero new spend.

## Budget and next step

Prior corrective work and unresolved reservations consume USD 0.310574.
Adding calibration gives USD 0.316438 against the USD 5 corrective allowance,
leaving **USD 4.683562**. No new unresolved reservation was introduced.

Calibration cleared the declared prerequisite for experiment 004: twenty fresh
seeds per subject, 20261021–20261040, with the same model and five-minute
request deadline. Its observations remain separate from this calibration.

## Retained evidence

Machine-readable result: [003.json](003.json). Raw protocol, model and checker
captures, fixtures, replay, comparison and result-building scripts, and private
latency queries are retained under `research-artifacts/prelude-search/003/` in
[`research/prelude-search/003`](https://github.com/andreasronge/ptc_runner/tree/research/prelude-search/003).
The artifact is never merged; only this report and its result belong on main.
