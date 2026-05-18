# Benchmark Evaluation

Benchmark results for PTC-Lisp code generation across different models.

## Results Summary (v0.10.1)

These are real-provider demo benchmark runs from May 18, 2026, using
OpenRouter and schema data mode. Each model ran the 30-test demo suite 5
times, for 150 test executions per model.

| Model | Provider model | Tests | Runs | Pass Rate | Avg Attempts | Duration | Tokens |
|-------|----------------|-------|------|-----------|--------------|----------|--------|
| Gemini 3.1 Flash Lite | `openrouter:google/gemini-3.1-flash-lite` | 30 | 5 | 99.3% (149/150) | 1.25 | 4.1m | 10,908 |
| Claude Haiku 4.5 | `openrouter:anthropic/claude-haiku-4.5` | 30 | 5 | 99.3% (149/150) | 1.31 | 7.7m | 11,462 |

Both Haiku 4.5 and Gemini Flash Lite are small, inexpensive models. The high
pass rates show that PTC-Lisp generation is reliable without requiring a
frontier-sized model. These numbers are a small evaluation sample, not a
statistical claim about long-run model rankings.

## Test Suite

The benchmark uses 30 tests organized into 5 categories:

| Category | Tests | Turn Limit | Description |
|----------|-------|------------|-------------|
| Basic (Level 1) | 1-4 | 1 | count, filter, sum, avg |
| Intermediate (Level 2) | 5-8 | 1 | boolean fields, numeric comparison, AND logic, extremes |
| Advanced (Level 3) | 9-13 | 1 | top-N, OR logic, cross-dataset joins |
| Lisp-specific | 14-15 | 3 | group-by with aggregation, map destructuring |
| Multi-turn | 16-30 | 2-6 | tool calls, temporal analysis, optimization, exploration, plan execution |

Tests 1-15 are single-shot (one turn, no recovery). Tests 16-30 allow multi-turn interaction — the model can explore, recover from errors, and refine its approach.

## What the Numbers Show

### Multi-turn attempts are mostly by design, not errors

The 1.25-1.31 average attempts per test does *not* mean 25-31% of tests fail on
the first try. Multi-turn tests are designed to require multiple turns: the
model searches, inspects results, then returns an answer. This is the REPL
pattern working as intended.

Breaking this down by test category:

- **Single-shot tests (1-15)**: near-100% first-attempt success rate across both models. These are pure data transformation — the model writes one correct program on the first try.
- **Multi-turn tests (16-30)**: these naturally use 2-3 turns because the model needs to call tools, inspect results, then return an answer. Multiple turns here is the expected workflow, not a failure.
- **Genuine recovery**: a small percentage of attempts fail due to code errors (unsupported interop methods, type mismatches). The runtime provides clear feedback and the model self-corrects on the next turn.
- **Unrecoverable (0.7% in these runs)**: each model had one failed execution out of 150.

### Unrecoverable failures are task-level errors

Across both fresh runs (300 total test executions), 2 tests ended as FAIL:

| Model | Failed Test | Classification | What Happened |
|-------|-------------|----------------|---------------|
| Gemini 3.1 Flash Lite | #8, cheapest product name | `budget_exhausted` | The one-turn single-shot task generated code with a type error, leaving no recovery turn. |
| Claude Haiku 4.5 | #23, ergonomics document | `validation_error` | The model returned `DOC-001`; validation expected `DOC-002`. |

The Gemini failure is a good example of the single-shot tradeoff: tests 1-13
run with `max_turns: 1`, so a code error is terminal. The Haiku failure is a
reasoning or inspection failure in a tool-calling task: the code ran, but the
validated answer was wrong.

Recoverable errors — ones the model self-corrects after runtime feedback — can
include unsupported Java interop methods, nested `#()` anonymous functions,
and type mismatches. These are the cases where PTC-Runner's feedback loop
matters most.

### Recovery works

When the model writes code that fails at runtime (unsupported Java interop, type mismatches, nested anonymous functions), PTC-Runner returns a clear error message. The model then corrects its approach on the next turn. This recovery succeeds in nearly all cases — only the reasoning failures (where the code runs but produces the wrong answer) are unrecoverable.

Examples observed in the fresh reports:
- Calling unavailable substring helpers, then switching to `subs`
- Using nested `#()` anonymous functions, then switching to `(fn [...] ...)`
- Calling sequence helpers such as `first` on maps or sets, then rewriting the extraction logic

The reports also show models proactively using nil-safe patterns such as
`fnil`, `(or value 0)`, and `(get map key 0)`, but the current `N=5` runs do
not provide enough evidence to call "arithmetic on nil values" a common
recovered error.

## Hardest Tests

The tests that cause the most failures and retries:

| Test | Challenge | Why It's Hard |
|------|-----------|---------------|
| #20: Find certification reimbursement policy | Search returns decoy results | Must fetch and compare content, not trust first match |
| #23: Which document mentions 'ergonomics'? | Answer requires inspecting fetched content | Model must check the right field, not guess from titles |
| #17: Find policy covering two topics | Multi-step search and intersection | Model must search, analyze, and narrow results |

These are all multi-turn tool-calling tasks requiring the model to resist premature answers and actually verify its findings.

In the current `N=5` runs, #23 produced the only wrong-answer validation
failure, while #20 and #17 remained among the higher-attempt cases.

## Improving Reliability

### 1. Turn Limits

For complex queries, allow more iterations:

```elixir
SubAgent.run(agent, context, max_turns: 8)  # default is 5
```

### 2. Prompt Customization

The base prompt includes common mistakes to avoid. Domain-specific examples can further improve reliability. See [SubAgent Advanced](guides/subagent-advanced.md).

### 3. Language Improvements (Ongoing)

Some retries stem from models expecting Clojure functions or Java interop methods that PTC-Lisp doesn't support. We add commonly-expected functions and interop methods as they are identified through benchmark analysis.

## Running Benchmarks

```bash
cd demo

# Run benchmark with reports (30 tests, default model, 5 runs)
mix lisp --test --runs=5 --report

# Specific OpenRouter models
mix lisp --test --runs=5 --model=openrouter:gemini-flash-lite --report
mix lisp --test --runs=5 --model=openrouter:haiku --report

# Verbose output to debug failures
mix lisp --test --model=haiku -v
```

## Further Reading

- [SubAgent Getting Started](guides/subagent-getting-started.md) — Basic usage
- [SubAgent Advanced](guides/subagent-advanced.md) — Turn limits, truncation, prompts
- [PTC-Lisp Specification](ptc-lisp-specification.md) — Language reference
