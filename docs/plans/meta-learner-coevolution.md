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

## Possible Exploration Paths (for Claude Code)

Use Claude Code as the outer-loop architect to explore:

1. **M representation variants**: try different structural constraints on M, see which leads to sustained improvement
2. **A/T/C interaction patterns**: sequential, adversarial, cooperative — how does the interaction pattern affect M's learning?
3. **LLM budget strategies**: fixed budget, annealing, M-controlled — which produces the best distillation?
4. **Environmental drift rates**: too fast and M can't learn, too slow and M over-specializes — what's the sweet spot?
5. **Population sizes and selection pressure**: tournament selection, proportional, elitist — does it matter?
6. **Two-player vs three-player**: does the full A/T/C system produce meaningfully better M's than the simpler Author/Solver setup?
