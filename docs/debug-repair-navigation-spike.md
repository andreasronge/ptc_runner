# Model-navigated repair experiment

## Status

This document records a spike, not a shipping recommendation. It compares the
`debug-a-failed-run` repair agent's deterministic incident projection with a
variant in which the model chooses how to navigate the same immutable traces
and frozen source through `debug.nav`.

The experiment used the same domain-blind repair task and DeepSeek provider for
three incident classes:

1. an attributable mission-component defect;
2. an underdetermined defect for which the correct decision is to abstain;
3. a workflow-control defect connecting two correct missions.

All conclusions below come from the captured private runs inspected through
the `private-run-analysis-v1` PTC profile. Raw JSONL was not used as the
analysis interface.

## Question

The existing repair workflow acquires a bounded incident packet with PTC-Lisp
before the first model call. The model receives generated programs, capability
evidence, the frozen mission dependency closure, workflow source, provenance,
and completeness fields. Its model phase only synthesizes a repair or abstains.

The alternative tested here asks whether a coding-agent-like model loop should
choose which logs and sources to inspect instead. A small deterministic seed
identifies the failed run and boundary failure; `debug.nav` remains available
to the model for adaptive investigation.

## Workflow-control control arm

The spike first added a failure class distinct from the original pricing bug:

- `inventory/reserve` correctly maps an order ID to
  `reservation:<order-id>`;
- `shipping/schedule` correctly preserves the reservation ID it receives;
- workflow `main` invokes both missions in order but routes the incoming order
  ID into shipping rather than the reservation returned by inventory;
- the host workflow detects the cross-step mismatch and fails.

The fully preloaded repair agent selected workflow component `main`, preserved
both correct mission components, proposed `(get reservation "reservation_id")`,
and passed the observed case plus two held-out identifier shapes in one model
call. The successful repair run was `cmd-7fe7h7navwaws2gkp0sahx2jvx`.

This arm also exposed two reusable gaps:

- the incident projection must include bounded workflow source, not only the
  mission closure reached from generated programs;
- `target_mission` is meaningful only for a mission target. Workflow reports
  must omit it, while mission reports still require a nonblank value.

## Navigable variant

The experimental application is `repair-agent/ptc-navigable.json`.

Its deterministic seed contains:

- a summary of the selected failed run;
- the boundary workflow failure and its typed relationships;
- the collection catalog returned by `debug.nav/open`.

The model initially had one shared navigation/completion budget. Later trials
used two host-controlled phases while retaining the correlated transcript:

- up to six `investigate` turns with `debug.nav`;
- two reserved `synthesize` turns for one final read if necessary and a typed
  `repair.terminal/propose` or `repair.terminal/abstain` action.

The prompt did not name a suspect, component, source path, expected patch, or
domain-specific traversal. Caching was disabled and temperature was zero, so
each rerun was a fresh model trajectory rather than a replay.

## Fresh target captures

| Incident | Failed target run | Evidence visible before model navigation |
| --- | --- | --- |
| attributable mission defect | `cmd-0w3eggypyrrgmb4qretz2fchg6` | workflow failure and collection catalog |
| underdetermined defect | `cmd-26d3z2t3vn4nrt61bh41bhg9f7` | workflow failure and collection catalog |
| workflow-control defect | `cmd-1fzx9dm8p5xvc26yk4r7g5aa6k` | workflow failure and collection catalog |

PTC confirmed all three were complete deterministic captures with no model
calls, an `explicit_failure` terminal reason, and the intended generated
programs.

## Representative navigable trials

The configurations evolved in response to observed protocol failures, so this
table is an engineering experiment rather than a statistical model benchmark.

| Run | Configuration and outcome | PTC finding |
| --- | --- | --- |
| `cmd-4yg82b5ep4dc080t3np558bmgy` | attributable case, one six-turn phase; turn limit | the sixth program finally read both decisive leaf sources, leaving no turn to submit |
| `cmd-35afa6pc0y9jmpnr7gfg17zf20` | attributable case, one eight-turn phase; turn limit | still browsing provider evidence on turn eight after guessing several filters |
| `cmd-5gp1q3ffv5qwsmh8etbvh76aj4` | attributable case, six navigation plus two terminal-only turns; completed with abstention | stopped after `pricing.tax`; it explicitly reported that the two leaf sources had not been inspected, so the abstention was honest but wrong for the available capture |
| `cmd-6c5a24rnzkak49qsw9qe0yecv5` | underdetermined case, phased; correct abstention | inspected both constant components and correctly identified the missing intended formulas; seven model calls |
| `cmd-7e6wq8rpaf59sknftgnvyty551` | workflow-control case, phased; turn limit after final failure | found workflow `main` and the exact routing defect, then tried to re-read source after navigation authority closed and finally emitted only a replacement function fragment |
| `cmd-1nk2zcxpwhy8dyneactqp0twg8` | attributable case, final phase allowed navigation; workflow failure | authored the exact complete repair but omitted `target_mission`; terminal validation called `fail`, making the otherwise correctable mistake terminal |
| `cmd-7ca1064f9adsksjnw5fgdzjwb2` | attributable case after correction-friendly terminal validation; turn limit | used both reserved completion turns for source reads, including one retry after an invalid `name` filter, and never submitted |

The successful and failed traces had complete reconstructed turns and correct
five-field phased annotations. The failures were model-loop outcomes such as
`intermediate_result`, `evaluation_error`, or terminal program failure, not
missing capture evidence or failed navigation-provider capabilities.

## What the experiment established

### Adaptive navigation is possible

The model independently discovered evaluation IDs, generated programs,
mission component sources, dependency leaves, and workflow source. In the
workflow-control arm it selected workflow code rather than blaming either
correct mission. No domain-specific suspect was preloaded.

### It was materially less reliable than deterministic projection

The deterministic projector follows exact typed relationships in a bounded
PTC-Lisp loop and reports completeness. The model repeatedly spent turns on
facts already present in the seed, manually reconstructed filters, or queried
collections that could not close the current evidence gap.

Representative examples included:

- calling `debug.nav/open` again even though its catalog was in the seed;
- rereading the same parent activity;
- passing a capability name as a `model_exchanges.capability_id`;
- querying `prelude_sources` with an unsupported `name` filter;
- guessing component identities instead of following the relationship object
  already returned by the evidence item;
- reading provider exchanges after the responsible source closure was within
  reach.

The attributable and workflow repairs that the preloaded agent solved in one
model call consumed seven or eight calls and still did not reliably publish a
report. Raising the shared turn count changed the browsing trajectory but did
not solve completion.

### Reserving turns is not the same as reserving a terminal action

A phase boundary ensures later model calls exist, but it does not force the
model to use them for completion. Removing navigation authority caused a late
read to fail. Retaining navigation authority let the model spend both final
turns reading. Prompt text saying "one final read, then submit" did not enforce
that protocol.

The missing runtime capability is close to the declared-terminal source policy
tracked by issue #1504: allow bounded evidence reads and require a declared
terminal action in the same accepted program, rather than trying to infer
completion from a shared turn budget.

### Terminal validation must be correctable

Calling `fail` from `repair.terminal/propose` ended the agent when a mission
proposal omitted `target_mission`. The model had authored the correct repair,
and one synthesis turn remained, but it received no correction opportunity.

The spike now returns a deliberately contract-invalid value for invalid target
metadata. The result contract can then provide path-specific feedback and let
the bounded loop retry. This is a workaround for the example; a general
terminal API should distinguish correctable model input errors from terminal
subject failure directly.

## Recommendation

Do not replace deterministic incident curation with unconstrained model
navigation.

Use this division of responsibility instead:

1. The host deterministically projects the structurally adjacent incident
   closure, exact source hashes, typed relationships, and completeness.
2. The model synthesizes from that packet.
3. If the packet identifies a specific incomplete evidence edge, grant a
   bounded navigation escape hatch for that gap rather than reopening the
   entire evidence graph.
4. The runtime reserves and enforces a typed terminal action, optionally after
   one bounded read in the same program.
5. Host-owned validation and promotion remain separate from model authoring.

The useful property of the deterministic program is not that it diagnoses the
bug. It mechanically traverses relationships the host already proved. Fault
selection remains with the model, while evidence acquisition stays complete,
cheap, and reproducible.

## Follow-up experiments

The next experiment should be smaller, not a larger browsing budget:

- have the deterministic curator emit a named incomplete relationship or
  missing evidence class;
- give the model only that relationship, `debug.nav/follow`, and the terminal
  actions;
- allow one navigation program and one enforced terminal program;
- repeat across the three existing incident classes and another unrelated
  domain;
- compare correctness, abstention, model calls, invalid filters, and terminal
  completion with the fully preloaded baseline.

## Verification

- All three navigable project documents pass `mix ptc validate`.
- The focused debug-example, embedded-example, and materialization suites pass:
  23 tests, 0 failures.
- Formatting and `git diff --check` pass.
- Every target and repair trace used for the findings above was analyzed with
  PTC's private run-analysis profile.
- Private `.ptc` run artifacts are intentionally not committed.
