defmodule PtcDemo.TestRunner do
  @moduledoc """
  Automated test runner for the PTC demo.

  Runs example queries and validates results match expected constraints.
  Since data is randomly generated, we test properties not exact values.
  """

  alias PtcDemo.Agent

  # Test cases defined as a function to avoid module attribute escaping issues
  defp test_cases do
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
      %{
        query: "How many employees are there?",
        expect: :integer,
        constraint: {:eq, 200},
        description: "Total employees should be 200"
      },

      # Filtered counts (should be > 0 given random distribution)
      %{
        query: "How many products are in the electronics category?",
        expect: :integer,
        constraint: {:between, 1, 499},
        description: "Electronics products should be between 1-499"
      },
      %{
        query: "How many orders were paid by credit_card?",
        expect: :integer,
        constraint: {:between, 1, 999},
        description: "Credit card orders should be between 1-999"
      },
      %{
        query: "How many employees work remotely?",
        expect: :integer,
        constraint: {:between, 1, 199},
        description: "Remote employees should be between 1-199"
      },

      # Aggregations
      %{
        query: "What is the total of all order amounts?",
        expect: :number,
        constraint: {:gt, 1000},
        description: "Total order revenue should be > 1000"
      },
      %{
        query: "What is the average employee salary?",
        expect: :number,
        constraint: {:between, 50_000, 200_000},
        description: "Average salary should be between 50k-200k"
      },

      # Combined filters
      %{
        query: "How many orders over 1000 were paid by credit_card?",
        expect: :integer,
        constraint: {:between, 0, 999},
        description: "High-value credit card orders should be 0-999"
      },
      %{
        query: "Count employees in engineering department",
        expect: :integer,
        constraint: {:between, 1, 199},
        description: "Engineering employees should be between 1-199"
      },

      # Expenses
      %{
        query: "Sum all travel expenses",
        expect: :number,
        constraint: {:gt, 0},
        description: "Travel expenses sum should be > 0"
      }
    ]
  end

  @doc """
  Run all test cases and report results.

  Options:
    - verbose: true/false (default false) - show detailed output
  """
  def run_all(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)

    IO.puts("\n=== PTC Demo Test Runner ===\n")

    # Ensure agent is started
    ensure_agent_started()

    results =
      test_cases()
      |> Enum.with_index(1)
      |> Enum.map(fn {test_case, index} ->
        run_test(test_case, index, verbose)
      end)

    # Summary
    passed = Enum.count(results, & &1.passed)
    failed = Enum.count(results, &(!&1.passed))

    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("Results: #{passed} passed, #{failed} failed")
    IO.puts(String.duplicate("=", 50))

    if failed > 0 do
      IO.puts("\nFailed tests:")

      results
      |> Enum.reject(& &1.passed)
      |> Enum.each(fn r ->
        IO.puts("  - #{r.query}")
        IO.puts("    #{r.error}")
      end)
    end

    # Return exit code for CI
    if failed > 0, do: {:error, failed}, else: :ok
  end

  @doc """
  Run a single test by index (1-based).
  """
  def run_one(index) do
    cases = test_cases()

    if index > 0 and index <= length(cases) do
      ensure_agent_started()
      test_case = Enum.at(cases, index - 1)
      run_test(test_case, index, true)
    else
      IO.puts("Invalid index. Use list() to see available tests.")
    end
  end

  @doc """
  List all available test cases.
  """
  def list do
    IO.puts("\nAvailable test cases:\n")

    test_cases()
    |> Enum.with_index(1)
    |> Enum.each(fn {tc, i} ->
      IO.puts("  #{i}. #{tc.query}")
      IO.puts("     Expected: #{tc.description}")
    end)

    IO.puts("\nRun with: PtcDemo.TestRunner.run_one(N)")
  end

  # Private functions

  defp ensure_agent_started do
    case Process.whereis(Agent) do
      nil ->
        {:ok, _pid} = Agent.start_link()
        :ok

      _pid ->
        :ok
    end
  end

  defp run_test(test_case, index, verbose) do
    if verbose do
      IO.puts("#{index}. #{test_case.query}")
    else
      IO.write(".")
    end

    result =
      case Agent.ask(test_case.query) do
        {:ok, _answer} ->
          # Get the actual result from running the program
          case get_last_result() do
            {:ok, value} ->
              validate_result(value, test_case)

            {:error, reason} ->
              %{passed: false, error: "Failed to get result: #{reason}"}
          end

        {:error, reason} ->
          %{passed: false, error: "Query failed: #{reason}"}
      end

    result = Map.merge(result, %{query: test_case.query, index: index})

    if verbose do
      if result.passed do
        IO.puts("   ✓ #{test_case.description}")
      else
        IO.puts("   ✗ #{result.error}")
      end
    end

    result
  end

  defp get_last_result do
    case Agent.last_result() do
      nil ->
        {:error, "No result available"}

      result ->
        {:ok, result}
    end
  end

  defp validate_result(value, test_case) do
    type_ok = check_type(value, test_case.expect)
    constraint_ok = check_constraint(value, test_case.constraint)

    cond do
      not type_ok ->
        %{passed: false, error: "Wrong type: got #{inspect(value)}, expected #{test_case.expect}"}

      not constraint_ok ->
        %{
          passed: false,
          error: "Constraint failed: got #{inspect(value)}, expected: #{test_case.description}"
        }

      true ->
        %{passed: true, value: value}
    end
  end

  defp check_type(value, :integer), do: is_integer(value)
  defp check_type(value, :number), do: is_number(value)
  defp check_type(value, :list), do: is_list(value)
  defp check_type(_value, _), do: true

  defp check_constraint(value, {:eq, expected}), do: value == expected
  defp check_constraint(value, {:gt, min}), do: value > min
  defp check_constraint(value, {:gte, min}), do: value >= min
  defp check_constraint(value, {:lt, max}), do: value < max
  defp check_constraint(value, {:between, min, max}), do: value >= min and value <= max
  defp check_constraint(_value, _), do: true
end
