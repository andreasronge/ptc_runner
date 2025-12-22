# Benchmark Evaluation

Benchmark results comparing LLM accuracy on PTC-Lisp and PTC-JSON DSLs.

## Test Configuration

- **Models**: Gemini 2.5 Flash, Claude Haiku 4.5, DeepSeek v3.2 (via OpenRouter)
- **Dataset**: 2500 records (500 products, 1000 orders, 500 employees, 500 expenses)
- **Tests**: 15-16 queries across 3 difficulty levels
- **Data mode**: Schema-only (LLM sees field names/types, not actual data)
- **Runs**: 5 runs per model
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
| Haiku 4.5 | **100%** | 5/5 | 50.6s | $0.0624 |
| DeepSeek v3.2 | **100%** | 5/5 | 2.2m | $0.0095 |
| Gemini 2.5 Flash | 98.7% | 4/5 | 25.8s | $0.0197 |

### Comparison

| Model | Lisp | JSON |
|-------|------|------|
| Gemini 2.5 Flash | **98.75%** | 98.7% |
| DeepSeek v3.2 | 97.5% | **100%** |
| Haiku 4.5 | 95.0% | **100%** |

## Conclusions

1. **Both DSLs now achieve 95%+ accuracy** across all models after prompt improvements
2. **Lisp is more token-efficient**: ~50% fewer tokens than JSON for equivalent queries
3. **Speed**: Gemini is fastest (17-26s), DeepSeek is slowest (1.4-2.2m)
4. **Cost**: DeepSeek is 3-6x cheaper than alternatives

### Recommendations

| Priority | Model + DSL | Accuracy | Speed | Cost |
|----------|-------------|----------|-------|------|
| **Best overall** | Gemini + Lisp | 98.75% | Fast | Low |
| **Highest accuracy** | Haiku/DeepSeek + JSON | 100% | Med/Slow | Med/Low |
| **Budget** | DeepSeek + either | 97.5-100% | Slow | Lowest |

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
