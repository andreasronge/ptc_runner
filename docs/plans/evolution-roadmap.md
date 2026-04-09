# Evolution Roadmap

Status: ACTIVE
Date: 2026-04-09
Context: See `evolution-findings.md` for completed experiments. See `archive/` for historical plans.

## Current State

Three-species coevolution (Authors + MetaLearner M + Solvers) is working. M controls
GP-vs-LLM operator selection via cond-trees. At lambda_llm=0.0, evolved M achieves
100% solve rate. At lambda_llm >= 5e-5, all M variants converge to GP-only. The
distillation regime (where M learns selective LLM use) requires lambda in [5e-6, 1e-5].

Key modules: `lib/ptc_runner/meta/` (meta_loop.ex, meta_evaluator.ex, meta_learner.ex,
author.ex, failure_vector.ex, seeds.ex) and `lib/ptc_runner/evolve/` (loop.ex,
operators.ex, llm_operators.ex, evaluator.ex, individual.ex).

## Priority 1: lambda_llm Calibration (Next Experiment)

Break-even lambda = 1.25e-5 (tokens_per_solve ~10k, solve_value ~0.125).

**Experiment:** Sweep with [0, 1e-6, 5e-6, 1e-5, 2e-5] to bracket the distillation
regime. Use `mix meta.sweep`.

**Key question:** Does M learn to use LLM selectively at the break-even lambda? (LLM
for hard cross-dataset joins, GP for easy threshold problems.)

## Priority 2: Distillation Over Time

At the optimal lambda, track `tokens_per_solve` across outer generations. If it
decreases while `solve_rate` holds, that's distillation — the publishable chart.

## Priority 3: LLM-Evolved M

With `m_llm_mutation_rate > 0`, does LLM mutation on M itself produce better strategies
than GP mutation of M? The meta-meta question.

## Future Directions

### GP Value Proposition

Run the LLM mutation prompt N times (no GP) and compare success rate to GP+LLM over N
generations. If raw LLM succeeds at the same rate, GP is overhead. If GP finds solutions
by combining partial successes, that's the value proposition.

### M Representation Expansion

Current M returns a single operator keyword. Extensions:
- **Compound actions:** `[:llm_mutation :point_mutation]` — try LLM first, GP fallback
- **Parameterized operators:** M controls not just which operator but its parameters
- **Arbitrary PTC-Lisp:** move beyond cond-trees to full programs (larger search space)

### Author Structural Mutation

Current Authors only tweak thresholds (point_literal, point_symbol, arg_swap). Adding
template-based mutation (wrap in filter, add group-by) would create structurally novel
problems instead of just threshold variations.

### Longer Runs

20+ outer generations to see if M strategies diverge meaningfully or converge. Current
experiments run 4 generations — enough to validate mechanism, not enough to see long-term
dynamics.

### Heritable Mutator Genome

Each organism is `{solver_ast, mutator_ast}` — the mutation strategy co-evolves with the
solution. This is the next major architectural leap (suggested by Codex).

### Prelude Discovery

When Solvers evolve useful subexpressions (e.g., set-join pattern), extract as named
prelude functions. Future generations use them as building blocks. Original M0 vision —
discovering reusable abstractions from execution — driven by evolution.

### Multi-Problem Generalization

Current: one Solver population per problem. Next: one Solver evaluated across ALL
problems. Can a single evolved program solve multiple data pipeline tasks?

### LLM Cost Annealing

Start with low LLM cost penalty, increase over generations. Early generations use LLM
freely. Later generations must internalize patterns.

### Compare with SubAgent.run

Evolve SubAgent configurations (system prompt, parameters) instead of programs directly.
Closer to the original Meta-Harness approach. Compare: which produces better results
per dollar spent?

### Three-Player A/T/C System

Add Tester (T) and Coder (C) to the current Author/Solver setup. T generates tests
probing specification boundaries. C provides independent implementations. The TDD
dynamic was deferred from the original design.

## Improvement Ideas (from experiments)

### Better Partial Credit Scoring

- **Structural similarity:** compare AST structure, not just output values
- **Intermediate value credit:** capture let-binding values, compare against expected
- **Type-weighted scoring:** list-when-map-expected (0.05) > integer-when-map (0.01)

### Anti-Collapse Measures

- **Diversity preservation:** novelty search or fitness sharing
- **Island model:** multiple sub-populations with different strategies
- **Minimum size threshold:** prevent shrinkage to degenerate 3-node programs

### Prompt Engineering for LLM Mutation

- **Incremental prompting:** "what ONE function call should I add?" instead of full rewrite
- **Error-specific prompts:** include crash error in prompt for targeted fixes
- **Program decomposition:** write pipeline steps separately, then compose

## References

- `refs/godel-machine.pdf` — Godel Machine paper
- `refs/hyper-agents.md` — Meta AI Hyperagents framework
- `refs/meta-harness.md` — Stanford Meta-Harness paper (March 2026)
- `archive/hyperagent-evolution.md` — Original evolution plan with implementation status
- `archive/m0-failure-boundary-mining.md` — M0 failure boundary mining design
- `archive/meta-evolve-v2-plan.md` — Meta-Harness-inspired plan (superseded)
- `archive/meta-learner-coevolution.md` — Three-species coevolution exploration
