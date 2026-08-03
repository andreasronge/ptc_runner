# Evidence: a single-pass incident compiler against the agent loop

**Status:** experiment record and handoff, 2026-08-02/03, branch
`worktree-incident-evidence-compiler`. One model, one corpus, ten reps per
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

Three incidents × two arms × ten reps = 60 runs.

| incident | arm | calls (median, range) | recall (median, range) | published |
| --- | --- | --- | --- | --- |
| checkout-5xx | fast | 1 (1-1) | 0.86 (0.29-1.00) | 10/10 |
| checkout-5xx | loop | 16 (10-20) | 0.57 (0.14-1.00) | 10/10 |
| dual-cause-payments | fast | 1 (1-1) | 0.86 (0.00-1.00) | 10/10 |
| dual-cause-payments | loop | 15.5 (8-21) | 0.57 (0.14-1.00) | 9/10 |
| batch-silent-failure | fast | 1 (1-1) | 0.80 (0.40-1.00) | 10/10 |
| batch-silent-failure | loop | 11 (7-17) | 0.60 (0.40-1.00) | 10/10 |

```
fast  calls median= 1  total= 30   recall median=0.86  range 0.00-1.00  published 30/30
loop  calls median=14  total=410   recall median=0.60  range 0.14-1.00  published 29/30
```

The recall difference survives a test that respects incident as a blocking
factor: shuffling arm labels within each incident (200,000 draws) puts the
observed block-averaged difference of +0.170 at p=0.017. No single incident
reaches significance alone (p=0.10, 0.07, 0.66) — the result rests on all three
blocks pointing the same way, not on any one of them. Publication rate does not
differ (30/30 against 29/30, Fisher p=1.0).

Every published report in both arms was fully grounded: zero unresolved and
zero mismatched citations, verified against the evidence source. As one fast
run shows below, that is a weaker property than it sounds.

## What was unexpected

**The correction turn never fired.** `corrected: 0` in all thirty fast runs. It
was added because the loop's one structural advantage is a correction turn, and
it turned out to be unnecessary on this corpus. It costs nothing when unused.

**A fully grounded report can still be worthless.**
`fast-dual-cause-payments-4` published twenty-one citations, ten of them
checked, zero unresolved and zero mismatched — and scored 0.00 required-fact
recall. Every claim it made was traceable to a real record with a matching
digest; it simply made none of the claims that mattered. The citation check
verifies grounding, not relevance, and nothing at three reps had exercised the
gap. This is the most useful thing the extra reps bought.

**At three reps the single pass looked tighter. It is not.** The earlier record
said it never scored above 0.86 or below 0.29 and read that stability as
evidence the single pass was the safer shape. At ten reps both arms span nearly
the whole range — fast 0.00-1.00, loop 0.14-1.00. The medians separate; the
distributions overlap heavily. What survives is that the fast arm's median is
higher at a fourteenth of the calls, not that it is steadier.

**The fabrication reading did not survive either.** The loop still owns the only
failure — `dual-cause-payments` rep 2, failed closed with
`unresolved-citations` after 17 calls — but one failure in thirty against zero
in thirty is no evidence at all (Fisher p=1.0). That more turns mean more
chances to invent a citation remains a plausible hypothesis with nothing behind
it. Testing it needs a corpus where either arm fails often enough to count.

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

## Runtime capabilities confirmed

Probed directly against the mission environment, no model calls involved,
because the answers decide whether a model-authored retrieval arm is buildable
at all:

- Source handed to `kernel/eval-source` may contain `def` and `defn`, and what
  it defines **persists into later `eval-source` calls for the life of the
  run**. A function defined in one evaluation is callable from the next.
- A dynamically defined function may call mission capabilities — one defined in
  a probe called `incident.evidence/search` and returned its thirteen records.
- It may **not** shadow a protected namespace's public exports. Both `defn` and
  `def` against `incident.evidence/resolve-citations` are refused with
  `invalid_form: … it is a public export of the protected namespace …`, and the
  real function still answers afterwards. Model-authored code cannot rewrite
  the citation check that judges it.
- The generator and the generated code are necessarily on opposite sides.
  `llm`, `kernel-eval` and `kernel-mission-inventory` are workflow-side only
  (`runner.ex` `workflow_tools`, reserved in `environment.ex`), while
  `mission_tools` (`evaluation.ex`) grants only the mission environment's own
  capability callbacks. Generated code therefore cannot call the model or
  recursively evaluate, and is bounded by `mission_capability_calls`.

What this does *not* provide is a prelude in the bundle sense. A runtime `defn`
is not in the `FrozenBundle`: not covered by the component source hash, not
versioned, dead at end of run, and absent from `mission_inventory` — which is
built once at run construction, so **the model never sees its own library in
its tool context**, and with no declared `:signature` there is no `export-meta`
for `fit/handles?` to read. A generated library that should outlive its run has
to be promoted into a real component with a docstring and signature.

## Limits

- **n=10 per cell**, 60 runs. The recall difference is significant under a
  blocked permutation test (p=0.017) and the direction is consistent across all
  three incidents. The distributions still overlap heavily, the effect leans on
  three same-direction blocks rather than any single one, and one model on one
  corpus cannot generalise regardless of p.
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
| `experiments/components/authored-pass.clj` | the `authored` arm — **built, compile-checked, never run live** |
| `experiments/components/fit.clj` | model-judged applicability via `export-meta` + `describe` |
| `experiments/components/documented-target.clj` | the documented export `fit` judges |
| `experiments/components/fit-stress.clj` | synthetic cases proving `fit` discriminates |
| `exp-single-pass.json`, `exp-loop.json`, `exp-authored.json` | the arms' manifests |
| `experiments/results/paired-2026-08-03.jsonl` | the first 18 rows (reps 1-3) |
| `experiments/results/paired-2026-08-03-reps-4-10.jsonl` | the further 42 rows (reps 4-10) |

Add repeats:

```bash
export OPENROUTER_API_KEY=...            # or source .env, which lives in the
                                         # main clone, not in this worktree
./incident_compiler/experiments/run.sh checkout-5xx fast 11
./incident_compiler/experiments/run.sh checkout-5xx loop 11
```

The two arms use different manifests, so a `fast` and a `loop` stream can run
concurrently; two runs of the *same* arm cannot, because `run.sh` rewrites that
manifest's `incident_id` in place. Give each stream its own `PTC_EXP_DIR` so the
two appends to `results.jsonl` cannot interleave. A loop run is roughly 150s
against the fast arm's 70s, so a full sweep is paced by the loop arm.

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

**A hard case. Everything else is now waiting on it.** Reps 4-10 are done and
the medians are settled; running more of the same corpus buys nothing. Two
separate mechanisms are blocked on the same missing input:

- `fit/handles?` answers yes 12/12 here because there is no task it should
  reject, so triage cannot be validated.
- The `authored` arm cannot beat the `fast` arm on a corpus where fetching
  every record already fits in one context. It can only pay an extra authoring
  call to re-derive the same program.

One incident with hundreds of records, or heavy cross-referencing, makes both
testable at once. Phase 2's SREGym capture is the plan's route to it and remains
its one open item.

Two things can be done before that corpus exists:

1. **Run the `authored` arm on the current three incidents** — nine runs, about
   twenty minutes. Not to win: to check the authoring call produces a runnable
   program at all. The `authoring` annotation counts `program-ran` /
   `eval-failed` / `records` so authoring quality stays separable from report
   quality. Predicted outcome is a tie at one extra call; a tie is the useful
   null, and anything worse is a prompt defect worth finding now rather than
   confounded with a new corpus.
2. **Exercise the persistence result.** `eval-source` definitions survive
   across evaluations within a run (see *Runtime capabilities confirmed*), so
   the richer shape is authoring a helper library once and running several cheap
   programs against it — filter, aggregate, join — rather than one monolithic
   fetch. That shape does nothing on 11-13 records and is the whole point on
   hundreds.

After those, unchanged from before: **the Phase 3 pilot proper**, with bars
committed first, and then the decision about whether `fast` (and possibly
`authored`) becomes a second shipped entry point beside the loop.

This record is evidence for designing that pilot, not a substitute for it.

The components under `experiments/` are experiment-grade: they work and are
reproducible, but they have no tests and are not part of the shipped
application. The entry-point decision is about which, if any, graduate — at
which point they need the same treatment as anything else in
`incident_compiler/`.

One-off probes used while diagnosing (prompt dumps, shape probes, a
speculate-then-deoptimise hybrid, the `eval-source` capability probes behind
*Runtime capabilities confirmed*) were deliberately not kept. The hybrid is
recoverable from this branch's history if the triage question is reopened.
