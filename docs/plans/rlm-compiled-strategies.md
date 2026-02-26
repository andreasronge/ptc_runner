# RLM with Compiled Strategies and Function Passing

Exploration of how function passing, compiled agents, and a potential `tree-reduce` built-in can eliminate redundant LLM calls in recursive RLM patterns.

## Problem: Redundant LLM Calls in RLM Recursion

In the current RLM recursive pattern (`:self` tool), every recursion level gets an LLM call that generates a fresh PTC-Lisp program. For tasks like OOLONG-Pairs, intermediate levels rediscover the same strategy:

```
Root LLM call:       "group by city, split large groups, recurse"  → generates code
Child LLM call:      "group by city, split large groups, recurse"  → generates ~same code
Grandchild LLM call: "group by city, split large groups, recurse"  → generates ~same code
Leaf LLM call:       "small enough, compute pairs directly"        → actual useful work
```

A 4-depth tree with branching factor 4 uses ~85 LLM calls. Most are wasted — they regenerate identical strategy code.

Additionally, helper functions like `parse-profile` and `shared-hobbies?` are redefined at every level. Function inheritance (already implemented) reduces this, but each child still gets an LLM call just to write `(map parse-profile ...)` boilerplate.

## Key Insight: Separate Strategy Design from Strategy Execution

The LLM's value is in **designing the algorithm** — deciding how to decompose, what to split on, when to stop recursing. Executing that algorithm recursively is mechanical and doesn't need LLM reasoning at intermediate nodes.

## What's Generic vs Domain-Specific

The RLM contribution is the recursive decomposition pattern, not domain-specific parsing:

| Generic (LLM designs once) | Domain-specific (deterministic) |
|---|---|
| When to recurse (size threshold) | Parsing profile lines |
| How to decompose (group-by-city, split-in-half) | String extraction (regex) |
| How to aggregate (flatten, deduplicate) | Hobby set intersection |
| Parallelism strategy (pmap, batch size) | Format-specific grep patterns |

For benchmarks, the LLM must discover both. For production systems, parsing would be Elixir code and only the decomposition strategy would come from the LLM.

## Approach 1: Separate Parent + Child Agents with `:fn` Parameters

Instead of one `:self` agent, define a strategist parent and a worker child with different prompts. Functions flow via `:fn` signature parameters.

### A: Flat (no recursion)

```elixir
child = SubAgent.new(
  name: "pair-finder",
  prompt: "Find pairs in data/corpus using data/parse_fn and data/match_fn.",
  signature: "(corpus :string, parse_fn :fn, match_fn :fn) -> {count :int, pairs [:string]}",
  max_turns: 3
)

parent = SubAgent.new(
  name: "orchestrator",
  prompt: """
  Define parse-profile and shared-hobbies? helpers.
  Split corpus by city. For each city group, call tool/find-pairs
  passing your helpers as :parse_fn and :match_fn.
  """,
  signature: "(corpus :string) -> {count :int, pairs [:string]}",
  tools: %{"find-pairs" => SubAgent.as_tool(child)},
  max_turns: 5
)
```

Limitation: one level of fan-out only.

### B: Recursive child with `:self` + `:fn`

The child recurses via `:self` and accepts strategy functions. The child must forward `:fn` params on each recursive call:

```clojure
;; Child must forward functions manually
(tool/search {:corpus subset :parse_fn data/parse_fn :match_fn data/match_fn})
```

This works but the LLM must know to forward them — adds prompt complexity.

### C: `:fn` → `def` alias pattern (recommended for this approach)

Parent passes functions once via `:fn`. Child aliases them into `def` on turn 1. Grandchildren inherit via the automatic `:self` inheritance mechanism:

```clojure
;; Child turn 1: alias into namespace
(def parse-profile data/parse_fn)
(def shared-hobbies? data/match_fn)

;; Child turn 2: recurse — grandchildren inherit both via :self
(pmap #(tool/search {:corpus %}) chunks)
```

No need to forward `:fn` params on every recursive call.

### Comparison

| Variant | Recursion | Function flow | LLM burden |
|---|---|---|---|
| A: `:fn` only | None | Explicit per call | Low |
| B: `:self` + `:fn` | Yes | Two channels (`:fn` + inheritance) | High — must forward |
| C: `:self` + `:fn` → `def` | Yes | `:fn` once, then inheritance | Medium — alias once |

## Approach 2: `child_prompt` on SubAgent

Add an optional `child_prompt` field. Root uses `prompt`, `:self` children use `child_prompt`:

```elixir
SubAgent.new(
  prompt: """
  First, define reusable helpers (parse-profile, shared-hobbies?).
  Then subdivide by city and delegate to tool/search.
  Your helpers will be inherited by children automatically.
  """,
  child_prompt: """
  Find pairs in data/corpus where profiles share a city and hobby.
  Use the inherited helpers directly. Recurse if corpus is large.
  """,
  signature: "(corpus :string) -> {count :int, pairs [:string]}",
  tools: %{"search" => :self},
  max_depth: 4
)
```

Implementation: in `resolve_self_tools/2`, create the child with `child_prompt` as its `prompt` (and `child_prompt: nil` so grandchildren reuse the same child prompt).

Advantage: simple, no new concepts. Children never see "define helpers" instructions.

## Approach 3: Compiled Orchestrator + Leaf SubAgentTool

Use `SubAgent.compile` to freeze orchestration logic. Only leaf agents make LLM calls.

```elixir
leaf_agent = SubAgent.new(
  name: "chunk-processor",
  prompt: "Find all pairs of profiles in data/corpus that share city + hobby.",
  signature: "(corpus :string) -> {count :int, pairs [:string]}",
  max_turns: 3
)

orchestrator = SubAgent.new(
  name: "orchestrator",
  prompt: """
  Split data/corpus into chunks of ~50 lines each.
  Call tool/process on each chunk via pmap.
  Aggregate and deduplicate all pairs.
  """,
  signature: "(corpus :string) -> {count :int, pairs [:string]}",
  tools: %{"process" => SubAgent.as_tool(leaf_agent)},
  max_turns: 1  # Required for compilation
)

{:ok, compiled} = SubAgent.compile(orchestrator, llm: llm,
  sample: %{corpus: "PROFILE 1: name=Alice, city=NYC, hobbies=[hiking]\n..."})

# Execute: orchestration is frozen, only leaf agents call LLM
{:ok, step} = SubAgent.run(compiled, context: %{corpus: big_corpus}, llm: llm)
```

The compiled source might be:

```clojure
(let [lines (split-lines data/corpus)
      chunks (partition 50 lines)
      results (pmap #(tool/process {:corpus (join "\n" %)}) chunks)
      all-pairs (flatten (map :pairs results))]
  (return {:count (count (distinct all-pairs)) :pairs (distinct all-pairs)}))
```

Advantage: orchestration is zero-cost after compilation.
Limitation: only one level of fan-out — no recursive decomposition.

### Fully compiled (zero LLM calls)

For deterministic tasks like pair-matching, compile the leaf too:

```elixir
{:ok, compiled_leaf} = SubAgent.compile(leaf_agent, llm: llm,
  sample: %{corpus: "PROFILE 1: ..."})

# Use compiled_leaf as a pure Elixir tool in the orchestrator
orchestrator = SubAgent.new(
  ...
  tools: %{"process" => CompiledAgent.as_tool(compiled_leaf)},
  max_turns: 1
)

{:ok, compiled_all} = SubAgent.compile(orchestrator, llm: llm, ...)
# Zero LLM calls at runtime — entire pipeline is frozen
```

## Approach 4: `tree-reduce` Built-in (Strongest Design)

A PTC-Lisp built-in operator that the engine executes recursively, outside the sandbox. The LLM defines four strategy functions; the engine manages the recursion tree.

### Usage

```clojure
;; LLM designs strategy (one multi-turn session)
(defn should-split? [chunk]
  (> (count (split-lines chunk)) 50))

(defn decompose [chunk]
  (let [lines (split-lines chunk)
        mid (quot (count lines) 2)]
    [(join "\n" (take mid lines))
     (join "\n" (drop mid lines))]))

(defn process-leaf [chunk]
  (let [profiles (map parse-profile (split-lines chunk))]
    (find-matching-pairs profiles)))

(defn aggregate [results]
  (flatten results))

;; Engine handles recursion — no LLM calls for intermediate nodes
(return (tree-reduce data/corpus should-split? decompose process-leaf aggregate))
```

### Engine behavior

1. Calls `should-split?` in a sandbox → boolean
2. If true: calls `decompose` in a sandbox → list of chunks
3. Spawns parallel processes for each chunk (like `pmap`)
4. Each process runs `tree-reduce` recursively
5. Calls `aggregate` on collected results
6. Each function call gets its own sandbox (timeout, memory limits)

### For semantic tasks

Leaf nodes can use `tool/llm-query` — the only place LLM calls are needed:

```clojure
(defn process-leaf [chunk]
  (let [profiles (map parse-profile (split-lines chunk))
        pairs (candidate-pairs profiles)
        judged (tool/llm-query {:prompt "Which pairs are semantically compatible?"
                                :pairs pairs
                                :signature "[{id :string, compatible :bool}]"})]
    (filter :compatible judged)))
```

### Compile + tree-reduce

The ultimate combination: compile the strategy design, then `tree-reduce` executes mechanically:

```elixir
strategy_agent = SubAgent.new(
  prompt: """
  Analyze the sample corpus. Define should-split?, decompose,
  process-leaf, and aggregate functions for finding profile pairs.
  Call tree-reduce with all four functions.
  """,
  signature: "(corpus :string) -> {count :int, pairs [:string]}",
  max_turns: 1
)

{:ok, compiled} = SubAgent.compile(strategy_agent, llm: llm, sample: %{corpus: sample})
# One LLM call at compile time. Zero at runtime. Engine recurses mechanically.
```

### Implementation scope

- New built-in `tree-reduce` in the Lisp evaluator
- Manages sandbox processes like `pmap` does, but with recursive spawning
- Needs depth limits (reuse `max_depth` or add parameter)
- Existing `pmap` infrastructure is a good foundation

## Approach 5: PTC-Lisp Self-Recursive Function

The LLM writes a recursive function in PTC-Lisp that calls itself (no SubAgent boundary):

```clojure
(defn tree-reduce [data]
  (if (should-split? data)
    (aggregate (pmap tree-reduce (decompose data)))
    (process-leaf data)))

(return (tree-reduce data/corpus))
```

This works in principle — `pmap` spawns parallel processes, each runs `tree-reduce` recursively. But the sandbox has a 1s timeout and 10MB memory limit. A deep `pmap` tree with large data chunks will hit those limits because the entire recursion runs in one sandbox context. The current RLM approach works because each recursion level is a separate SubAgent with its own sandbox.

## Summary Comparison

| Approach | LLM calls (runtime) | Recursion | Works today? | Implementation |
|---|---|---|---|---|
| Current RLM (`:self`) | Every level | Yes | Yes | — |
| `child_prompt` field | Every level (less waste) | Yes | Needs small change | Add field + resolve_self_tools |
| Parent/child with `:fn` | Every level | Optional | Yes | — |
| Compiled orchestrator + leaf | Leaf only | One level | Yes | — |
| Fully compiled pipeline | Zero | One level | Yes | — |
| PTC-Lisp self-recursion | Zero | Yes, but sandbox limits | Partially | — |
| `tree-reduce` built-in | Zero (or leaf `llm-query`) | Yes, engine-driven | Needs new built-in | New eval form, sandbox mgmt |
| Compiled + `tree-reduce` | Zero (or leaf `llm-query`) | Yes, engine-driven | Needs `tree-reduce` | Combines compile + tree-reduce |

## Recommendations

### Short-term (no new infrastructure)

1. **Compiled orchestrator + leaf SubAgentTool** — works today, eliminates orchestration LLM calls
2. **`child_prompt`** — small addition to SubAgent, makes `:self` prompts much cleaner

### Medium-term

3. **`tree-reduce` built-in** — the highest-leverage addition, unlocks zero-cost recursive decomposition with compile

### Key insight

The compile pattern transforms the problem from "LLM generates strategy at every level" to "LLM designs strategy once, engine executes it". Combined with `tree-reduce`, this gives the reliability of deterministic execution with the flexibility of LLM-designed algorithms.

## Open Questions

1. **`tree-reduce` depth limits** — reuse `max_depth` from agent config, or make it a parameter?
2. **Error handling** — what if `process-leaf` fails on one chunk? Fail entire tree or return partial?
3. **Budget integration** — should `tree-reduce` respect `turn_budget` and `token_limit`?
4. **Observability** — how to trace a `tree-reduce` execution tree? Reuse existing trace infrastructure?
5. **`:fn` in output signatures** — currently closures can't be returned from SubAgent. Enabling this would unlock "compile strategy functions, return them, drive recursion externally."
