defmodule PtcDemo.TraceAnalyzer.Tools do
  @moduledoc """
  Tool implementations for trace analysis.

  Cheap metadata tools: `list_traces`, `trace_summary`
  Expensive inspection tools: `turn_detail`, `diff_traces`
  """

  alias PtcRunner.TraceLog.Analyzer

  @doc """
  Build the tool map for the trace analyzer agent.
  """
  def build(trace_dir) do
    %{
      "list_traces" => list_traces_tool(trace_dir),
      "trace_summary" => trace_summary_tool(trace_dir),
      "turn_detail" => turn_detail_tool(trace_dir),
      "diff_traces" => diff_traces_tool(trace_dir)
    }
  end

  # --- list_traces ---

  defp list_traces_tool(trace_dir) do
    {fn args -> list_traces(trace_dir, args) end,
     signature:
       "(status :string, label :string, limit :int) -> " <>
         "{count :int, traces [{filename :string, timestamp :string, agent_name :string, " <>
         "status :string, turns :int, total_tokens :int, duration_ms :int, trace_label :string}]}",
     description:
       "List available trace files. All parameters are optional. " <>
         "Filter by status (ok, error, all) or label (substring match on filename). Default limit 20."}
  end

  defp list_traces(trace_dir, args) do
    status_filter = args["status"]
    label_filter = args["label"]
    limit = args["limit"] || 20

    trace_dir
    |> list_jsonl_files()
    |> Enum.map(fn path ->
      try do
        events = Analyzer.load(path)
        summary = Analyzer.summary(events)
        meta = extract_trace_meta(events)

        %{
          filename: Path.basename(path),
          timestamp: extract_timestamp(events),
          agent_name: extract_agent_name(events),
          status: summary.status,
          turns: summary.turns,
          total_tokens: summary.tokens[:total],
          duration_ms: summary.duration_ms,
          trace_label: meta["trace_label"] || meta["type"]
        }
      rescue
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> maybe_filter_status(status_filter)
    |> maybe_filter_label(label_filter)
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(limit)
    |> then(fn traces ->
      {:ok, %{count: length(traces), traces: traces}}
    end)
  end

  # --- trace_summary ---

  defp trace_summary_tool(trace_dir) do
    {fn args -> trace_summary(trace_dir, args) end,
     signature:
       "(filename :string) -> " <>
         "{filename :string, status :string, duration_ms :int, turns :int, " <>
         "total_tokens :int, input_tokens :int, output_tokens :int, " <>
         "tool_call_count :int, tool_sequence [{name :string, duration_ms :int}], " <>
         "turn_summaries [{turn :int, type :string, program_preview :string, " <>
         "result_preview :string, tokens :int, duration_ms :int}], " <>
         "errors [{event :string, turn :int, reason :string}]}",
     description:
       "Get a summary of a trace: turns, tokens, tool call sequence, per-turn summaries, errors. Cheap metadata operation."}
  end

  defp trace_summary(trace_dir, %{"filename" => filename}) do
    path = Path.join(trace_dir, filename)

    if File.exists?(path) do
      events = Analyzer.load(path)
      summary = Analyzer.summary(events)
      meta = extract_trace_meta(events)

      turns = extract_turn_summaries(events)

      tool_sequence =
        events
        |> Analyzer.filter(type: "tool")
        |> Enum.filter(&(&1["event"] == "tool.stop"))
        |> Enum.map(fn e ->
          %{
            name: get_in(e, ["metadata", "tool_name"]),
            duration_ms: e["duration_ms"]
          }
        end)

      errors =
        events
        |> Enum.filter(fn e ->
          String.ends_with?(e["event"] || "", ".exception") or
            (e["event"] == "turn.stop" and
               get_in(e, ["metadata", "type"]) in ["error", "retry"])
        end)
        |> Enum.map(fn e ->
          %{
            event: e["event"],
            turn: get_in(e, ["metadata", "turn"]),
            reason: get_in(e, ["metadata", "reason"])
          }
        end)

      {:ok,
       %{
         filename: filename,
         status: summary.status,
         duration_ms: summary.duration_ms,
         turns: summary.turns,
         total_tokens: summary.tokens[:total],
         input_tokens: summary.tokens[:input],
         output_tokens: summary.tokens[:output],
         llm_calls: summary.llm_calls,
         tool_call_count: summary.tool_calls,
         tool_sequence: tool_sequence,
         turn_summaries: turns,
         errors: errors,
         meta: meta
       }}
    else
      {:error, "Trace file not found: #{filename}"}
    end
  end

  # --- turn_detail ---

  defp turn_detail_tool(trace_dir) do
    {fn args -> turn_detail(trace_dir, args) end,
     signature:
       "(filename :string, turn :int, include_messages :bool) -> " <>
         "{turn :int, type :string, program :string, result_preview :string, " <>
         "prints [:string], duration_ms :int, input_tokens :int, output_tokens :int, " <>
         "total_tokens :int, tool_calls [{name :string, args :map, duration_ms :int}]}",
     description:
       "Get detailed info for a specific turn: program, tool calls, prints, result, token usage. " <>
         "Set include_messages to true to see full LLM messages (expensive, adds messages and llm_response fields)."}
  end

  defp turn_detail(trace_dir, args) do
    path = Path.join(trace_dir, args["filename"])
    turn_num = args["turn"]
    include_messages = args["include_messages"] || false

    if File.exists?(path) do
      events = Analyzer.load(path)

      turn_stop =
        events
        |> Enum.find(fn e ->
          e["event"] == "turn.stop" and get_in(e, ["metadata", "turn"]) == turn_num
        end)

      if turn_stop do
        meta = turn_stop["metadata"] || %{}

        detail = %{
          turn: turn_num,
          type: meta["type"],
          program: meta["program"],
          result_preview: meta["result_preview"],
          prints: meta["prints"] || [],
          duration_ms: turn_stop["duration_ms"],
          input_tokens: get_in(turn_stop, ["measurements", "input_tokens"]),
          output_tokens: get_in(turn_stop, ["measurements", "output_tokens"]),
          total_tokens: get_in(turn_stop, ["measurements", "tokens"])
        }

        span_id = turn_stop["span_id"]

        tool_calls =
          events
          |> Enum.filter(fn e ->
            e["event"] == "tool.stop" and e["parent_span_id"] == span_id
          end)
          |> Enum.map(fn e ->
            %{
              name: get_in(e, ["metadata", "tool_name"]),
              args: get_in(e, ["metadata", "args"]),
              duration_ms: e["duration_ms"]
            }
          end)

        detail = Map.put(detail, :tool_calls, tool_calls)

        detail =
          if include_messages do
            llm_start =
              events
              |> Enum.find(fn e ->
                e["event"] == "llm.start" and e["parent_span_id"] == span_id
              end)

            llm_stop =
              events
              |> Enum.find(fn e ->
                e["event"] == "llm.stop" and e["parent_span_id"] == span_id
              end)

            messages = get_in(llm_start || %{}, ["metadata", "messages"]) || []
            response = get_in(llm_stop || %{}, ["metadata", "response"])

            detail
            |> Map.put(:messages, messages)
            |> Map.put(:llm_response, response)
          else
            detail
          end

        {:ok, detail}
      else
        {:error, "Turn #{turn_num} not found in trace"}
      end
    else
      {:error, "Trace file not found: #{args["filename"]}"}
    end
  end

  # --- diff_traces ---

  defp diff_traces_tool(trace_dir) do
    {fn args -> diff_traces(trace_dir, args) end,
     signature:
       "(file_a :string, file_b :string) -> " <>
         "{file_a :map, file_b :map, deltas :map, first_divergence :map, same_tool_sequence :bool}",
     description:
       "Compare two traces. Shows token delta, turn delta, tool sequence match, " <>
         "and identifies the first point of divergence (different turn type, different program, or one trace ending earlier)."}
  end

  defp diff_traces(trace_dir, %{"file_a" => file_a, "file_b" => file_b}) do
    path_a = Path.join(trace_dir, file_a)
    path_b = Path.join(trace_dir, file_b)

    with true <- File.exists?(path_a) || {:error, "File not found: #{file_a}"},
         true <- File.exists?(path_b) || {:error, "File not found: #{file_b}"} do
      events_a = Analyzer.load(path_a)
      events_b = Analyzer.load(path_b)
      summary_a = Analyzer.summary(events_a)
      summary_b = Analyzer.summary(events_b)

      turns_a = extract_turn_summaries(events_a)
      turns_b = extract_turn_summaries(events_b)

      tool_seq_a = extract_tool_sequence(events_a)
      tool_seq_b = extract_tool_sequence(events_b)

      first_divergence = find_first_divergence(turns_a, turns_b)

      {:ok,
       %{
         file_a: %{
           filename: file_a,
           status: summary_a.status,
           turns: summary_a.turns,
           total_tokens: summary_a.tokens[:total],
           duration_ms: summary_a.duration_ms,
           tool_sequence: tool_seq_a
         },
         file_b: %{
           filename: file_b,
           status: summary_b.status,
           turns: summary_b.turns,
           total_tokens: summary_b.tokens[:total],
           duration_ms: summary_b.duration_ms,
           tool_sequence: tool_seq_b
         },
         deltas: %{
           turns: (summary_b.turns || 0) - (summary_a.turns || 0),
           total_tokens: (summary_b.tokens[:total] || 0) - (summary_a.tokens[:total] || 0),
           duration_ms: (summary_b.duration_ms || 0) - (summary_a.duration_ms || 0),
           tool_calls: (summary_b.tool_calls || 0) - (summary_a.tool_calls || 0)
         },
         first_divergence: first_divergence,
         same_tool_sequence: tool_seq_a == tool_seq_b
       }}
    else
      {:error, msg} -> {:error, msg}
    end
  end

  # --- Helpers ---

  defp list_jsonl_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp extract_trace_meta(events) do
    case Enum.find(events, &(&1["event"] == "trace.start")) do
      %{"meta" => meta} when is_map(meta) -> meta
      _ -> %{}
    end
  end

  defp extract_timestamp(events) do
    case Enum.find(events, &(&1["event"] == "trace.start")) do
      %{"timestamp" => ts} -> ts
      _ -> nil
    end
  end

  defp extract_agent_name(events) do
    case Enum.find(events, &(&1["event"] == "run.start")) do
      %{"metadata" => %{"agent" => %{"name" => name}}} -> name
      _ -> nil
    end
  end

  defp extract_turn_summaries(events) do
    events
    |> Enum.filter(&(&1["event"] == "turn.stop"))
    |> Enum.sort_by(&get_in(&1, ["metadata", "turn"]))
    |> Enum.map(fn e ->
      meta = e["metadata"] || %{}

      %{
        turn: meta["turn"],
        type: meta["type"],
        program_preview: truncate(meta["program"], 120),
        result_preview: truncate(meta["result_preview"], 80),
        tokens: get_in(e, ["measurements", "tokens"]),
        duration_ms: e["duration_ms"]
      }
    end)
  end

  defp extract_tool_sequence(events) do
    events
    |> Enum.filter(&(&1["event"] == "tool.stop"))
    |> Enum.map(&get_in(&1, ["metadata", "tool_name"]))
  end

  defp maybe_filter_status(traces, nil), do: traces
  defp maybe_filter_status(traces, "all"), do: traces

  defp maybe_filter_status(traces, status) do
    Enum.filter(traces, &(&1.status == status))
  end

  defp maybe_filter_label(traces, nil), do: traces

  defp maybe_filter_label(traces, label) do
    label_down = String.downcase(label)

    Enum.filter(traces, fn t ->
      String.contains?(String.downcase(t.filename), label_down)
    end)
  end

  defp find_first_divergence(turns_a, turns_b) do
    do_find_divergence(turns_a, turns_b)
  end

  defp do_find_divergence([], []), do: nil

  defp do_find_divergence([], [b | _]) do
    %{turn: b.turn, reason: "trace A ended, trace B continues"}
  end

  defp do_find_divergence([a | _], []) do
    %{turn: a.turn, reason: "trace B ended, trace A continues"}
  end

  defp do_find_divergence([a | rest_a], [b | rest_b]) do
    cond do
      a.type != b.type ->
        %{turn: a.turn, reason: "different turn type: #{a.type} vs #{b.type}"}

      a.program_preview != b.program_preview ->
        %{turn: a.turn, reason: "different programs"}

      true ->
        do_find_divergence(rest_a, rest_b)
    end
  end

  defp truncate(nil, _), do: nil

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp truncate(other, _), do: inspect(other)
end
