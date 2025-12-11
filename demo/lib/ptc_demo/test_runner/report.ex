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

    ## Summary

    | Metric | Value |
    |--------|-------|
    | Passed | #{summary.passed}/#{summary.total} |
    | Failed | #{summary.failed} |
    | Total Attempts | #{summary.total_attempts} |
    | Avg Attempts/Test | #{if summary.total > 0, do: Float.round(summary.total_attempts / summary.total, 2), else: 0.0} |
    | Duration | #{Base.format_duration(summary.duration_ms)} |
    | Total Runs | #{summary.stats.total_runs} |
    | System Prompt Tokens | #{summary.stats.system_prompt_tokens} |
    | Input Tokens | #{summary.stats.input_tokens} |
    | Output Tokens | #{summary.stats.output_tokens} |
    | Total Tokens | #{summary.stats.total_tokens} |
    | Cost | #{Base.format_cost(summary.stats.total_cost)} |

    ## Results

    #{generate_results_table(summary.results)}

    #{generate_failed_details(summary.results)}

    #{generate_all_programs_section(summary.results)}
    """
  end

  @doc """
  Write a test report to a file.

  Generates a markdown report from the summary and writes it to the specified path.
  Creates the file if it doesn't exist, overwrites if it does.

  ## Parameters

    - `path` - File path to write the report to
    - `summary` - Test summary map
    - `dsl_name` - DSL name string for the report title

  ## Returns

  `:ok` on success, or raises an error if the file cannot be written.

  ## Example

      PtcDemo.TestRunner.Report.write("test_report.md", summary, "Lisp")
  """
  @spec write(String.t(), map(), String.t()) :: :ok
  def write(path, summary, dsl_name) do
    content = generate(summary, dsl_name)
    File.write!(path, content)
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
