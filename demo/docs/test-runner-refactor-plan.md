# Test Runner Refactoring Plan

## Goal

Create a unified, DRY test runner architecture that:
1. Adds `mix json --test --report=report.md` command (parity with `mix lisp`)
2. Shares common logic between JSON and Lisp test runners
3. Supports multi-turn tests for both DSLs
4. Maintains flexibility for DSL-specific behavior

## Current State Analysis

### What Exists

| Component | JSON | Lisp |
|-----------|------|------|
| Agent | `Agent` (575 lines) | `LispAgent` (699 lines) |
| Test Runner | `TestRunner` (256 lines) | `LispTestRunner` (841 lines) |
| CLI | None | `LispCLI` (514 lines) |
| Mix Alias | None | `mix lisp` |

### Duplication Between Runners

The following code is duplicated or nearly identical:

1. **Constraint validation** - `check_type/2`, `check_constraint/2`
2. **Result formatting** - `format_duration/1`, `format_cost/1`, `truncate/2`
3. **Report generation** - `write_report/2`, `generate_report/1`, table generation
4. **CLI argument parsing** - model resolution, dotenv loading, API key validation
5. **Test execution flow** - run_all/run_one patterns, verbose output
6. **Test case structure** - same map format with query/expect/constraint/description

### Key Differences

| Aspect | JSON | Lisp |
|--------|------|------|
| Program extraction | `extract_ptc_program/1` looks for `{"program":...}` | Looks for `(...)` S-expressions |
| Memory support | None | Yes (`memory` field in state) |
| Error formatting | `PtcRunner.Json.format_error/1` | Custom `format_lisp_error/1` |
| Agent name | `PtcDemo.Agent` | `PtcDemo.LispAgent` |

## Proposed Architecture

### New Module Structure

```
demo/lib/ptc_demo/
├── test_runner/
│   ├── base.ex           # Shared logic (NEW)
│   ├── test_case.ex      # Test case definitions (NEW)
│   └── report.ex         # Report generation (NEW)
├── json_test_runner.ex   # JSON-specific runner (ENHANCED)
├── lisp_test_runner.ex   # Lisp-specific runner (REFACTORED)
├── json_cli.ex           # JSON CLI entry point (NEW)
├── lisp_cli.ex           # Existing, minor refactor
└── cli_base.ex           # Shared CLI utilities (NEW)
```

### Module Responsibilities

#### 1. `PtcDemo.TestRunner.Base`

Shared test execution logic:

```elixir
defmodule PtcDemo.TestRunner.Base do
  @moduledoc """
  Shared test runner functionality for both JSON and Lisp DSLs.
  """

  # Constraint checking
  def check_type(value, :integer), do: is_integer(value)
  def check_type(value, :number), do: is_number(value)
  def check_type(value, :list), do: is_list(value)
  def check_type(value, :string), do: is_binary(value)
  def check_type(value, :map), do: is_map(value)
  def check_type(_value, _), do: true

  def check_constraint(value, {:eq, expected})
  def check_constraint(value, {:gt, min})
  def check_constraint(value, {:gte, min})
  def check_constraint(value, {:lt, max})
  def check_constraint(value, {:between, min, max})
  def check_constraint(value, {:length, expected}) when is_list(value)
  def check_constraint(value, {:starts_with, prefix}) when is_binary(value)
  def check_constraint(_value, _), do: true

  # Formatting helpers
  def format_cost(cost)
  def format_duration(ms)
  def truncate(str, max_len)
  def format_attempt_result(result)
  def type_of(value)

  # Validation
  def validate_result(value, test_case)

  # Summary building
  def build_summary(results, start_time, model, data_mode, stats)
  def print_summary(summary)
  def print_failed_tests(results)
end
```

#### 2. `PtcDemo.TestRunner.TestCase`

Shared test case definitions:

```elixir
defmodule PtcDemo.TestRunner.TestCase do
  @moduledoc """
  Shared test case definitions for both JSON and Lisp runners.
  """

  @doc """
  Base test cases that work with both DSLs.
  """
  def common_test_cases do
    [
      # Simple counts
      %{
        query: "How many products are there?",
        expect: :integer,
        constraint: {:eq, 500},
        description: "Total products should be 500"
      },
      %{
        query: "How many orders are there?",
        expect: :integer,
        constraint: {:eq, 1000},
        description: "Total orders should be 1000"
      },
      # ... more shared cases
    ]
  end

  @doc """
  Test cases specific to Lisp DSL (sort-by with comparators, etc.)
  """
  def lisp_specific_cases do
    [
      %{
        query: "Find the most expensive product and return its name",
        expect: :string,
        constraint: {:starts_with, "Product"},
        description: "Most expensive product name should start with 'Product'"
      },
      # ... lisp-specific cases
    ]
  end

  @doc """
  Multi-turn test cases (memory persistence).
  """
  def multi_turn_cases do
    [
      %{
        queries: [
          "Count delivered orders and store the result in memory as delivered-count",
          "What percentage of all orders are delivered? Use memory/delivered-count..."
        ],
        expect: :number,
        constraint: {:between, 1, 99},
        description: "Multi-turn: percentage calculation using stored count"
      },
      # ... more multi-turn cases
    ]
  end
end
```

#### 3. `PtcDemo.TestRunner.Report`

Report generation:

```elixir
defmodule PtcDemo.TestRunner.Report do
  @moduledoc """
  Markdown report generation for test runs.
  """

  def write_report(path, summary, dsl_name)
  def generate_report(summary, dsl_name)
  def generate_results_table(results)
  def generate_failed_details(results)
  def generate_all_programs_section(results)
  def format_timestamp(dt)
end
```

#### 4. `PtcDemo.CLIBase`

Shared CLI utilities:

```elixir
defmodule PtcDemo.CLIBase do
  @moduledoc """
  Shared CLI utilities for JSON and Lisp entry points.
  """

  def load_dotenv()
  def ensure_api_key!()
  def parse_common_args(args)
  def resolve_model(name, presets)
  def format_stats(stats)
  def format_number(n)
  def format_cost(cost)
end
```

#### 5. `PtcDemo.JsonTestRunner` (enhanced)

```elixir
defmodule PtcDemo.JsonTestRunner do
  @moduledoc """
  Test runner for PTC-JSON DSL.
  """

  alias PtcDemo.TestRunner.{Base, TestCase, Report}
  alias PtcDemo.Agent

  def run_all(opts \\ [])
  def run_one(index, opts \\ [])
  def list()

  # Private: DSL-specific test execution
  defp run_single_turn_test(test_case, index, total, verbose)
  defp run_multi_turn_test(test_case, queries, index, total, verbose)

  # Test cases: common + JSON-specific (if any)
  defp test_cases do
    TestCase.common_test_cases() ++
    TestCase.multi_turn_cases()  # JSON now supports multi-turn
  end
end
```

#### 6. `PtcDemo.JsonCLI` (new)

```elixir
defmodule PtcDemo.JsonCLI do
  @moduledoc """
  Interactive CLI for the PTC-JSON Demo.
  """

  def main(args)
  # Similar structure to LispCLI but uses Agent instead of LispAgent
end
```

### Agent Changes

The `PtcDemo.Agent` (JSON) needs to support memory for multi-turn tests:

1. Add `:memory` field to struct (map of name → value)
2. Update `agent_loop/7` to pass and return memory
3. After successful program execution, check for "store" instruction or detect variable assignment
4. Inject memory values into the context passed to `PtcRunner.Json.run`:
   ```elixir
   # Merge memory into datasets context
   context_with_memory = Map.merge(datasets, memory)
   PtcRunner.Json.run(program_json, context: context_with_memory, ...)
   ```
5. Update system prompt to document memory convention:
   - Store: use a query that mentions "store as X" → agent extracts and stores result
   - Retrieve: use `{"op": "load", "name": "memory_X"}` to access stored value

**Implementation approach**: The agent will parse LLM responses for "store as {name}" patterns and maintain a memory map. Stored values are injected as context variables with `memory_` prefix.

## Implementation Plan

### Phase 1: Extract Shared Module

1. Create `lib/ptc_demo/test_runner/base.ex`
   - Move constraint checking functions
   - Move formatting helpers
   - Move validation logic
   - Move summary building

2. Create `lib/ptc_demo/test_runner/report.ex`
   - Move report generation from LispTestRunner
   - Parameterize DSL name in report title

3. Create `lib/ptc_demo/test_runner/test_case.ex`
   - Define common test cases
   - Define DSL-specific test cases
   - Define multi-turn test cases

### Phase 2: Refactor LispTestRunner

1. Update `LispTestRunner` to use shared modules
2. Keep Lisp-specific logic:
   - Agent interaction (LispAgent)
   - Test case selection (common + lisp-specific + multi-turn)
3. Verify all tests still pass

### Phase 3: Enhance JsonTestRunner

1. Rename existing `TestRunner` to `JsonTestRunner`
2. Add multi-turn test support
3. Add report generation
4. Add attempt tracking
5. Add token/cost stats
6. Add CLI options (model, data_mode, report)
7. Use shared modules

### Phase 4: Add Memory to JSON Agent

1. Add `:memory` field to Agent struct
2. Implement memory persistence across queries
3. Option A: If PtcRunner.Json supports context memory, use it
4. Option B: Store results in agent state and inject into context

### Phase 5: Create CLI Modules

1. Create `lib/ptc_demo/cli_base.ex`
   - Extract shared CLI utilities from LispCLI

2. Create `lib/ptc_demo/json_cli.ex`
   - Similar structure to LispCLI
   - Uses Agent instead of LispAgent

3. Refactor `LispCLI` to use CLIBase

4. Add mix alias in `mix.exs`:
   ```elixir
   aliases: [
     json: "run --no-halt -e \"PtcDemo.JsonCLI.main(System.argv())\" --",
     lisp: "run --no-halt -e \"PtcDemo.LispCLI.main(System.argv())\" --"
   ]
   ```

### Phase 6: Testing & Documentation

1. Test both CLIs:
   - `mix json --test`
   - `mix json --test --verbose`
   - `mix json --test --report=json-report.md`
   - `mix lisp --test --report=lisp-report.md`

2. Compare reports side-by-side

3. Update demo README with new commands

## Test Case Organization

### Common Test Cases (both DSLs)

| Category | Count | Description |
|----------|-------|-------------|
| Simple counts | 4 | Total products, orders, employees, expenses |
| Filtered counts | 4 | By category, status, remote, pending |
| Aggregations | 3 | Total revenue, avg salary, avg price |
| Combined filters | 2 | Multi-condition queries |
| Expenses | 1 | Travel expense sum |
| Cross-dataset | 3 | Distinct, joins, correlations |

### Lisp-Specific Cases

| Category | Count | Description |
|----------|-------|-------------|
| Sort operations | 2 | sort-by with comparators (>, <) |

### Multi-Turn Cases (both DSLs)

| Category | Count | Description |
|----------|-------|-------------|
| Memory persistence | 2 | Store and retrieve across queries |

**Total**: ~19 common + 2 lisp-specific + 2 multi-turn = ~21-23 tests

## File Changes Summary

| File | Action |
|------|--------|
| `lib/ptc_demo/test_runner/base.ex` | CREATE |
| `lib/ptc_demo/test_runner/test_case.ex` | CREATE |
| `lib/ptc_demo/test_runner/report.ex` | CREATE |
| `lib/ptc_demo/cli_base.ex` | CREATE |
| `lib/ptc_demo/json_cli.ex` | CREATE |
| `lib/ptc_demo/json_test_runner.ex` | CREATE (new, replaces test_runner.ex) |
| `lib/ptc_demo/test_runner.ex` | DELETE |
| `lib/ptc_demo/lisp_test_runner.ex` | MODIFY (use shared modules) |
| `lib/ptc_demo/lisp_cli.ex` | MODIFY (use CLIBase) |
| `lib/ptc_demo/agent.ex` | MODIFY (add memory support) |
| `mix.exs` | MODIFY (add json alias) |

## Open Questions

1. **~~PtcRunner.Json memory support~~**: **RESOLVED** - JSON DSL does NOT support memory operations. The JSON DSL has `let` for local bindings but no persistent memory across program executions.

   **Decision**: Option B - Implement agent-level memory. Store results in Agent state and inject into context as variables (e.g., `memory_delivered_count`). The LLM can then use `{"op": "load", "name": "memory_delivered_count"}` to access stored values.

2. **Test case naming**: Should multi-turn tests have a `:multi_turn` key or use presence of `:queries` list to detect?
   - **Recommendation**: Use presence of `:queries` key (current approach in LispTestRunner)

3. **~~Backward compatibility~~**: **RESOLVED** - No backward compatibility. Delete `TestRunner` and use clear names: `JsonTestRunner` and `LispTestRunner`. Simpler design, no aliases or delegates.

## Testing Strategy

### Current State

- **No demo test folder** - `demo/test/` doesn't exist
- **No mocking library** - Project doesn't use Mox
- **ReqLLM fixture system** - Supports record/replay but designed for provider testing, not application-level mocking
- **E2E tests in main project** - Use real API calls, tagged with `:e2e` and excluded by default

### Proposed Testing Approach

Since the test runners orchestrate LLM → program generation → execution, we need to test at multiple levels:

#### Level 1: Unit Tests (No LLM, No Mocking)

Test the shared modules in isolation without any LLM calls:

```
demo/test/
├── test_helper.exs
├── ptc_demo/
│   └── test_runner/
│       ├── base_test.exs      # Constraint checking, formatting
│       ├── report_test.exs    # Report generation
│       └── test_case_test.exs # Test case definitions
```

**What to test:**
- `Base.check_type/2` - all type checks
- `Base.check_constraint/2` - all constraint types (eq, gt, between, etc.)
- `Base.validate_result/2` - combined validation
- `Base.format_duration/1`, `format_cost/1`, `truncate/2` - formatting
- `Report.generate_report/2` - given a summary map, verify markdown output
- `TestCase.common_test_cases/0` - verify structure and count

**Example test:**

```elixir
defmodule PtcDemo.TestRunner.BaseTest do
  use ExUnit.Case, async: true

  alias PtcDemo.TestRunner.Base

  describe "check_constraint/2" do
    test "eq constraint passes on exact match" do
      assert Base.check_constraint(500, {:eq, 500}) == true
    end

    test "eq constraint returns error message on mismatch" do
      assert Base.check_constraint(499, {:eq, 500}) == "Expected 500, got 499"
    end

    test "between constraint passes when in range" do
      assert Base.check_constraint(50, {:between, 1, 100}) == true
    end

    test "between constraint returns error when out of range" do
      assert Base.check_constraint(101, {:between, 1, 100}) ==
               "Expected between 1-100, got 101"
    end
  end

  describe "check_type/2" do
    test "integer type" do
      assert Base.check_type(42, :integer) == true
      assert Base.check_type(42.0, :integer) == false
    end

    test "number type accepts integers and floats" do
      assert Base.check_type(42, :number) == true
      assert Base.check_type(42.5, :number) == true
    end
  end
end
```

#### Level 2: Integration Tests with Mock Agent

Create a mock agent that returns predetermined responses:

```elixir
defmodule PtcDemo.MockAgent do
  @moduledoc """
  Mock agent for testing test runners without real LLM calls.
  """
  use GenServer

  defstruct [:responses, :call_count, :last_result, :last_program]

  def start_link(responses) do
    GenServer.start_link(__MODULE__, responses, name: __MODULE__)
  end

  def ask(question) do
    GenServer.call(__MODULE__, {:ask, question})
  end

  def last_result, do: GenServer.call(__MODULE__, :last_result)
  def last_program, do: GenServer.call(__MODULE__, :last_program)
  def programs, do: GenServer.call(__MODULE__, :programs)
  def reset, do: GenServer.call(__MODULE__, :reset)
  def stats, do: %{total_tokens: 0, total_cost: 0.0, requests: 0}
  def model, do: "mock:test-model"
  def data_mode, do: :schema
  def set_data_mode(_), do: :ok
  def set_model(_), do: :ok

  # GenServer callbacks...
end
```

**Usage in tests:**

```elixir
defmodule PtcDemo.JsonTestRunnerTest do
  use ExUnit.Case

  alias PtcDemo.{JsonTestRunner, MockAgent}

  setup do
    # Define mock responses for each test query
    responses = %{
      "How many products are there?" => {:ok, "There are 500 products.", 500},
      "How many orders are there?" => {:ok, "There are 1000 orders.", 1000}
    }

    {:ok, _pid} = MockAgent.start_link(responses)
    on_exit(fn -> GenServer.stop(MockAgent) end)
    :ok
  end

  test "run_all passes when all constraints are met" do
    # JsonTestRunner would need to accept an :agent option
    result = JsonTestRunner.run_all(agent: MockAgent)

    assert result.passed == result.total
    assert result.failed == 0
  end
end
```

#### Level 3: E2E Tests (Real LLM, Tagged)

Keep real LLM tests but tag them for optional execution:

```elixir
defmodule PtcDemo.JsonTestRunner.E2ETest do
  use ExUnit.Case

  @moduletag :e2e
  @moduletag timeout: 120_000

  test "full test run with real LLM" do
    result = PtcDemo.JsonTestRunner.run_all(model: "openrouter:anthropic/claude-haiku-4.5")

    # Lenient assertions for LLM variability
    assert result.passed >= result.total * 0.8  # At least 80% pass
    assert result.total == 19  # Expected test count
  end
end
```

### Implementation: Agent Injection

To enable mock testing, modify runners to accept an optional `:agent` module:

```elixir
def run_all(opts \\ []) do
  agent = Keyword.get(opts, :agent, PtcDemo.Agent)  # Default to real agent

  # Use agent module throughout
  agent.reset()
  agent.set_data_mode(data_mode)
  # ...
  case agent.ask(query) do
    {:ok, answer} -> ...
  end
end
```

### Test Configuration

**demo/mix.exs additions:**

```elixir
def project do
  [
    # ... existing config
    elixirc_paths: elixirc_paths(Mix.env())
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

**demo/test/test_helper.exs:**

```elixir
ExUnit.start(exclude: [:e2e])
```

### Files to Create

| File | Purpose |
|------|---------|
| `demo/test/test_helper.exs` | ExUnit config, exclude :e2e |
| `demo/test/support/mock_agent.ex` | Mock agent for testing |
| `demo/test/ptc_demo/test_runner/base_test.exs` | Unit tests for Base |
| `demo/test/ptc_demo/test_runner/report_test.exs` | Unit tests for Report |
| `demo/test/ptc_demo/json_test_runner_test.exs` | Integration tests with mock |
| `demo/test/ptc_demo/lisp_test_runner_test.exs` | Integration tests with mock |

### Running Tests

```bash
cd demo

# Run unit tests (fast, no API calls)
mix test

# Run with E2E tests (requires API key)
mix test --include e2e

# Run specific test file
mix test test/ptc_demo/test_runner/base_test.exs
```

## Out of Scope

The following are explicitly NOT part of this refactor:

1. **Changes to PtcRunner library** - No modifications to `lib/ptc_runner/` (the core library)
2. **New DSL operations** - Not adding memory operations to PTC-JSON DSL
3. **Performance optimization** - Focus is on structure, not speed
4. **New test cases** - Using existing test cases, just reorganizing them
5. **CLI feature parity with REPL** - CLI is for `--test` mode, not full interactive REPL
6. **Renaming Agent to JsonAgent** - Keep `Agent` name for JSON (established pattern)

## Task Breakdown (Epic-Ready)

Tasks are sized for single PRs (100-500 lines). Dependencies shown with →.

### Phase 1: Shared Infrastructure (no breaking changes)

| # | Task | Est. Lines | Depends On | E2E Validation |
|---|------|------------|------------|----------------|
| 1.1 | Create `TestRunner.Base` with constraint/formatting functions | ~150 | None | Unit tests pass |
| 1.2 | Create `TestRunner.Report` with markdown generation | ~120 | None | Unit tests pass |
| 1.3 | Create `TestRunner.TestCase` with shared test definitions | ~100 | None | Unit tests pass |
| 1.4 | Create `CLIBase` with shared CLI utilities | ~80 | None | Unit tests pass |
| 1.5 | Set up demo test infrastructure (test_helper, mock_agent) | ~100 | None | `mix test` runs |

### Phase 2: Refactor Existing (maintain functionality)

| # | Task | Est. Lines | Depends On | E2E Validation |
|---|------|------------|------------|----------------|
| 2.1 | Refactor `LispTestRunner` to use shared modules | ~200 | 1.1, 1.2, 1.3 | `mix lisp --test` unchanged |
| 2.2 | Refactor `LispCLI` to use `CLIBase` | ~100 | 1.4 | `mix lisp` unchanged |
| 2.3 | Add unit tests for shared modules | ~200 | 1.5, 2.1 | `mix test` all pass |

### Phase 3: JSON Parity (new functionality)

| # | Task | Est. Lines | Depends On | E2E Validation |
|---|------|------------|------------|----------------|
| 3.1 | Create `JsonTestRunner` using shared modules | ~250 | 2.1 | `mix json --test` works |
| 3.2 | Create `JsonCLI` with test mode support | ~150 | 2.2 | `mix json --test --report=r.md` works |
| 3.3 | Delete old `TestRunner`, add mix alias | ~20 | 3.1, 3.2 | Both CLIs work |

### Phase 4: Multi-turn Support (enhancement)

| # | Task | Est. Lines | Depends On | E2E Validation |
|---|------|------------|------------|----------------|
| 4.1 | Add memory support to JSON `Agent` | ~100 | 3.1 | Agent stores/retrieves values |
| 4.2 | Add multi-turn test cases to `JsonTestRunner` | ~50 | 4.1 | Multi-turn tests pass |
| 4.3 | Integration tests with MockAgent | ~150 | 1.5, 3.1 | `mix test` all pass |

### Phase 5: Documentation

| # | Task | Est. Lines | Depends On | E2E Validation |
|---|------|------------|------------|----------------|
| 5.1 | Update demo README with new commands | ~50 | 3.3 | README accurate |

## Success Criteria

1. `mix json --test` runs all JSON tests with same output format as `mix lisp --test`
2. `mix json --test --report=report.md` generates comparable markdown report
3. Both runners share >80% of validation/formatting code
4. No regression in existing `mix lisp --test` functionality
5. Multi-turn tests pass for both DSLs
6. Unit tests pass without any API calls
7. Integration tests work with mock agent

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| LispTestRunner refactor breaks existing tests | High | Phase 2 maintains exact behavior, E2E validation after each task |
| Mock agent doesn't match real agent API | Medium | Define clear agent interface, test with both |
| JSON multi-turn memory is unreliable | Medium | Can ship without multi-turn if problematic (out of scope fallback) |

## Definition of Done

Each task is complete when:
- [ ] Code compiles without warnings
- [ ] Unit tests pass (`mix test`)
- [ ] E2E validation passes (as specified in task)
- [ ] No regression in existing functionality
- [ ] Code follows project style (run `mix format`)
