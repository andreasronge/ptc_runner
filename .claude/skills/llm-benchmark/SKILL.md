---
name: llm-benchmark
description: |
  Guide for designing, running, and interpreting LLM benchmark experiments — prompt ablation,
  statistical analysis of pass rates, per-turn interaction metrics, and data-leakage prevention.
  Use this skill when the user is: running benchmark tests against LLM prompts or configurations,
  comparing prompt variants (A/B testing prompts), analyzing benchmark results for statistical
  significance, designing test suites for LLM behavior, investigating per-turn LLM interaction
  quality, or asking whether sample sizes are sufficient. Also use when the user mentions ablation,
  pass rate, confidence intervals, Fisher exact test, or prompt optimization in a benchmarking context.
---

# LLM Benchmark & Prompt Optimization

## Purpose

Help design rigorous LLM benchmarks that produce actionable conclusions, not misleading numbers. The core challenge: LLM outputs are stochastic, sample sizes are expensive, and naive pass/fail comparisons hide important signals.

## Benchmark Integrity — Data Leakage Prevention

This is the most common source of misleading benchmark results. Before running any benchmark:

**Check for leakage between test data and prompts.** The LLM's system prompt, prompt templates, and any addon prompts must not contain:
- Test-specific values, IDs, or expected answers
- Domain-specific examples that overlap with test data (e.g., if tests query documents, prompt examples should not reference those documents)
- Hints about the structure or content of test datasets

**Use domain-blind prompts.** Orchestration prompts (system prompts, planners, agent configurations) must work across unrelated domains without changes. Tool descriptions may reference their specific domain, but the reasoning layer should not.

**Verify before each run:**
1. Search the prompt files for any test-case values (IDs, names, expected answers)
2. Check that prompt examples use generic/synthetic data, not test data
3. Ensure test constraints are not visible to the LLM in any form

**When modifying prompts during optimization:** Re-verify after every edit. It's tempting to add "helpful" examples from test cases — this invalidates the benchmark entirely.

## Experimental Design

### Two Benchmark Modes

Always be clear about which question you're answering:

**Policy benchmarks** — "Should the default behavior change?"
- Each test keeps its natural configuration (turn budget, routing, etc.)
- Compare current defaults against proposed new defaults
- Tests must span all task types, not just the ones you expect to improve

**Mechanism benchmarks** — "Does this specific technique help?"
- Force equal conditions across variants (same turn budget, same model, same temperature)
- Isolate one variable at a time
- Use this for understanding why something works, not for shipping decisions

Do not use mechanism benchmarks to make policy decisions. A forced 6-turn budget on a naturally single-turn task answers a different question than whether the default should change.

### Sample Size

LLM benchmarks have high variance. Before running, decide what effect size you need to detect:

| Detectable difference | Runs per variant |
|-----------------------|-----------------|
| 20 percentage points | ~100 |
| 15pp | ~175 |
| 10pp | ~400 |
| 5pp | ~1500 |

At n=30, a swing from 33% to 53% pass rate is within normal ±1 standard deviation. That's not a signal — it's noise. Either run more samples or accept that you can only detect large differences.

**Rule of thumb:** If you can't tell the variants apart at n=30, the difference is either small or nonexistent. Run n=100+ only if you have reason to believe a real 10-15pp difference exists.

### What to Measure

Pass rate alone is too noisy at practical sample sizes. Per-turn metrics give 4-6x more data points from the same runs:

| Metric | What it reveals |
|--------|----------------|
| First-turn validity | Does the model produce structurally valid output on turn 1? |
| Parse/protocol error rate | Is the model following the expected format? |
| Turns to first useful action | How quickly does the model engage with the task? |
| Mean turns on pass | Efficiency — does one variant waste turns? |
| Error recovery (salvage) rate | Of runs with errors, how many still succeed? |
| Tokens per successful run | Cost-efficiency — the most decision-relevant cost metric |
| Budget exhaustion rate | Does the variant run out of turns? |

**Important distinction:** "First-turn validity" means "did the model produce structurally correct output" (e.g., parseable code), not "did turn 1 produce the right answer." Measure interaction quality, not task success, at the per-turn level.

**Salvage rate** should include all failure types (parse, runtime, tool errors), not just one category. A run where the model called a wrong function and then recovered is salvage behavior.

### Statistical Tools

**Wilson score interval** — confidence interval for a proportion (pass rate). Better than normal approximation for small samples.

**Fisher exact test** — compare pass/fail rates between two variants. Returns a p-value. p < 0.05 means the difference is unlikely due to chance. p > 0.2 means no meaningful signal at this sample size.

**Two-proportion sample size** — how many runs per variant to detect a given difference with desired power. This answers "how many runs do I need?" before you start.

### Common Mistakes

1. **Running small batches and comparing batch-to-batch.** Three batches of n=30 showing 33%, 53%, 43% are consistent with a true rate of ~43%. The variation is expected, not alarming.

2. **Confounding variables.** If variant A uses 6 turns and variant B uses 4, you can't attribute pass rate differences to the prompt change — it might be the turn budget.

3. **Overfitting to specific tests.** If you optimize a prompt on tests 20-23 and it improves on tests 20-23, that's not evidence it's better in general. Test on held-out tasks.

4. **Reporting "precision" when you mean "detection."** "Recommended N for 5pp precision" (estimating one rate) is different from "Recommended N to detect a 5pp difference" (comparing two rates). Label clearly.

## Test Suite Design

### Organize by Interaction Pattern

Tests should cover distinct interaction patterns, not just difficulty levels. Having 8 tests that all test "single-expression computation" doesn't tell you more than 2-3.

| Category | What it tests | Guideline |
|----------|--------------|-----------|
| Direct answer | Simple computation, return immediately | 2-3 tests |
| Inspect-then-answer | Need to examine data before answering | 2-3 tests |
| Multi-step exploration | Search, fetch, compare, answer | 3-4 tests |
| Error recovery | Tasks where turn 1 commonly fails | 2-3 tests |
| State persistence | Multi-turn with memory across queries | 2 tests |

### Test Case Hygiene

- **Generic domains.** Test data should not overlap with common training data patterns. Avoid "employee" + "42" combinations.
- **Decoy data.** For retrieval tasks, include plausible-but-wrong results that require the model to verify rather than guess.
- **Constraint validation.** Test pass/fail should be determined by objective constraints (exact match, range, type), not subjective judgment.

## Prompt Optimization Workflow

### The Iteration Loop

1. **Establish baseline.** Run current prompt configuration on the full test suite. Record pass rate, per-turn metrics, and token usage.

2. **Change one thing.** Modify the prompt, a configuration knob, or a feedback format. Document what changed and why.

3. **Run comparison.** Same tests, same model, same conditions. Mechanism benchmark to understand the change; policy benchmark if considering making it the default.

4. **Interpret results.** Look at per-turn metrics, not just pass rate. A prompt that improves first-turn validity but doesn't yet improve pass rate is moving in the right direction.

5. **Check for regressions.** Before celebrating an improvement on hard tasks, verify no regression on easy tasks. Run the full suite, not just the tasks you targeted.

6. **Cross-model check.** Run at least one additional model family early (even at smaller N) to catch model-specific effects.

### Prompt Change Principles

- **Explain intent, not just rules.** "Do NOT guess" works better than "ALWAYS verify" because it explains the why.
- **Shorter prompts are better.** Every instruction the model has to parse costs attention. Remove lines that aren't earning their weight.
- **Avoid competing instructions.** "Explore incrementally" and "return directly if obvious" fight each other. Pick one framing and let the model decide based on task complexity.
- **Watch for waste turns.** Read actual turn transcripts, not just final results. If the model consistently wastes turn 1 on something unproductive, the prompt is causing it.
- **Test with `max_turns: 1` AND `max_turns: N`.** A good prompt should work for both — the model should return directly when it can, and explore when it must.

### Decision Framework

Before making a prompt change the default:

| Check | How |
|-------|-----|
| No regression on simple tasks | Policy benchmark across all test types |
| Improvement on target tasks | Mechanism benchmark on specific tasks |
| Token cost acceptable | Compare tokens/pass (success-adjusted) |
| Works across models | Cross-model spot check |
| No data leakage | Search prompts for test values |
