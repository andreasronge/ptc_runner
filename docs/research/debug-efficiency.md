# Program: debug-efficiency

Status: proposed, 2026-09-21. Protocol decision:
[#2028](https://github.com/andreasronge/ptc_runner/issues/2028).
This is a bounded comparison of debugging approaches, not a commitment to
build an autonomous debugger. No live run or provider spend is authorized.

## Question

Can Jev-assisted evidence selection materially reduce end-to-end time and
cost to a correct diagnosis, without increasing wrong conclusions, compared
with a simple reasoning-model baseline?

The immediate application is a read-only assistant for captured PtcRunner
failures. It returns a diagnosis with evidence, or an explicit abstention.
Patch generation and automatic repair are outside the first comparison.

## Hypotheses

| id | hypothesis | metric | null model | tolerance | state |
| --- | --- | --- | --- | --- | --- |
| H1 | Jev evidence selection followed by a reasoning model reduces time and cost at comparable diagnosis quality and answered coverage | total USD, median/p95 duration_ms, correct/wrong diagnoses and coverage | fixed evidence extraction plus one call to the same reasoning model | minimum gains and allowed quality/coverage differences must be frozen in #2028 before final evaluation; no verdict until then | open |
| H2 | Bounded Jev navigation with escalation improves on fixed selection | the same end-to-end metrics, plus escalation and call counts | H1's frozen fixed-selection approach | thresholds must be frozen in #2028; no automatic promotion from screening | open |

### Initial alternatives

| approach | purpose |
| --- | --- |
| Deterministic interpretation of explicit diagnostics | Establish how much requires no model; report coverage separately. |
| Fixed evidence extraction plus one reasoning-model call | Simple primary baseline. |
| Reasoning model navigating the evidence | Test whether adaptive investigation earns its time and cost. |
| Jev selects evidence, then one reasoning-model call | Test inexpensive selection with a fixed final reasoner. |
| Bounded Jev navigation with escalation | Test several small decisions against fixed selection and reasoning-led navigation. |

All alternatives receive the same underlying evidence, tool authority and
result contract. They may select different records. The host supplies actual
record identities and allowed actions, performs exact computations, and
enforces stopping. Jev selects or scores bounded options; a generative model
handles novel explanations when needed. Abstain/escalate must be available
when no offered explanation is supported.

The [Jev lab](../../scripts/labs/jev-decision/README.md) records six ticket
decisions in one request for USD 0.000028014. It reports no latency measurement
and tests neither debugging nor probability calibration on debugging cases.
Jev's typed outputs do not establish correct diagnoses. Its documented
weaknesses include indirection, numerical reasoning and irrelevant large
inputs; the first comparison should use small concrete decisions.
See [TypeSafe's capabilities](https://docs.typesafe.ai/concepts/system-one)
and [version 1.13 limitations](https://docs.typesafe.ai/model-jaggedness/jev-1.13).

### Evaluation contract to freeze

- Start with roughly 30–50 distinct screening incidents: real regressions
  and seeded failures, across several applications/failure families, including
  intentionally insufficient-evidence and no-bug cases. Establish causes,
  acceptable evidence and abstentions independently of the investigator.
  Keep the labels and scorer outside the system being optimized.
- Separate development and untouched evaluation sets by application or bug
  family; keep near duplicates together. Publish eligibility and exclusions
  before running. Missing capture data is an evidence limitation, not a
  reasoning failure; keep such cases visible in coverage accounting.
- Score correct diagnoses, wrong diagnoses, abstentions and answered coverage
  separately. Evidence must support the conclusion, not merely exist. Model
  confidence or agreement between models is not sufficient ground truth.
  Use executable reproductions and independently reviewed labels where possible.
- Include every model call, tool call, failed attempt, retry and escalation
  in cost and elapsed time. Report median/p95 duration_ms, total and per-case
  USD, calls, escalation rate and cost per correct diagnosis. Speed and cost
  comparisons require comparable accuracy and coverage; abstaining on every
  case cannot win. Freeze retry and known-usage failure scoring in advance.
- Select alternatives and calibrate confidence thresholds only on development
  cases. Freeze finalists before final evaluation; report paired differences
  and uncertainty. A small screening sample, especially its p95, is descriptive
  and cannot establish narrow equivalence or a three-point accuracy difference.
  Expand only for a declared decision that needs more precision.
- Interleave conditions and incident families, control concurrency, and record
  model/provider versions, question/evidence versions and live timings.
  Repeated calls on one incident are not independent incidents. Avoid choosing
  a winning variant from repeated inspection of the final evaluation set.
- Retain requests, responses, usage, failures and the selected evidence path.
  Replay validates accounting and orchestration, not live provider latency or
  the quality of unobserved decisions. Changed requests need new recordings;
  do not replay old answers as if they evaluated a new policy.

## Budget and limits

These are planning constraints, not spending authority. #2028 must declare
exact limits in a self-contained experiment issue before a live run.

| limit | proposed boundary |
| --- | --- |
| initial engineering cap | two engineering days for corpus feasibility and minimal comparison setup, then stop/review; confirm in #2028 |
| live spend | none authorized; freeze an independent cap, reservations and per-case limits in #2028 |
| models | Jev plus a reasoning baseline; pin and record resolved versions before dispatch |
| investigation bounds | per-case elapsed time, total calls, tokens, dollars and escalation limit fixed before evaluation |
| candidate search | initial alternatives above; a fixed development-evaluation budget, not an unbounded prompt search |
| runtime changes | only demonstrated blockers to a valid comparison, tracked as ordinary issues |

The prelude-search remainder is not this program's budget. A complete product
decision provider, new evidence graph or research manager is not a prerequisite.
A thin comparison harness must still account for every dispatch, enforce caps,
and retain evidence. Private inspection sent to a model requires the host's
explicit private-data authorization.

## Stop rules

- **Feasibility:** if independent labels and representative captures cannot be
  assembled within the engineering cap, report the gap and stop. Do not turn
  corpus preparation into an infrastructure program.
- **Accounting/evidence:** unknown spend, breached limits, corrupted captures
  or scorer defects stop the recording. Retain reservations and partial results.
  Known-cost model failures follow the frozen scoring rule; they must not
  silently disappear from denominators.
- **No useful advantage:** retain the simpler approach when a sufficiently
  precise final comparison excludes the declared useful improvement. An
  inconclusive screen earns neither a success claim nor automatic expansion.
- **Complexity:** no recursive investigations, dynamic question generation,
  self-repair, or new graph framework in the first comparison. A later method
  must address an observed failure and be compared with the frozen baseline.
- **Generalization:** claims remain limited to tested capture surfaces, models
  and incident families. Dependency navigation does not establish caller,
  data-flow or distributed-system debugging. Transfer needs held-out families
  or applications and a separately declared evaluation.

## Ledger

No experiments run. Prelude-search 002–004 are background observations, not
debug-efficiency measurements. Their replay agreement does not validate Jev
or establish a debugging speed advantage.

## Backlog

| id | kind | hypothesis | settles | priority | spawned_by | after |
| --- | --- | --- | --- | --- | --- | --- |
| debug-efficiency/b01 | explore | H1, H2 | corpus feasibility, independent labels, capture gaps and a frozen protocol through #2028 | 1 | maintainer | |
| debug-efficiency/b02 | measure | H1, H2 | initial bounded comparison on the approved corpus | 2 | b01 | b01 |
| debug-efficiency/b03 | measure | H1 | offline-generated, frozen question library versus the best simple baseline, only if selection is an observed bottleneck | deferred | b02 | b02 |
| debug-efficiency/b04 | measure | H2 | bounded generated subqueries or decomposition, one change at a time, only if unresolved cases require it | deferred | b02 | b02 |

## Pending proposals

#2028 must freeze the corpus manifest, models, evidence representations,
scorer, useful-gain thresholds, tolerated regressions, failure policy,
engineering cap and live-spend cap, then obtain an explicit go/no-go.
The next experiment issue must be self-contained under the
[research publication rules](README.md). No existing issue authorizes b02.

## Runtime wants

- #2021 tracks missing final mission evaluation diagnostics. Assess its impact
  on corpus eligibility first. Where authoritative evidence is required but
  absent, fix capture or mark the case unanswerable; do not infer the missing
  diagnostic from a model's guess. It is not a blanket dependency for all cases.
- The current Jev lab lacks LLM replay, cost-budget and admission integration.
  The first harness needs explicit bounded accounting and response recording;
  promoting it into the product is a separate decision after useful results.
- Keep #2023's inspection-fixture reliability investigation separate from model
  evaluation. New reproducible runtime defects become ordinary issues; fixing
  the debugger recursively is outside this program's initial scope.
