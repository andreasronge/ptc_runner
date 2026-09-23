# Program: debug-efficiency

Status: offline preparation, 2026-09-23. Protocol decision:
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
| H1 | Jev evidence selection followed by a reasoning model reduces time and cost at comparable diagnosis quality and answered coverage | total USD, median/p95 duration_ms, correct/wrong diagnoses and coverage | fixed evidence extraction plus one call to the same reasoning model | proposed live rule below; no verdict until evaluation | open |
| H2 | Bounded Jev navigation with escalation improves on fixed selection | the same end-to-end metrics, plus escalation and call counts | H1's frozen fixed-selection approach | proposed live rule below; no automatic promotion from screening | open |

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

These are planning constraints, not spending authority. A later experiment
issue must declare exact limits before a live run.

| limit | proposed boundary |
| --- | --- |
| initial engineering cap | two engineering days shared with #2030 for corpus feasibility and minimal comparison setup; approximately 0.2 day used |
| live spend | none authorized; proposed USD 50 cap and per-case reservations require a separate experiment issue |
| models | Jev plus a reasoning baseline; pin and record resolved versions before dispatch |
| investigation bounds | per-case elapsed time, total calls, tokens, dollars and escalation limit fixed before evaluation |
| candidate search | initial alternatives above; a fixed development-evaluation budget, not an unbounded prompt search |
| runtime changes | only demonstrated blockers to a valid comparison, tracked as ordinary issues |

The prelude-search remainder is not this program's budget. A complete product
decision provider, new evidence graph or research manager is not a prerequisite.
A thin comparison harness must still account for every dispatch, enforce caps,
and retain evidence. Private inspection sent to a model requires the host's
explicit private-data authorization.

## Offline preparation and proposed live protocol

The [screening inventory](debug-efficiency-corpus.md) has 33 candidate incidents and zero admission-ready packets. The [offline check](../../scripts/labs/debug-efficiency/README.md) uses seven synthetic cases to demonstrate the common evidence/result contract and accounting. These are neither debugging measurements nor provider recordings. No live model call was made. The current recommendation is **no-go for a live comparison** until a later, approved experiment issue freezes an eligible corpus and resolves the gaps below. This PR may merge its offline preparation; a later experiment artifact PR must be tagged and must never merge.

The following is a proposed protocol for that later issue, not run authorization:

1. **Corpus and authority.** Admit only signed case packets with an independently checked cause (or a justified insufficient-evidence/no-bug disposition), frozen source/input, trace, and authorized private inspection snapshot. Record all missing evidence and excluded cases before dispatch. The host exposes the same bounded `list/open/read/follow` evidence authority, byte limits and record IDs to every arm; it computes exact relationships and costs. A fixed extractor follows a published deterministic rule on that authority. Model arms may choose among the same record IDs; they cannot read labels, oracle outputs or ungranted private data. The final JSON is `diagnose` with one cause and cited evidence IDs, `no_bug` with citations, or `abstain` with neither. Unsupported, invented or misattributed citations score wrong. A no-bug case requires an explicit no-bug disposition with evidence; it is not a free abstention.
2. **Five arms.** Run deterministic explicit-diagnostic interpretation, fixed extraction plus one reasoning call, reasoning-led navigation, Jev selection plus one reasoning call, and bounded Jev navigation with optional reasoning escalation. The deterministic arm is reported separately from model comparisons. Navigation offers a fixed menu of record IDs at each step, never generated queries. Reasoning navigation gets at most two evidence reads and two reasoning calls. Jev selection gets one Jev call and one reasoning call. Jev navigation gets at most three Jev calls, two reads and one final reasoning call; it may spend one further reasoning call only as its single escalation. Escalation and abstention rules are frozen using development cases. No automatic patch or repair loop is allowed.
3. **Versions and separation.** Before a live dispatch, query the provider catalog once, select an explicit reasoning model ID and a Jev model ID with immutable revision or deployment identifiers, record provider route, model revision, pricing, prompt hash, evidence schema hash, runtime commit and question menu, then pin them in the experiment issue and protocol file. If a provider cannot supply a stable revision or changes it during the run, stop; never silently use an alias or replace a model. Use the same reasoning revision in every arm. Develop prompts, fixed extractor, thresholds and any Jev option menu only on development families. Freeze them and a cryptographic case/partition manifest before opening untouched evaluation families. Repeated calls on one incident remain one paired incident.
4. **Bounds and failure policy.** Proposed ceiling: 50 admitted incidents, four model arms, USD 0.20 reserved per arm/incident, USD 50 total including setup and failures, 90 seconds and 30,000 tokens per arm/incident, at most five model calls for the most expensive arm, one escalation, no automatic retry of malformed or rejected answers, and at most one transport retry only if the provider proves no dispatch occurred. Reserve before each dispatch; record every request, response, usage, read, elapsed interval, rejected answer, failed call and reservation. A dispatched call with unknown usage stops the run and keeps its full reservation unresolved. A known-cost failed/rejected call consumes cost and counts as failure in its paired denominator. A predispatch refusal consumes zero but also counts as failure. No case replacement after seeing results. Interleave arms within each incident and incident families across time, with one in-flight request per provider route. Report actual end-to-end live duration including reads, retries, waits and escalation; replay duration is never a proxy.
5. **Paired scoring and decision.** Count correct, wrong/unsupported, abstention, failure, answered coverage and no-bug correctness per arm and family. A failure remains in the denominator. Compare each Jev arm with the fixed baseline on the same eligible incidents. Proposed guardrails: the upper one-sided 95% confidence bound for the paired *increase* in wrong-diagnosis rate is at most 2 percentage points, and the lower one-sided bound for answered-coverage difference is at least minus 5 points. Useful gain requires at least 30% lower total measured USD **and** 25% lower median end-to-end duration, with one-sided 95% paired, family-cluster bootstrap bounds still above zero improvement. Report p95 descriptively and cost per correct diagnosis; it is not a gate on this small screen. Use a fixed bootstrap seed, 10,000 family-cluster resamples and publish paired rows/intervals. If too few independent families make intervals unstable, report inconclusive. H2 must also beat fixed Jev selection under the same rules. No winner is selected from repeated evaluation inspection.

These numeric ceilings and tolerances are **proposals** for a maintainer go/no-go decision. The later `experiment` issue must freeze or explicitly revise them, name the actual IDs and approved spend, and meet the [research publication contract](README.md). Approximately 0.2 engineering day was used for this preparation, leaving about 1.8 days of the proposed shared feasibility cap with #2030; no Jev lab hardening was done. Missing retained/adjudicated packets and #2021's diagnostic limitation block a defensible live screen now. Offline replay proves neither live latency nor Jev diagnosis quality.

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

#2028 produced the offline inventory, contract, proposed thresholds and a no-go
recommendation while case packets are absent. The next experiment issue must
freeze the eligible corpus, exact models and approved spend under the
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
