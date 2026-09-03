# DABStep fraud analysis

DABStep dev task 49 is a multiple-choice question over 138,236 synthetic card
payments:

> What is the top country (ip_country) for fraud? A. NL, B. BE, C. ES, D. FR

The published answer is `B. BE`. NL leads raw fraudulent volume and count and is
the tempting wrong answer; BE wins only on fraud divided by total volume, by
0.087 percentage points.

With four options a model can emit `B. BE` without doing that arithmetic. So the
example is not about getting the answer. It is about three problems you hit
the moment you take a model's answer seriously:

1. **Did it actually do the work?** A correct string is not proof.
2. **Can you afford to keep the proof?** Checking the work means recording what
   the model saw. Here a 23 MB source becomes a 74 MB record — nearly twice the
   memory the program itself was allowed to use.
3. **Who checks the checker?** A second model can read the first one's
   programs and measure the answer itself. It is still a model, with the same
   failure modes, so the decision to publish has to be made in code.

The workflow makes two analyzer runs that are blind to each other, retains the
exact PTC-Lisp programs from both, and gives those programs, the original
input, and the returned figures to a reviewer with the same read-only data
functions. The reviewer returns the volumes it measured and any problems it
saw. Workflow code then ranks all three measurements, requires them to agree
to the cent, and publishes the answer only when they do. The
reviewer's problems are published beside the answer, never used to pick it.

## Run it

Requirements: a current `ptc` build, Node/npm for the pinned filesystem MCP
server, `curl`, and an OpenRouter key for live runs.

```console
./fetch-data.sh
ptc validate ptc-project.json
ptc run ptc-project.json \
  --input inputs/deepseek.json \
  --env-file /absolute/path/to/private.env \
  --envelope out.json
```

The environment file must define `OPENROUTER_API_KEY`. Keep it outside the
repository, owner-readable only, and pass its exact path.
`inputs/deepseek.json` uses DeepSeek for both blind analyzers and GPT-5.6 Luna
for the review. Use `inputs/luna.json` to run all three stages with Luna. The
result names the answer and how it was reached:

```json
{"ok": true, "value": "B. BE", "agreed": true,
 "top_country": {"analysis": "BE", "recheck": "BE", "review": "BE"},
 "problems": []}
```

`value` is `Not Applicable` whenever the three measurements disagree, and
`top_country` then says which stage differed.

### Replay, with no model and no key

```console
./fetch-data.sh
ptc run ptc-project.replay.json --input inputs/luna.json --envelope out-replay.json
```

`replay.jsonl` is assembled from the programs Luna wrote in live run
`cmd-0twkysj3vwd4wwwjjgx42p09qs`: the program each stage ended with, keyed
to the requests this workflow makes. It is not a recording of the whole
session. Luna's exploratory first turn in each stage printed a page, and a
printed page carries a cursor that the filesystem server signs with a
per-process key, so a full recording replays only on the process that made it.
`record-replay.sh` writes such a recording from any run; the reviewer fixture
below is one.

The replay executes the three retained programs against the checksum-pinned
`data/payments.csv`. Each scans all 49 pages and aggregates per country, so
the run makes 147 read-only mission calls, compares the three tables in
workflow code, and returns:

```json
{"ok": true, "value": "B. BE", "agreed": true,
 "top_country": {"analysis": "BE", "recheck": "BE", "review": "BE"},
 "problems": []}
```

Matching is exact, so editing the task, tools, prompt, contracts, or
retained source causes a fixture miss rather than silently reusing
unrelated output. Inside a workflow a miss surfaces as an explicit failure;
the hash it looked for is in the run's private record.

### Reviewer regressions

Two fixed bad sessions test the reviewer without waiting for a model to make
the same mistake again:

```console
ptc run ptc-project.reviewer-replay.json \
  --input inputs/reviewer-wrong-metric.json --envelope wrong-metric.json
ptc run ptc-project.reviewer-replay.json \
  --input inputs/reviewer-off-by-one.json --envelope off-by-one.json
```

The first case is reduced from DeepSeek run
`cmd-40vw2hcbwe10tw74g84hqddg0d`: the country volumes are right, but the
session ranked absolute fraudulent volume and answered `A. NL`. The second
uses a real execution of a pagination program that applies `rest` to every
page and therefore drops the first data row of each page; its answer is still
`B. BE`, so only the totals give it away. In both cases the workflow's own
comparison catches the defect: the reviewer's measurement ranks BE first in
the first case, and disagrees with the analyzer's totals in the second. The
result also carries what the reviewer wrote. For the off-by-one case, live
Luna run `cmd-0cwcp0r52fj5tbfk7192bf3htx` said:

> The analyzer discarded the first data row on every page by applying
> `(rest ...)` to rows, even though read-page rows are already data vectors;
> its aggregates are therefore incomplete.

For the wrong-metric case, run `cmd-3kbr0mpsavy4estjs3sszqa0hb` measured the
right table and ranked BE first, but its prose muddled which ranking the
session had used. That is the point of comparing measurements rather than
reading verdicts.

`reviewer-replay.jsonl` is a recording of those two runs, each a single Luna
turn that scanned all 49 pages. `mix nightly` executes both replays and
asserts the comparison, not the wording. The instruction is short on purpose:
the reviewer is asked to check the programs, solve the task itself, and
return its volumes and any problems. An earlier wording that made the
independent solution optional produced three failures in a row: a reviewer
that called only `fraud-definition` and approved, one that repeated the
absolute-volume mistake and approved, and one that flagged the off-by-one
session for the wrong reason.

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
keeps three things that let you tell the difference, and the workflow uses the
first of them itself: `agent.core/run-outcome` with `retain_programs` returns
every admitted program with a bounded execution summary, and the workflow
passes those straight to the same-run reviewer.

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
benchmark scores. They predate the current raw-CSV reader and the review
stage and are not re-scored against them.

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

### What the review stage found

The review stage went through three live samples before the decision moved
into workflow code. With the first wording the reviewer approved without
running a single program (`cmd-12ey2m6pd7je5x0xeaweb1zmpq`). With a second
wording it raised five objections to a correct answer after one exploratory
read (`cmd-6efc163cz9fxvpvr8j9bt5m7c7`). With the final wording it scanned
every page itself, then compared its ratio-ranked winner against the option
with the largest absolute fraud volume and vetoed the right answer
(`cmd-7xx3se058f8jn6wqfbkqy4qm71`). A reviewer that can veto is a second
single point of failure; a reviewer that must show its measurement is
evidence.

Live runs of the final workflow, 2026-09-03, are in
[`evidence/integrated-cohort.json`](evidence/integrated-cohort.json):

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

"Analyzers" names the model behind both blind derivations; the reviewer is
Luna in every row. Ten runs of one task on one day, not a benchmark score.

`problems` counts what the reviewer wrote, published beside the answer.
Where it wrote something on a correct run, it restated the fraud definition
or objected to an intermediate step whose ranking the workflow never used.
The failed DeepSeek run hit the heap ceiling with a retain-all program, then
handed `read-page` a cursor it had composed itself, which failed closed as
`:malformed-cursor`; the stage gave up and the workflow failed rather than
answer.

## Keeping the evidence small

Three numbers that are easy to conflate:

| | bytes |
|---|---:|
| source file | 23,581,339 |
| evaluation heap ceiling | 40,000,000 |
| evidence, captured in full | 74,373,399 |

The program never holds the file. It streams one page at a time and keeps eight
per-country pairs, so it finishes comfortably inside a 40 MB heap. The recording
is what does not fit: capturing every byte that crossed the capability boundary
costs about three times the source, and nearly twice the memory the program was
allowed to use in the first place.

That ceiling is real, not decorative — every DeepSeek run above and one Luna
run tried to retain every row, hit it, and rewrote their own program as a
streaming aggregation to finish. So a workflow can sit comfortably inside its
sandbox and still be impossible to record. The two problems are separate;
this section is the second one.

That source is a single file, `data/payments.csv`. `fetch-data.sh` downloads it,
checks its hash, header, and line count, and stops — it does not reshape the
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

**Record identities, not payloads.** The full-capture figure above is three
times the source because an MCP result carries its payload twice, in both
`content` and `structuredContent`. The read mapping therefore declares
`"inspection_capture": "digest_results"`:

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

Each evaluation is bounded to 40 MB and 600 seconds. The shipped inputs allow
up to 16 turns for each analyzer and 4 for the reviewer; those ceilings are
enforced by `input.schema.json`, not merely set by the input files.

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
ptc repl --profile private-run-analysis-v2 --private-unattended \
  --resource traces=.ptc/traces --resource inspection=.ptc/inspection \
  --format jsonl -e '(analysis/runs {"limit" 1})'

mkdir -p .ptc-transcripts && chmod 700 .ptc-transcripts
ptc transcript RUN_REF \
  --traces .ptc/traces \
  --inspection .ptc/inspection \
  --private-unattended \
  --private-output .ptc-transcripts/run.private.json
ptc viewer ptc-project.json
```

Every number in this README came out of that profile: `analysis/counters`
for calls and cost, `generated_sources` filtered by `mission_name` for what
each stage ran, and `execution_prints` for what the workflow printed.
`AGENTS.md` has the exact expressions. A transcript carries the same private
material as the record it came from, so `.ptc-transcripts/` is gitignored and
must stay owner-only. Inspection is sealed as `.ptc/inspection/<run-ref>.ptcins`
and is queried through the analysis and transcript interfaces, not parsed
directly. The checked-in evidence holds hashes and the selected generated
source — never raw inspection or credentials.

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
