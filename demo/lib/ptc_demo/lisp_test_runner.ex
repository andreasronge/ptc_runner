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
  Run a comparison benchmark across multiple prompt profiles.

  Runs the full test suite once per prompt and outputs a comparison table.

  ## Options

    * `:model` - Model to use (default: agent's current model)
    * `:data_mode` - Data mode :schema or :explore (default: :schema)
    * `:verbose` - Show detailed output per run (default: false)

  ## Examples

      # Compare single_shot vs multi_turn prompts
      PtcDemo.LispTestRunner.run_comparison([:single_shot, :multi_turn])
  """
  def run_comparison(prompts, opts \\ []) when is_list(prompts) do
    CLIBase.load_dotenv()
    CLIBase.ensure_api_key!()

    IO.puts("\n=== Prompt Comparison Benchmark ===")
    IO.puts("Prompts: #{inspect(prompts)}")
    IO.puts("")

    # Run tests for each prompt
    results =
      Enum.map(prompts, fn prompt ->
        IO.puts("\n--- Running with prompt: #{prompt} ---")
        summary = run_all(Keyword.merge(opts, prompt: prompt, verbose: false))
        {prompt, summary}
      end)

    # Print comparison table
    print_comparison_table(results)

    results
  end

  defp print_comparison_table(results) do
    IO.puts("\n========================================")
    IO.puts("PROMPT COMPARISON")
    IO.puts("========================================")
    IO.puts("")

    # Header
    IO.puts(
      String.pad_trailing("Prompt", 15) <>
        String.pad_leading("Pass", 8) <>
        String.pad_leading("Rate", 8) <>
        String.pad_leading("Tokens", 10) <>
        String.pad_leading("Time", 10)
    )

    IO.puts(String.duplicate("-", 51))

    # Rows
    Enum.each(results, fn {prompt, summary} ->
      pass_rate = Float.round(summary.passed / summary.total * 100, 1)

      tokens =
        if summary[:stats][:total_tokens] do
          "#{summary.stats.total_tokens}"
        else
          "-"
        end

      time =
        if summary[:duration_ms] do
          "#{Float.round(summary.duration_ms / 1000, 1)}s"
        else
          "-"
        end

      IO.puts(
        String.pad_trailing("#{prompt}", 15) <>
          String.pad_leading("#{summary.passed}/#{summary.total}", 8) <>
          String.pad_leading("#{pass_rate}%", 8) <>
          String.pad_leading(tokens, 10) <>
          String.pad_leading(time, 10)
      )
    end)

    IO.puts("")
  end

  @doc """
  Run all test cases and report results.

  ## Options

    * `:verbose` - Show detailed output (default: false)
    * `:model` - Model to use (default: agent's current model)
    * `:data_mode` - Data mode :schema or :explore (default: :schema)
    * `:prompt` - Prompt profile to use (default: :auto). See `PtcDemo.Prompts.list/0`.
    * `:report` - Path to write markdown report file (optional)
    * `:runs` - Number of times to run all tests (default: 1)
    * `:validate_clojure` - Validate generated programs against Babashka (default: false)

  ## Examples

      PtcDemo.LispTestRunner.run_all()
      PtcDemo.LispTestRunner.run_all(verbose: true)
      PtcDemo.LispTestRunner.run_all(model: "anthropic:claude-3-5-haiku-latest")
      PtcDemo.LispTestRunner.run_all(prompt: :single_shot)
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
    prompt_profile = Keyword.get(opts, :prompt, :auto)
    report_path = Keyword.get(opts, :report)
    runs = Keyword.get(opts, :runs, 1)
    validate_clojure = Keyword.get(opts, :validate_clojure, false)

    # Check Babashka availability if Clojure validation requested
    clojure_available = check_clojure_validation(validate_clojure)

    # Ensure agent is started
    ensure_agent_started(data_mode, prompt_profile, agent_mod)

    # Set model if specified
    if model do
      agent_mod.set_model(model)
    end

    current_model = agent_mod.model()

    if verbose do
      IO.puts("\n=== PTC-Lisp Demo Test Runner ===")
      IO.puts("Model: #{current_model}")
      IO.puts("Data mode: #{data_mode}")

      prompt_display =
        if prompt_profile == :auto do
          "auto (single_shot/multi_turn per test)"
        else
          "#{prompt_profile}"
        end

      IO.puts("Prompt: #{prompt_display}")

      if runs > 1 do
        IO.puts("Runs: #{runs}")
      end

      if clojure_available do
        IO.puts("Clojure validation: enabled")
      end

      IO.puts("")
    end

    # Run tests multiple times if requested
    summaries =
      for run_num <- 1..runs do
        run_single_batch(
          run_num,
          runs,
          data_mode,
          prompt_profile,
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

    # Build aggregate summary for report and return value
    aggregate_summary = Base.build_aggregate_summary(summaries)

    if report_path do
      actual_path =
        if report_path == :auto do
          CLIBase.generate_report_filename("lisp", current_model)
        else
          report_path
        end

      written_path = Report.write(actual_path, aggregate_summary, "Lisp")
      IO.puts("\nReport written to: #{written_path}")

      # Regenerate aggregate summary of all reports
      reports_dir = Path.dirname(written_path)
      generate_aggregate_summary(reports_dir)
    end

    # Return the aggregate summary, include individual runs for reference
    Map.put(aggregate_summary, :all_runs, summaries)
  end

  defp run_single_batch(
         run_num,
         total_runs,
         data_mode,
         prompt_profile,
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

        # Set prompt based on test type when :auto
        effective_prompt = prompt_for_test(test_case, prompt_profile)
        agent_mod.set_prompt_profile(effective_prompt)

        # Note: debug is false for batch runs - use run_one for debugging
        run_test(
          test_case,
          index,
          length(test_cases()),
          verbose,
          false,
          agent_mod,
          clojure_available
        )
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
    # Normalize opts to keyword list for consistent access
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    agent_mod = Keyword.get(opts, :agent, Agent)

    # Only load dotenv and check API key if using real agent
    if agent_mod == Agent do
      CLIBase.load_dotenv()
      CLIBase.ensure_api_key!()
    end

    cases = test_cases()

    if index > 0 and index <= length(cases) do
      data_mode = Keyword.get(opts, :data_mode, :schema)
      prompt_profile = Keyword.get(opts, :prompt, :auto)
      model = Keyword.get(opts, :model)
      validate_clojure = Keyword.get(opts, :validate_clojure, false)
      verbose = Keyword.get(opts, :verbose, true)
      debug = Keyword.get(opts, :debug, false)

      test_case = Enum.at(cases, index - 1)

      # Use :single_shot as default for starting the agent (will be overridden)
      ensure_agent_started(data_mode, :single_shot, agent_mod)

      if model do
        agent_mod.set_model(model)
      end

      # Set prompt based on test type when :auto
      effective_prompt = prompt_for_test(test_case, prompt_profile)
      agent_mod.set_prompt_profile(effective_prompt)

      if verbose do
        max_turns = Map.get(test_case, :max_turns, 1)
        IO.puts("   [Prompt] #{effective_prompt}, max_turns: #{max_turns}")
      end

      clojure_available = check_clojure_validation(validate_clojure)
      run_test(test_case, index, length(cases), verbose, debug, agent_mod, clojure_available)
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
      max_turns = Map.get(tc, :max_turns, 1)
      prefix = if max_turns > 1, do: "[MULTI-TURN] ", else: ""
      IO.puts("  #{i}. #{prefix}#{tc.query}")
      IO.puts("     Expected: #{tc.description}")
    end)

    IO.puts("\nRun with: PtcDemo.LispTestRunner.run_one(N)")
    IO.puts("Run all:  PtcDemo.LispTestRunner.run_all()")
  end

  # Private functions

  # Select appropriate prompt for test type
  defp prompt_for_test(test_case, :auto) do
    if Map.get(test_case, :max_turns, 1) > 1, do: :multi_turn, else: :single_shot
  end

  defp prompt_for_test(_test_case, explicit_profile), do: explicit_profile

  defp ensure_agent_started(data_mode, prompt_profile, agent_mod) do
    # When :auto, use :single_shot as default for starting (will be overridden per-test)
    start_prompt = if prompt_profile == :auto, do: :single_shot, else: prompt_profile

    # For mock agents, assume they're already started or will be in test setup
    # For real Agent, check and start if needed
    if agent_mod == Agent do
      case Process.whereis(Agent) do
        nil ->
          {:ok, _pid} = Agent.start_link(data_mode: data_mode, prompt: start_prompt)
          :ok

        _pid ->
          # Reset to ensure clean state
          Agent.reset()
          Agent.set_data_mode(data_mode)
          Agent.set_prompt_profile(start_prompt)
          :ok
      end
    else
      # Mock agents are started in test setup, just ensure they're ready
      :ok
    end
  end

  defp run_test(test_case, index, total, verbose, debug, agent_mod, clojure_available) do
    query = test_case.query
    max_turns = Map.get(test_case, :max_turns, 1)
    expect = Map.get(test_case, :expect)
    signature = Map.get(test_case, :signature)

    if verbose do
      prefix = if max_turns > 1, do: "[MULTI-TURN] ", else: ""
      IO.puts("\n[#{index}/#{total}] #{prefix}#{query}")
    else
      IO.write(if max_turns > 1, do: "M", else: ".")
    end

    # Build ask options - signature takes precedence over expect for type validation
    ask_opts = [max_turns: max_turns, expect: expect, debug: debug]
    ask_opts = if signature, do: Keyword.put(ask_opts, :signature, signature), else: ask_opts

    result =
      case agent_mod.ask(query, ask_opts) do
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

        # Show all programs for multi-turn tests
        if result[:all_programs] && length(result.all_programs) > 1 do
          IO.puts("   All programs:")

          Enum.each(result.all_programs, fn {prog, prog_result} ->
            result_str = Base.format_attempt_result(prog_result)
            IO.puts("     - #{Base.truncate(prog, 70)}")
            IO.puts("       Result: #{Base.truncate(result_str, 60)}")
          end)
        else
          if result[:program] do
            IO.puts("   Program: #{String.trim(result.program)}")
          end
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

  # Execute program in Clojure and compare results
  defp add_clojure_validation(result, verbose) do
    program = result[:program]
    ptc_result = result[:final_result]

    # Build context with the same data used by PTC-Lisp
    context = %{
      "products" => PtcDemo.SampleData.products(),
      "orders" => PtcDemo.SampleData.orders(),
      "employees" => PtcDemo.SampleData.employees(),
      "expenses" => PtcDemo.SampleData.expenses(),
      "documents" => PtcDemo.SampleData.documents()
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

  # Generate aggregate summary of all reports in directory
  defp generate_aggregate_summary(reports_dir) do
    case Mix.Tasks.Aggregate.aggregate_reports(reports_dir) do
      {:ok, report} ->
        summary_path = Path.join(reports_dir, "SUMMARY.md")
        File.write!(summary_path, report)
        IO.puts("Summary updated: #{summary_path}")

      {:error, _reason} ->
        # Silently skip if aggregation fails (e.g., only one report)
        :ok
    end
  end
end
