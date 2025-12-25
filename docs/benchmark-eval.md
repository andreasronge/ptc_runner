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
| Gemini 2.5 Flash | **100%** | 5/5 | 11.4s | $0.0050 |
| DeepSeek v3.2 | 98.8% | 4/5 | 76s | $0.0089 |
| Haiku 4.5 | 98.8% | 4/5 | 34s | $0.0318 |

### PTC-JSON (15 tests)

| Model | Pass Rate | Perfect Runs | Avg Duration | Total Cost |
|-------|-----------|--------------|--------------|------------|
| Haiku 4.5 | **100%** | 5/5 | 50.6s | $0.0624 |
| DeepSeek v3.2 | **100%** | 5/5 | 2.2m | $0.0095 |
| Gemini 2.5 Flash | 98.7% | 4/5 | 25.8s | $0.0197 |

### Comparison

| Model | Lisp | JSON |
|-------|------|------|
| Gemini 2.5 Flash | **100%** | 98.7% |
| DeepSeek v3.2 | 98.8% | **100%** |
| Haiku 4.5 | 98.8% | **100%** |

## Token Efficiency

| Metric | JSON | Lisp |
|--------|------|------|
| System prompt | ~1,500 tokens | ~2,100 tokens |
| Output per query | ~44 tokens | ~20 tokens |

Lisp has a larger system prompt (+40%) but generates smaller programs (2.2x fewer tokens).
After ~23 queries per session, Lisp's smaller outputs offset its larger prompt.

## Conclusions

1. **Both DSLs achieve 98%+ accuracy** across all models after prompt improvements
2. **Gemini + Lisp now achieves 100%** - the best performing combination
3. **Lisp is more token-efficient for multi-query sessions** (smaller output offsets larger prompt)
4. **Speed**: Gemini is fastest (~11s), DeepSeek is slowest (~76s)
5. **Cost**: DeepSeek is 3-6x cheaper than alternatives

### Recommendations

| Priority | Model + DSL | Accuracy | Speed | Cost |
|----------|-------------|----------|-------|------|
| **Best overall** | Gemini + Lisp | 100% | Fast | Low |
| **Highest accuracy** | Gemini + Lisp or Haiku/DeepSeek + JSON | 100% | Varies | Varies |
| **Budget** | DeepSeek + either | 98.8-100% | Slow | Lowest |

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
