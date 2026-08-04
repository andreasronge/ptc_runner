# Evidence: a single-pass incident compiler against the agent loop

**Status:** experiment record and handoff, 2026-08-02/03, branch
`worktree-incident-evidence-compiler`. One model, one corpus; ten reps per cell
for `fast` and `loop`, three for `authored`. Nothing here is a release claim;
see *Limits* before quoting any number.

The branch is rebased onto `origin/main` and has no PR open. The tagged-union
contract fix this branch once carried is no longer outstanding: `main` landed
its own, and this branch's version was dropped as superseded.

Context: [`incident-evidence-compiler.md`](incident-evidence-compiler.md) Phase 3
proposes a four-system comparison and requires bars committed in writing before
the full matrix runs. This is **not** that comparison. It is the dogfooding that
Phase 1 exists to produce — build the application, then discover what the
runtime cannot yet express — and it happens to have produced a result worth
recording before the pilot is designed.

## What was compared

Three ways of running the same application, on the same corpus, same model
(`openrouter:deepseek/deepseek-v3.2`), same result contract and citation check.
`fast` and `loop` were compared first; `authored` was added later.

| arm | shape |
| --- | --- |
| `loop` | `incident.compiler/run` — the shipped `agent.core` loop |
| `fast` | fetch everything in one program, one model call for the whole report, verify, plus one correction turn if citations fail |
| `authored` | as `fast`, except the model **writes** the gathering program: one call to author it, `check-source` to validate it, then the same single report call and verification |

The fast arm is a plain PTC-Lisp workflow, ~100 lines: one `kernel/eval-source`
that searches and fetches every record, one `llm/request` carrying all bodies
and the generated result-contract description, then `resolve-citations` over
every citation before returning. Retrieval is a **program**, not a sequence of
model turns.

## Result

Three incidents × two arms × ten reps = 60 runs, plus a third arm at three
reps added later — 69 runs in total.

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

### The authored arm

Added later, on the same corpus, after `main` landed `check-source` and
parameterized evaluation. Three incidents × three reps = 9 runs.

```
authored  calls median=2  total=18   recall median=0.86  range 0.71-0.86  published 9/9
```

Same median as `fast` (0.86) at one extra call, and **far more consistent**:
0.71–0.86 against `fast`'s 0.00–1.00. Because the earlier three-rep record was
wrong about exactly this — it read a narrow range at small n as stability — the
claim was checked rather than eyeballed. Resampling `fast` under the authored
arm's own design, three runs per incident, 200,000 draws:

| | |
| --- | --- |
| P(a `fast` sample being this tight) | **0.0002** |
| P(a `fast` sample's mean being this high) | 0.24 |

So the consistency is real and the central tendency is not. `authored` does not
compile *better* reports than `fast` on this corpus; it compiles reports whose
quality varies far less, and it never produced the fully-grounded-but-empty
report that `fast` did.

**It did not write the program that was predicted.** The expectation was that it
would re-derive "search once, fetch everything", pay one extra call, and tie.
Instead it enumerates `list-sources` and searches per source, and it returns
*fewer* records than `fast` does — median 12, range 9–13, against `fast`'s
flat 13. Fetching less and scoring the same median, with a fraction of the
spread, is not what a re-derivation looks like. Why a source-balanced traversal
would be steadier than a flat fetch is a hypothesis this corpus cannot settle.

**Authoring never failed.** 9/9 programs were runnable and `check-source`
rejected none, so the repair turn never fired — the same result as the fast
arm's correction turn, and it costs nothing when unused. That the repair path is
untested here is a gap, not a reassurance.

## The stress corpus

`schema-migration-stall`, 332 records across 8 sources, generated by
`tools/gen_stress_corpus.exs` and built so that no arm can fetch it whole:
`search` caps at 50 and defaults a missing limit to 20, and the incident opens
with hours of routine traffic, so a truncated search returns only the
pre-incident tail. It is solvable two ways — per-source search at limit 50, or
a union of targeted queries — and reaches 0 of 7 needles by taking the earliest
records.

Three arms, three reps:

| arm | published | calls | required-fact recall |
| --- | --- | --- | --- |
| `fast` | 1/3 | 1, 1, 2 | **0.00** |
| `authored` | 0/3 | 2, 2, 3 | — |
| `loop` | 2/3 | 24, 29, 24 | **0.00, 0.00** |

**Every arm scored zero.** Not "worse" — zero. Three published reports between
them, all fully grounded, none containing a single required fact.

**But zero here does not mean what it meant on the small corpus, and reading
the reports is what shows it.** Every published report correctly characterised
the evidence it was given and named what it was missing:

> The provided evidence shows normal operations for orders-service and its
> database from 20:01 to 21:25, **with no indication of a schema migration
> stall** on the public.orders table.

Its open questions ask for migration entries touching `public.orders`, lock
samples showing waiters on it, and alerts indicating degradation — which are
precisely the records it never received. The model was handed 50 shift-handover
notes and objective checks and said so.

So `required_fact_recall` is measuring **retrieval** here, not reasoning, and
the metric cannot tell a well-hedged 0.00 from a fabricated one. On the
13-record corpus a 0.00 meant the model had the evidence and missed it; on this
one it means the evidence never arrived. Reporting both as "scored zero" without
that distinction was wrong, and only reading the reports caught it.

The prediction registered before the run holds exactly. The authored programs
fetched **160 records every time** — eight sources times the twenty-record
default — and 160 is not a number anyone chose; it is what ignoring `truncated`
costs on this corpus. The fast arm's single 50-record search returned the
earliest 50 of 332, all pre-incident. The loop spent 24–29 calls and cited five
records. None of the three ever learned it was working from a subset, because
none of them reads `truncated`.

**The comparison is uninformative here, and that is the finding.** These arms
differ in how they orchestrate a model; they share one retrieval assumption,
and the corpus breaks that assumption first. Whatever separates a single pass
from a loop is invisible behind a common failure that has nothing to do with
either. The earlier 69 runs measured three orchestration shapes on a corpus
where retrieval could not fail; this one shows what the shapes are worth when
it can.

**A second failure sits underneath.** `result_contract_failed` accounts for
five of the six non-publications, and at least one is not a reasoning failure:
one rejected report carried **20 citations on a single observed fact** against
a schema that allows 8. Given far more evidence than the contract was drawn
for, the model piles citations onto individual claims and breaches a bound the
13-record incidents never approached. That is a defect in the application's
contract, not in any arm.

### What the model saw, and what it wrote

Read back through the inspection profile before touching anything, because the
obvious fix assumes the model lacked information.

**It did not.** The authoring prompt is 10,264 bytes of mission model context
and it names `limit`, `truncated` *and* `matched` — in every authored run. The
model was shown that `search` takes a `limit` and answers how many records
`matched` and whether the page was `truncated`, and used none of the three. The
fast arm's report prompt is 18,813 bytes; nothing here is a context-size
failure either.

The three programs it wrote are idiomatically varied — one `reduce`, one
`->>` with `#()` and `mapcat`, one using keyword access throughout — and
structurally identical: `list-sources`, then a per-source `search` with `nil`
in the limit position, then `get-record` per summary. All three ran, all three
passed `check-source` with no repair, and all three returned exactly 160
records.

So this is not a broken program and not a missing fact. Each program is correct
about what it does; none of them entertains the possibility that `search`
returned less than everything. Reading `records` without reading `matched` is
the whole failure, and the field was on screen.

That changes what the fix is. Passing `limit 50` repairs this corpus and
nothing else — the next corpus is 600 records and 50 is wrong again. What the
evidence argues for is either an authoring prompt that says something about
completeness rather than trusting the signature to imply it, or a tool that
makes truncation impossible to ignore: a cursor that must be drained, or a
refusal to answer a query whose result it had to cut. Documenting the field
demonstrably is not enough.

One thing `check-source` cannot do, worth knowing before leaning on it: it
resolves names, not shapes. Every one of these programs is name-correct and
semantically blind, and it passed all three.

### Telling the model its coverage changed nothing, because it already knew

The report prompt was made truthful — it had been asserting "Every record below
is the complete evidence" unconditionally, which was false the moment retrieval
fell short. With an accurate "these are 50 of the 332 records this incident
holds" the fast arm published 3/3 at 0.00, the same as before.

The reason is not that the model ignored the sentence. Reading the reports from
both conditions side by side, they are equally hedged: without the sentence it
already wrote "no indication of a schema migration stall", because fifty
consecutive shift-handover notes are self-evidently not an incident. The
coverage line told it something it had inferred from the data.

That does not make the line useless — a corpus whose first fifty records looked
alarming would not be self-evident — but it does mean this experiment failed to
test what it was built to test, and the earlier reading of it ("information is
not the binding constraint") was not supported by it.

One genuine finding survives. The prompt's only rule about missing evidence is
*"where the evidence does not answer a question that matters, record an open
question"* — which prescribes handling it **inside** a report. The
`insufficient_evidence` branch appears solely as an unexplained line of schema
in the contract dump. A model told it is missing evidence, and told what to do
when evidence is missing, does the thing it was told. If abstention is wanted,
the rules have to say so.

Not fixed here, deliberately. The obvious repairs — pass `limit 50`, read
`truncated`, raise the citation cap — are each one line, and applying them
before the failure is recorded would turn a measured result into an anecdote
about a corpus that was quietly adjusted until the arms passed.

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

## What the private logs show

Analyzed with the runtime's own `inspection-analysis-v2` profile rather than by
reading JSONL from outside, so the numbers come from the same correlated
private records an operator would query.

**Every run fetches each record twice, and it is correct.** Across all 9
authored runs, `evidence.get` calls run 45–50% duplicate — 26 calls for 13
records. The first hypothesis, that the model's per-source traversal was
silently dropping records to paging, is **wrong**: `matched` equals `returned`
in every search and no `truncated` flag is ever set. Attributing the calls by
`evaluation_id` gives the real answer:

```
mission-evaluation-10  gets 13  distinct 13   <- the gathering program
mission-evaluation-36  gets 13  distinct 13   <- the citation verification
```

One gather pass, one verify pass, no duplicate inside either.
`resolve-citations` re-reads each cited record from the evidence source instead
of trusting the copy the program already holds, which is what makes it a check
rather than a restatement — verifying against the same bytes the model was
shown would be circular.

The control matters here: **the fast arm shows the identical ratio in all 20 of
its runs**, so this is a property of the application's verification step, not of
model-authored retrieval.

**What the model actually wrote, and what it said.** Reading the generated
sources and the model's own replies back out of the same records:

| | |
| --- | --- |
| distinct programs across 9 runs | **8** |
| replies carrying prose | **0** |
| report replies wrapped in a ```` ```json ```` fence, against an explicit instruction not to | **7 of 9** |
| programs reading `data/params` | 0 |
| programs hardcoding the incident id as a literal | 9 |
| programs that read `truncated` | 0 |

Eight distinct programs in nine runs, at `temperature 0` with a fixed seed:
temperature zero is not determinism. No reply ever carried narration — the
authoring prompt asked for program text and nothing else, and got exactly that
nine times out of nine. The *report* call is the one it disobeys, fencing its
JSON in seven of nine replies despite being told not to; `parse-report` strips
fences, so this costs nothing and would have been invisible without reading the
exchanges.

Two things follow for work already planned. Every program bakes its incident id
in as a literal, so **as authored these are single-use artifacts** — promoting
one into a reusable component (#1167) needs a parameterization step, and the
authoring prompt never mentions `data/params`, so that is a prompt gap rather
than a model failure. And **no program reads `truncated`**, which cost nothing
here because nothing ever truncated, but is precisely the silent-evidence-loss
failure the hard case would trigger.

**The consequence is a scaling ceiling nobody had costed.** Mission capability
calls follow `2R + S + 1` exactly — twice the record count, one search per
source, one `list-sources` — while `llm_calls`, the headline metric of this
whole comparison, hides it completely. Measured against every incident in the
corpus, and `checkout-5xx` matches at 2×13+6+1 = 33.

The manifests capped `mission_capability_calls` at 512, reached near 250
records. **Raised to 4096** (host ceiling 8192), sized from the rule above, in
preference to weakening verification: re-reading each cited record is what makes
the check a check, and sampling would trade an integrity property for headroom.

**A second, harder ceiling sits underneath it.** The evidence server caps
`search` at `@max_limit 50` and defaults a missing limit to 20, and it returns
no cursor. The fast arm asks for 50 and ignores `truncated`; the authored
programs pass `nil` and take 20 per source. So no arm can see more than 50
records from one call, and beyond that the corpus is reachable only by issuing
*more* searches — per source, or by query. Raising the call limit does not
touch this.

That is left as it is. A capped, filterable search is what an evidence API
actually looks like, and changing the system under test to make the experiment
work would answer a question nobody asked. It does mean the hard case is not
"can an arm afford hundreds of records" but **"can an arm reach evidence it
cannot fetch wholesale"** — which is the assumption the fast arm has never had
stressed, and the one a generated program is supposed to be better at.

Registered before the run, so it can be wrong: on a corpus of several hundred
records the fast arm should degrade badly, because one 50-record search cannot
see the evidence; the authored arm should do better only if it searches per
source *and* passes a limit, which none of the nine programs it has written so
far does; and no arm reads `truncated`, so all of them will lose evidence
silently rather than fail.

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
- [#1172](https://github.com/andreasronge/ptc_runner/issues/1172) — hit while
  analyzing this experiment's own private records. A private session answers
  `unbound_var` with only `private evaluation failed`, while the identical
  fault outside one says `Undefined variables: defn-, g, x`; the redacted names
  are the analyst's own script text, not captured data. Alongside it, `defn-`
  in dynamic source fails as an undefined *variable* rather than saying it is
  component-only, and a profile resource directory whose artifacts sit one
  level down answers `{"items" []}` — a capture that matched nothing reads
  exactly like one holding no runs.

## Runtime capabilities confirmed

Probed directly against the mission environment, no model calls involved,
because the answers decide whether a model-authored retrieval arm is buildable
at all. Every item here was re-verified after this branch rebased onto `main`
at [PR #1169](https://github.com/andreasronge/ptc_runner/pull/1169), which
changed the generated-program boundary; all of them still hold.

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

Two things `main` added while this branch was away change how generated code
should be written, and both were confirmed by the same probe:

- **`kernel/check-source` validates without executing.** It answers
  `{:outcome :valid, :source_hash …}` or `{:outcome :invalid, :diagnostic …}`,
  and it resolves names against the live mission environment — an undefined
  function is caught as `:unbound_var` before anything runs, where
  `(program …)` still surfaces the same fault only at evaluation. A repair loop
  no longer has to spend an evaluation to learn its program does not compile.
- **`kernel/eval-source-with` passes data as data.** Parameters arrive at
  `data/params` inside the evaluated program, so a value never has to be
  rendered into source text. A hostile string passed as a parameter comes back
  as a string, intact and never parsed — the injection shape that string
  concatenation creates is structurally absent rather than escaped around.

The components under `experiments/` still build their programs by
concatenation and predate this surface. That is now the wrong way to write
them; see *Next step*.

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
| `experiments/components/authored-pass.clj` | the `authored` arm |
| `experiments/components/fit.clj` | model-judged applicability via `export-meta` + `describe` |
| `experiments/components/documented-target.clj` | the documented export `fit` judges |
| `experiments/components/fit-stress.clj` | synthetic cases proving `fit` discriminates |
| `exp-single-pass.json`, `exp-loop.json`, `exp-authored.json` | the arms' manifests |
| `experiments/results/paired-2026-08-03.jsonl` | the first 18 rows (reps 1-3) |
| `experiments/results/paired-2026-08-03-reps-4-10.jsonl` | the further 42 rows (reps 4-10) |
| `experiments/results/authored-2026-08-03.jsonl` | the 9 authored-arm rows |
| `experiments/results/stress-2026-08-03.jsonl` | the 9 stress-corpus rows |
| `tools/gen_stress_corpus.exs` | regenerates `schema-migration-stall` |

Add repeats:

```bash
export OPENROUTER_API_KEY=...            # or source .env, which lives in the
                                         # main clone, not in this worktree
./incident_compiler/experiments/run.sh checkout-5xx fast 11
./incident_compiler/experiments/run.sh checkout-5xx loop 11
./incident_compiler/experiments/run.sh checkout-5xx authored 4
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
- The `authored` arm has now run, and its result is bounded by the same
  ceiling: it matches `fast`'s median at one extra call, because a corpus where
  fetching everything already fits leaves an authored program nothing to be
  cleverer about. Its one real finding — a far tighter spread — is the kind of
  claim that needs a corpus where the arms can actually diverge.

One incident with hundreds of records, or heavy cross-referencing, makes both
testable at once. Phase 2's SREGym capture is the plan's route to it and remains
its one open item.

Both arms now pass values as parameters rather than concatenating them into
source, and the authored arm checks its program before running it. Its nine
runs are recorded above. What remains:

1. **More reps on the authored arm.** Nine runs establish the variance result
   at p=0.0002 but leave the mean unsettled, and the repair path untested
   because nothing it wrote ever failed to compile.
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
