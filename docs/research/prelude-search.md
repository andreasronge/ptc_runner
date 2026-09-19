# Program: prelude-search

Status: active, methodology revised 2026-09-19. Harness under `scripts/labs/prelude-search/`;
its design and the experiment ladder it was built for are in
`docs/plans/reproducible-prelude-search.md`, which this document supersedes
as the record of results and next steps.

## Question

Does bounded search over model-written candidates, selected by a check
against recorded executions, produce prelude repairs that hold on executions
the model never saw, at a cost that single-shot repair cannot match?

## Hypotheses

| id | hypothesis | metric | null model | tolerance | state |
| --- | --- | --- | --- | --- | --- |
| H0 | A no-provider run reconstructed in a fresh process from retained application files and private inspection records reproduces its strict JSON result hash | fraction equal | exactly 1 | 0 | open; 000 checked same-process repeatability only |
| H1 | Checked candidate search improves final-test success over a capable single-agent baseline under the same total token and dollar ceilings | paired final-test pass-rate difference | measured baseline on the same instances | 3 percentage points; uncertainty required | open |
| H2 | Feedback from selection failures beats independent candidate sampling under the same total token and dollar ceilings | paired final-test pass-rate difference and actual cost | measured independent sampling on the same instances | 3 percentage points; uncertainty required | open |
| H3 | A helper the model wrote on one subject lowers cost on an unseen subject | cost per solved instance | the same run without the helper | ±10% | open |

## Budget and limits

Informational until a run is approved in the console; the maintainer files
issues by hand until then.

| limit | value |
| --- | --- |
| program budget | USD 25 |
| per-experiment cap | USD 5 |
| allowed kinds | measure, change, explore |
| allowed models | `openrouter:deepseek/deepseek-v4-flash`; a second model only when a verdict depends on it |
| filing depth | 3 experiments without a maintainer decision |
| first run version | approves `prelude-search/b01` and `prelude-search/b05`; nothing else is filed without a new version |

## Stop rules

- **Answered.** Every hypothesis is `supported`, `refuted`, or `dropped`.
- **Flat.** Two consecutive valid, sufficiently precise experiments exclude the
  minimum useful improvement: stop that line pending a maintainer decision.
  An underpowered or inconclusive result does not count as evidence of no effect.
- **Budget.** Remaining budget below the per-experiment cap: stopped pending
  a decision.
- **Invalid twice.** Two consecutive `invalid` verdicts on the harness: the
  harness needs an ordinary issue before research continues.
- **Runtime first.** A hypothesis whose next experiment needs a runtime
  change waits on that ordinary issue; it is not dropped.

## Ledger

No finished rows yet. A row requires the tag and the result file.

### Pending migration

- `prelude-search/000`, issue #1995, merged as `ccc81520a` (PR #1998, the
  harness itself): 300 of 300 re-executions byte-equal across three
  subjects, about 5 ms per re-execution. Needs a result file and the tag
  `research/prelude-search/000`. Report:
  [000](reports/prelude-search/000-reproducibility.md).
- `prelude-search/001`, issue #1996, branch `ptc-manager/issue-1996-job-167`
  at `e4b36ab4e`, model `openrouter:deepseek/deepseek-v4-flash`, USD 0.30 as
  reported by the agent: K=4 held-out 91.7% against a sampling prediction of
  89.7%, K=2 70.0% against 67.9%, E1 43.3%. The method review found blocking
  method defects (held-out selection outside the runtime, scorer wrong in
  both directions, replay without usage or timeouts, cap checked per batch),
  so its verdict will be `invalid` once tagged. Report:
  [001](reports/prelude-search/001-deepseek-e1-e2.md).

Reading of 001: these are selection-set success rates, not independent final-test
rates. The same tests selected the winner and supplied the reported outcome.
The pooled sampling formula `1 - (1 - p)^K` is illustrative only: case difficulty
varies and candidate outcomes may be correlated. Agreement with that formula
neither establishes independence nor refutes a search advantage. Report 001
remains invalid; its original text is preserved as historical evidence.

### Corrective experiment protocol

Freeze this protocol and its seed list before generating model answers:

- Partition distinct inputs into visible examples, selection/feedback tests,
  and final tests. Check disjointness by input value, not just by index or
  seed. Generate oracle values privately. Never expose final inputs, outputs,
  or scores to proposal, selection, retry, or early-stop decisions.
- Verify every planted mutation changes at least one oracle result in both
  selection and final sets. An equivalent or unreached mutation is a harness
  defect, not a solved repair; record it and fix the harness before the run.
- Run the same subject/mutation/input instances in every condition. Include
  one-turn E1 as a historical diagnostic, a capable three-turn E1 baseline,
  independent sampling at K=2 and K=4, and later depth-three feedback.
  Primary comparisons share total token and dollar ceilings per instance;
  a turn increase never silently increases the budget. Report actual usage,
  failures, and cost per final-test success alongside success rates.
- Select one candidate by selection results with a frozen tie-break (first
  passing candidate in attempt order). Freeze that choice before evaluating
  final tests. No selected candidate means final-test failure. Never choose
  another candidate because the selected candidate failed final tests.
- Score every candidate's diagnosis separately from selection. Accept the
  correct qualified or unqualified function name, reject empty form matches,
  and validate citations against the exact visible ordering for that attempt.
  Do not report citation existence as proof that a diagnosis is supported.
- Keep checking and selection in recorded no-model workflow/mission executions.
  Preserve proposal sources, selection evidence, chosen index, and final
  evaluation separately. Replay must preserve successful responses, usage,
  and error categories; it does not reproduce elapsed provider latency.
- Reserve the worst-case remaining spend before each case starts. Include
  retries and failed calls in the issue cap; missing usage stops the live run.
- Report paired case outcomes, denominators, per-subject results, and a
  predeclared 95% paired confidence interval. Resample whole instances within
  subjects, preserving all conditions together; repeated attempts are not
  independent observations. Conclusions apply to these toy subjects only.
  Support requires the interval's lower bound above the minimum useful
  improvement; an upper bound below it rules out that improvement at this
  precision. Otherwise the result is inconclusive. Equivalence requires the
  entire interval inside the declared equivalence band.

These requirements apply when run manually; implementation of the research
steward is not a prerequisite. The initial sixty instances are a pilot, not a
promise of precision within three percentage points. Freeze any larger study
before inspecting its final outcomes.

## Backlog

| id | kind | hypothesis | settles | priority | spawned_by | after |
| --- | --- | --- | --- | --- | --- | --- |
| prelude-search/b01 | measure | H1 | corrective rerun of 001 under the protocol above: three disjoint sets, effective mutations, recorded selection, matched budgets, capable E1, all-candidate scoring, complete replay, paired uncertainty | 1 | prelude-search/001 | |
| prelude-search/b02 | measure | H2 | feedback depth 3 using selection failures only versus independent K=4 at matched total budgets, scored on untouched final tests | 2 | prelude-search/001 | b01 |
| prelude-search/b03 | measure | H1 | soft evidence and the no-bug and spec-bug case classes: false-repair rate with and without an `authority` field on evidence | 3 | maintainer | b01 |
| prelude-search/b04 | measure | H3 | a kept evidence-reading helper on an unseen subject, with and without | 4 | maintainer | b02 |
| prelude-search/b05 | change | H0 | record the run input privately and reconstruct no-provider E0 runs from retained files in a fresh process; compare identities and result hashes | 2 | prelude-search/001 | |
| prelude-search/b06 | change | H1 | render `data/params` as its value to the model instead of its type; prompt tokens and pass rate on b01's fixtures | 3 | prelude-search/001 | b01 |
| prelude-search/b07 | explore | H2 | which evidence-graph representation a feedback loop would need from the debugger prelude, from the captured failures of 001 | 5 | maintainer | |

## Pending proposals

None. Entries the steward proposes land here until a run version approves
them.

## Runtime wants

From `prelude-search/001`. Each becomes an ordinary issue with a
reproduction when a run version approves filing it; none is filed yet.

- Mission params passed with `kernel/eval-with` are recorded by identity
  hash only, and a mission's return value has no first-class inspection
  record, so how a candidate was selected cannot be audited from the
  artifacts.
- `data/params` is rendered to the model as a typed name, not its value, so
  a one-request repair had to carry the same data in the user message.
- `kernel/eval-source-with` accepts a mission program, not a complete
  component with `ns`, docstrings, and export metadata, so each candidate
  had to be compiled into a frozen no-model application to check it.
- Replay response cursors are run-scoped, so identical request hashes in
  separate runs cannot share one fixture; the experiment produced 180
  fixture files.
- A live provider error has no successful response object, so a replay
  fixture cannot reproduce a timeout candidate.
- The run input is not recorded in any artifact (from `prelude-search/000`;
  the lab stores it beside the run).
