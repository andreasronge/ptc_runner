# RLM Recursion Analysis: Sub-Agents vs Recursive PTC-Lisp

## How the Original RLM Works

The original Python RLM uses a **recursive tree of LLM+REPL pairs**. Each node in the tree:

1. Gets its own **Python REPL** (persistent namespace across iterations)
2. Gets its own **LLM connection** (via TCP socket)
3. Runs an **iterative loop**: LLM generates code → REPL executes → result appended to history → repeat until `FINAL_VAR()`

The code in each REPL can call:

- **`llm_query(prompt)`** — plain LLM call, no iteration (leaf-like)
- **`rlm_query(prompt)`** — spawns a full child RLM with its own REPL + iteration loop
- **`rlm_query_batched(prompts)`** — spawns multiple children sequentially

At `max_depth`, `rlm_query()` degrades to plain `llm_query()`.

### Depth System

```
max_depth=3

RLM (depth=0)
 └─ rlm_query() → Child RLM (depth=1)
     └─ rlm_query() → Child RLM (depth=2)
         └─ rlm_query() → Plain LM call (depth=3 >= max_depth, no REPL)
```

### Data Flow

- **Downward**: prompt string becomes child's context; budget/timeout reduced by elapsed amounts
- **Upward**: child's final answer returned as string; cost accumulated in parent
- **No shared variables**: each RLM has an isolated namespace; communication only through function arguments and return values

## Where Are LLMs Needed?

**LLMs are called at every node, not just leaves.** Each node needs the LLM to:

1. **Decide** whether to decompose further or solve directly
2. **Write code** for the decomposition strategy (how to split, what to pass to children)
3. **Aggregate** child results (reduce step)

This is fundamentally different from a static map-reduce — the LLM dynamically chooses the decomposition strategy at each level.

## Current PTC-Runner Approach

The PTC-Runner mirrors this with the `:self` tool pattern:

```elixir
SubAgent.new(
  prompt: "Find matching items in data/corpus...",
  signature: "(corpus :string) -> {count :int}",
  tools: %{"search" => :self},   # Sentinel for recursion
  max_depth: 4,
)
```

When PTC-Lisp calls `(tool/search {:corpus substring})`, it spawns a **new child sub-agent** — a full LLM call with the same agent config but different data context. Each child can spawn further children up to `max_depth`.

Key features:
- Closures (functions) from the parent's memory are inherited via `inherited_ns`
- Each child gets a fresh LLM call with a partial dataset
- Budget and depth limits propagate downward

## The Core Question: Why Not Just Generate a Recursive PTC-Lisp Program?

PTC-Lisp already has `pmap`, `filter`, `group-by`, `reduce`, and recursion support. A single LLM call could generate a complete recursive program:

```clojure
(defn find-pairs [corpus]
  (if (< (count (lines corpus)) 100)
    ;; Base case: small enough to process directly
    (let [profiles (parse-profiles corpus)]
      (find-matching-pairs profiles))
    ;; Recursive case: split and recurse
    (let [chunks (partition-all 50 (lines corpus))
          results (pmap (fn [chunk] (find-pairs (join "\n" chunk))) chunks)]
      (flatten results))))

(find-pairs data/corpus)
```

This would use **1 LLM call** instead of N.

## Trade-off Analysis

| Approach | LLM Calls | Adaptability | Complexity | Cost |
|----------|-----------|-------------|------------|------|
| Recursive sub-agents (current) | N (one per node) | High — adapts at each level | High | High |
| Single recursive PTC-Lisp | 1 | Low — strategy fixed upfront | Low | Low |
| Hybrid (see below) | 1 + leaf calls | Medium | Medium | Medium |

### Arguments for LLM-at-Every-Node (Current Approach)

- Each node can **adapt its strategy** based on the actual data it sees
- The LLM can **iterate** (multi-turn) at each level — if the first approach fails, it tries another
- Parent doesn't need to anticipate what children will encounter
- Works when the decomposition strategy isn't known upfront
- Handles **heterogeneous data** that needs different strategies at different subtrees

### Arguments for a Single Recursive PTC-Lisp Program

- Avoids N×LLM calls (expensive, slow)
- PTC-Lisp already has the building blocks for map-reduce
- For **well-structured problems** (counting, pairs, NIAH), the decomposition is straightforward
- At intermediate nodes, the LLM is mostly just re-discovering the same "split and aggregate" pattern

### Sandbox Limitation

PTC-Lisp runs in a sandbox with 1s timeout and 10MB memory. A recursive program processing a large corpus would need to hold the whole thing in memory and do all computation in one shot. The sub-agent approach offloads each chunk to a separate sandbox invocation. This is a practical constraint, not a fundamental architectural one — sandbox limits could be raised or the sandbox could be made re-entrant.

## Assessment

For many RLM benchmarks (counting, pairs, NIAH), the decomposition strategy is **simple enough** that a single PTC-Lisp program with recursion could work. The LLM at intermediate nodes is mostly just re-discovering the same "split and aggregate" pattern. The LLM is really only needed at **leaves** (where actual data analysis happens) and at the **root** (to decide the overall strategy).

Cases where LLM-at-every-node genuinely helps:

- Data is **heterogeneous** and needs different strategies at different subtrees
- Decomposition itself requires **semantic understanding** (not just mechanical splitting)
- **Error recovery** is needed — a child can try a different approach if the first fails

## Proposed Hybrid Approach

Generate a recursive PTC-Lisp program at the root that uses `tool/llm-query` only at the leaves for actual analysis, while recursion and aggregation logic is pure PTC-Lisp:

```clojure
;; Root LLM generates this program (1 LLM call)
(defn analyze-chunk [chunk]
  ;; Leaf: use LLM for semantic analysis
  (tool/llm-query {:prompt (str "Find matching pairs in:\n" chunk)}))

(defn process [corpus]
  (if (< (count (lines corpus)) 50)
    (analyze-chunk corpus)
    (let [chunks (partition-all 25 (lines corpus))
          results (pmap (fn [c] (process (join "\n" c))) chunks)]
      (merge-results results))))

(process data/corpus)
```

This would dramatically reduce LLM calls while preserving semantic analysis at the leaves.
