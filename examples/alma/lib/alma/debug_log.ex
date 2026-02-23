defmodule Alma.DebugLog do
  @moduledoc """
  Converts archive entries with runtime logs into greppable text for the debug agent.

  The output format is designed for `grep`/`grep-n` pattern matching, with
  consistent line prefixes (`[recall]`, `[mem-update]`) and structured tool call
  formatting. Falls back gracefully when `:runtime_logs` is missing (old entries).
  """

  @default_max_episodes 6
  @default_max_result_chars 200

  @doc """
  Formats parent archive entries into a greppable debug log string.

  Options:
  - `max_episodes` — max episodes per design (default: #{@default_max_episodes})
  - `max_result_chars` — max chars for tool result display (default: #{@default_max_result_chars})
  """
  @spec format_parents([map()], keyword()) :: String.t()
  def format_parents(parents, opts \\ []) do
    max_episodes = Keyword.get(opts, :max_episodes, @default_max_episodes)
    max_result_chars = Keyword.get(opts, :max_result_chars, @default_max_result_chars)

    parents
    |> Enum.map(&format_design(&1, max_episodes, max_result_chars))
    |> Enum.join("\n\n")
  end

  @doc """
  Formats a store summary section from final memory.
  """
  @spec format_stores(map()) :: String.t()
  def format_stores(memory) when is_map(memory) do
    vs = Map.get(memory, :__vector_store)
    gs = Map.get(memory, :__graph_store)

    lines = ["=== STORES after collection ==="]

    lines =
      if vs do
        entries = vs.entries || %{}
        count = map_size(entries)

        collections =
          entries
          |> Map.values()
          |> Enum.map(& &1.collection)
          |> Enum.uniq()
          |> Enum.sort()

        summary = [
          "Vector store: #{count} entries (collections: #{Enum.join(collections, ", ")})"
        ]

        # Include 5 most recent entries as a snapshot for content verification
        snapshot =
          entries
          |> Enum.sort_by(fn {id, _} -> id end, :desc)
          |> Enum.take(5)
          |> Enum.map(fn {id, e} ->
            text = String.slice(e.text || "", 0, 80)
            "  [#{id}] (#{e.collection}) #{text}"
          end)

        lines ++ summary ++ snapshot
      else
        lines ++ ["Vector store: empty"]
      end

    lines =
      if gs && is_map(gs) && map_size(gs) > 0 do
        nodes = map_size(gs)

        edges =
          gs
          |> Map.values()
          |> Enum.map(&MapSet.size/1)
          |> Enum.sum()
          |> div(2)

        node_list =
          gs
          |> Map.keys()
          |> Enum.sort()
          |> Enum.take(20)
          |> Enum.join(", ")

        lines ++ ["Graph store: #{nodes} nodes, #{edges} edges", "  Nodes: #{node_list}"]
      else
        lines ++ ["Graph store: empty"]
      end

    Enum.join(lines, "\n")
  end

  def format_stores(_), do: ""

  # --- Private ---

  defp format_design(parent, max_episodes, max_result_chars) do
    name = Map.get(parent.design, :name, "unknown")
    score = Float.round(parent.score * 1.0, 2)
    trajectories = Map.get(parent, :trajectories, [])

    header = "=== DESIGN: #{name} (score: #{score}) ==="

    episodes =
      trajectories
      |> select_episodes(max_episodes)
      |> Enum.with_index(1)
      |> Enum.map(fn {result, idx} ->
        format_episode(result, idx, max_result_chars)
      end)

    store_section =
      case Map.get(parent, :final_memory) do
        memory when is_map(memory) -> "\n" <> format_stores(memory)
        _ -> ""
      end

    sim_summary = format_aggregate_similarity(trajectories)

    Enum.join([header | episodes], "\n") <> store_section <> sim_summary
  end

  defp select_episodes(results, max_episodes) when length(results) <= max_episodes, do: results

  defp select_episodes(results, max_episodes) do
    successes =
      results
      |> Enum.filter(& &1.success?)
      |> Enum.sort_by(& &1.steps, :asc)

    failures =
      results
      |> Enum.reject(& &1.success?)
      |> Enum.sort_by(& &1.steps, :desc)

    # Best success + worst failure first, then fill remaining
    candidates = Enum.take(successes, 1) ++ Enum.take(failures, 1)
    remaining = max_episodes - length(candidates)

    if remaining > 0 do
      extra =
        (Enum.drop(successes, 1) ++ Enum.drop(failures, 1))
        |> Enum.take(remaining)

      candidates ++ extra
    else
      Enum.take(candidates, max_episodes)
    end
  end

  defp format_episode(result, idx, max_result_chars) do
    status = if result.success?, do: "SUCCESS", else: "FAILED"
    steps = Map.get(result, :steps, 0)
    runtime_logs = Map.get(result, :runtime_logs, [])

    header = "--- EPISODE #{idx}: #{status} (#{steps} steps) ---"

    # Task-level error (e.g. timeout, crash)
    task_error =
      case Map.get(result, :error) do
        nil -> []
        err -> ["[task] ERROR: #{truncate(to_string(err), max_result_chars)}"]
      end

    log_lines =
      if runtime_logs == [] do
        []
      else
        Enum.flat_map(runtime_logs, &format_runtime_log(&1, max_result_chars))
      end

    # Task agent actions from observation_log
    task_actions =
      (Map.get(result, :observation_log) || [])
      |> Enum.map(fn obs ->
        action = Map.get(obs, :action, "?")
        msg = extract_action_message(obs, max_result_chars)
        "[task] #{action}: #{msg}"
      end)

    Enum.join([header | task_error] ++ log_lines ++ task_actions, "\n")
  end

  defp format_runtime_log(
         %{phase: phase, prints: prints, tool_calls: tool_calls} = log,
         max_result_chars
       ) do
    phase_tag = phase_tag(phase)

    error_lines =
      case Map.get(log, :error) do
        nil -> []
        err -> ["[#{phase_tag}] ERROR: #{truncate(to_string(err), max_result_chars)}"]
      end

    print_lines =
      Enum.map(prints || [], fn p ->
        "[#{phase_tag}] PRINT: #{truncate(to_string(p), max_result_chars)}"
      end)

    tool_lines =
      Enum.map(tool_calls || [], fn tc ->
        args_str = format_args(tc.args)
        result_str = format_result(tc.result, max_result_chars)
        "[#{phase_tag}] TOOL #{tc.name}: #{args_str} -> #{result_str}"
      end)

    return_line =
      case Map.get(log, :return) do
        nil ->
          []

        ret ->
          [
            "[#{phase_tag}] RETURN: #{truncate(inspect(ret, limit: 10, printable_limit: max_result_chars), max_result_chars)}"
          ]
      end

    sim_lines = format_similarity_stats(log, phase_tag)

    error_lines ++ print_lines ++ tool_lines ++ sim_lines ++ return_line
  end

  defp format_runtime_log(%{phase: phase}, _max_result_chars) do
    ["[#{phase_tag(phase)}] ERROR: incomplete log"]
  end

  # Format per-query similarity stats lines for a single runtime log.
  defp format_similarity_stats(%{similarity_stats: stats, embed_mode: embed_mode}, phase_tag)
       when is_list(stats) and stats != [] do
    find_stats = Enum.filter(stats, &(&1.op == :find))

    if find_stats == [] do
      []
    else
      query_lines =
        Enum.map(find_stats, fn %{query: query, scores: scores, embed_ms: embed_ms} ->
          {top, spread, quality} = score_summary(scores)

          "[#{phase_tag}] SIMILARITY: query=#{inspect(query)} " <>
            "top=#{format_score(top)} spread=#{format_score(spread)} " <>
            "k=#{length(scores)} #{quality} embed_ms=#{embed_ms}"
        end)

      # Aggregate line
      all_tops = Enum.map(find_stats, fn s -> score_top(s.scores) end)
      mean_top = safe_mean(all_tops)
      min_top = Enum.min(all_tops, fn -> 0.0 end)
      low_count = Enum.count(all_tops, &(&1 < 0.5))
      total_embed_ms = find_stats |> Enum.map(& &1.embed_ms) |> Enum.sum()
      mode_str = if embed_mode, do: " embed=#{embed_mode}", else: ""

      agg_line =
        "[#{phase_tag}] SIM_SUMMARY: #{length(find_stats)} queries " <>
          "mean_top=#{format_score(mean_top)} min_top=#{format_score(min_top)} " <>
          "low_quality=#{low_count} total_embed_ms=#{total_embed_ms}#{mode_str}"

      query_lines ++ [agg_line]
    end
  end

  defp format_similarity_stats(_, _), do: []

  defp score_top(scores) when scores == [], do: 0.0
  defp score_top(scores), do: Enum.max(scores)

  defp score_summary([]), do: {0.0, 0.0, "NO_RESULTS"}

  defp score_summary(scores) do
    top = Enum.max(scores)
    bottom = Enum.min(scores)
    spread = top - bottom

    quality =
      cond do
        top < 0.3 -> "LOW_QUALITY"
        top < 0.5 -> "WEAK"
        spread < 0.1 -> "NO_DISCRIMINATION"
        true -> "OK"
      end

    {top, spread, quality}
  end

  defp safe_mean([]), do: 0.0
  defp safe_mean(values), do: Enum.sum(values) / length(values)

  defp format_score(f), do: :erlang.float_to_binary(f * 1.0, decimals: 3)

  # Aggregate similarity stats across all episodes for the design summary.
  defp format_aggregate_similarity(trajectories) do
    all_stats =
      trajectories
      |> Enum.flat_map(fn result ->
        (Map.get(result, :runtime_logs) || [])
        |> Enum.flat_map(fn log ->
          (Map.get(log, :similarity_stats) || [])
          |> Enum.filter(&(&1.op == :find))
        end)
      end)

    if all_stats == [] do
      ""
    else
      all_tops = Enum.map(all_stats, fn s -> score_top(s.scores) end)
      mean_top = safe_mean(all_tops)
      min_top = Enum.min(all_tops, fn -> 0.0 end)
      max_top = Enum.max(all_tops, fn -> 0.0 end)
      low_count = Enum.count(all_tops, &(&1 < 0.5))
      no_result_count = Enum.count(all_stats, &(&1.scores == []))
      total_embed_ms = all_stats |> Enum.map(& &1.embed_ms) |> Enum.sum()
      mean_embed_ms = if all_stats != [], do: div(total_embed_ms, length(all_stats)), else: 0

      # Get embed mode from the first runtime log that has it
      embed_mode_str =
        trajectories
        |> Enum.find_value("unknown", fn result ->
          (Map.get(result, :runtime_logs) || [])
          |> Enum.find_value(fn log -> Map.get(log, :embed_mode) end)
        end)

      lines = [
        "\n=== SIMILARITY QUALITY ===",
        "Embed mode: #{embed_mode_str}",
        "Total queries: #{length(all_stats)} (#{no_result_count} empty)",
        "Top scores: mean=#{format_score(mean_top)} min=#{format_score(min_top)} max=#{format_score(max_top)}",
        "Low quality (top < 0.5): #{low_count}/#{length(all_stats)}",
        "Mean embed latency: #{mean_embed_ms}ms"
      ]

      "\n" <> Enum.join(lines, "\n")
    end
  end

  defp extract_action_message(%{result: result}, max_chars) when is_map(result) do
    # Prefer :message field (GraphWorld actions), fall back to inspect
    case Map.get(result, :message) do
      msg when is_binary(msg) -> truncate(msg, max_chars)
      _ -> truncate(inspect(result, limit: 5, printable_limit: max_chars), max_chars)
    end
  end

  defp extract_action_message(%{result: result}, max_chars) do
    truncate(inspect(result, limit: 5, printable_limit: max_chars), max_chars)
  end

  defp extract_action_message(_, _), do: "?"

  defp phase_tag(:recall), do: "recall"
  defp phase_tag(:"mem-update"), do: "mem-update"
  defp phase_tag(other), do: to_string(other)

  defp format_args(args) when is_map(args) do
    args
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v, limit: 5, printable_limit: 60)}" end)
  end

  defp format_args(args), do: inspect(args, limit: 5, printable_limit: 60)

  defp format_result(result, max_chars) when is_binary(result) do
    truncate(result, max_chars)
  end

  defp format_result(result, max_chars) do
    result
    |> inspect(limit: 10, printable_limit: max_chars)
    |> truncate(max_chars)
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."
end
