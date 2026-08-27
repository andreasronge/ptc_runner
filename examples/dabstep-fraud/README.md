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

The checked-in replay preserves the representative Luna run's final analysis
program. Its exploratory first program omits the unused `next_cursor` from its
printed preview: upstream MCP cursors are intentionally opaque and may change
when `fetch-data.sh` recreates checksum-identical files. The replay still uses
exact request matching, executes the generated PTC-Lisp, and performs all 133
local MCP reads against the checksum-pinned data projection.

```console
./fetch-data.sh
ptc run ptc-project.replay.json \
  --input inputs/luna.json \
  --envelope out-replay.json
```

No model credential is needed. Replay is exact-request matched: changing the
task, tools, prompt, or continuation causes a fixture miss instead of silently
using unrelated output.

The portable fixture was verified again after deleting and rebuilding the
column projection with `fetch-data.sh`.

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

## Observed comparison

These are five independent live samples per model observed on 2026-08-24 with
the same task, six-turn budget, data, contracts, and PtcRunner limits. Caching
was disabled. They are observations of one task, not benchmark scores.

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

Both live failures were model-authored rather than provider or artifact
failures. Luna received result-contract feedback after invalid terminal
candidates and continued within its remaining turns. DeepSeek completed a
streaming EUR-volume calculation on its final turn but returned a sorted rate
vector instead of one permitted answer string. The sealed inspection records,
resolved-model counters, selected-run transcript check, costs, and run
references are recorded in
[`evidence/current-main-smoke.json`](evidence/current-main-smoke.json).

## Why the data is columnar

The pinned source CSV is 23.6 MB. `fetch-data.sh` verifies it first, then
deterministically transposes all 21 columns into newline-delimited files. The
model still chooses any distinct projection; host code contains no answer,
country, or fraud-rate logic.

The MCP installation can read only `data/columns/*.txt`. It cannot read the raw
CSV, the answer-bearing `reference/dev.jsonl`, or the benchmark context files.
For the representative three-column run this reduced exact private inspection
to 8.3 MB. The initial row-file design exceeded PtcRunner's fail-closed 16 MB
inspection capture after 294 reads; the projected design completes in 133.

`payments.clj` aligns independently paged columns with bounded buffers. The
application grants only two prompt-visible functions: the official fraud
definition and the paged reader. The raw MCP function stays out of the prompt
because `model_visible` defaults to `false`; both host documents now state it
explicitly so the guarantee is checkable without consulting the schema.
Evaluation is bounded to 40 MB, 600 seconds, 256 mission capability calls, and
six agent turns; the turn ceiling is enforced by `input.schema.json` rather than
only set by the shipped inputs.

### What the reader's cursor does and does not prove

The upstream MCP cursor is opaque and server-validated, so a forged one fails
the read. The outer `read-page` cursor is not. It is an ordinary map the model
receives and hands back, and it carries the per-column leftovers that keep
independently paged columns aligned. PtcRunner exposes no keyed digest to
mission components, and the pinned filesystem server accepts no positional read,
so this example cannot seal that cursor. Two checks bound it instead:

- `read-page` validates every column state — exact key set, types, a `carry`
  containing no line break, at most 65,536 buffered values — and fails closed
  with `:malformed-column-state` otherwise.
- A page that would emit rows while performing zero upstream reads is refused
  with `:unbacked-page`. Every page also reports `read_calls`, `content_hashes`,
  and `unbacked_columns`, so a column served from the cursor buffer is visible
  in the trace instead of being indistinguishable from one read from disk.

Both checks are deliberately absent from the `read-page` docstring. They are
runtime guarantees an auditor reads out of the trace, not instructions to the
model, and leaving the prompt byte-identical is what keeps the preserved cohort
comparable and the checked-in replay runnable. Announcing a check to the model
would change the experiment without making the check stronger.

That closes the zero-cost fabrication path: a cursor asserting `done` with
invented values now fails instead of returning rows. It does not make the cursor
unforgeable. A model that performs one genuine read per page can still return
other columns' values from a buffer it authored. Sealing it properly needs
either a keyed digest available to mission components or aligned paging inside
the provider, and is left to follow-up work. The cohort below was classified
before these checks existed and is not re-scored by them.

## Benchmark fidelity and attribution

This is DABStep dev task 49 with its exact published question, guidelines, and
answer. The released payment data is synthetic, while the task is derived from
realistic analytical work. This example is not a DABStep leaderboard
submission and makes no benchmark-score claim.

The official harness supplies a larger context corpus. This example supplies
the payments data plus the exact fraud definition from the pinned official
manual through a prompt-visible domain function. It omits unrelated fee,
merchant, MCC, and acquirer files, and exposes a lossless model-selected column
projection instead of raw rows. Those are deliberate harness deviations.

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
exact model exchanges and capability payloads and is intentionally gitignored.

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
