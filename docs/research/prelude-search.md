# Program: prelude-search

Status: active, 2026-09-18. Harness under `scripts/labs/prelude-search/`;
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
| H0 | A recorded run re-executes byte-equal from its frozen bundle and its input | fraction of re-executions equal | none; the claim is exactly 1 | 0 | open until `prelude-search/000` is migrated |
| H1 | K parallel candidates with a held-out check beat single-shot repair at equal per-candidate budget | held-out pass rate | independent sampling: 1 − (1 − p₁)ᴷ where p₁ is the single-shot rate | ±3 points | open |
| H2 | Feedback from a failed check beats more width at equal tokens | held-out pass rate per dollar | H1's K=4 result at the same spend | ±3 points | open |
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
- **Flat.** Two consecutive valid experiments on one hypothesis move its
  metric by less than the tolerance: the hypothesis is `dropped`.
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

Reading of 001, recorded for the corrective experiment: had the run been
valid, the observed lift sits inside the null model's tolerance, which would
make the verdict `refutes` for H1 as stated. H1 may need restating as a
per-dollar claim rather than a per-candidate one.

## Backlog

| id | kind | hypothesis | settles | priority | spawned_by | after |
| --- | --- | --- | --- | --- | --- | --- |
| prelude-search/b01 | measure | H1 | corrective rerun of 001: held-out check inside a no-model mission driven by workflow code and captured in the run's artifacts; scorer accepts qualified names, scores all candidates, and requires `cited_executions` to exist and show the claimed values; fixtures carry usage and error responses so replay reproduces cost and timeouts; budget reserved per case; E1 at three turns as an added row | 1 | prelude-search/001 | |
| prelude-search/b02 | measure | H2 | feedback depth 3 (failing held-out input and both outputs fed back) versus K=4 at equal tokens | 2 | prelude-search/001 | b01 |
| prelude-search/b03 | measure | H1 | soft evidence and the no-bug and spec-bug case classes: false-repair rate with and without an `authority` field on evidence | 3 | maintainer | b01 |
| prelude-search/b04 | measure | H3 | a kept evidence-reading helper on an unseen subject, with and without | 4 | maintainer | b02 |
| prelude-search/b05 | change | H0 | record the run input as a private inspection record so E0 runs from artifacts alone; measure E0 on the recorded runs | 2 | prelude-search/001 | |
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
