# DABStep fraud analysis

DABStep dev task 49 is a multiple-choice question over 138,236 synthetic card
payments:

> What is the top country (ip_country) for fraud? A. NL, B. BE, C. ES, D. FR

The published answer is `B. BE`. NL leads raw fraudulent volume and count and
is the tempting wrong answer; BE wins only on fraud divided by total volume, by
0.087 percentage points.

With four options a model can emit `B. BE` without doing that arithmetic, so a
correct string is not proof it did the calculation. PtcRunner preserves the
generated program and its bounded tool traffic, so the work can be checked
instead of the answer. In the observed five-run cohorts, DeepSeek returned the
exact answer 3/5 times and GPT-5.6 Luna 4/5 times—but private transcript
inspection showed fully trace-proven computation in 3/5 and 1/5 runs
respectively.

## Run it

Requirements: `ptc` 0.14.0, Node/npm for the pinned filesystem MCP server,
`curl`, `jq`, and an OpenRouter key for live runs. The host documents declare
`structured_output_mode` and `usage_guarantees` on every live model, which
current `ptc` requires; an older build predating that requirement rejects them
as unknown properties.

```console
./fetch-data.sh
ptc validate ptc-project.json
ptc doctor ptc-project.json --connect --env-file /absolute/path/to/private.env
ptc run ptc-project.json \
  --input inputs/deepseek.json \
  --env-file /absolute/path/to/private.env \
  --envelope out.json
jq '.result.value' out.json
```

The environment file must define `OPENROUTER_API_KEY`. Keep it outside the
repository, owner-readable only, and pass its exact path with `--env-file`.
Use `inputs/luna.json` for GPT-5.6 Luna.

The command result is an object because PtcRunner 0.14 requires an object-root
result contract:

```json
{"ok": true, "value": "B. BE"}
```

### Replay without a live model

The checked-in replay preserves all five turns of a live GPT-5.6 Luna run
against the raw CSV: an exploratory read, a malformed `defn` the model then
corrected, the corrected scan, its execution, and `(return "B. BE")`. Replay
executes every one of those programs and performs all 50 local MCP reads
against the checksum-pinned `data/payments.csv`.

One byte of the recorded conversation is edited. The model's exploratory
program printed `next_cursor`; `ptc-fs-mcp` signs each cursor with a
per-process key, so that signature differs on every server start and no fixture
could ever match the following request. The preview drops the unused
`next_cursor` and keeps `:rows` and `:read_calls`. Nothing else is altered.

```console
./fetch-data.sh
ptc run ptc-project.replay.json \
  --input inputs/luna.json \
  --envelope out-replay.json
```

No model credential is needed. Replay is exact-request matched: changing the
task, tools, prompt, or continuation causes a fixture miss instead of silently
using unrelated output. Three consecutive runs returned `B. BE` with 50 mission
capability calls and no errors, and it was verified again after deleting `data/`
and re-running `fetch-data.sh`, producing a byte-identical 74,371,086-byte
inspection artifact.

## What the program computed

The official DABStep manual defines fraud as the ratio of fraudulent volume to
total volume. Here, volume is `eur_amount`, and fraudulent rows have
`has_fraudulent_dispute == True`.

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

NL is the tempting wrong answer: it leads both raw fraudulent transaction
count and raw fraudulent EUR volume. Only the ratio puts BE first, by about
0.087 percentage points.

## The actual generated PTC-Lisp

Luna run `cmd-0xfcwmstj3d6xraxrm810bfm9p` generated the program preserved in
[`evidence/luna-01.clj`](evidence/luna-01.clj). The committed file is the exact
generated source plus a trailing newline, so two different hashes are recorded:
the inspection source hash is
`c61fd9af9544a6f7a12fd1391826ecbf57a4bee7f1288f1329d025fcd9340a7f` and the file
itself hashes to
`7d26a2642dd7f2f3552189d961921c72dced16a3e23cf57fc1779c0545a79047`. Both appear
in [`evidence/cohort.json`](evidence/cohort.json) as `source_hash` and
`source_file_sha256`.

Formatted for display, it:

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

The model chose the three required columns, followed every cursor to `nil`,
kept only per-country aggregates, divided fraudulent EUR by total EUR, ranked
the four options, and returned the required format in one program.

That run used the column-projection reader. The program is reproduced as
generated; it still compiles and runs against the current raw-CSV reader
unchanged, because `read-page` keeps the same signature and cursor discipline.

## Observed comparison

These are five independent live samples per model observed on 2026-08-24 with
the same task, six-turn budget, data, contracts, and PtcRunner limits. Caching
was disabled. They are observations of one task, not benchmark scores.

They predate the raw-CSV reader. The cohort ran against the column-projection
design, so its read counts and inspection sizes describe that design. The
prompt-visible API is unchanged — the same `read-page` calls work against either
reader — but the cohort is not re-scored against the current one and no run
below was repeated.

| Model | Exact answer | Evidence-backed | Model calls | Observed cost |
|---|---:|---:|---:|---:|
| `openrouter:deepseek/deepseek-v4-flash` | 3/5 | 3/5 | 29 | $0.006663 |
| `openrouter:openai/gpt-5.6-luna` | 4/5 | 1/5 | 16 | $0.003161 |

“Evidence-backed” was defined before classification and requires all of:

- exact published answer `B. BE`;
- the three semantic columns above;
- terminal cursor traversal;
- per-country total and fraudulent EUR aggregation; and
- traceable derivation of those aggregates from a successful scan, including
  values returned to a later turn as a model-visible observation; and
- division into rates in generated PTC-Lisp before selecting BE.

One Luna run got the right answer using transaction-count rate instead of the
manual-defined EUR-volume rate. Two more computed EUR numerators and
denominators but left the division to model reasoning. Those count as exact
answers and fail the stricter computation criterion. One DeepSeek run first
exceeded the heap with a retain-all program, then completed a separate
streaming aggregation. Its following model request contained all eight exact
aggregate pairs; the model reused those observed values in a later program
that performed the division. An earlier review associated the heap failure
with the wrong generated program and incorrectly classified this run as
unproven. Two DeepSeek runs failed at the turn/result boundary. Every run,
including failures, is recorded with its run reference, source hashes, calls,
duration, cost, and classification in
[`evidence/cohort.json`](evidence/cohort.json).

### Current-main smoke

After the runtime fixes linked from the experiment were merged, one new live
sample per model and a portable replay were run on 2026-08-26. These samples
verify the current product path; they are not additions to the original
five-run cohorts.

| Path | Outcome | Model calls | Mission reads | Observed cost |
|---|---|---:|---:|---:|
| GPT-5.6 Luna live | turn limit after final evaluation error | 6 | 158 | $0.001561 |
| DeepSeek V4 Flash live | result contract rejected a rate vector at `/value` | 6 | 134 | $0.001326 |
| Luna replay | `B. BE` | 2 | 133 | — |

Those samples also used the column-projection reader, so their mission-read
counts reflect 16,384-byte pages. Both live failures were model-authored rather
than provider or artifact failures. Luna received result-contract feedback after invalid terminal
candidates and continued within its remaining turns. DeepSeek completed a
streaming EUR-volume calculation on its final turn but returned a sorted rate
vector instead of one permitted answer string. The sealed inspection records,
resolved-model counters, selected-run transcript check, costs, and run
references are recorded in
[`evidence/current-main-smoke.json`](evidence/current-main-smoke.json).

## Why the model reads the raw CSV

The pinned source is one 23,581,339-byte `data/payments.csv`. `fetch-data.sh`
downloads it, verifies its checksum, header, and line count, and stops there. It
does not reshape the data, so nothing between the benchmark file and the model
is authored by a helper script.

The MCP installation can read only `data/payments.csv`. It cannot read the
answer-bearing `reference/dev.jsonl` or the benchmark context files.

`payments.clj` pages that file and projects the columns the model asked for, so
the projection is still model-selected — it happens in the component rather than
on disk. The application grants only two prompt-visible functions: the official
fraud definition and the paged reader. The raw MCP function stays out of the
prompt because `model_visible` defaults to `false`; both host documents state it
explicitly so the guarantee is checkable without consulting the schema.

The server runs with `--max-read-bytes 500000 --max-result-bytes 1000000`, which
is what makes reading the whole file affordable: one page carries 485,376 source
bytes, so a complete scan is 49 reads instead of the 1,440 the 16,384-byte
default of `ptc-fs-mcp` would need. The consumer ceiling is `max_result_bytes`
1,048,576, one notch above the server's, because PtcRunner's accounting is
slightly wider than the server's and equal values are rejected as
`mcp_response_exceeded`.

Reading all 21 columns rather than three would cost evidence volume. Captured in
full, this run records 74,373,399 bytes of private inspection — about three
times the source, because an MCP result carries its payload in both `content`
and `structuredContent`.

The read mapping therefore declares `"inspection_capture": "digest_results"`,
which brings the artifact to **270,127 bytes**. Inspection keeps the capability
arguments, the complete MCP request bodies, every model exchange, and a
`result_identity` and `response_identity` for each accepted response:

```json
{"encoding": "ptc-deterministic-json-v1", "encoded_bytes": 496387,
 "sha256": "sha256:16b97ab9ea6519107313b22745f215d805335f2abcff0e365d5afa51c9e1500a"}
```

What is dropped is the accepted response body. An auditor can still see that 49
reads happened, in order, with those exact arguments, each returning a value of
exactly that size and identity — and `payments.csv` is checksum-pinned by
`fetch-data.sh`, so the content is reproducible and the identity confirms it is
the same one. Rejected responses, error envelopes, and MCP stderr keep their
bodies. Model exchanges are never digested.

Evaluation is bounded to 40 MB, 600 seconds, 256 mission capability calls, and
six agent turns; the turn ceiling is enforced by `input.schema.json` rather than
only set by the shipped inputs.

### What the reader's cursor does and does not prove

`read-page` performs exactly one upstream read per call and hands the upstream
MCP cursor straight back to the server. That cursor is opaque and
server-validated — `ptc-fs-mcp` signs it with a per-process key — so a forged
position fails the read instead of returning invented rows. Every page reports
`read_calls` and `content_hashes`, so a page is always attributable to the read
that produced it.

What the model can still author is `carry`: the partial final line of the
previous page, which `read-page` prepends before splitting. `read-page`
validates it — exact cursor key set, types, no line break, at most 65,536
bytes — and fails closed with `:malformed-cursor` otherwise. A model performing
one genuine read per page could still fabricate at most that one line.

That is a tighter bound than the column-projection reader this example used
before, whose cursor carried up to 65,536 buffered values per column and needed
an `:unbacked-page` check because a page could be served entirely from that
buffer. Reading one file leaves no buffer to serve from and no unbacked page to
refuse.

These checks are deliberately absent from the `read-page` docstring. They are
runtime guarantees an auditor reads out of the trace, not instructions to the
model. Announcing a check to the model would change the experiment without
making the check stronger.

## Benchmark fidelity and attribution

This is DABStep dev task 49 with its exact published question, guidelines, and
answer. The released payment data is synthetic, while the task is derived from
realistic analytical work. This example is not a DABStep leaderboard
submission and makes no benchmark-score claim.

The official harness supplies a larger context corpus. This example supplies
the pinned payments CSV unmodified, plus the exact fraud definition from the
pinned official manual through a prompt-visible domain function. It omits
unrelated fee, merchant, MCC, and acquirer files. That omission is a deliberate
harness deviation; the payments data itself is served as published.

The prompt-facing namespace and function documentation also name DABStep and
point directly to the relevant manual fact. They do not expose the published
answer, but they reveal benchmark identity and may cue memorized knowledge. A
contamination-resistant follow-up should use neutral dataset APIs and verify
the workflow on option permutations and counterfactual data where BE is not
the correct result.

Dataset revision:
`9cef9a2976ccce4d306bf220604597788b090d43`. The source and context hashes are
recorded in `fetch-data.sh` and `evidence/cohort.json`; updating them requires
recomputing the reference table and rerunning both cohorts and replay.

> DABstep: Data Agent Benchmark for Multi-step Reasoning © 2025 by Alexander
> David Egg, Martin Iglesias Goyanes, Andreu Mora, Friso H. Kingma, Thomas
> Wolf, Leandro Von Werra is licensed under Creative Commons Attribution 4.0
> International. <https://creativecommons.org/licenses/by/4.0/>

Upstream dataset: <https://huggingface.co/datasets/adyen/DABstep>

## Inspect a run

The project writes canonical traces, private inspection, results, and command
envelopes below owner-only `.ptc/`. Treat inspection as sensitive: it contains
exact model exchanges and is intentionally gitignored. Read payloads are stored
as identities rather than content, so a digested record reports
`capture_mode: "digest_results"` and `result_available?: false` — that is a
weaker evidence class, not a missing or truncated exchange.

`ptc` owns the whole `.ptc/` layout: it creates `envelopes/`, `inspection/`,
`results/`, and `traces/` as one owner-only unit and never repairs that root in
place. Writing anything else below it — including a transcript — makes every
later `ptc run` fail with `envelope/publication_failed: … is incomplete`, and
makes `ptc viewer` fail with `viewer/internal_error`. Send transcripts to a
directory you own instead, and lock it down yourself.

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

A transcript carries the same private material as the inspection record it is
derived from, so `.ptc-transcripts/` is gitignored and must stay owner-only.

Current PtcRunner writes sealed private inspection evidence as
`.ptc/inspection/<run-ref>.ptcins`; it is intentionally queried through the
bounded analysis and transcript interfaces rather than parsed as JSONL.

The checked-in evidence contains hashes and the selected generated source, not
raw private inspection or credentials.
