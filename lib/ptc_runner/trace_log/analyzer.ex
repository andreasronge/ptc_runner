defmodule PtcRunner.TraceLog.Analyzer do
  @moduledoc """
  Offline analysis of trace log files.

  Provides functions to load, filter, summarize, and visualize trace data
  captured by `PtcRunner.TraceLog`.

  ## Example

      events = TraceLog.Analyzer.load("trace.jsonl")
      summary = TraceLog.Analyzer.summary(events)

      # Filter to specific event types
      llm_events = TraceLog.Analyzer.filter(events, type: "llm")

      # Find slowest operations
      slowest = TraceLog.Analyzer.slowest(events, 5)

      # Print timeline
      TraceLog.Analyzer.print_timeline(events)
  """

  @doc """
  Loads events from a JSONL trace file.

  Returns a list of event maps in chronological order.

  ## Examples

      events = Analyzer.load("trace.jsonl")
      length(events)  #=> 42
  """
  @spec load(String.t()) :: [map()]
  def load(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Creates a summary of the trace execution.

  Extracts key metrics from the trace including duration, turns, token counts,
  and call counts for LLM and tool operations.

  ## Examples

      summary = Analyzer.summary(events)
      summary.duration_ms  #=> 1234
      summary.turns        #=> 3
      summary.llm_calls    #=> 3
      summary.tool_calls   #=> 5
  """
  @spec summary(list(map())) :: map()
  def summary(events) do
    run_stop = find_event(events, "run.stop")

    %{
      duration_ms: run_stop && run_stop["duration_ms"],
      turns: extract_turns(run_stop),
      llm_calls: count_events(events, "llm.stop"),
      tool_calls: count_events(events, "tool.stop"),
      tokens: extract_tokens(run_stop),
      status: extract_status(run_stop)
    }
  end

  @doc """
  Filters events by various criteria.

  ## Options

    * `:type` - Event type prefix (e.g., "llm", "tool", "run")
    * `:span_id` - Filter by span ID
    * `:min_duration_ms` - Minimum duration in milliseconds

  ## Examples

      # All LLM events
      llm_events = Analyzer.filter(events, type: "llm")

      # All events taking > 100ms
      slow = Analyzer.filter(events, min_duration_ms: 100)

      # Events in a specific span
      span_events = Analyzer.filter(events, span_id: "abc123")
  """
  @spec filter(list(map()), keyword()) :: list(map())
  def filter(events, criteria) do
    Enum.filter(events, fn event ->
      matches_criteria?(event, criteria)
    end)
  end

  @doc """
  Returns the N slowest events by duration.

  Only includes events that have a `duration_ms` field (typically stop events).

  ## Examples

      slowest = Analyzer.slowest(events, 5)
      Enum.map(slowest, & &1["event"])  #=> ["llm.stop", "tool.stop", ...]
  """
  @spec slowest(list(map()), pos_integer()) :: list(map())
  def slowest(events, n \\ 5) do
    events
    |> Enum.filter(&Map.has_key?(&1, "duration_ms"))
    |> Enum.sort_by(& &1["duration_ms"], :desc)
    |> Enum.take(n)
  end

  @doc """
  Builds a span hierarchy tree from events.

  Groups events by span_id and constructs parent-child relationships
  using parent_span_id.

  ## Examples

      tree = Analyzer.build_tree(events)
      # Returns nested structure with children
  """
  @spec build_tree(list(map())) :: list(map())
  def build_tree(events) do
    # Group events by span_id
    by_span =
      events
      |> Enum.filter(&Map.has_key?(&1, "span_id"))
      |> Enum.group_by(& &1["span_id"])

    # Build nodes with start/stop info
    nodes =
      Map.new(by_span, fn {span_id, span_events} ->
        start_event = Enum.find(span_events, &String.ends_with?(&1["event"], ".start"))
        stop_event = Enum.find(span_events, &String.ends_with?(&1["event"], ".stop"))

        node = %{
          span_id: span_id,
          event_type: extract_event_type(start_event || stop_event),
          parent_span_id: (start_event || stop_event)["parent_span_id"],
          start: start_event,
          stop: stop_event,
          duration_ms: stop_event && stop_event["duration_ms"],
          children: []
        }

        {span_id, node}
      end)

    # Build tree by linking children to parents
    root_nodes =
      Enum.reduce(nodes, nodes, fn {span_id, node}, acc ->
        case node.parent_span_id do
          nil ->
            acc

          parent_id ->
            case Map.get(acc, parent_id) do
              nil ->
                acc

              parent ->
                updated_parent = %{parent | children: [span_id | parent.children]}
                Map.put(acc, parent_id, updated_parent)
            end
        end
      end)

    # Find root nodes (no parent)
    root_nodes
    |> Map.values()
    |> Enum.filter(&is_nil(&1.parent_span_id))
    |> Enum.map(&expand_children(&1, root_nodes))
  end

  @doc """
  Prints an ASCII timeline visualization of events.

  Shows the sequence of events with timing information.

  ## Examples

      Analyzer.print_timeline(events)
      # Outputs:
      # [0ms] run.start
      # [10ms] llm.start
      # [150ms] llm.stop (140ms)
      # ...
  """
  @spec print_timeline(list(map())) :: :ok
  def print_timeline(events) do
    first_timestamp =
      events
      |> Enum.find(&(&1["event"] == "trace.start" || &1["event"] == "run.start"))
      |> get_in(["timestamp"])

    base_time = parse_timestamp(first_timestamp)

    events
    |> Enum.reject(&(&1["event"] == "trace.start"))
    |> Enum.each(fn event ->
      offset_ms = timestamp_offset(event["timestamp"], base_time)
      duration_str = format_duration(event["duration_ms"])
      event_type = event["event"]
      details = format_event_details(event)

      IO.puts("[#{offset_ms}ms] #{event_type}#{duration_str}#{details}")
    end)

    :ok
  end

  @doc """
  Returns events as a formatted string timeline.

  Like `print_timeline/1` but returns a string instead of printing.
  """
  @spec format_timeline(list(map())) :: String.t()
  def format_timeline(events) do
    first_timestamp =
      events
      |> Enum.find(&(&1["event"] == "trace.start" || &1["event"] == "run.start"))
      |> get_in(["timestamp"])

    base_time = parse_timestamp(first_timestamp)

    events
    |> Enum.reject(&(&1["event"] == "trace.start"))
    |> Enum.map_join("\n", fn event ->
      offset_ms = timestamp_offset(event["timestamp"], base_time)
      duration_str = format_duration(event["duration_ms"])
      event_type = event["event"]
      details = format_event_details(event)

      "[#{offset_ms}ms] #{event_type}#{duration_str}#{details}"
    end)
  end

  # Private helpers

  defp find_event(events, event_type) do
    Enum.find(events, &(&1["event"] == event_type))
  end

  defp count_events(events, event_type) do
    Enum.count(events, &(&1["event"] == event_type))
  end

  defp extract_turns(nil), do: nil

  defp extract_turns(run_stop) do
    case get_in(run_stop, ["metadata", "step", "usage", "turns"]) do
      nil -> get_in(run_stop, ["metadata", "turns"])
      turns -> turns
    end
  end

  defp extract_tokens(nil), do: nil

  defp extract_tokens(run_stop) do
    usage = get_in(run_stop, ["metadata", "step", "usage"])

    if usage do
      %{
        input: usage["input_tokens"],
        output: usage["output_tokens"],
        total: usage["total_tokens"]
      }
    else
      nil
    end
  end

  defp extract_status(nil), do: nil

  defp extract_status(run_stop) do
    case run_stop["metadata"]["status"] do
      status when is_atom(status) -> Atom.to_string(status)
      status when is_binary(status) -> status
      _ -> nil
    end
  end

  defp matches_criteria?(event, criteria) do
    Enum.all?(criteria, fn
      {:type, type} ->
        String.starts_with?(event["event"], type)

      {:span_id, span_id} ->
        event["span_id"] == span_id

      {:min_duration_ms, min} ->
        (event["duration_ms"] || 0) >= min
    end)
  end

  defp extract_event_type(nil), do: "unknown"

  defp extract_event_type(event) do
    event["event"]
    |> String.split(".")
    |> Enum.take(1)
    |> Enum.join()
  end

  defp expand_children(node, all_nodes) do
    children =
      node.children
      |> Enum.map(&Map.get(all_nodes, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&expand_children(&1, all_nodes))

    %{node | children: children}
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp timestamp_offset(_timestamp, nil), do: 0

  defp timestamp_offset(timestamp, base_time) do
    case parse_timestamp(timestamp) do
      nil -> 0
      dt -> DateTime.diff(dt, base_time, :millisecond)
    end
  end

  defp format_duration(nil), do: ""
  defp format_duration(ms), do: " (#{ms}ms)"

  defp format_event_details(event) do
    case event["event"] do
      "tool.start" ->
        tool = get_in(event, ["metadata", "tool_name"]) || ""
        if tool != "", do: " - #{tool}", else: ""

      "tool.stop" ->
        tool = get_in(event, ["metadata", "tool_name"]) || ""
        if tool != "", do: " - #{tool}", else: ""

      _ ->
        ""
    end
  end
end
