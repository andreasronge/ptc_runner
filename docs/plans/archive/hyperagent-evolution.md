# Hyperagent Evolution for PtcRunner

See also: `./refs/hyper-agents.md`, `m0-failure-boundary-mining.md`, `meta-learner-coevolution.md`

## Motivation

The current benchmark suite (55 test cases including 25 M0-clustered, 3 difficulty levels) is 95%+ solved on the original 13. There is no selection pressure for evolving better agents. We need both harder problems and a self-improvement mechanism inspired by the Darwin Godel Machine / Hyperagents framework (Meta AI).

### Core insight

The unit of evolution is the **agent spec** (system prompt sections + parameters + prelude), not the generated PTC-Lisp code. The LLM compiles specs into valid programs via `SubAgent.run/2`. Self-improvement happens at two levels: the agent strategies evolve across generations, and a library of reusable functions (the "prelude") co-evolves as stable building blocks.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Hyperagent Loop                         │
│                                                          │
│  ┌────────────┐   ┌──────────────┐   ┌───────────────┐  │
│  │  Static     │   │ Agent Specs  │   │  Evaluation   │  │
│  │  Hard Suite │──▶│ + Prelude    │──▶│  (Ablation)   │  │
│  │             │   │              │   │               │  │
│  └─────────────┘   └──────┬───────┘   └──────┬────────┘  │
│                           │                  │           │
│                    ┌──────▼───────┐   ┌──────▼────────┐  │
│                    │  Mutator     │◀──│  Selection    │  │
│                    │  (LLM +      │   │  (top-K)      │  │
│                    │  failure-    │   └───────────────┘  │
│                    │  aware)      │                      │
│                    └──────────────┘                      │
│                                                          │
│  Later: problem co-evolution ◀── success_rate feedback   │
└─────────────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 0: Static Hard Problems (start here)

Validate the mechanism before evolving problems. Pick 3-5 problems that current agents solve < 50% of the time.

#### Options for sourcing hard problems

**Option A: Hand-crafted multi-step tasks**

Write problems that require composition, edge-case handling, and multi-tool orchestration. Examples:
- Cross-dataset joins with ambiguous matching criteria
- Multi-step aggregation where intermediate results need validation
- Problems requiring the agent to handle missing/malformed data gracefully

**Option B: Round-trip program synthesis**

1. Write a complex PTC-Lisp program (30-50 lines, multiple tools, branching logic)
2. Run it to capture input/output pairs
3. LLM generates a natural-language description from the code (describe *what*, not *how*)
4. The description + I/O examples become the problem
5. Agent must regenerate a program producing matching outputs
6. Equivalence check: run both on held-out inputs

Advantages: infinite supply, automatic ground truth, difficulty scales with program complexity. The description abstraction level (how much implementation detail leaks) is itself a tunable difficulty parameter.

**Option C: Exercism Clojure (validation set only)**

PTC-Lisp is a subset of Clojure, so many Exercism problems won't translate (no lazy seqs, namespaces, Java interop). But 10-15 problems that fit PTC-Lisp's subset could serve as a held-out generalization check — agents that score well on problems they never trained against demonstrate real improvement, not overfitting.

**Recommendation:** Start with Option A (3-5 hand-crafted), use Option B once the mechanism works, hold Option C as a validation set.

### Phase 1: `compile-and-test` Tool

Give agents the ability to write, compile, and test small PTC-Lisp functions within a single turn. This is the inner-loop evolution mechanism.

```clojure
;; Agent writes a helper function
(def helper-code
  "(defn parse-record [s]
     (let [parts (split s \",\")]
       {:name (first parts) :value (parse-int (second parts))}))")

;; Compile and test it in a nested sandbox
(def result (tool/compile-and-test
  {:code helper-code
   :test-cases [{:input "alice,42" :expected {:name "alice" :value 42}}
                {:input "bob,7"    :expected {:name "bob" :value 7}}]}))

;; Use it if it passes
(when (:passed? result)
  (eval helper-code)
  (map parse-record raw-lines))
```

#### Implementation

- New tool wrapping `Sandbox.execute/3` with nested invocation
- Inherits parent sandbox constraints (timeout, memory)
- Returns `{:passed? bool, :results [...], :error nil | string}`
- Requires adding a scoped `eval` to PTC-Lisp (sandboxed, only within `compile-and-test` context)

### Phase 2: Evolved Prelude (library of building blocks)

A shared library of small, tested PTC-Lisp functions that agents can reuse.

```clojure
;; prelude (evolved separately, slower timescale)
(defn safe-search [query]
  (let [results (tool/search {:q query})]
    (if (empty? results) [] results)))

(defn verify-answer [answer question]
  (tool/check {:answer answer :question question}))

;; agent program (small, composes prelude functions)
(-> question safe-search first (verify-answer question) return)
```

**Evolution of prelude functions:**
- A function survives if agents using it score higher than agents that don't
- Functions nobody uses get pruned
- New functions get promoted from successful `compile-and-test` results
- Prelude evolves on a slower timescale than agent strategies (like genes vs regulatory networks)

**Selection pressure:** Track per-function usage across generations. Compute the marginal value of each function: compare agent scores with/without it.

### Phase 3: Evolutionary Loop

One-generation loop (validate before scaling):

1. Seed 3-4 agent variants (different system prompt strategies)
2. Each variant gets the same prelude + tools
3. Evaluate against the static hard suite (N=3 runs per test, via `Ablation.Runner`)
4. Select top-K (K=2) using Wilson lower bound for ranking
5. Mutate winners: LLM-powered, failure-aware (uses `TurnAnalysis` diagnostics)
6. Evaluate children
7. Did anything improve? If yes, the mechanism works.

#### Agent spec structure

```elixir
%{
  id: "agent-gen3-v2",
  parent_ids: ["agent-gen2-v1"],
  generation: 3,
  prompt_sections: [
    "Break the problem into independent subtasks",
    "Use compile-and-test to validate helper functions before using them",
    "Cross-check the result against the original question"
  ],
  parameters: %{max_turns: 4, retry_turns: 1},
  prelude: :v2,
  mutation_history: [{2, "Added compile-and-test instruction"}],
  scores: %{}
}
```

#### Failure-aware mutation

Use `TurnAnalysis` diagnostics to direct mutations:

| Failure signal | Mutation direction |
|---|---|
| `budget_exhausted?` | Reduce steps, increase efficiency |
| `parse_failure_rate` high | Simplify code generation strategy |
| `first_turn_valid?` low | Improve initial decomposition |
| Specific tests always fail | Add targeted strategy for that pattern |

### Phase 4: Problem Co-Evolution (future)

Once agent evolution is validated, add problem generation to maintain selection pressure.

#### Teacher-Student model

- **Student (agent):** maximize score
- **Teacher (problem generator):** generate problems at the difficulty frontier

```
generator_reward = -abs(success_rate - 0.5)
```

Problems that are too easy or too hard get penalized. 40-60% success rate is the sweet spot.

#### Round-trip as the problem generator

Use Option B from Phase 0 at scale:
1. Generate random PTC-Lisp programs of increasing complexity
2. Run them, capture I/O pairs
3. LLM generates descriptions at controlled abstraction levels
4. Validate: current best agent solves 30-70% of the time
5. Problems that are 0% (broken) or 100% (too easy) get discarded

#### Automatic curriculum

As agents improve, the problem generator must keep up. The success rate feedback loop creates an automatic curriculum — problems stay at the difficulty frontier without manual tuning.

## Implementation Status (April 2026)

### What was built

Phases 0-3 were partially realized through a different architecture than originally
planned. Instead of evolving SubAgent specs (system prompts + parameters), we built
a three-species coevolution system operating directly on PTC-Lisp programs:

**Species 1: MetaLearner M** — PTC-Lisp cond-trees that select GP operators
(including `:llm_mutation`) based on an 8-element failure vector (6 original +
`node_count`, `has_join_pattern`). M controls the GP-vs-LLM decision for each
solver mutation. Located in `lib/ptc_runner/meta/`. Can itself be mutated by
LLM via `m_llm_mutation_rate` config.

**Species 2: Authors** — PTC-Lisp programs that generate problems by computing
ground truth from data context. Author fitness = `-abs(success_rate - 0.5)` —
problems at the difficulty frontier (40-60% solve rate) score highest.

**Species 3: Solvers** — the inner population evolved by the existing `evolve/loop.ex`
with M controlling operator selection via an `operator_selector` callback.

### Key findings from experiments

1. **GP operators alone cannot make structural leaps.** With no LLM, all M variants
   perform identically because the operators are equally incapable of inventing new
   program patterns (e.g., set-based joins, group-by aggregation).

2. **LLM mutation solves everything when unrestricted.** At 30% LLM rate, Gemini
   Flash Lite solves all problems by Gen 1-3 regardless of M's GP selection.

3. **M found the economically rational strategy.** With lambda_llm=0.001, each LLM
   call costs ~1.0 fitness while solving one problem is worth ~0.167. M correctly
   learns to never call LLM. The distillation dynamics require calibrated lambda_llm.

4. **Three-species coevolution is stable** with anchor Authors. Without anchors,
   Author mutation destroys the ecosystem in 2-3 generations. With permanent seed
   Authors, the Author pool grows (6→10), the difficulty frontier stabilizes at
   ~0.30 success rate, and M improves (0.167→0.375 at Gen 1).

5. **Genuine Godelian self-reference works.** M (PTC-Lisp) selects operators for
   solvers (PTC-Lisp), is mutated by those same operators, and runs in the same
   sandbox. Authors (PTC-Lisp) generate problems that solvers attempt. All three
   species share the representation. DGM-H costs $500/run. This costs <$5.

### What's different from the original plan

- **No compile-and-test tool** (Phase 1). Not needed — M controls mutation strategy
  externally rather than agents testing code internally.
- **No evolved prelude** (Phase 2). The prelude concept was replaced by M selecting
  `:llm_mutation` which gives the solver access to LLM-generated structural patterns.
- **Authors are simpler than planned.** They compute ground truth directly rather than
  generating description + I/O pairs. Natural language descriptions are optional metadata,
  not part of the evolved genome.
- **The unit of evolution is smaller.** Instead of full agent specs (system prompt +
  parameters + prelude), M is a single cond-tree (~15-30 AST nodes) and Authors are
  single expressions (~5-50 nodes). This makes GP mutation viable and keeps costs low.

### Phase A.6: Measurement infrastructure + lambda_llm calibration

Added 6 measurement metrics to MetaEvaluator (`tokens_per_solve`, `hard_solve_rate`,
`llm_precision`, `gp_sufficiency`, `llm_call_count`, `operator_entropy`), extended
FailureVector with AST features (`node_count`, `has_join_pattern`), added LLM-as-M-mutator,
and built `mix meta.sweep` calibration tool.

**lambda_llm calibration results:** At lambda=0.0, evolved M achieves 1.0 solve rate
(100%, including hard cross-dataset joins) using 86k tokens. At lambda>=5e-5, all M
variants converge to GP-only (0 tokens, 0 hard solves). Break-even lambda = 1.25e-5
(tokens_per_solve ~10k, solve_value ~0.125). The distillation regime requires lambda
∈ [5e-6, 1e-5] — below our initial sweep range.

### Remaining open questions from original plan

Open questions 1, 2, 3 are deferred. Questions 4-6 are partially addressed:
- **Evaluation cost** (Q4): ~$5 for 4 outer generations with 6-10 Authors, 4 M variants.
  Well within budget. Gemini Flash Lite at ~42 tokens/call is extremely cost-effective.
- **Generalization** (Q5): not yet tested. Authors generate problems from the same
  data context — need held-out data to measure overfitting.
- **Program size** (Q6): solver programs range 3-48 AST nodes. No size explosion observed.

## Open Questions

1. **`eval` scope:** How tightly to scope the sandboxed `eval`? Only within `compile-and-test`? Or as a general PTC-Lisp form? The tighter the scope, the safer but less expressive.

2. **Prelude size:** How many functions before the prelude becomes noise? Start small (5-10), measure whether agents actually use them.

3. **Hierarchical agents:** Instead of one agent generating a big program, a coordinator could delegate to specialist sub-agents (planner, solver, verifier). Each sub-agent generates small programs. Evolution operates at two levels: inner (each sub-agent's strategy) and outer (the coordinator's decomposition strategy). Hold for later — adds orchestration complexity.

4. **Evaluation cost:** At 3 runs x 5 tests x 8 candidates = 120 LLM calls per generation. Feasible with haiku; expensive with larger models. Consider haiku for evolution, validate winners on stronger models.

5. **Generalization vs overfitting:** Evolved agents may overfit to the hard suite. The held-out Exercism set (Phase 0, Option C) guards against this. Also: periodically rotate problems in the hard suite.

6. **Program size scaling:** LLMs degrade on large programs. The prelude + `compile-and-test` approach mitigates this by keeping individual generated programs small. Monitor average program size per generation — if it grows, that's a signal to increase prelude investment.
