defmodule PtcRunner.CLIProgress.Format do
  @moduledoc false

  @spec interactive(map(), pos_integer()) :: binary()
  def interactive(frame, width) do
    primary = [phase(frame) <> " " <> duration(frame.elapsed_ms), agent(frame), remaining(frame)]
    optional = [llm(frame), evaluations(frame), workers(frame), spend(frame)]

    Enum.reduce(optional, Enum.reject(primary, &is_nil/1), fn segment, segments ->
      candidate = Enum.reject(segments ++ [segment], &is_nil/1)
      if String.length(Enum.join(candidate, " | ")) <= width, do: candidate, else: segments
    end)
    |> Enum.join(" | ")
    |> String.slice(0, width)
  end

  @spec milestone(map(), binary()) :: binary()
  def milestone(frame, event) do
    details =
      case event do
        "still running" -> [llm_calls(frame), remaining(frame)]
        _terminal -> [llm_calls(frame), spend(frame)]
      end

    "[#{duration(frame.elapsed_ms)}] " <>
      Enum.join(Enum.reject([event | details], &is_nil/1), " · ")
  end

  defp phase(%{phase: phase}) when phase in ["ok", "completed"], do: "completed"
  defp phase(%{phase: phase}) when phase in ["error", "failed"], do: "failed"
  defp phase(%{phase: phase}) when is_binary(phase), do: phase
  defp phase(_), do: "running"

  defp agent(%{agents: agents}) when is_list(agents) and length(agents) > 1,
    do: "#{length(agents)} agents active"

  defp agent(%{agents: [%{turn: turn, max_turns: max}]}), do: "agent #{turn}/#{max}"
  defp agent(_), do: nil

  defp remaining(%{remaining_ms: ms}) when is_integer(ms) and ms >= 0,
    do: "#{div(ms + 999, 1_000)}s left"

  defp remaining(_), do: nil

  defp llm(frame) do
    case llm_count(frame) do
      0 -> nil
      count -> "llm #{count}"
    end
  end

  defp llm_calls(frame) do
    case llm_count(frame) do
      0 -> nil
      1 -> "1 LLM call"
      count -> "#{count} LLM calls"
    end
  end

  defp llm_count(%{usage: %{capability_calls: calls}}) when is_map(calls) do
    Enum.reduce(calls, 0, fn
      {name, count}, total when is_integer(count) ->
        if to_string(name) == "llm-request", do: total + count, else: total

      {_scope, nested}, total when is_map(nested) ->
        total + llm_count(%{usage: %{capability_calls: nested}})

      _entry, total ->
        total
    end)
  rescue
    _ -> 0
  end

  defp llm_count(_), do: 0

  defp evaluations(%{
         usage: %{subordinate_evaluations: used},
         limits: %{subordinate_evaluations: max}
       }),
       do: "evals #{used}/#{max}"

  defp evaluations(_), do: nil
  defp workers(%{parallel: %{held: held, capacity: cap}}), do: "workers #{held}/#{cap}"
  defp workers(_), do: nil

  defp spend(%{
         usage: %{
           llm_spend: %{
             "state" => "available",
             "total_cost" => %{"currency" => "USD", "microunits" => microunits}
           }
         }
       })
       when is_integer(microunits) and microunits >= 0 do
    whole = div(microunits, 1_000_000)

    fraction =
      microunits
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")

    if fraction == "", do: "$#{whole}", else: "$#{whole}.#{fraction}"
  end

  defp spend(_), do: nil

  defp duration(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1_000)
    :io_lib.format("~2..0B:~2..0B", [div(seconds, 60), rem(seconds, 60)]) |> IO.iodata_to_binary()
  end

  defp duration(_), do: "00:00"
end
