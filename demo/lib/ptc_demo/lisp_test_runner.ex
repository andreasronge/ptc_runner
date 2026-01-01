defmodule PtcDemo.LispTestRunner do
  @moduledoc """
  Automated test runner for the PTC demo using SubAgent.

  Uses PTC-Lisp via SubAgent to generate and execute programs.
  Includes Lisp-specific test cases in addition to common test cases.

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

  alias PtcDemo.Agent
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
    * `:runs` - Number of times to run all tests (default: 1)
    * `:validate_clojure` - Validate generated programs against Babashka (default: false)

  ## Examples

      PtcDemo.LispTestRunner.run_all()
      PtcDemo.LispTestRunner.run_all(verbose: true)
      PtcDemo.LispTestRunner.run_all(model: "anthropic:claude-3-5-haiku-latest")
      PtcDemo.LispTestRunner.run_all(report: "test_report.md")
      PtcDemo.LispTestRunner.run_all(runs: 3)
      PtcDemo.LispTestRunner.run_all(validate_clojure: true)
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
    validate_clojure = Keyword.get(opts, :validate_clojure, false)

    # Check Babashka availability if Clojure validation requested
    clojure_available = check_clojure_validation(validate_clojure)

    # Ensure agent is started
    ensure_agent_started(data_mode, agent_mod)

    # Set model if specified
    if model do
      agent_mod.set_model(model)
    end

    current_model = agent_mod.model()

    IO.puts("\n=== PTC-Lisp Demo Test Runner ===")
    IO.puts("Model: #{current_model}")
    IO.puts("Data mode: #{data_mode}")

    if runs > 1 do
      IO.puts("Runs: #{runs}")
    end

    if clojure_available do
      IO.puts("Clojure validation: enabled")
    end

    IO.puts("")

    # Run tests multiple times if requested
    summaries =
      for run_num <- 1..runs do
        run_single_batch(
          run_num,
          runs,
          data_mode,
          verbose,
          agent_mod,
          current_model,
          clojure_available
        )
      end

    # Print aggregate summary if multiple runs
    if runs > 1 do
      print_aggregate_summary(summaries)
    end

    # Write report for last run if requested
    last_summary = List.last(summaries)

    if report_path do
      actual_path =
        if report_path == :auto do
          CLIBase.generate_report_filename("lisp", current_model)
        else
          report_path
        end

      written_path = Report.write(actual_path, last_summary, "Lisp")
      IO.puts("\nReport written to: #{written_path}")
    end

    # Return the last summary for CLI exit code, but include all summaries
    Map.put(last_summary, :all_runs, summaries)
  end

  defp run_single_batch(
         run_num,
         total_runs,
         data_mode,
         verbose,
         agent_mod,
         current_model,
         clojure_available
       ) do
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
        run_test(test_case, index, length(test_cases()), verbose, agent_mod, clojure_available)
      end)

    stats = agent_mod.stats()
    summary = Base.build_summary(results, start_time, current_model, data_mode, stats)

    Base.print_summary(summary)
    Base.print_failed_tests(results)

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
      validate_clojure = Keyword.get(opts, :validate_clojure, false)

      ensure_agent_started(data_mode, agent_mod)

      if model do
        agent_mod.set_model(model)
      end

      clojure_available = check_clojure_validation(validate_clojure)
      test_case = Enum.at(cases, index - 1)
      run_test(test_case, index, length(cases), true, agent_mod, clojure_available)
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

  defp run_test(test_case, index, total, verbose, agent_mod, clojure_available) do
    # Handle multi-turn tests (queries list) vs single-turn (query string)
    case test_case do
      %{queries: queries} ->
        run_multi_turn_test(
          test_case,
          queries,
          index,
          total,
          verbose,
          agent_mod,
          clojure_available
        )

      %{query: query} ->
        run_single_turn_test(
          test_case,
          query,
          index,
          total,
          verbose,
          agent_mod,
          clojure_available
        )
    end
  end

  defp run_single_turn_test(test_case, query, index, total, verbose, agent_mod, clojure_available) do
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

    # Add Clojure validation if enabled and we have a program
    result =
      if clojure_available and result[:program] do
        add_clojure_validation(result, verbose)
      else
        result
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

  defp run_multi_turn_test(
         test_case,
         queries,
         index,
         total,
         verbose,
         agent_mod,
         clojure_available
       ) do
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

    # Add Clojure validation if enabled and we have a program
    result =
      if clojure_available and result[:program] do
        add_clojure_validation(result, verbose)
      else
        result
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

  # Execute program in Clojure and compare results
  defp add_clojure_validation(result, verbose) do
    program = result[:program]
    ptc_result = result[:final_result]

    # Build context with the same data used by PTC-Lisp
    context = %{
      "products" => PtcDemo.SampleData.products(),
      "orders" => PtcDemo.SampleData.orders(),
      "employees" => PtcDemo.SampleData.employees(),
      "expenses" => PtcDemo.SampleData.expenses()
    }

    case PtcRunner.Lisp.ClojureValidator.execute(program, context: context) do
      {:ok, clj_result} ->
        case PtcRunner.Lisp.ClojureValidator.compare_results(ptc_result, clj_result) do
          :match ->
            if verbose do
              IO.puts("   Clojure: executed, results match")
            end

            Map.put(result, :clojure_valid, true)

          {:mismatch, details} ->
            if verbose do
              IO.puts("   Clojure: MISMATCH - #{details}")
            end

            result
            |> Map.put(:clojure_valid, false)
            |> Map.put(:clojure_error, "Result mismatch: #{details}")
        end

      {:error, msg} ->
        if verbose do
          IO.puts("   Clojure: ERROR - #{msg}")
        end

        result
        |> Map.put(:clojure_valid, false)
        |> Map.put(:clojure_error, msg)
    end
  end

  # Check if Clojure validation is available and requested
  defp check_clojure_validation(validate_clojure) do
    cond do
      validate_clojure == false ->
        # Explicitly disabled
        false

      validate_clojure == true ->
        # Explicitly enabled - check availability
        if PtcRunner.Lisp.ClojureValidator.available?() do
          IO.puts("Clojure validation: enabled (Babashka found)")
          true
        else
          IO.puts("WARNING: Clojure validation requested but Babashka not installed.")
          IO.puts("Install with: mix ptc.install_babashka")
          IO.puts("")
          false
        end

      true ->
        # Not specified - don't enable by default in demo
        false
    end
  end
end
