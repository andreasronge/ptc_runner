# Evolution Findings: GP+LLM Hybrid on PTC-Lisp

Status: ACTIVE RESEARCH
Date: 2026-04-01 (updated 2026-04-09)
Branch: gstack of ptc_runner on GitHub
Roadmap: `evolution-roadmap.md`
Historical plans: `archive/` (hyperagent-evolution, m0-failure-boundary-mining, meta-evolve-v2-plan, meta-learner-coevolution)

## Background: What is PTC-Lisp and Why Evolve It?

### The problem

When you use an LLM to query data or orchestrate tools, the LLM typically generates
code that runs once and is thrown away. Each new query costs another LLM call. For a
benchmark of 55 problems, that's 55 LLM calls. Run it 3 times for statistical
confidence, that's 165 calls. Evolve 20 agent variants over 10 generations, that's
33,000 calls. It gets expensive fast.

### PTC-Lisp: programs as the unit of work

PTC-Runner is an Elixir library where LLMs write small programs in PTC-Lisp (a
Clojure-like Lisp) instead of returning raw text. These programs run inside isolated
BEAM processes (1 second timeout, 10MB memory limit) and can call tools to access data.

A typical PTC-Lisp program looks like this:

```clojure
;; Count products over $500 — simple filter + count
(count (filter (fn [p] (> (get p :price) 500)) data/products))
```

Or for something more complex, a cross-dataset join:

```clojure
;; Average expense amount for employees in big departments (>30 headcount)
;; This is a 4-step pipeline: group → filter groups → collect IDs → join + average
(let [dept-groups (group-by (fn [e] (get e :department)) data/employees)
      big-depts (set (map first
                       (filter (fn [[dept emps]] (> (count emps) 30)) dept-groups)))
      emp-ids (set (map (fn [e] (get e :id))
                        (filter (fn [e] (contains? big-depts (get e :department)))
                                data/employees)))
      matching (filter (fn [ex] (contains? emp-ids (get ex :employee_id)))
                       data/expenses)]
  (/ (reduce + 0 (map (fn [ex] (get ex :amount)) matching))
     (count matching)))
```

Key properties:
- **Small**: programs are typically 5-60 AST nodes (vs thousands of lines for Python)
- **Fast**: execute in <15ms in the BEAM sandbox
- **Safe**: isolated process, can't escape the sandbox, automatic timeout
- **Structured**: the AST is a simple tree of ~10 node types, amenable to programmatic manipulation

### The idea: evolve programs instead of generating them

Instead of asking an LLM to write a new program every time, what if we:
1. Start with a few seed programs (possibly LLM-generated)
2. Use genetic programming (GP) to mutate and recombine them
3. Let the LLM act as an expensive mutation operator (available but penalized)
4. Over generations, evolution discovers programs that work without needing the LLM

This is "distillation through evolution" — the LLM's knowledge gets compiled into
PTC-Lisp code that runs for free.

### What we built

```
lib/ptc_runner/evolve/
├── individual.ex       # A program with its parsed AST and fitness score
├── evaluator.ex        # Run programs in sandbox, compare output, score fitness
├── operators.ex        # GP mutations: tweak numbers, swap functions, restructure AST
├── llm_operators.ex    # Ask an LLM to improve a program (expensive but creative)
└── loop.ex             # Evolution loop: evaluate → select → reproduce → repeat
```

The evolution loop works like this:

```
Generation 0: [seed programs, possibly wrong]
     ↓ evaluate each against expected output
     ↓ score fitness (correctness - LLM_cost - program_size)
     ↓ select best via tournament
     ↓ reproduce: GP mutation (free) or LLM mutation (costs tokens)
Generation 1: [mutated programs, some better]
     ↓ ... repeat ...
Generation N: [evolved programs, hopefully correct and LLM-free]
```

## Summary

Built a genetic programming system that evolves PTC-Lisp programs in BEAM sandboxes.
LLM available as a mutation operator with fitness cost. Tested on 7 problems ranging
from simple filters to 4-step cross-dataset pipelines.

## What Works

### GP on structurally close seeds (no LLM needed)

When seeds contain the right function calls and GP only needs to tweak arguments,
pure GP works reliably. Example: P1 asks "count products over $500" (answer: 261).
Seeds were wrong — `(> price 400)`, `(> price 600)`, `(< price 500)`. GP's point
mutation operator changed the threshold number, and by Gen 1 found the correct
program. Zero LLM calls.

```
Gen 0: best=-0.0001  correct=0/12   ← no seed is correct
Gen 1: best= 0.9992  correct=1/12   ← mutation found (> price 500)
Gen 9: best= 0.9992  correct=12/12  ← entire population converged
```

### LLM mutation for structural leaps

When the seed programs don't contain the right building blocks (e.g., no `group-by`),
random GP mutations can't invent them. But the LLM mutation operator can. Example:
P3 asks "count employees per department" (answer: `{engineering: 29, sales: 32, ...}`).
Seeds were just `(count data/employees)` — structurally nowhere close.

The LLM mutation invented a `reduce`-based counting approach that nobody on the team
would have written:

```clojure
;; LLM-invented solution (different from the Author's group-by approach)
(let [depts (map (fn [emp] (get emp "department")) data/employees)
      counts (reduce (fn [acc dept]
                       (assoc acc dept (+ (get acc dept 0) 1)))
                     {} depts)]
  counts)
```

The winning program uses zero LLM tokens at runtime — the LLM was only used during
evolution (as a mutation operator), not during execution. This is genuine distillation:
LLM knowledge compiled into PTC-Lisp code that runs for free.

### Decomposed LLM mutation with examples

Early attempts at LLM mutation failed: the LLM would rewrite entire programs but
produce invalid PTC-Lisp syntax (Clojure-like constructs that PTC-Lisp doesn't
support). The fix was decomposed prompting — give the LLM:

1. **Problem description** (natural language, what to compute)
2. **Working PTC-Lisp examples** (copy-pasteable patterns, especially set-based joins)
3. **Explicit syntax rules** (`[x]` for fn params, `(set list)` not `#{...}`)
4. **Diagnosis** of what's wrong ("too high — your filter is too broad")

With all four, Gemini Flash Lite produces correct cross-dataset join programs
5/5 on P5 and 5/5 on P7. Without the description, 0/5 on both. The examples
are critical — the LLM copies the pattern and adapts it to the specific problem.

### Partial credit scoring

Graded fitness (0.0 to 1.0) prevents population collapse when no program is correct.
Programs producing the right type score 0.2, close values score up to 0.9.
This keeps diversity alive while the population searches for the correct answer.

### Millisecond evaluation

All evaluations run in the BEAM sandbox in <15ms. A full evolution run
(8 generations × 12 individuals × evaluation) takes seconds for the GP part.
The bottleneck is LLM API latency, not computation.

## Test Problems

| ID | Description | Type | Difficulty | Answer |
|----|-------------|------|------------|--------|
| P1 | Count products with price > $500 | integer | Easy | 261 |
| P2 | Average order total for delivered orders | number | Easy | 2540.60 |
| P3 | Count employees per department | map | Medium | `{eng: 29, fin: 26, ...}` |
| P5 | Count delivered orders for electronics products | integer | Hard | 32 |
| P6 | Revenue from expensive delivered products | number | Hard | 284689.48 |
| P7 | Avg expense for big departments (>30 headcount) | number | Hard | 998.18 |

Easy = single dataset, one operation. Medium = single dataset, group-by + aggregate.
Hard = cross-dataset join requiring set-based ID lookup across two datasets.

Data: 500 products, 1000 orders, 200 employees, 800 expenses. Deterministic with
seeded RNG `{42, 42, 42}`.

## Problems Found

### 1. Size limit silently kills correct programs

The `max_ast_nodes` default (50) was too low for cross-dataset join programs (57-102
nodes). Correct LLM-generated programs were being filtered out before evaluation.
This was the root cause of P5 and P7 failures — not prompt quality.

**Fix applied**: bumped default to 80. Complex problems may need 120+.

**Lesson**: always log when programs are filtered by size. Silent filtering is debugging poison.

### 2. LLM does most of the work

For problems where LLM mutation succeeds, GP adds minimal value. The LLM generates
the correct program on its first mutation attempt; GP just propagates it through
selection. This was confirmed on P3, P5, and P7 — all solved in 1-3 generations
by LLM mutation, not by GP refinement.

**Open question**: can we find problems where GP iteration genuinely adds value
over a single LLM call? The current evidence says no.

### 3. Without problem description, LLM mutation is blind

When the LLM only sees "produced 972, expected 998" it makes random filter changes
(e.g., filter by status="approved") that don't address the actual issue (wrong subset
of data). The output gap alone doesn't contain enough information to guide structural
changes.

**Implication for co-evolution**: the Author must provide a description, not just I/O
pairs. Pure round-trip synthesis (no description) won't work for hard problems.

### 4. Partial credit can mislead

For P5 (expected: 32), `(count (first data/orders))` = 8 scored higher (0.375) than
`(count (filter ... "delivered" ...))` = 200 (0.2) because 8 is numerically closer
to 32. But the 200-program is structurally much closer to the answer. The scoring
rewards numeric proximity over structural similarity.

### 5. Population collapse on hard problems

Without LLM mutation or with failed LLM mutations, the population collapses to
the smallest program with the highest partial score. `subtree_delete` mutations
shrink programs because smaller wrong programs beat larger wrong programs
(lower size penalty). By Gen 3-5, all individuals are 3-node programs.

### 6. GP operators rarely produce improvements

The cheap operators (point mutation, arg swap, wrap, subtree delete/dup, crossover)
mostly produce broken programs or functionally equivalent programs. No tracking yet
of which operators produce improvements, but observation suggests LLM mutation
accounts for >90% of fitness gains.

## Model Comparison

| Model | P3 (dept count) | P5 (cross join) | P7 (4-step pipeline) | Cost |
|-------|----------------|-----------------|---------------------|------|
| DeepSeek V3.2 | Solved Gen 3 | Not tested w/ desc | Stuck at 0.88 | ~$0.01/call |
| Gemini Flash Lite | Not tested | Solved Gen 1 | Solved Gen 1 | ~$0.001/call |

Gemini Flash Lite is 10x cheaper and produced better PTC-Lisp syntax. The
few-shot examples in the prompt are critical for both models.

## Architecture (what was built)

```
lib/ptc_runner/evolve/
├── individual.ex       # Individual struct, AST node counting, from_source
├── evaluator.ex        # Run programs, output matching, partial credit scoring
├── operators.ex        # 6 GP operators + crossover on PTC-Lisp ASTs
├── llm_operators.ex    # LLM mutation with diagnosis, examples, description
└── loop.ex             # (mu+lambda) selection, elitism, generation logging
```

Key design decisions:
- Per-problem solver populations (Phase 1)
- Tournament selection (size 3) with top-2 elitism
- LLM mutation rate configurable (default 0, set per-run)
- Seeded RNG for deterministic data (`{42, 42, 42}`)
- Data accessed via `data/products` etc. in PTC-Lisp context

## Phase A: Self-Improving Meta-Learner M (April 2026)

### What was built

A meta-evolution system where M variants (PTC-Lisp cond-trees) compete to
select GP operators for the inner evolution loop. M is itself subject to GP
mutation — genuine Godelian self-reference where the meta-learner and its
subjects share the same representation.

```
lib/ptc_runner/meta/
├── failure_vector.ex     # 8-element failure signal (6 original + node_count, has_join_pattern)
├── meta_learner.ex       # M struct with sandbox-based operator selection
├── meta_evaluator.ex     # Runs inner evolve loop with M controlling operators + 6 metrics
├── meta_loop.ex          # Outer (mu+lambda) evolution of M population + LLM-as-M-mutator
├── author.ex             # Coevolved problem generators with difficulty frontier scoring
└── seeds.ex              # 4 seed M variants + 3 baselines + 6 seed Authors
```

Integration: `evolve/loop.ex` accepts an `operator_selector` callback.
`evolve/operators.ex` accepts an explicit `operator:` option. Both are
backward-compatible — existing behavior unchanged when no callback is provided.

Also fixed: nil `step.usage` crash in `evolve/evaluator.ex` (pre-existing bug
exposed by GP mutations producing broken programs).

### Experiment 1: GP-only (no LLM mutation)

**Setup:** 4 seed M variants + 3 baselines, 3 problems (count-expensive,
avg-order, count-all), 8 inner generations, population 12, no LLM.

**Result:** All 7 variants scored identically (0.333 solve_rate — only
the trivial P3 solved). Zero differentiation across M variants.

**Why:** GP operators alone cannot make structural leaps. P1 needed a
threshold change from 400→500 (too far for point mutation). P2 needed
a structural rewrite (count→get+first). M's operator selection is
irrelevant when all operators are equally incapable.

### Experiment 2: GP+LLM (0.3 mutation rate, gemini-flash-lite)

**Setup:** Same variants, 4 problems (added active-expensive), 0.3 LLM
mutation rate, `openrouter:google/gemini-3.1-flash-lite-preview`.

**Result:** All variants solved all 4 problems (1.0 solve_rate). LLM
mutation solved everything by Gen 1-3. Token tracking was broken
(tokens=0 everywhere due to evaluate_population overwriting the field).

**Why:** At 0.3 LLM rate, the LLM fires frequently enough to solve
everything regardless of M's GP operator selection. M is irrelevant
in the other direction — too much LLM help.

### Experiment 3: GP+LLM (0.1 mutation rate, harder problems)

**Setup:** Same variants, 4 problems including cross-dataset join
(eng-expense-count requiring set+contains?+filter across employees→expenses).
LLM rate lowered to 0.1. Token tracking fixed.

**Results:**

| variant | solve | fitness | tokens | entropy |
|---------|-------|---------|--------|---------|
| baseline-random | 0.75 | -10.06 | 10,813 | 0.0 |
| seed-random | 0.75 | -12.47 | 13,215 | 2.43 |
| seed-conservative | 0.75 | -14.53 | 15,283 | 0.0 |
| seed-aggressive | 0.75 | -17.42 | 18,166 | 0.78 |
| seed-adaptive | 0.75 | -18.38 | 19,127 | 0.34 |
| baseline-handwritten | 0.75 | -18.53 | 19,278 | 1.33 |
| baseline-llm-heavy | 1.0 | -33.95 | 34,954 | 0.0 |

**Key findings:**

1. **Cross-dataset join (P3) is the differentiator.** Only baseline-llm-heavy
   solved it, spending 13,924 tokens. All others failed — GP cannot invent
   `set` + `contains?` patterns from seeds that don't contain them.

2. **Token tracking works.** baseline-random: 10,813 tokens. baseline-llm-heavy:
   34,954 tokens. The 3x cost difference is now visible in fitness.

3. **The real tension:** baseline-llm-heavy solves everything (1.0) at 3x cost.
   baseline-random is cheapest but misses P3. The optimal strategy: use LLM only
   for structurally hard problems, GP for the rest.

4. **M's action space is too narrow.** M can select among 6 GP operators but
   cannot request LLM mutation. The GP-vs-LLM decision is made by a random roll
   (10% chance), not by M. M needs `:llm_mutation` as a 7th option to control
   WHEN to spend tokens. That's where distillation happens.

5. **Operator entropy confirms M variants behave differently.** seed-random=2.43
   (all operators), seed-conservative=0.0 (collapsed to arg_swap), seed-aggressive=0.78
   (crossover+subtree_dup). The mechanism works mechanically; the action space
   just can't affect outcomes for hard problems.

### What was built next (Phase A.5)

**`:llm_mutation` as M's 7th operator.** When operator_selector returns `:llm_mutation`,
`produce_child` bypasses the random roll and forces LLM mutation. M now fully controls
the GP-vs-LLM decision. The `llm_mutation_rate` config is only used in the backward-
compatible default path (when no operator_selector is set).

**Author struct + coevolution.** `lib/ptc_runner/meta/author.ex` — Authors are PTC-Lisp
programs that compute ground truth from data context. Author fitness =
`-abs(success_rate - 0.5) - size_penalty`. 6 seed Authors spanning easy (count-all) to
hard (cross-dataset join). Authors mutated with safe operators (point_literal, point_symbol,
arg_swap) and validated — rejected if output type changes or program crashes.

**Three-species MetaLoop.** Authors + M variants + Solvers coevolve. Anchor Authors
(the 6 seeds) persist across all generations to prevent ecosystem collapse. Evolved
Author mutants compete in a separate pool.

### Experiment 4: Three-species coevolution

**Setup:** 4 M seeds (including seed-llm-aware, seed-adaptive with `:llm_mutation`),
6 anchor Authors, author_lambda=3 (3 mutants per gen), 4 outer generations,
llm_mutation_rate=0.0 (M controls LLM decisions), lambda_llm=0.001.

**Results:**

| Gen | M_best | M_tokens | Authors | Author_rate |
|-----|--------|----------|---------|-------------|
| 0 | 0.167 | 9,622 | 6 | 0.50 |
| 1 | 0.375 | 0 | 8 | 0.50 |
| 2 | 0.273 | 0 | 10 | 0.30 |
| 3 | 0.333 | 0 | 10 | 0.30 |
| 4 | 0.250 | 0 | 10 | 0.30 |

**Key findings:**

1. **No ecosystem collapse.** Anchor Authors prevent the death spiral from earlier
   runs. The system runs 4+ generations stably with growing Author diversity.

2. **M improved at Gen 1** (0.167→0.375). First real M improvement observed in
   any experiment. seed-conservative won — never calls LLM, lowest cost.

3. **Author diversity emerges.** Mutant Authors create genuinely different problems:
   `(> 500 (get p "price"))` (reversed comparison), `(> (get p "price") 499)` (shifted
   threshold). The Author pool grew from 6→10 across 4 generations.

4. **Author success rate stabilized at 0.30** — between trivial anchors (rate=1.0) and
   hard anchors (rate=0.0). A difficulty frontier exists and is stable.

5. **LLM-calling M variants were eliminated.** At lambda_llm=0.001, each LLM call
   costs ~1.0 fitness (1000 tokens * 0.001). Solving one problem is worth ~0.167
   (1/6 problems). Net: -0.833 per LLM call. M correctly learns to never call LLM
   because the penalty exceeds the benefit. This is economically rational but means
   the distillation dynamics can't emerge at this penalty level.

6. **tokens=0 after Gen 0.** All LLM-aware M variants eliminated in the first
   selection round. The surviving M (seed-conservative) and its offspring never
   return `:llm_mutation`.

## Phase A.6: Measurement Infrastructure + lambda_llm Calibration (April 2026)

### What was built

Enhanced the three-species coevolution with comprehensive measurement metrics and
a lambda_llm calibration sweep tool. Also extended M's representation with AST
features and added LLM-as-M-mutator.

**Measurement metrics added to MetaEvaluator:**
- `tokens_per_solve` — total LLM tokens / problems solved (distillation metric)
- `hard_solve_rate` — solve rate on cross-dataset/grouped problems only
- `llm_precision` — successful LLM solves / problems with LLM tokens used
- `gp_sufficiency` — problems solved without LLM / total solved
- `llm_call_count` — how many times M selected `:llm_mutation`
- `operator_entropy` — per-M-variant Shannon entropy of operator distribution

**FailureVector AST features:**
- `node_count` — AST size of the individual being mutated
- `has_join_pattern` — whether the program uses `set` + `contains?` (join indicator)

**LLM-as-M-mutator:** MetaLoop can now apply LLM mutation to M itself (controlled
by `m_llm_mutation_rate` config). The LLM receives M's source, performance metrics,
and a strategy diagnosis, then rewrites the cond-tree.

**Calibration sweep:** `mix meta.sweep` runs MetaLoop at multiple lambda_llm values
and produces a comparison summary. Logs per-generation metrics to JSON files.

### Experiment 5: lambda_llm = 0.0 (no LLM penalty)

**Setup:** 4 M seeds (seed-random, seed-conservative, seed-llm-aware, seed-adaptive),
6 anchor Authors, 4 outer generations, llm_model=gemini-2.0-flash-lite,
llm_mutation_rate=0.0 (M controls LLM decisions), lambda_llm=0.0 (no LLM cost).

**Results (Gen 1):**

| M variant | solve | tokens | tok/solve | llm_prec | gp_suf | hard_solve |
|-----------|-------|--------|-----------|----------|--------|------------|
| meta-2451 (evolved) | **1.000** | 70,896 | 10,128 | 1.00 | 0.00 | **1.00** |
| seed-llm-aware | **1.000** | 66,357 | 9,480 | 1.00 | 0.14 | **1.00** |
| seed-adaptive | 0.857 | 57,026 | 9,504 | 0.83 | 0.17 | **1.00** |
| seed-random | 0.429 | 11,438 | 3,813 | 1.00 | 0.33 | 0.00 |
| seed-conservative | 0.143 | 0 | 0 | 0.00 | 1.00 | 0.00 |

**Key findings:**

1. **M strategies differentiate massively at lambda=0.0.** From 0.143 (conservative,
   GP-only) to 1.000 (llm-aware, mostly LLM). The flat scores from Experiment 3
   (all 0.333) are gone — removing the LLM penalty reveals the actual strategy space.

2. **Evolved M (meta-2451) achieved 100% solve rate.** A GP mutation of a seed M
   produced a variant that solves all 7 problems including cross-dataset joins. Evolution
   can improve M, not just propagate the best seed.

3. **hard_solve_rate is the differentiator.** seed-conservative and seed-random both
   fail hard problems (0.0 hard solve). seed-adaptive and seed-llm-aware solve them
   (1.0 hard solve). The new metric correctly identifies this.

4. **gp_sufficiency reveals the cost structure.** seed-conservative achieves 1.0 GP
   sufficiency (all solves from GP) but only 0.143 solve rate. seed-llm-aware achieves
   0.14 gp_sufficiency (mostly LLM) but 1.000 solve rate. The tradeoff is quantified.

5. **llm_precision is uniformly high** (0.83-1.00 for variants that use LLM). When M
   does call LLM, it works. The problem isn't LLM effectiveness but M's decision about
   WHEN to call it.

6. **tokens_per_solve is ~10k for LLM-heavy variants** (~$0.001/solve with Gemini Flash
   Lite). This is the baseline cost before distillation.

### Experiment 6: Full lambda_llm calibration sweep

**Setup:** 4 lambda values (0.0, 5e-5, 1e-4, 1e-3), 4 outer generations each,
same M seeds and Authors. `mix meta.sweep` with gemini-2.0-flash-lite.

**Results (best M per lambda):**

| lambda | best_M | solve_rate | tokens | tok/solve | hard_solve | gp_suf |
|--------|--------|-----------|--------|-----------|------------|--------|
| 0.0 | meta-7069 (evolved) | **1.000** | 86,052 | 8,605 | **1.00** | 0.10 |
| 5e-5 | seed-conservative | 0.375 | 0 | 0 | 0.00 | 1.00 |
| 1e-4 | seed-conservative | 0.182 | 0 | 0 | 0.00 | 1.00 |
| 1e-3 | seed-conservative | 0.444 | 0 | 0 | 0.00 | 1.00 |

**Key findings:**

1. **The sweet spot is below 5e-5.** At every non-zero lambda tested, seed-conservative
   (GP-only) wins because LLM costs exceed solve benefits. Break-even analysis:
   tokens_per_solve ~10k, solve_value = 1/num_problems ~= 0.125. Break-even lambda =
   0.125 / 10000 = **1.25e-5**. The sweep missed it — need lambdas below 5e-5.

2. **At lambda=0.0, evolution produces a 100% solver.** meta-7069 (evolved M) achieves
   1.0 solve rate including hard problems, using 86k tokens. This proves the mechanism
   works when LLM has no cost. gp_sufficiency=0.10 confirms LLM did the heavy lifting.

3. **At non-zero lambdas, all M variants converge to GP-only.** Even at 5e-5, every
   M variant has 0 tokens and 1.0 gp_sufficiency. LLM-using variants are eliminated
   in early selection rounds.

4. **The distillation dynamics require lambda < 1.25e-5.** Above this, LLM is always
   uneconomical. Below it, LLM is net-positive for hard problems. The interesting
   regime is lambda ∈ [5e-6, 1e-5] where hard-problem LLM calls have positive ROI
   but easy-problem calls don't (since GP already solves easy problems at 0 token cost).

### Example Programs from Each Population

All examples from Experiment 5, lambda=0.0, Gen 1.

**M variants (operator selectors)** — cond-trees that take a failure vector and return an operator:

```clojure
;; meta-2451 (evolved, 100% solve) — calls LLM for small stuck programs
(fn [fv]
  (cond
    (get fv :compile_error)            :point_mutation
    (get fv :timeout)                  :subtree_delete
    (get fv :size_bloat)               :subtree_delete
    (get fv :wrong_type)               :llm_mutation
    (and (< (get fv :partial_score) 0.3)
         (< (get fv :node_count) 20))  :llm_mutation
    (get fv :no_improvement)           :crossover
    (< 0.8 (get fv :partial_score))    :arg_swap
    :else                              :point_mutation))

;; seed-conservative (14% solve, 0 tokens) — never calls LLM
(fn [fv]
  (cond
    (get fv :compile_error)  :point_mutation
    (get fv :timeout)        :subtree_delete
    (get fv :size_bloat)     :subtree_delete
    (get fv :wrong_type)     :arg_swap
    (get fv :no_improvement) :crossover
    :else                    :point_mutation))
```

Note: meta-2451 differs from its parent (seed-adaptive) by a GP mutation that flipped
`(< (get fv :partial_score) 0.8)` to `(< 0.8 (get fv :partial_score))` — reversing
the comparison. This accidentally made it call `:arg_swap` less often and `:point_mutation`
more, slightly changing the operator distribution. The strategy difference is marginal;
both llm-aware M's achieve 100% solve.

**Authors (problem generators)** — programs that compute ground truth from data context:

```clojure
;; author-count-filtered [ANCHOR, easy] — count products above price threshold
(count (filter (fn [p] (> (get p "price") 500)) data/products))

;; author-cross-dataset [ANCHOR, hard] — cross-dataset join: engineering expenses
(let [eng-ids (set (map (fn [e] (get e "id"))
                        (filter (fn [e] (= (get e "department") "engineering"))
                                data/employees)))
      eng-expenses (filter (fn [ex] (contains? eng-ids (get ex "employee_id")))
                           data/expenses)]
  (count eng-expenses))

;; author-2440 [EVOLVED from author-grouped-count] — mutated field name
;; GP point_symbol changed "department" → "department_mut" creating a new problem
(let [grouped (group-by (fn [e] (get e "department_mut")) data/employees)]
  (into {} (map (fn [[k v]] [k (count v)]) grouped)))
```

Author mutations create genuinely different problems by tweaking field names and
thresholds. `"department_mut"` doesn't exist in the data, so the grouped result is
`{nil: 200}` — a trivially solvable problem (fitness penalized for being too easy).

**Solvers (evolved programs)** — best program per problem, from seed-llm-aware's inner loop:

```clojure
;; Easy: count all products (solved by GP, 0 LLM tokens)
(count data/products)

;; Medium: average of delivered orders (LLM-assisted, 947 tokens)
(let [delivered-orders (filter (fn [x] (= (get x :status) "delivered")) data/orders)]
  (/ (reduce + 0 (map (fn [x] (get x :total)) delivered-orders))
     (count delivered-orders)))

;; Hard: cross-dataset join for engineering expenses (LLM-invented, 15559 tokens)
(let [eng-ids (set (map (fn [e] (get e :id))
                        (filter (fn [e] (= (get e :department) "engineering"))
                                data/employees)))
      eng-expenses (filter (fn [ex] (contains? eng-ids (get ex :employee_id)))
                           data/expenses)]
  (count eng-expenses))
```

The hard solver program was invented by LLM mutation — GP cannot discover `set` +
`contains?` patterns from seeds that don't contain them. Once invented, the program
runs for free (~5ms in the BEAM sandbox, 0 tokens at runtime).

## Phase A.7: Branch-Level Crossover + Fine Lambda Sweep (April 2026)

### What was built

**Branch-level crossover for M variants.** `crossover_m/2` in `meta_loop.ex` extracts
cond branches from two parent M's, shuffles and samples them, and recombines into a
valid `(fn [fv] (cond ...))` offspring. Always preserves an `:else` fallback branch.
New `reproduce_m/2` uses 50% crossover + 50% mutation (configurable via `m_crossover_rate`).

Crossover offspring validity: 100% in testing (5/5). Cond branches are semantically
modular units (condition → operator), making them natural crossover points. This was
the recommendation from a FirstPrinciples + Council analysis comparing crossover,
genotype/phenotype separation, and epistatic interactions.

**LLM call cap.** `max_llm_calls_per_problem` (default 5) in MetaEvaluator. When M
requests `:llm_mutation` past the cap, forced to `:point_mutation`. Prevents degenerate
M variants from burning excessive time/tokens.

**Model default.** `meta.sweep` now defaults to `gemini-flash-lite` (resolved via
`LLM.Registry.resolve!`). Previous runs required manual `--llm-model` flag.

**Performance.** Attempted parallel M evaluation via `Task.async_stream` but Finch
connection pool exhaustion at >2 concurrent LLM-calling tasks forced sequential M eval.
Author generation remains parallel. Wall-clock timing per lambda point and per-M
evaluation added.

### Experiment 7: Fine lambda_llm calibration sweep

**Setup:** 5 lambda values (0.0, 1e-6, 5e-6, 1e-5, 2e-5), 4 outer generations,
gemini-flash-lite, m_crossover_rate=0.5, max_llm_calls_per_problem=5, 6 anchor Authors.

**Results (best M per lambda):**

| lambda | best_M | solve_rate | tokens | tok/solve | hard_solve | gp_suf |
|--------|--------|-----------|--------|-----------|------------|--------|
| 0.0 | meta-2155 | 0.286 | 4,646 | 2,323 | 0.00 | 0.50 |
| 1e-6 | meta-28251 | 0.375 | 5,629 | 1,876 | 0.00 | 0.33 |
| 5e-6 | meta-56022 | **0.429** | 4,733 | **1,578** | 0.00 | 0.33 |
| 1e-5 | meta-82186 | **0.429** | 4,685 | **1,562** | 0.00 | 0.33 |
| 2e-5 | meta-103373 | **0.429** | 4,685 | **1,562** | 0.00 | 0.33 |

**Key findings:**

1. **The distillation regime is lambda ∈ [5e-6, 2e-5].** Solve rate plateaus at 0.429
   with lowest token cost. Unlike Experiment 6 where all non-zero lambdas killed LLM
   use, these finer lambdas allow LLM while penalizing excess. The break-even prediction
   of 1.25e-5 falls squarely in the observed sweet spot.

2. **All best M's are evolved variants** (meta-XXXX, not seeds). Crossover is producing
   winners — no seed M survived as best in any lambda point. This validates the
   crossover mechanism.

3. **hard_solve_rate = 0.0 everywhere.** No cross-dataset joins solved in any run.
   The LLM call cap at 5 is likely too low — hard problems need structural invention
   that may require more LLM attempts. Previous experiments without caps solved hard
   problems at lambda=0.0.

4. **lambda=0.0 scored worst** (0.286) — counterintuitive. With crossover producing
   more diverse M variants (some LLM-heavy), the population may be spending tokens
   on variants that don't help. Non-zero lambda provides selection pressure against
   wasteful LLM use.

5. **gp_sufficiency = 0.33-0.50** across all lambdas. About a third of solves come
   from GP alone, the rest need LLM. No distillation trend over 4 generations —
   tok/solve is stable, not decreasing.

6. **Timing: ~3-4 min per lambda point** (5 points in 19 min). Sequential M evaluation
   with LLM call cap is fast enough. Parallel M evaluation was attempted but caused
   Finch connection pool exhaustion.

### What's next

See `evolution-roadmap.md` for future directions and next experiments.
