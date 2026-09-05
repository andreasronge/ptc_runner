# Coached navigation improvement experiment

This experiment asks whether one agent can inspect another agent's failed
navigation run, propose a generic instruction change, and improve its behavior
on incidents the coach never saw. It is prompt improvement of an agent system,
not model training or evidence of autonomous runtime repair.

## Result: do not adopt this candidate

The single generated instruction change did not improve the fixed evaluation.
Both arms produced four supported diagnoses, three unsupported diagnoses on the
under-specified case, and two failed investigations. Each published seven
contract-valid reports, but only four met the diagnosis oracle.

| New incident | Original instructions | Coach addendum |
| --- | --- | --- |
| Half-open page boundary: identify `page.stop` | 2/3 | 2/3 |
| Reversed workflow result: identify `main` | 2/3 | 2/3 |
| Unspecified casing policy: abstain | 0/3 | 0/3 |
| Total expected verdicts | 4/9 | 4/9 |

All six text-case reports treated the caller's one expected output as proof
that the component's general casing contract required title case. The source
only says to apply canonical casing; it does not define that policy. A
mismatch is established, but whether to change the casing function, its caller,
or the caller's expectation is not uniquely established. The expected
abstention was fixed before any model evaluation and was not adjusted to fit
these reports.

| Measurement across all nine runs | Original | Candidate |
| --- | --- | --- |
| Median model calls | 20 | 20 |
| Total model calls | 163 | 160 |
| Median run time | 210 seconds | 217 seconds |
| Reported total model cost | $0.035298 | $0.037643 |
| Feedback messages with preview truncation | 32 | 29 |
| Generated programs containing `println` | 27 | 25 |

The candidate's slightly lower total call count includes a six-call abort on
an unavailable relationship; it is not evidence of more efficient successful
navigation. Its four supported diagnoses all used 20 calls, compared with
15, 18, 20, and 20 for the original. Original failures were a turn limit and
a final result-contract rejection. Candidate failures were a turn limit and
the unavailable-link abort. All queried turn pages were complete.

The coach plus all 18 evaluation runs reported $0.153472 in model cost. Times
and costs are descriptive observations under concurrent provider execution,
not guarantees. Three samples per constructed incident are too few for a
general reliability claim. These scores also cannot be compared directly with
the earlier Gemini 9/9 result because this experiment uses different incidents.

No runtime prompt or shipped prelude was changed. The host-side decision is to
retain the control and reject this candidate for adoption. The demonstrated
loop is evidence-based proposal and evaluation, including rejecting an
unhelpful update; it has not yet demonstrated a performance improvement.

## Fixed protocol

- Training evidence: only DeepSeek navigation run
  `cmd-3c1q7epwzdvf0y7m3nf98xfhm5`, a turn-limit failure from the original
  workflow-control experiment. Its exact trace and inspection pair are copied
  into an isolated snapshot. No evaluation incident is installed in that host.
- Coach: `openrouter:google/gemini-3.8-flash`, one run, at most 16 calls and
  16,000-character observations. It must read the failed investigation's
  turns, cite observed mistakes, and propose one domain-blind addendum of at
  most 1,800 characters. It may not change the model, tools, budgets, result
  contract, or existing task. No alternative candidates or whole-run evaluation retries.
- Freeze the returned addendum through `ptc repl` into a new input artifact.
  Do not edit the model's wording after seeing evaluation results.
- Evaluate the original and appended tasks with
  `openrouter:deepseek/deepseek-v4-flash`, 20 calls, 2,048-character observations,
  no consolidation reminder, 4,096 output tokens, 1,024 retained events,
  temperature zero, and provider cache disabled. Both arms use the same
  captured incident bytes and the same navigation API, with no helper prelude.
- Three samples per arm per incident: 18 runs. Six runs start in each sample
  wave, with control/candidate launch order reversed in the second wave.
  Keep all failures. Report expected verdicts, explanation quality, calls,
  elapsed time, reported cost, and evidence-presentation friction.

The three new deterministic incidents are a half-open page range boundary
error, a deadline-ordering workflow that reverses a correctly ranked result,
and ambiguous text canonicalization with no casing policy. The diagnosis
oracle is outside model authority. Correcting the boundary and workflow
sources makes their checks pass. In the ambiguous case, changing the caller's
expectation to match the existing output also passes; this confirms execution,
not that the original expectation was wrong. No single fix is established by
that case's contract.

These remain small constructed incidents, structurally related to the first
experiment. Successful transfer would justify broader testing, not a general
claim of self-improvement across software projects.

## Coach outcome and admission

Coach run `cmd-20223qxzrz4br2ynnjhyjrg4vr` completed in 91 seconds,
using 16 calls and reporting $0.080531. Its addendum contains 1,131 characters. It identified bulk printing, repeated
manual record inspection, loss of `*1` history after a nil result, and an
exploratory final turn instead of completion. Its addendum asks for named
bindings, small projections, direct typed-link traversal, and final-turn
completion. The wording was admitted unchanged as domain-blind; it is a
candidate, not adopted runtime guidance.

The coach used an in-loop protocol retry within its fixed call budget. It also
encountered navigation friction and attempted one
read of the underlying application's run ID. That ID was outside its installed
single-run snapshot. It could inspect the old investigator's observations but
could not open the underlying capture or any new incident. This is a useful
check that separation was enforced by capability authority, not just a prompt.

One phrase in the candidate describes `*1` as the previous expression result.
The precise runtime contract is the last value of the previous successful
ordinary program; failed evaluations preserve history. The candidate was not
silently corrected before testing. Any adoption would need this wording fixed
and independently re-evaluated.

## Reproduction

The scripts are a dated maintainer lab rooted at the checkout and use
`tmp/nav-self-improvement`. They require the original frozen training capture
under `tmp/repair-showcase/debug-final-workflow-control/.ptc` and the current
example files. Start with a new output directory; do not overwrite an earlier
experiment. The coach preparation script copies bytes, not parsed log data.
Keep the environment file outside the experiment directory.

```sh
python3 scripts/labs/debug-repair-showcase/self-improvement/prepare-coach.py
ptc run tmp/nav-self-improvement/coach.ptc-project.json \
  --env-file "$ENV_FILE" --progress \
  --private-output tmp/nav-self-improvement/coach/report.private.json
python3 scripts/labs/debug-repair-showcase/self-improvement/prepare-holdouts.py
```

Run `python3 scripts/labs/debug-repair-showcase/self-improvement/verify-fixtures.py`
to capture each deliberate failure and verify the fixture expectations before
starting model trials.
Inspect the coach result with PTC and admit it only if it is domain-blind and
within scope. Use one `-e` evaluation containing `export-candidate.clj` to
publish `frozen/candidate.input.json` with `--private-output`; PTC's current
CLI does not accept a script argument together with that output switch.
The supplied `export-candidate.py` performs that invocation.
The exported file is directly usable as `ptc run --input`. It is never parsed
as a log by a Python script.

```sh
python3 scripts/labs/debug-repair-showcase/self-improvement/run-comparison.py \
  --env-file "$ENV_FILE" --coach-run "$COACH_RUN_ID"
ptc repl --project tmp/nav-self-improvement/candidate-span.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 16000 \
  --load scripts/labs/debug-repair-showcase/analyze-navigation.clj \
  scripts/labs/debug-repair-showcase/score-navigation.clj
```

The comparison runner records input-byte hashes in `comparison.json` before
launching any trial. This identifies the exact unchanged control and candidate
inputs. The scripts only prepare configuration, copy captures, and invoke
PTC. Analysis of results, conversations, failures, and generated programs is
always performed through PTC.

## PTC friction

- `ptc docs repl` says output can publish a single non-interactive evaluation,
  but `--private-output SCRIPT` is rejected and requires exactly one `-e`.
  Reading the static query file into an argument works without parsing logs.
  The reference and generated site page now explicitly document the `-e` restriction.
- The current runtime warns that Gemini 3.8 Flash is not an exact local model
  catalog entry. The installed provider nevertheless completes runs and reports
  measured token usage and cost. Treat the latter as reported usage, not a
  locally catalogued price guarantee.

## Frozen artifact identity

The dated run used these SHA-256 input-byte hashes:

- Control: `2211c5f84642c8be2b82ce89d9d1d4a16da9896fb938dcd8b1194b786470bad2`
- Candidate: `d0e514a9837b4111a6947db9df5e297d3ef9d5a03687f33f017759b2e8853be7`

The two inputs have identical agent settings. The candidate task consists of
exactly the control task followed by the coach's returned addendum. The first
candidate trial's captured request confirms that addendum was present.

## Mechanisms observed during evaluation

Two early candidate traces identify concrete interface issues beyond vague
instruction-following concerns:

- `cmd-60ncmf8xp41zcqz6tgttgf6zkd` requested `mission-evaluation-9` in
  turns 5 and 8 although the captured incident's mission ID was
  `mission-evaluation-3`. The shipped `debug.nav/read` docstring contains
  exactly `mission-evaluation-9` in its example. This supports testing an
  example that obtains the identifier from a prior result, rather than using
  a realistic-looking fixed identifier. The trace also overwrote an activity
  binding from an unrelated `*1` value and had to fetch the activity again.
- `cmd-17033yrda5qey49sg31kvwm9mn` took the first relationship from a
  generated-source item without checking its state. That relationship was
  `producing_turn` with state `unavailable`, because this fixture is
  deterministic. Calling `debug.nav/follow` ended the agent run after six
  calls. Its docstring explicitly warns about this behavior, and the prelude
  intentionally calls `fail` on an unavailable relationship. The model ignored
  the guard requirement despite both the task and addendum describing complete
  typed relationships. A future safe-navigation interface could make this
  mistake recoverable while preserving evidence authority; this experiment
  does not change the current fail-fast contract.

The frozen candidate is not edited to address these evaluation observations.
They are hypotheses for a subsequent experiment with fresh holdouts.

## Validation completed

The three deliberate incident captures failed as intended. Corrected boundary
and workflow variants passed, and the text variant passed when its expectation
matched the implemented policy. All 18 model trials completed with retained
captures and no external retries. All result and turn analysis used PTC.
Python scripts passed syntax checks, the comparison CLI help path passed,
`mix precommit` passed, and ExDoc built with warnings treated as errors. Review
remains paused; no commit or push was made.
