# Debug navigation bench

Work in progress. A maintainer lab, not a shipped example. It records the
2026-09-04 revisit of `examples/debug-a-failed-run` and the three measurement
rounds that followed: how well a model-driven debugger navigates a frozen
capture through `debug.nav`, across three failure shapes, two prompt regimes,
and two models. Everything below was measured on `ptc 0.14.0 (ad54de32,
clean)`, byte-identical to main at the time, through OpenRouter.

Issues filed from this work: #1809 (observation previews truncate every
nested page by depth), #1810 (a private run that reaches `normal_event_count`
dies as `event_sink_unavailable` and discards every artifact), and two items
added to #1800 (analysis-profile argument errors).

## What the shipped example does today

| Arm | Result on the release binary |
| --- | --- |
| `target` + `debugger` (deterministic) | exactly as documented |
| `repair-agent`, all three arms | correct on the first try, one model call each, $0.0006 to $0.0009 |
| `debugger-agent` (14 turns, DeepSeek) | `turn_limit_exceeded` in 2 of 2 runs, no report |

The repair proposals promote through the stable CLI without the README's
hand-written descriptor and checksum:

```console
ptc materialize debug-a-failed-run/target.ptc-project.json --target-mission pricing \
  --component pricing.rule --out candidate \
  --from-result debug-a-failed-run/repair-agent/.ptc/results/RUN.private.json \
  --result-pointer /candidate_source
ptc run debug-a-failed-run/target.ptc-project.json --component-override-descriptor candidate/descriptor.json
```

`mix ptc.repair` with the shipped `suite.json` files ran 3 of 3 held-out cases
green for both propose arms. Neither command is mentioned in the example
README, and `ptc repair` is not a stable command.

The debugger-agent fails because every `debug.nav` page is preview-truncated
by depth, so each hop costs two turns: one to follow, one to `println` the
fields out of `*1`. `max_observation_chars` cannot lift the depth cap
(#1809). Sixteen turns are needed for the four-component closure; the arm
grants fourteen.

## The bench

Three targets from the example, each captured once:

- `t`: `target`, the defect is in `pricing.rule`, inside the dependency closure of the failing call;
- `amb`: `target-ambiguous`, two constants sum to the wrong total and nothing pins either, so the right answer is to abstain;
- `wc`: `target-workflow-control`, both missions are correct and the defect is in the workflow's routing, outside any dependency closure.

Three prompt regimes, all domain-blind:

- `p1`: the shipped debugger-agent task. It prescribes the traversal order and stops the model at the first source with no dependency.
- `p2`: names the collections and relationship types, prescribes no order.
- `p3`: `p2` plus verdict definitions (a diagnosis names exactly one read source inconsistent with its own contract or the required values; two candidates that could each absorb the discrepancy is insufficient evidence), a decision-based stopping rule, a sentence that generated programs are authored by the workflow environment, `consolidate_at_turns_remaining` 6, and two terminal actions selected into the evidence mission from `debug.terminal.clj`:
  - `diagnose` requires the frozen source's `source_hash` and a verbatim `excerpt`; it refuses a hash the capture does not hold and an excerpt that does not occur in that source, so a diagnosis can only name a component the model actually opened;
  - `abstain` takes the missing evidence as structured entries and refuses any entry naming a component or environment whose frozen source is in the capture, with the component list, so a false abstention costs a turn instead of the run.

Two models: `openrouter:deepseek/deepseek-v4-flash` (the example's model) and
`openrouter:openai/gpt-5.6-luna`. Temperature 0, 30 turns, and the #1810
workaround (`normal_event_count` 4096) in host and manifest.

## Results

Round 1 ran with the default event ceiling. 27 of 36 runs died as
`event_sink_unavailable`, including all 18 vocabulary-only runs; the logs are
in `evidence/round1-log.txt` and the root cause is #1810.

Round 2, three samples per cell:

| Target, expected | Prompt | DeepSeek | Luna |
| --- | --- | --- | --- |
| `t`, diagnose `pricing.rule` | p1 | 3 correct | 2 correct, 1 called `fail` |
| `t` | p2 | 1 correct, 2 hit 30 turns | 2 correct, 1 false abstention |
| `amb`, abstain | p1 | 3 abstained | 3 wrong (`orders`, or no component named) |
| `amb` | p2 | 1 abstained, 1 wrong, 1 output truncated | 2 abstained, 1 wrong |
| `wc`, diagnose `main` | p1 | 3 correct | 1 wrong (`shipping`), 2 abstained |
| `wc` | p2 | 1 correct, 1 abstained, 1 hit 30 turns | 1 correct, 1 tautology, 1 abstained |

Round 3, prompt `p3` with the terminal actions, two samples per cell:

| Target, expected | DeepSeek | Luna |
| --- | --- | --- |
| `t`, diagnose `pricing.rule` | 2 correct | 2 correct |
| `amb`, abstain | 0, both died on truncated output | 2 abstained |
| `wc`, diagnose `main` | 1 correct, 1 hit 30 turns | 2 correct |

Cost per run was $0.003 to $0.013 for both models. DeepSeek runs took 1.5 to
7 minutes, Luna runs 30 to 75 seconds. All three rounds together cost under
one dollar. Per-run turns, tokens and cost are reproducible with
`score-cell.sh`; the decisions are in `evidence/round*/`.

## What the traces say

- **The prescribed order does not stop a model from going beyond it.** In all three `wc` runs under `p1`, DeepSeek walked both mission sources, saw them clean, read the workflow's prelude sources on its own, and named `main`. Luna obeyed the prompt's stopping rule literally, reported at the dependency leaves, and abstained with a cause that correctly described the routing defect but named no component because it had not read the author. That is the report contract working and the stopping rule being overfit to the single-call topology.
- **Without an order, DeepSeek wanders.** Its turn-limit runs read activity, capability calls and failure values, re-opened the run, and reached the generated program around turn 26. On the ambiguous target under `p3` it read for 23 turns with ever longer programs, never called a terminal action, and its 24th response overflowed the 4096-token output ceiling the application limit imposes regardless of the host's `max_tokens`.
- **Luna's failures under `p1` are judgment, not navigation.** On the ambiguous target it walked everything, derived that 80 plus 20 cannot equal 110, and still reported `diagnosed`. Once it blamed `shipping` after confusing the target's failure with its own report contract.
- **The verdict definitions changed that judgment.** Under `p3` both Luna abstentions reason explicitly that either dependency could absorb the missing amount.
- **The abstain refutation fired on Luna's first attempt in both ambiguous runs.** Luna listed the two components it had read as missing, meaning it lacked their contracts; the action answered that both sources are in the capture; Luna restated the absent evidence as an authoritative expected value, and that was accepted. The refusal text should say "if you have read it, describe what about it is undetermined" rather than "read it".
- **Excerpt verification refused twice, both times for whitespace.** A multi-line excerpt failed to parse, an indented one did not match, a one-line fragment passed. Collapse whitespace before the substring check. The hash is the load-bearing check.
- **No run in round 3 named a wrong component.** Under `p1` the example's schema accepts `diagnosed` with no `component_id`, and one Luna run used that shape.
- **About half of every run is display recovery** until #1809 lands.

## Recommendations for the example

1. Keep the prescribed order and DeepSeek for the shipped arm: 9 of 9 across the three shapes, including the abstention and the workflow defect. Raise `max_turns` to 30 and add the #1810 workaround to host and manifest until it is fixed.
2. Add the terminal actions whatever the prompt. The hash requirement and the abstain refutation are domain-blind, close the `diagnosed` without `component_id` hole, and cost one to three turns.
3. Add the verdict definitions and the environment sentence to the shipped task. Neither hurt DeepSeek on the diagnosable targets and both are what a stronger model needed.
4. Keep the stopping-rule change out of the DeepSeek arm until it is measured together with the prescribed order; removing the order is what sent DeepSeek wandering.
5. Rewrite the README's promotion section around `ptc materialize --from-result`, document `mix ptc.repair` and the suites or delete the suites, and replace "a verified live run" with measured rates for all three targets.
6. Do not hand the agent the deterministic walk. It diagnoses in two turns but turns the arm into the repair arm's shape and covers one topology.

## Reproduce

```console
ptc init debug-a-failed-run --example debug-a-failed-run
for t in target target-ambiguous target-workflow-control; do ptc run debug-a-failed-run/$t.ptc-project.json; done
scripts/labs/debug-nav-bench/probe.sh debug-a-failed-run                      # terminal actions, no model
ENV_FILE=.env scripts/labs/debug-nav-bench/run.sh debug-a-failed-run out p3 2   # 12 runs, six at a time
scripts/labs/debug-nav-bench/score-cell.sh debug-a-failed-run/nb-wc-p3-luna
scripts/labs/debug-nav-bench/turns.sh debug-a-failed-run/nb-wc-p3-luna RUN_ID
```

`run.sh` takes `p1`, `p2` or `p3`; `gen-cells.sh` writes the cells and host
documents without running them. `.env` must hold `OPENROUTER_API_KEY`.

## Caveats

Two or three samples per cell, one capture per topology, temperature 0 but
not deterministic, Luna at the application's default output ceiling. The
captures also hold the passing run from the promotion rerun beside the failed
one; both models selected the failed run correctly every time.
