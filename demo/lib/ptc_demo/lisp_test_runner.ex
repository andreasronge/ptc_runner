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

  # Test cases covering various query patterns
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
      %{
        query: "How many expenses are there?",
        expect: :integer,
        constraint: {:eq, 800},
        description: "Total expenses should be 800"
      },

      # Filtered counts
      %{
        query: "How many products are in the electronics category?",
        expect: :integer,
        constraint: {:between, 1, 499},
        description: "Electronics products should be between 1-499"
      },
      %{
        query: "How many orders have status delivered?",
        expect: :integer,
        constraint: {:between, 1, 999},
        description: "Delivered orders should be between 1-999"
      },
      %{
        query: "How many employees work remotely?",
        expect: :integer,
        constraint: {:between, 1, 199},
        description: "Remote employees should be between 1-199"
      },
      %{
        query: "How many expenses are pending approval?",
        expect: :integer,
        constraint: {:between, 1, 799},
        description: "Pending expenses should be between 1-799"
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
      %{
        query: "What is the average product price?",
        expect: :number,
        constraint: {:between, 1, 10_000},
        description: "Average product price should be between 1-10000"
      },

      # Sort with comparator (tests the fix for sort-by with >)
      %{
        query: "Find the most expensive product and return its name",
        expect: :string,
        constraint: {:starts_with, "Product"},
        description: "Most expensive product name should start with 'Product'"
      },
      %{
        query: "Get the names of the top 3 highest paid employees",
        expect: :list,
        constraint: {:length, 3},
        description: "Should return exactly 3 employee names"
      },

      # Combined filters
      %{
        query: "How many orders over 500 have status delivered?",
        expect: :integer,
        constraint: {:between, 0, 999},
        description: "High-value delivered orders should be 0-999"
      },
      %{
        query: "Count employees in the engineering department",
        expect: :integer,
        constraint: {:between, 1, 199},
        description: "Engineering employees should be between 1-199"
      },

      # Expenses
      %{
        query: "What is the total amount of travel expenses?",
        expect: :number,
        constraint: {:gt, 0},
        description: "Travel expenses sum should be > 0"
      },

      # Cross-dataset queries (joining/correlating multiple datasets)
      %{
        query:
          "How many unique products have been ordered? (count distinct product_id values in orders)",
        expect: :integer,
        constraint: {:between, 1, 500},
        description: "Unique ordered products should be between 1-500"
      },
      %{
        query: "What is the total expense amount for employees in the engineering department?",
        expect: :number,
        constraint: {:gte, 0},
        description: "Engineering department expenses should be >= 0"
      },
      %{
        query:
          "How many employees have submitted expenses? (count unique employee_ids in expenses that exist in employees)",
        expect: :integer,
        constraint: {:between, 1, 200},
        description: "Employees with expenses should be between 1-200"
      },

      # Multi-turn queries (tests memory persistence between questions)
      %{
        queries: [
          "Count delivered orders and store the result in memory as delivered-count",
          "What percentage of all orders are delivered? Use memory/delivered-count and total order count."
        ],
        expect: :number,
        constraint: {:between, 1, 99},
        description: "Multi-turn: percentage calculation using stored count"
      },
      %{
        queries: [
          "Store the list of employees in the engineering department in memory as engineering-employees",
          "What is the average salary of the engineering employees stored in memory?"
        ],
        expect: :number,
        constraint: {:between, 50_000, 200_000},
        description: "Multi-turn: average salary using stored employee list"
      }
    ]
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
    load_dotenv()
    ensure_api_key!()

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

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    # Summary
    passed = Enum.count(results, & &1.passed)
    failed = Enum.count(results, &(!&1.passed))
    total = length(results)
    total_attempts = Enum.sum(Enum.map(results, & &1.attempts))

    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("Results: #{passed}/#{total} passed, #{failed} failed")

    IO.puts(
      "Total attempts: #{total_attempts} (#{Float.round(total_attempts / total, 1)} avg per test)"
    )

    IO.puts("Duration: #{format_duration(duration_ms)}")
    IO.puts("Model: #{current_model}")
    IO.puts(String.duplicate("=", 50))

    if failed > 0 do
      IO.puts("\nFailed tests:")

      results
      |> Enum.reject(& &1.passed)
      |> Enum.each(fn r ->
        IO.puts("\n  #{r.index}. #{r.query}")
        IO.puts("     Error: #{r.error}")
        IO.puts("     Attempts: #{r.attempts}")

        if r[:all_programs] && length(r.all_programs) > 0 do
          IO.puts("     Programs tried:")

          Enum.each(r.all_programs, fn {prog, result} ->
            result_str = format_attempt_result(result)
            IO.puts("       - #{truncate(prog, 60)}")
            IO.puts("         Result: #{result_str}")
          end)
        end
      end)
    end

    # Print stats
    stats = LispAgent.stats()
    IO.puts("\nToken usage: #{stats.total_tokens} tokens, cost: #{format_cost(stats.total_cost)}")

    # Build summary
    summary = %{
      passed: passed,
      failed: failed,
      total: total,
      total_attempts: total_attempts,
      duration_ms: duration_ms,
      model: current_model,
      data_mode: data_mode,
      results: results,
      stats: stats,
      timestamp: DateTime.utc_now()
    }

    # Write report if requested
    if report_path do
      write_report(report_path, summary)
      IO.puts("\nReport written to: #{report_path}")
    end

    summary
  end

  @doc """
  Run a single test by index (1-based).
  """
  def run_one(index, opts \\ []) do
    load_dotenv()
    ensure_api_key!()

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
              validation = validate_result(value, test_case)

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
            result_str = format_attempt_result(prog_result)
            IO.puts("     - #{truncate(prog, 60)}")
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
              validation = validate_result(value, test_case)

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
            result_str = format_attempt_result(prog_result)
            IO.puts("     - #{truncate(prog, 70)}")
            IO.puts("       → #{result_str}")
          end)
        end
      else
        IO.puts("   FAIL: #{result.error}")
        IO.puts("   Attempts: #{result.attempts}")

        if result[:all_programs] && length(result.all_programs) > 0 do
          IO.puts("   All programs tried:")

          Enum.each(result.all_programs, fn {prog, prog_result} ->
            result_str = format_attempt_result(prog_result)
            IO.puts("     - #{truncate(prog, 70)}")
            IO.puts("       → #{result_str}")
          end)
        end
      end
    end

    result
  end

  defp validate_result(value, test_case) do
    type_ok = check_type(value, test_case.expect)
    constraint_result = check_constraint(value, test_case.constraint)

    cond do
      not type_ok ->
        %{
          passed: false,
          error:
            "Wrong type: got #{inspect(value)} (#{type_of(value)}), expected #{test_case.expect}"
        }

      constraint_result != true ->
        %{
          passed: false,
          error: constraint_result
        }

      true ->
        %{passed: true, value: value}
    end
  end

  defp type_of(v) when is_integer(v), do: :integer
  defp type_of(v) when is_float(v), do: :float
  defp type_of(v) when is_binary(v), do: :string
  defp type_of(v) when is_list(v), do: :list
  defp type_of(v) when is_map(v), do: :map
  defp type_of(v) when is_boolean(v), do: :boolean
  defp type_of(nil), do: nil
  defp type_of(_), do: :unknown

  defp check_type(value, :integer), do: is_integer(value)
  defp check_type(value, :number), do: is_number(value)
  defp check_type(value, :list), do: is_list(value)
  defp check_type(value, :string), do: is_binary(value)
  defp check_type(value, :map), do: is_map(value)
  defp check_type(_value, _), do: true

  defp check_constraint(value, {:eq, expected}) do
    if value == expected, do: true, else: "Expected #{expected}, got #{value}"
  end

  defp check_constraint(value, {:gt, min}) do
    if value > min, do: true, else: "Expected > #{min}, got #{value}"
  end

  defp check_constraint(value, {:gte, min}) do
    if value >= min, do: true, else: "Expected >= #{min}, got #{value}"
  end

  defp check_constraint(value, {:lt, max}) do
    if value < max, do: true, else: "Expected < #{max}, got #{value}"
  end

  defp check_constraint(value, {:between, min, max}) do
    if value >= min and value <= max do
      true
    else
      "Expected between #{min}-#{max}, got #{value}"
    end
  end

  defp check_constraint(value, {:length, expected}) when is_list(value) do
    actual = length(value)
    if actual == expected, do: true, else: "Expected length #{expected}, got #{actual}"
  end

  defp check_constraint(value, {:starts_with, prefix}) when is_binary(value) do
    if String.starts_with?(value, prefix) do
      true
    else
      "Expected to start with '#{prefix}', got '#{value}'"
    end
  end

  defp check_constraint(_value, _), do: true

  defp format_cost(cost) when is_float(cost) and cost > 0 do
    "$#{:erlang.float_to_binary(cost, decimals: 4)}"
  end

  defp format_cost(_), do: "$0.00"

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp format_attempt_result({:error, msg}), do: "ERROR: #{truncate(to_string(msg), 50)}"
  defp format_attempt_result(result), do: truncate(inspect(result), 50)

  defp truncate(str, max_len) when is_binary(str) do
    str = String.replace(str, ~r/\s+/, " ") |> String.trim()

    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  defp truncate(other, max_len), do: truncate(inspect(other), max_len)

  # Report generation

  defp write_report(path, summary) do
    content = generate_report(summary)
    File.write!(path, content)
  end

  defp generate_report(summary) do
    """
    # PTC-Lisp Test Report

    **Generated:** #{format_timestamp(summary.timestamp)}
    **Model:** #{summary.model}
    **Data Mode:** #{summary.data_mode}

    ## Summary

    | Metric | Value |
    |--------|-------|
    | Passed | #{summary.passed}/#{summary.total} |
    | Failed | #{summary.failed} |
    | Total Attempts | #{summary.total_attempts} |
    | Avg Attempts/Test | #{Float.round(summary.total_attempts / summary.total, 2)} |
    | Duration | #{format_duration(summary.duration_ms)} |
    | Total Tokens | #{summary.stats.total_tokens} |
    | Cost | #{format_cost(summary.stats.total_cost)} |

    ## Results

    #{generate_results_table(summary.results)}

    #{generate_failed_details(summary.results)}

    #{generate_all_programs_section(summary.results)}
    """
  end

  defp generate_results_table(results) do
    header =
      "| # | Query | Status | Attempts | Program |\n|---|-------|--------|----------|---------|"

    rows =
      Enum.map(results, fn r ->
        status = if r.passed, do: "PASS", else: "FAIL"
        program = truncate(r[:program] || "-", 40)
        query = truncate(r.query, 40)
        "| #{r.index} | #{query} | #{status} | #{r.attempts} | `#{program}` |"
      end)

    [header | rows] |> Enum.join("\n")
  end

  defp generate_failed_details(results) do
    failed = Enum.reject(results, & &1.passed)

    if Enum.empty?(failed) do
      ""
    else
      details =
        Enum.map(failed, fn r ->
          programs_section =
            if r[:all_programs] && length(r.all_programs) > 0 do
              programs =
                Enum.map(r.all_programs, fn {prog, result} ->
                  result_str = format_attempt_result(result)
                  "  - `#{prog}`\n    - Result: #{result_str}"
                end)

              "\n**Programs tried:**\n#{Enum.join(programs, "\n")}"
            else
              ""
            end

          """
          ### #{r.index}. #{r.query}

          - **Error:** #{r.error}
          - **Expected:** #{r.description}
          - **Constraint:** `#{inspect(r.constraint)}`
          - **Attempts:** #{r.attempts}
          #{programs_section}
          """
        end)

      """
      ## Failed Tests

      #{Enum.join(details, "\n---\n")}
      """
    end
  end

  defp generate_all_programs_section(results) do
    """
    ## All Programs Generated

    #{Enum.map_join(results, "\n", fn r -> generate_test_programs(r) end)}
    """
  end

  defp generate_test_programs(r) do
    status = if r.passed, do: "PASS", else: "FAIL"

    programs =
      if r[:all_programs] && length(r.all_programs) > 0 do
        Enum.map_join(r.all_programs, "\n", fn {prog, result} ->
          result_str = format_attempt_result(result)
          "   - `#{prog}` -> #{result_str}"
        end)
      else
        "   (no programs)"
      end

    """
    ### #{r.index}. #{r.query} [#{status}]
    #{programs}
    """
  end

  defp format_timestamp(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  # Load .env file if present
  defp load_dotenv do
    env_file =
      cond do
        File.exists?(".env") -> ".env"
        File.exists?("../.env") -> "../.env"
        true -> nil
      end

    if env_file do
      env_file
      |> Dotenvy.source!()
      |> Enum.each(fn {key, value} -> System.put_env(key, value) end)
    end
  end

  # Ensure at least one API key is set
  defp ensure_api_key! do
    has_key =
      System.get_env("OPENROUTER_API_KEY") ||
        System.get_env("ANTHROPIC_API_KEY") ||
        System.get_env("OPENAI_API_KEY")

    unless has_key do
      IO.puts("""

      ERROR: No API key found!

      Set one of these environment variables:
        - OPENROUTER_API_KEY (recommended, supports many models)
        - ANTHROPIC_API_KEY
        - OPENAI_API_KEY

      You can create a .env file in the demo directory:
        OPENROUTER_API_KEY=sk-or-...

      """)

      System.halt(1)
    end
  end
end
