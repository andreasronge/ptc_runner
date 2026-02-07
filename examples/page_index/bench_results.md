# PageIndex Benchmark Results

Benchmark run: 2026-02-07

## Configuration

- **Models**: bedrock:haiku, bedrock:sonnet
- **Modes**: agent (single-pass SubAgent), planner (MetaPlanner with verification)
- **Questions**: 3 (from FinanceBench, 3M 2022 10K only)
- **Runs per cell**: 5
- **Total runs**: 60
- **Judge model**: bedrock:sonnet

## Questions

| ID | Question | Difficulty |
|----|----------|------------|
| Q1 | Is 3M a capital-intensive business based on FY2022 data? | Medium |
| Q2 | What drove operating margin change as of FY2022 for 3M? | Hard |
| Q3 | If we exclude the impact of M&A, which segment has dragged down 3M's overall growth in 2022? | Hard |

## Overall Results

- **Successful runs**: 38/60 (63%)
- **Correctness** (of 38 judged): 18 correct, 3 partially correct, 11 incorrect
- **Effective accuracy** (correct / total attempted): 30%

## Results by Model and Mode

### Correctness (correct / judged runs)

|                        | Haiku Agent | Haiku Planner | Sonnet Agent | Sonnet Planner |
|------------------------|-------------|---------------|--------------|----------------|
| Q1 (capital-intensive) | 1/5         | 2/3           | 4/5          | 1/5            |
| Q2 (operating margin)  | 2/5         | 1/1           | 2/2          | 4/4            |
| Q3 (M&A segment)       | 1/3         | 0/0           | 0/5          | 0/0            |

### Error Rate (errors / total runs)

|                        | Haiku Agent | Haiku Planner | Sonnet Agent | Sonnet Planner |
|------------------------|-------------|---------------|--------------|----------------|
| Q1 (capital-intensive) | 0/5         | 2/5           | 0/5          | 0/5            |
| Q2 (operating margin)  | 0/5         | 4/5           | 3/5          | 1/5            |
| Q3 (M&A segment)       | 2/5         | 5/5           | 0/5          | 5/5            |

### Performance

| Metric         | Agent  | Planner |
|----------------|--------|---------|
| Avg duration   | 39.0s  | 28.2s   |
| Avg tokens     | 80.0k  | 11.2k   |
| Avg turns      | 8.5    | 1       |

## Key Findings

### Sonnet agent is the most accurate

Sonnet agent achieved the highest correctness rate (6/12 correct out of non-error runs), particularly on Q1 (capital-intensive) where it got 4/5 correct. It was the only configuration to reliably answer Q2 when it didn't error.

### Planner uses 7x fewer tokens

Planner mode consistently used ~11k tokens per run vs ~80k for agent mode. The planner decomposes the question into a plan upfront (1 LLM turn for planning), then executes deterministic fetch tasks and a single synthesis step.

### Planner reliability is poor on hard questions

Haiku planner failed on all 5 runs for Q3 and 4/5 runs for Q2 (mostly timeouts at 300s). The planner generates complex multi-step plans that are brittle -- when any step fails verification, it replans, which can cascade into timeouts.

### Q3 (M&A segment exclusion) is unsolved

No model/mode combination reliably answers Q3. This question requires:
1. Understanding what M&A impact means in this context
2. Finding organic growth rates per segment
3. Identifying the Consumer segment as the underperformer

Sonnet agent got 0/5 correct (all partially correct or incorrect). Haiku agent got 1/3. Both planner configurations errored on all 5 runs.

### Haiku agent is fast but inaccurate on Q1

Haiku agent went 1/5 on Q1 (capital-intensive). It tends to conclude 3M *is* capital-intensive, getting the direction wrong. This suggests haiku struggles with the reasoning step of comparing the CAPEX/revenue ratio against industry benchmarks.

### Planner agent types show rich decomposition

The planner creates specialized agents per run. Observed agent types across all runs:
analyst, analyzer, calculator, capital_intensity_analyzer, computation_engine, financial_analyst, growth_analyzer, growth_calculator, margin_analyzer, segment_analyst, segment_calculator, synthesizer.

## Recommendations

1. **Use sonnet for accuracy-critical tasks** -- haiku is cheaper but significantly less accurate
2. **Planner mode needs reliability improvements** before it can replace agent mode, despite its token efficiency
3. **Q3-style questions need better retrieval** -- consider adding segment-level organic growth data to the index summaries so the retriever can locate the right sections
4. **Add retry/timeout handling in planner** -- the 300s timeouts on haiku planner suggest the plan executor needs better circuit-breaking

## Reproducing

```bash
cd examples/page_index

# Run benchmarks
mix run bench.exs --runs 5 --models bedrock:haiku,bedrock:sonnet --modes agent,planner

# Analyze results
mix run analyze.exs bench_runs/<timestamp>

# With LLM-as-judge
mix run analyze.exs bench_runs/<timestamp> --judge
```
