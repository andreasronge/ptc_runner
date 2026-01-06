defmodule PtcDemo.JsonTestRunner do
  @moduledoc """
  Automated test runner for the PTC demo using SubAgent.

  Note: This runner now uses PTC-Lisp via SubAgent (the JSON DSL has been unified).
  Test cases are DSL-agnostic English queries - the LLM generates appropriate Lisp code.

  Runs example queries and validates results match expected constraints.
  Since data is randomly generated, we test properties not exact values.

  ## Usage

      # Run all tests with default model
      PtcDemo.JsonTestRunner.run_all()

      # Run all tests with specific model
      PtcDemo.JsonTestRunner.run_all(model: "anthropic:claude-3-5-haiku-latest")

      # Run with verbose output
      PtcDemo.JsonTestRunner.run_all(verbose: true)

      # Generate a report file
      PtcDemo.JsonTestRunner.run_all(report: "report.md")

      # List available tests
      PtcDemo.JsonTestRunner.list()

      # Run a single test
      PtcDemo.JsonTestRunner.run_one(3)
  """

  alias PtcDemo.Agent
  alias PtcDemo.TestRunner.{Base, TestCase, Report}
  alias PtcDemo.CLIBase

  # Test cases covering various query patterns
  defp test_cases do
    TestCase.common_test_cases() ++
      TestCase.multi_turn_cases()
  end

  @doc """
  Run all test cases and report results.

  ## Options

    * `:verbose` - Show detailed output (default: false)
    * `:model` - Model to use (default: agent's current model)
    * `:data_mode` - Data mode :schema or :explore (default: :schema)
    * `:report` - Path to write markdown report file (optional)
    * `:runs` - Number of times to run all tests (default: 1)

  ## Examples

      PtcDemo.JsonTestRunner.run_all()
      PtcDemo.JsonTestRunner.run_all(verbose: true)
      PtcDemo.JsonTestRunner.run_all(model: "anthropic:claude-3-5-haiku-latest")
      PtcDemo.JsonTestRunner.run_all(report: "test_report.md")
      PtcDemo.JsonTestRunner.run_all(runs: 3)
  """
  def run_all(opts \\ []) do
    agent_mod = Keyword.get(opts, :agent, Agent)

    # Only load dotenv and check API key if using real agent
    if agent_mod == Agent do
      CLIBase.load_dotenv()
      CLIBase.ensure_api_key!()
    end

    verbose = Keyword.get(opts, :verbose, false)
    model = Keyword.get(opts, :model)
    data_mode = Keyword.get(opts, :data_mode, :schema)
    report_path = Keyword.get(opts, :report)
    runs = Keyword.get(opts, :runs, 1)

    # Ensure agent is started
    ensure_agent_started(data_mode, agent_mod)

    # Set model if specified
    if model do
      agent_mod.set_model(model)
    end

    current_model = agent_mod.model()

    if verbose do
      IO.puts("\n=== PTC-JSON Demo Test Runner ===")
      IO.puts("Model: #{current_model}")
      IO.puts("Data mode: #{data_mode}")

      if runs > 1 do
        IO.puts("Runs: #{runs}")
      end

      IO.puts("")
    end

    # Run tests multiple times if requested
    summaries =
      for run_num <- 1..runs do
        run_single_batch(run_num, runs, data_mode, verbose, agent_mod, current_model)
      end

    # Print aggregate summary if multiple runs
    if runs > 1 do
      print_aggregate_summary(summaries)
    end

    # Build aggregate summary for report and return value
    aggregate_summary = Base.build_aggregate_summary(summaries)

    if report_path do
      actual_path =
        if report_path == :auto do
          CLIBase.generate_report_filename("json", current_model)
        else
          report_path
        end

      written_path = Report.write(actual_path, aggregate_summary, "JSON")
      IO.puts("\nReport written to: #{written_path}")
    end

    # Return the aggregate summary, include individual runs for reference
    Map.put(aggregate_summary, :all_runs, summaries)
  end

  defp run_single_batch(run_num, total_runs, data_mode, verbose, agent_mod, current_model) do
    if total_runs > 1 do
      IO.puts("\n--- Run #{run_num}/#{total_runs} ---")
    end

    start_time = System.monotonic_time(:millisecond)

    results =
      test_cases()
      |> Enum.with_index(1)
      |> Enum.map(fn {test_case, index} ->
        # Reset context before each test to get clean attempt count
        agent_mod.reset()
        agent_mod.set_data_mode(data_mode)
        run_test(test_case, index, length(test_cases()), verbose, agent_mod)
      end)

    stats = agent_mod.stats()
    summary = Base.build_summary(results, start_time, current_model, data_mode, stats)

    if verbose do
      Base.print_summary(summary)
      Base.print_failed_tests(results)
    end

    summary
  end

  defp print_aggregate_summary(summaries) do
    total_passed = Enum.sum(Enum.map(summaries, & &1.passed))
    total_failed = Enum.sum(Enum.map(summaries, & &1.failed))
    total_tests = total_passed + total_failed
    runs = length(summaries)

    IO.puts("\n========================================")
    IO.puts("AGGREGATE SUMMARY (#{runs} runs)")
    IO.puts("========================================")
    IO.puts("Total tests run: #{total_tests}")
    IO.puts("Total passed:    #{total_passed}")
    IO.puts("Total failed:    #{total_failed}")
    IO.puts("Pass rate:       #{Float.round(total_passed / total_tests * 100, 1)}%")

    # Show per-run breakdown
    IO.puts("\nPer-run results:")

    summaries
    |> Enum.with_index(1)
    |> Enum.each(fn {summary, idx} ->
      status = if summary.failed == 0, do: "PASS", else: "FAIL"
      IO.puts("  Run #{idx}: #{summary.passed}/#{summary.total} (#{status})")
    end)
  end

  @doc """
  Run a single test by index (1-based).
  """
  def run_one(index, opts \\ []) do
    agent_mod = Keyword.get(opts, :agent, Agent)

    # Only load dotenv and check API key if using real agent
    if agent_mod == Agent do
      CLIBase.load_dotenv()
      CLIBase.ensure_api_key!()
    end

    cases = test_cases()

    if index > 0 and index <= length(cases) do
      data_mode = Keyword.get(opts, :data_mode, :schema)
      model = Keyword.get(opts, :model)
      verbose = Keyword.get(opts, :verbose, true)

      ensure_agent_started(data_mode, agent_mod)

      if model do
        agent_mod.set_model(model)
      end

      test_case = Enum.at(cases, index - 1)
      run_test(test_case, index, length(cases), verbose, agent_mod)
    else
      verbose = Keyword.get(opts, :verbose, true)

      if verbose do
        IO.puts("Invalid index. Use list() to see available tests (1-#{length(cases)}).")
      end

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

    IO.puts("\nRun with: PtcDemo.JsonTestRunner.run_one(N)")
    IO.puts("Run all:  PtcDemo.JsonTestRunner.run_all()")
  end

  # Private functions

  defp ensure_agent_started(data_mode, agent_mod) do
    # For mock agents, assume they're already started or will be in test setup
    # For real Agent, check and start if needed
    if agent_mod == Agent do
      case Process.whereis(Agent) do
        nil ->
          {:ok, _pid} = Agent.start_link(data_mode: data_mode)
          :ok

        _pid ->
          # Reset to ensure clean state
          Agent.reset()
          Agent.set_data_mode(data_mode)
          :ok
      end
    else
      # Mock agents are started in test setup, just ensure they're ready
      :ok
    end
  end

  defp run_test(test_case, index, total, verbose, agent_mod) do
    # Handle multi-turn tests (queries list) vs single-turn (query string)
    case test_case do
      %{queries: queries} ->
        run_multi_turn_test(test_case, queries, index, total, verbose, agent_mod)

      %{query: query} ->
        run_single_turn_test(test_case, query, index, total, verbose, agent_mod)
    end
  end

  defp run_single_turn_test(test_case, query, index, total, verbose, agent_mod) do
    if verbose do
      IO.puts("\n[#{index}/#{total}] #{query}")
    else
      IO.write(".")
    end

    result =
      case agent_mod.ask(query, max_turns: 1) do
        {:ok, _answer} ->
          # Get all programs attempted during this query
          all_programs = agent_mod.programs()
          attempts = length(all_programs)

          # Get the actual result from running the program
          case agent_mod.last_result() do
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
              |> Map.put(:program, agent_mod.last_program())
              |> Map.put(:attempts, attempts)
              |> Map.put(:all_programs, all_programs)
              |> Map.put(:final_result, value)
          end

        {:error, reason} ->
          all_programs = agent_mod.programs()

          %{
            passed: false,
            error: "Query failed: #{inspect(reason)}",
            program: agent_mod.last_program(),
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

  defp run_multi_turn_test(test_case, queries, index, total, verbose, agent_mod) do
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

        case agent_mod.ask(query, max_turns: 1) do
          {:ok, _answer} ->
            new_programs = agent_mod.programs()
            {:cont, {:ok, all_programs_acc ++ new_programs}}

          {:error, reason} ->
            new_programs = agent_mod.programs()

            {:halt,
             {%{
                passed: false,
                error: "Query failed: #{inspect(reason)}",
                program: agent_mod.last_program(),
                attempts: length(all_programs_acc) + length(new_programs),
                all_programs: all_programs_acc ++ new_programs
              }, []}}
        end
      end)

    # If we got through all queries successfully, validate the final result
    result =
      case result do
        :ok ->
          all_programs = agent_mod.programs()
          attempts = length(all_programs)

          case agent_mod.last_result() do
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
              |> Map.put(:program, agent_mod.last_program())
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
