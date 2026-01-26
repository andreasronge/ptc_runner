# RLM Example: Large Corpus Analysis

This example demonstrates the **Recursive Language Model (RLM)** pattern as described in [arXiv:2512.24601](https://arxiv.org/abs/2512.24601).

An LLM acts as an **orchestrator** that dispatches work to parallel sub-agents and aggregates results.

## Key Features

1. **Token-based chunking with overlap** - `Chunker.by_tokens` handles variable line lengths; overlap prevents boundary incidents (stack traces) from being split
2. **Simple worker agents** - Workers just analyze their chunk; no recursive subdivision needed
3. **Operator-level budget control** - `token_limit` and `on_budget_exceeded` options for cost control

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
Corpus: 10000 lines -> 8 chunks of ~4000 tokens (200 overlap)

=== Starting RLM Orchestration (Sonnet -> Haiku) ===

=== RLM Audit Complete ===
%{total: 42, incidents: ["CRITICAL: Database connection timeout...", ...]}

Execution Metrics:
  LLM Requests: 9
  Duration: 3421ms
  Tokens: 18500
```

## See Also

- [RLM Patterns Guide](../../docs/guides/subagent-rlm-patterns.md) - Full documentation
- [`PtcRunner.Chunker`](../../lib/ptc_runner/chunker.ex) - Chunking utilities
