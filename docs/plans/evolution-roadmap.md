# Evolution Roadmap

Status: ACTIVE
Date: 2026-04-10
Context: See `evolution-findings.md` for completed experiments (through Experiment 7). See `archive/` for historical plans.

## Current State

Three-species coevolution with branch-level M crossover. Experiment 7 (fine lambda
sweep) found the distillation regime at lambda ∈ [5e-6, 2e-5] with 0.429 solve rate.
All best M's are crossover-evolved variants. Hard problems (cross-dataset joins) remain
unsolved — the LLM call cap (5) is likely too restrictive.

Key modules: `lib/ptc_runner/meta/` (meta_loop.ex with `crossover_m/2` and `reproduce_m/2`,
meta_evaluator.ex with LLM call cap, meta_learner.ex, author.ex, failure_vector.ex,
seeds.ex) and `lib/ptc_runner/evolve/` (loop.ex, operators.ex, llm_operators.ex,
evaluator.ex, individual.ex).

## Done

- ~~lambda_llm calibration~~ — Experiment 7: sweet spot at [5e-6, 2e-5], break-even
  prediction of 1.25e-5 confirmed. No distillation trend in 4 generations.
- ~~Branch-level M crossover~~ — `crossover_m/2` implemented, 100% offspring validity,
  crossover offspring winning in all lambda points.
- ~~LLM call cap~~ — `max_llm_calls_per_problem: 5` in MetaEvaluator. Prevents
  degenerate M variants from burning tokens. May be too restrictive for hard problems.
- ~~Default model~~ — `gemini-flash-lite` alias, resolved via Registry.

## Priority 1: Unlock Hard Problem Solving

hard_solve_rate = 0.0 in Experiment 7. Two hypotheses:

**A) LLM call cap too low.** Raise `max_llm_calls_per_problem` from 5 → 15 and rerun
at lambda=5e-6. If hard problems start solving, the cap was the bottleneck.

**B) Seed solvers too far from solution.** The 3 solver seeds are trivial count/filter
programs. Hard problems need `set` + `contains?` patterns. Add a solver seed closer
to the cross-dataset join structure.

**Experiment:** Run both A and B independently, compare hard_solve_rate.

## Priority 2: Distillation Over Time

At lambda=5e-6, run 12+ outer generations. Track `tokens_per_solve` per generation.
If it decreases while `solve_rate` holds, that's distillation — the publishable chart.
Experiment 7 showed no trend in 4 generations — may need longer runs.

## Priority 3: LLM-Evolved M

With `m_llm_mutation_rate > 0`, does LLM mutation on M itself produce better strategies
than GP mutation of M? The meta-meta question.

## Future Directions

### GP Value Proposition

Run the LLM mutation prompt N times (no GP) and compare success rate to GP+LLM over N
generations. If raw LLM succeeds at the same rate, GP is overhead. If GP finds solutions
by combining partial successes, that's the value proposition.

### M Biological Evolution Mechanisms (Staged)

Current M limitations: no crossover between variants, direct encoding (AST = behavior),
cond branches don't interact, most GP mutations produce broken programs.

**Stage 1: Branch-level crossover** (~30-50 lines)

Exchange cond branches between two M parents. Branches are semantically modular
units (condition → operator), making them natural crossover points. Implementation:
extract the cond branch list from two parents, sample/interleave branches, wrap back
in `(fn [fv] (cond ...))`. Add `crossover_m/2` to MetaLoop alongside existing `mutate_m/2`.

```clojure
;; Parent A (error-focused)          Parent B (score-focused)
(fn [fv]                             (fn [fv]
  (cond                                (cond
    (get fv :compile_error) :point_mutation    (< (get fv :partial_score) 0.2) :llm_mutation
    (get fv :timeout)       :subtree_delete    (< (get fv :partial_score) 0.8) :crossover
    (get fv :wrong_type)    :llm_mutation       (get fv :size_bloat)           :subtree_delete
    :else                   :point_mutation))   :else                          :arg_swap))

;; Offspring (branches from both)
(fn [fv]
  (cond
    (get fv :compile_error)              :point_mutation     ;; from A
    (< (get fv :partial_score) 0.2)      :llm_mutation       ;; from B
    (get fv :timeout)                    :subtree_delete     ;; from A
    :else                                :arg_swap))         ;; from B
```

**Key question:** What fraction of crossover offspring are valid? Track this metric.
If <30% valid, the representation itself needs changing (proceed to Stage 2).

**Why this matters:** Experiments show seed-conservative (cheap) and seed-llm-aware
(effective) contain complementary strategies. Crossover can produce offspring that are
conservative on easy problems AND LLM-aware on hard problems — a combination no single
seed contains.

**Stage 2: Parameter extraction (if crossover validity is low)** (~100 lines)

Separate M into genotype (parameter vector) and phenotype (fixed cond-tree template).
The genotype is a PTC-Lisp map of thresholds/weights; the phenotype is a fixed
interpreter. GP mutation operates on the parameter map — always produces valid M.

```clojure
;; GENOTYPE — evolvable numeric parameters
{:error_weight 0.8
 :score_low 0.2
 :score_high 0.8
 :size_threshold 0.7
 :llm_bias 0.3
 :crossover_bias 0.15}

;; PHENOTYPE — fixed template parameterized by genotype
(fn [fv genome]
  (let [score (get fv :partial_score)]
    (cond
      (and (get fv :compile_error)
           (> (get genome :error_weight) 0.5))     :point_mutation
      (and (< score (get genome :score_low))
           (> (get genome :llm_bias) 0.2))          :llm_mutation
      (and (get fv :no_improvement)
           (> (get genome :crossover_bias) 0.1))    :crossover
      (< score (get genome :score_high))            :arg_swap
      :else                                         :point_mutation)))
```

Benefits:
- **Every mutation valid** — tweak 0.2 → 0.25, can't break cond structure
- **Neutral mutations** — changing score_low from 0.2 to 0.19 may not change behavior
  now but creates diversity for future selection pressure
- **Smooth landscape** — intermediate strategies between conservative and LLM-aware
  can be discovered incrementally
- **Crossover trivial** — uniform crossover on parameter vectors

Tradeoff: M can only discover strategies within the template's structure. Trades
expressiveness for evolvability. Consider evolving the template itself (Stage 3).

**Stage 3: Epistatic interactions (future)**

Add `let`-bindings that create intermediate "regulatory" signals combining failure
vector fields. Multiple cond branches read these signals, creating non-linear
interactions between conditions.

```clojure
(fn [fv]
  (let [aggressive? (and (< (get fv :partial_score) 0.3)
                         (get fv :no_improvement))
        structural? (or (get fv :wrong_type)
                        (not (get fv :has_join_pattern)))]
    (cond
      (get fv :compile_error)           :point_mutation
      (and aggressive? structural?)     :llm_mutation      ;; epistatic
      aggressive?                       :crossover
      structural?                       :wrap_form
      :else                             :point_mutation)))
```

**Biological analogies that DON'T map well to M** (skip these):
- Diploidy — M too small (15-30 nodes), double evaluation cost for no benefit
- Epigenetics — M has no persistent state, would need MetaLoop architectural changes
- Speciation — population of 4-8 too small for reproductive isolation
- Developmental timing — M runs once per selection, no development to sequence

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
