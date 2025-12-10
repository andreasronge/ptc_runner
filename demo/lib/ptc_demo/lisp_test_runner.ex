defmodule PtcDemo.LispTestRunner do
  @moduledoc """
  Automated test runner for the PTC-Lisp demo.

  Runs example queries and validates results match expected constraints.
  Since data is randomly generated, we test properties not exact values.

  ## Usage

      # Run all tests with default model
      PtcDemo.LispTestRunner.run_all()

      # Run all tests with specific model
      PtcDemo.LispTestRunner.run_all(model: "anthropic:claude-3-5-haiku-latest")

      # Run with verbose output
      PtcDemo.LispTestRunner.run_all(verbose: true)

      # Generate a report file
      PtcDemo.LispTestRunner.run_all(report: "report.md")

      # List available tests
      PtcDemo.LispTestRunner.list()

      # Run a single test
      PtcDemo.LispTestRunner.run_one(3)
  """

  alias PtcDemo.LispAgent
  alias PtcDemo.TestRunner.{Base, TestCase, Report}
  alias PtcDemo.CLIBase

  # Test cases covering various query patterns
  defp test_cases do
    TestCase.common_test_cases() ++
      TestCase.lisp_specific_cases() ++
      TestCase.multi_turn_cases()
  end

  @doc """
  Run all test cases and report results.

  ## Options

    * `:verbose` - Show detailed output (default: false)
    * `:model` - Model to use (default: agent's current model)
    * `:data_mode` - Data mode :schema or :explore (default: :schema)
    * `:report` - Path to write markdown report file (optional)

  ## Examples

      PtcDemo.LispTestRunner.run_all()
      PtcDemo.LispTestRunner.run_all(verbose: true)
      PtcDemo.LispTestRunner.run_all(model: "anthropic:claude-3-5-haiku-latest")
      PtcDemo.LispTestRunner.run_all(report: "test_report.md")
  """
  def run_all(opts \\ []) do
    CLIBase.load_dotenv()
    CLIBase.ensure_api_key!()

    verbose = Keyword.get(opts, :verbose, false)
    model = Keyword.get(opts, :model)
    data_mode = Keyword.get(opts, :data_mode, :schema)
    report_path = Keyword.get(opts, :report)

    # Ensure agent is started
    ensure_agent_started(data_mode)

    # Set model if specified
    if model do
      LispAgent.set_model(model)
    end

    current_model = LispAgent.model()
    start_time = System.monotonic_time(:millisecond)

    IO.puts("\n=== PTC-Lisp Demo Test Runner ===")
    IO.puts("Model: #{current_model}")
    IO.puts("Data mode: #{data_mode}\n")

    results =
      test_cases()
      |> Enum.with_index(1)
      |> Enum.map(fn {test_case, index} ->
        # Reset context before each test to get clean attempt count
        LispAgent.reset()
        LispAgent.set_data_mode(data_mode)
        run_test(test_case, index, length(test_cases()), verbose)
      end)

    stats = LispAgent.stats()
    summary = Base.build_summary(results, start_time, current_model, data_mode, stats)

    Base.print_summary(summary)
    Base.print_failed_tests(results)

    # Write report if requested
    if report_path do
      Report.write(report_path, summary, "Lisp")
      IO.puts("\nReport written to: #{report_path}")
    end

    summary
  end

  @doc """
  Run a single test by index (1-based).
  """
  def run_one(index, opts \\ []) do
    CLIBase.load_dotenv()
    CLIBase.ensure_api_key!()

    cases = test_cases()

    if index > 0 and index <= length(cases) do
      data_mode = Keyword.get(opts, :data_mode, :schema)
      model = Keyword.get(opts, :model)

      ensure_agent_started(data_mode)

      if model do
        LispAgent.set_model(model)
      end

      test_case = Enum.at(cases, index - 1)
      run_test(test_case, index, length(cases), true)
    else
      IO.puts("Invalid index. Use list() to see available tests (1-#{length(cases)}).")
      nil
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
      case tc do
        %{queries: queries} ->
          IO.puts("  #{i}. [MULTI-TURN]")
          Enum.each(queries, fn q -> IO.puts("     → #{q}") end)

        %{query: query} ->
          IO.puts("  #{i}. #{query}")
      end

      IO.puts("     Expected: #{tc.description}")
    end)

    IO.puts("\nRun with: PtcDemo.LispTestRunner.run_one(N)")
    IO.puts("Run all:  PtcDemo.LispTestRunner.run_all()")
  end

  # Private functions

  defp ensure_agent_started(data_mode) do
    case Process.whereis(LispAgent) do
      nil ->
        {:ok, _pid} = LispAgent.start_link(data_mode: data_mode)
        :ok

      _pid ->
        # Reset to ensure clean state
        LispAgent.reset()
        LispAgent.set_data_mode(data_mode)
        :ok
    end
  end

  defp run_test(test_case, index, total, verbose) do
    # Handle multi-turn tests (queries list) vs single-turn (query string)
    case test_case do
      %{queries: queries} ->
        run_multi_turn_test(test_case, queries, index, total, verbose)

      %{query: query} ->
        run_single_turn_test(test_case, query, index, total, verbose)
    end
  end

  defp run_single_turn_test(test_case, query, index, total, verbose) do
    if verbose do
      IO.puts("\n[#{index}/#{total}] #{query}")
    else
      IO.write(".")
    end

    result =
      case LispAgent.ask(query) do
        {:ok, _answer} ->
          # Get all programs attempted during this query
          all_programs = LispAgent.programs()
          attempts = length(all_programs)

          # Get the actual result from running the program
          case LispAgent.last_result() do
            nil ->
              %{
                passed: false,
                error: "No result returned",
                attempts: attempts,
                all_programs: all_programs
              }

            value ->
              validation = Base.validate_result(value, test_case)

              validation
              |> Map.put(:program, LispAgent.last_program())
              |> Map.put(:attempts, attempts)
              |> Map.put(:all_programs, all_programs)
              |> Map.put(:final_result, value)
          end

        {:error, reason} ->
          all_programs = LispAgent.programs()

          %{
            passed: false,
            error: "Query failed: #{inspect(reason)}",
            program: LispAgent.last_program(),
            attempts: length(all_programs),
            all_programs: all_programs
          }
      end

    result =
      Map.merge(result, %{
        query: query,
        index: index,
        description: test_case.description,
        constraint: test_case.constraint
      })

    if verbose do
      if result.passed do
        IO.puts("   PASS: #{test_case.description}")
        IO.puts("   Attempts: #{result.attempts}")

        if result[:program] do
          IO.puts("   Program: #{String.trim(result.program)}")
        end
      else
        IO.puts("   FAIL: #{result.error}")
        IO.puts("   Attempts: #{result.attempts}")

        if result[:all_programs] && length(result.all_programs) > 0 do
          IO.puts("   All programs tried:")

          Enum.each(result.all_programs, fn {prog, prog_result} ->
            result_str = Base.format_attempt_result(prog_result)
            IO.puts("     - #{Base.truncate(prog, 60)}")
            IO.puts("       Result: #{result_str}")
          end)
        end
      end
    end

    result
  end

  defp run_multi_turn_test(test_case, queries, index, total, verbose) do
    query_display = Enum.join(queries, " → ")

    if verbose do
      IO.puts("\n[#{index}/#{total}] [MULTI-TURN] #{query_display}")
    else
      IO.write("M")
    end

    # Run each query in sequence without resetting (memory persists)
    {result, _} =
      Enum.reduce_while(queries, {nil, []}, fn query, {_prev_result, all_programs_acc} ->
        if verbose do
          IO.puts("   Turn: #{query}")
        end

        case LispAgent.ask(query) do
          {:ok, _answer} ->
            new_programs = LispAgent.programs()
            {:cont, {:ok, all_programs_acc ++ new_programs}}

          {:error, reason} ->
            new_programs = LispAgent.programs()

            {:halt,
             {%{
                passed: false,
                error: "Query failed: #{inspect(reason)}",
                program: LispAgent.last_program(),
                attempts: length(all_programs_acc) + length(new_programs),
                all_programs: all_programs_acc ++ new_programs
              }, []}}
        end
      end)

    # If we got through all queries successfully, validate the final result
    result =
      case result do
        :ok ->
          all_programs = LispAgent.programs()
          attempts = length(all_programs)

          case LispAgent.last_result() do
            nil ->
              %{
                passed: false,
                error: "No result returned after multi-turn",
                attempts: attempts,
                all_programs: all_programs
              }

            value ->
              validation = Base.validate_result(value, test_case)

              validation
              |> Map.put(:program, LispAgent.last_program())
              |> Map.put(:attempts, attempts)
              |> Map.put(:all_programs, all_programs)
              |> Map.put(:final_result, value)
          end

        %{passed: false} = error_result ->
          error_result
      end

    result =
      Map.merge(result, %{
        query: query_display,
        queries: queries,
        index: index,
        description: test_case.description,
        constraint: test_case.constraint,
        multi_turn: true
      })

    if verbose do
      if result.passed do
        IO.puts("   PASS: #{test_case.description}")
        IO.puts("   Attempts: #{result.attempts}")

        if result[:all_programs] && length(result.all_programs) > 0 do
          IO.puts("   All programs:")

          Enum.each(result.all_programs, fn {prog, prog_result} ->
            result_str = Base.format_attempt_result(prog_result)
            IO.puts("     - #{Base.truncate(prog, 70)}")
            IO.puts("       → #{result_str}")
          end)
        end
      else
        IO.puts("   FAIL: #{result.error}")
        IO.puts("   Attempts: #{result.attempts}")

        if result[:all_programs] && length(result.all_programs) > 0 do
          IO.puts("   All programs tried:")

          Enum.each(result.all_programs, fn {prog, prog_result} ->
            result_str = Base.format_attempt_result(prog_result)
            IO.puts("     - #{Base.truncate(prog, 70)}")
            IO.puts("       → #{result_str}")
          end)
        end
      end
    end

    result
  end
end
