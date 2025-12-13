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

# Set your API key (pick one)
export OPENROUTER_API_KEY=sk-or-v1-...    # Recommended - many models
# OR
export ANTHROPIC_API_KEY=sk-ant-...

# Optional: choose a different model via environment variable
export PTC_DEMO_MODEL=deepseek

# Install dependencies
mix deps.get

# === See Available Models ===
mix json --list-models   # Show all available models

# === JSON DSL ===
# Run the JSON chat (default model)
mix json

# Or with options:
mix json --model=haiku              # Use Claude Haiku
mix json --model=devstral           # Use Mistral Devstral (free)
mix json --explore                  # Start in explore mode

# === Lisp DSL ===
# Run the Lisp chat (recommended - most token efficient)
mix lisp

# Lisp with specific model
mix lisp --model=haiku
mix lisp --model=openrouter:anthropic/claude-haiku-4.5

# Lisp with explore mode
mix lisp --explore
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
```

## JSON CLI Options

```bash
mix json [options]
```

| Option | Description |
|--------|-------------|
| `--model=<name>` | Set model (preset name or full model ID) |
| `--list-models` | Show available models and exit |
| `--explore` | Start in explore mode (LLM discovers schema) |
| `--test` | Run automated tests and exit |
| `--verbose`, `-v` | Verbose output (for test mode) |
| `--report[=<file>]` | Generate markdown report (auto-names if no file given) |
| `--runs=<n>` | Run tests multiple times for reliability testing |

Model presets: `haiku`, `devstral`, `gemini`, `deepseek`, `kimi`, `gpt`

Examples:
```bash
mix json                                      # Interactive with default model
mix json --list-models                        # Show available models
mix json --model=haiku                        # Use Claude Haiku
mix json --model=openrouter:anthropic/claude-haiku-4.5  # Use full model ID
mix json --test --model=gemini --verbose      # Test with Gemini
mix json --test --runs=3 --report=gemini.md   # Run 3x, save report
```

## Lisp CLI Options

```bash
mix lisp [options]
```

| Option | Description |
|--------|-------------|
| `--model=<name>` | Set model (preset name or full model ID) |
| `--list-models` | Show available models and exit |
| `--explore` | Start in explore mode (LLM discovers schema) |
| `--test` | Run automated tests and exit |
| `--verbose`, `-v` | Verbose output (for test mode) |
| `--report[=<file>]` | Generate markdown report (auto-names if no file given) |
| `--runs=<n>` | Run tests multiple times for reliability testing |
| `--validate-clojure` | Validate generated programs against Babashka |

Model presets: `haiku`, `devstral`, `gemini`, `deepseek`, `kimi`, `gpt`

Examples:
```bash
mix lisp                                      # Interactive with default model
mix lisp --list-models                        # Show available models
mix lisp --model=haiku                        # Use Claude Haiku
mix lisp --model=openrouter:anthropic/claude-haiku-4.5  # Use full model ID
mix lisp --test --model=gemini --verbose      # Test with Gemini
mix lisp --test --runs=3 --report=gemini.md   # Run 3x, save report
mix lisp --test --validate-clojure            # Validate syntax with Babashka
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

Both JSON and Lisp runners use the **same 15 test cases** for fair comparison:

| Level | Tests | Description |
|-------|-------|-------------|
| **Level 1: Basic** | 4 | Simple count, filtered count, sum, average |
| **Level 2: Intermediate** | 4 | Boolean fields, numeric comparisons, AND logic, find extremes |
| **Level 3: Advanced** | 5 | Top-N sorting, OR logic, multi-step aggregation, cross-dataset join |
| **Multi-turn** | 2 | Memory persistence between queries |

This unified test suite enables direct comparison of DSL capabilities and LLM performance.

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


