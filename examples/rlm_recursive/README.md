# RLM Recursive - Recursive Language Model Benchmarks

This example implements benchmarks from the [RLM paper (arXiv:2512.24601)](https://arxiv.org/abs/2512.24601), demonstrating how LLMs can process arbitrarily long inputs by treating them as an external environment and programmatically examining, decomposing, and recursively processing them.

## Paper Findings: When is Recursion Needed?

The RLM paper found that **task complexity determines whether recursion is essential**:

| Benchmark | Complexity | Recursion Needed? | Paper Finding |
|-----------|------------|-------------------|---------------|
| **S-NIAH** | O(1) | No | Direct probing (grep) works |
| **OOLONG** | O(n) | No | REPL alone sufficient |
| **OOLONG-Pairs** | O(n²) | **Yes** | Recursion essential (0% → 60% F1) |
| **BrowseComp** | Multi-hop | **Yes** | Multi-doc reasoning needs recursion |

> "The REPL environment alone was enough to handle long inputs, but **recursive self-calls were essential for tasks with high information density**."

Our benchmarks reproduce this behavior:
- **S-NIAH**: Solves in 1-2 turns via `grep` probing (no recursion needed)
- **Counting**: Solves in 1 turn via direct filtering (no recursion needed - this is correct!)

This matches the paper's findings for O(1) and O(n) tasks.

## The Core RLM Insight

**Bulk data stays in memory, not LLM context.** The LLM writes processing code; the computer executes it on arbitrarily large datasets:

```clojure
;; LLM writes this code once, computer filters 50K profiles instantly
(def matching
  (filter
    (fn [line]
      (and (> (parse-age line) 30) (includes? line "hiking")))
    (split-lines data/corpus)))
(return {:count (count matching)})
```

This is fundamentally different from stuffing everything into the prompt.

## Benchmarks

### S-NIAH (Single Needle in a Haystack)

**Task**: Find one hidden fact in a large corpus.

**Example**: Find "The access code for agent_7291 is XKQMTR" in 10,000 lines.

**Behavior**: Uses `grep-n` to locate the needle instantly - O(1) LLM turns regardless of corpus size.

```clojure
(def matches (grep-n "agent_7291" data/corpus))
(return {:answer (extract-code (first matches)) :found true})
```

### OOLONG-Counting

**Task**: Count entities matching criteria.

**Example**: "How many people are over 30 AND have hiking as a hobby?" across 5,000 profiles.

**Behavior**: Direct in-memory filtering - the computer processes all profiles in milliseconds.

```clojure
(def matching (filter #(and (> (age %) 30) (has-hobby? % "hiking")) profiles))
(return {:count (count matching)})
```

**Note**: This solves in 1 turn without recursion - **this is the expected behavior** per the paper. Recursion would be needed for O(n²) tasks like pairwise comparison.

### OOLONG-Pairs (O(n²) - Recursion Essential!)

**Task**: Find all pairs of people in the same city who share at least one hobby.

**Example**: With 100 profiles across 5 cities, find ~150+ valid pairs.

**Why Recursion is Essential**: This is an O(n²) task - comparing all pairs explodes quickly:
- 100 profiles = 4,950 comparisons
- 500 profiles = 124,750 comparisons
- Direct enumeration exhausts context before completing

**Strategy**: Divide by city (reduces n² to sum of smaller n²), then find pairs within each city group:

```clojure
;; Group profiles by city
(def by-city (group-by :city profiles))

;; For each city, find pairs or recurse if group too large
(defn find-pairs-in-group [group]
  (if (> (count group) 30)
    ;; Too large - recurse with just this city's profiles
    (tool/query {:corpus (profiles->corpus group)})
    ;; Small enough - enumerate pairs directly
    (for [p1 group, p2 group
          :when (and (< (:id p1) (:id p2)) (shares-hobby? p1 p2))]
      (pair-id p1 p2))))

(return {:count (count all-pairs) :pairs (take 20 all-pairs)})
```

**Key Insight**: The paper found OOLONG-Pairs went from **0% to 60% F1** with recursion - this is the benchmark where RLM truly shines.

### Semantic Pairs (Recursion + LLM Judgment)

**Task**: Find all pairs of people in the same city with *semantically compatible* interests.

**Note**: This is our own benchmark, not from the OOLONG dataset. The [OOLONG benchmarks](https://huggingface.co/oolongbench) (oolong-synth, oolong-real) focus on counting and frequency tasks. Our semantic pairs benchmark extends the RLM approach by requiring LLM judgment per pair — something that can't be solved programmatically.

**Why Two Tools**: This benchmark separates concerns:
- `tool/evaluate_pairs` (`:self`) — Recursive data decomposition for large datasets
- `tool/llm-query` (builtin, via `llm_query: true`) — Ad-hoc LLM calls for batch semantic judgment

The agent uses `tool/llm-query` with a judgment prompt and structured signature to classify pairs as compatible or not, batching them as needed via `pmap`.

**Results** (40 profiles, seed 42, 260 expected pairs):

- **Accuracy**: 62% (162/260) in 10 turns, 118s
- **Main bottleneck**: Judge calibration — the ground truth uses specific category relationships (outdoor↔fitness, creative↔social, tech↔creative, fitness↔social) that the judge must infer

```bash
mix run run.exs --benchmark semantic_pairs --profiles 40 --trace --progress
```

## When Would Recursion Be Used?

Recursion becomes essential when:

1. **Quadratic complexity** (OOLONG-Pairs): Comparing all pairs of entries
2. **Multi-hop reasoning**: Synthesizing information across multiple documents
3. **Context exceeds window**: Input is 2+ orders of magnitude beyond context limit
4. **LLM judgment per chunk**: Each subdivision requires reasoning, not just filtering

The `:self` tool is available for these cases:

```clojure
;; Recursive subdivision (when needed)
(let [mid (quot n 2)
      r1 (tool/query {:corpus (take mid lines) ...})
      r2 (tool/query {:corpus (drop mid lines) ...})]
  (return {:count (+ (:count r1) (:count r2))}))
```

## Usage

```bash
# Install dependencies
mix deps.get

# Run S-NIAH benchmark (default)
mix run run.exs

# Run with tracing
mix run run.exs --trace

# Run counting benchmark with 5000 profiles
mix run run.exs --benchmark counting --profiles 5000

# Run pairs benchmark (demonstrates essential recursion)
mix run run.exs --benchmark pairs --profiles 100 --trace

# View help
mix run run.exs --help
```

## CLI Options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `--benchmark` | `-b` | "sniah", "counting", "pairs", or "semantic_pairs" | sniah |
| `--lines` | `-l` | Corpus lines for S-NIAH | 1000 |
| `--profiles` | `-p` | Profiles for counting/pairs | 500 |
| `--seed` | `-s` | Random seed | 42 |
| `--trace` | `-t` | Enable tracing | false |
| `--min-age` | | Min age for counting | 30 |
| `--hobby` | | Hobby for counting | hiking |

## Architecture

```
lib/
├── rlm_recursive.ex      # Main API: run/1, run_benchmark/2
├── agent.ex              # Agent builder with :self tool
├── scorer.ex             # Ground truth validation
└── generators/
    ├── sniah.ex          # S-NIAH corpus generator
    ├── counting.ex       # OOLONG-Counting generator
    ├── pairs.ex          # OOLONG-Pairs generator (O(n²))
    └── semantic_pairs.ex # Semantic compatibility pairs (custom benchmark)
```

### Key Patterns

**Grep-based probing** for search tasks:
```clojure
(grep-n "search_term" data/corpus)
;; => [{:line 472 :text "The access code for agent_7291 is XKQMTR"}]
```

**Budget introspection** (PtcRunner-specific, not from the RLM paper — not yet used in benchmarks):
```clojure
(def b (budget/remaining))
;; => {:turns 15, :depth {:current 1, :max 4}, ...}
```

**Recursive self-calls** (when complexity requires it):
```clojure
(tool/query {:corpus subset :min_age data/min_age :hobby data/hobby})
```

## Comparison with `examples/parallel_workers/`

| Feature | `parallel_workers/` (Simple) | `rlm_recursive/` (Advanced) |
|---------|-----------------|----------------------------|
| Chunking | Pre-chunked in Elixir | LLM decides |
| Tools | External worker agents | `:self` for recursion |
| Validation | Manual inspection | Automated scoring |
| Paper alignment | Orchestration pattern | Full RLM benchmarks |

## Tracing

Enable tracing to see execution:

```bash
mix run run.exs --trace
```

Traces are saved to the `traces/` folder (gitignored).

### Managing Traces

Use the `mix rlm_traces` task to export, view, or clean traces:

```bash
# Export all traces to Chrome DevTools format
mix rlm_traces --export

# Export and open in Chrome
mix rlm_traces --export --open

# Export a specific trace file
mix rlm_traces --export --file traces/recursive_trace.jsonl

# Print trace tree(s) to terminal
mix rlm_traces --tree

# Clean up all trace files
mix rlm_traces --clean
```

### Chrome DevTools Export

After running `mix rlm_traces --export`, load the `.json` files in Chrome:
1. Open DevTools (F12) → Performance tab
2. Click 'Load profile...' and select a `.json` file
3. Or navigate to `chrome://tracing` and load the file

See [Observability Guide](../../docs/guides/subagent-observability.md#chrome-devtools-export) for details.

## LLM Provider Setup

See [llm_client/README.md](../../llm_client/README.md) for provider configuration (OpenRouter, AWS Bedrock, etc.).

## Future Work

To further explore recursive behavior, add:
- **Multi-hop QA**: Questions requiring synthesis across documents
- **BrowseComp**: Multi-document reasoning benchmark from the paper

## References

- [arXiv:2512.24601](https://arxiv.org/abs/2512.24601) - Recursive Language Models (Zhang, Kraska, Khattab)
- [examples/parallel_workers/](../parallel_workers/) - Simpler parallel orchestration with pre-chunking
- [RLM Patterns Guide](../../docs/guides/subagent-rlm-patterns.md)
