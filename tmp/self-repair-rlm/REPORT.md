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
