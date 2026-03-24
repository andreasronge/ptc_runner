defmodule PtcDemo.Planning.Report do
  @moduledoc """
  Generates comparison reports for planning benchmark experiments.
  """

  alias PtcRunner.Metrics.{TurnAnalysis, Statistics}

  @doc """
  Print a side-by-side comparison table to console.
  """
  def print_summary(run_results, conditions) do
    by_condition = Enum.group_by(run_results, & &1.condition)

    label_width = 24
    col_width = 14

    # Header
    IO.puts("")
    IO.write(String.pad_trailing("", label_width))
    for c <- conditions, do: IO.write(String.pad_leading(Atom.to_string(c), col_width))
    IO.puts("")
    IO.puts(String.duplicate("-", label_width + col_width * length(conditions)))

    # Compute aggregates per condition
    aggregates =
      for c <- conditions do
        name = Atom.to_string(c)
        results = Map.get(by_condition, name, [])
        metrics_list = Enum.map(results, & &1.metrics)
        agg = TurnAnalysis.aggregate(metrics_list)
        {name, agg, results}
      end

    rows = [
      {"Pass rate", fn {_, agg, _} -> format_pct(agg.pass_rate) end},
      {"  95% CI",
       fn {_, _, results} ->
         passed = Enum.count(results, & &1.passed?)
         total = length(results)
         {lo, hi} = Statistics.wilson_interval(passed, max(total, 1))
         "[#{format_pct(lo)}, #{format_pct(hi)}]"
       end},
      {"Mean turns (pass)",
       fn {_, agg, _} ->
         if agg.mean_turns_on_pass, do: format_float(agg.mean_turns_on_pass), else: "-"
       end},
      {"Mean tokens", fn {_, agg, _} -> format_int(agg.mean_total_tokens) end},
      {"  Planner tokens",
       fn {_, _, results} ->
         tokens = results |> Enum.map(& &1.planner_tokens) |> Enum.reject(&is_nil/1)
         if tokens != [], do: format_int(Enum.sum(tokens) / length(tokens)), else: "-"
       end},
      {"  Executor tokens",
       fn {_, _, results} ->
         tokens = results |> Enum.map(& &1.executor_tokens) |> Enum.reject(&is_nil/1)
         if tokens != [], do: format_int(Enum.sum(tokens) / length(tokens)), else: "-"
       end},
      {"Plan overhead",
       fn {_, _, results} ->
         planned =
           results
           |> Enum.filter(&(&1.planner_tokens != nil and &1.executor_tokens != nil))

         if planned != [] do
           total_planner = planned |> Enum.map(& &1.planner_tokens) |> Enum.sum()

           total_all =
             planned
             |> Enum.map(&((&1.planner_tokens || 0) + (&1.executor_tokens || 0)))
             |> Enum.sum()

           if total_all > 0,
             do: format_pct(total_planner / total_all),
             else: "-"
         else
           "-"
         end
       end},
      {"Mean tool calls",
       fn {_, _, results} ->
         counts = Enum.map(results, & &1.tool_call_count)
         if counts != [], do: format_float(Enum.sum(counts) / length(counts)), else: "-"
       end},
      {"Mean plan steps",
       fn {_, _, results} ->
         steps =
           results
           |> Enum.map(& &1.plan_steps)
           |> Enum.reject(&is_nil/1)
           |> Enum.map(&length/1)

         if steps != [], do: format_float(Enum.sum(steps) / length(steps)), else: "-"
       end},
      {"Budget exhausted", fn {_, agg, _} -> format_pct(agg.budget_exhausted_rate) end}
    ]

    for {label, value_fn} <- rows do
      IO.write(String.pad_trailing(label, label_width))

      for agg_data <- aggregates do
        IO.write(String.pad_leading(value_fn.(agg_data), col_width))
      end

      IO.puts("")
    end

    # Statistical comparison vs first condition
    if length(conditions) > 1 do
      IO.puts("")
      first_name = Atom.to_string(hd(conditions))
      IO.puts("Statistical comparison (vs #{first_name}):")

      {_, _, baseline_results} = hd(aggregates)
      baseline_pass = Enum.count(baseline_results, & &1.passed?)
      baseline_fail = length(baseline_results) - baseline_pass

      for {name, _agg, results} <- tl(aggregates) do
        pass = Enum.count(results, & &1.passed?)
        fail = length(results) - pass
        p = Statistics.fisher_exact_p(baseline_pass, baseline_fail, pass, fail)
        sig = if p < 0.05, do: "*", else: ""
        IO.puts("  #{name}: p=#{Float.round(p, 3)}#{sig}")
      end
    end

    IO.puts("")
    :ok
  end

  @doc """
  Generate a JSON-serializable map from results.
  """
  def to_json(run_results, conditions) do
    by_condition = Enum.group_by(run_results, & &1.condition)

    condition_summaries =
      for c <- conditions do
        name = Atom.to_string(c)
        results = Map.get(by_condition, name, [])
        metrics_list = Enum.map(results, & &1.metrics)
        agg = TurnAnalysis.aggregate(metrics_list)

        passed = Enum.count(results, & &1.passed?)
        total = length(results)

        {ci_lo, ci_hi} =
          if total > 0,
            do: Statistics.wilson_interval(passed, total),
            else: {0.0, 0.0}

        %{
          condition: name,
          total_runs: total,
          passed: passed,
          failed: total - passed,
          aggregate_metrics: agg,
          confidence_interval: %{lower: ci_lo, upper: ci_hi}
        }
      end

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      conditions: condition_summaries,
      raw_results:
        Enum.map(run_results, fn r ->
          %{
            condition: r.condition,
            test_index: r.test_index,
            run: r.run,
            passed: r.passed?,
            metrics: r.metrics,
            duration_ms: r.duration_ms,
            tool_call_count: r.tool_call_count,
            plan_steps: r.plan_steps,
            planner_tokens: r.planner_tokens,
            executor_tokens: r.executor_tokens
          }
        end)
    }
  end

  defp format_pct(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_pct(_), do: "-"

  defp format_float(value) when is_number(value), do: "#{Float.round(value * 1.0, 1)}"
  defp format_float(_), do: "-"

  defp format_int(value) when is_number(value), do: "#{round(value)}"
  defp format_int(_), do: "-"
end
