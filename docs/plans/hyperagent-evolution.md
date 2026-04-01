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

## Open Questions

1. **`eval` scope:** How tightly to scope the sandboxed `eval`? Only within `compile-and-test`? Or as a general PTC-Lisp form? The tighter the scope, the safer but less expressive.

2. **Prelude size:** How many functions before the prelude becomes noise? Start small (5-10), measure whether agents actually use them.

3. **Hierarchical agents:** Instead of one agent generating a big program, a coordinator could delegate to specialist sub-agents (planner, solver, verifier). Each sub-agent generates small programs. Evolution operates at two levels: inner (each sub-agent's strategy) and outer (the coordinator's decomposition strategy). Hold for later — adds orchestration complexity.

4. **Evaluation cost:** At 3 runs x 5 tests x 8 candidates = 120 LLM calls per generation. Feasible with haiku; expensive with larger models. Consider haiku for evolution, validate winners on stronger models.

5. **Generalization vs overfitting:** Evolved agents may overfit to the hard suite. The held-out Exercism set (Phase 0, Option C) guards against this. Also: periodically rotate problems in the hard suite.

6. **Program size scaling:** LLMs degrade on large programs. The prelude + `compile-and-test` approach mitigates this by keeping individual generated programs small. Monitor average program size per generation — if it grows, that's a signal to increase prelude investment.
