# DABStep fraud analysis

One question, four options, 138,236 payment rows:

> What is the top country (ip_country) for fraud? A. NL, B. BE, C. ES, D. FR

The published answer is `B. BE`. NL has more fraud in euros and in count; BE
wins only on fraud divided by total volume, by 0.087 percentage points. A model
can say `B. BE` without doing that arithmetic. This example is about knowing
whether it did, and about what happens when the model you ask to check is a
model too.

## What you can watch it do

- **Work through a table one page at a time and keep almost nothing.** The
  dataset is 138,236 rows. A generated program pages through it with
  `read-page` and carries eight per-country pairs, so a whole scan is 49 reads
  and a handful of numbers. The page and capture sizes are in
  [`evidence/STUDY.md`](evidence/STUDY.md#keeping-the-evidence-small).
- **Turn a memory limit into a better program.** `ptc.json` sets
  `evaluation_heap_words` to 5,000,000, which is 40 MB for each program
  evaluation inside a mission. That ceiling is per evaluation; it is not a cap
  on total application memory. A program that tries to hold every row is
  stopped and rolled back, and the loop hands the model that fact as feedback.
  Every DeepSeek run in the
  [integrated cohort](evidence/STUDY.md#cohorts) then rewrote it as a streaming
  aggregation.
- **Check the arithmetic before accepting the answer.** Two blind analyses and a
  reviewer each compute the per-country totals, and `workflow.clj` publishes
  the letter only when all three tables agree to the cent. That comparison is workflow code, tested without a
  model in `test/ptc_runner/kernel/dabstep_review_comparison_test.exs`, and it
  catches all three seeded regressions replayed in
  [`evidence/STUDY.md`](evidence/STUDY.md#replay-fixtures).

## Run it

Requirements: a current `ptc` build, Node/npm for the pinned filesystem MCP
server, `curl`, and an OpenRouter key for live runs.

Download the dataset first. Both the live and the replay project read
`data/payments.csv` through the filesystem MCP server, so replay removes the
model calls, not the download:

```console
./fetch-data.sh
ptc validate ptc-project.json
```

Live, with a key:

```console
ptc run ptc-project.json --input inputs/deepseek.json \
  --env-file /absolute/path/to/private.env --envelope out.json
```

Without a key:

```console
ptc run ptc-project.replay.json --input inputs/luna.json --envelope out-replay.json
```

The result value:

```json
{"ok": true, "value": "B. BE", "agreed": true,
 "top_country": {"analysis": "BE", "recheck": "BE", "review": "BE"},
 "problems": []}
```

The replay run returns exactly that. It executes three retained programs from a
live Luna run against the pinned data, 147 reads, and makes no model network
calls. What the fixture is and is not is in
[`evidence/STUDY.md`](evidence/STUDY.md#replay-fixtures).

Live runs vary. `inputs/deepseek.json` uses DeepSeek for both analyzers and
GPT-5.6 Luna for the review; `inputs/luna.json` uses Luna throughout. A live
run makes 6 to 17 model calls and costs under a cent. Nine of the ten runs in
the [integrated cohort](evidence/STUDY.md#cohorts) agreed on `B. BE`, some of
them with a reviewer problem recorded beside the answer; the tenth failed.

## A program it generated

The analyzers write their own PTC-Lisp. This is what a DeepSeek analyzer wrote
in run `cmd-7xx3se058f8jn6wqfbkqy4qm71` after an earlier attempt tried to keep
all 138,236 rows and was stopped at the evaluation heap ceiling:

```clojure
(defn process-page [acc page]
  (reduce (fn [m row]
            (let [country (get row 0) amount (get row 1) fraud? (get row 2)
                  cur (get m country {:total 0.0 :fraud 0.0})]
              (assoc m country {:total (+ (:total cur) amount)
                                :fraud (if fraud? (+ (:fraud cur) amount) (:fraud cur))})))
          acc (get page "rows")))

(defn read-all-pages [cursor acc]
  (let [page (dabstep.payments/read-page cursor cols)
        next-cursor (get page "next_cursor")]
    (if (nil? next-cursor)
      (process-page acc page)
      (recur next-cursor (process-page acc page)))))
```

Eight per-country pairs instead of 138,236 rows.

## Verify and correct within the run

The reviewer now proposes its measurements through `agent.core/run-outcome`'s
`verify` callback. Deterministic workflow code compares them with both blind
derivations. When those two agree but the reviewer differs, the same reviewer
gets discrepancy feedback and at most one correction, within its original
`review_turns` budget. It must recompute rather than copy the expected totals.
If the blind derivations disagree, verification is unresolved immediately.
If the corrected measurements still disagree, or no correction turn is
available, the answer stays `Not Applicable`. Other agent or provider failures
remain failed runs.

This improves the current result, not the workflow source. The verifier is
workflow code; the reviewer retains only its read-only payment API. An
`agent-verification` trace annotation records each accepted, rejected, or
unresolved decision. Agreement is still evidence, not proof against a mistake
all three derivations share. The existing recorded cohort below predates this
verification-and-correction path.

Replay a deliberately biased reviewer, followed by a corrected measurement:

```console
ptc run ptc-project.replay.json --host-config ptc-host.verification-replay.json --input inputs/luna.json
```

That returns `B. BE`. With `--input inputs/verification-exhausted.json`, the
reviewer has only one turn: the same biased measurement is rejected and the
result is `Not Applicable`. Both commands still need the downloaded dataset.
The fixture is a constructed regression, not a recording of a model making
and correcting that error. [Verification evidence](evidence/VERIFICATION.md)
records its construction and the separate live probe.

## The flow

```text
analysis  (blind)                         table A ─┐
recheck   (blind)                         table B ─┼─ agree to the cent? ─► "B. BE"
review    (reads A, B and their programs, ─ table C ─┘        no ─► "Not Applicable"
           then measures for itself)        + problems
```

Each stage is an agent loop in its own mission with the same two read-only
functions from `payments.clj`: `fraud-definition` and a paged `read-page` over
the CSV. The two analyzers never see each other. The reviewer sees both tables
and every program that produced them, and must return its own table plus any
problems it found. `workflow.clj` ranks the three tables and publishes the
answer only when all three agree to the cent. The reviewer's problems are
published beside the answer and never used to pick it.

Four things PtcRunner does here that carry over to other workflows:

- **Retained programs.** `agent.core/run-outcome` with `"retain_programs"`
  returns every program a loop admitted, each with a bounded note of what it
  did. That is what the reviewer reads.
- **Missions as sandboxes.** Three loops, one component, and no way for a
  stage to see another's transcript unless the workflow hands it over.
- **A contract per stage.** `phase_return_schemas` says analyzers return a
  table and the reviewer returns a table plus problems. The loop bounces a
  bad shape back to the model before the workflow ever sees it.
- **The decision is code.** `review.clj` compares tables; it is tested
  without a model in `test/ptc_runner/kernel/dabstep_review_comparison_test.exs`.

## What the reviewer sees

The workflow renders one prompt: the task, the input, both tables, and the
REPL session as numbered steps. This is the real prompt from the off-by-one
regression, trimmed to the step that matters:

```text
Review the REPL session below for the given task and input. It records
trial-and-error discovery, so intermediate steps may fail or be exploratory.
Check the programs, then solve the task yourself with run_ptc_lisp. Return
the volumes you measured and any problems that could make the analyzer
result wrong.

TASK
What is the top country (ip_country) for fraud? A. NL, B. BE, C. ES, D. FR
...
REPL SESSION
STEP 1 — turn 1, analysis
EXECUTION
{"observation" "user=> \"Fraud is defined as the ratio of fraudulent volume over total volume.\"" "outcome" "continued"}
SOURCE
(dabstep.payments/fraud-definition)

---

STEP 2 — turn 2, analysis
EXECUTION
{"outcome" "returned"}
SOURCE
(let [stats (loop [cursor nil totals {}]
              (let [page (dabstep.payments/read-page cursor ["ip_country" "eur_amount" "has_fraudulent_dispute"])
                    totals2 (reduce (fn [acc row] ...)
                                    totals
                                    (rest (get page "rows")))]
                ...
```

`(rest (get page "rows"))` drops the first row of every page. The totals are
0.04% low and the answer is still `B. BE`, so nothing but the numbers gives it
away.

## What it wrote back

Luna's recorded review, run `cmd-0cwcp0r52fj5tbfk7192bf3htx`, one turn, all
49 pages, reformatted for width:

```clojure
(let [stats (loop [cursor nil totals {}]
              (let [page (dabstep.payments/read-page cursor ["ip_country" "eur_amount" "has_fraudulent_dispute"])
                    totals2 (reduce (fn [acc row]
                                      (let [country (nth row 0)
                                            amount (or (nth row 1) 0)
                                            fraudulent (nth row 2)
                                            prior (get acc country [0 0])]
                                        (if country
                                          (assoc acc country [(+ (nth prior 0) (if fraudulent amount 0))
                                                              (+ (nth prior 1) amount)])
                                          acc)))
                                    totals
                                    (get page "rows"))]
                (if (get page "next_cursor")
                  (recur (get page "next_cursor") totals2)
                  totals2)))
      countries (mapv (fn [[country volumes]] {"ip_country" country
                                              "fraudulent_volume" (double (nth volumes 0))
                                              "total_volume" (double (nth volumes 1))})
                      stats)]
  (return {"countries" countries
           "problems" ["The analyzer discarded the first data row on every page by applying
                       (rest ...) to rows, even though read-page rows are already data
                       vectors; its aggregates are therefore incomplete."]}))
```

Same API, same shape, one bug fixed. The workflow compares its table with the
analyzers' and reports `measurements_agree: false`. The sentence is a bonus:
in the shared-defect study below, two reviewers measured correctly and wrote
nothing, and the comparison caught them anyway.

Three such sessions are fixed inputs under `inputs/reviewer-*.json`, each with
a recorded Luna review in `reviewer-replay.jsonl`, so the nightly suite replays
them with no key:

```console
ptc run ptc-project.reviewer-replay.json --input inputs/reviewer-wrong-metric.json --envelope out.json
```

| Case | The shared mistake | What gives it away |
|---|---|---|
| `wrong-metric` | tables right, answer ranked by absolute volume: `A. NL` | the reviewer's table ranks BE first |
| `off-by-one` | `rest` on every page | totals differ from the reviewer's |
| `shared-refused` | `is_refused_by_adyen` used as the fraud flag | totals differ from the reviewer's |

## Two moments from live runs

**The heap ceiling.** In every DeepSeek run at least one analyzer first
tried to keep all 138,236 rows. The sandbox stopped it at the 40 MB evaluation
ceiling, rolled the program back, and the loop fed this back:

```text
The program exceeded the mission heap budget and was stopped. The failed
program was rolled back; previously committed definitions remain. ... Retry
with a more efficient program: filter, page, or project before collecting;
use reduce for a compact summary ... The program cannot raise this limit.

TURN BUDGET: 13 turns remain, including the next program.
```

The streaming aggregation shown above is what the same model wrote next. A
run's recording is about 270 KB because the read mapping keeps an identity for
each page instead of its bytes; capturing the same 49 reads in full would take
74 MB. The arithmetic is in
[`evidence/STUDY.md`](evidence/STUDY.md#keeping-the-evidence-small).

**Why the verdict is code.** An earlier version let the reviewer approve or
reject in words. Live, it approved without running a program, then raised five
objections to a correct answer, then scanned every page correctly and vetoed
the right answer by comparing its ratio winner against the largest absolute
volume. A reviewer that can veto is a second single point of failure. A
reviewer that must show its measurement is evidence. Those three run references
are in [`evidence/STUDY.md`](evidence/STUDY.md#cohorts).

## Look inside a run

Every number in this README came out of the run records, through `ptc`:

```console
ptc repl --profile private-run-analysis-v2 --private-unattended \
  --resource traces=.ptc/traces --resource inspection=.ptc/inspection \
  --run RUN_REF --format jsonl \
  -e '(analysis/counters {"run_id" "RUN_REF"})' \
  -e '(analysis/read "RUN_REF" {"collection" "generated_sources" "mission_name" "review"})'
```

For `cmd-0twkysj3vwd4wwwjjgx42p09qs` the counters say
`"evaluations_by_mission": {"analysis": 2, "recheck": 2, "review": 2}`,
`"mission_capability_calls": 149`, and six Luna calls for $0.004234; the
second expression prints the reviewer's two programs verbatim. `AGENTS.md`
lists the collections. `ptc viewer ptc-project.json` shows the same records
per mission in a browser.

## What we measured

| | Runs | Outcome |
|---|---:|---|
| [Live three-stage runs, 2026-09-03](evidence/STUDY.md#cohorts) | 10 | 9 agreed on `B. BE`; 1 DeepSeek run failed after handing `read-page` a cursor it made up |
| [Seeded regressions, replayed nightly](evidence/STUDY.md#replay-fixtures) | 3 | all caught by the comparison; the recorded review names the defect in two, and in the third gets the table right and the words muddled |
| [Shared-defect reviews](https://github.com/andreasronge/ptc_runner/issues/1802) | 30 | 28 of 29 measured the true table; none copied the defective program; shown the programs, the reviewer used one call and 49 reads every time |

Observations of one task on one day, not a benchmark score. Run references,
the earlier single-stage cohort, the reader's guarantees, capture sizes, and
benchmark fidelity are in [`evidence/STUDY.md`](evidence/STUDY.md).

## Continue the experiment

Everything below starts from files in this directory.

- **A defect that flips the letter.** All three seeded defects still rank BE
  first. Seed one that does not (`issuing_country` instead of `ip_country`,
  or a partial scan) by executing it in the `analysis` mission REPL, and
  watch the comparison and the reviewer split on it.
- **One more derivation on disagreement.** The reviewer's own measurement
  error was 1 in 29. Change `workflow.clj` to run a fourth blind derivation
  before publishing `Not Applicable`, and measure how often it rescues a
  correct answer.
- **Review any past run.** The host schema has `ptc_trace_snapshot` and
  `ptc_inspection_snapshot` provider sources, so a second application can be
  given a finished run as data and review it after the fact, with the exact
  observations rather than retained summaries.
- **A cheaper reviewer.** The verdict no longer depends on the reviewer's
  prose, so try DeepSeek in `reviewer_model` and compare measurement
  accuracy and cost against Luna.
- **Take the benchmark name out.** `payments.clj` names DABStep. Rename the
  namespace, permute the options, and run counterfactual data where NL wins
  ([#1637](https://github.com/andreasronge/ptc_runner/issues/1637)).

## Files

- `ptc.json`, `workflow.clj`, `review.clj`, `payments.clj`: the application,
  the three-stage workflow, the shared prompt and comparison, the reader.
- `reviewer.ptc.json`, `reviewer-workflow.clj`, `inputs/reviewer-*.json`:
  the regression application and its three fixed sessions.
- `ptc-project*.json`, `ptc-host*.json`: live and replay projects.
- `record-replay.sh`: writes a replay fixture from a run's model exchanges.
- `evidence/`: cohorts, the representative generated program, and
  [`STUDY.md`](evidence/STUDY.md), which also carries the dataset license.
