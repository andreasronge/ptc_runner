# Benchmark Evaluation

Benchmark results comparing LLM accuracy on PTC-Lisp and PTC-JSON DSLs.

## Test Configuration

- **Models**: Gemini 2.5 Flash, Claude Haiku 4.5, DeepSeek v3.2 (via OpenRouter)
- **Dataset**: 2500 records (500 products, 1000 orders, 500 employees, 500 expenses)
- **Tests**: 15-16 queries across 3 difficulty levels
- **Data mode**: Schema-only (LLM sees field names/types, not actual data)
- **Runs**: 5 runs per model (statistically meaningful)
- **Date**: December 2025

### Test Categories

| Level | Tests | Description |
|-------|-------|-------------|
| 1 | 1-5 | Basic: count, filter, sum, avg |
| 2 | 6-10 | Intermediate: compound filters, sort, OR logic |
| 3 | 11-16 | Advanced: cross-dataset joins, multi-turn memory |

## Results

### PTC-Lisp (16 tests)

| Model | Pass Rate | Perfect Runs | Avg Duration | Total Cost |
|-------|-----------|--------------|--------------|------------|
| Gemini 2.5 Flash | **98.75%** | 4/5 | 16.9s | $0.0046 |
| DeepSeek v3.2 | 97.5% | 3/5 | 83.6s | $0.0039 |
| Haiku 4.5 | 95.0% | 1/5 | 35.3s | $0.0317 |

### PTC-JSON (15 tests)

| Model | Pass Rate | Perfect Runs | Avg Duration | Total Cost |
|-------|-----------|--------------|--------------|------------|
| Haiku 4.5 | **100%** | 5/5 | 54.7s | $0.0707 |
| Gemini 2.5 Flash | 90.7% | 0/5 | 25.4s | $0.0110 |
| DeepSeek v3.2 | 70.7% | 0/5 | 3.5m | $0.0063 |

### Comparison

| Model | Lisp | JSON | Delta |
|-------|------|------|-------|
| Haiku 4.5 | 95.0% | **100%** | +5% |
| Gemini 2.5 Flash | **98.75%** | 90.7% | -8% |
| DeepSeek v3.2 | 97.5% | 70.7% | **-27%** |

## Failure Analysis

### DeepSeek JSON Issues

DeepSeek's 27% accuracy drop on JSON (vs Lisp) is not timeout-related. Primary causes:

| Error Type | % of Failures |
|------------|---------------|
| Empty LLM responses | 68% |
| Over-engineered output | 9% |
| Other (logic errors) | 23% |

- **Empty responses**: DeepSeek returns no content unpredictably (0 occurrences with Lisp)
- **Over-engineering**: Returns `{"count": 105, "percentage": 52.5}` instead of just `105`

### Gemini JSON Issues

Gemini's consistent failure on "count distinct" queries (returns 1000 instead of correct count). No empty response issues.

## Conclusions

1. **DSL choice matters by model**: Gemini excels at Lisp, Haiku excels at JSON
2. **Lisp is more consistent**: All models score 95%+ on Lisp; JSON varies widely
3. **Token efficiency**: Lisp uses ~50% fewer tokens than JSON for equivalent queries
4. **Cost vs accuracy trade-off**: DeepSeek is 7-10x cheaper but accuracy drops significantly for JSON
5. **Speed**: Gemini is fastest (17-25s), DeepSeek is slowest (1.4-3.5m)

### Recommendations

- **Best overall**: Gemini 2.5 Flash + Lisp (98.75% accuracy, fast, cheap)
- **Best for JSON**: Haiku 4.5 (100% accuracy, but 6x more expensive)
- **Budget option**: DeepSeek + Lisp only (97.5% accuracy at lowest cost)

## Running Benchmarks

```bash
cd demo

# Run Lisp benchmark (5 runs)
mix lisp --test --runs=5 --report

# Run JSON benchmark
mix json --test --runs=5 --report

# With specific model
mix lisp --test --model=gemini --runs=5

# With Clojure syntax validation
mix lisp --test --validate-clojure
```

Or via GitHub Actions:
```bash
gh workflow run "Benchmark Tests" -f runs=5 -f dsl=both
```

Reports are saved to `demo/reports/`.
