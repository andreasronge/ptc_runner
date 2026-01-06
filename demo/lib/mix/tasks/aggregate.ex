defmodule Mix.Tasks.Aggregate do
  @moduledoc """
  Aggregates benchmark reports from multiple models into a single summary.

  ## Usage

      mix aggregate [reports_dir] [--output FILE]

  ## Examples

      # Aggregate reports from demo/reports/ (default)
      mix aggregate

      # Aggregate reports from a specific directory
      mix aggregate /path/to/reports

      # Specify output file
      mix aggregate --output summary.md

  The task reads all markdown reports (*.md) from the specified directory,
  parses their summary tables, and generates a combined report with:
  - Comparison table across all models
  - Combined statistics
  - All failures from all models
  """

  use Mix.Task

  @shortdoc "Aggregate benchmark reports into a summary"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [output: :string, help: :boolean],
        aliases: [o: :output, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
      System.halt(0)
    end

    reports_dir = List.first(positional) || "reports"
    output_file = opts[:output] || Path.join(reports_dir, "SUMMARY.md")

    case aggregate_reports(reports_dir) do
      {:ok, report} ->
        File.write!(output_file, report)
        Mix.shell().info("Aggregated report written to: #{output_file}")

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
        System.halt(1)
    end
  end

  @doc """
  Aggregates all markdown reports in the given directory.
  Returns {:ok, report_content} or {:error, reason}.
  """
  def aggregate_reports(reports_dir) do
    pattern = Path.join(reports_dir, "*.md")

    case Path.wildcard(pattern) do
      [] ->
        {:error, "No markdown reports found in #{reports_dir}"}

      files ->
        # Filter out SUMMARY.md if it exists
        files = Enum.reject(files, &String.ends_with?(&1, "SUMMARY.md"))

        if Enum.empty?(files) do
          {:error, "No benchmark reports found (only SUMMARY.md exists)"}
        else
          reports = Enum.map(files, &parse_report/1)
          {:ok, generate_aggregate_report(reports)}
        end
    end
  end

  # Parse a single markdown report file
  defp parse_report(file_path) do
    content = File.read!(file_path)
    filename = Path.basename(file_path)

    %{
      filename: filename,
      model: extract_field(content, "Model"),
      generated: extract_field(content, "Generated"),
      version: extract_field(content, "PtcRunner Version"),
      commit: extract_field(content, "Git Commit"),
      summary: parse_summary_table(content),
      failures: parse_failures(content)
    }
  end

  # Extract a field value from **Field:** value format
  defp extract_field(content, field) do
    case Regex.run(~r/\*\*#{Regex.escape(field)}:\*\*\s*(.+)/, content) do
      [_, value] -> String.trim(value)
      _ -> "unknown"
    end
  end

  # Parse the summary table into a map
  defp parse_summary_table(content) do
    # Match the summary table section
    table_pattern = ~r/## Summary\s+\|[^\n]+\|\s+\|[-|]+\|\s+((?:\|[^\n]+\|\s*)+)/

    case Regex.run(table_pattern, content) do
      [_, table_rows] ->
        table_rows
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn row, acc ->
          case Regex.run(~r/\|\s*([^|]+)\s*\|\s*([^|]+)\s*\|/, row) do
            [_, key, value] ->
              Map.put(acc, normalize_key(key), String.trim(value))

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  # Normalize table keys to atoms
  defp normalize_key(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.to_atom()
  end

  # Parse the failed tests section
  defp parse_failures(content) do
    # Match ## Failed Tests followed by content until next ## heading
    case Regex.run(~r/## Failed Tests\n\n([\s\S]*?)(?=\n## [A-Z])/, content) do
      [_, failures_section] ->
        # Parse individual failures (split by --- separator)
        failures_section
        |> String.split(~r/\n---\n/, trim: true)
        |> Enum.flat_map(&parse_single_failure/1)

      _ ->
        []
    end
  end

  # Parse a single failure entry
  defp parse_single_failure(text) do
    # Match ### followed by index number and query text (may have "(Run N)" suffix)
    case Regex.run(~r/###\s*(\d+)\.\s*(.+?)(?:\s*\(Run \d+\))?\s*\n/s, text) do
      [_, index, query] ->
        error =
          case Regex.run(~r/\*\*Error:\*\*\s*(.+)/, text) do
            [_, e] -> String.trim(e)
            _ -> "unknown"
          end

        [
          %{
            index: String.to_integer(index),
            query: String.trim(query),
            error: error
          }
        ]

      _ ->
        []
    end
  end

  # Generate the aggregated report
  defp generate_aggregate_report(reports) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")

    # Get metadata from first report (they should all have same version/commit)
    first = List.first(reports)

    """
    # Benchmark Aggregate Report

    **Generated:** #{timestamp}
    **PtcRunner Version:** #{first.version}
    **Git Commit:** #{first.commit}
    **Reports Aggregated:** #{length(reports)}

    ## Model Comparison

    #{generate_comparison_table(reports)}

    ## Summary Statistics

    #{generate_summary_stats(reports)}

    #{generate_failures_section(reports)}
    """
  end

  # Generate the comparison table
  defp generate_comparison_table(reports) do
    header = "| Model | Pass Rate | Passed | Failed | Attempts | Avg Attempts | Duration | Cost |"

    separator =
      "|-------|-----------|--------|--------|----------|--------------|----------|------|"

    rows =
      reports
      |> Enum.map(fn r ->
        s = r.summary
        model_name = extract_model_name(r.model)

        "| #{model_name} | #{s[:pass_rate] || "?"} | #{s[:passed] || "?"} | #{s[:failed] || "?"} | #{s[:total_attempts] || "?"} | #{s[:avg_attempts_test] || "?"} | #{s[:duration] || "?"} | #{s[:cost] || "?"} |"
      end)
      |> Enum.join("\n")

    """
    #{header}
    #{separator}
    #{rows}
    """
  end

  # Extract a short model name from the full model string
  defp extract_model_name(model) do
    model
    |> String.replace(~r/^openrouter:/, "")
    |> String.replace(~r/^anthropic\//, "")
    |> String.replace(~r/^google\//, "")
    |> String.replace(~r/^deepseek\//, "")
  end

  # Generate summary statistics
  defp generate_summary_stats(reports) do
    total_tests =
      Enum.sum(
        Enum.map(reports, fn r ->
          parse_int(r.summary[:passed]) + parse_int(r.summary[:failed])
        end)
      )

    total_passed = Enum.sum(Enum.map(reports, fn r -> parse_int(r.summary[:passed]) end))
    total_failed = Enum.sum(Enum.map(reports, fn r -> parse_int(r.summary[:failed]) end))
    total_cost = Enum.sum(Enum.map(reports, fn r -> parse_cost(r.summary[:cost]) end))

    # Token aggregation
    total_input = Enum.sum(Enum.map(reports, fn r -> parse_int(r.summary[:input_tokens]) end))
    total_output = Enum.sum(Enum.map(reports, fn r -> parse_int(r.summary[:output_tokens]) end))
    total_tokens = Enum.sum(Enum.map(reports, fn r -> parse_int(r.summary[:total_tokens]) end))

    perfect_runs = Enum.count(reports, fn r -> parse_int(r.summary[:failed]) == 0 end)

    """
    | Metric | Value |
    |--------|-------|
    | Total Tests Across All Models | #{total_tests} |
    | Total Passed | #{total_passed} |
    | Total Failed | #{total_failed} |
    | Overall Pass Rate | #{if total_tests > 0, do: Float.round(total_passed / total_tests * 100, 1), else: 0}% |
    | Models with 100% Pass Rate | #{perfect_runs}/#{length(reports)} |
    | Input Tokens | #{format_number(total_input)} |
    | Output Tokens | #{format_number(total_output)} |
    | Total Tokens | #{format_number(total_tokens)} |
    | Total Cost | $#{Float.round(total_cost, 4)} |
    """
  end

  # Format large numbers with comma separators
  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  # Generate the failures section
  defp generate_failures_section(reports) do
    all_failures =
      reports
      |> Enum.flat_map(fn r ->
        Enum.map(r.failures, fn f ->
          f
          |> Map.put(:model, extract_model_name(r.model))
          |> Map.put(:filename, r.filename)
        end)
      end)

    if Enum.empty?(all_failures) do
      """
      ## Failures

      No failures across any model.
      """
    else
      # Group by query to deduplicate
      failures_by_query =
        all_failures
        |> Enum.group_by(& &1.query)

      entries =
        failures_by_query
        |> Enum.sort_by(fn {_, failures} -> List.first(failures).index end)
        |> Enum.map(fn {query, failures} ->
          models = failures |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.join(", ")
          first = List.first(failures)
          count = length(failures)
          run_info = if count > 1, do: " (#{count} occurrences)", else: ""

          """
          ### #{first.index}. #{query}

          **Models affected:** #{models}#{run_info}
          **Error:** #{first.error}
          """
        end)
        |> Enum.join("\n---\n\n")

      """
      ## Failures

      #{entries}
      """
    end
  end

  # Helper to parse integer from string like "31/34" -> 31
  defp parse_int(nil), do: 0

  defp parse_int(str) do
    case Regex.run(~r/^(\d+)/, str) do
      [_, num] -> String.to_integer(num)
      _ -> 0
    end
  end

  # Helper to parse cost from string like "$0.0344"
  defp parse_cost(nil), do: 0.0

  defp parse_cost(str) do
    case Regex.run(~r/\$?([\d.]+)/, str) do
      [_, num] -> String.to_float(num)
      _ -> 0.0
    end
  end
end
