# PTC Runner Demo - Chat with Your Data

Interactive chat demo showing how PtcRunner enables efficient LLM queries over large datasets.

## The Problem with Traditional Function Calling

```
User: "Total travel expenses?"
  ↓
LLM calls get_expenses()
  ↓
800 expense records (80KB JSON) → INTO LLM CONTEXT  ← Expensive!
  ↓
LLM processes all that data
  ↓
Answer: "$42,500"
```

**Issues:** High token cost, slow, context limit problems with large data.

## The PtcRunner Solution

```
User: "Total travel expenses?"
  ↓
LLM generates: (->> ctx/expenses
                   (filter (where :category = "travel"))
                   (sum-by :amount))
  ↓
PtcRunner.Lisp executes in sandbox → Only "42500" back to LLM
```

**Benefits:**
- Data never enters LLM context (10-100x fewer tokens)
- Fast execution in BEAM
- Sandboxed with timeout/memory limits
- Same data reused across multiple queries

## Quick Start

```bash
cd demo

# Option 1: OpenRouter (one key works with all model aliases)
export OPENROUTER_API_KEY=sk-or-v1-...

# Option 2: AWS Bedrock (after `aws sso login --profile sandbox`)
eval $(aws configure export-credentials --profile sandbox --format env)

# Install dependencies
mix deps.get

# Run the interactive chat
mix lisp
```

## Model Selection

Use model aliases with explicit provider prefix:

```bash
# OpenRouter (default) - requires OPENROUTER_API_KEY
mix lisp --model=haiku              # Uses default provider (openrouter)
mix lisp --model=openrouter:haiku   # Explicit OpenRouter
mix lisp --model=openrouter:gemini  # Gemini via OpenRouter
mix lisp --model=openrouter:deepseek

# AWS Bedrock - requires AWS credentials (see Quick Start)
mix lisp --model=bedrock:haiku      # Claude 3 Haiku on Bedrock
mix lisp --model=bedrock:sonnet     # Claude 3.5 Sonnet on Bedrock

# Via environment variable
export PTC_DEMO_MODEL=bedrock:haiku
mix lisp

# See all available aliases and providers
mix lisp --list-models
```

**Note:** Both providers now use the same model generations:
| Alias | Model |
|-------|-------|
| `haiku` | Claude Haiku 4.5 |
| `sonnet` | Claude Sonnet 4 |

**Direct model IDs** (advanced):
```bash
mix lisp --model=openrouter:anthropic/claude-haiku-4.5
mix lisp --model=bedrock:anthropic.claude-3-haiku-20240307-v1:0
```

## Generation Modes

The demo supports two modes for generating PTC programs:

| Mode | Command | Tokens/call | Description |
|------|---------|-------------|-------------|
| **Text** (default) | `main([])` | ~600 | Uses `PtcRunner.Schema.to_prompt/0` with examples and retry logic |
| **Structured** | `main(["--structured"])` | ~11,000 | Uses JSON schema for guaranteed valid output |

Text mode is recommended for cost-efficiency. It uses `PtcRunner.Schema.to_prompt/0` which generates a compact description of operations (~300 tokens) instead of the full JSON schema (~10k tokens).

## Available Datasets (loaded once, kept in memory)

| Dataset   | Records | Example Fields |
|-----------|---------|----------------|
| products  | 500     | name, category, price, stock, rating, status |
| orders    | 1000    | customer_id, total, status, payment_method |
| employees | 200     | department, level, salary, bonus, remote |
| expenses  | 800     | category, amount, status, date |

The LLM knows the full schema including enum values (e.g., `payment_method: credit_card|paypal|bank_transfer|crypto`), simulating MCP tool schema discovery.

## Example Queries

**Products:**
```
How many products are in the electronics category?
What's the average price of active products?
Find products with rating above 4.5
What's the most expensive product?
```

**Orders:**
```
What's the total revenue from delivered orders?
How many orders were cancelled?
How many orders over 1000 were paid by credit_card?
```

**Employees:**
```
Total salary for the engineering department?
How many employees work remotely?
Average bonus for senior level employees?
```

**Expenses:**
```
Sum all travel expenses
How many expenses are pending approval?
Total approved expenses over $500?
```

**Cross-dataset queries:**
```
How many unique products have been ordered?
What is the total expense amount for employees in the engineering department?
How many employees have submitted expenses?
```

## Example PTC-Lisp Programs

```clojure
;; Count products in a category
(count (filter (where :category = "electronics") ctx/products))

;; Total revenue from delivered orders
(->> ctx/orders
     (filter (where :status = "delivered"))
     (sum-by :total))

;; Average salary in engineering
(avg-by :salary (filter (where :department = "engineering") ctx/employees))

;; Find most expensive product
(->> ctx/products (sort-by :price >) (first))

;; Remote employees count
(count (filter (where :remote) ctx/employees))

;; Cross-dataset: unique products ordered
(count (distinct (pluck :product_id ctx/orders)))

;; Cross-dataset: expenses for engineering employees
(let [eng-ids (pluck :id (filter (where :department = "engineering") ctx/employees))]
  (->> ctx/expenses
       (filter (fn [e] (contains? eng-ids (:employee_id e))))
       (sum-by :amount)))

;; Parallel Fetch: search then fetch full content concurrently
(let [results (ctx/search {:query "security"})
      ids (pluck :id (:results results))]
  (pmap (fn [id] (ctx/fetch {:id id})) ids))
```

## CLI Options

```bash
mix lisp [options]
mix lisp --help        # Show all available options
```

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show all available options and examples |
| `--model=<name>` | Set model (alias or full model ID) |
| `--list-models` | Show available models and exit |
| `--prompt=<name>` | Set prompt profile (single_shot, explicit_return, or auto) |
| `--prompt=a,b` | Compare multiple prompts (e.g., `--prompt=single_shot,explicit_return`) |
| `--list-prompts` | Show available prompt profiles and exit |
| `--show-prompt` | Show system prompt and exit |
| `--explore` | Start in explore mode (LLM discovers schema) |
| `--test` | Run all automated tests and exit |
| `--test=<n>` | Run a single test by index (e.g., `--test=14`) |
| `--verbose`, `-v` | Verbose output (for test mode) |
| `--debug`, `-d` | Debug mode - shows full LLM responses (useful for troubleshooting) |
| `--compaction` | Enable pressure-triggered context compaction (older turns trimmed) |
| `--filter=<type>` | Filter tests: `multi_turn`, `single_turn`, or `all` (default: all) |
| `--report[=<file>]` | Generate markdown report (auto-names if no file given) |
| `--runs=<n>` | Run tests multiple times for reliability testing |
| `--retry-turns=<n>` | Extra retry turns after must-return phase (default: 0) |
| `--validate-clojure` | Validate generated programs against Babashka |

Model aliases: `haiku`, `sonnet`, `gemini`, `deepseek`, `devstral`, `kimi`, `gpt` (use `provider:alias` syntax)

Examples:
```bash
mix lisp                                  # Interactive with default model (haiku)
mix lisp --list-models                    # Show available models
mix lisp --model=gemini                   # Use Gemini via OpenRouter
mix lisp --prompt=single_shot             # Use single-shot prompt explicitly
mix lisp --test --model=deepseek -v       # Test with DeepSeek
mix lisp --test --validate-clojure        # Validate syntax with Babashka
mix lisp --debug                          # Debug mode to see full LLM responses
mix lisp --test --filter=multi_turn --compaction   # Multi-turn tests with compaction
```

## Prompt Profiles

Prompts are composable — the language reference is included by default (use `reference: :none` to omit it for capable models):

| Profile | Description |
|---------|-------------|
| `:single_shot` | Single-shot (last expression = answer) |
| `:explicit_return` | Multi-turn + explicit return (return/fail required) |
| `:explicit_journal` | Multi-turn + explicit return + journal |

| `:auto` | Auto-select per test: `:single_shot` for max_turns=1, `:explicit_return` otherwise |

The language reference is included by default. Omit it for capable models via structured profiles:

```elixir
system_prompt: %{language_spec: {:profile, :explicit_return, reference: :none}}
```

```bash
# Explicit prompt selection
mix lisp --prompt=single_shot
mix lisp --prompt=explicit_return

# Compare prompt performance
mix lisp --test --prompt=single_shot,explicit_return

# See available profiles
mix lisp --list-prompts
```

### Prompt Comparison Benchmark

Compare multiple prompts in a single test run:

```bash
mix lisp --test --prompt=single_shot,explicit_return
```

Output:
```
========================================
PROMPT COMPARISON
========================================

Prompt             Pass    Rate    Tokens      Time
---------------------------------------------------
single_shot       14/15   93.3%      1200      18.2s
explicit_return   14/15   93.3%      1400      19.1s
```

Or programmatically:
```elixir
PtcDemo.LispTestRunner.run_comparison([:single_shot, :explicit_return])
```

## Interactive Commands

| Command | Description |
|---------|-------------|
| `/datasets` | List available datasets with sizes |
| `/program` | Show the last generated PTC program |
| `/programs` | Show all programs from this session |
| `/result` | Show last execution result (raw value) |
| `/examples` | Show example queries |
| `/stats` | Show token usage and cost statistics |
| `/mode` | Show/change data mode (schema/explore) |
| `/model` | Show/change model |
| `/prompt` | Show/change prompt profile |
| `/compaction` | Show/toggle pressure-triggered compaction (`on`/`off`) |
| `/debug` | Show/toggle debug mode (`on`/`off`) |
| `/system` | Show system prompt |
| `/context` | Show conversation history |
| `/reset` | Clear conversation context and stats |
| `/help` | Show help |
| `/quit` | Exit |

## Usage Statistics

The demo tracks token usage and costs across your session. Use `/stats` to see:

```
Session Statistics:
  Requests:      4
  Input tokens:  2,456
  Output tokens: 312
  Total tokens:  2,768
  Total cost:    $0.003421
```

This demonstrates how text mode keeps token usage low compared to structured mode.

## Automated Testing

### Lisp DSL Tests

Run the Lisp test suite from the command line:

```bash
# Run all tests (dots for progress)
mix lisp --test

# Run a single test by index
mix lisp --test=14 --verbose

# Run with verbose output
mix lisp --test --verbose

# Run with specific model
mix lisp --test --model=haiku
mix lisp --test --model=gemini --verbose

# Generate a markdown report
mix lisp --test --report=report.md
mix lisp --test --model=haiku --verbose --report=haiku_report.md
```

Or programmatically in IEx:

```elixir
# Run all tests
PtcDemo.LispTestRunner.run_all()

# With options
PtcDemo.LispTestRunner.run_all(model: "anthropic:claude-3-5-haiku-latest", verbose: true)

# Generate a report
PtcDemo.LispTestRunner.run_all(model: "google:gemini-2.0-flash", report: "gemini_report.md")

# List available tests
PtcDemo.LispTestRunner.list()

# Run a single test
PtcDemo.LispTestRunner.run_one(3)
```

Example output:
```
=== PTC-Lisp Demo Test Runner ===
Model: openrouter:anthropic/claude-3.5-haiku
Data mode: schema

[1/14] How many products are there?
   PASS: Simple count of products
   Attempts: 1
   Program: (count ctx/products)

[2/14] How many orders have status 'delivered'?
   PASS: Filter by string equality + count
   Attempts: 1
   Program: (count (filter (where :status = "delivered") ctx/orders))
...

==================================================
Results: 15/15 passed, 0 failed
Total attempts: 16 (1.1 avg per test)
Duration: 45.2s
Model: openrouter:anthropic/claude-3.5-haiku
==================================================

Token usage: 12,456 tokens, cost: $0.0042
Report written to: report.md
```

The report includes:
- Summary table with pass/fail counts, attempts, duration, and cost
- Results table showing each test's status, attempts, and final program
- Detailed section for failed tests showing all programs tried and their results
- Complete list of all programs generated during the test run

### Report Output Directory

Reports are saved to the `reports/` directory by default (git-ignored):

```bash
# Auto-generate filename: reports/lisp_deepseek_20251212-1430.md
mix lisp --test --model=deepseek --report

# Explicit filename: reports/haiku.md
mix lisp --test --report=haiku.md

# Subdirectories created automatically: reports/models/gemini.md
mix lisp --test --report=models/gemini.md

# Absolute paths are used as-is
mix lisp --test --report=/tmp/report.md
```

The auto-generated filename format is `{dsl}_{model}_{YYYYMMDD-HHMM}.md`.

### Multiple Test Runs

Use `--runs=<n>` to run the test suite multiple times for reliability testing:

```bash
# Run tests 5 times
mix lisp --test --runs=5

# With verbose output and report
mix lisp --test --runs=3 --verbose --report=stability-test.md
```

This shows aggregate statistics across all runs:
```
========================================
AGGREGATE SUMMARY (3 runs)
========================================
Total tests run: 42
Total passed:    40
Total failed:    2
Pass rate:       95.2%

Per-run results:
  Run 1: 15/15 (PASS)
  Run 2: 13/14 (FAIL)
  Run 3: 13/14 (FAIL)
```

### Ablation Testing (Variant Comparison)

Compare prompt variants with statistical analysis using `mix ablation`. This runs a controlled experiment: variant x test x N matrix with per-turn metrics and Fisher exact tests.

```bash
# Compare current default routing vs no-reference variant
mix ablation --variants=auto,explicit_no_ref --tests=1,2,3,20,23 --runs=10

# Compare mechanism variants (forced 6-turn budget)
mix ablation --variants=auto,baseline --tests=20,23 --runs=30

# With specific model and JSON export
mix ablation --variants=auto,baseline --tests=1,2,3,5,8 --runs=10 \
  --model=gemini --json
```

**Options:**

| Option | Description |
|--------|-------------|
| `--variants` | Comma-separated variant names (required) |
| `--tests` | Comma-separated test indices (required) |
| `--runs` | Runs per test per variant (default: 5) |
| `--model` | Model to use (default: from `PTC_DEMO_MODEL` env) |
| `--json` | Write JSON report to `demo/reports/` |
| `--verbose` | Show detailed output |

**Policy variants** use natural turn budgets per test (same as normal test runs):

| Name | Routing |
|------|---------|
| `auto` | Current default: `:single_shot` for max_turns=1, `:explicit_return` otherwise |

**Mechanism variants** force a 6-turn budget to isolate prompt effects:

| Name | Prompt | Notes |
|------|--------|-------|
| `baseline` | `:explicit_return` | Explicit return, 6 turns |
| `explicit` | `:explicit_return` | Explicit return, 6 turns |
**Output includes** pass rate with 95% confidence intervals, first-turn validity, parse/no-code rates, mean turns, budget exhaustion, salvage rate, token costs, and Fisher exact p-values for statistical comparison.

For detailed guidance on experimental design, sample sizes, and interpreting results, see [Benchmark Analysis](../docs/guides/benchmark-analysis.md).

### Inspecting Benchmark Traces

Every benchmark run generates `.jsonl` trace files in `traces/`. Use the trace viewer to inspect the exact system prompt, LLM conversation, generated programs, and tool calls for each test:

```bash
# Clear old traces, run a benchmark, then view
rm -f traces/*.jsonl
mix ablation --variants=auto --tests=1,20 --runs=1 --model=haiku

# From the ptc_runner root directory
mix ptc.viewer --trace-dir demo/traces
```

The viewer shows turn-by-turn details: system prompt (to verify which composed prompt was used), the LLM's response, PTC-Lisp programs with syntax highlighting, tool call arguments/results, and execution output. See [PTC Viewer](../ptc_viewer/README.md) for more.

### Clojure Validation (Lisp only)

The `--validate-clojure` flag executes generated programs in Babashka and compares results with PTC-Lisp:

```bash
# Validate with Babashka
mix lisp --test --validate-clojure
```

This does more than syntax checking - it actually runs each program in Clojure with the same dataset and verifies the results match. This helps ensure PTC-Lisp programs are fully compatible with real Clojure.

**Installing Babashka:**

Babashka must be installed from the parent `ptc_runner` directory (not `demo/`):

```bash
# From ptc_runner root
cd ..
mix ptc.install_babashka

# Or with options
mix ptc.install_babashka --force           # Reinstall
mix ptc.install_babashka --version 1.4.192 # Specific version
```

This downloads the appropriate binary for your platform (macOS/Linux) and installs it to `_build/tools/bb`.

### Test Suite Structure

30 tests organized into 5 groups, testing progressively harder interaction patterns:

**Single-shot tests (1-13)** — `max_turns: 1`, no tools, `:single_shot` prompt

These test pure data computation. The LLM writes one program against in-memory datasets (products, orders, employees, expenses). No recovery from errors.

| # | What it tests | Skill |
|---|--------------|-------|
| 1 | Count all products | Simple count |
| 2 | Count delivered orders | Filter by string equality |
| 3 | Total order revenue | Sum aggregation |
| 4 | Average product rating | Average aggregation |
| 5 | Remote employees | Boolean field filter |
| 6 | Products over $500 | Numeric comparison |
| 7 | Orders > $1000 by credit card | AND conditions |
| 8 | Cheapest product name | Find min + extract field |
| 9 | 3 most expensive products | Top-N sort + extract |
| 10 | Cancelled or refunded orders | OR conditions |
| 11 | Average senior salary | Two-step filter + aggregate |
| 12 | Unique products ordered | Distinct + count (cross-dataset) |
| 13 | Engineering dept expenses | Cross-dataset join + sum |

**Lisp-specific tests (14-15)** — `max_turns: 3`, no tools

Tests PTC-Lisp features not available in simpler DSLs (group-by with destructuring, multiple aggregations).

| # | What it tests | Skill |
|---|--------------|-------|
| 14 | Expense category stats | group-by + map destructuring |
| 15 | Employee with most rejected claims | Group, filter, find max |

**Multi-turn tool tests (16-23)** — `max_turns: 2-6`, with search/fetch tools

These test multi-turn exploration with tool calls against a 40-document policy corpus. The LLM must search, fetch, inspect output, and reason before answering.

| # | What it tests | max_turns | Skill |
|---|--------------|-----------|-------|
| 16 | Search + parallel fetch | 2 | pmap with tool calls |
| 17 | Find document covering two topics | 6 | Query refinement |
| 18 | Month with highest order growth | 4 | Temporal trend analysis |
| 19 | Budget-constrained product selection | 5 | Greedy optimization |
| 20 | Find certification reimbursement doc | 6 | Decoy resistance (must fetch to verify) |
| 21 | Department in both security & compliance | 6 | Multi-search intersection |
| 22 | Find sabbatical leave policy | 6 | Query refinement from broad results |
| 23 | Which doc mentions 'ergonomics'? | 4 | Must inspect fetched content |

**Cross-dataset verification (24)** — `max_turns: 4`, no tools

| # | What it tests | Skill |
|---|--------------|-------|
| 24 | Department with most rejected expenses | Cross-dataset join + aggregate |

**Plan-mode tests (25-30)** — `max_turns: 6-16`, with explicit plan steps

These test sequential multi-step analysis where the LLM receives an explicit plan and tracks progress via `step-done`.

| # | What it tests | max_turns | Skill |
|---|--------------|-----------|-------|
| 25 | Customer value report (tiers) | 6 | ETL pipeline: aggregate → segment → count |
| 26 | Q1 vs Q2 order comparison | 6 | Comparative period analysis |
| 27 | Remote vs office expense comparison | 6 | Cross-dataset join + group averages |
| 28 | 6-department stats | 16 | Independent sub-tasks combined |
| 29 | Top 3 categories by revenue + employees | 10 | 5-hop cross-dataset pipeline |
| 30 | Departments with high remote salaries | 10 | Threshold search with early exit |

**Summary:**

| Group | Tests | max_turns | Tools | Prompt |
|-------|-------|-----------|-------|--------|
| Single-shot | 1-13 | 1 | No | `:single_shot` |
| Lisp-specific | 14-15 | 3 | No | `:explicit_return` |
| Multi-turn tool | 16-23 | 2-6 | Yes | `:explicit_return` |
| Cross-dataset | 24 | 4 | No | `:explicit_return` |
| Plan-mode | 25-30 | 6-16 | No | `:explicit_journal` |

### Test Runner Internals

Understanding how the test runner works helps when debugging failures:

**Key files:**
- `lib/ptc_demo/lisp_test_runner.ex` - Main test execution logic
- `lib/ptc_demo/agent.ex` - GenServer wrapper around SubAgent
- `lib/ptc_demo/test_runner/test_case.ex` - Test definitions
- `lib/ptc_demo/test_runner/base.ex` - Validation logic

**Single-turn test flow:**
1. `agent_mod.reset()` clears memory and history
2. `agent_mod.ask(query)` calls `SubAgent.run/2` with default `max_turns: 5`
3. LLM generates PTC-Lisp, executed via `Lisp.run/2`
4. Result validated against `expect` type and `constraint`

**Multi-turn test flow:**
1. `agent_mod.reset()` clears state before the test
2. For each query in `queries` list:
   - `agent_mod.ask(query, max_turns: 1)` - single turn per query
   - Memory persists between queries (no reset)
   - `agent_mod.programs()` accumulates all programs across queries
3. Final result validated after last query

**Memory persistence in multi-turn:**
- `agent.ex` line 199: `context = Map.merge(datasets, %{"memory" => state.memory})`
- `agent.ex` line 232: `memory: step.memory` - updated from SubAgent result
- Memory flows: Agent state → SubAgent context → Lisp execution → Step.memory → Agent state

**Common debugging tips:**
- Check if memory was actually stored (map return vs non-map)
- Check if `ctx/memory` is `%{}` vs `nil` (empty map is truthy, not nil)
- Use `--verbose` or `-v` to see all programs and their results
- Multi-turn "All programs tried" shows programs from ALL queries combined

### Test Assertions

Tests use **constraint-based assertions** since data is randomly generated:
- `:integer` / `:number` / `:string` / `:list` - type checks
- `{:eq, 500}` - exact value
- `{:between, 1, 499}` - range check
- `{:gt, 0}` - greater than
- `{:length, 3}` - list length
- `{:starts_with, "Product"}` - string prefix

## How It Works

1. **Startup**: Datasets loaded into BEAM memory (GenServer state)
2. **Query**: You ask a natural language question
3. **Generate**: LLM creates a compact PTC-Lisp program (~50-100 bytes)
4. **Execute**: PtcRunner runs program in sandbox against in-memory data
5. **Respond**: Only small result returns to LLM for natural language answer

The key insight: **2500 records stay in BEAM memory, never touching LLM context.**

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        User Question                         │
└─────────────────────────┬───────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    LLM (via ReqLLM)                          │
│  • Receives question + schema (not data!)                   │
│  • Generates PTC-Lisp program                                │
└─────────────────────────┬───────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                      PtcRunner.Lisp                          │
│  • Executes program in sandboxed BEAM process               │
│  • Processes 2500 records in memory                         │
│  • Returns small result (number, filtered list, etc.)       │
└─────────────────────────┬───────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    LLM (via ReqLLM)                          │
│  • Receives small result                                    │
│  • Generates natural language answer                        │
└─────────────────────────────────────────────────────────────┘

## Tracing & Performance Analysis

Trace files are created automatically for every query, saved to the `traces/` directory (git-ignored) as `.jsonl` files. View traces with the interactive viewer:

```bash
# From the ptc_runner root
mix ptc.viewer
```

Each trace captures run timing, per-turn timing with token counts, and LLM API call latency.

## Troubleshooting

### MaxTurnsExceeded with No Programs

**Symptom:** You get `MaxTurnsExceeded: Exceeded max_turns limit of 5` but `/context` shows "No conversation yet" and no programs are visible.

**Cause:** The LLM is returning responses that don't contain valid PTC-Lisp code (e.g., prose explanations, wrong code fence format, or natural language instead of code).

**Solution:** Use `--debug` or `-d` to enable debug mode, then inspect the trace:

```bash
mix lisp --debug --prompt=explicit_return
```

After an error, use `SubAgent.Debug.print_trace(step, raw: true)` to see:
- The full LLM response (before code extraction)
- What feedback was sent back to the LLM
- How truncation affected the data

This reveals why the code parser failed and helps diagnose whether:
- The LLM is confused about the task
- The system prompt isn't being sent correctly
- The model doesn't support the code format

See [SubAgent Troubleshooting](../docs/guides/subagent-troubleshooting.md) for more debugging tips.
