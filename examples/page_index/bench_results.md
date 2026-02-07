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

## Quality Gate Analysis

A follow-up benchmark was run with `--no-quality-gate` to isolate the impact of the planner's quality gate (pre-flight data sufficiency check). Config: planner-only, 3 runs per cell, both models.

### Quality Gate ON vs OFF

| | Gate ON (30 runs) | Gate OFF (18 runs) |
|---|---|---|
| **Success rate** | 27% (8/30) | 89% (16/18) |
| **Correct (of judged)** | 100% (8/8) | 50% (8/16) |
| **Correct / total** | 27% (8/30) | 44% (8/18) |

### Per Question (Gate OFF)

| Question | Correct / Judged | Notes |
|----------|-----------------|-------|
| Q1 (capital-intensive, M) | 3/6 | Same hit rate as with gate, no wasted runs |
| Q2 (operating margin, H) | 5/5 | Huge improvement -- gate was killing these runs |
| Q3 (M&A segment, H) | 0/5 | Still hard, but produces answers instead of timing out |

### Root Cause: False-Negative Verification

Error analysis of the quality-gate-ON runs revealed three failure modes:

1. **`:max_replans_exceeded`** (14 of 22 errors) -- The quality gate's verification predicates reject task outputs because they can't confirm specific numbers exist in raw table-format text. The gate diagnoses "upstream data insufficient" even when the fetched sections contain the right data. This triggers replanning, which fails the same way, until the replan limit (2) is hit.

2. **PdfExtractor GenServer timeout** (2 errors) -- GenServer became unresponsive early in the benchmark before the ETS cache was populated.

3. **Type validation failures** (2 errors) -- The calculator agent returns integers where the signature expects floats (e.g., `total_assets: expected float, got int`).

### Conclusion

The quality gate is actively harmful in its current form. It never saved a run by catching genuinely bad data -- every run that passed the gate on the first try would have succeeded without it. Meanwhile, it killed 14 runs that would have otherwise produced answers (and based on the gate-OFF results, roughly half of those answers would have been correct).

The gate should either be removed or made much more lenient -- only rejecting truly empty or malformed responses rather than trying to validate whether the right data was fetched from document sections.

## Recommendations

1. **Disable quality gate** -- it reduces overall accuracy from 44% to 27% by killing runs with false-negative verification
2. **Use sonnet for accuracy-critical tasks** -- haiku is cheaper but significantly less accurate
3. **Planner without gate is the best cost/accuracy tradeoff** -- 44% accuracy at 11k tokens vs agent's 30% at 80k tokens
4. **Q3-style questions need better retrieval** -- consider adding segment-level organic growth data to the index summaries so the retriever can locate the right sections
5. **Fix int/float type validation** -- the planner's signature validation should coerce integers to floats rather than rejecting them

## Reproducing

```bash
cd examples/page_index

# Run benchmarks
mix run bench.exs --runs 5 --models bedrock:haiku,bedrock:sonnet --modes agent,planner

# Run without quality gate
mix run bench.exs --runs 3 --modes planner --no-quality-gate

# Analyze results
mix run analyze.exs bench_runs/<timestamp>

# With LLM-as-judge
mix run analyze.exs bench_runs/<timestamp> --judge
```
