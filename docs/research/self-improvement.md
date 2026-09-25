# Program: self-improvement

Status: active, 2026-09-23. Discussion
[#2034](https://github.com/andreasronge/ptc_runner/issues/2034) decided to
pursue this program. No live run or provider spend is authorized. This document proposes how existing
programs combine into one question; it does not restart
[prelude-search](prelude-search.md) or widen
[debug-efficiency](debug-efficiency.md).

## Question

Can PtcRunner improve its own agentic workflows and tools from execution
evidence, such that each accepted improvement is verified by a judge outside
the loop, and gains compound across iterations and layers at a cost below
ordinary engineering?

### Layers

Each layer improves the one below it and is judged by evidence the layer
cannot edit. A layer starts only when the layer below it has a frozen, valid
baseline.

| layer | what improves | judge outside the loop | owner |
| --- | --- | --- | --- |
| L0 | an agent performs an application task | the task's result contract and tests | shipped workflows |
| L1 | a prelude is repaired or optimized from traces | replay equality or held-out executions | this program; repair search in prelude-search |
| L2 | a debugger diagnoses failed runs, or abstains | independently labelled causes | debug-efficiency |
| L3 | the debugger's own procedure improves | the L2 corpus, with an untouched final set | this program |
| L4 | the research process proposes its own next experiments | maintainer decisions and later verdicts | research steward; proposal-only |

### Loop invariants

- The mutable surface is replaceable PTC-Lisp: application components and
  preludes, on an experiment branch. The Kernel, authority, quotas, deadlines,
  evidence capture, scorers, labels and budgets are fixed for the duration of
  an experiment. A candidate that needs any of them changed is rejected and
  recorded as a runtime want.
- A candidate's score never grants capabilities, relaxes limits or changes
  its own evaluation. Capability references are checked against the actual
  mission inventory before a candidate is admitted.
- Every execution is pinned to a procedure or prelude version. Rejected
  candidates and their evidence are retained.
- No layer grades itself. Model agreement or confidence is not ground truth.
- Orchestration prompts stay domain-blind; learned domain procedures are
  application data.
- A candidate never merges through an experiment; an improvement that earns
  adoption becomes an ordinary issue with a reproduction.

### Selection safeguards

Repeated proposal and selection against a finite set of tasks overfits: gains
on that set shrink or vanish elsewhere. [RRSI](https://arxiv.org/abs/2609.24972)
reports this for four prior harness-evolution methods. Their gains of 1.3–3.6
points on the evolve set became −1.2 to +0.9 points out of distribution, while
tokens per trial roughly doubled. A random held-out split from the same
benchmark did not reveal the difference; only other benchmarks did. Removing
selection-side safeguards cost more out-of-distribution accuracy than removing
proposal-side ones. That paper reports one run per method without
uncertainty, so this program adopts its mechanisms, not its effect sizes.

- **Noise floor first.** Before any evolution, run the frozen parent
  repeatedly on the evolve set to estimate the run-to-run tolerance δ. A
  candidate is accepted only if it scores at least the best accepted version
  minus δ, so small regressions cannot accumulate as noise.
- **Cost pays for itself.** A candidate that raises cost must raise the score
  proportionally; the allowance is frozen before evolution. A gain within δ
  is accepted only if it lowers cost. Cost is measured as model-visible
  tokens, prelude source size and Kernel resource usage.
- **Mechanical leakage screening.** Before evaluation, reject a diff whose
  string or number literals match identifiers, entity names, input values
  or expected outputs from the evolve set or scorer. Candidates are PTC-Lisp
  source, so this is a deterministic check, not a model's judgment.
- **No inert machinery.** Reject or prune a function that Kernel traces show
  was never invoked during evaluation, and a component with no positive
  measured gain within a declared window.
- **Small, attributable edits.** Each candidate changes one component and
  states one hypothesis. The edit ledger records component, hypothesis, diff,
  score change, cost change and the acceptance decision; the proposer sees
  it so that falsified hypotheses are not re-proposed.
- **Held out by family and by model.** Decisions use failure families or
  applications absent from the evolve set, and at least one model the loop
  never ran. A random split of the evolve distribution is not sufficient.
- **Frozen selection.** The rule choosing the version sent to final
  evaluation is declared before evolution starts. Evolution runs are
  repeated so that uncertainty covers the search, not only the final
  evaluation.

## Hypotheses

| id | hypothesis | metric | null model | tolerance | state |
| --- | --- | --- | --- | --- | --- |
| H1 | Model-proposed edits to deterministic prelude helpers reduce execution cost while every recorded execution replays byte-equal | replay-equal fraction on recordings and property-test inputs the proposer never saw; paired median/p95 `duration_ms` and Kernel resource usage | the unmodified prelude on the same recordings | equality exactly 1; useful cost reduction to freeze before evaluation | open |
| H2 | Repair guided by an L2 diagnosis beats independent candidate sampling | paired final-test pass-rate difference and cost per final-test success | independent sampling at the same total token and dollar ceilings | to freeze; uncertainty required | open |
| H3 | A procedure evolved from the parent debugger's development failures beats that frozen parent on held-out failure families and a held-out model | paired correct and wrong diagnoses, answered coverage, cost per correct diagnosis, all refinement and validation cost included; generalization gap reported | the frozen parent debugger | wrong diagnoses must not increase beyond a frozen margin; useful gain to freeze | open |
| H4 | An L3 improvement propagates: repairs guided by the evolved debugger beat repairs guided by its parent | the H2 metrics | H2's diagnosis-guided repair using the parent debugger | to freeze; uncertainty required | open |
| H5 | Steward-proposed experiments reach a conclusive verdict as often as maintainer-authored ones | share of accepted proposals, share of run proposals ending `supports` or `refutes` | maintainer-authored backlog entries over the same period | descriptive until a sample size is declared | open |

H1 needs no model to judge: a model proposes, and replay equality decides.
Equality cannot be gamed on the paths the recordings cover, but an edit can
break paths they miss, so the judge includes recordings and property-test
inputs withheld from the proposer. Because any change to a model-visible
request breaks replay, H1 covers only behaviour-preserving edits. Edits that
change model-visible guidance need fresh live evaluation under H2 or H3.

H4 is the north-star test. A single round of improvement at one layer is
optimization; self-improvement requires that gains propagate between layers
or continue across iterations.

## Measurement

Every comparison is paired on the same cases, models, evidence, authority
and total budget, and reports case outcomes, denominators and a predeclared
95% paired confidence interval, following the rules in prelude-search. In
addition, this program reports:

- **Generalization gap:** evolve-set gain minus held-out-family gain, for
  every accepted version. A growing gap is the primary overfitting signal;
  a lower evolve-set score with better held-out results is acceptable.
- **Complexity growth:** model-visible tokens per trial, prelude source size
  and Kernel resource usage for every accepted version against the parent.
- **Iteration curve:** untouched final-set result for each accepted version
  N, N+1, …, with the cumulative cost of every proposal, rejected candidate,
  refinement and validation. A flat curve after one iteration is not
  self-improvement.
- **Break-even:** cumulative development cost divided by per-run saving,
  expressed as the number of production runs needed to recover it.
- **Engineering comparator:** the same target improved by a hand-written
  checklist, phased workflow or helper, with engineering hours recorded. A
  loop that cannot beat this has no product case.
- **Reliability:** pass^k over repeated trials on the same case, beside
  single-trial accuracy.
- **Compute-matched controls:** best-of-K sampling and generic coaching at
  the same total budget, so that gains are attributed to the loop's structure
  rather than to extra inference.
- **Rejection memory:** how often the proposer re-submits an edit equivalent
  to a rejected one, with and without access to rejected candidates.
- **Robustness:** results on held-out failure families and after a tool or
  schema change the loop did not see.

Replay validates accounting and orchestration only. It does not reproduce
live latency or evaluate responses to changed requests.

## Budget and limits

These are planning constraints, not spending authority.

| limit | proposed boundary |
| --- | --- |
| live spend | none authorized; each experiment issue declares its own cap |
| models | pinned and recorded before dispatch; one proposer model, plus one held-out model for final evaluation that the loop never runs |
| iterations | a fixed number of improvement rounds per experiment, declared in its issue |
| mutable surface | application components and preludes on the experiment branch only |
| runtime changes | only demonstrated blockers, tracked as ordinary issues |

## Stop rules

- **Foundation first:** L3 and H4 wait until debug-efficiency has a frozen,
  valid baseline with independent labels. An unreliable lower layer is not
  improved by a loop above it.
- **Noise floor:** if evaluation errors, timeouts or truncation dominate a
  recording, stop and file the harness defect. prelude-search/004 ended with
  48 of 105 candidate slots in evaluation errors; that pattern stops a run.
- **Uncalibrated:** no evolution starts before the parent's noise tolerance
  δ is measured on the evolve set.
- **Overfitting:** a generalization gap that grows over two consecutive
  accepted versions stops that layer pending a maintainer decision.
- **Flat:** two consecutive valid, sufficiently precise iterations that
  exclude the useful gain stop that layer pending a maintainer decision.
- **Judge touched:** any candidate or harness change that alters a scorer,
  label, budget or authority invalidates the experiment, as does any use of
  held-out families or the held-out model to tune thresholds or pick a
  version.
- **Budget:** remaining budget below the next iteration's reservation stops
  the run with partial results retained.

## Ledger

| experiment | report / result | immutable tag | verdict | known USD | consumed or reserved USD |
| --- | --- | --- | --- | ---: | ---: |
| self-improvement/001 | [report](reports/self-improvement/001-prelude-helper-inventory.md) / [result](reports/self-improvement/001.json) | [001](https://github.com/andreasronge/ptc_runner/tree/research/self-improvement/001) | inconclusive; explore, no hypothesis tested | 0 | 0 |

001 inventoried 61 public shipped prelude functions: 10 deterministic, 20
model-visible, 31 nondeterministic. It shortlisted `prompt.audit/segments`,
`prompt.audit/measure`, `prompt.audit/delta` and, with pure callbacks,
`cap/fold-pages`. No retained recording executes any shortlisted helper, so
H1 cannot yet be judged by replay. Of the deterministic helpers, only
`cap/unwrap!` (1) and `validate-phase-return` (13) have recorded executions,
and both are too small to justify a model search.

Prelude-search 000–004, the tool-compiler lab
([report](reports/tool-compiler/000-compiled-extraction-recipe.md)) and any
future debug-efficiency results are prior evidence, not measurements of this
program.

## Backlog

| id | kind | hypothesis | settles | priority | spawned_by | after |
| --- | --- | --- | --- | --- | --- | --- |
| self-improvement/b01 | explore | H1 | which shipped prelude helpers have deterministic, replay-covered executions and a measurable cost, how many recordings cover them, and which paths no recording reaches | 1 | maintainer | |
| self-improvement/b09 | change | H1 | a no-model judge corpus for the 001 shortlist: frozen bundles, visible and withheld inputs, result hashes, failure envelopes; #2056 | 1 | self-improvement/001 | b01 |
| self-improvement/b10 | measure | H1 | paired isolated-run Kernel usage and elapsed cost for the shortlisted helpers, with a hand-written optimization baseline, before any model-proposed edit | 2 | self-improvement/001 | b09 |
| self-improvement/b02 | measure | H1 | model-proposed behaviour-preserving edits judged by replay equality on withheld recordings and property tests, and by paired cost, against the unmodified prelude and a hand-optimized helper | 2 | b01 | b09, b10 |
| self-improvement/b11 | explore | H2, H3 | model-visible agent correction paths, using retained failure fixtures from prelude-search/004; changed requests need live evaluation | 4 | self-improvement/001 | b09 |
| self-improvement/b07 | change | H3, H4 | the mechanical leakage screen and trace-based inert-code check, validated on seeded leaking and inert candidates before any evolution uses them | 3 | maintainer | |
| self-improvement/b08 | measure | H3 | noise tolerance δ from repeated runs of the frozen parent debugger on the development set | 3 | maintainer | debug-efficiency/b02 |
| self-improvement/b03 | measure | H2 | diagnosis-guided repair against independent sampling at matched budget, using the frozen debug-efficiency baseline as the diagnoser | 3 | maintainer | debug-efficiency/b02 |
| self-improvement/b04 | measure | H3 | bounded evolution of the debugger procedure under the selection safeguards, on development cases, frozen before final evaluation on held-out families and a held-out model, against the parent, a checklist and compute-matched coaching | 4 | maintainer | b07, b08 |
| self-improvement/b05 | measure | H4 | rerun b03 with the b04 candidate as diagnoser | 5 | b04 | b03, b04 |
| self-improvement/b06 | explore | H5 | tabulate steward and maintainer proposals and their verdicts once the steward has run for a declared period | 6 | maintainer | |

### Conditions before b02

The b09 corpus (#2056, `scripts/labs/helper-corpus/`) is a pilot judge, not
yet sufficient for an H1 verdict. b02 does not start until:

- **Withheld inputs are out of the proposer's reach.** They are committed in
  plain text; either the proposer runs without repository access or the
  withheld set moves to a tagged, never-merged branch.
- **The corpus covers failure paths and real variation.** It has 8–11 inputs
  per helper, near-duplicate generated inputs, no failure case for the three
  `prompt.audit` helpers, and nine unrepresented arms, including five
  `cap/fold-pages` error arms.
- **Helper cost is measurable.** Whole-run `duration_ms` of 14–30 ms is
  dominated by Kernel overhead and cannot show a helper speedup; b10 must
  establish a measure that can.
- **The target is worth optimizing.** `prompt.audit` is development tooling,
  not a per-request path. b10 records whether any shortlisted helper has a
  production cost worth a model search; if none does, H1 needs a different
  target before b02.

## Pending proposals

- Decide whether captured prelude-search failures (timeouts, truncation,
  evaluation errors) may enter a debug-efficiency development set. #2028
  currently keeps reports 002–004 outside its cohort.
- #2056 (b09) and #2057 (seeded-mutation case packets for the
  debug-efficiency corpus) are ready. Both are no-model captures on the
  prelude-search Phase 0 mechanism; neither authorizes spend.

## Runtime wants

From self-improvement/001:

- Per-public-helper invocation and branch identifiers, with evaluation steps,
  heap and `duration_ms` attributable to one invocation. Today only aggregate
  run usage exists.
- A no-provider re-execution path that compares strict outputs and failure
  envelopes for one shipped helper across a candidate bundle.

Known gaps that bound this program:

- #2021: missing final mission evaluation diagnostics limit which failures an
  L2 debugger can diagnose from authoritative evidence.
- Changed model-visible requests cannot be replayed; every such candidate
  needs live evaluation.
