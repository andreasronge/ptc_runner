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

  # ============================================================
  # Tree Functions for Hierarchical Traces
  # ============================================================

  @typedoc """
  A trace tree node representing a trace file and its children.

  Fields:
  - `path`: File path to this trace
  - `trace_id`: Unique trace identifier
  - `events`: Loaded events from this trace
  - `summary`: Summary statistics for this trace
  - `children`: List of child trace tree nodes
  """
  @type trace_tree :: %{
          path: String.t(),
          trace_id: String.t() | nil,
          events: [map()],
          summary: map(),
          children: [trace_tree()]
        }

  @doc """
  Loads a trace file and recursively loads all child traces.

  Child traces are discovered from:
  - `pmap.stop` events with `child_trace_ids` metadata
  - `tool.stop` events with `child_trace_id` metadata

  Returns a tree structure where each node contains:
  - `path`: File path
  - `trace_id`: Trace ID
  - `events`: Loaded events
  - `summary`: Execution summary
  - `children`: List of child trace trees

  ## Examples

      {:ok, tree} = Analyzer.load_tree("parent_trace.jsonl")
      length(tree.children)  #=> 28

  ## Options

  - `:base_dir` - Directory to search for child trace files (defaults to same directory as parent)
  - `:_seen` - Internal option for cycle detection (do not set manually)
  """
  @spec load_tree(String.t(), keyword()) :: {:ok, trace_tree()} | {:error, term()}
  def load_tree(path, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, Path.dirname(path))
    seen = Keyword.get(opts, :_seen, MapSet.new())

    try do
      events = load(path)
      summary = summary(events)
      trace_id = extract_trace_id(events)

      # Cycle detection: skip if we've already visited this trace
      if trace_id && MapSet.member?(seen, trace_id) do
        {:error, {:cycle_detected, trace_id}}
      else
        # Add current trace_id to seen set for children
        new_seen = if trace_id, do: MapSet.put(seen, trace_id), else: seen
        child_opts = Keyword.put(opts, :_seen, new_seen) |> Keyword.put(:base_dir, base_dir)

        # Find child trace IDs from pmap.stop and tool.stop events
        child_trace_ids = extract_child_trace_ids(events)

        # Recursively load child traces (skipping cycles)
        children =
          child_trace_ids
          |> Enum.map(&find_trace_file(&1, base_dir))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn child_path ->
            case load_tree(child_path, child_opts) do
              {:ok, child_tree} -> child_tree
              {:error, {:cycle_detected, _}} -> nil
              {:error, _} -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok,
         %{
           path: path,
           trace_id: trace_id,
           events: events,
           summary: summary,
           children: children
         }}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Returns a flat list of all file paths in the trace tree.

  Useful for cleanup operations.

  ## Examples

      {:ok, tree} = Analyzer.load_tree("parent.jsonl")
      paths = Analyzer.list_tree(tree)
      #=> ["parent.jsonl", "child1.jsonl", "child2.jsonl", ...]
  """
  @spec list_tree(trace_tree()) :: [String.t()]
  def list_tree(%{path: path, children: children}) do
    child_paths = Enum.flat_map(children, &list_tree/1)
    [path | child_paths]
  end

  @doc """
  Deletes all trace files in the tree.

  Returns `{:ok, deleted_count}` on success, `{:error, reason}` on failure.

  ## Examples

      {:ok, tree} = Analyzer.load_tree("parent.jsonl")
      {:ok, 29} = Analyzer.delete_tree(tree)
  """
  @spec delete_tree(trace_tree()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_tree(tree) do
    paths = list_tree(tree)

    results =
      Enum.map(paths, fn path ->
        case File.rm(path) do
          :ok -> :ok
          {:error, _} = err -> err
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, length(paths)}
    else
      {:error, {:delete_failed, errors}}
    end
  end

  @doc """
  Prints an ASCII visualization of the trace tree hierarchy.

  Shows execution times and nested structure for debugging and analysis.

  ## Examples

      {:ok, tree} = Analyzer.load_tree("parent.jsonl")
      Analyzer.print_tree(tree)
      # Output:
      # ├─ [1234ms] parent (trace-abc123)
      # │  ├─ [100ms] worker-1 (trace-def456)
      # │  ├─ [120ms] worker-2 (trace-ghi789)
      # │  └─ [95ms] worker-3 (trace-jkl012)
  """
  @spec print_tree(trace_tree()) :: :ok
  def print_tree(tree) do
    do_print_tree(tree, "", true)
    :ok
  end

  @doc """
  Returns the trace tree as a formatted string.

  Like `print_tree/1` but returns a string instead of printing.
  """
  @spec format_tree(trace_tree()) :: String.t()
  def format_tree(tree) do
    do_format_tree(tree, "", true)
    |> String.trim_trailing("\n")
  end

  @doc """
  Exports a trace tree to Chrome DevTools Trace Event format.

  The output can be opened in Chrome DevTools (Performance panel → Load profile)
  or at chrome://tracing for flame chart visualization.

  ## Parameters

  - `tree` - A trace tree from `load_tree/1`
  - `output_path` - Path to write the JSON file (e.g., "trace.json")

  ## Examples

      {:ok, tree} = Analyzer.load_tree("rlm_trace.jsonl")
      :ok = Analyzer.export_chrome_trace(tree, "rlm_trace.json")

      # Then open Chrome DevTools → Performance → Load profile → select rlm_trace.json
      # Or navigate to chrome://tracing and load the file

  ## Visualization

  The flame chart shows:
  - **Horizontal axis**: Time (wider = longer duration)
  - **Vertical stacking**: Nested calls (children below parents)
  - **Colors**: Different categories (turns, tools, pmap)

  Click any span to see details including arguments and results.
  """
  @spec export_chrome_trace(trace_tree(), String.t()) :: :ok | {:error, term()}
  def export_chrome_trace(tree, output_path) do
    trace_events = build_chrome_trace_events(tree, 0, 0)

    chrome_trace = %{
      "traceEvents" => trace_events,
      "metadata" => %{
        "source" => "PtcRunner.TraceLog",
        "trace_id" => tree.trace_id
      }
    }

    # Compact JSON - pretty: true creates huge files that crash browsers
    case Jason.encode(chrome_trace) do
      {:ok, json} ->
        File.write(output_path, json)

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  # Build Chrome Trace Event format events from a trace tree
  # Returns list of trace events with timestamps in microseconds
  #
  # For parallel children (pmap/pcalls), we use:
  # - Same start time (they run concurrently)
  # - Different thread IDs (so they appear on separate rows in flame chart)
  defp build_chrome_trace_events(tree, start_time_us, tid) do
    build_chrome_trace_events(tree, start_time_us, tid, 0)
  end

  defp build_chrome_trace_events(tree, start_time_us, tid, _child_index) do
    events = tree.events
    trace_id = tree.trace_id || "unknown"

    # Find the trace duration for this level
    trace_stop = Enum.find(events, &(&1["event"] == "trace.stop"))
    total_duration_us = (trace_stop["duration_ms"] || 0) * 1000

    # Create the main span for this trace
    main_span = %{
      "name" => trace_name(tree),
      "cat" => "trace",
      "ph" => "X",
      "ts" => start_time_us,
      "dur" => total_duration_us,
      "pid" => 1,
      "tid" => tid,
      "args" => %{
        "trace_id" => trace_id
      }
    }

    # Convert internal events to Chrome trace format
    internal_events = convert_events_to_chrome(events, start_time_us, tid)

    # Recursively process children
    # Parallel children (from pmap) start at the same time but get unique thread IDs
    child_events =
      tree.children
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, index} ->
        # Same start time (parallel execution)
        # Unique thread ID: base tid + 1 + index (avoids collision with parent)
        child_tid = tid * 100 + index + 1
        build_chrome_trace_events(child, start_time_us, child_tid, index)
      end)

    [main_span | internal_events] ++ child_events
  end

  defp trace_name(tree) do
    # Try to get a meaningful name from meta or summary
    cond do
      tree.summary[:meta][:tool_name] ->
        "worker: #{tree.summary[:meta][:tool_name]}"

      tree.trace_id ->
        short_id = String.slice(tree.trace_id, 0, 8)
        "trace-#{short_id}"

      true ->
        "trace"
    end
  end

  defp convert_events_to_chrome(events, base_time_us, depth) do
    # Pair start/stop events and convert to Chrome "X" (complete) events
    events
    |> pair_start_stop_events()
    |> Enum.map(fn {start_event, stop_event} ->
      event_type = event_type_from_name(start_event["event"])
      duration_us = (stop_event["duration_ms"] || 0) * 1000

      # Calculate relative timestamp from event order
      start_offset = calculate_event_offset(events, start_event) * 1000

      %{
        "name" => event_name(event_type, stop_event),
        "cat" => event_type,
        "ph" => "X",
        "ts" => base_time_us + start_offset,
        "dur" => duration_us,
        "pid" => 1,
        "tid" => depth,
        "args" => event_args(event_type, start_event, stop_event)
      }
    end)
  end

  defp pair_start_stop_events(events) do
    # Group events by type and pair start/stop
    events
    |> Enum.reduce({[], %{}}, &process_event_for_pairing/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp process_event_for_pairing(event, {pairs, pending}) do
    event_name = event["event"]

    cond do
      is_nil(event_name) ->
        {pairs, pending}

      String.ends_with?(event_name, ".start") ->
        key = event_pairing_key(event_name, ".start", event)
        {pairs, Map.put(pending, key, event)}

      String.ends_with?(event_name, ".stop") ->
        key = event_pairing_key(event_name, ".stop", event)
        match_stop_event(pairs, pending, key, event)

      true ->
        {pairs, pending}
    end
  end

  defp event_pairing_key(event_name, suffix, event) do
    base = String.replace_suffix(event_name, suffix, "")
    {base, event["metadata"]["turn_number"] || event["metadata"]["tool_name"]}
  end

  defp match_stop_event(pairs, pending, key, stop_event) do
    case Map.pop(pending, key) do
      {nil, pending} -> {pairs, pending}
      {start_event, pending} -> {[{start_event, stop_event} | pairs], pending}
    end
  end

  defp event_type_from_name(event_name) when is_binary(event_name) do
    event_name
    |> String.split(".")
    |> List.first()
  end

  defp event_type_from_name(_), do: "unknown"

  defp event_name(type, stop_event) do
    case type do
      "turn" -> "Turn #{stop_event["metadata"]["turn_number"] || "?"}"
      "tool" -> stop_event["metadata"]["tool_name"] || "tool"
      "pmap" -> "pmap (#{stop_event["metadata"]["count"] || "?"} tasks)"
      "pcalls" -> "pcalls (#{stop_event["metadata"]["count"] || "?"} tasks)"
      "llm" -> "LLM call"
      _ -> type
    end
  end

  defp event_args(type, start_event, stop_event) do
    base = %{
      "duration_ms" => stop_event["duration_ms"]
    }

    case type do
      "turn" ->
        Map.merge(base, %{
          "turn_number" => stop_event["metadata"]["turn_number"],
          "tokens" => stop_event["metadata"]["tokens"]
        })

      "tool" ->
        Map.merge(base, %{
          "tool_name" => stop_event["metadata"]["tool_name"],
          "args" => start_event["metadata"]["args"],
          "child_trace_id" => stop_event["metadata"]["child_trace_id"]
        })

      "pmap" ->
        Map.merge(base, %{
          "count" => stop_event["metadata"]["count"],
          "success_count" => stop_event["metadata"]["success_count"],
          "error_count" => stop_event["metadata"]["error_count"],
          "child_trace_ids" => stop_event["metadata"]["child_trace_ids"]
        })

      _ ->
        base
    end
  end

  defp calculate_event_offset(events, target_event) do
    # Sum durations of all stop events before this one to estimate offset
    events
    |> Enum.take_while(&(&1 != target_event))
    |> Enum.filter(&String.ends_with?(&1["event"] || "", ".stop"))
    |> Enum.map(&(&1["duration_ms"] || 0))
    |> Enum.sum()
  end

  # Private helpers for tree functions

  defp extract_trace_id(events) do
    case Enum.find(events, &(&1["event"] in ["trace.start", "run.start"])) do
      nil -> nil
      event -> event["trace_id"]
    end
  end

  defp extract_child_trace_ids(events) do
    pmap_ids =
      events
      |> Enum.filter(&(&1["event"] in ["pmap.stop", "pcalls.stop"]))
      |> Enum.flat_map(&(get_in(&1, ["metadata", "child_trace_ids"]) || []))

    tool_ids =
      events
      |> Enum.filter(&(&1["event"] == "tool.stop"))
      |> Enum.map(&get_in(&1, ["metadata", "child_trace_id"]))
      |> Enum.reject(&is_nil/1)

    Enum.uniq(pmap_ids ++ tool_ids)
  end

  defp find_trace_file(trace_id, base_dir) do
    # Look for trace file with the given trace_id
    # Common naming patterns: trace-{id}.jsonl, {id}.jsonl
    patterns = [
      Path.join(base_dir, "trace-#{trace_id}.jsonl"),
      Path.join(base_dir, "#{trace_id}.jsonl"),
      Path.join(base_dir, "*#{trace_id}*.jsonl")
    ]

    Enum.find_value(patterns, fn pattern ->
      case Path.wildcard(pattern) do
        [path | _] -> path
        [] -> nil
      end
    end)
  end

  defp do_print_tree(tree, prefix, is_last) do
    {connector, child_prefix} =
      if is_last do
        {"└─ ", "   "}
      else
        {"├─ ", "│  "}
      end

    duration = tree.summary[:duration_ms] || 0
    trace_id_short = if tree.trace_id, do: " (#{String.slice(tree.trace_id, 0..7)}...)", else: ""
    status = if tree.summary[:status], do: " [#{tree.summary[:status]}]", else: ""

    IO.puts("#{prefix}#{connector}[#{duration}ms]#{status}#{trace_id_short}")

    children = tree.children
    last_index = length(children) - 1

    children
    |> Enum.with_index()
    |> Enum.each(fn {child, index} ->
      do_print_tree(child, prefix <> child_prefix, index == last_index)
    end)
  end

  defp do_format_tree(tree, prefix, is_last) do
    {connector, child_prefix} =
      if is_last do
        {"└─ ", "   "}
      else
        {"├─ ", "│  "}
      end

    duration = tree.summary[:duration_ms] || 0
    trace_id_short = if tree.trace_id, do: " (#{String.slice(tree.trace_id, 0..7)}...)", else: ""
    status = if tree.summary[:status], do: " [#{tree.summary[:status]}]", else: ""

    line = "#{prefix}#{connector}[#{duration}ms]#{status}#{trace_id_short}\n"

    children = tree.children
    last_index = length(children) - 1

    child_lines =
      children
      |> Enum.with_index()
      |> Enum.map_join("", fn {child, index} ->
        do_format_tree(child, prefix <> child_prefix, index == last_index)
      end)

    line <> child_lines
  end
end
