# Choose a workflow shape

Choose how to split a task between missions, agent loops, and trusted workflow
code. The shapes compose — a real design usually combines two or three.

| Shape | Reach for it when | Runnable form |
| --- | --- | --- |
| [One bounded question](#one-bounded-question) | a single read-only question over data you already hold | [`support-triage`](https://github.com/andreasronge/ptc_runner/tree/main/examples/support-triage) |
| [Domain rules as mission code](#domain-rules-as-mission-code) | the policy is deterministic — thresholds, scoring, routing | [tutorial step 2](designing-agent-workflows.md#step-2-move-the-rules-into-mission-code) |
| [Specialists as missions](#specialists-as-missions) | stages need different data, tools, or rules | [`support-triage/03-specialists`](https://github.com/andreasronge/ptc_runner/tree/main/examples/support-triage) (data) and [`named-mission-reader-writer`](https://github.com/andreasronge/ptc_runner/tree/main/examples/named-mission-reader-writer) (tools) |
| [Review the work](#review-the-work) | a stage's answer must be checked before anyone acts on it | [`dabstep-fraud`](https://github.com/andreasronge/ptc_runner/tree/main/examples/dabstep-fraud) |
| [Plan, then act](#plan-then-act) | the task ends in an effect | [debug-a-failed-run repair agent](https://github.com/andreasronge/ptc_runner/tree/main/examples/debug-a-failed-run) |
| [Parallel fan-out](#parallel-fan-out) | items are independent — one call per document or ticket | [tutorial step 07](https://github.com/andreasronge/ptc_runner/tree/main/examples/kernel-tutorial) |
| [Contracts instead of parsing](#contracts-instead-of-parsing) | anything downstream consumes the answer | [support-triage step 03](https://github.com/andreasronge/ptc_runner/tree/main/examples/support-triage) |
| [Effects at the edge](#effects-at-the-edge) | the workflow writes somewhere | [named-mission-reader-writer](https://github.com/andreasronge/ptc_runner/tree/main/examples/named-mission-reader-writer) |

## One bounded question

One mission, one `agent.core/run`, no tools. Reach for this first: connecting
tools or adding stages only adds surface.

## Domain rules as mission code

Ship deterministic policy as a prompt-visible mission component, not as prompt
text or one-call-per-rule tools. The model composes the functions in one
program and the rules stay reviewable. Prompt-stated rules drift; tool-relayed
rules drag every intermediate value through the model's context.
[the customization guide](components-and-preludes.md) has the contract.

## Specialists as missions

Give each stage a named mission and let one trusted workflow drive a loop per
stage. The mission decides what a specialist can see; the workflow decides what
crosses between stages. Inspect failures with `agent.core/run-outcome`; on abort,
use the [abort helper](../agent-library-reference.md#agent-core-fail-outcome) to
preserve its diagnostic. Select handoff contracts for consumed values.

## Review the work

Keep the exact programs a stage ran (`agent.core/run-outcome` with
`"retain_programs"`) and hand them, with the input and returned evidence, to a
reviewer mission that has the same read-only tools and measures the answer
itself. Compare the two measurements in workflow code. A model can describe a
defect, but publishing stays a workflow decision.

## Plan, then act

`agent.core/run-phased-result-value` runs ordered phases in different missions
on one transcript. The planning phase's mission simply has no write tool, so the
plan cannot execute early.

## Parallel fan-out

Fan out with `pmap` or `pcalls` from the trusted workflow instead of looping
turn by turn. Bounded parallelism is a limits decision: every branch draws from
the same admission queue, so size the shared limits for the whole fan-out. Use
sequential stages whenever one stage's output feeds the next.

## Contracts instead of parsing

Declare the shape as a manifest `result_schema` and produce the value with
`agent.core/run`. Invalid candidates get bounded correction
feedback while turns remain, and the run fails honestly rather than shipping a
malformed report.

## Effects at the edge

Keep writes in the last possible stage, behind an explicitly allowed effect
tool. Never automatically retry an indeterminate write — a timeout may mean the
effect happened, so reconcile first. Read tools are retry-safe by comparison,
but still deserve least privilege: every readable source is data the model can
observe, leak into a later stage, or spend budget on.

## Going further

The [Design an agent workflow](designing-agent-workflows.md) tutorial walks the
first three shapes on one scenario. For a chapter-by-chapter course that grows a
multi-specialist agent, see the
[PtcRunner tutorial series](https://github.com/andreasronge/ptc_runner_tutorial).
