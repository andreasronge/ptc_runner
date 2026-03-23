defmodule PtcDemo.Ablation.Report do
  @moduledoc """
  Generates comparison reports from ablation experiment results.
  """

  alias PtcRunner.Metrics.{TurnAnalysis, Statistics}

  @doc """
  Print a side-by-side comparison table to console.
  """
  def print_summary(run_results, variants) do
    # Group results by variant
    by_variant = Enum.group_by(run_results, & &1.variant)

    # Column width
    label_width = 24
    col_width = 14

    # Header
    IO.puts("")
    IO.write(String.pad_trailing("", label_width))
    for v <- variants, do: IO.write(String.pad_leading(v.name, col_width))
    IO.puts("")
    IO.puts(String.duplicate("-", label_width + col_width * length(variants)))

    # For each variant, compute aggregated metrics
    aggregates =
      for v <- variants do
        results = Map.get(by_variant, v.name, [])
        metrics_list = Enum.map(results, & &1.metrics)
        agg = TurnAnalysis.aggregate(metrics_list)
        {v.name, agg, results}
      end

    # Rows
    rows = [
      {"Pass rate", fn {_, agg, _} -> format_pct(agg.pass_rate) end},
      {"  95% CI",
       fn {_, _, results} ->
         passed = Enum.count(results, & &1.passed?)
         total = length(results)
         {lo, hi} = Statistics.wilson_interval(passed, max(total, 1))
         "[#{format_pct(lo)}, #{format_pct(hi)}]"
       end},
      {"1st turn valid", fn {_, agg, _} -> format_pct(agg.first_turn_validity_rate) end},
      {"Parse failure rate", fn {_, agg, _} -> format_float(agg.mean_parse_failure_rate) end},
      {"No code rate", fn {_, agg, _} -> format_float(agg.mean_no_code_rate) end},
      {"Multi-block rate", fn {_, agg, _} -> format_float(agg.mean_multi_code_block_rate) end},
      {"Mean turns (pass)",
       fn {_, agg, _} ->
         if agg.mean_turns_on_pass, do: format_float(agg.mean_turns_on_pass), else: "-"
       end},
      {"Budget exhausted", fn {_, agg, _} -> format_pct(agg.budget_exhausted_rate) end},
      {"Salvage rate", fn {_, agg, _} -> format_pct(agg.recoverable_error_salvage_rate) end},
      {"Mean tokens", fn {_, agg, _} -> format_int(agg.mean_total_tokens) end},
      {"Tokens/pass",
       fn {_, agg, _} ->
         if agg.mean_total_tokens_on_pass,
           do: format_int(agg.mean_total_tokens_on_pass),
           else: "-"
       end}
    ]

    for {label, value_fn} <- rows do
      IO.write(String.pad_trailing(label, label_width))

      for agg_data <- aggregates do
        IO.write(String.pad_leading(value_fn.(agg_data), col_width))
      end

      IO.puts("")
    end

    # Statistical comparison vs first variant
    if length(variants) > 1 do
      IO.puts("")
      IO.puts("Statistical comparison (vs #{hd(variants).name}):")

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

      # Sample size recommendation
      total = length(baseline_results)

      if total > 0 do
        p_hat = baseline_pass / total
        p_hat = if p_hat == 0.0, do: 0.01, else: if(p_hat == 1.0, do: 0.99, else: p_hat)
        p2 = min(p_hat + 0.05, 0.99)

        if p_hat != p2 do
          n = Statistics.sample_size_for_two_proportions(p_hat, p2)
          IO.puts("  Recommended N to detect 5pp difference: #{n} per variant")
        end
      end
    end

    IO.puts("")
    :ok
  end

  @doc """
  Generate a JSON-serializable map from results.
  """
  def to_json(run_results, variants) do
    by_variant = Enum.group_by(run_results, & &1.variant)

    variant_summaries =
      for v <- variants do
        results = Map.get(by_variant, v.name, [])
        metrics_list = Enum.map(results, & &1.metrics)
        agg = TurnAnalysis.aggregate(metrics_list)

        passed = Enum.count(results, & &1.passed?)
        total = length(results)

        {ci_lo, ci_hi} =
          if total > 0 do
            Statistics.wilson_interval(passed, total)
          else
            {0.0, 0.0}
          end

        %{
          name: v.name,
          agent_overrides: inspect(Map.get(v, :agent_overrides)),
          total_runs: total,
          passed: passed,
          failed: total - passed,
          aggregate_metrics: agg,
          confidence_interval: %{lower: ci_lo, upper: ci_hi}
        }
      end

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      variants: variant_summaries,
      raw_results:
        Enum.map(run_results, fn r ->
          %{
            variant: r.variant,
            test_index: r.test_index,
            run: r.run,
            passed: r.passed?,
            metrics: r.metrics,
            duration_ms: r.duration_ms
          }
        end)
    }
  end

  defp format_pct(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_pct(_), do: "-"

  defp format_float(value) when is_float(value), do: "#{Float.round(value, 3)}"
  defp format_float(_), do: "-"

  defp format_int(value) when is_number(value), do: "#{round(value)}"
  defp format_int(_), do: "-"
end
