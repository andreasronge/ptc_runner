# Depth-one recursive self-debugging experiment

Date: 2026-08-15

## Question

Can one root investigator use immutable `debug.nav` evidence, request a small
number of focused sequential child investigations, and then produce a safer or
more efficient diagnosis and repair candidate than one long investigator loop?

The experiment is deliberately depth one. Children can navigate the evidence
but cannot delegate. The trusted workflow owns the child-call count, individual
turn budgets, total provider quota, final result validation, and termination.

## Conditions

- Baseline: the existing shipped-`debug.nav` single investigator results in
  `tmp/self-repair-adversarial/REPORT.md`.
- RLM-lite: a root mission with `debug.nav` plus the two action constructors
  `debug.rlm/investigate` and `debug.rlm/finish`; up to three sequential child
  missions, each with read-only `debug.nav`.
- Fixtures: the identifiable transitive `deep` failure and the deliberately
  underdetermined `ambiguous` control.
- Models: Luna and DeepSeek through the existing frozen host configurations.

## Results

The depth-one action harness exposed protocol friction before establishing the
value of delegation. The experiment therefore adds a simpler control: one
ordinary `agent.main` debugger with `debug.nav`, no delegation vocabulary, and
the generic task of explaining the cause, citing evidence, and recommending the
smallest next change. It receives the first failed RLM canary unchanged. This
tests whether PTC Runner can reproduce the open-ended manual investigation
without a special workflow.

The subject was failed RLM canary `cmd-65hrha6x8z5dv899byz4z44n00`. Its one
root program was `(return (debug.nav/runs {"limit" 10}))`; the workflow expected
the returned value to be either a `debug.rlm/investigate` or `debug.rlm/finish`
action and rejected the run listing.

| Investigator | Debugger run | Result | Model / evidence calls |
| --- | --- | --- | --- |
| Luna | `cmd-292x7x3nw7zbd91kd4mwc8yqrz` | contract-valid report, but missed the protocol cause | 10 / 14 |
| DeepSeek | `cmd-3qyk0dq03dajnxkkwrv9d3dka5` | reached agent turn limit without a report | 10 / 14 |

Luna spent two turns listing runs, two opening the selected run, four reading
or following errors and activity, and then queried `turns` with
`evaluation_id=workflow-evaluation-3`. The relevant generated turn is nested
under that workflow evaluation and is identified by `parent_evaluation_id`, so
the query returned no useful turn. Luna concluded that the direct producer was
missing and recommended capturing more boundary diagnostics.

DeepSeek used the useful unfiltered `turns` query on turn four. Its next
feedback contained both the exact generated `(return (debug.nav/runs ...))`
source and the original root instruction allowing only `investigate` or
`finish` to cross the boundary. It also read `generated_sources` on turn five.
Despite having the decisive comparison, it continued through activity,
model-exchange, an unavailable related target run, boundary relationships, and
run metadata. Its tenth program still explored rather than returned, so
`agent.core` correctly stopped it at the declared limit.

The manual diagnosis used the same PTC evidence substrate. From the CLI's run
reference, one private-analysis session issued `analysis/runs`,
`analysis/open`, `analysis/read execution_errors`, and an unfiltered
`analysis/read turns`. The last query exposed the terminal navigation program.
The comparison against the action contract came from the workflow source that
had just been authored in the working tree. No subagent and no raw JSONL parser
was involved.

The important differences were therefore:

1. The manual investigator already knew the exact run id and retained the
   workflow's intended action contract; the PTC agents had to rediscover both.
2. Deterministic REPL queries cost no model turns. The agents paid one model
   turn for every navigation decision and spent several on repeated catalog
   reads and output shaping.
3. The canonical boundary error's `direct_boundary_producer` was incomplete.
   The decisive child turn was available, but not presented as the natural
   causal continuation from the workflow failure.
4. Seeing decisive evidence was not sufficient for DeepSeek: the generic
   open-ended loop lacked a reliable evidence-sufficiency/stopping decision.

This falsifies the stronger claim that merely granting `debug.nav` makes the
PTC agent equivalent to a coding agent operating around PTC. The evidence is
available, and a plain agent is the right reasoning shape, but the current
projection makes it pay for joins and context that the external coding agent
already possesses.

## Friction

1. The first Luna canary terminated its first navigation call with
   `(return (debug.nav/runs ...))`. The root task's phrase “return exactly” for
   delegation actions was not enough to distinguish terminal actions from
   ordinary navigation. The workflow rejected the run listing as an invalid
   root action after one model call. PTC private analysis identified the exact
   generated program. The generic task now states that `debug.nav` calls are
   intermediate and only `debug.rlm/investigate` or `debug.rlm/finish` may
   cross the root boundary.
2. An open-ended debugger can choose the wrong identifier domain even after
   `open` advertises both `evaluation_id` and `parent_evaluation_id`. Luna
   filtered reconstructed turns with the workflow evaluation id instead of
   following the nesting edge to its child turn.
3. `direct_boundary_producer` was incomplete for an explicit workflow failure
   even though the inspection snapshot contained one nested returned child,
   its generated source, and the workflow's subsequent rejection. The model
   had to infer and manually join that chain.
4. Repeated `runs`, `open`, and error reads consumed most of Luna's ten-turn
   budget. DeepSeek obtained decisive evidence by turn five but had no robust
   stopping behavior and exhausted the same budget.

## Product implication

Keep the investigator open-ended; do not require an RLM or a fixed diagnosis
workflow for this case. Improve the evidence boundary instead. A small incident
entry point should return the failing workflow evaluation, its directly nested
evaluations, their generated programs and terminal values, and the effective
workflow component or task that consumed those values. Preserve typed links to
expand each item with `debug.nav`.

The acceptance test is this exact canary: with no hint about `return`, an
ordinary `agent.main` debugger should identify the invalid terminal navigation
within four model calls and recommend reserving `return` for the declared root
actions. A second criterion should require it to finish once that comparison is
available rather than spending the remaining budget on unrelated metadata.

## Coding-agent context experiment

The next comparison isolated two pieces of context the external coding agent
had before reasoning:

- **run reference**: the exact failed run id and generic
  `execution/workflow_failed` message;
- **working set**: the same plus a read-only `debug.workspace/changed` facade
  returning the exact frozen `debug.rlm.workflow` and `debug.rlm` sources from
  the failed run. Being in the working set was explicitly not evidence of
  fault.

The diagnosis prompt did not mention `return`, action protocols, or an expected
cause. Both conditions retained unrestricted `debug.nav` and allowed four model
calls. The prior no-context ten-turn runs were not repeated.

| Context | Model | Debugger run | Result | Model / evidence calls |
| --- | --- | --- | --- | --- |
| run reference | Luna | `cmd-06dwmc8fmm6hc0vb215mc6dph1` | returned, missed cause | 4 / 5 |
| run reference | DeepSeek | `cmd-1ez4d07a7tqkdwx2kyhe7h5gxw` | turn limit | 4 / 4 |
| run reference + working set | Luna | `cmd-22f891w4n97apwnmq8drkjv4c0` | returned, missed cause | 4 / 7 |
| run reference + working set | DeepSeek | `cmd-7ennehkhk21ea3xjb7ehyw63k9` | turn limit | 4 / 9 |

The run reference removed discovery cost for Luna: it opened the exact run on
turn one and read unfiltered `activity` plus `turns` on turn two. It therefore
saw the terminal `(return (debug.nav/runs ...))`, but without the workflow
source treated that call as valid and safely declined to infer a cause.
DeepSeek ignored the supplied specificity, listed runs anyway, and spent its
remaining calls on `open`, `execution_errors`, and `boundary_failure`; it never
read `turns`.

The working-set arm did not join the missing halves. Luna's first program used
the nonexistent `json/encode`, so static checking spent one correction turn
before any evidence call. Turn two successfully returned the exact changed
sources. Turn three unnecessarily listed runs. Its final program requested
`activity`, `turns`, and `capability_calls` and constructed a report in the same
program. Because the model had not yet received those query results while
authoring that terminal program, its conclusion remained a generic workflow
failure rather than a comparison with the offending generated source.

DeepSeek read the working set on turns two and three but also requested a
nonexistent `run` collection and repeatedly reopened the catalog. It never read
the target `turns` collection and did not return on the final turn.

This rejects both small hypotheses under the four-call criterion:

1. Supplying the run reference alone does not reproduce coding-agent behavior.
2. Supplying the frozen changed sources alongside the same navigation API does
   not reproduce it either.

The external coding agent had the action contract in working memory and then
received the generated program from one deterministic PTC query. The PTC
agents had the same facts available, but in separate observations and with
catalog, identifier, language-correction, and terminal-synthesis costs between
them. A larger turn budget might eventually produce an answer, but would not
test the intended coding-agent-like property.

The next minimal experiment should therefore replace separate startup reads
with one structural, non-diagnostic `debug.case/context` operation returning:

```text
run_id and terminal error
directly nested evaluation and generated program
that evaluation's terminal value
frozen changed-component sources
typed links for expansion
```

The operation must not label a cause or recommend a fix. Reuse the same generic
prompt, two models, and four-call ceiling. Success would show that the missing
primitive is co-location of runtime evidence and current source, analogous to
a coding agent starting from a failed command while retaining its working set.

## Structural case-context experiment

The experiment added that projection as an experiment-only `debug.case/context`
prelude. It performs deterministic joins over `debug.nav` and
`debug.workspace/changed` and returns the terminal workflow error, directly
nested evaluation, generated program, single nested capability result, exact
frozen changed sources, typed relationships, and completeness metadata. It
does not name a cause, assign blame, or suggest a fix. The changed-component
ids are fixed in this fixture; a product version would receive its working set
from the host rather than hard-code it.

Both models received the same failed run id, generic diagnosis task, open
`debug.nav`, and four-model-call limit.

| Model | Debugger run | Result | Model / evidence calls |
| --- | --- | --- | --- |
| Luna | `cmd-3arkjfkac6pr80qyf6c19rgtjc` | correct cause and next change | 4 / 11 |
| DeepSeek | `cmd-3pryesyveyf3h60fe4rqf26d3x` | turn limit without report | 4 / 16 |

Luna called `debug.case/context` immediately. The first observation already
co-located the root program `(return (debug.nav/runs {"limit" 10}))`, the
workflow's accepted `debug.rlm/investigate` and `debug.rlm/finish` actions,
and the explicit failure. Luna spent two additional calls verifying errors,
activity, and turns, then correctly reported that the root returned a raw
navigation result rather than a recursive-workflow action. It recommended
using navigation only as intermediate evidence gathering and crossing the
root boundary with `investigate` or `finish`. This is the first open-ended PTC
run in the experiment to reproduce the manual coding-agent diagnosis within
the four-call criterion.

DeepSeek also called `debug.case/context` first, but then requested the same
complete projection again. It passed the projection's entire relationships
array to `debug.nav/follow`, whose contract expects one relationship map, and
used its final two calls to read boundary and child activity. It never
synthesized a report. A separate PTC private-analysis query confirmed that the
second-turn feedback contained 13,991 characters, including the faulty source,
accepted action protocol, and completeness field, with no truncation marker.
Its failure was therefore not caused by hidden or truncated decisive evidence.

The result supports a narrower conclusion than “case context fixes debugging”:
structural co-location can make an ordinary PTC agent behave like the manual
coding-agent investigation, but it is not sufficient across models. The
remaining friction is stopping and traversal ergonomics. Completeness metadata
did not stop DeepSeek, repeated context reads remained possible, and a typed
relationship was still easy to pass at the wrong container level.

The useful product direction is a general, structural incident projection—not
an RLM-specific diagnosis workflow—with safely followable links and clear
working-set provenance. Before designing it into `debug.nav`, run the same
unchanged projection shape against an unrelated failure. That experiment will
test whether the join is genuinely general or merely fits this action-protocol
canary. DeepSeek's behavior should be treated separately as evidence that a
model-agnostic interface may also need an explicit evidence-sufficiency or
bounded-synthesis affordance.

## Unrelated functional-failure generalization

The next run kept the structural packet fields, generic diagnosis request,
models, and four-call ceiling, but changed the incident to the adversarial
`deep` fixture (`cmd-0m05wjqpk4q7g5v61vhmb3gpm4`). This is an unrelated
transitive functional defect: the captured task requires subtotal plus 20,
`orders/place` enforces that invariant through `pricing.tax`, and the frozen
`pricing.rule` source adds 2. The working set contained all four mission
components, including the unused discount decoy, without identifying a suspect.

| Model | Debugger run | Result | Model / evidence calls |
| --- | --- | --- | --- |
| Luna | `cmd-2wa5pb2tkzv0kqbbsvvq5qz5w9` | returned, but misdiagnosed the explicit failure boundary | 4 / 20 |
| DeepSeek | `cmd-6aaqy1hv0mh85bmnqjy4srb1dt` | turn limit without report | 4 / 27 |

This did not fairly test whether the co-located evidence generalizes. Despite
the prompt reserving `return` for the final report, both models first emitted
`(return (debug.case/context ...))`. The result contract rejected the case map,
so one of four calls was spent correcting terminal ceremony before either model
could reason about the packet.

Luna then bound the context and printed it. The complete representation was
4,037 characters, but the print observation projected only 2,000; it included
the task's plus-20 requirement and boundary metadata but cut off the working-set
sources. The full value remained bound in evaluator memory, yet Luna never read
its `working_set`. It finally blamed an unspecified explicit-failure path and
recommended removing that path, which is not the demonstrated `pricing.rule`
defect.

DeepSeek bound the context without making it the program value, so its next
observation contained only `#'ctx`. It then printed the map; the following
observation exposed the `working_set` key but not the component source bodies.
Its last call recomputed context and printed relationships instead of returning.

PTC private analysis verified that evidence acquisition itself was complete.
Each context evaluation made four successful `prelude_sources` reads; the
captured `pricing.rule` item had source hash
`sha256:e9d90f3d300507fac49da9e0b06c844546c3d4866d0c66e7846d7a1e905ff2dd`.
The debugger runs simply did not surface and compare those sources within the
remaining model calls.

This exposes a more basic difference from a coding agent: startup context
should not itself be a model-chosen tool call. A coding agent begins after the
failed command with that context already present; it does not have to decide
whether to `return`, bind, print, or recompute it. The next experiment should
have a host workflow acquire the same non-diagnostic packet and place it in the
agent's initial context before model turn one. That changes transport and
budget accounting, not diagnostic content. Only then is another unrelated-case
run a valid test of projection generality.

One CLI friction item also appeared before provider activity: `--input` is
resolved as a confined reference relative to the manifest directory, not as a
path relative to the shell working directory. Supplying the repository-relative
path produced `application/reference_missing` with source `input.json`; using
the basename succeeded. The run guide says that `--input INPUT.json` replaces
the manifest input but does not state this resolution rule.

## Host-preloaded context experiment

The follow-up removed context acquisition from the model loop. An
experiment-local workflow now evaluates the same `debug.case/context` program
deterministically with `kernel/eval-with`, serializes its result into an
explicitly untrusted block in the initial user message, and then starts
`agent.core`. The model gets all four turns for reasoning and its separate
`investigate` mission contains only `debug.nav`; it cannot call or recompute
the case projection.

The matrix reused both incidents, the same generic diagnosis request, the same
result contract, and the four-call ceiling:

| Incident | Model | Debugger run | Result | Model / evidence calls |
| --- | --- | --- | --- | --- |
| invalid root action | Luna | `cmd-35qgq0yrpysaxge2h0maxejege` | correct cause and correction | 1 / 7 |
| invalid root action | DeepSeek | `cmd-4p08at6v1crhmt6b48b4hjgjms` | turn limit without report | 4 / 10 |
| transitive pricing defect | Luna | `cmd-2b5ve76z6cm1hwgzzn0xdty4z0` | correct cause and correction | 1 / 9 |
| transitive pricing defect | DeepSeek | `cmd-58ghmkqzm9f3jdcn1gnhe4vr9v` | correct cause and correction | 3 / 9 |

PTC private analysis verified the input boundary rather than assuming the
wrapper worked. Both protocol runs received a 14,609-character initial message
containing the generated `(return (debug.nav/runs ...))` source, accepted
`debug.rlm/investigate` action contract, working set, and no truncation marker.
Both pricing runs received a 4,963-character message containing the external
plus-20 requirement, `pricing.rule`, its `(+ subtotal 2)` source, the complete
working set, and no truncation marker.

Luna returned directly on turn one in both cases without calling `debug.nav`.
For the protocol run it distinguished a successful navigation call from the
workflow's rejection of its raw result and recommended crossing the boundary
with `debug.rlm/investigate` or `debug.rlm/finish`. For the pricing run it
followed the captured `orders -> pricing.tax -> pricing.rule` source chain,
computed 102 versus 120, and recommended changing the rule from 2 to 20.

DeepSeek also solved the unrelated pricing case without navigation. Its first
program invented a `DATA` file and unavailable `json/decode`; normal language
feedback listed the valid JSON functions. It then printed the diagnosis it had
already derived from the initial packet and returned the correct report on
turn three. This is avoidable model ceremony, but not missing incident evidence.

On the protocol case DeepSeek had no language, evaluation, or result-contract
failure. It defined an `open-run` helper, reopened the already projected run,
then read workflow activity and execution errors. It exhausted the limit without
synthesizing, despite the complete packet and consolidation instruction. That
remaining failure is evidence-size or stopping behavior, not acquisition.

The result clears the main confound and rejects the strongest overfitting
concern: the same structural startup shape enabled correct one-turn Luna
diagnoses on two unrelated failure classes and a correct DeepSeek diagnosis on
the functional defect. It does not yet establish a model-independent product.
The projection still uses experiment-specific working sets, and a complete
14.6K packet was not sufficient to make DeepSeek stop on the more abstract
protocol failure.

The next useful comparison is therefore smaller, not deeper: preserve the same
observed facts but project a compact incident header before the expandable
details—for example failure boundary, generated program, consuming contract,
and working-set references. Run only the failing DeepSeek/protocol cell first.
If it returns, packet salience was the issue; if it still explores, the runtime
needs a stronger bounded-synthesis affordance rather than more navigation APIs.

## Compact protocol-header experiment

The single failing DeepSeek/protocol cell was rerun with a generic compact
projection over the same acquired case map. It contained exactly four top-level
sections:

1. run and workflow failure;
2. the captured producer turn, including its original task and generated source;
3. directly nested activity; and
4. expandable working-set hashes, capability-call metadata, and completeness.

The projection removed component source bodies and capability results. It did
not add a cause, suspect, or repair. The producer's captured task already states
the accepted `debug.rlm/investigate` and `debug.rlm/finish` actions and that a
`debug.nav` result must not cross the boundary, so those exact observed contract
facts remained available without parsing or summarizing workflow source.

DeepSeek run `cmd-59mscnbxpswjma3167fsrdaf0v` again exhausted four model calls
without a report, using 11 evidence calls in total. PTC verified that its initial
message fell from 14,609 to 5,008 characters while still containing
`explicit_failure`, the generated `(return (debug.nav/runs ...))` source, both
accepted action names, and no source body or truncation marker.

Its trajectory was entirely valid navigation:

1. `debug.nav/open` on the supplied run;
2. `execution_errors` for the child mission evaluation;
3. workflow `activity`; and
4. `capability_calls` for the navigation call.

There were no language, evaluation, or result-contract corrections. The fourth
feedback explicitly marked the next program as the final turn and required
`return` or `fail`; DeepSeek issued another `debug.nav/read` instead. Compactness
made the traversal more targeted than the full-packet run but did not produce a
stopping decision.

This falsifies packet size as the primary explanation for this cell. More
evidence aggregation or navigation helpers are unlikely to help. The smallest
remaining control is the same compact initial packet with no `debug.nav` in the
investigation mission. If DeepSeek then returns the correct protocol diagnosis,
tool availability is inducing unbounded verification and a product path needs a
host-enforced synthesis phase. If it still fails, the model cannot reliably
synthesize this abstract contract mismatch from the packet under the current
prompt and four-call budget.

## Synthesis-only control

The same DeepSeek/protocol compact packet was then passed to a separate
`synthesize` mission with an empty component set and no selected mission
providers. The initial instruction explicitly described this as a synthesis
phase with no evidence-navigation functions. Context acquisition, packet
contents, model, result schema, and four-call ceiling were unchanged.

Run `cmd-160nqrcyc20atsavh86bztte38` returned the correct diagnosis in two model
calls and used seven evidence calls, all from deterministic context acquisition.
It made no investigation calls. PTC verified a 4,975-character untruncated
initial message containing the generated navigation source, both accepted
actions, and the no-navigation phase instruction.

DeepSeek's first program already attempted to report that the mission returned
raw `debug.nav/runs` data and the workflow subsequently rejected it. The program
had an unclosed string at line 2, column 341, so normal parse-error feedback
requested a corrected program. On turn two it returned a contract-valid report
that:

- identified the raw navigation result as neither `debug.rlm/investigate` nor
  `debug.rlm/finish`;
- cited the returned child evaluation, exact generated source, producer task,
  and explicit workflow failure; and
- recommended returning one of the protocol actions instead.

The successful run took 164 seconds, so removing navigation improved behavioral
completion rather than provider latency. Together with the paired compact run,
this is evidence that available tools induced continued verification for this
model and incident: with `debug.nav`, four valid reads and no report; without
it, an immediate diagnosis attempt and a corrected report.

This does not justify removing navigation from general debugging. Some incidents
need evidence absent from their startup projection. It does support an explicit
phase boundary: a bounded exploration phase may use `debug.nav`, but a separate
host-enforced synthesis phase should receive the accumulated incident packet or
notebook with no navigation authority. Merely printing `FINAL TURN` while
leaving evidence tools callable was not sufficient for DeepSeek.

The remaining product question is how to carry selected exploration findings
into that synthesis phase without exposing raw private transcripts or requiring
the model to obey a finish convention. That is a narrower runtime/workflow
problem than adding more graph traversal operations.

## Host-enforced phased-agent experiment

The follow-up implemented the boundary as a domain-blind `agent.core`
primitive rather than another debugger prelude. `run-phased-result-value`
accepts one to eight ordered `{mission, max_turns, instruction?}` phases with a
combined 128-turn ceiling. It retains the exact assistant tool call and tool
observation messages, rebuilds the system prompt from the next mission's
authority, and appends a host-authored transition instruction. A `return` ends
a non-final phase but is retained as evidence; only the final phase may satisfy
the application result contract and complete the agent. This prevents a
plausible but semantically unchecked exploration report from bypassing the
restricted synthesis mission.

Integration coverage exercised three distinct paths:

- an intermediate observation consumes the last exploration turn and crosses
  the boundary with its assistant/tool correlation intact;
- a non-final `return` becomes retained evidence rather than completing the
  workflow; and
- a three-phase plan gives its middle phase a phase-local budget rather than
  the final workflow's `return`/`fail` instruction.

The real-model experiment used two exploration turns with `debug.nav`, two
synthesis turns with an empty mission, the existing host-preloaded structural
packet, and the same compact four-field report contract. Every quality verdict
below came from `private-run-analysis-v1`, including turn completeness, mission
identity, generated source, and retained phase-transition messages:

| Incident | Model | Debugger run | Model / subordinate evaluations | PTC verdict |
| --- | --- | --- | --- | --- |
| invalid root action | DeepSeek | `cmd-42zx46szssetmeefh4meyeardk` | 4 / 5 | correct diagnosis after enforced synthesis |
| transitive pricing defect | Luna | `cmd-4m9r49q4s7fmq2kb9hy02gg46a` | 3 / 4 | correct cause and smallest correction |
| ambiguous contract failure | Luna | `cmd-2z6czj98b6vchedfs1vpepfq32` | 3 / 4 | correct abstention |
| ambiguous contract failure | DeepSeek | `cmd-13sm3hk1d395fs2e1w6hfc5650` | 4 / 5 | completed, but confidently wrong |

DeepSeek's protocol trajectory is the direct paired confirmation. It spent
both exploration turns on `debug.nav/open` and `debug.nav/read`. The first
synthesis program repeated a `debug.nav/read`; the empty synthesis mission
rejected that stale call as an unknown namespace. Its final turn then returned
the correct report: the child evaluation successfully returned raw
`debug.nav/runs` data, but the workflow required `debug.rlm/investigate` or
`debug.rlm/finish`. The retained transcript was sufficient; no notebook,
curator, or copied evidence API was needed.

Luna's pricing exploration found and returned the right provisional report on
its second turn. The host did not accept it early. The tool-free phase received
that exact report and independently returned the same causal chain:
`orders/place` requires subtotal plus 20, `pricing.tax` delegates to
`pricing.rule`, and the frozen rule adds 2. The ambiguity run followed the same
path and preserved the safe conclusion that a `const` violation at `total`
does not reveal the required constant or distinguish a faulty implementation
from a faulty contract.

DeepSeek demonstrates the limit of phase control. Enforced synthesis made it
stop, but it misread the same `const` violation as proof that `orders/place`
used the wrong map-key representation. It proposed changing a string key to a
keyword key even though that would not change the JSON result and would not
satisfy the hidden total constraint. The boundary therefore solves authority
and stopping behavior, not causal correctness or calibrated abstention.

### Conclusions

1. Exact correlated messages are a sufficient handoff mechanism for this
   scale. A model-authored notebook or summarizer is not yet justified.
2. Phase authority belongs in the generic agent loop. A debugger-specific
   `finish` convention is weaker because the model can ignore it while tools
   remain callable.
3. Tool removal may initially cause one stale call. Ordinary evaluation-error
   feedback recovered within the synthesis budget; the host did not need to
   silently rewrite the program.
4. A forced report is not evidence of a correct diagnosis. General analysis
   still needs an explicit diagnosis-versus-insufficient-evidence decision and
   host-side checks for mechanically testable claims before producing a repair
   candidate.
5. The next experiment should keep this phased loop fixed and vary the final
   contract, not add navigation. A compact report with an explicit
   `decision` enum plus a deterministic check of any proposed target/change
   can test whether DeepSeek abstains rather than filling a mandatory diagnosis
   slot with an invented explanation.

### PTC-analysis friction

The first unattended analysis attempt placed `--private-output` in a directory
that was an ancestor of the trace and inspection resource directories. The CLI
correctly rejected the unsafe layout, but reported only the generic
`arguments/invalid_arguments` diagnostic. Moving the output to a physically
separate sibling root worked. The diagnostic should identify the conflicting
paths and the required separation, as the guide already explains.

## Explicit decision and host-gated repair experiment

The next comparison kept the phased loop, exact correlated transcript, and
evidence access unchanged. Only the final contract changed. The synthesis
mission had to return one of two explicit decisions:

- `propose-change`, with an exact component, base-source hash, complete
  candidate source, and supporting evidence; or
- `insufficient-evidence`, with the missing evidence named explicitly.

A proposal was not treated as a fix. It was passed unchanged to `mix
ptc.repair`, which applied the existing G1--G4 compatibility gates and then ran
a host-owned deterministic validation suite. The validator invoked the target
function through `kernel/eval-with`; it had no provider configuration and made
zero LLM calls. This isolates candidate behavior from the debugger model and
from a second model's judgment.

| Incident | Model | Debugger run | Model outcome | Host outcome |
| --- | --- | --- | --- | --- |
| transitive pricing defect | Luna | `cmd-3bw7s35svxnfaz8vr25v5g452q` | correct `propose-change` | G1--G4 and all three behavioral cases passed |
| ambiguous contract failure | DeepSeek | `cmd-6metqjtezfmg2bk4p7mgvyhfe2` | no decision within four turns | no candidate |
| ambiguous contract failure | DeepSeek | `cmd-32gtth60sfgqaemjwa0pqcgghj` | wrong `propose-change` after one extra synthesis turn | G1--G4 passed; behavioral case rejected it |

For pricing, Luna identified `pricing.rule/apply-standard`, supplied the exact
base hash, and changed `(+ subtotal 2)` to `(+ subtotal 20)`. The three
deterministic cases covered 100, 0, and -10. PTC private analysis of validation
runs `cmd-32xd0awqr6sk6hgfqzb9069tjt`,
`cmd-67d9mwkhjnw3dsqemh9hecvn94`, and
`cmd-2k6dnv96wawc5yhf0drpz0txrx` verified the candidate override and a clean
zero-LLM execution in each case.

The four-turn DeepSeek ambiguity run exhausted its budget while trying
nonexistent navigation and data-query functions in synthesis. One additional
synthesis correction turn was allowed as a bounded stopping rule. It produced
a contract-valid but incorrect candidate: change `orders/place` from a string
`"total"` key to a keyword `:total` key. Its cause claimed that JSON required
the keyword representation and that the observed `const` violation proved it.
Neither claim follows from the evidence, and both key forms project to the same
JSON key.

That candidate still compiled, preserved prompt-visible exports, did not widen
effects, and preserved dependencies, so G1--G4 all passed. The deterministic
case rejected it with `result_mismatch`. PTC private analysis of validation run
`cmd-4efbkxcv5q697cmphy2c989634` verified that the exact override was active,
the run completed normally with no execution errors and zero LLM calls, and its
result remained `{"total": 100}` instead of the host-required
`{"total": 120}`. The gate therefore converted a confident hallucinated repair
into a retained rejected candidate rather than a self-applied change.

### Conclusions

1. An explicit abstention enum did not calibrate DeepSeek on this ambiguity.
   The richer schema increased correction pressure, and an extra turn merely
   made the wrong explanation structurally valid.
2. Static compatibility is necessary but insufficient. G1--G4 answer whether
   a candidate can safely enter the environment, not whether it repairs the
   observed behavior.
3. A host-owned, no-model behavioral suite is a useful acceptance boundary.
   The model may diagnose and author; the host owns accepted versus rejected.
4. The general debugger result should therefore permit an optional candidate,
   but the durable lifecycle state should be host-authored: diagnosed,
   insufficient evidence, candidate rejected, or candidate validated. It
   should not rely on the model to report its own success.
5. The next small increment is not more prompt tuning. It is to make a rejected
   validation result available as bounded evidence to a later repair phase and
   test whether one correction attempt improves the candidate without changing
   the investigation protocol.

### Repair-path friction

The first valid pricing candidate passed G1--G4 and was materialized, then
`ptc.repair` failed with `validation_destination_unavailable` because the
parent of `--validation-out` did not already exist. Creating that parent and
rerunning succeeded. The command should validate or create the destination
before publishing a candidate, and the diagnostic should name the missing
parent path. As implemented, an incidental output-directory problem is
reported only after the operator sees `candidate ready`, which makes the
acceptance boundary harder to interpret and automate.

## Bounded validation-feedback correction experiment

The rejected DeepSeek ambiguity candidate was used for one bounded correction
experiment. The new run received:

- the original immutable incident projection and complete frozen working-set
  sources;
- its previous candidate and stated cause;
- the host-authored validation facts: G1--G4 passed, input subtotal 100,
  expected `{"total": 120}`, actual `{"total": 100}`, and
  `result_mismatch`; and
- the unchanged propose-change-or-insufficient-evidence contract.

The correction phase had no `debug.nav` authority and a two-turn ceiling. The
task explicitly preserved the causal standard: a new candidate still required
evidence distinguishing one faulty implementation, and the model must not
guess merely to satisfy the observed case. This matters because the additional
expected value proves that the previous key rewrite was ineffective but still
does not distinguish `pricing.base`, `pricing.tax`, or `orders` as faulty.

DeepSeek run `cmd-40bj4q76nwsj5r86frzezdfcbh` exhausted both turns without a
decision. PTC private analysis verified two complete model exchanges and no
missing or ambiguous reconstructed evidence:

1. Although the prompt already contained the complete `pricing.base` source,
   the model said it needed to investigate and called
   `(doc "pricing.base/amount")`. The empty synthesis mission returned no
   documentation.
2. The feedback marked the next program as the final turn and required
   `return` or `fail`. The model called `(dir)` instead, and the host ended the
   run with `runtime_limit_exceeded`.

No candidate existed, so G1--G4 and behavioral validation correctly did not
run. Adding another turn would weaken the stated stopping rule rather than
test repair feedback.

### Conclusions

1. Validation rejection is useful evidence, but merely serializing it into a
   new task did not make this model revise or abstain. The remaining failure is
   again phase stopping, not missing source.
2. An empty mission is prelude-free, not terminal-only. Core introspection
   forms such as `doc` and `dir` remain available, so a model can continue
   exploratory ceremony even when the host says synthesis is final.
3. There is no supported cross-run continuation path from `ptc.repair` back
   into the exact prior agent transcript. `run-phased-result-value` preserves
   correlation inside one run, but validation happens after that run closes.
   This experiment therefore had to start a new run and reserialize the prior
   decision and rejection into its initial task.
4. A general repair lifecycle needs a host-authored validation-feedback
   envelope and an explicit terminal-only correction phase. The latter should
   enforce the parsed action shape, not depend on another natural-language
   `FINAL TURN` reminder.
5. The next experiment should be one paired control on the same packet: a
   generic terminal-only phase that accepts only `return` or `fail`, with one
   correction feedback turn for a rejected nonterminal program. Success would
   establish that validation feedback can change the decision; failure would
   show that this model cannot safely correct the ambiguous case under a
   bounded loop.

### Correction-path friction

The manifest label vocabulary accepts `stage: validating` but not a distinct
`correcting` stage, so the experiment identity can only live in the run name.
More importantly, the runtime has no first-class handoff joining a rejected
candidate, its exact authoring transcript, and the host validation report into
a later phase. A self-repair host currently has to invent this lifecycle and
private-evidence serialization outside PtcRunner.

## Parsed terminal-only correction experiment

The paired follow-up added one generic phase policy to
`agent.core/run-phased-result-value`: `terminal_only: true`. The policy is
enforced by the host's existing source-check path before mission evaluation.
It uses the PTC-Lisp parser, not source-text matching, and admits only a single
top-level `return` or `fail` form. A rejected correlated tool call receives one
bounded correction message when the phase still has a turn. An integration
test deliberately places `(return 42)` inside a string passed to `doc`; the
program is rejected without consuming a subordinate evaluation, while the
following `(return 42)` is admitted.

The live comparison reused the exact ambiguous DeepSeek correction packet,
model, evidence, result contract, and two-turn budget. Only the terminal-only
phase policy changed.

The first run, `cmd-6j3ge6n3tjgf0avm7xc2z4a0jm`, did not exercise the policy.
PTC private analysis reconstructed two complete provider exchanges in which
the provider consumed the full 4096-token output allowance but returned empty
assistant content and no tool call. There were no generated programs, source
checks, or mission evaluations. Both turns therefore became protocol errors
and the run exhausted its budget. This is provider/model variance, not evidence
for or against terminal enforcement.

One identical rerun was allowed by the stopping rule. Run
`cmd-7tpmc98j0a9fdkpzy2xpfj6v5k` reached the new boundary: its canonical trace
records two source checks followed by two synthesis evaluations, both returned,
and two result-contract checks. Thus both generated programs were parsed as
terminal forms and evaluated. Neither value satisfied the result contract, so
the terminal contract-failure path closed the run. No candidate was available
for G1--G4 or behavioral validation.

The second run then exposed a more serious observability failure. Its private
inspection sink failed while handling the terminal result-contract failure.
The command wrote the private canonical trace but no inspection artifact or
result. The generic error does not identify the rejected record or validation
cause. PTC's public analysis profile ignores private traces, while
`private-run-analysis-v1` requires the missing inspection file. Consequently
PTC could not analyze the surviving canonical trace; the counters above were
recovered with a direct read only after the required PTC attempt failed. The
exact model programs and rejected values were lost with the inspection
artifact.

### Conclusions

1. Parsed terminal enforcement closes the authority and stopping hole: when
   the model produced programs, both were terminal and no exploratory `doc` or
   `dir` evaluation occurred.
2. Terminal shape is not structured correctness. DeepSeek still failed to
   produce a contract-valid diagnosis or abstention within two turns.
3. The semantic comparison is inconclusive because neither rerun produced a
   candidate: one failed at the model protocol boundary and the other at the
   result contract, followed by inspection loss. More reruns would violate the
   narrow stopping rule and invite prompt/model lottery.
4. Keep `terminal_only` as a generic phase primitive, not a debugger-specific
   prelude. The next repair increment should be the host-authored cross-run
   validation-feedback envelope already identified above, paired with this
   primitive.
5. Before relying on self-analysis, private canonical traces must remain
   analyzable when inspection publication itself fails. Otherwise the failure
   most in need of debugging removes the only supported PTC analysis path.

### Terminal-correction friction

An inspection assertion added while diagnosing the failure established that
internal `kernel-check-source` calls are intentionally absent from inspection
records, so the new `require: terminal` ledger projection was not the cause.
The remaining failure is reported only as `inspection_sink_unavailable` plus
`inspection_publication_failed`; neither diagnostic identifies the record that
poisoned the sink. Because private analysis cannot fall back to the retained
private trace, this class of publication failure currently requires an
out-of-band trace reader and still loses the generated source and capability
payloads needed for causal diagnosis.

## Host-authored validation-feedback envelope experiment

The next increment removed the operator-written prose handoff. `ptc.repair`
now writes owner-only `feedback.json` beside its aggregate validation report.
The artifact has four top-level concepts:

- `version` and `kind` identify the contract;
- `state` is host-authored lifecycle state (`candidate-rejected` or
  `candidate-validated`);
- `candidate` labels the previous model report as
  `model-authored-untrusted`; and
- `validation` labels the host comparison as `host-authored` and retains each
  case's input, expected value, available actual value, status, reason, and
  artifact references.

The command generated this envelope directly by rerunning the rejected
ambiguous DeepSeek candidate through the reconstructed frozen target. The
candidate bound to the exact original `orders` source hash
`sha256:e9181edf...ce9cf0`, passed G1--G4, and failed the observed case with
input `{"subtotal":100}`, expected `{"total":120}`, actual
`{"total":100}`, and `result_mismatch`. No person summarized or copied those
facts into a prompt.

An experiment workflow then consumed that exact `feedback.json` as
`--private-input`, reacquired the immutable incident projection by
`diagnosed_run_id`, and passed both packets to a two-turn terminal-only
correction phase. The envelope and workflow instruction remain domain-blind;
the experiment manifest deliberately binds the ambiguous fixture's context
mission and model policy.

Run `cmd-29wsm8d6cmhhpwatzhpgz4yw0z` reached the model twice. Its surviving
private canonical trace records two successful parsed source checks, two
returned synthesis evaluations (468 and 456 source bytes), and two failed
result-contract decisions. Thus the cross-run handoff and terminal boundary
both worked mechanically, but DeepSeek still produced no contract-valid
candidate or abstention in the fixed budget.

The run then reproduced `inspection_sink_unavailable` at exactly the same
terminal result-contract-failure transition as the prior experiment. The
required PTC private-analysis attempt failed during profile setup because the
inspection directory contained no artifact. The canonical trace could prove
event order and counters, but the exact two decisions were again lost. No
second live correction was allowed: it would be another model sample rather
than evidence about the envelope seam.

### Root cause and repair

The recurring sink failure was model-independent. Authenticated result-contract
details retain `CommandContractAuthority` and `CommandPath` structs internally.
Those structs are correct for the runtime error boundary but are not JSON
inspection values, so emitting the workflow `execution-error` poisoned the
sink and replaced the real `result_contract_failed` outcome with
`inspection_sink_error`.

The spike now projects only the inspection copy: it drops the internal
authority attestation and renders each already-authorized path as a JSON
Pointer. The runtime error keeps its authenticated structs unchanged. A
regression exercises one-turn and four-turn exhaustion with inspection enabled
and verifies both the original failure taxonomy and the retained `/sum`
diagnostic. This fix prevents future terminal-correction runs from destroying
their own evidence, but it cannot recover the two already-lost model values.

### Conclusions

1. `feedback.json` is the missing cross-run data seam. It removes manual prose
   serialization while preserving the crucial authority distinction between a
   model candidate and host validation facts.
2. The envelope alone does not make DeepSeek correct or abstain. On this
   ambiguous case it produced two terminal, contract-invalid values, matching
   the earlier prompt-serialized experiment at the level still observable.
3. The generic product primitive should remain a private artifact emitted by
   validation. The experiment-specific launcher that chooses a context mission,
   model, contract, and turn budget is not yet a general repair orchestrator.
4. The next experiment should not add another prompt or rerun this case. It
   should test a host loop that accepts `feedback.json` plus an explicit
   correction manifest, launches exactly one correction run, and if a new
   candidate exists sends it back through `ptc.repair`. Lifecycle transitions
   remain host-authored; the model never declares itself validated.
5. PTC analysis fallback for a missing inspection artifact remains necessary
   even with the producer fixed. Older runs and unrelated publication failures
   can still leave a private canonical trace as the only surviving evidence.

## One-shot host repair loop experiment

The next increment tested the lifecycle rather than adding another model
prompt. `repair-loop.exs` accepts a strict configuration containing an existing
owner-only `feedback.json`, an explicit correction manifest, the target
manifest, and a bounded validation suite. It creates one owner-only output
root, runs exactly one correction, and owns the terminal state:

- `correction-failed` for a failed run or malformed decision;
- `correction-abstained` for a structurally valid insufficient-evidence report;
- `candidate-rejected` when `ptc.repair` materializes but host validation
  fails;
- `candidate-validated` only after G1--G4 and every named host case passes; or
- `repair-failed` for an operational/static-gate failure after proposal.

The model cannot write any of those states. A `propose-change` value is stored
as owner-only untrusted input and passed to the existing `ptc.repair`; an
abstention stops before materialization. The loop records correction traces,
inspection, result, envelope, candidate, validation evidence, and a compact
host-authored lifecycle report beneath the output root. It does not promote,
modify the target checkout, rerun automatically, or guess after failure.

Provider-free controls established both sides of the branch. The abstention
fixture ended `correction-abstained` with no candidate directory. The proposal
fixture selected the known `pricing.base` component, passed G1--G4, produced
`total: 120` for the host's observed input, and ended `candidate-validated`.
Its validation envelope names correction run
`cmd-474pbs7bykcgnn2kpajjzwksk2` as author and preserves the model-versus-host
authority split. These controls prove host-loop mechanics only; the candidate
content is deliberately deterministic and domain-specific.

### Single DeepSeek correction

The only live sample used the unchanged domain-blind feedback-correction
manifest, the exact rejected-candidate feedback envelope, and DeepSeek. Host
loop output `/private/tmp/ptc-repair-loop-deepseek-20260815` ended
`correction-failed` with exit status 7 for correction run
`cmd-48fg14tapr9szpy227d85kzaqy`. No candidate or validation run was created.

The verdict came from `private-run-analysis-v1`, not a direct inspection-log
read. PTC correlated a complete canonical trace with 42 inspection records,
two complete model exchanges, three generated sources, and the original
workflow `result_contract_failed` error. Both turns generated the identical
program:

```clojure
(return :insufficient-evidence)
```

The first value failed the report schema at the root: the discriminator was
`decision`, but the JSON value kind was a string rather than an object. The
model received that exact structural diagnostic and repeated the same scalar
on its final turn. Semantically this is the safe conclusion for the ambiguous
fixture; mechanically it is not a usable correction report because it omits
the cause, evidence, and missing evidence. The loop correctly did not coerce
it into a host-authored abstention.

This run also confirms the prior inspection fix under the exact failure that
used to poison publication. The private analysis profile can now see the
generated programs, feedback, model exchanges, and original result-contract
diagnostic rather than an `inspection_sink_unavailable` replacement.

### Friction and conclusions

1. The host loop is enough to close one bounded repair cycle; a new public
   `debug.nav` operation is not required for orchestration. Evidence discovery
   stays in the explicit correction manifest, while lifecycle and validation
   stay with the host.
2. The remaining blocker in this cell is terminal protocol, not evidence or
   stopping. DeepSeek chose the right branch twice but treated the branch name
   as the whole value. More prompt text would repeat an already-delivered type
   diagnostic. A later comparison should test host-encoded terminal actions or
   structured-output synthesis, where `abstain` and `propose` cannot be
   confused with their report payloads.
3. The result must not be auto-coerced. Turning
   `:insufficient-evidence` into a valid abstention would erase the required
   explanation and allow a model shorthand to cross a host boundary as if it
   were complete evidence.
4. Private input staging has a sharp edge: the generic owner-only temporary
   sibling helper creates a dot-prefixed directory, but application references
   exclude that path and `--private-input` then fails as `reference_missing`.
   The working loop uses a random owner-only, non-dot sibling, matching
   `ptc.repair` validation staging.
5. Unattended PTC analysis again required an already-created session trace
   directory, and its directory must be pairwise separate from both resource
   directories and the `--private-output` parent. The generic physical-
   separation error did not identify the conflicting pair. After using sibling
   output and session roots, analysis succeeded without further workaround.
