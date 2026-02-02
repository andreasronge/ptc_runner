defmodule PtcDemo.TestRunner.Report do
  @moduledoc """
  Markdown report generation for test runs.

  Generates structured markdown reports from test summaries, displaying test results,
  failed test details, and all generated programs for both JSON and Lisp DSLs.

  Reports include:
    - Header with timestamp, model, and data mode
    - Summary table with pass/fail counts and metrics
    - Results table with all test outcomes
    - Failed test details with error information and programs tried
    - Complete list of all programs generated

  The report title is parameterized by DSL name (e.g., "PTC-JSON Test Report", "PTC-Lisp Test Report").
  """

  alias PtcDemo.TestRunner.Base

  @doc """
  Generate a markdown report from a test summary.

  Takes a test summary map (typically built by Base.build_summary) and a DSL name,
  returns a formatted markdown string suitable for writing to a file.

  The summary map should contain:
    - `:timestamp` - DateTime when tests ran
    - `:model` - Model name string
    - `:data_mode` - Data mode atom
    - `:passed` - Count of passed tests
    - `:failed` - Count of failed tests
    - `:total` - Total number of tests
    - `:total_attempts` - Total attempts across all tests
    - `:duration_ms` - Duration in milliseconds
    - `:stats` - Map with `:total_tokens` and `:total_cost`
    - `:results` - List of result maps

  ## Parameters

    - `summary` - Test summary map built by Base.build_summary
    - `dsl_name` - DSL name string (e.g., "JSON", "Lisp") for report title

  ## Returns

  A formatted markdown string ready to be written to a file.

  ## Example

      summary = Base.build_summary(results, start_time, "claude-3-5-haiku", :schema, stats)
      report = PtcDemo.TestRunner.Report.generate(summary, "Lisp")
      File.write!("report.md", report)
  """
  @spec generate(map(), String.t()) :: String.t()
  def generate(summary, dsl_name) do
    """
    # PTC-#{dsl_name} Test Report

    **Generated:** #{format_timestamp(summary.timestamp)}
    **Model:** #{summary.model}
    **Data Mode:** #{summary.data_mode}
    **Return Retries:** #{summary[:retry_turns] || 0}
    **PtcRunner Version:** #{summary[:version] || "unknown"}
    **Git Commit:** #{summary[:commit] || "unknown"}#{if summary[:git_dirty], do: " (uncommitted changes)", else: ""}

    ## Summary

    | Metric | Value |
    |--------|-------|
    | Passed | #{summary.passed}/#{summary.total} |
    | Failed | #{summary.failed} |
    | Pass Rate | #{if summary.total > 0, do: Float.round(summary.passed / summary.total * 100, 1), else: 0.0}% |
    | Total Attempts | #{summary.total_attempts} |
    | Avg Attempts/Test | #{if summary.total > 0, do: Float.round(summary.total_attempts / summary.total, 2), else: 0.0} |
    | Total Retries | #{Map.get(summary, :total_retries, 0)} |
    | Tests with Retries | #{Map.get(summary, :tests_with_retries, 0)} |
    | Duration | #{Base.format_duration(summary.duration_ms)} |
    | Total Runs | #{summary.stats.total_runs} |
    | Input Tokens | #{summary.stats.input_tokens} |
    | Output Tokens | #{summary.stats.output_tokens} |
    | Total Tokens | #{summary.stats.total_tokens} |
    | System Prompt Tokens (est.) | #{summary.stats.system_prompt_tokens} |
    | Cost | #{Base.format_cost(summary.stats.total_cost)} |

    ## Results

    #{generate_results_table(summary.results)}

    #{generate_failed_details(summary.results)}

    #{generate_invalid_clojure_section(summary.results)}

    #{generate_all_programs_section(summary.results)}
    """
  end

  @doc """
  Generate a JSON report from a test summary.

  Creates a machine-readable JSON structure with metrics, stats, and detailed
  failure information including execution traces.

  ## Parameters

    - `summary` - Test summary map built by Base.build_summary
    - `dsl_name` - DSL name string (e.g., "JSON", "Lisp")

  ## Returns

  A map suitable for JSON encoding containing:
    - `:dsl` - DSL name
    - `:generated` - Timestamp string
    - `:model` - Model name
    - `:data_mode` - Data mode string
    - `:version` - PtcRunner version
    - `:commit` - Git commit hash
    - `:metrics` - Pass/fail counts, rates, duration
    - `:stats` - Token usage and cost
    - `:failures` - List of failed tests with traces
  """
  @spec generate_json(map(), String.t()) :: map()
  def generate_json(summary, dsl_name) do
    %{
      dsl: dsl_name,
      generated: format_timestamp(summary.timestamp),
      model: summary.model,
      data_mode: to_string(summary.data_mode),
      retry_turns: summary[:retry_turns] || 0,
      version: summary[:version] || "unknown",
      commit: summary[:commit] || "unknown",
      git_dirty: summary[:git_dirty] || false,
      metrics: %{
        passed: summary.passed,
        failed: summary.failed,
        total: summary.total,
        pass_rate: calculate_pass_rate(summary),
        total_attempts: summary.total_attempts,
        avg_attempts_per_test: calculate_avg_attempts(summary),
        total_retries: Map.get(summary, :total_retries, 0),
        tests_with_retries: Map.get(summary, :tests_with_retries, 0),
        duration_ms: summary.duration_ms
      },
      stats:
        Map.take(summary.stats, [
          :input_tokens,
          :output_tokens,
          :total_tokens,
          :system_prompt_tokens,
          :total_runs,
          :total_cost,
          :requests
        ]),
      failures: extract_failures_with_traces(summary.results)
    }
  end

  defp calculate_pass_rate(%{total: 0}), do: 0.0

  defp calculate_pass_rate(%{passed: passed, total: total}),
    do: Float.round(passed / total * 100, 1)

  defp calculate_avg_attempts(%{total: 0}), do: 0.0

  defp calculate_avg_attempts(%{total_attempts: attempts, total: total}),
    do: Float.round(attempts / total, 2)

  defp extract_failures_with_traces(results) do
    results
    |> Enum.reject(& &1.passed)
    |> Enum.map(fn r ->
      %{
        index: r.index,
        query: r.query,
        error: r[:error] || "Unknown error",
        run: r[:failed_in_run],
        trace: r[:trace]
      }
    end)
  end

  @doc """
  Write a test report to a file.

  Generates both a markdown report (for humans) and a JSON report (for machines)
  from the summary and writes them to the specified path.
  Creates the files if they don't exist, overwrites if they do.

  Relative paths are automatically placed in the `reports/` directory and the
  directory is created if it doesn't exist. Absolute paths are used as-is.

  ## Parameters

    - `path` - File path to write the report to (relative paths go to reports/)
    - `summary` - Test summary map
    - `dsl_name` - DSL name string for the report title

  ## Returns

  The resolved markdown file path where the report was written.
  A corresponding JSON file is also written with the same base name.

  ## Example

      # Writes to reports/test_report.md and reports/test_report.json
      PtcDemo.TestRunner.Report.write("test_report.md", summary, "Lisp")

      # Writes to /tmp/report.md and /tmp/report.json
      PtcDemo.TestRunner.Report.write("/tmp/report.md", summary, "JSON")
  """
  @default_reports_dir "reports"

  @spec write(String.t(), map(), String.t()) :: String.t()
  def write(path, summary, dsl_name) do
    md_path = resolve_report_path(path)
    ensure_report_dir!(md_path)

    # Write markdown report
    File.write!(md_path, generate(summary, dsl_name))

    # Write JSON report alongside markdown
    json_path = String.replace_suffix(md_path, ".md", ".json")
    json_content = summary |> generate_json(dsl_name) |> Jason.encode!(pretty: true)
    File.write!(json_path, json_content)

    md_path
  end

  # Resolves a report path - relative paths are placed in the reports/ directory
  defp resolve_report_path(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(@default_reports_dir, path)
    end
  end

  # Ensures the parent directory exists for a given file path
  defp ensure_report_dir!(path) do
    dir = Path.dirname(path)

    unless File.dir?(dir) do
      File.mkdir_p!(dir)
    end
  end

  # Private helpers

  defp generate_results_table(results) do
    header =
      "| # | Query | Status | Attempts | Program |\n|---|-------|--------|----------|---------|"

    rows =
      Enum.map(results, fn r ->
        status = if r.passed, do: "PASS", else: "FAIL"
        program = Base.truncate(r[:program] || "-", 40)
        query = Base.truncate(r.query, 40)
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
                  result_str = Base.format_attempt_result(result)
                  "  - `#{prog}`\n    - Result: #{result_str}"
                end)

              "\n**Programs tried:**\n#{Enum.join(programs, "\n")}"
            else
              ""
            end

          run_info = if r[:failed_in_run], do: " (Run #{r.failed_in_run})", else: ""

          """
          ### #{r.index}. #{r.query}#{run_info}

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

  defp generate_invalid_clojure_section(results) do
    # Find programs that passed PTC execution but failed Clojure validation
    invalid =
      results
      |> Enum.filter(fn r -> r.passed and r[:clojure_valid] == false end)

    if Enum.empty?(invalid) do
      ""
    else
      entries =
        Enum.map(invalid, fn r ->
          """
          ### #{r.index}. #{r.query}

          **Program:**
          ```clojure
          #{r[:program] || "(no program)"}
          ```

          **Clojure error:** #{r[:clojure_error] || "Unknown error"}
          """
        end)

      """
      ## Clojure Validation Failures

      The following programs executed successfully in PTC-Lisp but failed Clojure validation:

      #{Enum.join(entries, "\n---\n")}
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
          result_str = Base.format_attempt_result(result)
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
end
