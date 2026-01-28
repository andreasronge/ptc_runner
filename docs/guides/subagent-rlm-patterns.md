# Recursive Language Model (RLM) Patterns

This guide covers implementing RLM patterns in ptc_runner for processing large datasets that exceed practical context limits.

## What is RLM?

Recursive Language Models ([arXiv:2512.24601](https://arxiv.org/abs/2512.24601)) is an approach where the LLM acts as an **orchestrator** rather than a processor. Instead of feeding massive data into a single prompt, the model writes code that:

1. **Chunks** large data into manageable pieces
2. **Fans out** work to parallel sub-agents
3. **Aggregates** results into a final answer

The key insight: put bulk context in a persistent environment (memory/data), let the model manipulate it via code, and use sub-LLM calls strategically.

## The Problem: Context Limitations

Traditional approaches fail with large datasets:

| Approach | Problem |
|----------|---------|
| Stuff everything in prompt | Attention dilution, cost explosion |
| Sequential chunk processing | Slow, loses cross-chunk patterns |
| RAG retrieval | Only sees "relevant" snippets, misses structure |

## The Solution: RLM with PTC-Lisp

ptc_runner is well-suited for RLM because:

- **Context firewall**: Large data stays in `data/*`, never bloats the prompt
- **Native parallelism**: `pmap` spawns concurrent BEAM processes
- **Pre-chunking**: `PtcRunner.Chunker` handles chunking in Elixir (recommended)
- **Budget introspection**: `(budget/remaining)` enables adaptive strategies
- **Recursive agents**: Agents can call themselves for divide-and-conquer

## Basic Pattern: Chunk-Map-Aggregate

The simplest RLM pattern pre-chunks data in Elixir using `PtcRunner.Chunker`:

```elixir
alias PtcRunner.{SubAgent, Chunker}

# 1. Pre-chunk in Elixir with overlap (recommended)
corpus = File.read!("logs/production.log")
chunks = Chunker.by_tokens(corpus, 4000, overlap: 200)

# 2. Define a simple worker agent
worker = SubAgent.new(
  prompt: """
  Analyze the log chunk in data/chunk for CRITICAL or ERROR incidents.
  Return a list of incident descriptions found.
  """,
  signature: "(chunk :string) -> {incidents [:string]}",
  max_turns: 3,
  llm: :haiku
)

# 3. Define the orchestrator (no chunking logic needed)
orchestrator = SubAgent.new(
  prompt: """
  Process the pre-chunked logs in data/chunks.
  Use pmap with 'analyze' tool to process all chunks in parallel.
  Aggregate and return total count and first 10 unique incidents.
  """,
  signature: "(chunks [:string]) -> {total :int, incidents [:string]}",
  tools: %{"analyze" => SubAgent.as_tool(worker)},
  max_turns: 5,
  llm: :sonnet
)

# 4. Run with pre-chunked data and budget control
{:ok, step} = SubAgent.run(orchestrator,
  context: %{"chunks" => chunks},
  token_limit: 100_000,
  on_budget_exceeded: :return_partial
)
```

The orchestrator generates simple PTC-Lisp (no chunking logic):

```clojure
(let [results (pmap #(tool/analyze {:chunk %}) data/chunks)
      all-incidents (flatten (map :incidents results))
      unique (distinct all-incidents)]
  (return {:total (count unique)
           :incidents (take 10 unique)}))
```

## Recursive Pattern: Self-Subdividing Agents

For hierarchical decomposition, use the `:self` sentinel in the tools map:

```elixir
analyzer = SubAgent.new(
  prompt: """
  Analyze the data chunk in data/chunk.

  If the chunk is small (< 1000 lines), analyze directly.
  If large, subdivide into smaller chunks and use the 'worker' tool recursively.
  Aggregate child results before returning.
  """,
  signature: "(chunk :string) -> {findings [:string]}",
  tools: %{"worker" => :self},  # Self-recursion via :self sentinel
  max_depth: 3,
  max_turns: 5,
  llm: :haiku
)

{:ok, step} = SubAgent.run(analyzer,
  context: %{"chunk" => large_data},
  llm_registry: registry
)
```

The agent decides dynamically whether to process or subdivide:

```clojure
(let [lines (split-lines data/chunk)
      n (count lines)]
  (if (< n 1000)
    ;; Base case: analyze directly
    (return {:findings (analyze-for-patterns lines)})
    ;; Recursive case: subdivide
    (let [halves (partition (/ n 2) lines)
          results (pmap #(tool/worker {:chunk (join "\n" %)}) halves)]
      (return {:findings (flatten (map :findings results))}))))
```

## Budget-Aware Orchestration

Agents can query remaining budget via `(budget/remaining)`:

```clojure
(budget/remaining)
;; => {:turns 15
;;     "work-turns" 10
;;     "retry-turns" 5
;;     :depth {:current 1 :max 3}
;;     :tokens {:input 5000 :output 2000 :total 7000}
;;     "llm-requests" 3}
```

Use this to make smart decisions about parallelization:

```clojure
(let [b (budget/remaining)
      chunk-count (count chunks)]
  (if (> chunk-count (:turns b))
    ;; Not enough budget for all chunks, batch them
    (let [batch-size (max 1 (/ chunk-count (:turns b)))
          batches (partition batch-size chunks)]
      (pmap #(tool/analyze-batch {:chunks %}) batches))
    ;; Enough budget, process individually
    (pmap #(tool/analyze {:chunk %}) chunks)))
```

For recursive agents, check depth before subdividing:

```clojure
(let [b (budget/remaining)
      at-max-depth? (>= (get-in b [:depth :current])
                        (dec (get-in b [:depth :max])))]
  (if at-max-depth?
    (analyze-directly data/chunk)
    (subdivide-and-recurse data/chunk)))
```

## Chunking Strategies

### Pre-Chunking in Elixir (Recommended)

Use `PtcRunner.Chunker` to chunk data before passing to the agent. Token-based chunking with overlap is safest for production:

```elixir
alias PtcRunner.Chunker

# Token-based with overlap (recommended for production)
# - Handles variable line lengths (JSON blobs, stack traces)
# - Overlap ensures boundary incidents aren't split
chunks = Chunker.by_tokens(corpus, 4000, overlap: 200)

# Line-based (simpler, fine if line lengths are predictable)
chunks = Chunker.by_lines(corpus, 2000)

# Line-based with overlap
chunks = Chunker.by_lines(corpus, 2000, overlap: 100)

SubAgent.run(orchestrator,
  context: %{"chunks" => chunks}
)
```

The agent then processes pre-chunked data directly:

```clojure
(pmap #(tool/analyze {:chunk %}) data/chunks)
```

This approach is simpler and more reliable than having the LLM generate chunking code.

### LLM-Generated Chunking (Alternative)

For dynamic chunking where the LLM decides how to split:

#### By Line Count

```clojure
(let [lines (split-lines data/corpus)
      chunks (partition 2000 lines)]  ; 2000 lines per chunk
  ...)
```

#### By Delimiter

```clojure
(let [sections (split data/corpus "---\n")  ; Split on delimiter
      chunks (partition 5 sections)]         ; Group 5 sections per chunk
  ...)
```

## Model Selection Strategy

| Role | Model | Rationale |
|------|-------|-----------|
| Orchestrator | Sonnet/Opus | Needs reasoning for strategy |
| Chunk workers | Haiku | Fast, cheap, parallelizable |
| Aggregator | Sonnet | Synthesis requires intelligence |

```elixir
# Workers use haiku (bound at tool creation)
worker_tool = SubAgent.as_tool(worker, llm: :haiku)

# Orchestrator uses sonnet (at runtime)
SubAgent.run(orchestrator, llm: :sonnet, tools: %{"worker" => worker_tool})
```

## Budget Enforcement

For operator-level cost control, use `token_limit` or a custom `budget` callback:

```elixir
# Simple token limit
SubAgent.run(orchestrator,
  llm: llm,
  token_limit: 100_000,
  on_budget_exceeded: :return_partial  # or :fail (default)
)

# Custom callback for fine-grained control
SubAgent.run(orchestrator,
  llm: llm,
  budget: fn usage ->
    cond do
      usage.total_tokens > 100_000 -> :stop
      usage.llm_requests > 50 -> :stop
      true -> :continue
    end
  end
)
```

The callback receives `%{total_tokens, input_tokens, output_tokens, llm_requests}`.

## Comparison with Alternatives

| Feature | Standard RAG | Long Context | RLM (ptc_runner) |
|---------|--------------|--------------|------------------|
| Data scope | Retrieved snippets | Everything in prompt | Everything via code |
| Logic | Fixed retrieval | Probabilistic | Orchestrated map-reduce |
| Parallelism | None | None | Native (`pmap`) |
| Cost | Low | Very high | Medium (structured) |
| Cross-chunk patterns | Poor | Good (but diluted) | Good (aggregation) |

## Best Practices

1. **Pre-chunk in Elixir**: Use `PtcRunner.Chunker` instead of LLM-generated chunking for reliability.

2. **Size chunks appropriately**: 1000-3000 lines is typical. Too small = overhead, too large = attention issues.

3. **Use fast models for workers**: Haiku processes chunks; Sonnet orchestrates.

4. **Set budget limits**: Use `token_limit` to control costs in production.

5. **Set depth limits**: Recursive agents should have `max_depth: 3` or less to prevent runaway recursion.

6. **Monitor with telemetry**: Track `llm_requests` and `duration_ms` to tune chunk sizes.

## Production Considerations

### Boundary Handling with Overlap

Multi-line incidents (stack traces, JSON blobs) can be split across chunk boundaries. Use overlap to ensure nothing is missed:

```elixir
# 200 tokens of overlap ensures incidents at boundaries are seen by both chunks
chunks = Chunker.by_tokens(corpus, 4000, overlap: 200)
```

The worker may report the same incident twice, but the final `distinct` handles deduplication.

### Token-based vs Line-based Chunking

Line-based chunking (`by_lines`) is intuitive but risky - a single JSON log line could be 10KB. Token-based chunking (`by_tokens`) ensures workers never hit context limits:

```elixir
# Safer for logs with variable line lengths
chunks = Chunker.by_tokens(corpus, 4000)

# vs. line-based (fine if line lengths are predictable)
chunks = Chunker.by_lines(corpus, 2000)
```

### Worker Failure Handling

Currently, if one worker in `pmap` fails, the entire operation fails. For fault-tolerant RLM:

**Option 1: Prompt engineering** - Instruct the planner to handle partial results:
```
"If some worker calls fail, proceed with available results and note which chunks failed."
```

**Option 2: Defensive Lisp** - Wrap worker calls in error handling (future library feature).

For most use cases, fail-fast is acceptable. For mission-critical RLM over unreliable data, consider pre-validating chunks in Elixir.

### Aggregation Patterns

For simple aggregation (flatten, distinct, take), inline Lisp is fine:

```clojure
(let [all (flatten (map :incidents results))]
  (return {:total (count (distinct all))
           :incidents (take 10 (distinct all))}))
```

For complex aggregation (merging time-series, conflict resolution, weighted scoring), consider:
- A dedicated Aggregator agent with its own prompt
- Pre-processing in Elixir before returning to the user

## Example: Log Analysis

See `examples/parallel_workers/` for a complete working example that:
- Generates a 10k+ line test corpus with hidden incidents
- Uses Sonnet as planner, Haiku as workers
- Demonstrates parallel chunk processing
- Aggregates findings into a final report

```bash
# Generate test data
mix run examples/parallel_workers/gen_data.exs

# Run the parallel workers workflow
mix run examples/parallel_workers/run.exs
```

## See Also

- [Composition Patterns](subagent-patterns.md) - SubAgents as tools, orchestration
- [Core Concepts](subagent-concepts.md) - Context firewall, memory model
- [PTC-Lisp Specification](../ptc-lisp-specification.md) - `pmap`, `partition`, etc.
- [Observability](subagent-observability.md) - Tracking parallel execution
