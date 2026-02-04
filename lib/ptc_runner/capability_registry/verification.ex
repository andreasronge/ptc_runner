defmodule PtcRunner.CapabilityRegistry.Verification do
  @moduledoc """
  Tool verification and health management.

  Provides functions to run test suites against tools, perform pre-flight
  checks, and manage tool health states.

  ## Verification Flow

  1. **Pre-flight** - Run smoke tests before linking
  2. **Full suite** - Run all tests for registration
  3. **Regression** - Verify repaired tools pass all historical tests

  ## Health States

  - `:pending` - Never tested
  - `:green` - All tests pass
  - `:red` - Tests failing (quarantined)
  - `:flaky` - Intermittent failures

  """

  alias PtcRunner.CapabilityRegistry.{Registry, TestSuite, ToolEntry}

  require Logger

  @type run_result :: %{
          status: :pass | :fail | :error,
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [term()],
          duration_ms: non_neg_integer()
        }

  @doc """
  Runs a full test suite against a tool.

  Returns detailed results for all test cases.
  """
  @spec run_test_suite(Registry.t(), String.t()) :: {:ok, run_result()} | {:error, term()}
  def run_test_suite(registry, tool_id) do
    with {:ok, tool} <- fetch_tool(registry, tool_id),
         {:ok, suite} <- fetch_suite(registry, tool_id) do
      run_cases(tool, suite.cases)
    end
  end

  @doc """
  Runs smoke tests (pre-flight check) for a tool.

  Returns quickly - only runs tests tagged with :smoke.
  Limited to first 3 smoke tests for speed.
  """
  @spec run_smoke_tests(Registry.t(), String.t(), keyword()) ::
          {:ok, run_result()} | {:error, term()}
  def run_smoke_tests(registry, tool_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)

    with {:ok, tool} <- fetch_tool(registry, tool_id),
         {:ok, suite} <- fetch_suite(registry, tool_id) do
      smoke = suite |> TestSuite.smoke_cases() |> Enum.take(limit)

      if smoke == [] do
        {:ok, %{status: :pass, passed: 0, failed: 0, errors: [], duration_ms: 0}}
      else
        run_cases(tool, smoke)
      end
    end
  end

  @doc """
  Performs pre-flight check and updates health status.

  Returns `:ok` if smoke tests pass, or `{:error, failures}` if they fail.
  Updates the registry health status accordingly.
  """
  @spec preflight_check(Registry.t(), String.t()) :: {:ok, Registry.t()} | {:error, term()}
  def preflight_check(registry, tool_id) do
    case run_smoke_tests(registry, tool_id) do
      {:ok, %{status: :pass}} ->
        {:ok, Registry.mark_healthy(registry, tool_id)}

      {:ok, %{status: :fail} = result} ->
        _registry = Registry.mark_unhealthy(registry, tool_id)
        {:error, {:preflight_failed, result}}

      {:error, :suite_not_found} ->
        # No test suite - can't verify, keep pending
        {:ok, registry}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Registers a tool only if its test suite passes.

  For new tools, runs the provided test suite.
  """
  @spec register_with_verification(Registry.t(), ToolEntry.t(), TestSuite.t()) ::
          {:ok, Registry.t()} | {:error, term()}
  def register_with_verification(registry, tool, suite) do
    case run_cases(tool, suite.cases) do
      {:ok, %{status: :pass}} ->
        registry =
          registry
          |> Registry.register_tool(tool)
          |> put_suite(tool.id, TestSuite.record_run(suite, :green))
          |> Registry.mark_healthy(tool.id)

        {:ok, registry}

      {:ok, %{status: :fail} = result} ->
        {:error, {:tests_failed, result}}
    end
  end

  @doc """
  Registers a repair tool that must pass all historical tests.

  Inherits tests from the superseded tool and merges with new tests.
  This prevents regressions when repairing tools.
  """
  @spec register_repair(Registry.t(), ToolEntry.t(), [map()]) ::
          {:ok, Registry.t()} | {:error, term()}
  def register_repair(registry, repaired_tool, new_test_cases) do
    old_id = repaired_tool.supersedes

    if old_id == nil do
      {:error, :no_supersedes_specified}
    else
      # Get historical test suite
      historical_suite =
        case Map.fetch(registry.test_suites, old_id) do
          {:ok, suite} -> suite
          :error -> TestSuite.new(repaired_tool.id)
        end

      # Create new suite inheriting from historical
      new_suite =
        TestSuite.new(repaired_tool.id, inherited_from: old_id)

      # Add new test cases
      new_suite =
        Enum.reduce(new_test_cases, new_suite, fn tc, acc ->
          TestSuite.add_case(acc, tc.input, tc.expected, tags: tc[:tags] || [])
        end)

      # Merge historical + new
      full_suite = TestSuite.merge(historical_suite, new_suite)

      # Run all tests
      case run_cases(repaired_tool, full_suite.cases) do
        {:ok, %{status: :pass}} ->
          # All pass - register and update health
          registry =
            registry
            |> Registry.register_tool(repaired_tool)
            |> put_suite(repaired_tool.id, TestSuite.record_run(full_suite, :green))
            |> Registry.mark_healthy(repaired_tool.id)
            # Flag skills that applied to the old tool
            |> Registry.flag_skills_for_tool(old_id, "tool_repaired: #{repaired_tool.id}")

          {:ok, registry}

        {:ok, %{status: :fail, errors: errors}} ->
          {:error, {:regressions_detected, errors}}
      end
    end
  end

  @doc """
  Adds a test case to a tool's suite.
  """
  @spec add_test_case(Registry.t(), String.t(), map(), term(), keyword()) :: Registry.t()
  def add_test_case(registry, tool_id, input, expected, opts \\ []) do
    suite =
      case Map.fetch(registry.test_suites, tool_id) do
        {:ok, existing} -> existing
        :error -> TestSuite.new(tool_id)
      end

    updated = TestSuite.add_case(suite, input, expected, opts)
    put_suite(registry, tool_id, updated)
  end

  @doc """
  Records a production failure as a regression test.
  """
  @spec record_failure_as_test(Registry.t(), String.t(), map(), String.t()) :: Registry.t()
  def record_failure_as_test(registry, tool_id, failure_input, diagnosis) do
    suite =
      case Map.fetch(registry.test_suites, tool_id) do
        {:ok, existing} -> existing
        :error -> TestSuite.new(tool_id)
      end

    updated = TestSuite.add_regression(suite, failure_input, diagnosis)
    put_suite(registry, tool_id, updated)
  end

  @doc """
  Gets the test suite for a tool.
  """
  @spec get_suite(Registry.t(), String.t()) :: TestSuite.t() | nil
  def get_suite(registry, tool_id) do
    Map.get(registry.test_suites, tool_id)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp fetch_tool(registry, tool_id) do
    case Registry.get_tool(registry, tool_id) do
      nil -> {:error, :tool_not_found}
      tool -> {:ok, tool}
    end
  end

  defp fetch_suite(registry, tool_id) do
    case Map.fetch(registry.test_suites, tool_id) do
      {:ok, suite} -> {:ok, suite}
      :error -> {:error, :suite_not_found}
    end
  end

  defp put_suite(registry, tool_id, suite) do
    %{registry | test_suites: Map.put(registry.test_suites, tool_id, suite)}
  end

  defp run_cases(tool, cases) when is_list(cases) do
    start_time = System.monotonic_time(:millisecond)

    results =
      Enum.map(cases, fn test_case ->
        run_single_case(tool, test_case)
      end)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    passed = Enum.count(results, &match?(:pass, &1))
    failed = Enum.count(results, &match?({:fail, _}, &1))
    errors = Enum.filter(results, &match?({:fail, _}, &1))

    status = if failed > 0, do: :fail, else: :pass

    {:ok,
     %{status: status, passed: passed, failed: failed, errors: errors, duration_ms: duration_ms}}
  end

  defp run_single_case(%ToolEntry{layer: :base, function: function}, test_case) do
    result = function.(test_case.input)

    case test_case.expected do
      :should_not_crash ->
        # As long as it didn't crash, it passes
        :pass

      expected ->
        if result == expected do
          :pass
        else
          {:fail, {:mismatch, expected: expected, actual: result}}
        end
    end
  rescue
    e ->
      case test_case.expected do
        :should_not_crash -> {:fail, {:crashed, e}}
        _ -> {:fail, {:crashed, e}}
      end
  catch
    kind, reason ->
      {:fail, {:caught, kind, reason}}
  end

  defp run_single_case(%ToolEntry{layer: :composed, code: code}, test_case) do
    # For composed tools, we need to evaluate the PTC-Lisp code
    # This is a simplified version - full implementation would use Lisp.run

    # Create a context with the test input
    context = %{"input" => test_case.input}

    # Wrap the tool code with a call using the input
    # This assumes the tool is a defn that takes one argument
    call_expr = "(#{extract_fn_name(code)} data/input)"

    case PtcRunner.Lisp.run(call_expr, context: context, timeout: 5000) do
      {:ok, step} ->
        case test_case.expected do
          :should_not_crash ->
            :pass

          expected ->
            if step.return == expected do
              :pass
            else
              {:fail, {:mismatch, expected: expected, actual: step.return}}
            end
        end

      {:error, step} ->
        case test_case.expected do
          :should_not_crash -> {:fail, {:execution_error, step.fail}}
          _ -> {:fail, {:execution_error, step.fail}}
        end
    end
  rescue
    e -> {:fail, {:crashed, e}}
  end

  defp run_single_case(%ToolEntry{function: nil, code: nil}, _test_case) do
    {:fail, :no_executable}
  end

  # Extract function name from defn code
  defp extract_fn_name(code) do
    case Regex.run(~r/\(defn\s+([a-z0-9_-]+)/, code) do
      [_, name] -> name
      _ -> "anonymous"
    end
  end
end
