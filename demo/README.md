# PTC Runner Demo - Chat with Your Data

Interactive chat demo showing how PtcRunner enables efficient LLM queries over large datasets.

## Two DSL Options

This demo includes two language implementations:

| DSL | Module | Description |
|-----|--------|-------------|
| **PTC-JSON** | `PtcDemo.JsonCLI` | JSON-based DSL (stable) |
| **PTC-Lisp** | `PtcDemo.LispCLI` | Clojure-like DSL (experimental, ~3-5x more token efficient) |

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

**JSON DSL:**
```
User: "Total travel expenses?"
  ↓
LLM generates: {"op":"pipe","steps":[
  {"op":"load","name":"expenses"},
  {"op":"filter","where":{"op":"eq","field":"category","value":"travel"}},
  {"op":"sum","field":"amount"}
]}
  ↓
PtcRunner executes in sandbox → Only "42500" back to LLM
```

**Lisp DSL (more compact):**
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

# Set your OpenRouter API key (one key works with all model aliases)
export OPENROUTER_API_KEY=sk-or-v1-...

# Install dependencies
mix deps.get

# Run the Lisp chat (recommended - most token efficient)
mix lisp

# Or JSON chat
mix json
```

## Model Selection

All model aliases use OpenRouter. Set `OPENROUTER_API_KEY` once and switch freely:

```bash
# Via CLI flag
mix lisp --model=gemini        # Gemini 2.5 Flash
mix lisp --model=deepseek      # DeepSeek Chat V3
mix lisp --model=devstral      # Devstral (free)
mix lisp --model=haiku         # Claude Haiku 4.5 (default)

# Via environment variable
export PTC_DEMO_MODEL=gemini
mix lisp

# See all available aliases
mix lisp --list-models
```

**Direct provider access** (advanced - requires that provider's API key):
```bash
export ANTHROPIC_API_KEY=sk-ant-...
mix lisp --model=anthropic:claude-haiku-4.5
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

## Example Lisp Programs

The Lisp DSL generates more compact, readable programs:

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

## JSON CLI Options

```bash
mix json [options]
```

| Option | Description |
|--------|-------------|
| `--model=<name>` | Set model (alias or full model ID) |
| `--list-models` | Show available models and exit |
| `--explore` | Start in explore mode (LLM discovers schema) |
| `--test` | Run all automated tests and exit |
| `--test=<n>` | Run a single test by index (e.g., `--test=14`) |
| `--verbose`, `-v` | Verbose output (for test mode) |
| `--debug`, `-d` | Debug mode - shows full LLM responses (useful for troubleshooting) |
| `--report[=<file>]` | Generate markdown report (auto-names if no file given) |
| `--runs=<n>` | Run tests multiple times for reliability testing |

Model aliases (via OpenRouter): `haiku`, `sonnet`, `gemini`, `deepseek`, `devstral`, `kimi`, `gpt`

Examples:
```bash
mix json                                  # Interactive with default model (haiku)
mix json --list-models                    # Show available models
mix json --model=gemini                   # Use Gemini via OpenRouter
mix json --test --model=deepseek -v       # Test with DeepSeek
```

## Lisp CLI Options

```bash
mix lisp [options]
mix lisp --help        # Show all available options
```

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show all available options and examples |
| `--model=<name>` | Set model (alias or full model ID) |
| `--list-models` | Show available models and exit |
| `--prompt=<name>` | Set prompt profile (single_shot, multi_turn, or auto) |
| `--prompt=a,b` | Compare multiple prompts (e.g., `--prompt=single_shot,multi_turn`) |
| `--list-prompts` | Show available prompt profiles and exit |
| `--show-prompt` | Show system prompt and exit |
| `--explore` | Start in explore mode (LLM discovers schema) |
| `--test` | Run all automated tests and exit |
| `--test=<n>` | Run a single test by index (e.g., `--test=14`) |
| `--verbose`, `-v` | Verbose output (for test mode) |
| `--debug`, `-d` | Debug mode - shows full LLM responses (useful for troubleshooting) |
| `--report[=<file>]` | Generate markdown report (auto-names if no file given) |
| `--runs=<n>` | Run tests multiple times for reliability testing |
| `--validate-clojure` | Validate generated programs against Babashka |

Model aliases (via OpenRouter): `haiku`, `sonnet`, `gemini`, `deepseek`, `devstral`, `kimi`, `gpt`

Examples:
```bash
mix lisp                                  # Interactive with default model (haiku)
mix lisp --list-models                    # Show available models
mix lisp --model=gemini                   # Use Gemini via OpenRouter
mix lisp --prompt=single_shot             # Use single-shot prompt explicitly
mix lisp --test --model=deepseek -v       # Test with DeepSeek
mix lisp --test --validate-clojure        # Validate syntax with Babashka
mix lisp --debug                          # Debug mode to see full LLM responses
```

## Prompt Profiles

Two prompts are available, automatically selected based on test type:

| Profile | Description |
|---------|-------------|
| `:single_shot` | Base language reference - for single-turn queries |
| `:multi_turn` | Base + memory addon - for conversational analysis |
| `:auto` | Auto-select based on test type (default) |

The test runner uses `:auto` by default, selecting `:single_shot` for single-query tests and `:multi_turn` for tests with multiple queries.

```bash
# Explicit prompt selection
mix lisp --prompt=single_shot
mix lisp --prompt=multi_turn

# Compare prompt performance
mix lisp --test --prompt=single_shot,multi_turn

# See available profiles
mix lisp --list-prompts
```

### Prompt Comparison Benchmark

Compare multiple prompts in a single test run:

```bash
mix lisp --test --prompt=single_shot,multi_turn
```

Output:
```
========================================
PROMPT COMPARISON
========================================

Prompt             Pass    Rate    Tokens      Time
---------------------------------------------------
single_shot       14/15   93.3%      1200      18.2s
multi_turn        14/15   93.3%      1400      19.1s
```

Or programmatically:
```elixir
PtcDemo.LispTestRunner.run_comparison([:single_shot, :multi_turn])
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

### JSON DSL Tests

Run the JSON test suite from the command line:

```bash
# Run all tests (dots for progress)
mix json --test

# Run with verbose output
mix json --test --verbose

# Run with specific model
mix json --test --model=haiku
mix json --test --model=gemini --verbose

# Generate a markdown report
mix json --test --report=report.md
mix json --test --model=haiku --verbose --report=haiku_report.md
```

Or programmatically in IEx:

```elixir
# Run all tests
PtcDemo.JsonTestRunner.run_all()

# With options
PtcDemo.JsonTestRunner.run_all(model: "anthropic:claude-3-5-haiku-latest", verbose: true)

# Generate a report
PtcDemo.JsonTestRunner.run_all(model: "google:gemini-2.0-flash", report: "json_report.md")

# List available tests
PtcDemo.JsonTestRunner.list()

# Run a single test
PtcDemo.JsonTestRunner.run_one(3)
```

### Test Suite Structure

Both runners share a common test suite, with Lisp having additional tests for Lisp-only features:

| Level | JSON | Lisp | Description |
|-------|------|------|-------------|
| **Level 1: Basic** | 4 | 4 | Simple count, filtered count, sum, average |
| **Level 2: Intermediate** | 4 | 4 | Boolean fields, numeric comparisons, AND logic, find extremes |
| **Level 3: Advanced** | 5 | 5 | Top-N sorting, OR logic, multi-step aggregation, cross-dataset join |
| **Lisp-only** | - | 1 | group-by + map with destructuring, multiple aggregations |
| **Multi-turn** | 2 | 2 | Memory persistence between queries |
| **Total** | **15** | **16** | |

The common tests enable direct comparison. The Lisp-only test exercises advanced features (like `fn [[key items]]` destructuring) not expressible in JSON.

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
3. **Generate**: LLM creates a compact PTC program
   - JSON DSL: ~200 bytes, structured or text mode
   - Lisp DSL: ~50-100 bytes, more compact syntax
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
│  • Generates PTC program (JSON or Lisp)                     │
└─────────────────────────┬───────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│              PtcRunner.Json or PtcRunner.Lisp                │
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

## Troubleshooting

### MaxTurnsExceeded with No Programs

**Symptom:** You get `MaxTurnsExceeded: Exceeded max_turns limit of 5` but `/context` shows "No conversation yet" and no programs are visible.

**Cause:** The LLM is returning responses that don't contain valid PTC-Lisp code (e.g., prose explanations, wrong code fence format, or natural language instead of code).

**Solution:** Use `--debug` or `-d` to enable debug mode, then inspect the trace:

```bash
mix lisp --debug --prompt=multi_turn
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
