# Benchmark Evaluation

Benchmark results for PTC-Lisp with guidance on interpreting and improving reliability.

## Results Summary

| Model | Pass Rate | Speed | Cost | Notes |
|-------|-----------|-------|------|-------|
| Gemini 2.5 Flash | 100% | Fastest (48s) | $0.004 | Best default performance |
| DeepSeek v3 | 98% | Slowest (3.2m) | $0.002 | Most cost-effective |
| Claude Haiku 4.5 | 96% | Medium (2.2m) | $0.067 | May need higher turn limits |

*Configuration: 17 tests, 3 runs per model, default settings (January 2026)*

## Interpreting Results

**Take these numbers with a grain of salt.** The pass rates reflect how well each model fits the test constraints, not absolute capability.

For example, Haiku's lower score doesn't mean it's "worse" - analysis of failures shows it often:
- Explores data more thoroughly before answering
- Attempts to verify results before returning
- Runs out of turns while being cautious

A model that gives quick, simple answers passes easily. A model that investigates may timeout. Both behaviors have value depending on your use case.

### What the Tests Measure

| Aspect | What's Tested |
|--------|---------------|
| Syntax | Can the model generate valid PTC-Lisp? |
| Constraints | Can it solve queries within turn limits? |
| Blind analysis | Can it work with heavily truncated results? |

The tests do NOT measure general reasoning ability or which model is "smarter".

## Test Configuration

### Test Categories

| Level | Tests | Turn Limit | Description |
|-------|-------|------------|-------------|
| Basic | 1-5 | 1 | count, filter, sum, avg |
| Intermediate | 6-10 | 1 | compound filters, sort, find extremes |
| Advanced | 11-15 | 1-6 | cross-dataset joins, tool calls, pmap |
| Multi-turn | 16-17 | 4-6 | iterative reasoning with memory |

Single-shot tests (turn limit 1) are unforgiving - no recovery from errors. Multi-turn tests allow iteration but can timeout if the model explores too much.

### Truncation Settings

The LLM sees very little of execution results:

| Setting | Default | Impact |
|---------|---------|--------|
| Feedback to LLM | ~512 chars | Only 5-10 records visible from 800 |
| Result display | ~500 chars | Forces code-based analysis |

This is intentional. With 2500 records in the dataset, the LLM cannot "eyeball" the data - it must write programs to filter, aggregate, and analyze. Lower truncation limits make tests harder but more realistic.

When results are truncated, the LLM receives a hint:
```
Hint: Result truncated. Write a program that filters or transforms data to return only what you need.
```

## Improving Reliability

Several factors can improve pass rates beyond the defaults:

### 1. Increase Turn Limits

For complex analytical queries, allow more iterations:

```elixir
SubAgent.run(agent, context, max_turns: 8)  # default is 5
```

This helps models that verify results or explore data incrementally.

### 2. Adjust Truncation

Lower truncation forces more programmatic analysis. Higher truncation lets the LLM see more data directly. See [SubAgent configuration](guides/subagent-configuration.md) for options.

### 3. Prompt Customization

The base prompt includes a "NOT Supported" section that prevents common errors (e.g., using `into` instead of `set`). Domain-specific examples can further improve reliability.

## Hardest Tests

Two tests cause most failures across all models:

**Test 16: Fraud Detection** (multi-turn, limit 4)
- Open-ended: must define what "suspicious" means
- Requires exploring patterns, then making a judgment
- Models often run out of turns while investigating

**Test 14: Expense Category Analysis** (single-shot, limit 1)
- Complex aggregation with multiple derived fields
- Must get it right on first attempt
- No room for syntax errors or refinement

## Practical Recommendations

| Use Case | Recommendation |
|----------|----------------|
| Production, reliability matters | Gemini - highest pass rate |
| Cost-sensitive, batch processing | DeepSeek - 30x cheaper than Haiku |
| Anthropic ecosystem | Haiku - increase `max_turns` for complex queries |

**Key insight**: All models achieve 96%+ with default settings. Choose based on cost, speed, and ecosystem fit rather than small benchmark differences.

## Running Benchmarks

```bash
cd demo

# Basic benchmark (default model)
mix lisp --test --runs=3 --report

# Specific model
mix lisp --test --model=gemini --runs=5

# Verbose output to see failures
mix lisp --test --model=haiku -v

# With Clojure syntax validation
mix lisp --test --validate-clojure
```

Via GitHub Actions:
```bash
gh workflow run benchmark.yml -f runs=3 -f dsl=lisp
```

Reports are saved to `demo/reports/`.

## Further Reading

- [SubAgent Getting Started](guides/subagent-getting-started.md) - Basic usage
- [SubAgent Configuration](guides/subagent-configuration.md) - Turn limits, truncation
- [SubAgent Troubleshooting](guides/subagent-troubleshooting.md) - Debugging failures
