# RLM Example: Recursive Large Corpus Analysis

This example demonstrates the **Recursive Language Model (RLM)** pattern as described in [arXiv:2512.24601](https://arxiv.org/abs/2512.24601). 

In this pattern, an LLM doesn't just "read" data; it acts as an **orchestrator** that writes code to partition massive datasets, dispatches work to parallel sub-agents, and aggregates the results.

## The Problem: The "Context Wall"

Traditional LLM agents struggle with large-scale data analysis for three reasons:
1. **Attention Dilution**: Even with 1M+ token windows, models lose precision when the "needle" is buried in too much "haystack."
2. **Cost & Latency**: Feeding a massive corpus into every turn of a conversation is prohibitively expensive and slow.
3. **Sequential Bottlenecks**: Processing a large document chunk-by-chunk in a loop is slow and fails to utilize the LLM's full reasoning capacity for orchestration.

## The Solution: RLM with PTC-Lisp

PtcRunner is uniquely suited for the RLM pattern because:
- **Context Firewall**: Large datasets stay in BEAM memory (`data/corpus`), never bloating the LLM prompt.
- **Native Parallelism**: The `pmap` (parallel map) primitive allows the model to spawn worker processes for every chunk concurrently.
- **Deterministic Slicing**: The model can use standard Lisp functions (`partition`, `split-lines`, `filter`) to prepare perfectly sized chunks for sub-agents.

## Example Workflow

1. **The Planner**: A high-level model (e.g., Sonnet 4.5) receives a task.
2. **The Plan**: Instead of answering, it generates PTC-Lisp code that:
   - Slices the corpus into 2000-line chunks.
   - Dispatches a "Worker Agent" to summarize each chunk in parallel.
   - Combines the summaries into a final report.
3. **The Workers**: Lightweight, specialized agents (e.g., Haiku 4.5) process the chunks.
4. **Conclusion**: The aggregator produces the final result.

## Comparison with Alternatives

| Feature | Standard RAG | Long Context LLM | RLM (PtcRunner) |
| :--- | :--- | :--- | :--- |
| **Data Scope** | Only sees "Relevant" snippets | Sees everything at once | Sees everything via code indices |
| **Logic** | Fixed Retrieval | Purely Probabilistic | Orchestrated Map-Reduce |
| **Parallelism** | None | None | **Native (pmap)** |
| **Cost** | Low | Very High | Medium (Structured) |

## Test Data

To effectively demonstrate RLM, the example uses a simulated **1M+ line log file** or a **concatenated technical manual**.

### Generating Test Data
You can generate a test corpus using the provided utility:
```bash
# Generates a 2MB log file with hidden "incidents"
mix run examples/rlm/gen_data.exs
```

## How to Run

1. **Install dependencies**:
   ```bash
   mix deps.get
   ```
2. **Run the demo**:
   ```bash
   mix run examples/rlm/run.exs
   ```

## Evaluation & Metrics

When running this example, look for the following metrics in the `Step` results:
- **`usage.duration_ms`**: Compare total time vs. sequential processing.
- **`usage.tokens`**: Monitor how much context was saved by using workers vs. a single large prompt.
- **`prints`**: See the intermediate "Fan-out" logs from parallel workers.
