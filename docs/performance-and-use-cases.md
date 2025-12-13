# Performance and Use Cases

This document covers PtcRunner's performance characteristics, ideal use cases, and benchmark results.

## Why Programmatic Tool Calling?

Traditional LLM tool calling requires a round-trip for each operation:

```
User: "What's the average salary of senior engineers?"
LLM → Tool: get_employees()
Tool → LLM: [500 employees...]
LLM → Tool: filter(department=engineering, level=senior)
Tool → LLM: [45 employees...]
LLM → Tool: calculate_average(field=salary)
Tool → LLM: 124807.24
LLM → User: "The average salary is $124,807.24"
```

**4 LLM calls, 4 round-trips, high latency and cost.**

With PTC, the LLM writes a single program:

```clojure
(->> ctx/employees
     (filter (all-of (where :department = :engineering)
                     (where :level = :senior)))
     (avg-by :salary))
```

**1 LLM call, executed locally in ~1ms.**

## Performance Benchmarks

### Test Configuration

- **Model**: DeepSeek V3.2 (via OpenRouter)
- **Dataset**: 2500 records (500 products, 1000 orders, 500 employees, 500 expenses)
- **Tests**: 15 queries across 3 difficulty levels
- **Data mode**: Schema-only (LLM sees field names/types, not actual data)
- **Runs**: Single benchmark run (not statistically significant)

### Results Snapshot

These results demonstrate that the DSLs work and are cost-effective, but the sample size is too small for precise accuracy claims.

| Metric | PTC-JSON | PTC-Lisp |
|--------|----------|----------|
| Passed | 15/15 | 14/15 |
| Avg Attempts | 1.3 | 1.2 |
| Total Duration | 2.4 min | 1.2 min |
| Output Tokens | 899 | 118 |
| Total Cost | ~$0.002 | ~$0.002 |

### Token Efficiency

PTC-Lisp is significantly more token-efficient:

```json
// PTC-JSON: 47 tokens
{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "employees"},
      {"op": "filter", "where": {"op": "eq", "field": "level", "value": "senior"}},
      {"op": "avg", "field": "salary"}
    ]
  }
}
```

```clojure
;; PTC-Lisp: 6 tokens
(->> ctx/employees (filter (where :level = :senior)) (avg-by :salary))
```

### Execution Performance

Program execution is fast—the sandbox overhead dominates:

- Simple queries: <5ms
- Complex multi-dataset joins: <20ms
- Sandbox spawn overhead: ~10-50ms

The 1-second default timeout is conservative; most programs complete in milliseconds.

## Running Benchmarks

The `demo/` directory contains a test runner for evaluating LLM accuracy:

```bash
cd demo

# Run JSON DSL benchmark
mix json --test

# Run Lisp DSL benchmark
mix lisp --test

# With specific model
PTC_TEST_MODEL=claude-haiku mix lisp --test

# With Clojure syntax validation (requires Babashka)
mix lisp --test --validate-clojure
```

Reports are saved to `demo/reports/` with timestamps.

### Test Categories

| Level | Tests | Description |
|-------|-------|-------------|
| 1 | 1-5 | Basic: count, filter, sum, avg |
| 2 | 6-10 | Intermediate: compound filters, sort, OR logic |
| 3 | 11-15 | Advanced: cross-dataset joins, multi-turn memory |

## When to Use PtcRunner

### Good Fit

| Use Case | Why |
|----------|-----|
| **Data analysis agents** | Filter, aggregate, join operations on datasets |
| **Cost-sensitive applications** | Single LLM call replaces multiple tool calls |
| **High-volume workloads** | Sub-millisecond execution after LLM generates program |
| **Multi-step pipelines** | Compose operations without round-trips |
| **Sandboxed execution** | Untrusted LLM output runs safely with resource limits |

### Poor Fit

| Use Case | Why |
|----------|-----|
| **External API calls** | PTC is for data transformation, not I/O |
| **Single simple operations** | Overhead not justified for one-shot queries |
| **Dynamic tool discovery** | Tools must be registered upfront |
| **Real-time streaming** | Programs execute atomically, not incrementally |

## DSL Selection Guide

### Choose PTC-Lisp when:

- Token cost is a priority (8x fewer output tokens)
- Queries involve complex pipelines (threading macros are cleaner)
- You want Clojure-compatible syntax for validation
- The LLM handles Lisp-like syntax well

### Choose PTC-JSON when:

- LLM is more reliable with JSON output
- You need strict schema validation
- Debugging/logging benefits from explicit structure
- Integration with JSON-based systems

## Cost Considerations

The primary cost advantage of PTC is **fewer LLM round-trips**:

- Traditional approach: N tool calls = N LLM invocations
- PTC approach: 1 program generation + occasional retries

Token efficiency also matters for high-volume use:
- PTC-Lisp uses ~8x fewer output tokens than PTC-JSON
- System prompts are compact (~1400-2000 tokens)

Actual savings depend on your model, query complexity, and retry rate. Run the benchmark with your target model to estimate costs.

## Known Limitations

### Multi-turn Memory Pattern

Both DSLs show weakness on two-turn memory queries where:
1. Turn 1: Store computed data in memory
2. Turn 2: Read from memory and return a value

LLMs sometimes return `{:key value}` maps when a plain value is expected. This is a prompt/training issue, not a DSL limitation. The test suite includes these edge cases to track improvements.

### Prompt Engineering Required

Achieving high accuracy requires well-crafted system prompts. The library provides `PtcRunner.Schema.to_prompt/0` for JSON and example prompts in the demo, but tuning for specific models improves results.

## References

- [Anthropic PTC Research](https://www.anthropic.com/research/ptc)
- [PTC-JSON Specification](ptc-json-specification.md)
- [PTC-Lisp Specification](ptc-lisp-specification.md)
- [Demo Application](../demo/README.md)
