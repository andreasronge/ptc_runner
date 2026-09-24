---
program: prelude-search
experiment: prelude-search/004
issue: 1996
tag: research/prelude-search/004
kinds: [measure]
hypotheses: [H1]
model: openrouter:deepseek/deepseek-v4-flash
replay: research-artifacts/prelude-search/004/live/fixtures/
tags: [sampling, final-test, deepseek, e1, e2]
---

# Prelude-search 004: stopped corrective E1/E2 pilot

Status: stopped, 2026-09-19; **H1 inconclusive**. The run completed 53 of 240
planned cases, covering thirteen complete interval instances and one extra
one-turn case. It stopped on output truncation in the next three-turn case.
Neither text normalisation nor ledger reconciliation was reached. This is an
incomplete, outcome-dependent prefix, not a representative three-subject study.

## Frozen protocol and stop

[Authorization](https://github.com/andreasronge/ptc_runner/issues/1996#issuecomment-5744271571)
followed the separate [003 calibration](003-deadline-calibration.md).
Source: `608c2a92d17a58164357d2d99f0cd201f5d8de7c`, including the independently
reviewed [timeout fix #2020](https://github.com/andreasronge/ptc_runner/pull/2020).
The source did not change during recording. Model:
`openrouter:deepseek/deepseek-v4-flash`, default routing, output limit 16384.
Planned seeds: 20261021–20261040 for each of three subjects, four conditions
per instance. Each condition has the same ceilings of 320000 tokens and
USD 0.10; these are not equal actual costs. Request deadline 300000 ms,
run/workflow 960000 ms, parallel 330000 ms; six-hour admission allowance.
Recording budget: USD 4.683562. No automatic retries or restarts.

The existing 40 visible, 20 selection and 20 final inputs are disjoint by value;
each planted mutation must affect selection and final examples. A recorded
no-model workflow picks the first selection-passing candidate, freezes it, then
checks final inputs. Final outcomes cannot cause reselection. Three-turn E1
allows the model/runtime interaction up to three turns; it is not the later
experiment with feedback from the independent selection checker.

Case `intervals-13-E1-three-turn`, seed 20261034, stopped with
`execution/model_output_truncated` (run `cmd-2tbr5gbc125jrh9mswnqgr56zn`).
Private inspection retains three complete model exchanges: 101869, 71461 and
120250 ms. The third returned `finish_reason: length`, 16384 output tokens,
and no usable `run_ptc_lisp` call. This was not a request timeout. The command
exited 1 after finalizing results, fixture index, stop summary and reservation.
There are 53 scored cases, one failed unscored case, and 186 unstarted cases.
The entire recording took 4444.849 seconds.

## Completed-case measurements

All observations below are intervals. Normaliser and reconciliation each have
zero completed cases in every condition; their rates are unavailable. Thus the
intervals and observed-overall rows are identical. The one-turn denominator is
14; all other denominators are 13. Do not compare unpaired point estimates as
if all four denominators matched.

| Condition | Final successes / cases | Input tokens | Output tokens | Known USD | Case wall seconds | USD / success |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| E1 one-turn | 3/14 | 72587 | 91413 | 0.009907 | 930.681 | 0.003302 |
| E1 three-turn | 3/13 | 188262 | 136887 | 0.014550 | 1367.438 | 0.004850 |
| E2 K=2 | 4/13 | 135186 | 142048 | 0.015010 | 829.893 | 0.003753 |
| E2 K=4 | 3/13 | 270372 | 287614 | 0.030449 | 958.896 | 0.010150 |

Case wall time includes model command startup; overall recording time also
includes preparation and checking. Cost per success here excludes the stopped
case, whose usage and conservative reservation are accounted for below.

| Condition | Scored candidate slots | Function correct | Exact form correct | Citation values valid | Sources returned | Candidates checked | Returned / success | Checked / success |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| E1 one-turn | 14 | 7/14 | 0/14 | 5/14 | 7 | 5 | 2.3333 | 1.6667 |
| E1 three-turn | 13 | 8/13 | 0/13 | 8/13 | 8 | 8 | 2.6667 | 2.6667 |
| E2 K=2 | 26 | 9/26 | 0/26 | 6/26 | 9 | 8 | 2.25 | 2.0 |
| E2 K=4 | 52 | 20/52 | 2/52 | 17/52 | 22 | 20 | 7.3333 | 6.6667 |

Scores include failed candidate slots, not only successful returns. “Sources
returned” is the harness's `candidates_generated` field; it does not count
intermediate model programs. “Checked” counts candidates accepted as valid by
the selection workflow, including candidates that fail its tests. Citation
validity checks quoted observed values against visible examples; it does not
prove the diagnosis follows from them.

## Paired uncertainty

The primary comparisons use only the thirteen complete paired instances,
seeds 20261021–20261033. Three-turn E1 solved 3/13.
The predeclared stratified paired percentile bootstrap uses 2000 resamples,
seed `[2026, 9, 19]`, preserving conditions within each sampled instance.
Only the intervals stratum is present.

| Comparison against three-turn E1 | Paired final successes | Difference | 95% bootstrap interval |
| --- | ---: | ---: | ---: |
| K=2 | 4/13 vs 3/13 | +7.69 percentage points | −15.38 to +38.46 points |
| K=4 | 3/13 vs 3/13 | 0.00 percentage points | −23.08 to +23.08 points |

Both intervals span zero and the predeclared three-point useful-improvement
threshold. Stopping depended on a model failure, the sample is small and covers
one toy subject, and these descriptive intervals do not correct for that
selection. Neither support, refutation nor equivalence is established. No
independence claim follows from a pooled sampling formula. Calibration 003 is
not pooled into these observations.

## Failure modes and verbatim diagnoses

Among 105 scored candidate slots, 46 returned a repair object; 48 ended at the
turn limit with `evaluation-error`, six with `intermediate-result`, and five
failed the return contract. Forty-one returned candidates were valid for the
selection checker. These are model/program outcomes, not transport timeouts.
The separately stopped case is not one of those 105 slots.

The following diagnosis objects are copied verbatim from completed raw result
objects (JSON whitespace is reformatted). They are retained model claims, not
endorsed explanations; the raw recording contains their matching ground truth,
candidate source, scores and selection results.


### E1 one-turn, seed 20261021, candidate index 0

```json
{
  "cited_executions": [
    {
      "index": 0,
      "observed_json": "{\"intervals\":[{\"end\":20261024,\"start\":20261021},{\"end\":20261029,\"start\":20261025}]}"
    },
    {
      "index": 2,
      "observed_json": "{\"intervals\":[{\"end\":20261064,\"start\":20261061},{\"end\":20261069,\"start\":20261066}]}"
    },
    {
      "index": 4,
      "observed_json": "{\"intervals\":[{\"end\":20261104,\"start\":20261101},{\"end\":20261109,\"start\":20261105}]}"
    }
  ],
  "form": "(<= (get next \"start\") (+ (get current \"end\") (- tolerance 1)))",
  "function": "touches?"
}
```


### E1 one-turn, seed 20261022, candidate index 0

```json
{
  "cited_executions": [
    {
      "index": 0,
      "observed_json": "[{\"end\":20261025,\"start\":20261022},{\"end\":20261028,\"start\":20261027},{\"end\":20261027,\"start\":20261030}]"
    },
    {
      "index": 2,
      "observed_json": "[{\"end\":20261068,\"start\":20261062}]"
    },
    {
      "index": 10,
      "observed_json": "[{\"end\":20261028,\"start\":20261022},{\"end\":20261027,\"start\":20261030}]"
    }
  ],
  "form": "(if (<= start finish) {\"start\" start \"end\" finish} {\"start\" start \"end\" finish})",
  "function": "ordered"
}
```


### E1 three-turn, seed 20261023, candidate index 0

```json
{
  "cited_executions": [
    {
      "index": 0,
      "observed_json": "{\"intervals\":[{\"end\":20261026,\"start\":20261023},{\"end\":20261028,\"start\":20261031}]}"
    },
    {
      "index": 1,
      "observed_json": "{\"intervals\":[{\"end\":20261043,\"start\":20261049},{\"end\":20261051,\"start\":20261048}]}"
    },
    {
      "index": 7,
      "observed_json": "{\"intervals\":[{\"end\":20261163,\"start\":20261171},{\"end\":20261169,\"start\":20261168}]}"
    },
    {
      "index": 16,
      "observed_json": "{\"intervals\":[{\"end\":20261343,\"start\":20261351},{\"end\":20261349,\"start\":20261349}]}"
    },
    {
      "index": 28,
      "observed_json": "{\"intervals\":[{\"end\":20261583,\"start\":20261591},{\"end\":20261589,\"start\":20261589}]}"
    }
  ],
  "form": "(defn- extend\n  \"Extend a merged interval without moving its start.\"\n  [current next]\n  {\"end\" (get current \"start\")\n   \"start\" (max (get current \"end\") (get next \"end\"))})",
  "function": "lab.intervals/extend"
}
```


## Replay, budget and retained evidence

All 53 completed cases replayed network-free in a fresh process, matching
candidate sources and diagnoses, failure categories, selection, chosen indices,
final outcomes and reported model spend exactly. Run ids, latency and non-model
bookkeeping are excluded. Replay introduced zero new spend. The stopped case
was not replayed or represented by a synthetic failure fixture. The earlier
32-case snapshot is explicitly labeled as interim validation.

Completed-case cost is USD 0.069916. Private inspection separately recovered
known stopped-case usage of 17116 input and 40501 output tokens, costing
USD 0.003524. Thus actual known recording cost is **USD 0.073440**.
The frozen stop rule retains the entire USD 0.10 failed-case reservation even
though its usage is now known: conservative recording accounting is
USD 0.169916, not actual provider spend. Prior work including calibration
consumed or reserved USD 0.316438; total corrective accounting is USD 0.486354,
leaving **USD 4.513646** of the USD 5 allowance. Earlier unknown-usage
reservations remain intact. No further live run has been started.

Machine-readable result: [004.json](004.json). Raw protocol, traces, inspection,
fixtures, completed-prefix replay and private analysis queries are retained in
`research-artifacts/prelude-search/004/` at
[`research/prelude-search/004`](https://github.com/andreasronge/ptc_runner/tree/research/prelude-search/004).
The artifact branch and PR are never merged; the tag retains their final commit.
The reusable result-builder
and replay verifier live alongside calibration 003 on that same artifact commit.

## Runtime follow-up and next decision

[#2021](https://github.com/andreasronge/ptc_runner/issues/2021) tracks missing
final mission evaluation diagnostics. Reproduction: open run
`cmd-15eb5hp054jngg1xb9q6bn1p18` from `intervals-0-E2-K-2` with the private
analysis profile. Both model exchanges and generated sources are present;
canonical activity records `evaluation_error`, but private `execution_errors`
and evaluation analyses are empty and terminal turn feedback is empty. The
handled outcome exposes only the generic turn-limit/evaluation-error pair.
This limits automated graph-based diagnosis; it did not change scoring.
The workflow-level truncation in the stopped case does have a retained error.

Before another live run, revise the protocol explicitly to decide whether
known-usage output truncation is a scored failed attempt or a study-wide stop.
The current protocol deliberately stopped. Increasing output tokens or changing
models would be a new condition and needs a new frozen recording. The present
priority is reliable failure handling and inspectable diagnostics before a
larger accuracy or Jev navigation study.
