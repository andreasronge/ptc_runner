---
program: prelude-search
experiment: prelude-search/000
issue: 1995
tag: research/prelude-search/000
kinds: [measure]
hypotheses: [H0]
model: none
replay: none
tags: [reproducibility, e0, no-model]
---

# Prelude-search 000: reproducibility of recorded runs

Date: 2026-09-17. Source: pull request #1998 (job 166), merged as
`ccc81520a`. This report is written from that pull request's validation
section; the experiment predates the report format.

## Conditions

Three purpose-written subject preludes (intervals, normaliser,
reconciliation), five semantic mutation operators, a seeded input generator.
Each recorded execution is a real PtcRunner run that leaves a trace and a
private inspection artifact. The run input is stored beside the artifacts by
the lab because the runtime does not record it. E0 re-executes every recorded
execution from its stored input and frozen bundle and compares the result
hash with the recorded `run-result`.

Command: `mix run scripts/labs/prelude-search/run.exs --phase 0` at the
default seed with 100 executions per subject.

## Result

| subject | executions | equal | unequal | milliseconds per re-execution |
| --- | ---: | ---: | ---: | ---: |
| intervals | 100 | 100 | 0 | 4.463 |
| normaliser | 100 | 100 | 0 | 5.110 |
| reconciliation | 100 | 100 | 0 | 4.908 |

All five mutation operators were exercised across all three subjects with
two executions each. A nightly test runs one subject with about ten
executions and asserts all equal.

## Comparison with the null model

H0 has no null model; the hypothesis is that the fraction equal is exactly
one. Observed: 300 of 300. The cost of one check, about five milliseconds,
is the unit every later budget in this program rests on.

## Runtime wants

- The run input is not recorded in the trace, the inspection artifact, or
  the envelope; the package replaces it with an excluded marker. The lab
  stores `<run-ref>.input.json` beside the artifacts. Recording it as a
  private inspection record would make the claim "a run re-executes from
  its artifacts alone" literally true.
