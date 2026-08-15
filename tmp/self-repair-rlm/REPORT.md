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
