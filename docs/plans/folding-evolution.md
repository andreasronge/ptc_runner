# Folding Evolution: Protein-Inspired Genotype-Phenotype Mapping for PTC-Lisp

Status: DESIGN
Date: 2026-04-10
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

## Coevolution: The Pressure Layer

The folding is the representation layer. The coevolution provides changing pressure so evolution doesn't plateau. Options explored (in order of complexity):

### Option A: Author Coevolution (simplest, already built)

Authors generate problems. Folded programs solve them. Author fitness = -abs(success_rate - 0.5). Already implemented in MetaLoop. Limitation: Authors only tweak thresholds, problem types don't change.

### Option B: Problem Ladder (static curriculum)

Problems ordered by complexity (count → filter → aggregate → group-by → cross-dataset join). Fitness = highest level solved + partial credit. Clear gradient but finite — once all levels solved, no pressure.

### Option C: Parasitic Coevolution (Hillis 1990)

Two populations coevolve:
- **Hosts**: folded PTC-Lisp programs that compute answers
- **Parasites**: test cases (input context + expected output) that try to break hosts

```
Host fitness:     fraction of parasites answered correctly
Parasite fitness: fraction of hosts that get it wrong
```

Parasites evolve to find inputs that hosts fail on. Hosts evolve to handle whatever parasites discover. Arms race creates open-ended pressure. Proven approach — Hillis showed this outperforms static fitness for sorting networks.

Implementation: parasites are PTC-Lisp programs that generate `{data_context, expected_output}` pairs. A parasite succeeds if most hosts can't reproduce its output. They share the same folding representation — parasites are folded programs too.

### Option D: Red Queen (three-way)

Three coevolving populations:
- **Folders**: genotype → fold → PTC-Lisp program → solve problems
- **Authors**: generate problems from data context
- **Breakers**: modify the data context (rename fields, shift values, add noise)

```
Folder fitness:   problems solved in the adversarial context
Author fitness:   -abs(success_rate - 0.5) (difficulty frontier)
Breaker fitness:  how much they reduce folder success rate
```

Breakers keep the environment shifting so folders can't overfit. A folder that hardcodes `(> (get x :price) 500)` fails when the breaker renames `:price` to `:cost`. Evolution selects for robust, general programs.

### Option E: Symbiosis / Composition

Programs don't just compete — they compose. A program's fitness depends on how useful it is as a building block for other programs.

```
Program A outputs a filtered collection
Program B takes a collection and counts it
Composition B(A) = count of filtered items

A's fitness: how many other programs improve when A fills their input
```

Programs with useful interfaces become keystones. Emergent modularity — programs discover reusable abstractions because reusable programs survive.

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

## Implementation Plan

### Phase 1: Fold + Bond + Assemble

Build the core pipeline: string → 2D grid → fragment bonds → PTC-Lisp AST. Test in REPL with hand-crafted genotypes. Measure: can we produce valid PTC-Lisp from random strings? What's the baseline validity rate?

Location: `lib/ptc_runner/folding/`
- `fold.ex` — string → 2D grid placement
- `chemistry.ex` — bond rules + multi-pass assembly
- `phenotype.ex` — assembled fragments → PTC-Lisp source string

### Phase 2: Evolution Loop

Plug folded programs into a simple evolution loop. Population of genotype strings, tournament selection, crossover + mutation, fitness from running the phenotype in the sandbox. Start with static problems (Author seeds) to validate the mechanism.

Location: `lib/ptc_runner/folding/loop.ex`

### Phase 3: Coevolution

Add parasitic coevolution (Option C). Parasites are also genotype strings that fold into programs generating test cases. Both populations share the same folding representation.

### Phase 4: Compare Development Processes

Implement codon table and/or pattern accumulator as alternative development processes. Same genotype strings, same evolution, same coevolution. Compare the measurement metrics to answer: which development process produces the most evolvable representations?

## Open Questions

1. **Alphabet size**: 26 letters + 10 digits + 26 lowercase = 62 characters. Too many? Too few? Biology uses 4 bases (DNA) or 20 amino acids (proteins). A smaller alphabet increases redundancy (more neutral mutations) but limits fragment variety.

2. **Genotype length**: Short strings (10-20) produce simple programs. Long strings (100+) have more folding complexity but more room for junk DNA. What's the right starting length?

3. **2D vs 1D folding**: 2D gives richer adjacency (8 neighbors per cell). 1D folding (string rewriting / L-system) is simpler. Start with 2D?

4. **Bond ambiguity**: When a fragment is adjacent to multiple compatible partners, which bonds? First match? Strongest affinity? Random? This choice affects evolvability.

5. **Developmental noise**: Should the fold be deterministic or stochastic? Biological protein folding has thermal noise. Adding randomness to the fold means the same genotype can produce different phenotypes — more robust evolution but harder to evaluate.

6. **Self-avoidance strictness**: When the fold hits an occupied cell, what happens? Skip? Bounce? Terminate? This affects how much of the genotype contributes to the phenotype.
