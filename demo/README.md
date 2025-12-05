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
LLM generates program: {"op":"pipe","steps":[
  {"op":"load","name":"expenses"},
  {"op":"filter","where":{"op":"eq","field":"category","value":"travel"}},
  {"op":"sum","field":"amount"}
]}
  ↓
PtcRunner executes in sandbox (data stays in BEAM memory)
  ↓
Only result "42500" → back to LLM  ← Cheap!
  ↓
Answer: "$42,500"
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

# Optional: choose a different model
export REQ_LLM_MODEL=anthropic:claude-sonnet-4-20250514

# Install dependencies
mix deps.get

# Run the chat (default schema mode - LLM receives full schema)
mix run -e "PtcDemo.CLI.main([])"

# Run in explore mode (LLM discovers schema via introspection)
mix run -e "PtcDemo.CLI.main([\"--explore\"])"
```

## Data Modes

The demo supports two data modes that control how much schema information the LLM receives:

| Mode | Flag | Description |
|------|------|-------------|
| **Schema** (default) | none | LLM receives full schema with field names and types |
| **Explore** | `--explore` | LLM must discover schema using `typeof` and `keys` operations |

Explore mode demonstrates the introspection workflow where an LLM discovers unknown data structures through multi-turn conversation:

```
you> How many products are there?
   [Phase 1] LLM explores: load products | first | keys
   [Result] ["id", "name", "category", ...]
   [Phase 1] LLM writes query: load products | count
   [Result] 500
```

Switch modes at runtime with `/mode schema` or `/mode explore`.

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

## Commands

| Command | Description |
|---------|-------------|
| `/datasets` | List available datasets with sizes |
| `/program` | Show the last generated PTC program |
| `/result` | Show the last execution result (raw value) |
| `/context` | Show conversation history |
| `/examples` | Show example queries |
| `/stats` | Show token usage and cost statistics |
| `/mode` | Show current data mode |
| `/mode schema` | Switch to schema mode (LLM gets full schema) |
| `/mode explore` | Switch to explore mode (LLM discovers schema) |
| `/reset` | Clear conversation context, stats, and reset to schema mode |
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

## Automated Testing

Run the test suite to verify the LLM generates correct programs:

```bash
# Run all tests
mix run -e "PtcDemo.TestRunner.run_all(verbose: true)"

# Quick run (dots for progress)
mix run -e "PtcDemo.TestRunner.run_all()"

# List available test cases
mix run -e "PtcDemo.TestRunner.list()"

# Run a single test by number
mix run -e "PtcDemo.TestRunner.run_one(5)"
```

Example output:
```
=== PTC Demo Test Runner ===

1. How many products are there?
   [Phase 1] Generating PTC program...
   [Program] {"program":{"op":"pipe","steps":[{"op":"load","name":"products"},...
   [Phase 2] Executing in sandbox...
   [Result] 500 (1ms)
   ✓ Total products should be 500

==================================================
Results: 11 passed, 0 failed
==================================================
```

Tests use **constraint-based assertions** since data is randomly generated:
- `:integer` / `:number` - type checks
- `{:eq, 500}` - exact value
- `{:between, 1, 499}` - range check
- `{:gt, 0}` - greater than

## How It Works

1. **Startup**: Datasets loaded into BEAM memory (GenServer state)
2. **Query**: You ask a natural language question
3. **Generate**: LLM creates a compact PTC program (~200 bytes)
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
│  • Generates PTC program (~200 bytes)                       │
└─────────────────────────┬───────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                      PtcRunner                               │
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
```
