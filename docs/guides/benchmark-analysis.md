# Benchmark Analysis & Ablation Testing

Tools for measuring per-turn interaction quality across prompt configurations, with statistical comparison.

## Architecture

```
PtcRunner.Metrics.TurnAnalysis   — extracts per-turn metrics from Step/Turn structs
PtcRunner.Metrics.Statistics     — Wilson CI, Fisher exact test, sample size calculations

PtcDemo.Ablation.Runner          — runs variant x test x N matrix via LispTestRunner
PtcDemo.Ablation.Report          — side-by-side comparison tables + JSON export
Mix.Tasks.Ablation               — CLI interface

PtcDemo.CljReplExperiment        — independent baseline: real Clojure REPL (no PTC-Lisp)
```

## Per-Turn Metrics (`TurnAnalysis`)

Every `SubAgent.run/2` produces a `%Step{}` containing a list of `%Turn{}` structs. `TurnAnalysis` extracts interaction quality metrics from this data:

| Metric | What it measures |
|--------|-----------------|
| `first_turn_valid?` | Did turn 1 produce parseable code? (program != nil) |
| `parse_failure_rate` | Fraction of turns with `:parse_error` |
| `no_code_rate` | Fraction of turns with `:no_code_found` |
| `multi_code_block_rate` | Fraction of turns with `:multiple_code_blocks` |
| `turns_to_first_tool_call` | Which turn first called a tool successfully? |
| `budget_exhausted?` | Did the run exhaust all turns? |
| `has_failed_turn?` | Did any turn fail (parse, runtime, tool errors)? |
| `turn_count` | Total turns used |

These measure **interaction mechanics**, not just final pass/fail. A variant that improves first-turn validity and reduces parse errors is stabilizing the interaction pattern, even if final pass rate variance is still high.

### Usage

```elixir
alias PtcRunner.Metrics.TurnAnalysis

# Single run
step = Agent.last_step()
metrics = TurnAnalysis.analyze(step, passed?: true)
# => %{first_turn_valid?: true, parse_failure_rate: 0.0, turn_count: 3, ...}

# Aggregate across runs
all_metrics = Enum.map(runs, &TurnAnalysis.analyze(&1.step, passed?: &1.passed?))
summary = TurnAnalysis.aggregate(all_metrics)
# => %{pass_rate: 0.85, first_turn_validity_rate: 0.95, mean_turns_on_pass: 2.1, ...}
```

### Aggregated Metrics

`aggregate/1` computes summary statistics from a list of per-run metrics:

- `pass_rate` — fraction of runs that passed
- `first_turn_validity_rate` — fraction where turn 1 produced parseable code
- `mean_parse_failure_rate`, `mean_no_code_rate`, `mean_multi_code_block_rate`
- `mean_turns_on_pass` — average turns used on successful runs (nil if none)
- `recoverable_error_salvage_rate` — of runs with any failed turn, fraction that still passed
- `budget_exhausted_rate` — fraction that ran out of turns

## Statistical Comparison (`Statistics`)

```elixir
alias PtcRunner.Metrics.Statistics

# Confidence interval for a pass rate
Statistics.wilson_interval(7, 10)
# => {0.39, 0.93}  (95% CI)

# Compare two variants
Statistics.fisher_exact_p(9, 1, 5, 5)
# => 0.07  (borderline significant)

# How many runs needed to detect a 5pp difference?
Statistics.sample_size_for_two_proportions(0.5, 0.55)
# => ~1500 per variant
```

### Interpreting Results

- **p < 0.05**: Statistically significant difference
- **p > 0.2**: No meaningful signal at this sample size
- When pass rate variance is high (33%-53% at n=30), per-turn metrics are more diagnostic — they give 4-6x more data points from the same runs

## Ablation Runner

Runs a controlled experiment: variant x test x N matrix.

### Two Benchmark Modes

**Policy benchmarks** answer "should default behavior change?" Each test keeps its natural turn budget.

```bash
# Policy: current routing vs smart REPL routing across all tests
mix ablation --variants=auto,smart_auto --runs=30 --tests=1,2,3,4,5,6,7,8,9,10,20,21,22,23
```

**Mechanism benchmarks** answer "does REPL framing improve interaction quality?" Both variants get the same forced turn budget.

```bash
# Mechanism: isolate REPL effect at equal 6-turn budget
mix ablation --variants=baseline,repl_full --runs=30 --tests=20,23
```

### Predefined Variants

**Policy variants** (natural turn budgets, runner-level routing):

| Name | Routing |
|------|---------|
| `auto` | Current default: single_shot / multi_turn per test |
| `smart_auto` | single_shot for single-turn, repl for multi-turn |

**Mechanism variants** (forced 6-turn budget, agent-level overrides):

| Name | Prompt | Format Options |
|------|--------|----------------|
| `baseline` | `:auto_return` | default |
| `repl_only` | `:repl` | none |
| `repl_full` | `:repl` | context_in_system + minimal_turn_info |

### Programmatic Usage

```elixir
alias PtcDemo.Ablation.{Runner, Report}

# Policy benchmark
variants = [
  %{name: "auto", prompt: :auto},
  %{name: "smart_auto", prompt: :smart_auto}
]

# Mechanism benchmark
variants = [
  %{name: "baseline", agent_overrides: [prompt_profile: :auto_return, max_turns: 6]},
  %{name: "repl_full", agent_overrides: [
    prompt_profile: :repl, max_turns: 6,
    format_options: [context_in_system: true, minimal_turn_info: true]
  ]}
]

results = Runner.run(variants, runs: 30, tests: [20, 23])
Report.print_summary(results, variants)
```

### Console Output

```
                        baseline      repl_full
--------------------------------------------
Pass rate                 40.0%         86.7%
  95% CI           [27%, 55%]    [74%, 94%]
1st turn valid            93.3%        100.0%
Parse failure rate        0.022         0.000
Mean turns (pass)           1.8           2.3
Budget exhausted           6.7%          3.3%
Salvage rate              33.3%         80.0%

Statistical comparison (vs baseline):
  repl_full: p=0.001*
  Recommended N to detect 5pp difference: 384 per variant
```

### Agent Overrides

Overrides are per-run, not conversational state. They flow through `Agent.ask/2` into `SubAgent.new/1`:

```elixir
# These override the prompt_profile defaults for a single run
Agent.ask(query,
  prompt_profile: :repl,
  format_options: [context_in_system: true],
  completion_mode: :auto,
  max_turns: 6
)
```

## CljReplExperiment — Reference Baseline

`PtcDemo.CljReplExperiment` is an **independent research harness** that runs LLMs against a real Clojure REPL process (via `PtcDemo.CljRepl` GenServer). It does not use PTC-Lisp, SubAgent, or the demo Agent.

### Purpose

Establishes an upper bound: how well does the LLM perform when the REPL environment is fully native Clojure with real execution semantics? The gap between CljReplExperiment results and PTC-Lisp REPL results isolates the effect of the execution environment from the REPL framing.

### How It Works

1. Starts a `clj -M` process via Elixir Port
2. Loads `demo/priv/clj_prelude.clj` — defines `tool/search`, `tool/fetch`, `return`, `fail` as real Clojure functions over a hardcoded 42-document dataset
3. Runs a multi-turn conversation (max 6 turns):
   - LLM writes one Clojure expression
   - Expression executes in the real REPL
   - Output (truncated to 250 chars) feeds back as the next user message
   - Loop until `(return value)` or `(fail reason)` is called

### Usage

```elixir
# Run test #20 (hallucination resistance)
CljReplExperiment.run()

# Run specific test
CljReplExperiment.run_test(23, verbose: true)

# Run all four tests (20-23)
CljReplExperiment.run_all()
```

### Test Coverage

| Test | What it measures |
|------|-----------------|
| #20 | Hallucination resistance — must not invent document IDs |
| #21 | Cross-reference — find department with security AND compliance docs |
| #22 | Keyword filtering — find sabbatical leave policy title |
| #23 | Content comparison — which document mentions "ergonomics"? |

### Relationship to Ablation Testing

CljReplExperiment results are compared **manually** against ablation results. They share the same test numbers (20-23) but use different infrastructure:

| | CljReplExperiment | Ablation Runner |
|---|---|---|
| Execution | Real `clj` process | PTC-Lisp sandbox |
| Data | Hardcoded in Clojure prelude | `SampleData` module |
| Tools | Native Clojure functions | PTC-Lisp tool adapter |
| Metrics | Pass/fail only | Full TurnAnalysis |
| LLM API | Direct `LLMClient` call | Via SubAgent loop |

To compare fairly, run both at the same turn budget (6) with the same model.

## Experimental Design Guidelines

### Sample Size

| Detectable difference | Runs per variant |
|-----------------------|-----------------|
| 20pp | ~100 |
| 15pp | ~175 |
| 10pp | ~400 |
| 5pp | ~1500 |

### What to Measure

Pass rate alone is too noisy at practical sample sizes. Per-turn metrics give more signal:

- **First-turn validity** tells you if the framing is helping the model write valid code
- **Parse/no-code rates** reveal protocol compliance
- **Mean turns on pass** shows efficiency
- **Salvage rate** measures error recovery capability
- **Tokens/pass** (success-adjusted cost) is the most decision-relevant cost metric

### Decision Process

**Step 1: Policy benchmark** — should the default routing change?

```bash
# Run across ALL test types with natural turn budgets
mix ablation --variants=auto,smart_auto --runs=30 \
  --tests=1,2,3,4,5,6,7,8,9,10,11,12,13,20,21,22,23
```

Stop conditions for rejecting `smart_auto` as default:
- Lower pass rate beyond CI overlap on any test class
- Materially higher mean turns on single-turn tasks
- Materially higher tokens/pass

**Step 2: Mechanism benchmark** — does REPL framing itself help?

```bash
# Equal 6-turn budget, multi-turn tests only
mix ablation --variants=baseline,repl_only,repl_full --runs=30 --tests=20,21,22,23
```

This isolates whether REPL framing, feedback formatting, or context placement drive the improvement.

**Step 3: Cross-model check** — run at least one non-Gemini model early, even at smaller N, to catch obvious inversions.

### Decision Rules

| Outcome | Action |
|---------|--------|
| `smart_auto` hurts single-turn tasks | Keep REPL as opt-in |
| `smart_auto` neutral on simple, better on multi-turn | Make `smart_auto` the new `:auto` |
| Results vary by model family | Keep opt-in, document which models benefit |
| REPL bundle beats partial variants consistently | Consolidate into single mode |
| Individual knobs help independently | Keep knobs separate |
