# RLM Recursive - Advanced Recursive Language Model Benchmarks

This example demonstrates **true recursive patterns** from the [RLM paper](https://arxiv.org/abs/2512.24601), where the LLM decides how to decompose problems rather than receiving pre-chunked data.

## Key Features

| Feature | Description |
|---------|-------------|
| **Recursive Self-Calls** | Agent calls itself via `:self` tool for divide-and-conquer |
| **LLM-Decided Chunking** | Model decides when/how to subdivide (not pre-chunked) |
| **Budget Awareness** | Uses `(budget/remaining)` to adapt recursion strategy |
| **Grep Probing** | Uses stdlib `grep`/`grep-n` for efficient corpus search |
| **Ground Truth Validation** | Automated scoring against known correct answers |

## Comparison with Simple RLM (`examples/rlm/`)

| Feature | `rlm/` (Simple) | `rlm_recursive/` (Advanced) |
|---------|-----------------|----------------------------|
| Chunking | Pre-chunked in Elixir | LLM decides split points |
| Recursion | Single level (pmap) | True recursion via `:self` |
| Budget | Just `token_limit` | Agent queries `(budget/remaining)` |
| Validation | Manual inspection | Automated ground truth scoring |
| Complexity | O(n) always | Can be O(log n) for search tasks |

## Benchmarks

### S-NIAH (Single Needle in a Haystack)

**Task**: Find one hidden fact in a large corpus.

**Example**: A corpus of 10,000 log lines contains one line like:
```
The access code for agent_7291 is XKQMTR
```

**Question**: "What is the access code for agent_7291?"

**Expected Strategy**:
1. Probe with `(grep "agent_7291" data/corpus)` - O(1) if using grep
2. Extract the code from matching line(s)
3. If grep returns too many matches, subdivide and recurse

**Complexity**: Near-constant for well-indexed searches (grep is O(n) but fast).

### OOLONG-Counting

**Task**: Count entities matching criteria across a corpus.

**Example**: 500 person profiles with attributes:
```
PROFILE 42: name=Alice Smith, age=35, city=Seattle, hobbies=[hiking, photography]
```

**Question**: "How many people are over 30 AND have hiking as a hobby?"

**Expected Strategy**:
1. Check corpus size
2. If small: count directly
3. If large: split, recurse, sum results (map-reduce)

**Complexity**: Linear (must examine all profiles).

## Usage

```bash
# Install dependencies (from examples/rlm_recursive/)
mix deps.get

# Run S-NIAH benchmark (default)
mix run run.exs

# Run with tracing
mix run run.exs --trace

# Run counting benchmark
mix run run.exs --benchmark counting

# Customize parameters
mix run run.exs --lines 5000 --seed 123
mix run run.exs --benchmark counting --profiles 200

# View help
mix run run.exs --help
```

## CLI Options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `--benchmark` | `-b` | "sniah" or "counting" | sniah |
| `--lines` | `-l` | Corpus lines for S-NIAH | 1000 |
| `--profiles` | `-p` | Profiles for counting | 500 |
| `--seed` | `-s` | Random seed | 42 |
| `--trace` | `-t` | Enable tracing | false |
| `--min-age` | | Min age for counting | 30 |
| `--hobby` | | Hobby for counting | hiking |

## Expected Output

```
╔══════════════════════════════════════════════════════════════╗
║           RLM Recursive Benchmark Runner                     ║
╚══════════════════════════════════════════════════════════════╝

Benchmark: sniah
Lines: 1000, Seed: 42

Generating S-NIAH corpus (1000 lines, seed 42)...
Needle hidden at line 472 of 1000
Query: What is the access code for agent_7291?

=== Starting S-NIAH Benchmark ===

=== Benchmark Complete ===
[PASS] Expected: "XKQMTR", Actual: "XKQMTR"

Return value:
%{"answer" => "XKQMTR", "found" => true}

════════════════════════════════════════════════════════════════
Summary
════════════════════════════════════════════════════════════════
Correct: true
Expected: "XKQMTR"
Actual: "XKQMTR"
```

## Architecture

```
lib/
├── rlm_recursive.ex      # Main API: run/1, run_benchmark/2
├── agent.ex              # Recursive agent builder with :self tool
├── scorer.ex             # Ground truth validation
└── generators/
    ├── sniah.ex          # S-NIAH corpus generator
    └── counting.ex       # OOLONG-Counting generator
```

### Recursive Agent Pattern

The key pattern is using `:self` in the tools map:

```elixir
SubAgent.new(
  prompt: "...",
  signature: "(corpus :string, query :string) -> {answer :string, found :bool}",
  tools: %{"search" => :self},  # Self-recursion!
  max_depth: 4,
  max_turns: 10
)
```

When the agent calls `(tool/search {:corpus sub_corpus :query query})`, it invokes itself with the new context.

### Budget-Aware Logic

Agents can query their remaining budget:

```clojure
(let [b (budget/remaining)
      at-limit? (>= (:current (:depth b)) (dec (:max (:depth b))))]
  (if at-limit?
    (process-directly data/corpus)
    (subdivide-and-recurse data/corpus)))
```

### Grep-Based Probing

Use stdlib grep functions for efficient search:

```clojure
;; Find lines containing pattern
(grep "agent_7291" data/corpus)
;; => ["The access code for agent_7291 is XKQMTR"]

;; Find with line numbers
(grep-n "agent_7291" data/corpus)
;; => [{:line 472 :text "The access code for agent_7291 is XKQMTR"}]
```

## Context Rot

The RLM paper introduces "context rot" - the phenomenon where single-shot prompts fail on large contexts even when the answer is present. Key insights:

1. **Attention dilutes**: As context grows, attention to any single fact decreases
2. **Recursion helps**: Breaking into focused sub-contexts maintains attention quality
3. **Grep bypasses rot**: Direct string search doesn't suffer from attention limits

This benchmark demonstrates how recursive decomposition with grep probing can achieve high accuracy on large corpora where single-shot approaches fail.

## Tracing

Enable tracing to see the recursive execution tree:

```bash
mix run run.exs --trace
```

Then open `trace_viewer.html` in your browser and load `traces/recursive_trace.jsonl`.

The trace shows:
- Parent/child relationships between recursive calls
- Token usage per call
- Return values at each level
- How the LLM decided to decompose the problem

## Environment

The benchmarks use AWS Bedrock by default. Set credentials:

```bash
export AWS_PROFILE=sandbox  # or set AWS_ACCESS_KEY_ID etc.
```

Or use OpenRouter:

```bash
export OPENROUTER_API_KEY=your_key
```

## See Also

- [examples/rlm/](../rlm/) - Simpler RLM with pre-chunking
- [RLM Patterns Guide](../../docs/guides/subagent-rlm-patterns.md)
- [arXiv:2512.24601](https://arxiv.org/abs/2512.24601) - Original RLM paper
