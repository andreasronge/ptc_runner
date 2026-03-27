# Spec-Driven Darwinian Generative Model (DGM)

## Overview

An evolutionary system over agent cognition: evolve *how agents think* (strategies, parameters, prompt structure) rather than the code they produce. Uses the existing English → PTC-Lisp compilation pipeline as the mutation operator — specifications compile to programs, programs execute, results drive selection.

### Core insight

The unit of evolution is the **spec**, not the code. The LLM compiles specs into valid PTC-Lisp programs. This gives structured high-level mutations compiled into valid code — solving the classic DGM problem where mutations are either too low-level (random AST edits) or too high-level (unconstrained LLM guesses).

### Why this works for PtcRunner

- **English → PTC-Lisp compilation** already works via `SubAgent.run/2`
- **Sandboxed execution** with timeout/memory limits provides safe evaluation
- **Ablation infrastructure** (`PtcDemo.Ablation.Runner`) already runs variant × test × N-runs matrices
- **Per-turn metrics** (`TurnAnalysis`) provide diagnostic signal beyond pass/fail
- **Statistical tools** (Wilson intervals, Fisher exact test) enable rigorous variant comparison

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Evolution Loop                      │
│                                                      │
│  ┌──────────┐    ┌──────────┐    ┌───────────────┐  │
│  │ Problem   │    │ Agent    │    │  Evaluation   │  │
│  │ Generator │───▶│ Specs    │───▶│  (Ablation)   │  │
│  │           │    │          │    │               │  │
│  └─────┬────┘    └────┬─────┘    └───────┬───────┘  │
│        │              │                  │           │
│        │         ┌────▼─────┐    ┌───────▼───────┐  │
│        │         │ Mutator  │◀───│  Selection    │  │
│        │         │ (LLM)    │    │  (top-K)      │  │
│        │         └──────────┘    └───────────────┘  │
│        │                                             │
│        └──── difficulty adjustment ◀─── success_rate │
└─────────────────────────────────────────────────────┘
```

**Flow per generation:**

1. Evaluate agent specs against problem suite (via ablation runner)
2. Select top-K performers
3. Mutate winners (LLM-powered, failure-aware)
4. Adjust problem difficulty to maintain 40-60% success rate
5. Repeat

## Phase 1 — Problem Generation (prerequisite)

### Motivation

The existing benchmark is 95%+ solved. There is no selection pressure — all agents look equally good. Evolution requires a difficulty frontier where agents score 40-60%.

### Design

Generate harder test cases from existing ones using LLM-powered mutation.

#### Problem spec

```elixir
defmodule Evolution.ProblemSpec do
  defstruct [
    :id,
    :parent_id,        # lineage tracking
    :description,      # natural language question
    :difficulty,        # estimated difficulty tier
    :mutation_applied,  # what changed from parent
    :evaluator,         # fn output -> {:pass, score} | {:fail, reason}
    :metadata           # generation, success_rate history
  ]
end
```

#### Mutation operators for problems

- **Add edge cases** — "Modify this question to require handling empty results"
- **Increase complexity** — "Make this require joining data across two datasets"
- **Add ambiguity** — "Make the question require disambiguation before answering"
- **Require multi-step reasoning** — "Split this into sub-problems that must be solved sequentially"
- **Scale input size** — increase data volume the agent must process

#### Problem validation

A generated problem must be validated before entering the suite:

1. Run the current best agent against it N times (N=5)
2. **Keep** if pass rate is 30-70% (the difficulty frontier)
3. **Discard** if pass rate is 0% (likely broken or unsolvable)
4. **Discard** if pass rate is 100% (too easy, no pressure)

This prevents failure modes:
- Trivial problems (generator makes things easy)
- Adversarial nonsense (unsolvable problems)
- Broken evaluators (problem looks hard but evaluator is wrong)

#### Deliverables

- `Evolution.ProblemGenerator` — LLM-powered mutation of existing `TestCase` entries
- `Evolution.ProblemValidator` — run-and-filter pipeline
- A curated "hard suite" of 20-30 problems at the difficulty frontier

## Phase 2 — Agent Evolution with Structured Specs

### Agent spec format

Break agent configuration into structured, independently-mutable components:

```elixir
defmodule Evolution.Spec do
  defstruct [
    :id,
    :parent_ids,        # list (supports recombination lineage)
    :generation,
    :prompt_sections,   # ordered list of strategy instructions
    :parameters,        # %{max_turns: int, retry_turns: int, ...}
    :tools_policy,      # :all | :minimal | custom
    :mutation_history,   # [{generation, mutation_description}]
    :scores             # %{test_id => [pass_rates]}
  ]
end
```

#### Why `prompt_sections` (not a single prompt string)

A single prompt string collapses strategy into an opaque blob. Structured sections enable:
- **Surgical mutation** — change one step without rewriting everything
- **Recombination** — take decomposition from agent A, verification from agent B
- **Interpretable lineage** — see exactly what changed between generations

Example:

```elixir
%Evolution.Spec{
  prompt_sections: [
    "Break the problem into independent subtasks",
    "Solve each subtask using the available tools",
    "Cross-check the result against the original question"
  ],
  parameters: %{max_turns: 4, retry_turns: 1}
}
```

Compiles to a SubAgent prompt by joining sections. Simple, reversible, directly maps to `SubAgent.new/1`.

#### Mutation operators for agents

LLM-powered, operating on spec components:

- **Add step** — "Add a verification step after solving"
- **Remove step** — "Remove the decomposition step"
- **Reorder steps** — "Move verification before the final answer"
- **Rephrase step** — "Make the decomposition instruction more specific"
- **Tweak parameter** — increase/decrease max_turns, retry_turns
- **Change tools policy** — restrict or expand available tools

#### Failure-aware mutation (key differentiator)

Don't mutate blindly. Use diagnostic metrics from failed runs:

```
Input to mutator:
  - Current spec
  - Per-test pass/fail breakdown
  - Failure mode analysis (from TurnAnalysis):
    - budget_exhausted? → "Agent runs out of turns on hard problems"
    - parse_failure_rate high → "Agent generates invalid code"
    - first_turn_valid? low → "Agent struggles on first attempt"

Mutator prompt:
  "This agent fails on multi-step reasoning tasks (tests 18, 22, 25).
   It exhausts its turn budget. Modify the strategy to be more efficient."
```

This turns evolution into **directed improvement** rather than blind search. Much more sample-efficient.

#### Selection

Per generation:
1. Evaluate all candidates (population size 5-10) against the hard suite
2. Each candidate gets N runs per test (N=3 minimum for statistical signal)
3. Rank by overall pass rate (Wilson lower bound for tie-breaking)
4. Select top-K (K=3) as parents for next generation

#### Evolution loop

```elixir
defmodule Evolution.Loop do
  @population_size 8
  @top_k 3
  @runs_per_test 3
  @max_generations 10

  def run(seed_specs, problem_suite, opts) do
    Enum.reduce(1..@max_generations, seed_specs, fn gen, population ->
      # 1. Evaluate
      results = evaluate(population, problem_suite, runs: @runs_per_test)

      # 2. Select
      winners = select_top_k(results, @top_k)

      # 3. Log lineage
      log_generation(gen, results, winners)

      # 4. Mutate (failure-aware)
      children = mutate_winners(winners, results, target: @population_size)

      children
    end)
  end
end
```

#### Deliverables

- `Evolution.Spec` — structured agent spec with lineage tracking
- `Evolution.Mutator` — LLM-powered, failure-aware mutation
- `Evolution.Loop` — orchestration: evaluate → select → mutate → repeat
- Integration with existing `PtcDemo.Ablation.Runner` for evaluation

## Phase 3 — Recombination

### When to add

After Phase 2 produces a diverse population of specialists — agents that are good for *different reasons*. Typically after 5+ generations.

### Design

Combine two parent specs:

```elixir
def crossover(spec_a, spec_b) do
  # Option 1: Mechanical — interleave prompt sections, average parameters
  # Option 2: LLM-assisted — "Combine the strengths of these two agents"
end
```

LLM-assisted crossover is preferred because it can resolve conflicts intelligently:

```
"Parent A excels at decomposition but runs out of turns.
 Parent B is efficient but misses edge cases.
 Combine their strategies into a single spec."
```

### Lineage

Track both parents: `parent_ids: [spec_a.id, spec_b.id]`

## Phase 4 — Co-Evolution (Problem + Agent)

### When to add

After Phase 2 validates that single-axis agent evolution works and produces measurable improvement.

### Design: Teacher-Student model

- **Student (agent)**: maximize score
- **Teacher (problem generator)**: generate problems at the edge of solver capability

#### Target success rate constraint

```elixir
generator_reward = -abs(success_rate - 0.5)
```

- Too easy → penalized
- Too hard → penalized
- 40-60% success rate → rewarded

This creates an **automatic curriculum** — problems stay at the difficulty frontier as agents improve.

#### Loop

```
1. Generate problem candidates (mutate existing + generate new)
2. Validate problems (30-70% current pass rate)
3. Evaluate agents against validated suite
4. Select top-K agents
5. Mutate agents (failure-aware)
6. Adjust problem difficulty based on new agent success rate
7. Repeat
```

#### Safeguards against collapse

- **Floor constraint**: problem suite must include at least 5 problems from the original validated set (anchor against drift)
- **Diversity requirement**: problems must span at least 3 difficulty tiers
- **Solvability check**: discard any problem with 0% pass rate across all agents

## Lineage Tracking

Critical for understanding what evolution discovers.

### What to track per generation

| Field | Purpose |
|-------|---------|
| `generation` | Which generation |
| `spec_id` | Unique identifier |
| `parent_ids` | Mutation or crossover parents |
| `mutation_applied` | Natural language description of change |
| `per_test_scores` | Pass rate per test case |
| `aggregate_score` | Overall pass rate (Wilson lower bound) |
| `failure_modes` | Dominant failure patterns |
| `problem_suite_version` | Which problems were used |

### Expected observations

**Early generations (1-3):** Trivial improvements — add retries, increase turns, add "be careful" instructions.

**Mid generations (4-7):** Emergence of patterns — decompose → solve → verify pipelines, multi-attempt strategies, fallback logic.

**Late generations (8+):** Specialization — some agents strong at reasoning, others at robustness. This is where recombination (Phase 3) becomes valuable.

## Implementation Sequence

```
Phase 1 — Problem Generation          ← START HERE
  └─ Unblocks everything else
  └─ Creates the difficulty frontier (40-60% pass rate)
  └─ Deliverables: ProblemGenerator, ProblemValidator, hard test suite

Phase 2 — Agent Evolution
  └─ Requires: hard test suite from Phase 1
  └─ Core evolutionary loop
  └─ Deliverables: Spec, Mutator, Loop modules

Phase 2.5 — Failure-Aware Mutation
  └─ Uses TurnAnalysis diagnostics to direct mutations
  └─ Highest bang-for-buck improvement over naive evolution

Phase 3 — Recombination
  └─ Requires: diverse population from Phase 2
  └─ Combine specialists

Phase 4 — Co-Evolution
  └─ Requires: validated single-axis evolution from Phase 2
  └─ Teacher-student model with target success rate
  └─ Automatic curriculum generation
```

## Open Questions

1. **Population size**: 5-10 seems right for early experiments. Larger populations need more evaluation budget (each candidate × N runs × M tests).
2. **Evaluation cost**: At 3 runs × 20 tests × 8 candidates = 480 LLM calls per generation. With haiku that's feasible; with larger models it gets expensive. Consider using haiku for evolution and validating winners on stronger models.
3. **Convergence criteria**: When do we stop? Options: N generations without improvement, target pass rate achieved, or manual inspection.
4. **Prompt section granularity**: How fine-grained should `prompt_sections` be? Too coarse limits mutation; too fine creates fragile prompts. Start coarse, refine based on what evolution wants to change.
5. **Generalization**: Do evolved agents generalize beyond the hard suite? Need a held-out validation set to check for overfitting.
