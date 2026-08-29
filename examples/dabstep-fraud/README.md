# DABStep fraud analysis

DABStep dev task 49 is a multiple-choice question over 138,236 synthetic card
payments:

> What is the top country (ip_country) for fraud? A. NL, B. BE, C. ES, D. FR

The published answer is `B. BE`. NL leads raw fraudulent volume and count and is
the tempting wrong answer; BE wins only on fraud divided by total volume, by
0.087 percentage points.

With four options a model can emit `B. BE` without doing that arithmetic. So the
example is not about getting the answer. It is about two problems you hit the
moment you take a model's answer seriously:

1. **Did it actually do the work?** A correct string is not proof.
2. **Can you afford to keep the proof?** Checking the work means recording what
   the model saw, and a 23 MB source can turn into a 74 MB record.

## Run it

Requirements: a current `ptc` build, Node/npm for the pinned filesystem MCP
server, `curl`, `jq`, and an OpenRouter key for live runs.

```console
./fetch-data.sh
ptc validate ptc-project.json
ptc run ptc-project.json \
  --input inputs/deepseek.json \
  --env-file /absolute/path/to/private.env \
  --envelope out.json
jq '.result.value' out.json
```

The environment file must define `OPENROUTER_API_KEY`. Keep it outside the
repository, owner-readable only, and pass its exact path. Use
`inputs/luna.json` for GPT-5.6 Luna. The result is an object because PtcRunner
requires an object-root result contract:

```json
{"ok": true, "value": "B. BE"}
```

### Replay, with no model and no key

```console
./fetch-data.sh
ptc run ptc-project.replay.json --input inputs/luna.json --envelope out-replay.json
```

The checked-in fixture holds all five turns of a live Luna run: an exploratory
read, a malformed `defn` the model then corrected, the corrected scan, its
execution, and `(return "B. BE")`. Replay executes every one of those programs
and performs all 50 reads against the checksum-pinned `data/payments.csv`.
Matching is exact, so editing the task, tools, or prompt causes a fixture miss
rather than silently reusing unrelated output.

One edit was made to the recording. The model's exploratory program printed
`next_cursor`, and `ptc-fs-mcp` signs each cursor with a per-process key, so
that value differs on every server start and no fixture could match the next
request. The preview keeps `:rows` and `:read_calls` and drops the cursor.

## Did the model actually do the work?

The official manual defines fraud as fraudulent volume over total volume — here
`eur_amount`, with fraudulent rows marked `has_fraudulent_dispute == True`.
Computed correctly, that gives:

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

A run that answers `B. BE` may or may not have produced that table. PtcRunner
keeps three things that let you tell the difference.

**The program the model wrote.** Preserved verbatim in
[`evidence/luna-01.clj`](evidence/luna-01.clj), from Luna run
`cmd-0xfcwmstj3d6xraxrm810bfm9p`:

```clojure
(let [cols ["ip_country" "eur_amount" "has_fraudulent_dispute"]
      res (loop [cur nil acc {}]
            (let [p (dabstep.payments/read-page cur cols)
                  a (reduce
                      (fn [m row]
                        (let [c (nth row 0)
                              amt (nth row 1)
                              fraud? (nth row 2)
                              [total fraud] (get m c [0 0])]
                          (assoc m c
                            [(+ total (or amt 0))
                             (+ fraud (if fraud? (or amt 0) 0))])))
                      acc
                      (get p :rows))]
              (if (nil? (get p :next_cursor))
                a
                (recur (get p :next_cursor) a))))
      opts [["A" "NL"] ["B" "BE"] ["C" "ES"] ["D" "FR"]]
      scored (map
               (fn [[letter country]]
                 (let [[total fraud] (get res country [0 0])]
                   [letter country (if (pos? total) (/ fraud total) 0)]))
               opts)
      best (reduce
             (fn [x y] (if (> (nth y 2) (nth x 2)) y x))
             (first scored)
             (rest scored))]
  (return (str (nth best 0) ". " (nth best 1))))
```

It picks the three required columns, follows every cursor to `nil`, keeps only
per-country aggregates, divides, ranks the four options, and returns. That is
the work, and you can read it.

**Every read it made.** Each page reports `read_calls` and `content_hashes`, so
a page is always attributable to the read that produced it.

**Every model exchange.** Recorded in full, never digested.

### What the reader can and cannot prove

`read-page` performs exactly one upstream read per call and hands the MCP cursor
straight back to the server. That cursor is opaque and server-signed, so a
forged position fails the read instead of returning invented rows.

What the model can still author is `carry`, the partial final line of the
previous page. `read-page` validates it — exact key set, types, no line break,
at most 65,536 bytes — and fails closed with `:malformed-cursor`. A model doing
one genuine read per page could still fabricate that one line, and no more.

These checks are deliberately absent from the `read-page` docstring. They are
guarantees an auditor reads out of the trace, not instructions to the model.

### What checking actually found

Five independent live samples per model, 2026-08-24, same task, six-turn budget,
data, contracts, and limits, caching disabled. Observations of one task, not
benchmark scores. They predate the current raw-CSV reader and are not re-scored
against it.

| Model | Exact answer | Evidence-backed | Model calls | Observed cost |
|---|---:|---:|---:|---:|
| `openrouter:deepseek/deepseek-v4-flash` | 3/5 | 3/5 | 29 | $0.006663 |
| `openrouter:openai/gpt-5.6-luna` | 4/5 | 1/5 | 16 | $0.003161 |

Luna got the answer right more often and earned it less often. "Evidence-backed"
was defined before classification and requires all of: the exact answer; the
three semantic columns; cursor traversal to the end; per-country total and
fraudulent EUR aggregation, traceably derived from a successful scan; and the
division performed in generated PTC-Lisp before selecting BE.

The gap is not fraud, it is shortcuts. One Luna run used a transaction-count
rate instead of the manual's volume rate. Two computed the numerators and
denominators but left the division to model reasoning. Those are right answers
that fail the stricter test. One DeepSeek run blew the heap with a retain-all
program and then completed a streaming aggregation; an earlier review
misattributed that failure and wrongly scored the run unproven.

Every run, including the four that failed outright,
is recorded with its run reference, source hashes, calls, duration, cost, and
classification in [`evidence/cohort.json`](evidence/cohort.json); a later
single-sample smoke on the merged runtime is in
[`evidence/current-main-smoke.json`](evidence/current-main-smoke.json).

## Keeping the evidence small

The source is one 23,581,339-byte `data/payments.csv`. `fetch-data.sh` downloads
it, checks its hash, header, and line count, and stops — it does not reshape the
data, so nothing between the benchmark file and the model is authored by a
helper script. The MCP installation can read that file and nothing else: not the
answer-bearing `reference/dev.jsonl`, not the benchmark context.

`payments.clj` pages the file and projects the columns the model asked for, so
the projection stays model-selected. The application grants two prompt-visible
functions — the fraud definition and the paged reader. The raw MCP read stays
out of the prompt via `model_visible: false`.

**Read fewer, bigger pages.** The server runs with `--max-read-bytes 500000
--max-result-bytes 1000000`, giving 485,376-byte pages: 49 reads for the whole
file instead of the 1,440 that `ptc-fs-mcp`'s 16,384-byte default would need.
Set the consumer ceiling one notch higher (`max_result_bytes` 1,048,576) —
PtcRunner's accounting is slightly wider than the server's, and equal values are
rejected as `mcp_response_exceeded`.

**Record identities, not payloads.** Captured in full, this run writes
74,373,399 bytes of private inspection, roughly three times the source, because
an MCP result carries its payload in both `content` and `structuredContent`. The
read mapping therefore declares `"inspection_capture": "digest_results"`:

| | bytes |
|---|---:|
| full capture | 74,373,399 |
| `digest_results` | **270,127** |

Inspection still keeps the capability arguments, the complete MCP request
bodies, every model exchange, and an identity for each accepted response:

```json
{"encoding": "ptc-deterministic-json-v1", "encoded_bytes": 496387,
 "sha256": "sha256:16b97ab9ea6519107313b22745f215d805335f2abcff0e365d5afa51c9e1500a"}
```

Only the accepted response body is dropped. You still see that 49 reads
happened, in order, with those exact arguments, each returning a value of
exactly that size and identity — and because `payments.csv` is checksum-pinned,
the content is reproducible and the identity confirms it is the same one.
Rejected responses, error envelopes, and MCP stderr keep their bodies.

Evaluation is bounded to 40 MB, 600 seconds, 256 mission capability calls, and
six agent turns; the turn ceiling is enforced by `input.schema.json`, not merely
set by the shipped inputs.

## Inspect a run

Traces, private inspection, results, and envelopes are written below owner-only
`.ptc/`. Treat inspection as sensitive — it holds exact model exchanges — and
it is gitignored. A digested record reports `capture_mode: "digest_results"` and
`result_available?: false`; that is a weaker evidence class, not a missing or
truncated exchange.

`ptc` owns the whole `.ptc/` layout and never repairs it in place. Writing
anything else below it — a transcript included — makes every later `ptc run`
fail with `envelope/publication_failed: … is incomplete`. Send transcripts
somewhere you own:

```console
run_ref=$(jq -r '.run_ref' out.json)
mkdir -p .ptc-transcripts && chmod 700 .ptc-transcripts
ptc transcript "$run_ref" \
  --traces .ptc/traces \
  --inspection .ptc/inspection \
  --private-unattended \
  --private-output ".ptc-transcripts/${run_ref}.private.json"
ptc viewer ptc-project.json
```

A transcript carries the same private material as the record it came from, so
`.ptc-transcripts/` is gitignored and must stay owner-only. Inspection is sealed
as `.ptc/inspection/<run-ref>.ptcins` and is queried through the analysis and
transcript interfaces, not parsed directly. The checked-in evidence holds hashes
and the selected generated source — never raw inspection or credentials.

## Benchmark fidelity and attribution

This is DABStep dev task 49 with its exact published question, guidelines, and
answer. The payment data is synthetic. This is not a leaderboard submission and
makes no benchmark-score claim.

The official harness supplies a larger context corpus. This example supplies the
pinned payments CSV unmodified plus the exact fraud definition from the pinned
manual, and omits the unrelated fee, merchant, MCC, and acquirer files. That
omission is a deliberate deviation; the payments data is served as published.

The prompt-facing namespace and function docs name DABStep and point at the
relevant manual fact. They do not expose the answer, but they reveal benchmark
identity and may cue memorized knowledge. A contamination-resistant follow-up
should use neutral dataset APIs and test option permutations and counterfactual
data where BE is not the correct result.

Dataset revision `9cef9a2976ccce4d306bf220604597788b090d43`. Source and context
hashes are in `fetch-data.sh` and `evidence/cohort.json`; changing them requires
recomputing the reference table and rerunning the cohorts and replay.

> DABstep: Data Agent Benchmark for Multi-step Reasoning © 2025 by Alexander
> David Egg, Martin Iglesias Goyanes, Andreu Mora, Friso H. Kingma, Thomas
> Wolf, Leandro Von Werra is licensed under Creative Commons Attribution 4.0
> International. <https://creativecommons.org/licenses/by/4.0/>

Upstream dataset: <https://huggingface.co/datasets/adyen/DABstep>
