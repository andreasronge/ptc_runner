# DABStep study notes

The [README](../README.md) is the demo. This file holds the material behind
it: what was measured, how the reader is bounded, what the evidence costs to
keep, and what this example does and does not claim about the benchmark.

## Reference table

The official manual defines fraud as fraudulent volume over total volume:
`eur_amount`, with fraudulent rows marked `has_fraudulent_dispute == True`.
Computed correctly over all 138,236 rows:

| IP country | Total EUR | Fraudulent EUR | Fraud rate |
|---|---:|---:|---:|
| **BE** | **2,150,473.54** | **263,833.85** | **12.269%** |
| NL | 2,701,907.13 | 329,134.08 | 12.182% |
| SE | 2,002,434.74 | 169,937.79 | 8.487% |
| IT | 2,599,613.80 | 182,231.72 | 7.010% |
| FR | 1,292,201.83 | 89,135.03 | 6.898% |
| ES | 644,883.17 | 43,531.87 | 6.750% |
| LU | 665,077.96 | 44,628.44 | 6.710% |
| GR | 640,705.29 | 39,916.73 | 6.230% |

NL leads raw fraudulent volume and count; BE wins only on the ratio, by 0.087
percentage points.

## Cohorts

**Single-stage cohort, 2026-08-24.** Five live samples per model, one agent
loop, six-turn budget, caching disabled. Classified by hand before scoring:
"evidence-backed" required the exact answer, the three semantic columns,
cursor traversal to the end, per-country aggregates derived from a successful
scan, and the division performed in generated PTC-Lisp.

| Model | Exact answer | Evidence-backed | Model calls | Observed cost |
|---|---:|---:|---:|---:|
| `openrouter:deepseek/deepseek-v4-flash` | 3/5 | 3/5 | 29 | $0.006663 |
| `openrouter:openai/gpt-5.6-luna` | 4/5 | 1/5 | 16 | $0.003161 |

Luna got the answer right more often and earned it less often: one run used a
transaction-count rate, two left the division to model reasoning. Every run is
in [`cohort.json`](cohort.json) with run reference, source hashes, calls,
duration, cost, and classification. This cohort predates the raw-CSV reader
and the review stage. [`current-main-smoke.json`](current-main-smoke.json) is
a later single-sample check on the merged runtime.

**Integrated cohort, 2026-09-03.** Ten live runs of the final three-stage
workflow, in [`integrated-cohort.json`](integrated-cohort.json):

| Run | Analyzers | Result | Agreed | Problems | Model calls | Heap kills | Observed cost |
|---|---|---|---|---:|---:|---:|---:|
| `cmd-0760rnpx50pssvz8h1jncw8yq0` | DeepSeek | B. BE | yes | 0 | 13 | 2 | $0.003715 |
| `cmd-0yv3hv8atyd0a3q091dtq3saaj` | DeepSeek | B. BE | yes | 1 | 15 | 2 | $0.003259 |
| `cmd-2gg9hhm9vdq2s948br1vvj9ea3` | DeepSeek | B. BE | yes | 0 | 14 | 1 | $0.004274 |
| `cmd-55t3jtqjh2w2m2ts6eax8j3710` | DeepSeek | failed | | | 16 | 2 | $0.001971 |
| `cmd-6jvrz8x9yvjpm1bfq57j3n317x` | DeepSeek | B. BE | yes | 1 | 17 | 1 | $0.004847 |
| `cmd-0ckkw7zg9424ws2nxsdd40hd8f` | Luna | B. BE | yes | 1 | 9 | 0 | $0.006180 |
| `cmd-0twkysj3vwd4wwwjjgx42p09qs` | Luna | B. BE | yes | 0 | 6 | 0 | $0.004234 |
| `cmd-2859a1v6ts4sdnc298w9wgp2xq` | Luna | B. BE | yes | 0 | 7 | 0 | $0.004987 |
| `cmd-63177zbj3hh1tw4ejmfvwt566h` | Luna | B. BE | yes | 2 | 8 | 0 | $0.006043 |
| `cmd-6yf6q8hy9f0qm49efrp8bs6pes` | Luna | B. BE | yes | 1 | 13 | 1 | $0.008401 |

The reviewer is Luna in every row. Where it wrote a problem on a correct run,
it restated the fraud definition or objected to an intermediate step whose
ranking the workflow never used. The failed DeepSeek run hit the heap ceiling
with a retain-all program, then handed `read-page` a cursor it had composed
itself, which failed closed as `:malformed-cursor`; the stage gave up and the
workflow failed rather than answer.

**Why the decision moved into workflow code.** Three earlier live samples of a
free-text verdict: the reviewer approved without running a program
(`cmd-12ey2m6pd7je5x0xeaweb1zmpq`); raised five objections to a correct
answer after one exploratory read (`cmd-6efc163cz9fxvpvr8j9bt5m7c7`);
scanned every page, then compared its ratio-ranked winner against the option
with the largest absolute fraud volume and vetoed the right answer
(`cmd-7xx3se058f8jn6wqfbkqy4qm71`). A reviewer that can veto is a second
single point of failure; a reviewer that must show its measurement is
evidence.

**Shared-defect counterfactual, 2026-09-03.** Thirty reviewer-only runs over
three defects both analyzers shared, with and without showing the reviewer
the programs. The reviewer measured the true table in 28 of 29 completed runs
and never copied the defective program; with the programs shown it used one
model call and exactly 49 reads every time and named the defect in 13 of 15
runs. Method, tables, and every run are in
[#1802](https://github.com/andreasronge/ptc_runner/issues/1802).

## What the reader can and cannot prove

`read-page` performs exactly one upstream read per call and hands the MCP
cursor straight back to the server. That cursor is opaque and server-signed,
so a forged position fails the read instead of returning invented rows. Each
page reports `read_calls` and `content_hashes`, so a page is always
attributable to the read that produced it.

What the model can still author is `carry`, the partial final line of the
previous page. `read-page` validates it (exact key set, types, no line break,
at most 65,536 bytes) and fails closed with `:malformed-cursor`. A model doing
one genuine read per page could still fabricate that one line, and no more.

These checks are absent from the `read-page` docstring on purpose. They are
guarantees an auditor reads out of the trace, not instructions to the model.

## Keeping the evidence small

| | bytes |
|---|---:|
| source file | 23,581,339 |
| evaluation heap ceiling | 40,000,000 |
| evidence, captured in full | 74,373,399 |
| evidence, `digest_results` | **270,127** |

The program never holds the file. It streams one page at a time and keeps
eight per-country pairs, so it finishes inside a 40 MB heap. Every DeepSeek run
in the integrated cohort and one Luna run first tried to retain every row, hit
the ceiling, and rewrote the program as a streaming aggregation. The recording
is what does not fit: an MCP result carries its payload twice, in `content`
and `structuredContent`, so full capture costs three times the source.

The read mapping therefore declares `"inspection_capture": "digest_results"`.
Inspection still keeps the capability arguments, the complete MCP request
bodies, every model exchange, and an identity for each accepted response:

```json
{"encoding": "ptc-deterministic-json-v1", "encoded_bytes": 496387,
 "sha256": "sha256:16b97ab9ea6519107313b22745f215d805335f2abcff0e365d5afa51c9e1500a"}
```

Only the accepted response body is dropped. Because `payments.csv` is
checksum-pinned, the identity confirms it is the same content. Rejected
responses, error envelopes, and MCP stderr keep their bodies. A digested
record reports `capture_mode: "digest_results"` and `result_available?: false`;
that is a weaker evidence class, not a missing exchange.

The server runs with `--max-read-bytes 500000 --max-result-bytes 1000000`,
giving 485,376-byte pages: 49 reads for the whole file instead of the 1,440
that `ptc-fs-mcp`'s default would need. The consumer ceiling is one notch
higher (`max_result_bytes` 1,048,576) because PtcRunner's accounting is
slightly wider than the server's and equal values are rejected as
`mcp_response_exceeded`. Each evaluation is bounded to 40 MB and 600 seconds;
the shipped inputs allow 16 turns per analyzer and 4 for the reviewer, and
`input.schema.json` enforces those ceilings.

## Replay fixtures

`reviewer-replay.jsonl` is a recording of live Luna reviews, one per
regression case, written by `record-replay.sh` through the analysis profile.
`replay.jsonl` for the full workflow is assembled from the final program of
each stage of live run `cmd-0twkysj3vwd4wwwjjgx42p09qs`, keyed to the hashes
a placeholder fixture missed on. A recording of the whole session cannot
replay elsewhere: the filesystem server signs each cursor with a per-process
key, and a heap kill reports a baseline that differs from run to run, so any
exploratory turn that printed a page or hit the ceiling puts a value in the
conversation that never recurs. See
[#1799](https://github.com/andreasronge/ptc_runner/issues/1799).

## Benchmark fidelity and attribution

This is DABStep dev task 49 with its exact published question, guidelines,
and answer. The payment data is synthetic. This is not a leaderboard
submission and makes no benchmark-score claim.

The official harness supplies a larger context corpus. This example supplies
the pinned payments CSV unmodified plus the exact fraud definition from the
pinned manual, and omits the unrelated fee, merchant, MCC, and acquirer files.
That omission is a deliberate deviation; the payments data is served as
published. The MCP installation can read `data/payments.csv` and nothing else:
not the answer-bearing `reference/dev.jsonl`, not the benchmark context.

The prompt-facing namespace and function docs name DABStep and point at the
relevant manual fact. They do not expose the answer, but they reveal benchmark
identity and may cue memorized knowledge. The workflow's demand for matching
measurements, not a letter, limits what memorization can buy; a
contamination-resistant follow-up would still use neutral dataset APIs and
counterfactual data where BE is not the correct result
([#1637](https://github.com/andreasronge/ptc_runner/issues/1637)).

Dataset revision `9cef9a2976ccce4d306bf220604597788b090d43`. Source and
context hashes are in `fetch-data.sh` and [`cohort.json`](cohort.json);
changing them requires recomputing the reference table and rerunning the
cohorts and replays.

> DABstep: Data Agent Benchmark for Multi-step Reasoning © 2025 by Alexander
> David Egg, Martin Iglesias Goyanes, Andreu Mora, Friso H. Kingma, Thomas
> Wolf, Leandro Von Werra is licensed under Creative Commons Attribution 4.0
> International. <https://creativecommons.org/licenses/by/4.0/>

Upstream dataset: <https://huggingface.co/datasets/adyen/DABstep>
