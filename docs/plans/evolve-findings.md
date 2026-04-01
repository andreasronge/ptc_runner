# Evolve Findings: GP+LLM Hybrid on PTC-Lisp

Status: ACTIVE RESEARCH
Date: 2026-04-01
Branch: gstack
Design doc: `~/.gstack/projects/andreasronge-ptc_runner/andreasronge-gstack-design-20260401-131308.md`

## Summary

Built a genetic programming system that evolves PTC-Lisp programs in BEAM sandboxes.
LLM available as a mutation operator with fitness cost. Tested on 7 problems ranging
from simple filters to 4-step cross-dataset pipelines.

## What Works

### GP on structurally close seeds (no LLM needed)

When seeds contain the right function calls and GP only needs to tweak arguments,
pure GP works reliably. P1 (count filtered products): seeds with wrong threshold
(400, 600) evolved to correct threshold (500) in 1 generation. Zero LLM calls.

### LLM mutation for structural leaps

P3 (employee count per department): seeds had no `group-by`. LLM mutation invented
a `reduce`-based counting approach in Gen 1. The winning program uses zero LLM tokens
at runtime — genuine distillation of LLM knowledge into PTC-Lisp code.

### Decomposed LLM mutation with examples

The LLM mutation prompt needs three things to work reliably:
1. **Problem description** (natural language, what to compute)
2. **Working PTC-Lisp examples** (especially patterns like set-based joins)
3. **Explicit syntax rules** (`[x]` for fn params, `(set list)` not `#{...}`)

With all three, Gemini Flash Lite produces correct cross-dataset join programs
5/5 on P5 and 5/5 on P7. Without the description, 0/5 on both.

### Partial credit scoring

Graded fitness (0.0 to 1.0) prevents population collapse when no program is correct.
Programs producing the right type score 0.2, close values score up to 0.9.
This keeps diversity alive while the population searches for the correct answer.

### Millisecond evaluation

All evaluations run in the BEAM sandbox in <15ms. A full evolution run
(8 generations × 12 individuals × evaluation) takes seconds for the GP part.
The bottleneck is LLM API latency, not computation.

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

## Possible Improvements

### Prompt engineering for LLM mutation

- **Incremental prompting**: instead of "fix the whole program," ask "what ONE
  function call should I add?" then "where should I insert it?" Multiple small
  LLM calls may work better than one big rewrite.
- **Error-specific prompts**: when the program crashes with a specific error
  (e.g., `:arity_error`), include the error in the prompt and ask for a targeted fix.
- **Program decomposition**: ask the LLM to write each step of a pipeline separately,
  then compose them. This avoids the "write a 100-node program in one shot" failure mode.

### Better partial credit

- **Structural similarity**: compare AST structure, not just output values.
  A program using `filter` + `count` on the right dataset should score higher
  than a degenerate program even if numerically further.
- **Intermediate value credit**: run the program, capture intermediate values
  (tool calls, let bindings), compare against the Author's intermediates.
  This gives gradient signal for multi-step pipelines.
- **Type-weighted scoring**: producing a list when a map is expected (0.05) should
  score higher than producing an integer (wrong structure entirely).

### GP operator improvements

- **Guided mutation**: use partial evaluation results to pick mutation targets.
  If a program's output has the wrong type, mutate the outermost form. If the
  value is close but wrong, mutate the filter predicate.
- **Library-aware mutation**: instead of random symbol swaps, know which functions
  are available and what types they expect. Don't swap `count` (coll -> int) with
  `first` (coll -> elem) if the context expects an integer.
- **Template insertion**: have a library of PTC-Lisp "templates" (e.g., filter+count,
  group-by+into, set-join pattern) that mutation can insert at appropriate points.

### Anti-collapse measures

- **Diversity preservation**: use novelty search or fitness sharing to prevent
  the population from converging to one program.
- **Island model**: run multiple sub-populations with different strategies
  (one GP-heavy, one LLM-heavy) and migrate between them.
- **Minimum size threshold**: don't let programs shrink below a minimum node count
  to prevent collapse to degenerate 3-node programs.

## Next Things to Investigate

### 1. Does GP add value over raw LLM generation?

The critical experiment: run the LLM mutation prompt N times (no GP) and compare
success rate to GP+LLM over N generations. If raw LLM succeeds at the same rate,
GP is overhead. If GP finds solutions the LLM alone misses (e.g., by combining
partial successes from multiple LLM calls), that's the value proposition.

### 2. Author co-evolution (Phase 2)

Build the Author population that generates problems. The Author is a PTC-Lisp
program that runs against the data and produces ground truth + description.
Author fitness = `-abs(solver_success_rate - 0.5)`. This creates automatic
curriculum and prevents benchmark saturation.

Key question: how does the Author generate natural language descriptions?
Options: (a) LLM generates description from code, (b) description is part
of the evolved genome, (c) description is derived from the AST structure.

### 3. LLM cost annealing

Start with low LLM cost penalty, increase over generations. Early generations
use LLM mutation freely. Later generations must internalize patterns. Track
average LLM tokens per generation — does it decrease over time?

### 4. Multi-problem generalization

Current setup: one Solver population per problem. Next: one Solver population
evaluated across ALL problems. Can a single evolved program solve multiple
data pipeline tasks? This requires more general programs (closer to a
"harness" than a specific solution).

### 5. Operator analytics

Track which operator produced each individual that enters the top-K.
After 50+ generations, we'll know: what % of improvements come from LLM
mutation vs GP operators? This determines whether to invest in better GP
or better LLM prompting.

### 6. Prelude discovery (reconnect with M0 vision)

When the Solver evolves a useful subexpression (e.g., the set-join pattern),
extract it as a named prelude function. Future generations can use it as a
building block. This is the original M0 vision — discovering reusable
abstractions from execution — but driven by evolution rather than hand-written
analysis.

### 7. Compare with SubAgent.run

The current Solver evolves programs directly. An alternative: evolve the
SubAgent configuration (system prompt, parameters) and let the LLM generate
programs at runtime. This is closer to the Meta-Harness approach. Compare:
which produces better results per dollar spent?
