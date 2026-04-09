# Meta-Learner Co-Evolution: Exploration Notes

See also: `hyperagent-evolution.md`, `m0-failure-boundary-mining.md`, `refs/hyper-agents.md`

## Core Goal

Evolve a meta-learner M (a PTC-Lisp program) that learns *how to improve agents* — not just better agents, but a better learning process. The training data must co-evolve with M to provide continuous selection pressure.

## Key Design Principles

- **M is PTC-Lisp**: The meta-learner is a program, not a prompt template. It's evaluable, reproducible, and fast.
- **LLM as a tool, not the engine**: M can call an LLM when it chooses, but pays a fitness cost for doing so. Evolution pressures M to internalize what it previously needed the LLM for.
- **No fixed fitness formula**: Competition between M variants replaces human-designed scoring. The environment determines what "fit" means, and the environment changes.
- **Open-ended**: Prescribe the physics (system structure), not the goals (what "good" means).

## The System: Three Co-Evolving Components

### A (Author) — Problem Generator

Generates PTC-Lisp programs + natural language descriptions. Programs are run to produce I/O pairs that serve as ground truth.

### T (Tester) — Test Generator

Given a description, generates tests. Explores the boundary of what the description specifies. Probes for ambiguity and edge cases.

### C (Coder) — Implementation Generator

Given tests, produces an implementation. Serves as an independent check — if C's implementation disagrees with A's on T's tests, either the test or the description is flawed.

### M (Meta-Learner) — The thing we actually care about

Observes agent execution and failures. Produces mutations to agent specs. Can also propose prelude functions (reusable abstractions). Has access to LLM as a tool but is penalized for using it.

## M's Relationship to the LLM

M decides if, when, and how to call the LLM. The quality of M's prompts is itself under evolutionary pressure — an M that constructs better prompts gets better responses.

Early M: dumb, calls LLM constantly, improves fast but expensive.
Late M: has internalized patterns, rarely needs LLM, cheap to run.

This is **distillation through evolution** — M learns to replace expensive LLM calls with cheap symbolic computation.

Possible budget mechanisms:
- Fixed token budget per generation (M that wastes tokens dies)
- Fitness penalty proportional to tokens used: `fitness = problems_solved - lambda * tokens`
- Annealing: start with cheap LLM access, increase cost over time

## Competition-Based Evaluation (Preferred)

Instead of a multi-objective fitness formula, M variants compete directly:

```
Population: 4-8 M variants
Each generation:
  1. Generate N fresh random problems
  2. Each M produces agents, agents attempt problems
  3. Rank by: problems solved / LLM tokens spent
  4. Top half reproduce (with mutation), bottom half replaced
  5. Drift the problem complexity distribution
```

Why this over a fitness formula: any fixed formula will be gamed. Competition makes "fitness" emergent from interactions, not a human design choice.

### Environmental Drift

The problem generator's complexity distribution drifts stochastically over time (random walk on parameters). This prevents M variants from over-specializing on the recent past. Analogous to environmental change in biology — rain, drought, new predators.

## Ideas We Explored But Rejected or Found Problematic

### Fixed multi-objective fitness (Rejected)

Three signals were identified:
1. **Compression**: program length with M's prelude vs without
2. **Convergence speed**: generations to solve fresh problems
3. **Abstraction diversity**: prelude function usage across problem types

Problem: any fixed weighting is gameable. M can flood the prelude with trivial functions to win on compression while adding no real capability. Adjusting weights just moves the exploit surface. The more carefully we design the scoring, the more we're doing the work evolution should do.

These signals are still the *mechanism* by which good M's win in competition — we just don't measure them directly.

### Pure PTC-Lisp M with no LLM (Rejected as starting point)

A pure symbolic M that analyzes execution traces and produces mutations is extremely hard to write. The search space of "programs that improve other programs" is vast. Without LLM assistance, M would need sophisticated program analysis capabilities that are themselves hard to evolve from scratch.

Kept as an aspirational end state: a mature M that has internalized enough patterns to rarely need the LLM.

### LLM called every N generations on fixed schedule (Superseded)

Initial idea: M runs pure PTC-Lisp most of the time, calls LLM every N generations for "creative leaps." Problem: the fixed schedule is itself a design choice that should be evolvable. Replaced by: M decides when to call the LLM, pays a cost, and the frequency evolves.

### Consensus oracle for test validation (Problematic)

In the A/T/C scheme: run T's tests against both A's program and C's implementation. If they agree, the test is valid; if they disagree, the test is wrong. Problem: both A and C may be wrong in the same way (shared LLM biases). Consensus != correctness. The ground truth should be A's actual execution, not C's independent interpretation.

### Two-player simplification: Author vs Solver (Simpler but less rich)

Collapse T and C into one Solver. A generates problems (program + description + I/O pairs), S tries to reconstruct. Ground truth from execution, no consensus needed. Cleaner but loses the TDD dynamic where tests probe the boundary of specifications. May be a good starting point before adding the full three-player system.

### Static hard problems / fixed benchmarks (Insufficient)

The existing benchmark suite (55 tests including 25 M0-clustered, original 13 at 95%+ solved) provides limited selection pressure on the original set. Any fixed benchmark eventually saturates. Useful only as a held-out validation set to check for regression, not as the primary evolutionary driver.

## Open Questions

### Representation of M

What can M express? Options from constrained to open:
- **Decision tree** over failure patterns (`cond` form) — small search space, limited
- **Rule table** mapping failure types to mutation templates — evolvable but rigid
- **Arbitrary PTC-Lisp program** — maximally expressive, enormous search space
- **PTC-Lisp program with structured interface** — must implement specific functions (`mutate`, `classify-failures`, `propose-prelude`) but internals are free

The representation determines what M can discover. Too constrained and it can't find novel strategies. Too open and the search space is intractable.

### Credit Assignment

When M2's agents outperform M1's, is it because M improved or because the problems happened to be easier? With environmental drift, this is noisy. Possible mitigations:
- Both M1 and M2 face the exact same problem set each generation (paired comparison)
- Evaluate over many generations to average out noise
- Focus on local improvements: did this specific failure pattern disappear?

### Problem Generator Design

How to generate random PTC-Lisp programs that are:
- Syntactically valid and terminating
- Varied enough to require different strategies
- Describable in natural language (for the T/C components)
- Of controllable difficulty

### What "Open-Ended Improvement" Means

The real benchmark: does the system keep improving, or does it plateau? Not "did M reach score X" but "is the curve still going up after 100 generations?" This is domain-independent but hard to measure — you need to run long enough to distinguish "still improving slowly" from "plateaued."

### How M Proposes Prelude Functions

M needs to not just mutate agent specs but also discover reusable building blocks. How does this work mechanically? Does M extract common subexpressions from successful agent programs? Does it ask the LLM to generalize a pattern? Does it have a separate "prelude mutation" operator?

### Self-Modification Scope

In DGM-H, the hyperagent edits its own source code. In our system, M is PTC-Lisp running in a sandbox — it can't edit files. Self-modification happens through reproduction: M produces M' as a new program. But can M reason about its own code? Can it introspect on its own mutation strategy?

## What We Built and Learned (April 2026)

The simplified two-player system (Author/Solver + M as controller) was implemented
first. See `evolve-findings.md` for full experimental results.

### Answers to open questions from experiments

**Representation of M:** We chose "PTC-Lisp program with structured interface" — M is a
`(fn [fv] (cond ...))` that must return an operator keyword. The cond-tree representation
is small (15-30 AST nodes), fast to evaluate, and amenable to GP mutation. However, the
cond-tree can only select from a fixed set of 7 operators (6 GP + `:llm_mutation`). It
cannot compose operators or invent new ones. This is sufficient for the "when to think"
question but not for "how to think differently."

**Credit assignment:** Paired comparison (all M variants face the same problem set each
generation) works. The noise from stochastic GP mutation is manageable with population
sizes of 4-8. The bigger credit assignment problem: M's fitness depends on both its
operator choices AND the random outcomes of those operators. Two identical M's can get
different fitness from the same problem set.

**LLM budget strategy:** M-controlled (`:llm_mutation` as an operator choice) works
mechanically. The key finding: **the budget parameter (lambda_llm) is the dominant
lever**, not M's policy. At lambda_llm=0.001, LLM is never worth calling. At 0.0,
LLM dominates. The interesting regime requires careful calibration where LLM is worth
it for hard problems (~0.00005). This is closer to "annealing" — the human tunes the
economic environment, and M adapts its policy to the incentive structure.

**Environmental drift:** Implemented via coevolved Authors. Anchor Authors prevent
collapse. Author mutation (safe point_literal/point_symbol/arg_swap only) creates
threshold variations that are genuinely different problems. The difficulty frontier
stabilizes at ~0.30 success rate within 2-3 generations.

**Population sizes:** mu=4, lambda=4 for M; mu=4, lambda=2-3 for Authors. Small but
functional. Diversity is the main risk — seed-conservative dominated in all runs
because it's cheapest. Larger populations (8-12) would help maintain strategy diversity.

**Two-player vs three-player:** We implemented the Author/Solver simplification
(not the full A/T/C). T (Tester) and C (Coder) were unnecessary for the current
scope — Authors generate problems directly, solvers attempt them. The TDD dynamic
(T probing specification boundaries) remains a future extension.

## Possible Exploration Paths (for Claude Code)

Updated based on experimental findings:

1. **lambda_llm calibration**: break-even at 1.25e-5 (tokens_per_solve~10k, solve_value~0.125). Sweep with [0, 1e-6, 5e-6, 1e-5, 2e-5] to bracket the distillation regime
2. **M representation expansion**: let M return compound actions (e.g., `[:llm_mutation :point_mutation]` — try LLM first, GP fallback) or parameterized operators
3. **Author structural mutation**: current Authors only tweak thresholds. Adding template-based mutation (wrap in filter, add group-by) would create structurally novel problems
4. **Longer runs**: 20+ outer generations to see if M strategies diverge meaningfully or converge
5. **Heritable mutator genome**: Codex's suggestion — each organism is `{solver_ast, mutator_ast}`. This is the next major architectural leap
6. **Distillation chart**: the publishable ALife result — LLM tokens per solve dropping while problem difficulty increases
