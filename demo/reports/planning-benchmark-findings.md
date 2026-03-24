# Planning Benchmark: Findings

## Method

Three conditions are compared on the same test cases using `mix planning`:

- **Direct** — Single SubAgent with tools and datasets, no plan. The LLM decides what to do each turn (ReAct-style). Uses the same prompt profile the test would normally get via `:auto` routing.

- **Planned** — Two-phase pipeline. First, a planner SubAgent (single-shot, `output: :text`, no tools) decomposes the task into 2-6 steps. The planner sees dataset schemas and tool signatures but cannot call them. Then an executor SubAgent runs with `plan: generated_steps`, which renders a progress checklist in feedback messages. The executor uses the same prompt, tools, and turn budget as the direct condition.

- **Specified** — Same as planned, but using developer-written plan steps from the test case definition instead of LLM-generated ones. This is the existing behavior when running plan-mode tests.

### Metrics

| Metric | Description |
|--------|-------------|
| Pass rate | Task success validated against expected output type and constraints |
| Mean turns | LLM round-trips (planner always uses 1 turn) |
| Mean tokens | Total token usage (planner + executor for planned) |
| Planner tokens | Tokens consumed by the planning phase |
| Plan overhead | Planner tokens as percentage of total |
| Tool calls | Number of tool invocations |
| Plan steps | Number of steps generated/specified |

All runs use the same model, datasets, and validation criteria. The benchmark uses `TurnAnalysis.aggregate` and Wilson confidence intervals for statistical comparison.

## Results

Model: Claude Haiku 4.5, N=5 per condition per test.

### Test 25: Customer value report (simple aggregation)

3 plan steps (specified), ~4 steps (planned). Single dataset, no tool calls needed.

|  | direct | planned | specified |
|--|--------|---------|-----------|
| Pass rate | 100% | 100% | 100% |
| Mean turns | 1.0 | 1.0 | 1.0 |
| Mean tokens | 2005 | 2699 | 2071 |
| Planner tokens | - | 568 | - |
| Plan overhead | - | 21% | - |

**Finding:** All three solve it in 1 turn. Planning adds 35% token cost with no benefit. The task is too simple to need decomposition.

### Test 28: 6-department stats (12 independent sub-tasks)

13 plan steps (specified), ~6 steps (planned). Multiple departments, same computation repeated.

|  | direct | planned | specified |
|--|--------|---------|-----------|
| Pass rate | 100% | 100% | 100% |
| Mean turns | 1.6 | 1.4 | 2.2 |
| Mean tokens | 3763 | 4265 | 6391 |
| Planner tokens | - | 653 | - |
| Plan overhead | - | 15% | - |

**Finding:** The 13-step developer plan over-decomposes the task, causing the executor to use 70% more tokens than direct. The LLM planner generates a more natural 6-step decomposition but still adds overhead vs direct. Direct is cheapest.

### Test 29: 5-hop cross-dataset pipeline

6 plan steps (specified), ~6 steps (planned). Requires chaining across products, orders, and expenses.

|  | direct | planned | specified |
|--|--------|---------|-----------|
| Pass rate | 100% | 100% | 100% |
| Mean turns | 1.6 | 2.0 | 1.0 |
| Mean tokens | 4376 | 6918 | 2629 |
| Planner tokens | - | 709 | - |
| Plan overhead | - | 10% | - |

**Finding:** Well-crafted developer plan guides the executor to solve it in 1 turn (2629 tokens). Direct takes 1.6 turns (4376 tokens). LLM-planned is worst at 2.0 turns (6918 tokens) — the generated steps are plausible but don't reduce executor work. The planner's decomposition is *coherent* but not *operational*.

## Conclusions

**Narrow reading:** This style of lightweight LLM planning (minimal prose planner, single-shot, no examples) did not improve these data-computation tasks on Haiku 4.5. This does not generalize to "LLM planning doesn't work" — it means this specific planner/model/task combination showed no benefit.

That said, the results are sufficient to support a conservative library stance:

1. **Lightweight LLM planning added cost without reducing executor work** in these tests. Planner overhead was 10-21%, and generated plans did not reduce turns or tokens. The plans were coherent prose but not operationally useful to the executor.

2. **Developer-specified plans help on genuinely complex multi-hop tasks** (test 29: 40% fewer tokens than direct) but **hurt on tasks the LLM can solve directly** (test 28: 70% more tokens than direct). Plans are not universally beneficial.

3. **Over-decomposition is harmful.** The 13-step developer plan for test 28 forced the executor through more work than necessary. The LLM planner naturally avoided this (6 steps), but still couldn't beat direct.

4. **Plan quality matters more than plan existence.** The difference between a good developer plan (test 29) and a decorative LLM plan is larger than the difference between having a plan and not having one.

## Implications for ptc_runner

- **Keep `plan:` as a useful primitive.** Well-crafted plans demonstrably help on complex tasks.
- **Keep `step-done`/progress support as optional scaffolding.**
- **Keep planner→executor as an example pattern in `demo/`**, not core runtime.
- **Do not reintroduce meta-planner, DAG, or replanning machinery.** The evidence does not justify it.
- **The benchmark infrastructure (`mix planning`) is useful for evaluating future planning strategies.** If prompt improvements or stronger models change the picture, the evidence will show it.

## What would strengthen the evidence

Testing these variants would help distinguish "planning is inherently decorative here" from "this planner/model pair is too weak":

- A stronger model (e.g., Sonnet or Opus)
- Tool-heavy retrieval benchmarks (search + fetch, where planning could reduce wasted calls)
- A planner prompt with concrete decomposition examples
- A "plan compression" variant limiting the planner to 2-4 steps max

## Limitations

- Small sample (N=5, 3 tests). Confidence intervals are wide.
- Single model (Haiku 4.5). Larger models may benefit more from planning.
- All tests are data-computation tasks. Tool-heavy retrieval tasks (search + fetch) may show different patterns.
- The planner prompt is minimal and untuned. A more sophisticated planner (with examples, tool hints, or success criteria) might perform better — but would also cost more tokens.
- The benchmark tests a specific planning style (single-shot prose decomposition). Other approaches (iterative planning, plan-with-examples, structured tool routing) are untested.
