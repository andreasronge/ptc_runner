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

  The task reads all JSON reports (*.json) from the specified directory
  and generates a combined markdown report with:
  - Comparison table across all models
  - Combined statistics
  - All failures from all models (with traces if available)
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
  Aggregates all JSON reports in the given directory.
  Returns {:ok, report_content} or {:error, reason}.

  Returns an error if there are fewer than 2 valid reports, since a summary
  of a single report isn't useful.
  """
  def aggregate_reports(reports_dir) do
    pattern = Path.join(reports_dir, "*.json")

    case Path.wildcard(pattern) do
      [] ->
        {:error, "No JSON reports found in #{reports_dir}"}

      files ->
        reports =
          files
          |> Enum.map(&parse_json_report/1)
          |> Enum.reject(&is_nil/1)

        cond do
          Enum.empty?(reports) ->
            {:error, "No valid JSON reports found"}

          length(reports) < 2 ->
            {:error, "Need at least 2 reports to aggregate"}

          true ->
            {:ok, generate_aggregate_report(reports)}
        end
    end
  end

  # Parse a single JSON report file
  defp parse_json_report(file_path) do
    filename = Path.basename(file_path)

    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms) do
          {:ok, data} ->
            Map.put(data, :filename, filename)

          {:error, _} ->
            Mix.shell().info("Warning: Could not parse JSON file: #{filename}")
            nil
        end

      {:error, _} ->
        Mix.shell().info("Warning: Could not read file: #{filename}")
        nil
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
    **PtcRunner Version:** #{first[:version] || "unknown"}
    **Git Commit:** #{first[:commit] || "unknown"}
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
        metrics = r[:metrics] || %{}
        stats = r[:stats] || %{}
        model_name = extract_model_name(r[:model] || "unknown")

        passed = metrics[:passed] || 0
        failed = metrics[:failed] || 0
        total = metrics[:total] || 0
        pass_rate = "#{metrics[:pass_rate] || 0.0}%"
        attempts = metrics[:total_attempts] || 0
        avg_attempts = metrics[:avg_attempts_per_test] || 0.0
        duration_ms = metrics[:duration_ms] || 0
        cost = format_cost(stats[:total_cost])

        "| #{model_name} | #{pass_rate} | #{passed}/#{total} | #{failed} | #{attempts} | #{avg_attempts} | #{format_duration(duration_ms)} | #{cost} |"
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
      Enum.sum(Enum.map(reports, fn r -> get_in(r, [:metrics, :total]) || 0 end))

    total_passed =
      Enum.sum(Enum.map(reports, fn r -> get_in(r, [:metrics, :passed]) || 0 end))

    total_failed =
      Enum.sum(Enum.map(reports, fn r -> get_in(r, [:metrics, :failed]) || 0 end))

    total_cost =
      Enum.sum(Enum.map(reports, fn r -> get_in(r, [:stats, :total_cost]) || 0.0 end))

    # Token aggregation
    total_input =
      Enum.sum(Enum.map(reports, fn r -> get_in(r, [:stats, :input_tokens]) || 0 end))

    total_output =
      Enum.sum(Enum.map(reports, fn r -> get_in(r, [:stats, :output_tokens]) || 0 end))

    total_tokens =
      Enum.sum(Enum.map(reports, fn r -> get_in(r, [:stats, :total_tokens]) || 0 end))

    perfect_runs =
      Enum.count(reports, fn r -> (get_in(r, [:metrics, :failed]) || 0) == 0 end)

    overall_pass_rate =
      if total_tests > 0, do: Float.round(total_passed / total_tests * 100, 1), else: 0

    """
    | Metric | Value |
    |--------|-------|
    | Total Tests Across All Models | #{total_tests} |
    | Total Passed | #{total_passed} |
    | Total Failed | #{total_failed} |
    | Overall Pass Rate | #{overall_pass_rate}% |
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

  defp format_number(n) when is_float(n), do: format_number(round(n))
  defp format_number(n), do: to_string(n)

  # Format cost
  defp format_cost(nil), do: "$0.00"
  defp format_cost(cost) when is_float(cost) and cost > 0, do: "$#{Float.round(cost, 4)}"
  defp format_cost(_), do: "$0.00"

  # Format duration
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  # Generate the failures section
  defp generate_failures_section(reports) do
    all_failures =
      reports
      |> Enum.flat_map(fn r ->
        failures = r[:failures] || []

        Enum.map(failures, fn f ->
          f
          |> Map.put(:model, extract_model_name(r[:model] || "unknown"))
          |> Map.put(:report_filename, r[:filename])
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
        |> Enum.group_by(& &1[:query])

      entries =
        failures_by_query
        |> Enum.sort_by(fn {_, failures} -> List.first(failures)[:index] || 0 end)
        |> Enum.map(fn {query, failures} ->
          models = failures |> Enum.map(& &1[:model]) |> Enum.uniq() |> Enum.join(", ")
          first = List.first(failures)
          count = length(failures)
          run_info = if count > 1, do: " (#{count} occurrences)", else: ""

          trace_info = format_trace_info(first[:trace])

          """
          ### #{first[:index] || "?"}. #{query}

          **Models affected:** #{models}#{run_info}
          **Error:** #{first[:error] || "Unknown error"}
          #{trace_info}
          """
        end)
        |> Enum.join("\n---\n\n")

      """
      ## Failures

      #{entries}
      """
    end
  end

  # Format trace information if available
  defp format_trace_info(nil), do: ""
  defp format_trace_info([]), do: ""

  defp format_trace_info(trace) when is_list(trace) do
    turns =
      trace
      |> Enum.map(fn turn ->
        status = if turn[:success], do: "✓", else: "✗"
        program = turn[:program] || "(no program)"
        result = turn[:result] || ""

        """
        - Turn #{turn[:number] || "?"} #{status}: `#{truncate(program, 60)}`
          Result: #{truncate(result, 80)}
        """
      end)
      |> Enum.join("")

    """

    <details>
    <summary>Execution trace (#{length(trace)} turns)</summary>

    #{turns}
    </details>
    """
  end

  defp truncate(str, max_len) when is_binary(str) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  defp truncate(other, _), do: inspect(other)
end
