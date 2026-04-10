# Folding Evolution: Protein-Inspired Genotype-Phenotype Mapping for PTC-Lisp

Status: ACTIVE (Phase 1-2 + measurement + dynamics + triad coevolution)
Date: 2026-04-10
Updated: 2026-04-10
Context: Evolved from the meta-learner M work (see `evolution-findings.md`). The question shifted from "how to evolve better operator selectors" to "how does the development process itself affect evolvability?"

## Core Idea

The genotype is a string. A folding process arranges the string in 2D space. Characters that end up adjacent bond to form PTC-Lisp fragments. The assembled fragments are the phenotype — a runnable PTC-Lisp program. The folding is the development process: it creates a non-linear mapping between genotype (sequence position) and phenotype (program structure).

This is inspired by protein folding, where a linear amino acid chain folds in 3D based on local interactions, and the folded shape determines function. Two amino acids far apart in the sequence can end up adjacent in the fold, creating an "active site."

## Why Folding?

In direct encoding (current M), genotype = phenotype. Every mutation directly changes behavior. This makes the fitness landscape rugged — most mutations break the program.

Folding introduces indirection:
- **Neutral mutations**: Changing a spacer character changes the fold but might not change which fragments bond. Hidden diversity accumulates.
- **Distant interactions**: A mutation at position 3 changes the fold so positions 15 and 22 are no longer adjacent — destroying one rule and potentially creating another. One mutation, many phenotypic effects (pleiotropy).
- **Cryptic variation**: Neutral mutations create diversity that becomes functional when the environment changes. The genotype carries latent potential.
- **Non-linear crossover**: String splicing is simple but the phenotypic effect is complex — the fold of the tail from parent B meets the fold of the head from parent A, creating novel adjacencies at the splice point.

## Architecture

```
Genotype (string)
    ↓ fold onto 2D grid
Spatial arrangement (characters on grid)
    ↓ find adjacent pairs (bonding)
Fragment pairs (guard+function, function+data, etc.)
    ↓ assemble via chemistry rules
PTC-Lisp AST
    ↓ run in sandbox
Output → fitness
```

## Step 1: Character Properties

Each character has a **fragment type** (what PTC-Lisp piece it represents) and a **fold instruction** (how it bends the chain).

### Fragment Types

```
Functions (consume adjacent fragments):
  A → filter     B → count      C → map
  D → get        E → reduce     F → group-by
  G → set        H → contains?  I → first

Connectors (binary operators):
  J → +          K → >          L → <
  M → =          N → and        O → or
  P → not        Q → fn [x]     R → let

Data sources (leaf nodes):
  S → data/products    T → data/employees
  U → data/orders      V → data/expenses

Field keys:
  a → :price     b → :status    c → :department
  d → :id        e → :name      f → :amount
  g → :category  h → :employee_id

Literals:
  0-9 → numbers (0→0, 1→100, 2→200, ... 9→900)

Spacers (affect fold only, no code):
  W → straight   X → turn left  Y → turn right  Z → reverse
```

### Fold Instructions

```
Uppercase letters → turn left
Lowercase letters → straight (continue current direction)
W,X,Y,Z → explicit fold override (straight, left, right, reverse)
Digits → straight
```

## Step 2: Folding

Walk the genotype string character by character, placing each on a 2D grid.

```
State: {grid, position, direction}
Initial: {empty_grid, (0,0), :right}

For each character:
  1. Place character at current position
  2. Compute new direction from fold instruction
  3. Advance position one step in new direction
  4. Self-avoidance: if position occupied, try turning left, then right, then skip
```

### Example Fold

```
Genotype: "QDaK5XASBw"

Q(fn) at (0,0), turn left → heading up
D(get) at (0,-1), turn left → heading left
a(:price) at (-1,-1), straight → heading left
K(>) at (-2,-1), turn left → heading down
5(500) at (-2,0), straight → heading down
X(spacer) at (-2,1), turn left → heading right
A(filter) at (-1,1), turn left → heading up
S(data/products) at (-1,0), turn left → heading left
B(count) at (-2,0) OCCUPIED → self-avoid → (-2,0) skip → advance
w(spacer) → ...

Grid:
       -2    -1     0
  -1:   K     a     D
   0:   5     S     Q
   1:         A
```

## Step 3: Bonding Chemistry

After folding, scan the grid for adjacent character pairs (including diagonals). Adjacent fragments bond according to fixed chemistry rules — the "physics" of this universe.

### Bond Rules

```
Priority order (first applicable rule wins):

1. get + field_key         → (get x key)
     D adjacent to a       → (get x :price)

2. comparator + two values → (comparator val1 val2)
     K adjacent to (get x :price) and 5  → (> (get x :price) 500)

3. fn + expression         → (fn [x] expression)
     Q adjacent to (> (get x :price) 500) → (fn [x] (> (get x :price) 500))

4. filter + fn + data      → (filter fn data)
     A adjacent to (fn [x] ...) and S     → (filter (fn [x] ...) data/products)

5. count/first + collection → (count collection) or (first collection)
     B adjacent to (filter ...) → (count (filter ...))

6. map + fn + collection   → (map fn collection)
7. reduce + fn + init + coll → (reduce fn init collection)
8. group-by + fn + coll    → (group-by fn collection)
9. set + collection        → (set collection)
10. contains? + set + value → (contains? set value)
11. let + bindings          → (let [...] body) — collects adjacent bound expressions
12. and/or + two exprs     → (and expr1 expr2)
13. not + expr             → (not expr)
```

### Multi-Step Assembly

Chemistry operates in passes (like embryonic development):

**Pass 1 — Leaf bonds**: get+key, data references, literals. Smallest fragments form first.

**Pass 2 — Predicate bonds**: comparators combine with pass-1 fragments. fn wraps predicates.

**Pass 3 — Structural bonds**: filter/map/reduce combine with fn and data. count/first wrap collections.

**Pass 4 — Composition bonds**: let bindings, set operations, contains? checks. Cross-dataset joins emerge here.

Each pass only bonds fragments from the current and previous passes. What's built in pass 1 constrains what's possible in pass 2. This prevents ambiguity (a fragment can't bond two ways simultaneously) and creates developmental cascades.

### Example Assembly

```
Grid:
       -2    -1     0
  -1:   K     a     D
   0:   5     S     Q
   1:         A

Pass 1 (leaves):
  D adjacent to a → (get x :price)
  S stays as data/products
  5 stays as 500

Pass 2 (predicates):
  K adjacent to (get x :price) and 5 → (> (get x :price) 500)
  Q adjacent to (> ...) → (fn [x] (> (get x :price) 500))

Pass 3 (structure):
  A adjacent to (fn [x] ...) and S → (filter (fn [x] (> (get x :price) 500)) data/products)

Phenotype: (filter (fn [x] (> (get x :price) 500)) data/products)
```

A 10-character genotype folded into a valid PTC-Lisp filter expression.

## Step 4: Genetic Operators

### Mutation

```
Point mutation:  flip one character to a random character
Insertion:       insert a random character at a random position
Deletion:        delete a character at a random position
```

Point mutations are conservative (change one fragment or fold instruction). Insertions/deletions are disruptive (shift the entire downstream fold — frameshift, like biology).

### Crossover

```
Single-point splice:
  Parent A: "QDaK5XASBw"
  Parent B: "CEhT3YFGdR"
  Cut A at 4, Cut B at 6:
  Offspring: "QDaK" + "FGdR" = "QDaKFGdR"
```

The head folds the same as parent A. At position 4, the fold continues with parent B's characters. New adjacencies appear at the splice point — novel bonds that neither parent had.

## Coevolution: Single Population, Multiple Roles

The folding is the representation layer. The coevolution provides changing selection pressure so evolution doesn't plateau.

### Design Principle: One Population, Role Fluidity

Instead of separate host/parasite populations, all individuals share the same folded genotype representation. An individual's role is determined by the interaction context, not its identity. In one matchup, individual A is the solver and B is the tester. In another, B solves and A tests. In later phases, individuals can also rewrite, compress, or repair each other.

This is a stronger research question than classic host-parasite: **how does one common genotype-phenotype map support multiple ecological functions?** It enables niche emergence rather than niche assignment — some lineages may specialize as solvers, others as testers, others as rewriters, even though they all share the same representation.

### Phase 1: Solver + Tester (start here)

Every individual can play two roles:

**Solver mode**: Given a task input (data context + question), execute as a PTC-Lisp program and produce output.

**Tester mode**: Given a data context, generate a `{input, expected_output}` pair that tests another individual.

Each generation, sample matchups:
- A solves, B's test case evaluates A
- B solves, A's test case evaluates B
- Both solve the same static problem set (baseline)

```
Fitness = w1 * solve_performance
        + w2 * test_effectiveness    (how many peers fail on my tests)
        + w3 * robustness            (how few peer tests break me)
```

This is similar to parasitic coevolution (Hillis 1990) but with one population instead of two. The arms race emerges from role switching, not population separation.

### Phase 2: Genotype-Level Rewriting

**Key insight**: PTC-Lisp is a sandboxed data-pipeline DSL without meta-programming (`quote`, `eval`, AST manipulation). Programs cannot rewrite other programs at the AST level. But they *can* propose edits at the **genotype string level**, and the folding creates the semantic effects.

A "rewriter" individual outputs a splice instruction when given a target genotype:
```
rewrite(target_genotype) → {position, length, replacement_chars}
```

The fold infrastructure applies the splice and tests whether the resulting phenotype is preserved or improved. This is more interesting than AST-level rewriting because:
- Genotype edits have **non-linear phenotypic effects** through folding
- A rewriter that learns to manipulate fold topology is discovering the structure of the development process itself
- It tests whether the folding representation is amenable to **directed modification**, not just random mutation

New interaction types:
- A rewrites B's genotype → test if phenotype preserved/improved
- A compresses B → shorter genotype, same phenotype on test archive

New fitness components:
```
+ w4 * rewrite_success       (edits that preserve/improve peers)
+ w5 * compression_ability   (shorter genotypes, same behavior)
+ w6 * rewrite_resistance    (robustness to peer rewrites)
```

**Constrained rewrite operations** (to prevent search space explosion):
- Replace one character at a position
- Insert 1-3 characters at a position
- Delete 1-3 characters at a position
- Splice: replace a substring of length 1-5

### Phase 3: Full Ecology (Competitive Repair)

The complete interaction cycle:
1. Program A is evaluated on a task and fails partially
2. Program B is given A's genotype and tries to patch it
3. Program C tries to break the patched version (generate a failing test)
4. Program D tries to compress the patched version (shorter, same behavior)

Roles in the full ecology:
- **solver**: produce output for tasks
- **tester**: generate inputs that break peers
- **rewriter**: propose improved genotype edits
- **compressor**: shorten genotypes while preserving behavior
- **repairer**: patch failing genotypes to pass more tests
- **attacker**: exploit brittleness or overfitting

All roles use the same folded genotype representation. Evolution creates specialist niches naturally — some lineages become excellent testers, others become robust solvers, others discover reusable compression patterns.

### Validating Edits: "Still Functional?"

An edit is successful if the edited program meets one of:
1. **Behavioral equivalence on test archive**: same outputs on a stored set of input/output pairs
2. **Property preservation**: maintains monotonicity, idempotence, type constraints, etc.
3. **Functional improvement**: remains valid for the task AND is shorter/faster/more robust

The minimal starting rule: **an edit is successful if the edited program is shorter or cheaper and matches the original on the behavioral test archive.**

### Research Questions This Enables

1. **Does folding create reusable semantic modules?** Do some folded regions consistently become good replacement subtrees?
2. **Does crossover preserve editability?** Are offspring easier to repair or compress than in direct encoding?
3. **Do specialist niches emerge?** Do lineages specialize as solvers/testers/rewriters even with shared representation?
4. **Does program-on-program evolution improve evolvability?** Do lineages that are easy to rewrite adapt faster?
5. **Does genotype-level rewriting discover fold structure?** Do successful rewriters learn which genotype positions have high phenotypic impact?

## Measurement

Beyond solve rate, folding lets us measure properties of the development process itself:

| Metric | What it measures |
|--------|-----------------|
| **Neutral mutation rate** | Fraction of mutations that don't change phenotype |
| **Mutational sensitivity** | How many bonds change per single-character mutation |
| **Crossover viability** | Fraction of crossover offspring that produce valid PTC-Lisp |
| **Fold complexity** | Number of adjacencies in the folded grid |
| **Active site count** | Number of fragment bonds that form |
| **Phenotype diversity** | Unique programs in the population |
| **Cryptic variation** | Neutral mutations that later become functional |
| **Evolvability** | Does fitness keep improving or plateau? |

These metrics characterize the development process, not specific programs. They let us compare folding against other development processes (codon tables, pattern accumulators, stack machines) using the same genotype strings and evolutionary parameters.

## Implementation Status

### What's Built

```
lib/ptc_runner/folding/
├── alphabet.ex              # 62-char alphabet → fragment types (incl. assoc, match, if)
├── fold.ex                  # genotype string → 2D grid placement
├── chemistry.ex             # 5-pass bond assembly → AST fragments (incl. assoc bonds)
├── phenotype.ex             # full pipeline: genotype → PTC-Lisp source
├── operators.ex             # genotype-level genetic operators (point/insert/delete/crossover)
├── individual.ex            # folded individual with auto phenotype development
├── direct.ex                # direct encoding baseline (recursive descent, no folding)
├── direct_individual.ex     # individual using direct encoding
├── loop.ex                  # basic evolution loop (static problems)
├── coevolution.ex           # solver/tester coevolution (multi-context profiles)
├── interactive_coevolution.ex # interactive coevolution with oracle + OutputInterpreter
├── triad_coevolution.ex     # three-role coevolution (solver/tester/oracle — all self-defined)
├── separated_coevolution.ex # three separate populations (solver/tester/oracle — independent)
├── output_interpreter.ex    # interprets tester output as data context modification
├── oracle.ex                # external oracle for computing correct answers
├── metrics.ex               # neutral mutation, crossover preservation, mutation spectrum
├── dynamics.ex              # regime-shift experiments (folding vs direct)
├── challenge_spec.ex        # structured challenge spec (legacy, replaced by OutputInterpreter)
├── challenge_decoder.ex     # hash-based decoder (legacy, replaced by OutputInterpreter)
├── challenge_transform.ex   # spec-based transform (legacy, replaced by OutputInterpreter)
├── archive.ex               # hall-of-fame archive for coevolution
└── match_tool.ex            # structural pattern matching tool for tester context
```

Scripts: `demo/scripts/folding_length_sweep.exs`, `demo/scripts/folding_vs_direct.exs`

Tests: 163 folding-specific tests in `test/ptc_runner/folding/`.

### Findings

**1. Validity rate is near 100%.** Random genotypes of any length almost always produce
*some* valid PTC-Lisp fragment. This is because even a single data source character or
literal counts. The interesting metric is not validity but *complexity* — how many bonds
form, and whether the resulting program uses higher-order functions.

**2. The plan's example genotype doesn't fully assemble.** `QDaK5XASBw` was designed to
produce `(filter (fn [x] (> (get x :price) 500)) data/products)` but the actual fold
puts `K` (comparator) 2 cells away from the assembled `(get x :price)`, so they can't
bond. The comparator instead bonds with the adjacent literal `500` and data source `S`.
This is correct behavior — it's a property of the fold geometry, not a bug. The genotype
would need different fold instructions to bring them closer. **Implication**: evolution
must discover genotypes where the fold creates the right adjacencies, not just the right
characters. This is the whole point of the representation.

**3. Data sources must emit `{:ns_symbol, :data, name}` not `{:symbol, name}`.** PTC-Lisp
resolves `data/products` by stripping the `data/` prefix and looking up `"products"` in
context. The initial implementation emitted `{:symbol, :products}` which formatted as bare
`products` — an unbound variable. Fixed to emit `{:ns_symbol, :data, :products}` which
formats as `data/products` and resolves correctly.

**4. Bond priority matters.** Comparators initially grabbed the first two adjacent values
without preference. This meant raw data sources (pass-0) could be consumed before
assembled get-expressions (pass-1). Fixed by sorting neighbor values: assembled > literal
> data_source. This gives pass-1 results priority as comparator operands.

**5. Single-context coevolution suffers from collusion.** When all individuals are evaluated
against one data context, the population converges on a single phenotype (e.g., literal
`500`). Everyone produces the same output, so everyone "passes" everyone else's test.
Solve scores hit ~1.0 with zero diversity. This is a classic coevolution pathology.

**6. Multi-context profiles solve the collusion problem.** The fix: evaluate each individual
across multiple context variations (different list sizes, different data). A program that
hardcodes `500` produces profile `[500, 500, 500]`. A program that computes `(count
data/products)` produces `[2, 3, 5]`. Profiles must match exactly, so hardcoders can only
match other hardcoders with the same value. With 3 contexts, populations maintain ~15
unique phenotype niches instead of collapsing to 1.

**7. The digit alphabet is too coarse for small-number problems.** Digits map to
`0, 100, 200, ..., 900`. There's no way to produce the literal `3` directly. Programs
must discover computational paths (e.g., `(count data/products)` → 3) rather than
hardcoding. This is actually desirable for the research question — it forces evolution
to compute rather than memorize — but makes simple counting problems harder than they
need to be for initial testing.

**8. Evolution discovers correct programs quickly on simple problems.** `(count
data/products)` is reliably discovered within 1-3 generations from random genotypes
(pop=50, len=10). The key adjacency `BS` (count + data/products) is likely enough in
random strings that tournament selection finds it fast.

### Observed Coevolution Dynamics

With 3 context variations, pop=40, 25 generations:

- **Gen 0**: High diversity (~28 unique phenotypes), low solve scores (~0.03), random tests
- **Gen 2-3**: Rapid convergence into output-profile groups. Test scores peak (~0.6) as
  the population splits into discriminating niches
- **Gen 5+**: Stable equilibrium at ~15 phenotype niches. Solve/test scores balanced
  around 0.8/0.4. The arms race sustains diversity
- **Phenotypes discovered**: `(count data/expenses)`, `(count data/products)`,
  `(> 600 data/products)`, `(= 300 data/orders)`, `(not 100)`, `(first data/products)`,
  `(reduce (fn [x] 300) data/products)`, various comparator expressions

The solve_score/test_score tradeoff is visible: individuals with high solve scores (match
many peers) tend to have lower test scores (their "test" is common/trivial), and vice versa.

### Interactive Coevolution with Match + If (April 2026)

Added structural pattern matching (`tool/match` with `*` wildcards) and `if` conditional
to the folding chemistry. Programs can now branch on structural properties of their peer:

```clojure
(if (tool/match {:pattern "(count *)"}) 200 500)
```

**Alphabet changes:** W→match, X→if, i-z→wildcard (was spacers). Relaxed `if` bonding
to accept any 2+ adjacent fragments (not just predicates), increasing `if` appearance
from 1-10% to 16-31% of random genotypes. Combined `if`+`match` appears in ~1.5%.

**Finding: no `if`/`match` programs survived evolution.** Simple `count` expressions
(2 characters, immediate fitness) outcompete conditional programs before they can
demonstrate an advantage. The `if`/`match` machinery works mechanically (verified via
hand-crafted programs and unit tests) but there is no ecological pressure that rewards
conditionals — `(count data/employees)` scores robust=0.86 uniformly across all contexts.

**Implication:** Conditionals need an environment where different contexts require
different strategies. Currently all contexts have the same data sources, so one expression
works everywhere. To create pressure for conditionals, contexts would need to differ
structurally (e.g., some contexts have products but no employees, forcing the solver to
adapt). This is an environment design problem, not a representation problem.

### Known Issues

1. **Phenotype complexity is low.** Most evolved phenotypes are 1-2 bond assemblies
   (count+data, comparator+values). Deeply nested programs (filter+fn+predicate+data)
   are rare because they require 3+ specific characters in the right fold adjacency.
   Longer genotypes and more generations may help.

2. **No `let` bindings emerge.** The `R` (let) character's bonding rules aren't exercised
   because let-binding requires adjacent bound expressions, which is hard to achieve
   by chance. May need a dedicated pass or different bond rule.

3. **Test effectiveness scoring may need tuning.** The current frontier-reward (peak at
   50% pass rate) penalizes both trivial and very hard tests. This is theoretically sound
   but may not provide enough gradient for tests that are slightly too hard.

4. **Robust score is often 0.** Most evolved phenotypes don't solve the static problem
   (e.g., produce `3` for count_products). The coevolution creates its own internal
   pressure but doesn't align with external objectives. The `w_robust` weight may need
   to be higher, or more diverse static problems are needed.

### Direct Data Transformation (replacing ChallengeDecoder)

The original interactive coevolution used a hash-based `ChallengeDecoder` that mapped
tester output (an integer, boolean, etc.) to a `ChallengeSpec` via modular arithmetic.
This created an arbitrary mapping: output `3` → `:swap_field`, output `4` → `:truncate`,
with no semantic relationship. Small mutations caused completely different challenge types.

**Replaced with `OutputInterpreter`:** The tester's phenotype IS the data transformation.
If the tester produces a list of maps, it directly replaces the relevant data source in
the context. `OutputInterpreter` detects which `data/X` the phenotype references and
replaces that source.

Example flow:
```
Tester phenotype: (filter (fn [x] (> (get x :price) 200)) data/products)
  → output: [%{"price" => 300}, %{"price" => 400}]
  → OutputInterpreter detects "data/products" → replaces products in context
  → Solver runs against modified context
  → Oracle computes correct answer on modified context
```

**Added `assoc` to the alphabet (Y character).** Bonds as `(assoc x :key value)` in
chemistry pass 1. Enables testers to produce transformations like
`(map (fn [x] (assoc x :price 500)) data/products)` — modifying field values, not just
filtering.

**Advantage over ChallengeDecoder:** Small genotype mutations → small transformation
changes → smooth fitness gradient. No arbitrary hash indirection.

### Triad Coevolution: Three Self-Defined Roles

The most elegant coevolution design: every individual plays all three roles depending
on interaction context. No external task definitions needed — the population defines
its own tasks.

**Protocol:** For each sampled triple (solver S, tester T, oracle O):
1. T runs against base context → T_output
2. `OutputInterpreter(T.source, T_output, base_ctx)` → modified_ctx
3. O runs against modified_ctx → expected_answer (oracle defines "correct")
4. S runs against modified_ctx → solver_answer
5. S passes if `solver_answer == expected_answer`

**Fitness:**
```
fitness = w_solve * (fraction of oracle tasks passed under tester challenges)
        + w_test  * (fraction of solvers that fail under my challenges)
        + w_oracle * (my tasks hit the difficulty frontier — ~50% pass rate)
```

**Tester potential gradient:** Since evolving programs that produce list-of-maps is hard
(requires `filter` or `map+assoc` assemblies), a gradient rewards output type:
nil → 0.0, scalar → 0.02, list → 0.08, list-of-maps → 0.15. This provides selection
pressure toward valid data transformations even before they emerge.

**Results (pop=50, genotype_length=30, 30 generations, 3 contexts):**
- Solver and oracle roles activate immediately: solve=0.93, oracle=0.22-0.53
- Test role has gradient (0.02) but testers haven't broken through to list-of-maps yet
- 9-22 unique phenotypes maintained (good diversity)
- Population discovered `(if * * data/expenses)` — returns a list of maps under some
  conditions, approaching a valid tester transformation
- Best fitness: 0.686 with solve=1.0, oracle=0.4

**The tester breakthrough needs:** Longer genotypes (50+, the sweet spot from measurement)
and more generations. The phenotype complexity for `(filter (fn [x] ...) data/X)` requires
4+ characters in fold adjacency — rare at length 25-30 but feasible at 50.

**Key insight:** The three-role design is self-sustaining. Oracles at the difficulty
frontier get high oracle scores; solvers that match many oracles get high solve scores;
testers that create discriminating contexts get high test scores. No external tasks needed.

### Strict Gating + Per-Role Elitism (Option C) — Failed

**Problem:** The original test scoring gave all individuals a nonzero test score via
frontier scoring on base context (even without data transformation). This meant the
tester role was "free" — no selection pressure to actually produce list-of-maps output.

**Solution attempted:**

1. **Strict tester gating:** `test_score = 0` unless the individual produces a valid
   data transformation (list of maps via `OutputInterpreter`).
2. **Per-role elitism:** Top-1 individual by each role score preserved regardless of
   overall fitness.

**Results (pop=50, genotype_length=50, 100 generations, 3 contexts):**
- Per-role elitism kept exactly 1 tester alive from gen 1 onwards
- That tester: `(or (reverse data/products) 100)` — test=0.667, solve=0.0, oracle=0.1
- Overall fitness: 0.23 (far below avg of ~0.49) — survived only via elitism
- Genetic material never spread: crossover offspring inherited tester genes but couldn't
  compete on overall fitness with solve=0.0
- Population converged to solve=0.92, test=0.01, oracle=0.46 — tester remained a
  protected singleton, not a growing niche

**Why it failed:** The fundamental problem is role conflict. In a single population with
`fitness = w_solve * solve + w_test * test + w_oracle * oracle`, a tester-specialist
(test=1.0, solve=0.0, oracle=0.0) gets fitness 0.3 while a solver-specialist (solve=0.9)
gets 0.36. Testers can never compete on overall fitness. Per-role elitism keeps one alive
but can't create a lineage.

### Separated Coevolution: Three Independent Populations

**Design:** Three separate populations, each with unambiguous selection pressure:
- **Solvers** (pop=30): fitness = fraction of (tester, oracle) pairs where solver matches oracle
- **Testers** (pop=30): fitness = frontier_score(solver fail rate under my modification).
  Must produce valid list-of-maps or fitness = 0.
- **Oracles** (pop=30): fitness = frontier_score(solver pass rate on my task).
  Must produce non-nil output or fitness = 0.

No role conflict. A tester doesn't need to also be a good solver.

**Implementation:** `SeparatedCoevolution` module. Script: `demo/scripts/separated_experiment.exs`.

**Results (solver=30, tester=30, oracle=30, genotype_length=50, 100 generations, 3 contexts):**
- **Tester breakthrough by gen 3:** 30/30 testers producing valid data transformations
  (vs 1 protected singleton in triad)
- **Role activation solved:** Full tester population, no role conflict

**Why it works where triad failed:**
1. **No role conflict** — tester fitness is purely "how many solvers fail", not a weighted
   sum with solve/oracle scores
2. **Full population devoted to each role** — 30 individuals exploring tester space vs 1
   protected singleton
3. **Rapid niche filling** — once 2 testers exist in gen 0, crossover spreads the pattern
   to the whole population by gen 3

### Degenerate Equilibrium: Constant-Output Collapse

**Problem discovered through diagnostics:** Despite role activation, all three populations
collapsed to trivial constant-expression agreement. Solver pass rate: 100% — testers
were not discriminating at all.

**Diagnostic analysis (100 gen run with full per-tester pass rate measurement):**
- All 30 solvers: `(= 800 0)` → `false` (constant, ignores data)
- All 30 oracles: `(not 400)` → `false`, `(< 900 800)` → `false` (constants)
- All 30 testers: variations of `(reverse data/expenses)` (valid but vacuous)
- Solver pass rate per tester: **100%** across all 30 testers
- Testers evolved `rest`, `reverse`, `rest+sort` compositions but they can't break
  solvers that ignore data entirely

**Root cause:** Self-referential evaluation without grounding collapses to trivial
agreement. When oracles define "correct = false", every solver that returns `false` passes
every test regardless of tester modifications. This is a known failure mode in competitive
coevolution — "mediocre stable states."

### Hybrid Oracle Attempt — Partial Success, Then Dropped

**Attempted fix:** Anchor oracle fitness to external ground truth tasks:
`oracle_fitness = 0.5 * frontier_score + 0.5 * correctness_vs_ground_truth`

**Result:** Oracle correctness = 0.0 for all 100 generations. No oracle ever produced
output matching `(count data/X)` results because `count` requires a specific 2-character
fold adjacency that's hard to evolve from scratch. The anchor provided zero selection
signal. However, one run incidentally produced 68.7% solver pass rate with data-dependent
phenotypes — but this was initialization-dependent, not a stable outcome.

**Conclusion:** Dropped the correctness anchor. The 68.7% result was a fluke — confirmed
by subsequent runs that reliably collapsed to constants without it. External anchoring
fails when the target phenotype is too hard to reach from random initialization.

### Data-Dependence Gate — The Fix That Worked

**The minimum intervention:** Fitness = 0 if output is identical on all base contexts.
One line of logic. Constants like `false`, `(= 800 0)`, `(> 700 700)` all produce the
same output on every context → fitness 0. Programs like `(count data/products)` produce
different outputs (2, 3, 5) → eligible for scoring.

Applied to both solvers AND oracles. Testers already gated (must produce list-of-maps).

**Results (solver=30, tester=30, oracle=30, genotype_length=50, 200 generations, 3 contexts):**
- Solver avg fitness: **0.66-0.69** (was 0.97-1.0 without gate)
- Discriminating testers: **30/30** at 66.7% pass rate (was 0/30)
- No collapse to constants across 200 generations
- All 30 solvers: `(count (rest (rest data/employees)))` — genuinely data-dependent
- All 30 oracles: `(count (rest (rest data/products)))` — real task definition
- Testers: `(reverse data/employees)`, `(reverse data/orders)`, `(sort data/employees)`
- Trend: solver avg gen 11-100 = 0.663, gen 101-200 = 0.685 → **plateau** (delta 0.022)

**Why it works:** Constants are the degenerate attractor. Block them structurally, and
the system finds data-dependent programs naturally. `rest/reverse` testers ARE sufficient
to discriminate between different `count` expressions — a solver counting employees
responds differently to `(reverse data/products)` than one counting products.

### Coevolution Synthesis: The Complexity Ceiling

After many experiments, a clear pattern emerged:

1. **The folding representation works** — it produces valid PTC-Lisp, enables regime-shift
   adaptation, and has interesting measurement properties
2. **Simple programs dominate every run** — `count`, `rest`, `reverse` win because they're
   1-2 bond assemblies. 4+ bond programs (`filter`, `map+fn`, `let+set+contains`) never
   emerge through evolution
3. **Coevolution finds equilibria, not arms races** — whether single-population, triad,
   or three-population, the system settles quickly and stops innovating

**The fundamental limitation isn't the coevolution design** (we've tried many) — it's that
the folding chemistry's complexity ceiling is too low for meaningful competition. When the
most complex evolved program is `(count (rest (rest data/X)))` (3 bonds), there aren't
enough possible strategies for an arms race. You need a richer phenotype space for testers
to have room to escalate and solvers to have room to adapt.

**What would move the needle** (if pursued):
- Genotype length 80-100 with populations of 100+ and 500+ generations
- Seeded genotypes containing known 4-bond programs (`filter+fn+predicate+data`) so
  evolution starts with complex programs and must maintain/improve them
- Complexity-biased selection — bonus fitness for programs with more bonds

**Or accept that the key findings are in hand.** The folding-vs-direct dynamics result,
the Altenberg connection, and the coevolution design iterations form a coherent research
story. The complexity ceiling is a known limitation, not an unsolved mystery.

## Representation Measurement Results

First sweep across genotype lengths 10, 20, 30, 50. Population 40, 20 generations of
coevolution, 3 context variations. Metrics measured on both random baseline (pre-evolution)
and evolved population (post-coevolution). Script: `demo/scripts/folding_length_sweep.exs`.

### Neutral Mutation Rate

| Length | Phenotype (base) | Phenotype (evol) | Behavioral (base) | Behavioral (evol) |
|--------|-----------------|-----------------|-------------------|-------------------|
| 10     | 67%             | 68%             | 70%               | 81%               |
| 20     | 68%             | 65%             | 74%               | 78%               |
| 30     | 71%             | 72%             | 76%               | 80%               |
| 50     | 69%             | 77%             | 79%               | 81%               |

**Key finding: ~70% phenotype neutrality, ~75-80% behavioral neutrality.** This is high.
Roughly 7 out of 10 point mutations don't change the phenotype string, and ~8 out of 10
don't change behavior. Behavioral neutrality > phenotype neutrality confirms that different
phenotype strings can compute the same thing (e.g., `(not 100)` and `(not 900)` both
return `false`).

**Length effect**: Neutral rate increases slightly with length (more spacer characters to
absorb mutations). Evolution increases neutrality further — evolved populations have
adapted genotypes where functional characters are "protected" by surrounding spacers.

**Interpretation**: The folding representation does provide substantial neutrality. This
validates the core hypothesis — the genotype carries hidden diversity that doesn't affect
the phenotype. Whether this translates to improved evolvability (faster adaptation when
the environment changes) requires a follow-up experiment.

### Crossover Preservation

| Length | Validity (base) | Validity (evol) | Behavior preserved (base) | Behavior preserved (evol) |
|--------|----------------|----------------|--------------------------|--------------------------|
| 10     | 98%            | 99%            | 66%                      | 73%                      |
| 20     | 100%           | 100%           | 54%                      | 56%                      |
| 30     | 100%           | 100%           | 48%                      | 51%                      |
| 50     | 99%            | 100%           | 56%                      | 54%                      |

**Validity is near-100% at all lengths.** String crossover always produces a valid genotype
string, and folding almost always produces some phenotype. This confirms that crossover
viability is trivially high and not a useful metric for this representation.

**Behavioral preservation ranges from 48-73%.** About half of crossover offspring behave
like one of their parents. Whether this is better or worse than GP subtree crossover on
ASTs needs a matched baseline comparison (see direct encoding baseline below).

**Length effect**: Shorter genotypes have higher behavioral preservation (fewer characters
= fewer possible disruptions). Evolution slightly increases preservation.

### Bond Count Distribution (Complexity)

| Length | Avg bonds (base) | Avg bonds (evol) | Max bonds (base) | Max bonds (evol) |
|--------|-----------------|-----------------|------------------|------------------|
| 10     | 0.35            | 1.05            | 5                | 2                |
| 20     | 1.02            | 1.77            | 4                | 4                |
| 30     | 1.40            | 1.43            | 4                | 4                |
| 50     | 3.23            | 4.22            | 8                | 11               |

**Longer genotypes produce more complex phenotypes.** This is the answer to the key
question: low phenotype complexity is a search issue at short lengths, not a property of
the representation. At length 50, random genotypes average 3.2 bonds with max 8. After
evolution, average rises to 4.2 with max 11.

**Length 50 is the sweet spot so far.** It produces meaningfully complex programs (4+ bonds
on average, max 11) while maintaining high neutrality (77% phenotype, 81% behavioral).

**Evolution increases average complexity but reduces diversity.** Baseline populations have
25-38 unique phenotypes; evolved populations converge to 8-17. This is expected — selection
favors fit phenotypes, reducing diversity. The coevolution maintains more diversity than
single-context evolution (which collapsed to 1).

## Folding vs Direct Encoding Comparison

Matched comparison using identical genotypes, same alphabet, same operators. The only
difference is the genotype-to-phenotype mapping. Direct encoding reads characters
left-to-right as a recursive-descent token stream (no fold, no grid, no chemistry).
Script: `demo/scripts/folding_vs_direct.exs`.

### Neutral Mutation Rate

| Length | Folding (phen) | Direct (phen) | Folding (behav) | Direct (behav) |
|--------|---------------|--------------|----------------|---------------|
| 10     | 60%           | 69%          | 61%            | 84%           |
| 20     | 66%           | 83%          | 69%            | 89%           |
| 30     | 69%           | 85%          | 76%            | 92%           |
| 50     | 70%           | 87%          | 76%            | 97%           |

**Direct encoding has substantially higher neutrality.** At length 50, direct encoding
is 87% phenotype-neutral vs folding's 70%. Behavioral neutrality gap is even wider:
97% vs 76%. This is the opposite of the hypothesis — folding was expected to increase
neutrality, but it decreases it.

**Why?** In direct encoding, a mutation to a character late in the genotype only affects
the tail of the expression. If the selected phenotype is determined by the first few
characters (the root of the recursive parse), the tail is irrelevant. In folding, a
mutation anywhere can change the 2D grid layout, shifting which characters are adjacent
and breaking or creating bonds far from the mutation site. Folding creates **more
non-local effects** — which is pleiotropy, not neutrality.

### Mutation Effect Spectrum

| Length | Metric       | Folding | Direct |
|--------|-------------|---------|--------|
| 10     | Neutral      | 62%     | 78%    |
| 10     | Large break  | 37%     | 17%    |
| 10     | Beneficial   | 1%      | 5%     |
| 50     | Neutral      | 73%     | 94%    |
| 50     | Large break  | 24%     | 2%     |
| 50     | Beneficial   | 3%      | 4%     |

**Folding has 5-12x more large breaks.** When a folding mutation IS non-neutral, it's
almost always catastrophic (large behavioral change). Direct encoding's non-neutral
mutations are gentler. Folding also has fewer beneficial mutations.

**This means the folding landscape is more rugged, not smoother.** The fold creates a
cliff-like fitness landscape: most mutations are absorbed (neutral), but the ones that
aren't are destructive. This is the opposite of the design goal.

### Crossover Preservation

| Length | Folding (behav) | Direct (behav) |
|--------|----------------|---------------|
| 10     | 51%            | 85%           |
| 20     | 60%            | 94%           |
| 30     | 55%            | 92%           |
| 50     | 43%            | 97%           |

**Direct encoding preserves crossover behavior 2x better.** At length 50, direct
encoding preserves behavior 97% of the time vs folding's 43%. The gap widens with
length — the opposite of what the folding hypothesis predicted.

**Why?** String crossover in direct encoding splices two prefix-suffix pairs. Since
direct encoding reads left-to-right, the prefix determines the root expression, and
the suffix fills in arguments. Crossover preserves the root from one parent. In folding,
a splice at position N changes the fold of everything after N, which can rearrange
the entire grid topology.

### Complexity

| Length | Folding (avg size) | Direct (avg size) |
|--------|-------------------|-------------------|
| 10     | 7.8               | 17.0              |
| 20     | 11.1              | 18.6              |
| 30     | 15.7              | 26.7              |
| 50     | 16.8              | 34.4              |

**Direct encoding produces 2x more complex phenotypes.** This is because direct encoding
consumes characters sequentially as function arguments, building deep expressions. Folding
requires specific spatial adjacency for bonding, which limits complexity.

### Interpretation

The matched comparison shows that **folding underperforms direct encoding on every
metric measured**: lower neutrality, more catastrophic mutations, worse crossover
preservation, and lower phenotype complexity. The folding representation creates
pleiotropy (non-local effects) rather than the intended neutrality.

However, these are static measurements on random populations. The question that remains
open is whether folding's non-local effects provide an advantage **during evolution** —
specifically:
- Does pleiotropy help explore the search space faster (single mutations create larger
  phenotypic jumps)?
- Does the fold topology create useful **modules** that crossover can recombine?
- Does the 2D spatial structure enable emergent patterns that sequential encoding can't?

These questions require evolutionary dynamics experiments, not just static measurement.
The static metrics suggest folding is a harder search space, but harder can sometimes
mean richer.

### What This Means for the Project

1. **The folding hypothesis (as stated) is not supported.** Folding does not increase
   neutrality or crossover preservation compared to direct encoding. It increases
   pleiotropy and landscape ruggedness.

2. **Reframe the research question.** Instead of "does folding improve evolvability
   through neutrality?", the question becomes "does folding's pleiotropy enable
   qualitatively different evolutionary dynamics?" — e.g., punctuated equilibrium,
   modular recombination, or cryptic variation that activates under environmental change.

3. **The direct encoding baseline is strong** on static metrics. But see the dynamics
   results below — static metrics alone tell an incomplete story.

## Evolutionary Dynamics: Regime Shift Experiment

The decisive test: train both representations on target problems (Regime A), shift to
different targets (Regime B), measure adaptation. Script: `Dynamics.regime_shift/5`.
Settings: pop=50, genotype_length=30, 3 runs averaged. Each regime has 4 target problems
(count expressions on different data sources and contexts).

### Results

```
  Gen │ Fold fit │ Dir fit  │ Phase
  ────┼──────────┼──────────┼──────
    0 │    0.071 │    0.050 │ A
    3 │    0.661 │    0.100 │ A       ← folding finds solutions
    5 │    0.792 │    0.100 │ A       ← folding converged; direct stuck
   20 │    0.792 │    0.100 │ A <<<   ← REGIME SHIFT
   21 │    0.490 │    0.100 │ B       ← folding drops, starts recovering
   30 │    0.626 │    0.100 │ B       ← folding recovering
   40 │    0.667 │    0.100 │ B       ← folding adapted; direct unchanged

  Pre-shift fitness:   Folding 0.792   Direct 0.100
  Post-shift drop:     Folding 0.302   Direct 0.000
  Final fitness:       Folding 0.667   Direct 0.100
  Recovery:            Folding 0.177   Direct 0.000
  Fitness jumps:       Folding 5       Direct 0
```

### Interpretation

**Folding dramatically outperforms direct encoding on evolutionary dynamics.** Direct
encoding never gets above 0.1 fitness (baseline partial credit for wrong-type output) —
it cannot discover `(count data/X)` programs through mutation and crossover. Folding
discovers them by generation 3-4 and achieves 0.792 fitness.

**The regime shift causes a fitness drop for folding (0.792 → 0.490) but it recovers.**
Over 20 post-shift generations, folding climbs from 0.49 to 0.667. Direct encoding shows
no drop (it was never fit) and no recovery.

**Folding shows 5 fitness jumps; direct shows 0.** This is the "punctuated" dynamic the
pleiotropy hypothesis predicts. Folding's non-local mutation effects create sudden
reorganizations — most are harmful (explaining the high break rate in static metrics)
but the rare beneficial ones drive large fitness jumps.

**Why direct encoding fails.** Direct encoding reads left-to-right: a `B` (count) at
position 0 consumes everything after it as its argument. To produce `(count data/products)`,
it needs `B` immediately followed by `S` with no intervening functional characters.
But any functional character between them (another count, a comparator, etc.) gets consumed
first, creating a deep nested expression. The high neutrality of direct encoding is exactly
the problem — most mutations change characters in the deeply nested tail which has no effect
on the output (dominated by the root). The representation is **too canalized**: the root
expression is locked in and mutations can't reach it.

Folding doesn't have this problem. In folding, `B` and `S` just need to be *adjacent in
the 2D grid*, regardless of their position in the genotype string. A mutation at any
position can shift the fold topology, bringing `B` and `S` together or apart. This is
pleiotropy working as intended — non-local mutation effects that can restructure the
program.

### Revised Assessment

The static metrics told an incomplete story:

| Metric | Static winner | Dynamic winner | Resolution |
|--------|-------------|---------------|------------|
| Neutrality | Direct (87%) | Folding | Direct's neutrality is inertia, not robustness |
| Crossover preservation | Direct (97%) | Folding | Direct preserves behavior that was never fit |
| Mutation break rate | Direct (2%) | Folding | Folding's breaks include beneficial reorganizations |
| Task performance | — | Folding (0.79) | Direct never discovers solutions (0.10) |
| Adaptation speed | — | Folding | Recovers from regime shift; direct doesn't |

**Contrary to our initial hypothesis, folded developmental encoding did not increase
mutational neutrality or semantic preservation relative to a direct encoding baseline.
Instead, folding introduced stronger pleiotropic effects, leading to more nonlocal
behavioral consequences under mutation and crossover. However, these pleiotropic effects
proved essential for evolutionary search: the folding representation discovered target
programs that the direct encoding could not reach, adapted to environmental shifts, and
exhibited punctuated fitness dynamics. The direct encoding's high neutrality corresponded
to evolutionary inertia rather than robustness — mutations were absorbed without effect,
but the representation could not explore beyond its initial basin.**

### Theoretical Grounding: Altenberg's Constructional Selection

Our regime shift results align with Lee Altenberg's framework from "Genome Growth and
the Evolution of the Genotype-Phenotype Map" (1995/2023, `private/LeeGGEGPM.pdf`).
Key connections:

**Bonner's Low Pleiotropy Principle vs Directional Selection.** Altenberg discusses
Bonner's (1974) argument that low pleiotropy is necessary for evolvability — mutations
that affect few traits are less likely to be lethal. Our static metrics confirmed this:
direct encoding's low pleiotropy (87% neutrality, 2% large breaks) looks "safer." But
Altenberg distinguishes between *stabilizing* selection (where low pleiotropy wins) and
*directional* selection (where variation aligned with the selection gradient wins, even
if pleiotropic). Our regime shift IS directional selection — the environment changed and
the population needed to reach a new phenotype. Folding's high pleiotropy enabled the
large phenotypic jumps that direct encoding's canalized structure could not achieve.

**Latent Directional Selection (Section 2.7).** Altenberg describes populations stuck on
"constrained peaks" — appearing to be at a fitness maximum, but only because the
genotype-phenotype map can't produce the right variation. This is exactly what happened
with direct encoding at fitness 0.10. It wasn't at a true peak — higher-fitness programs
exist — but the representation created a *kinetic constraint*. The "latent directional
selection" was invisible until folding opened up the right variational dimensions through
its 2D fold topology.

**The Genome as Population (Section 2.4).** Altenberg proposes treating the genome as a
population of genes, where genes with high "constructional fitness" proliferate. For our
genotype strings: subsequences that fold into useful active sites should proliferate
within evolved genotypes over evolutionary time. This predicts measurable motif
enrichment in evolved populations.

**Type I and Type II Effects (Sections 2.4-2.5).**
- Type I (genic selection): genes that produce good duplicates proliferate within the
  genome. Our Phase 3 genotype-level rewriting IS a Type I mechanism — rewriters that
  produce useful edits proliferate.
- Type II (correlated allelic variation): alleles of established genes tend to be
  adaptive because the gene's mode of action is correlated between its origin and its
  subsequent variation. Our folding chemistry creates Type II effects — a character's
  phenotypic contribution depends on its fold neighbors, and the fold topology is
  heritable across generations.

**Wagner's Linear Model (Section 4).** The three-layer model (genotype x → phenotype
y = Ax → fitness) provides a formal framework for our system. Our fold is a non-linear
"A matrix." Altenberg shows that under Gaussian stabilizing selection, new genes with
low pleiotropy are favored. This predicts that under steady-state conditions (no regime
shifts), folding should be at a disadvantage to direct encoding — and our static metrics
confirm this. The key insight: the *right* development process depends on whether the
environment is stable (favor low pleiotropy) or changing (favor directional variability).

### Next Steps

1. **Vary the task difficulty.** The current targets are simple count expressions. Test
   with harder targets (filter, map, group-by) to see if folding's advantage persists
   or if both representations plateau.

2. **Historical contingency.** Run many independent seeds and measure variance in final
   outcomes. If folding produces more divergent evolutionary histories, that supports
   the developmental coupling story.

3. **Red Queen responsiveness.** Under continuous regime shifts (every N generations),
   compare adaptation lag between encodings. Folding should show faster response.
   Altenberg's framework predicts folding wins under directional selection (regime
   shifts) but loses under stabilizing selection (stable targets).

4. **Longer runs.** 20 generations may not be enough to see full recovery. Run 100+
   post-shift generations to measure asymptotic recovery level.

5. **Motif enrichment analysis.** Measure whether evolved genotypes contain repeated
   subsequences that fold into useful active sites, as predicted by Altenberg's
   "genome as population" model. Compare motif frequencies in evolved vs random
   genotypes. If functional motifs proliferate, this is constructional selection
   operating on our genotype strings.

6. **Pleiotropy measurement per mutation.** For each point mutation, count how many
   phenotypic traits change (bonds formed, program output, active sites). Compare
   folding vs direct encoding. Altenberg predicts that under constructional selection,
   surviving genes should have lower pleiotropy than random genes. Measure: do
   mutations in evolved genotypes have lower pleiotropy than mutations in random
   genotypes? If yes, evolution has shaped the genotype-phenotype map itself.

7. **Stabilizing vs directional selection experiment.** Run both encodings under (a) a
   fixed target for 100 generations (stabilizing) and (b) a shifting target every 10
   generations (directional). Measure fitness in both conditions. Altenberg predicts
   direct encoding wins under (a), folding wins under (b). This is the clean test of
   the theoretical framework.

8. **Triad coevolution with longer genotypes.** ✓ DONE — Option C (strict gating +
   per-role elitism) kept 1 tester alive but couldn't create a lineage. Role conflict
   is fundamental in single-population multi-role design.

9. **Separated coevolution.** ✓ DONE — three independent populations solved role
   activation (30/30 valid testers by gen 3). But exposed degenerate equilibrium:
   all populations collapsed to constant-expression agreement (solver pass rate 100%).

10. **Data-dependence gate.** ✓ DONE — fitness = 0 if output identical on all contexts.
    One line of logic blocks constant-expression collapse. Solver pass rate dropped to
    66.7%, all populations compute data-dependent programs. System reaches stable
    equilibrium around `count+rest+reverse` (3-bond programs).

11. **Complexity ceiling identified.** The folding chemistry's phenotype space is too
    shallow for sustained arms races. Most complex evolved program: `(count (rest (rest
    data/X)))` (3 bonds). 4+ bond programs (`filter+fn+predicate+data`) never emerge
    through evolution. This is the fundamental limitation — not coevolution design.

12. **If pursuing further** (optional — key findings may already be in hand):
    - Genotype length 80-100, populations 100+, 500+ generations
    - Seed genotypes with known 4-bond programs for evolution to maintain/improve
    - Complexity-biased selection (bonus fitness for programs with more bonds)

## Implementation Plan

### Phase 1: Fold + Bond + Assemble ✓ DONE

Core pipeline implemented and tested. Validity rate ~100% for random genotypes. Bond
priority sorting ensures assembled fragments preferred over raw values. Data sources
emit namespace symbols for correct PTC-Lisp evaluation.

### Phase 2: Evolution + Coevolution ✓ DONE

Basic loop, profile-matching coevolution, interactive coevolution with oracle, and triad
coevolution (solver/tester/oracle all self-defined). Multi-context profiles prevent
collusion. OutputInterpreter replaced hash-based ChallengeDecoder for direct data
transformation.

### Phase 2.5: Representation Measurement ✓ DONE

Metrics module (neutral mutation rate at 3 levels, crossover preservation, mutation
spectrum, complexity distribution). Direct encoding baseline. Regime-shift dynamics
experiment. Key result: folding loses on statics but wins on dynamics.

### Phase 3: Genotype-Level Rewriting

Add rewriter/compressor roles. Individuals propose genotype string edits on peers.
Justified by dynamics results — folding's pleiotropy enables structural innovation.

### Phase 4: Full Ecology + Competitive Repair

Complete interaction cycle: solve → test → repair → compress → attack.

### Phase 5: Compare Development Processes

Alternative genotype-to-phenotype maps (codon table, stack machine). Same genotypes,
same evolution, different development. Compare metrics.

## Open Questions

### Answered (from implementation)

1. **2D vs 1D folding**: Started with 2D. Works well — 8-connected adjacency provides
   enough bonding opportunities. No reason to try 1D yet.

2. **Self-avoidance strictness**: Implemented as "try left, then right, then skip."
   This works — skipped characters don't contribute to the phenotype, creating junk DNA
   regions that can absorb mutations neutrally.

3. **Bond ambiguity**: Implemented as "first applicable rule wins" with priority sorting
   (assembled > literal > data_source). Deterministic. Works but may limit diversity —
   stochastic bonding could be worth exploring.

### Still Open

4. **Alphabet size**: 62 characters may be too many. The i-z lowercase range is all
   spacers — wasted diversity. Consider: (a) reduce to ~30 chars (functions + data +
   fields + digits + 4 spacers), or (b) add more semantic content to unused chars
   (more field keys, more data sources, small integer literals).

5. **Genotype length**: 10-15 works for simple programs. Longer genotypes (30+) should
   enable deeper nesting but haven't been tested under coevolution. Experiment: compare
   phenotype complexity vs genotype length under coevolution.

6. **Developmental noise**: Not implemented. Deterministic fold means same genotype always
   produces same phenotype. Adding stochastic fold could increase robustness but
   complicates fitness evaluation (need to average over multiple developments).

7. **Digit literal granularity**: Digits map to 0, 100, ..., 900. No way to produce
   small integers (1-99) directly. This forces computation (good for research) but
   limits expressiveness. Consider adding lowercase digit-like chars for small values.

### New Questions (from implementation)

8. **How to increase phenotype complexity?** Most evolved phenotypes are 1-2 bonds.
   Programs like `(filter (fn [x] (> (get x :price) 500)) data/products)` require
   4+ characters in specific fold adjacency — very unlikely by chance. Options:
   - Longer genotypes (more characters = more bonding opportunities)
   - Seeding with known-good genotypes
   - Gradual complexity curriculum (start with 1-bond targets, increase)
   - Modify fold instructions so functional characters cluster more

9. **How many context variations are needed?** 3 contexts prevent collusion effectively.
   Would 5 or 10 create more diverse niches? Or does it just slow convergence? The
   tradeoff is between discrimination power and evaluation cost (N contexts = N
   evaluations per individual per generation).

10. **Should test effectiveness reward novelty?** Current scoring rewards difficulty
    frontier (~50% pass rate). An alternative: reward unique output profiles that no
    other individual produces. This would directly incentivize phenotype diversity.

11. **Can coevolution discover programs that use the data?** Current experiments show
    programs using `count`, comparators, and data sources, but not `filter`, `map`, or
    `get` in combination. The fold geometry makes multi-bond assembly rare. This is the
    key challenge for the representation.

12. **What's the neutral mutation rate?** Not yet measured. Theory predicts folding should
    have higher neutral rate than direct encoding (spacer changes don't affect phenotype).
    Measuring this would validate the core hypothesis.

## Future Investigations

### Near-term (validate the representation)

- **Measure neutral mutation rate**: For each individual, apply 100 point mutations,
  count how many produce the same phenotype. Compare to a direct-encoding baseline.
  This is the key metric for the folding hypothesis.

- **Measure crossover viability**: What fraction of crossover offspring produce valid
  PTC-Lisp? Compare to GP crossover on ASTs. Theory: folding crossover should have
  higher viability because the string splice is always syntactically valid.

- **Phenotype complexity vs genotype length**: Run coevolution with lengths 10, 20, 30,
  50. Measure average bond count and max assembly depth. Find the length where 3+ bond
  programs appear regularly.

- **Context variation count sweep**: Run with 2, 3, 5, 10 contexts. Measure final niche
  count and average phenotype complexity. Find the sweet spot between diversity pressure
  and evaluation cost.

### Medium-term (improve the system)

- **Complexity curriculum**: Start evolution targeting simple programs (count, first),
  then increase target complexity. Alternatively, use the coevolution test scores as
  implicit curriculum — testers naturally create harder problems as solvers improve.

- **Alphabet optimization**: Run evolution with reduced alphabets (30 chars, 20 chars)
  and measure whether increased redundancy improves or hurts evolvability.

- **Bond rule tuning**: The current 4-pass system is rigid. Experiment with:
  - Allowing bonds across passes (pass-2 fragment bonds with pass-3 fragment)
  - Stochastic bond selection when multiple candidates exist
  - Affinity scores (some pairs bond more readily than others)

### Near-term (Altenberg-inspired experiments)

- **Stabilizing vs directional selection.** Fixed target 100 gens vs shifting target
  every 10 gens. Clean test of whether the right G-P map depends on environmental
  stability. Altenberg predicts direct wins stable, folding wins shifting.

- **Motif enrichment.** Extract all 3-character subsequences from evolved vs random
  genotypes. Compute enrichment ratio. If functional motifs (e.g., "DaK" = get+price+>)
  are enriched, constructional selection is operating on the genotype string.

- **Pleiotropy per mutation.** For each point mutation in evolved genotypes, count
  phenotypic traits changed. Compare to random genotypes. If evolved genotypes have
  lower pleiotropy, evolution has shaped the G-P map itself — the central prediction
  of Altenberg's theory.

### Long-term (Phase 3+ from the plan)

- **Genotype-level rewriting**: The most novel aspect of the design. Requires careful
  thought about how a PTC-Lisp program can output splice instructions. Altenberg's
  Type I effect predicts that rewriters producing useful edits will proliferate —
  this is constructional selection operating through program-on-program evolution.

- **Competitive repair cycle**: solve → test → repair → compress → attack. Requires
  rewriting infrastructure first.

- **Compare development processes**: Implement codon table or stack machine as
  alternative genotype-to-phenotype maps. Same genotypes, same evolution, different
  development. Compare neutral mutation rate, crossover viability, evolvability.
  Altenberg's framework predicts that each development process creates a different
  pleiotropy profile, and the "best" process depends on the selection regime.

## References

- Altenberg, L. (1995/2023). "Genome Growth and the Evolution of the Genotype-Phenotype
  Map." In *Evolution and Biocomputation*, Springer LNCS vol. 899, pp. 205-259.
  (`private/LeeGGEGPM.pdf`) — Constructional selection theory, pleiotropy and
  evolvability, genome-as-population model.
- Hillis, W.D. (1990). "Co-evolving parasites improve simulated evolution as an
  optimization procedure." — Parasitic coevolution for sorting networks.
- Bonner, J.T. (1974). *On Development*. — Low pleiotropy principle.
- Wagner, G.P. (1989). "The origin of morphological characters and the biological basis
  of homology." — Linear quantitative-genetic model of G-P maps.
- Kauffman, S.A. (1989). "Adaptation on rugged fitness landscapes." — NK adaptive
  landscape model.
