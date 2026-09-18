---
program: prelude-search
experiment: prelude-search/001
issue: 1996
tag: research/prelude-search/001
kinds: [measure]
hypotheses: [H1]
model: openrouter:deepseek/deepseek-v4-flash
replay: scripts/labs/prelude-search/fixtures/deepseek-v4-flash/
tags: [sampling, held-out-check, deepseek, e1, e2]
---

> Copied verbatim from the artifact branch `ptc-manager/issue-1996-job-167`
> at `e4b36ab4e`. The ledger records this experiment as **invalid**: the
> method review found that held-out selection ran outside the runtime, that
> the localisation scorer is wrong in both directions, that replay fixtures
> omit usage and timeouts, and that the budget cap was checked per batch.
> The numbers below are the author's claims and are superseded by
> `prelude-search/b01` once it runs.

# Prelude-search E1/E2: deepseek-v4-flash

Date: 2026-09-18  
Model: `openrouter:deepseek/deepseek-v4-flash`  
Instances: 20 per subject and condition (60 per condition)  
Visible/held-out inputs per instance: 40/10

The corrected live matrix made 420 candidate requests and cost USD 0.300298,
with 2,250,602 input tokens and 870,794 output tokens. The complete issue work,
including discarded harness probes and the invalid fixed-budget pilot, remained
below USD 1 and therefore below the USD 10 cap. A network-free replay reproduced
all table values exactly.

Localisation is scored on the first held-out-passing candidate. Function names
must equal the planted function name; form text must contain the planted form
or be contained by it. Wall time is the sum of command wall time for the rows,
not elapsed batch time. `generated/checked per solved` divides candidates that
returned source and reached the frozen-component checker by solved instances.

## Metrics

| condition | subject | function accuracy | form accuracy | held-out pass rate | tokens in | tokens out | USD | wall seconds | generated / checked per solved |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| E1 | intervals | 40.00% | 35.00% | 55.00% | 85,136 | 82,246 | 0.019803 | 1,338.624 | 1.45 / 1.45 |
| E1 | normaliser | 25.00% | 20.00% | 30.00% | 71,683 | 21,676 | 0.007248 | 890.834 | 1.33 / 1.33 |
| E1 | reconciliation | 25.00% | 25.00% | 45.00% | 185,806 | 23,429 | 0.014518 | 643.119 | 1.22 / 1.22 |
| **E1** | **overall** | **30.00%** | **26.67%** | **43.33%** | **342,625** | **127,351** | **0.041569** | **2,872.577** | **1.35 / 1.35** |
| E2 K=2 | intervals | 85.00% | 60.00% | 95.00% | 170,208 | 182,934 | 0.043264 | 1,653.938 | 1.84 / 1.84 |
| E2 K=2 | normaliser | 30.00% | 40.00% | 45.00% | 119,360 | 46,712 | 0.014408 | 1,445.808 | 1.89 / 1.89 |
| E2 K=2 | reconciliation | 45.00% | 55.00% | 70.00% | 353,115 | 34,889 | 0.030484 | 690.175 | 1.50 / 1.50 |
| **E2 K=2** | **overall** | **53.33%** | **51.67%** | **70.00%** | **642,683** | **264,535** | **0.088156** | **3,789.921** | **1.74 / 1.74** |
| E2 K=4 | intervals | 100.00% | 55.00% | 100.00% | 283,180 | 265,706 | 0.065029 | 1,859.551 | 3.50 / 3.50 |
| E2 K=4 | normaliser | 35.00% | 50.00% | 80.00% | 238,872 | 115,463 | 0.033851 | 1,640.904 | 2.63 / 2.63 |
| E2 K=4 | reconciliation | 55.00% | 60.00% | 95.00% | 743,242 | 97,739 | 0.071693 | 758.561 | 2.89 / 2.89 |
| **E2 K=4** | **overall** | **63.33%** | **55.00%** | **91.67%** | **1,265,294** | **478,908** | **0.170573** | **4,259.016** | **3.04 / 3.04** |

## E2 stop-rule verdict

**Yes.** K=4 raised held-out pass rate from E1's 26/60 (43.33%) to
55/60 (91.67%), a lift of 29 solved instances and 48.34 percentage points at
four times E1's per-instance token budget. K=2 reached 42/60 (70.00%). The
search line passes this stop rule.

## Verbatim diagnoses

Correct diagnosis and passing candidate, E2 K=2, intervals instance 0:

```json
{"cited_executions":[0,1,2],"form":"(if (<= start finish) {\"start\" start \"end\" finish} {\"start\" start \"end\" finish})","function":"ordered"}
```

Wrong diagnosis, E1, intervals instance 0. It named a qualified function that
does not equal the planted function-level ground truth:

```json
{"cited_executions":[0,2,3],"form":"(defn- ordered\n  \"Put one interval into ascending endpoint order.\"\n  [interval]\n  (let [start (get interval \"start\")\n        finish (get interval \"end\")]\n    (if (<= start finish)\n      {\"start\" start \"end\" finish}\n      {\"start\" finish \"end\" start})))","function":"lab.intervals/ordered"}
```

No candidate passed, E1, intervals instance 4:

```json
{"cited_executions":[0,1,2,10,11,12,13,22,23,24,25,34,35,36,37],"form":"(defn- touches?\n  \"Return true when the next interval is within tolerance.\"\n  [current next tolerance]\n  (<= (get next \"start\")\n      (+ (get current \"end\") (- tolerance 1))))","function":"touches?"}
```

## Failure modes

Counts are mutually exclusive over all 420 candidate attempts.

| outcome | count |
| --- | ---: |
| held-out pass | 224 |
| provider timeout (`llm_request_timeout`) | 26 |
| no usable tool call before the one-turn limit (`protocol-error`) | 91 |
| generated program evaluation error before return | 26 |
| intermediate result instead of return | 2 |
| returned candidate did not compile as a component | 24 |
| compiled candidate failed held-out executions | 27 |

The visible ordering is the only deliberate difference among E2 candidates.
Provider timeouts were retained as candidate error values; they were not
retried. One early probe also exhausted an 8,192-token output ceiling, so the
final matrix used 16,384 output tokens per request.

## Runtime wants

- Mission data is rendered to the model as a typed `data/params` name (`{}`),
  not the value. A one-request repair therefore had to include the same source
  and visible executions in the user message while also installing them under
  `data/params` for the generated program.
- LLM installations are workflow-only, so an `agent.core/run` cannot itself be
  invoked inside `kernel/eval-with`. The workflow loop selects a no-tool mission
  whose generated program runs against that mission instead.
- `kernel/eval-source-with` accepts a mission program, not complete component
  source with `ns`, docstrings, and export metadata. The checker had to compile
  each complete candidate into a frozen no-model application before executing
  held-out inputs.
- Mission params are recorded only by identity hash and a mission return has no
  first-class inspection record. The harness must preserve its private result
  and generated source to audit how a candidate was selected.
- Replay response cursors are run-scoped. Identical request hashes in separate
  command runs can have different live answers, so one combined fixture cannot
  replay this matrix; fixtures must be split per case.
- Live provider errors have no successful response object. The replay fixture
  must retain the bounded error map itself to reproduce timeout candidates.
