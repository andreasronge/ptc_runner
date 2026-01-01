defmodule PtcRunner.Tracer.Timeline do
  @moduledoc """
  Text-based timeline visualization for execution traces.

  Renders traces as ASCII timelines showing relative timing of events.
  Each entry is displayed as a bar proportional to its duration within
  the total execution time.

  ## Example

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{duration_ms: 150}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :tool_call, data: %{duration_ms: 30}})
      iex> tracer = PtcRunner.Tracer.finalize(tracer)
      iex> output = PtcRunner.Tracer.Timeline.render(tracer)
      iex> output =~ "Timeline:"
      true

  Note: Entries should have `duration_ms` in their data map for accurate
  bar rendering. Entries without duration default to 1ms for display.
  """

  alias PtcRunner.Tracer

  @bar_width 60

  @doc """
  Render a timeline visualization as a string.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new() |> PtcRunner.Tracer.finalize()
      iex> output = PtcRunner.Tracer.Timeline.render(tracer)
      iex> output =~ "no entries"
      true

  """
  @spec render(Tracer.t()) :: String.t()
  def render(%Tracer{} = tracer) do
    entries = Tracer.entries(tracer)

    if entries == [] do
      "Timeline: #{short_id(tracer.trace_id)} (no entries)"
    else
      render_with_entries(tracer, entries)
    end
  end

  defp render_with_entries(tracer, entries) do
    total = Tracer.total_duration(tracer)
    start_time = tracer.started_at

    header = "Timeline: #{short_id(tracer.trace_id)} (total: #{total}ms)"
    separator = String.duplicate("=", @bar_width + 20)

    lines =
      Enum.map(entries, fn entry ->
        render_entry(entry, start_time, total)
      end)

    Enum.join([header, separator] ++ lines ++ [separator], "\n")
  end

  defp render_entry(entry, start_time, total) do
    offset_ms = DateTime.diff(entry.timestamp, start_time, :millisecond)
    duration_ms = Map.get(entry.data, :duration_ms, 1)

    bar_start = if total > 0, do: trunc(offset_ms / total * @bar_width), else: 0
    bar_length = if total > 0, do: max(1, trunc(duration_ms / total * @bar_width)), else: 1

    bar = String.duplicate(" ", bar_start) <> String.duplicate("#", bar_length)

    "#{pad_ms(offset_ms)} |#{pad_bar(bar)}| #{entry.type} (#{duration_ms}ms)"
  end

  defp short_id(trace_id), do: String.slice(trace_id, 0, 8) <> "..."

  defp pad_ms(ms) do
    ms_str = "#{ms}ms"
    String.pad_leading(ms_str, 7)
  end

  defp pad_bar(bar), do: String.pad_trailing(bar, @bar_width)
end
