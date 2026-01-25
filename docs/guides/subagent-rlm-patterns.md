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
- **Deterministic chunking**: Lisp functions slice data predictably
- **Recursive agents**: Agents can call themselves for divide-and-conquer

## Basic Pattern: Chunk-Map-Aggregate

```elixir
# 1. Define a worker agent for processing chunks
worker = SubAgent.new(
  prompt: """
  Analyze the log chunk in data/chunk for CRITICAL or ERROR incidents.
  Return a list of incident descriptions found.
  """,
  signature: "(chunk :string) -> {incidents [:string]}",
  max_turns: 3,
  llm: :haiku  # Use fast model for parallel workers
)

# 2. Define the orchestrator
orchestrator = SubAgent.new(
  prompt: """
  Analyze the system logs in data/corpus for incidents.

  Strategy:
  1. Split the corpus into ~2000-line chunks using partition
  2. Use pmap with the 'analyze' tool to process all chunks in parallel
  3. Flatten and deduplicate the results
  4. Return the total count and first 10 unique incidents
  """,
  signature: "(corpus :string) -> {total :int, incidents [:string]}",
  tools: %{
    "analyze" => SubAgent.as_tool(worker)
  },
  max_turns: 5,
  llm: :sonnet  # Use smart model for orchestration
)

# 3. Run with large corpus
corpus = File.read!("logs/production.log")  # 100k+ lines

{:ok, step} = SubAgent.run(orchestrator,
  context: %{"corpus" => corpus},
  llm_registry: registry
)
```

The orchestrator generates PTC-Lisp like:

```clojure
(let [lines (split-lines data/corpus)
      chunks (partition 2000 lines)
      results (pmap #(tool/analyze {:chunk (join "\n" %)}) chunks)
      all-incidents (flatten (map :incidents results))
      unique (distinct all-incidents)]
  (return {:total (count unique)
           :incidents (take 10 unique)}))
```

## Recursive Pattern: Self-Subdividing Agents

For hierarchical decomposition, agents can call themselves:

```elixir
analyzer = SubAgent.new(
  prompt: """
  Analyze the data chunk in data/chunk.

  If the chunk is small (< 1000 lines), analyze directly.
  If large, subdivide into smaller chunks and use the 'self' tool recursively.
  Aggregate child results before returning.
  """,
  signature: "(chunk :string) -> {findings [:string]}",
  recursive: true,  # Enables self-recursion via 'self' tool
  max_depth: 3,     # Limits recursion depth
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
          results (pmap #(tool/self {:chunk (join "\n" %)}) halves)]
      (return {:findings (flatten (map :findings results))}))))
```

## Budget-Aware Orchestration

Agents can query remaining budget to make smart decisions:

```clojure
(let [remaining (budget/remaining)
      chunk-count (count chunks)]
  (if (> chunk-count (:turns remaining))
    ;; Not enough budget for all chunks, batch them
    (let [batch-size (max 1 (/ chunk-count (:turns remaining)))
          batches (partition batch-size chunks)]
      (pmap #(tool/analyze-batch {:chunks %}) batches))
    ;; Enough budget, process individually
    (pmap #(tool/analyze {:chunk %}) chunks)))
```

## Chunking Strategies

### By Line Count

```clojure
(let [lines (split-lines data/corpus)
      chunks (partition 2000 lines)]  ; 2000 lines per chunk
  ...)
```

### By Character Count

```clojure
(let [chunks (chunk/by-chars data/corpus 50000)]  ; 50k chars per chunk
  ...)
```

### By Semantic Boundaries

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

## Comparison with Alternatives

| Feature | Standard RAG | Long Context | RLM (ptc_runner) |
|---------|--------------|--------------|------------------|
| Data scope | Retrieved snippets | Everything in prompt | Everything via code |
| Logic | Fixed retrieval | Probabilistic | Orchestrated map-reduce |
| Parallelism | None | None | Native (`pmap`) |
| Cost | Low | Very high | Medium (structured) |
| Cross-chunk patterns | Poor | Good (but diluted) | Good (aggregation) |

## Best Practices

1. **Size chunks appropriately**: 1000-3000 lines is typical. Too small = overhead, too large = attention issues.

2. **Use fast models for workers**: Haiku processes chunks; Sonnet orchestrates.

3. **Aggregate incrementally**: Don't collect all results then process. Reduce as you go when possible.

4. **Set depth limits**: Recursive agents should have `max_depth: 3` or less to prevent runaway recursion.

5. **Monitor with telemetry**: Track `llm_requests` and `duration_ms` to tune chunk sizes.

## Example: Log Analysis

See `examples/rlm/` for a complete working example that:
- Generates a 10k+ line test corpus with hidden incidents
- Uses Sonnet as planner, Haiku as workers
- Demonstrates parallel chunk processing
- Aggregates findings into a final report

```bash
# Generate test data
mix run examples/rlm/gen_data.exs

# Run the RLM workflow
mix run examples/rlm/run.exs
```

## See Also

- [Composition Patterns](subagent-patterns.md) - SubAgents as tools, orchestration
- [Core Concepts](subagent-concepts.md) - Context firewall, memory model
- [PTC-Lisp Specification](../ptc-lisp-specification.md) - `pmap`, `partition`, etc.
- [Observability](subagent-observability.md) - Tracking parallel execution
