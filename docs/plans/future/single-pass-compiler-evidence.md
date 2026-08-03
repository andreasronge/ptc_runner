# Evidence: a single-pass incident compiler against the agent loop

**Status:** experiment record and handoff, 2026-08-02/03, branch
`worktree-incident-evidence-compiler`. One model, one corpus, three reps per
cell. Nothing here is a release claim; see *Limits* before quoting any number.

The branch is well ahead of `origin/main` and has no PR open. Unrelated to this
experiment but outstanding on it: `637958c1`, a fix for a live tagged-union
contract bug on `main`, is written, tested, and still unlanded.

Context: [`incident-evidence-compiler.md`](incident-evidence-compiler.md) Phase 3
proposes a four-system comparison and requires bars committed in writing before
the full matrix runs. This is **not** that comparison. It is the dogfooding that
Phase 1 exists to produce — build the application, then discover what the
runtime cannot yet express — and it happens to have produced a result worth
recording before the pilot is designed.

## What was compared

Two ways of running the same application, on the same corpus, same model
(`openrouter:deepseek/deepseek-v3.2`), same result contract and citation check.

| arm | shape |
| --- | --- |
| `loop` | `incident.compiler/run` — the shipped `agent.core` loop |
| `fast` | fetch everything in one program, one model call for the whole report, verify, plus one correction turn if citations fail |

The fast arm is a plain PTC-Lisp workflow, ~100 lines: one `kernel/eval-source`
that searches and fetches every record, one `llm/request` carrying all bodies
and the generated result-contract description, then `resolve-citations` over
every citation before returning. Retrieval is a **program**, not a sequence of
model turns.

## Result

Three incidents × two arms × three reps = 18 runs.

| incident | arm | calls | required-fact recall | failed |
| --- | --- | --- | --- | --- |
| checkout-5xx | fast | 1, 1, 1 | 0.29 / 0.71 / 0.71 | 0/3 |
| checkout-5xx | loop | 18, 15, 13 | 0.86 / 1.00 / 0.57 | 0/3 |
| dual-cause-payments | fast | 1, 1, 1 | 0.86 / 0.86 / 0.86 | 0/3 |
| dual-cause-payments | loop | 9, 17, 9 | 0.57 / *fail* / 0.29 | 1/3 |
| batch-silent-failure | fast | 1, 1, 1 | 0.60 / 0.80 / 0.80 | 0/3 |
| batch-silent-failure | loop | 10, 8, 11 | 0.60 / 0.60 / 1.00 | 0/3 |

```
fast  calls median= 1  total=  9   recall median=0.80  range 0.29-0.86  published 9/9
loop  calls median=11  total=110   recall median=0.60  range 0.29-1.00  published 8/9
```

Every published report in both arms was fully grounded: zero unresolved and
zero mismatched citations, verified against the evidence source.

## What was unexpected

**The correction turn never fired.** `corrected: 0` in all nine fast runs. It
was added because the loop's one structural advantage is a correction turn, and
it turned out to be unnecessary on this corpus. It costs nothing when unused.

**The loop is the arm that fabricated.** `dual-cause-payments` rep 2 failed
closed with `unresolved-citations` after 17 calls. More turns meant more
opportunities to invent a citation, and the fail-closed check caught it. The
fast arm never fabricated in nine runs.

That inverts the assumption the speculate-then-deoptimise design rested on —
that the loop is the safe fallback and the single pass is the risky shortcut.
On this evidence the single pass is *tighter*: never above 0.86, never below
0.29, and identical three times on one incident. The loop owns both the two
perfect scores and the only failure.

## What was tried and did not pay off

**Triage** (`fit/handles?`): one cheap model call reading the target export's
own documentation through `export-meta` plus a `describe` projection of the
data, answering whether a single pass suits this task. The mechanism works —
against synthetic inputs it correctly rejects a 4,200-record corpus with
`scale`/`iteration` and a heavily cross-referenced one with `iteration`, citing
the disqualifiers the docstring names. Against the real corpus it answers yes
12/12, which appears **correct**: every incident is 11-13 records, ~2.3 KB, six
sources. There is no hard case in the fixtures for it to reject, so triage adds
a call and no information here.

Three rounds of apparent triage failure all turned out to be defects in what it
was fed, not in the judge:

- the target's docstring described mechanics and never claimed the report
  separates facts from hypotheses, so the model would not assert it did;
- `json/generate-string` returns `nil` for an atom-keyed map, so
  `(json/generate-string (describe records))` sent an **empty** data shape in
  every call — the model's repeated "no input data shape is provided" was a
  true statement about its input, read for several rounds as confabulation;
- the sample was labelled "the data it would receive" when the signature takes
  an incident id and fetches internally.

Filed as [#1165](https://github.com/andreasronge/ptc_runner/issues/1165).

## Runtime friction found

- [#1165](https://github.com/andreasronge/ptc_runner/issues/1165) —
  `json/generate-string` returns `nil` silently for atom-keyed maps.
- [#1166](https://github.com/andreasronge/ptc_runner/issues/1166) — rejections
  that discard what the runtime knows: `split` on a string separator, `parse`
  unusable as a name because it is in `java_member_atoms`, `--inspect` path
  convention unstated, `--load` silently dropping a `return`.
- Fixed on this branch: declared annotation counter names containing a hyphen
  could never match, because the tool boundary rewrites hyphens to underscores
  while the declaration grammar requires kebab-case.

## Limits

- **n=3 per cell.** The medians differ (0.80 vs 0.60) but the distributions
  overlap. This does not establish that the fast arm is better, only that it is
  not obviously worse at a twelfth of the calls.
- **One model.** `deepseek-v3.2`. An earlier single-incident probe with
  `claude-haiku-4.5` moved recall but not turn count.
- **One corpus, no hard case.** Every incident is small and structurally
  similar. The fast arm's assumptions are never stressed, which is exactly why
  triage cannot be validated here.
- **Recall is mechanical.** Whether a cited record semantically supports its
  claim is not decidable this way; the oracle's `rubric` exists for a blind
  human pass that has not been run.

## How to continue

Everything needed is committed under `incident_compiler/`:

| Path | What |
| --- | --- |
| `experiments/run.sh` | one cell per invocation; appends one JSONL row |
| `experiments/collect.exs` | joins trace annotations, usage, and the scorer into that row |
| `experiments/components/single-pass.clj` | the `fast` arm |
| `experiments/components/fit.clj` | model-judged applicability via `export-meta` + `describe` |
| `experiments/components/documented-target.clj` | the documented export `fit` judges |
| `experiments/components/fit-stress.clj` | synthetic cases proving `fit` discriminates |
| `exp-single-pass.json`, `exp-loop.json` | the two arms' manifests |
| `experiments/results/paired-2026-08-03.jsonl` | the 18 rows behind every number above |

Add repeats:

```bash
export OPENROUTER_API_KEY=...            # or source .env
./incident_compiler/experiments/run.sh checkout-5xx fast 4
./incident_compiler/experiments/run.sh checkout-5xx loop 4
```

Rows land in `incident_compiler/experiments/runs/results.jsonl` (override with
`PTC_EXP_DIR`); traces and inspection artifacts land beside them. Nothing is
overwritten — a new rep number is a new row. To extend the recorded set, append
those rows to `experiments/results/paired-2026-08-03.jsonl` or add a dated file
next to it.

`run.sh` clears its own per-tag artifacts first, because `ptc.run` refuses to
overwrite a result. That refusal caught a real harness bug: a failed run was
being scored against the previous run's report, which would have quietly
poisoned the whole results file.

**Layout constraint worth knowing.** The manifest loader rejects path
traversal, so a manifest cannot reference a component outside its own
directory. That is why the two manifests sit in `incident_compiler/` and point
*down* into `experiments/components/`, rather than living beside the components
they select. Moving them produces `:invalid_component`.

## Next step

**More reps, not more design.** Reps 4-10 on the same three cells gives ~10 per
cell and lets the medians be compared rather than eyeballed. Roughly 40 minutes
of runs, no new code.

After that, in order:

1. **A hard case.** The corpus cannot exercise the fast arm's limits or
   validate triage. One incident with hundreds of records, or heavy
   cross-references, would make both testable. Phase 2's SREGym capture is the
   plan's route to this and remains its one open item.
2. **The Phase 3 pilot proper**, with bars committed first. This record is
   evidence for designing it, not a substitute.
3. **Decide whether the fast arm becomes a second shipped entry point** beside
   the loop, so the corpus can be run both ways from the manifest rather than
   from scratch files.

The components under `experiments/` are experiment-grade: they work and are
reproducible, but they have no tests and are not part of the shipped
application. Item 3 is the decision about which, if any, graduate — at which
point they need the same treatment as anything else in `incident_compiler/`.

One-off probes used while diagnosing (prompt dumps, shape probes, a
speculate-then-deoptimise hybrid) were deliberately not kept. The hybrid is
recoverable from this branch's history if the triage question is reopened.
