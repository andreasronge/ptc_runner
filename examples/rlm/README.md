# RLM Example: Large Corpus Analysis

This example demonstrates the **Recursive Language Model (RLM)** pattern as described in [arXiv:2512.24601](https://arxiv.org/abs/2512.24601).

An LLM acts as an **orchestrator** that dispatches work to parallel sub-agents and aggregates results.

## Key Features

1. **Token-based chunking with overlap** - `Chunker.by_tokens` handles variable line lengths; overlap prevents boundary incidents (stack traces) from being split
2. **Simple worker agents** - Workers just analyze their chunk; no recursive subdivision needed
3. **Operator-level budget control** - `token_limit` and `on_budget_exceeded` options for cost control
4. **Configurable parallel timeout** - `pmap_timeout` allows LLM-backed tools to run longer than the default 5s

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Elixir (run.exs)                                   │
│  ┌─────────────────────────────────────────────────┐│
│  │ Chunker.by_tokens(corpus, 4000, overlap: 200)   ││
│  │   → [chunk1, chunk2, chunk3, ...]               ││
│  └─────────────────────────────────────────────────┘│
│                         │                           │
│                         ▼                           │
│  ┌─────────────────────────────────────────────────┐│
│  │ Planner (Sonnet)                                ││
│  │   data/chunks available as pre-chunked list     ││
│  │   pmap #(tool/worker {:chunk %}) data/chunks    ││
│  └─────────────────────────────────────────────────┘│
│           │         │         │         │           │
│           ▼         ▼         ▼         ▼           │
│  ┌───────────────────────────────────────────────┐  │
│  │  Workers (Haiku) - parallel processing        │  │
│  │  [analyze] [analyze] [analyze] [analyze]      │  │
│  └───────────────────────────────────────────────┘  │
│                         │                           │
│                         ▼                           │
│  ┌─────────────────────────────────────────────────┐│
│  │ Aggregated Results                              ││
│  │   {:total N, :incidents [...]}                  ││
│  └─────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

## The Problem: Context Limitations

| Approach | Problem |
|----------|---------|
| Stuff everything in prompt | Attention dilution, cost explosion |
| Sequential chunk processing | Slow, loses cross-chunk patterns |
| RAG retrieval | Only sees "relevant" snippets |

## The Solution: RLM with PTC-Lisp

- **Context firewall**: Large data stays in `data/*`, never bloats the prompt
- **Native parallelism**: `pmap` spawns concurrent BEAM processes
- **Pre-chunking**: `PtcRunner.Chunker` handles chunking in Elixir
- **Budget control**: `token_limit` prevents runaway costs

## How to Run

```bash
# Generate test corpus (10k lines with hidden incidents)
mix run examples/rlm/gen_data.exs

# Run the RLM workflow
mix run examples/rlm/run.exs
```

## Expected Output

```
Corpus: 5001 lines -> 28 chunks of ~4000 tokens (200 overlap)

=== Starting RLM Orchestration (Sonnet -> Haiku) ===

=== RLM Audit Complete ===
%{"total_incidents" => 17, "first_10_unique" => ["CRITICAL: Database connection timeout...", ...]}

+- Turn 1 ----------------------------------------+
| Program: (pmap #(tool/worker {:chunk %}) ...)  |
| Output: Total chunks processed: 28             |
+------------------------------------------------+
...
+- Usage -----------------------------------------+
|   Input tokens:  9,141                         |
|   Duration:      55,291ms                      |
|   Turns:         4                             |
+-------------------------------------------------+
```

## Discussion: Performance and Limitations

### Observed Performance

| Metric | Value |
|--------|-------|
| Corpus | 5001 lines → 28 chunks |
| Wall clock | ~55 seconds |
| Planner tokens | ~9K input, ~500 output |
| Planner turns | 4 |
| Workers | 28 parallel Haiku calls |

### Parallelism Effectiveness

Sequential processing of 28 Haiku calls at ~10-15s each would take **280-420 seconds**. The observed **~55 seconds** suggests a **5-8x speedup** from parallelism. However, without worker-level tracing, we can't confirm this rigorously.

### Tracing Gap

The current tracing shows **planner turns** but not **worker internals**:

- Individual worker durations (which was slowest?)
- Worker token usage (cost breakdown)
- Worker success/failure rates
- Whether parallelism was effective (true overlap vs. bottlenecks)

This is because `pmap` spawns workers in separate BEAM processes, and their traces don't bubble up to the parent Step. See [Observability Guide](../../docs/guides/subagent-observability.md) for available tracing options.

### Relation to the RLM Paper

This example demonstrates the **mechanics** of RLM but not the full **adaptive intelligence** described in [arXiv:2512.24601](https://arxiv.org/abs/2512.24601):

| Paper Feature | This Example | Gap |
|---------------|--------------|-----|
| LLM-decided chunking | Pre-chunked in Elixir | Simpler, but less adaptive |
| Recursive subdivision | Single-level fan-out | No hierarchical decomposition |
| Budget-aware strategy | `token_limit` set | Planner doesn't use `(budget/remaining)` |
| Cross-chunk synthesis | Simple aggregation | No pattern detection across chunks |

### Possible Improvements

1. **Budget-aware batching**: Have the planner use `(budget/remaining)` to decide how many workers to spawn based on remaining token budget.

2. **Recursive workers**: Workers that can subdivide large chunks and call themselves, enabling hierarchical decomposition.

3. **Smarter aggregation**: Use Sonnet to synthesize patterns across worker results rather than simple concatenation.

4. **Worker-level tracing**: Collect child Step traces from `pmap` to enable full visibility into the parallel execution tree.

5. **Adaptive chunk sizing**: Let the LLM decide chunk boundaries based on content (e.g., log session boundaries) rather than fixed token counts.

## See Also

- [RLM Patterns Guide](../../docs/guides/subagent-rlm-patterns.md) - Full documentation
- [`PtcRunner.Chunker`](../../lib/ptc_runner/chunker.ex) - Chunking utilities
