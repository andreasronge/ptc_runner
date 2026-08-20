# Choose a workflow shape

> **Audience:** application authors deciding how to split a task between
> missions, agent loops, and trusted workflow code.

Most agent applications combine a few recurring shapes; this page names each
one, says when to reach for it, and points at a runnable demonstration.

The shapes compose — a real design usually combines two or three of them.

## One bounded question

Grant the data, ask the question, read the answer. One mission, one
`agent.core/run`, no tools. Reach for this first: if a task is a single
read-only question over data you already hold, connecting tools or adding
stages only adds surface. The
[Design an agent workflow](designing-agent-workflows.md) tutorial starts with
exactly this shape, and the shipped
[`support-triage`](https://github.com/andreasronge/ptc_runner/tree/main/examples/support-triage)
example is its runnable form.

## Domain rules as mission code

When the task has deterministic policy — thresholds, scoring, routing tables,
formulas — ship it as a prompt-visible mission component instead of prompt
text or one-call-per-rule tools. The model composes the functions in one
program; the rules stay in code you can review and test. Prompt-stated rules
drift; tool-relayed rules drag every intermediate value through the model's
context. See step 2 of the
[tutorial](designing-agent-workflows.md#step-2-move-the-rules-into-mission-code),
and [Customize agent components](components-and-preludes.md) for the
component contract.

## Specialists as missions

When stages of a task need different data, tools, or rules, give each stage a
named mission and let one trusted workflow drive a loop per stage. A mission
boundary is an authority decision, not a prompt decision: a specialist can
only see what its mission was granted, and the workflow chooses what crosses
between stages. Use `agent.core/run-outcome` when the workflow must handle a
specialist's failure as data. Runnable forms:
[`support-triage/03-specialists`](https://github.com/andreasronge/ptc_runner/tree/main/examples/support-triage)
(different data per specialist) and
[`named-mission-reader-writer`](https://github.com/andreasronge/ptc_runner/tree/main/examples/named-mission-reader-writer)
(different tool grants per specialist).

## Plan, then act

When a task ends in an effect, split deciding from doing:
`agent.core/run-phased-result-value` runs ordered phases in different
missions while keeping one transcript. The planning phase's mission simply
has no write tool — the plan cannot execute early because the authority to
act does not exist yet — and the acting phase carries the plan forward. The
phase contract, including `terminal_only` for decision-only final phases, is
specified in the [agent library reference](../agent-library-reference.md).

## Parallel fan-out

When items are independent — one specialist call per document, per ticket,
per case — fan out with `pmap` or `pcalls` from the trusted workflow instead
of looping turn by turn. Bounded parallelism is a limits decision: size the
shared provider and evaluation limits for the whole fan-out, since every
branch draws from the same admission queue. See the
[kernel limits reference](../kernel-limits-reference.md) for the concurrency
rows, and use sequential stages instead whenever one stage's output feeds the
next.

## Contracts instead of parsing

When anything downstream consumes an agent's answer, declare the shape as a
manifest `result_schema` contract and produce the final value with
`agent.core/run-result-value`. Invalid model candidates receive bounded
correction feedback while turns remain, and the run fails honestly rather
than shipping a malformed report — so the result's shape is enforced by the
runtime, never reconstructed by regexes. The contract profile is defined in
[Configure an application](../reference/application-manifest.md#validate-inputs-and-results).

## Effects at the edge

Keep writes in the last possible stage, behind an explicitly allowed effect
tool, and never automatically retry an indeterminate write — a timeout may
mean the effect happened. Reconcile the unknown outcome first, then continue.
Read-side tools can be granted freely by comparison, which is why the earlier
shapes stay read-only as long as possible. [Connect an MCP
tool](connecting-tools-with-mcp.md) covers effect metadata and `allow` lists.

## Going further

The [Design an agent workflow](designing-agent-workflows.md) tutorial walks
the first three shapes on one scenario. For a chapter-by-chapter course that
grows a multi-specialist agent — including parallel specialists, plan/act
phases, and effect handling — see the
[PtcRunner tutorial series](https://github.com/andreasronge/ptc_runner_tutorial),
which rebuilds the scenarios of the Claude Agent SDK cookbook on PtcRunner.
