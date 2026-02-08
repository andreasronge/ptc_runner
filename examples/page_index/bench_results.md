# PageIndex Benchmark Results

Benchmark run: 2026-02-08 (iterative mode, post tool-signature + full node-ID fixes)

## Configuration

- **Models**: bedrock:haiku, bedrock:sonnet
- **Mode**: iterative (multi-round SubAgent with extraction + synthesis loop)
- **Questions**: 3 (from FinanceBench, 3M 2022 10K only)
- **Runs per cell**: 5
- **Total runs**: 30
- **Quality gate**: ON
- **Benchmark**: `bench_runs/20260208T170939Z`

## Questions

| ID | Question | Difficulty |
|----|----------|------------|
| Q1 (01226) | What drove operating margin change as of FY2022 for 3M? | Hard |
| Q2 (01865) | If we exclude the impact of M&A, which segment has dragged down 3M's overall growth in 2022? | Hard |
| Q3 (00499) | Is 3M a capital-intensive business based on FY2022 data? | Medium |

**Ground truth**:
- Q1: Operating margin decreased ~1.7pp due to gross margin decline from higher raw material/logistics costs, increased SG&A from litigation charges, and restructuring costs.
- Q2: The Consumer segment, which experienced organic sales decline of approximately 0.9%.
- Q3: No. 3M has a CapEx/Revenue ratio of ~5.1%, indicating efficient capital management.

## Overall Results

| Model | Success Rate | Avg Duration | Avg Turns | Avg Tool Calls |
|-------|-------------|-------------|-----------|----------------|
| **haiku/iterative** | **100%** (15/15) | 64s | 16.5 | 15.9 |
| **sonnet/iterative** | **100%** (15/15) | 68s | 13.3 | 10.4 |

## Per-Question Results

| Question | Model | Success | Avg Duration | Avg Turns | Turns per run |
|----------|-------|---------|-------------|-----------|---------------|
| Q1 (operating margin) | haiku | 5/5 | 48s | 10.6 | 10, 10, 10, 10, 13 |
| Q1 (operating margin) | sonnet | 5/5 | 55s | 10.6 | 11, 10, 11, 11, 10 |
| Q2 (segment drag) | haiku | 5/5 | 105s | 28.8 | 11, 22, 22, 45, 44 |
| Q2 (segment drag) | sonnet | 5/5 | 100s | 19.8 | 22, 11, 22, 22, 22 |
| Q3 (capital intensive) | haiku | 5/5 | 40s | 10.0 | 11, 9, 10, 10, 10 |
| Q3 (capital intensive) | sonnet | 5/5 | 50s | 9.4 | 10, 8, 11, 8, 10 |

## Bugs Fixed Since Previous Benchmark

Two bugs in the previous benchmark (2026-02-07) caused significantly worse performance:

### 1. Missing tool signatures (all retrievers)

Tools were passed as bare anonymous functions to SubAgent, rendering as `tool/fetch_section() -> any` in the LLM namespace. The LLM had no visibility into parameter names or return types, causing it to waste 5-7 turns per extraction guessing map keys (`:text` instead of `:content`, using `keys`, `type` to introspect).

**Fix**: Added explicit signatures — the LLM now sees:
```
tool/fetch_section(node_id string, offset int) -> {node_id string, title string, pages string, content string, total_chars int, offset int, truncated bool, hint string}
```

### 2. Truncated node IDs (indexer)

Node IDs were capped at 30 chars (root) / 15 chars (children), producing ambiguous IDs like `financial_state_consolidated_statement_of_inco` (Income? Comprehensive Income?) and `management_s_di_performance_by_business_segmen` (missing `ts` suffix).

**Fix**: Removed the `String.slice` truncation. Node IDs now carry their full descriptive names.

### Impact of fixes

| Metric | Before fixes | After fixes |
|--------|-------------|-------------|
| Q2 sonnet avg turns | 24.4 | **19.8** (-19%) |
| Q2 haiku avg turns | 33.6 | **28.8** (-14%) |
| Q2 sonnet 45-turn outliers | 1 of 5 | **0 of 5** |
| Q1/Q3 turns | ~10.6 | ~10.3 (no change) |
| Overall success | 100% | 100% |

The fixes primarily helped Q2 (the hardest question) where ambiguous node IDs and blind tool usage caused extra iterations.

## Key Findings

### 1. Iterative mode achieves 100% completion

Both haiku and sonnet complete all 30 runs successfully. The extraction+synthesis loop is robust — when one extraction pass is insufficient, the synthesis agent requests specific follow-up data.

### 2. Q1 and Q3 are efficient (10 turns)

Both questions resolve in ~10 turns (1-2 extraction iterations), indicating the index structure and tool signatures are well-matched to these queries. Sonnet uses fewer tool calls than haiku (7.2 vs 10.6 for Q1) — more precise section targeting.

### 3. Q2 remains the hardest question

Q2 (segment drag excluding M&A) averages 20-29 turns with high variance. The Consumer segment's organic growth data is reported separately from the 3 main reportable segments, requiring broader exploration. Sonnet is more consistent (all runs 11-22 turns) while haiku has outliers hitting 44-45 turns.

### 4. Haiku is viable for iterative mode

Unlike planner mode (where haiku had 13% success in the previous benchmark), haiku achieves 100% in iterative mode. The framework handles orchestration while the model focuses on extraction — a better fit for smaller models.

### 5. Accuracy bottleneck is reasoning, not retrieval

Q3 (capital intensity) is consistently retrieved correctly (CapEx/Revenue = 5.1%) but models often conclude 3M IS capital-intensive, lacking the context that 5.1% is low for manufacturing. Q2 accuracy depends on whether the model explores beyond the 3 main reportable segments to find Consumer data.

## Reproducing

```bash
cd examples/page_index

# Re-index (required after node-ID fix)
mix run run.exs --index data/3M_2022_10K.pdf

# Run iterative benchmark
mix run bench.exs --runs 5 --models bedrock:haiku,bedrock:sonnet \
  --modes iterative --test-set 3M_2022_10K

# Single question
mix run bench.exs --runs 1 --modes iterative -q 01865 --models bedrock:sonnet

# Analyze results
mix run analyze.exs bench_runs/<timestamp>
```
