# Benchmark Evaluation

Benchmark results for PTC-Lisp code generation across different models.

## Results Summary (v0.9.0)

| Model | Tests | Runs | Pass Rate | Avg Attempts | Duration |
|-------|-------|------|-----------|--------------|----------|
| Claude Haiku 4.5 | 30 | 30 | 99.7% (897/900) | 1.24 | 50.7m |
| Gemini 3.1 Flash Lite Preview | 30 | 30 | 99.4% (895/900) | 1.22 | 46.1m |

*Configuration: 30 tests across 5 difficulty levels, schema data mode, March 2026.*

Both Haiku 4.5 and Flash Lite are small, inexpensive models. The high pass rates demonstrate that PTC-Lisp generation does not require large or expensive models.

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

The 1.22-1.24 average attempts per test does *not* mean 22-24% of tests fail on the first try. Multi-turn tests (16-30) are designed to require multiple turns — the model searches, inspects results, then returns an answer. This is the REPL pattern working as intended.

Breaking this down by test category:

- **Single-shot tests (1-15)**: near-100% first-attempt success rate across both models. These are pure data transformation — the model writes one correct program on the first try.
- **Multi-turn tests (16-30)**: these naturally use 2-3 turns because the model needs to call tools, inspect results, then return an answer. Multiple turns here is the expected workflow, not a failure.
- **Genuine recovery**: a small percentage of attempts fail due to code errors (unsupported interop methods, type mismatches). The runtime provides clear feedback and the model self-corrects on the next turn.
- **Unrecoverable (0.3-0.6%)**: the few tests that failed even after retries.

### Unrecoverable failures are LLM reasoning errors

Across both models (1800 total test executions), 8 tests ended as FAIL. All 8 were reasoning errors — the generated code ran successfully but produced the wrong answer:

| Failure Type | Count | Example |
|--------------|-------|---------|
| Hallucinated values | 3 | Returned a made-up document ID instead of extracting from tool results |
| Wrong field lookup | 3 | Searched `:content` for "ergonomics" when the word was in `:topics` |
| Guessed instead of checking | 2 | Printed results with `println` but then guessed the answer |

Recoverable errors — ones the model self-corrected after runtime feedback — did include language-related issues: unsupported Java interop methods (`.substring`, `.contains` on non-string types), nested `#()` anonymous functions, and type mismatches. These are real PTC-Lisp limitations that the multi-turn loop compensates for.

### Recovery works

When the model writes code that fails at runtime (unsupported Java interop, type mismatches, nested anonymous functions), PTC-Runner returns a clear error message. The model then corrects its approach on the next turn. This recovery succeeds in nearly all cases — only the reasoning failures (where the code runs but produces the wrong answer) are unrecoverable.

Common recovered errors:
- Using `.substring` or `.contains` on non-string types (switches to `subs` or `some`)
- Nested `#()` anonymous functions (switches to `(fn [...] ...)`)
- Arithmetic on nil values (adds default values)

## Hardest Tests

The tests that cause the most failures and retries:

| Test | Challenge | Why It's Hard |
|------|-----------|---------------|
| #20: Find certification reimbursement policy | Search returns decoy results | Must fetch and compare content, not trust first match |
| #23: Which document mentions 'ergonomics'? | Answer requires inspecting fetched content | Model must check the right field, not guess from titles |
| #17: Find policy covering two topics | Multi-step search and intersection | Model must search, analyze, and narrow results |

These are all multi-turn tool-calling tasks requiring the model to resist premature answers and actually verify its findings.

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

# Run benchmark with reports (30 tests, default model)
mix lisp --test --runs=5 --report

# Specific model
mix lisp --test --model=haiku --runs=30

# Verbose output to debug failures
mix lisp --test --model=haiku -v
```

## Further Reading

- [SubAgent Getting Started](guides/subagent-getting-started.md) — Basic usage
- [SubAgent Advanced](guides/subagent-advanced.md) — Turn limits, truncation, prompts
- [PTC-Lisp Specification](ptc-lisp-specification.md) — Language reference
