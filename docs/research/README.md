# Research programs

A research program is one question with hypotheses, a budget, stop rules, a
ledger of finished experiments, and a backlog of candidate experiments. Most
of the work an experiment produces is never merged: only its report reaches
this directory. The design of the loop that runs programs, and the console
side that will drive it, is in the PtcManager research-steward plan
(`docs/plans/research-steward.md` in that repository). Everything on this
page holds whether a program is driven by that console or by a person.

## Programs

| Program | Question | Status |
| --- | --- | --- |
| [prelude-search](prelude-search.md) | Does checked candidate search improve repair on unseen executions under matched budget ceilings? | paused; corrective pilot inconclusive |
| [debug-efficiency](debug-efficiency.md) | Can Jev-assisted evidence selection reduce time and cost to a correct diagnosis without increasing wrong conclusions? | proposed; protocol decision #2028, no live run authorized |
| [self-improvement](self-improvement.md) | Can workflows and tools improve from execution evidence, judged outside the loop, with gains that compound across layers? | draft; discussion #2034, no experiment authorized |

## Layout

```text
docs/research/README.md                          this index
docs/research/<program>.md                       the program document
docs/research/reports/<program>/<nnn>-<slug>.md  one report per experiment
docs/research/reports/<program>/<nnn>.json       the result file the report's numbers come from
scripts/labs/<program>/                          the harness, when the program has one
```

## The program document

Sections in order: **Question**; **Hypotheses** (id, sentence, metric, null
model, tolerance, state `open`/`supported`/`refuted`/`dropped`); **Budget and
limits**; **Stop rules**; **Ledger**; **Backlog**; **Pending proposals**;
**Runtime wants**.

The document carries no authority. Budgets and permissions come from an
approved run in the console, or from the maintainer filing an issue by hand.
A ledger row exists only for an experiment whose branch is tagged and whose
result file exists; the verdict is computed from the result file against the
hypothesis's predeclared comparison, uncertainty, and decision rule, and from
the method review, never from the experiment's own author. A point estimate
inside a tolerance is not evidence of equivalence. Until the harness emits
the required paired observations and uncertainty, conclusions stay provisional
and require maintainer review; automation must not infer them from aggregate
percentages alone. Backlog entries are `<program>/b<nn>`;
their `after` column is an ordering preference between entries, separate
from native GitHub issue dependencies.

## Experiment ids, kinds, and verdicts

An experiment is `<program>/<nnn>`. Its kind is `measure` (run a harness),
`change` (alter the runtime or a shipped prelude as a candidate and measure
it against main on the same replay fixtures; the candidate never merges
through the experiment), or `explore` (read code, traces, or literature and
produce backlog candidates with evidence; no measurement).

A verdict is `supports`, `refutes`, `inconclusive`, `invalid` (a method
defect of medium or higher severity makes the numbers unusable), or
`stopped`. A `change` that earns its change, and every runtime want, becomes
an ordinary issue with a reproduction, never a research pull request.

## What merges

The experiment's branch is retained on the remote and tagged
`research/<program>/<nnn>` at its final commit; that tag is the reproducible
record and it is never deleted. Only the report and the result file reach main. Fixtures,
harness changes, and candidate diffs stay on the branch. A harness change a
second experiment needs is an ordinary issue and an ordinary pull request.

## The report

Every report starts with this header so results are searchable with `rg`
without parsing prose:

```yaml
program: prelude-search
experiment: prelude-search/001
issue: 1996
tag: research/prelude-search/001
kinds: [measure]
hypotheses: [H1]
model: openrouter:deepseek/deepseek-v4-flash
replay: scripts/labs/prelude-search/fixtures/deepseek-v4-flash/
tags: [sampling, held-out-check, deepseek]
```

The header carries no verdict and no cost; those are ledger columns. The body
holds what the issue asked for: conditions, metric tables, the comparison
with the hypothesis's null model, verbatim examples, failure modes with
counts, and a **runtime wants** section listing what the experiment needed
from the runtime and had to work around.

To find prior results: `rg -l 'hypotheses: \[.*H1' docs/research/reports/`
for a hypothesis, `rg -l 'tags: .*deepseek' docs/research/reports/` for a
tag, and the program's ledger for verdicts and cost.

## The experiment issue

An experiment issue is self-contained; the program document is linked for
context, never required. It states:

- **Program and hypotheses**, by id and sentence.
- **Kind**, one of the three above.
- **Conditions**: matrix, seeds, model, this experiment's budget, its
  early-stop metric, untouched final evaluation set, uncertainty method, and
  its wall-clock cap. Budget is enforced before each
  spend, not checked afterwards.
- **Deliverable**: the report at its path with the header above and the
  result file beside it, written by the harness with one entry per
  hypothesis (`metric`, `observed`, `baseline`, condition values, paired case outcomes,
  denominators, confidence interval, and decision-rule version);
  for `measure`, replay fixtures on the branch, with usage and failure
  categories retained and an explicit case-to-fixture index; for `change`, the candidate diff and a baseline-versus-candidate
  table; for `explore`, candidate backlog entries with evidence.
- **Prior results** it builds on, by experiment id.
- **Pull request**: title `experiment(<program>): <slug>`, label
  `experiment`, body `Artifact for #<issue>`. It is never merged; it exists
  for the method review and the tag.

Prompts inside a harness stay domain-blind per the repository rules; the
subjects a harness studies are data.
