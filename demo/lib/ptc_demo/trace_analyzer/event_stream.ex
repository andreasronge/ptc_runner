defmodule PtcDemo.TraceAnalyzer.EventStream do
  @moduledoc """
  Streaming event reader for JSONL trace files.

  Reads trace files line-by-line without loading the entire file into memory.
  Supports filtering, field projection, pagination, and aggregation.
  """

  @doc """
  Query events from a JSONL trace file with streaming filters.

  Reads the file line-by-line, applies `where` filters, projects `select` fields,
  and returns up to `limit` matching events (starting from `offset`).

  ## Parameters

  - `path` - Path to the JSONL trace file
  - `opts` - Query options:
    - `:where` - Map of field filters (see Filtering below)
    - `:select` - List of field names to return (dot paths supported, e.g. `"data.result"`)
    - `:limit` - Maximum number of results (default: 20)
    - `:offset` - Number of matches to skip (default: 0)

  ## Filtering

  The `:where` map supports:
  - Exact match: `%{"tool_name" => "search"}` — field equals value
  - Prefix match: `%{"event" => "tool.*"}` — field starts with prefix (before `*`)
  - Numeric comparison: `%{"duration_ms" => ">1000"}` — supports `>`, `>=`, `<`, `<=`
  - Existence check: `%{"tool_name" => "*"}` — field is present and non-nil

  ## Returns

  `{:ok, %{events: [...], total_matched: n, has_more: bool}}`
  """
  @spec query(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def query(path, opts \\ []) do
    if File.exists?(path) do
      where = Keyword.get(opts, :where, %{})
      select = Keyword.get(opts, :select)
      limit = Keyword.get(opts, :limit, 20)
      offset = Keyword.get(opts, :offset, 0)

      # Compile where clauses into matchers
      matchers = compile_where(where)

      {events, total_matched, has_more} =
        path
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(&safe_decode/1)
        |> Stream.reject(&is_nil/1)
        |> Stream.filter(&matches_all?(&1, matchers))
        |> collect_with_pagination(offset, limit)

      # Apply field projection
      events = if select, do: Enum.map(events, &project(&1, select)), else: events

      {:ok, %{events: events, total_matched: total_matched, has_more: has_more}}
    else
      {:error, "File not found: #{Path.basename(path)}"}
    end
  end

  @doc """
  Aggregate events from a JSONL trace file with streaming computation.

  Reads the file line-by-line, filters with `where`, groups by `group_by` fields,
  and computes metrics over each group.

  ## Parameters

  - `path` - Path to the JSONL trace file
  - `opts` - Aggregation options:
    - `:where` - Map of field filters (same syntax as `query/2`)
    - `:group_by` - List of field names to group by (default: no grouping)
    - `:metrics` - List of metric expressions (default: `["count"]`)

  ## Metrics

  Supported metric expressions:
  - `"count"` — number of events in group
  - `"sum(field)"` — sum of numeric field
  - `"avg(field)"` — average of numeric field
  - `"min(field)"` — minimum of numeric field
  - `"max(field)"` — maximum of numeric field

  ## Returns

  `{:ok, %{groups: [...]}}`

  Each group is a map with the group_by key values plus computed metrics.
  Without `group_by`, returns a single group for all matching events.
  """
  @spec aggregate(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def aggregate(path, opts \\ []) do
    if File.exists?(path) do
      where = Keyword.get(opts, :where, %{})
      group_by = Keyword.get(opts, :group_by, [])
      metrics = Keyword.get(opts, :metrics, ["count"])

      matchers = compile_where(where)
      parsed_metrics = Enum.map(metrics, &parse_metric/1)

      # Stream and accumulate
      accumulators =
        path
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(&safe_decode/1)
        |> Stream.reject(&is_nil/1)
        |> Stream.filter(&matches_all?(&1, matchers))
        |> Enum.reduce(%{}, fn event, acc ->
          group_key = extract_group_key(event, group_by)
          group_acc = Map.get(acc, group_key, init_accumulators(parsed_metrics))
          updated = update_accumulators(group_acc, event, parsed_metrics)
          Map.put(acc, group_key, updated)
        end)

      # Finalize accumulators to results
      groups =
        accumulators
        |> Enum.map(fn {group_key, acc} ->
          group_fields =
            Enum.zip(group_by, Tuple.to_list(group_key))
            |> Map.new()

          metric_values =
            parsed_metrics
            |> Enum.zip(acc)
            |> Enum.map(fn {metric, value} -> {metric_name(metric), finalize(metric, value)} end)
            |> Map.new()

          Map.merge(group_fields, metric_values)
        end)
        |> Enum.sort_by(&Map.get(&1, metric_name(List.first(parsed_metrics)), 0), :desc)

      {:ok, %{groups: groups}}
    else
      {:error, "File not found: #{Path.basename(path)}"}
    end
  end

  @tail_read_size 512

  @doc """
  Extract lightweight metadata from a trace file without loading it into memory.

  Reads the first few lines with `IO.read/2` and JSON-decodes them for `trace.start`
  and `run.start` fields. Reads the last #{@tail_read_size} bytes to decode the small
  `trace.stop` line (for `duration_ms`) and regex-extract `status` from the `run.stop`
  line tail.

  Fields like `turns` and `total_tokens` are not available here — they live deep inside
  the `run.stop` data blob which can exceed 900 KB. Use `trace_summary` for those.

  Returns `{:ok, metadata_map}` or `{:error, reason}`.
  """
  @spec trace_metadata(String.t()) :: {:ok, map()} | {:error, String.t()}
  def trace_metadata(path) do
    with {:ok, %{size: size}} when size > 0 <- File.stat(path),
         {trace_start, run_start} <- read_head_events(path),
         {:ok, trace_stop, status} <- read_tail_fields(path, size) do
      if trace_start && trace_stop do
        {:ok,
         %{
           filename: Path.basename(path),
           timestamp: copy(trace_start["timestamp"]),
           agent_name: run_start && copy(run_start["agent_name"]),
           status: status,
           duration_ms: trace_stop && trace_stop["duration_ms"],
           trace_kind: copy(trace_start["trace_kind"]),
           producer: copy(trace_start["producer"]),
           trace_label: copy(trace_start["trace_label"]),
           query: copy(trace_start["query"]),
           model: copy(trace_start["model"])
         }}
      else
        {:error, "Incomplete trace (missing required events): #{Path.basename(path)}"}
      end
    else
      _ -> {:error, "Cannot read trace: #{Path.basename(path)}"}
    end
  end

  defp read_head_events(path) do
    {:ok, f} = File.open(path, [:read, :utf8])

    events =
      for _ <- 1..4,
          line = IO.read(f, :line),
          is_binary(line),
          e = safe_decode(String.trim(line)),
          not is_nil(e),
          do: e

    File.close(f)

    trace_start = Enum.find(events, &(&1["event"] == "trace.start"))
    run_start = Enum.find(events, &(&1["event"] == "run.start"))
    {trace_start, run_start}
  end

  defp read_tail_fields(path, size) do
    tail_size = min(size, @tail_read_size)
    {:ok, f} = :file.open(path, [:read, :binary])
    {:ok, _} = :file.position(f, size - tail_size)
    {:ok, tail} = :file.read(f, tail_size)
    :file.close(f)

    # Decode trace.stop (last line, always small)
    last_line = tail |> String.split("\n", trim: true) |> List.last() || ""

    trace_stop =
      case safe_decode(last_line) do
        %{"event" => "trace.stop"} = e -> e
        _ -> nil
      end

    # Extract status via regex from run.stop tail (status is a simple unescaped value)
    status =
      case Regex.run(~r/"status":"([^"]*)"/, tail) do
        [_, s] -> :binary.copy(s)
        _ -> nil
      end

    {:ok, trace_stop, status}
  end

  defp copy(nil), do: nil
  defp copy(s) when is_binary(s), do: :binary.copy(s)

  # --- Where clause compilation ---

  defp compile_where(where) when is_map(where) do
    Enum.map(where, fn {field, pattern} ->
      {to_string(field), compile_pattern(pattern)}
    end)
  end

  defp compile_pattern("*"), do: {:exists}
  defp compile_pattern(">" <> num), do: {:gt, parse_number(num)}
  defp compile_pattern(">=" <> num), do: {:gte, parse_number(num)}
  defp compile_pattern("<" <> num), do: {:lt, parse_number(num)}
  defp compile_pattern("<=" <> num), do: {:lte, parse_number(num)}

  defp compile_pattern(pattern) when is_binary(pattern) do
    if String.ends_with?(pattern, "*") do
      {:prefix, String.trim_trailing(pattern, "*")}
    else
      {:eq, pattern}
    end
  end

  defp compile_pattern(value) when is_number(value), do: {:eq, value}
  defp compile_pattern(value) when is_boolean(value), do: {:eq, value}
  defp compile_pattern(nil), do: {:eq, nil}

  # --- Matching ---

  defp matches_all?(event, matchers) do
    Enum.all?(matchers, fn {field, matcher} ->
      value = get_field(event, field)
      matches?(value, matcher)
    end)
  end

  defp matches?(value, {:exists}), do: not is_nil(value)
  defp matches?(value, {:eq, expected}), do: value == expected

  defp matches?(value, {:prefix, prefix}) when is_binary(value),
    do: String.starts_with?(value, prefix)

  defp matches?(_, {:prefix, _}), do: false

  defp matches?(value, {:gt, num}) when is_number(value), do: value > num
  defp matches?(value, {:gte, num}) when is_number(value), do: value >= num
  defp matches?(value, {:lt, num}) when is_number(value), do: value < num
  defp matches?(value, {:lte, num}) when is_number(value), do: value <= num
  defp matches?(_, _), do: false

  # --- Field access (supports dot paths) ---

  defp get_field(event, field) do
    case String.split(field, ".", parts: 2) do
      [key] -> Map.get(event, key)
      [key, rest] -> get_field(Map.get(event, key) || %{}, rest)
    end
  end

  # --- Projection ---

  defp project(event, fields) do
    Map.new(fields, fn field ->
      {field, get_field(event, field)}
    end)
  end

  # --- Pagination ---

  defp collect_with_pagination(stream, offset, limit) do
    # We need total_matched and has_more, so we count all matches
    stream
    |> Enum.reduce({[], 0, false}, fn event, {collected, count, _has_more} ->
      cond do
        count < offset ->
          {collected, count + 1, false}

        length(collected) < limit ->
          {collected ++ [event], count + 1, false}

        true ->
          # Past limit — just count
          {collected, count + 1, true}
      end
    end)
  end

  # --- Aggregation helpers ---

  defp parse_metric("count"), do: {:count}
  defp parse_metric("sum(" <> rest), do: {:sum, String.trim_trailing(rest, ")")}
  defp parse_metric("avg(" <> rest), do: {:avg, String.trim_trailing(rest, ")")}
  defp parse_metric("min(" <> rest), do: {:min, String.trim_trailing(rest, ")")}
  defp parse_metric("max(" <> rest), do: {:max, String.trim_trailing(rest, ")")}

  defp metric_name({:count}), do: "count"
  defp metric_name({:sum, field}), do: "sum_#{field}"
  defp metric_name({:avg, field}), do: "avg_#{field}"
  defp metric_name({:min, field}), do: "min_#{field}"
  defp metric_name({:max, field}), do: "max_#{field}"

  defp init_accumulators(metrics) do
    Enum.map(metrics, fn
      {:count} -> 0
      {:sum, _} -> 0
      {:avg, _} -> {0, 0}
      {:min, _} -> nil
      {:max, _} -> nil
    end)
  end

  defp update_accumulators(acc, event, metrics) do
    Enum.zip(metrics, acc)
    |> Enum.map(fn
      {{:count}, count} ->
        count + 1

      {{:sum, field}, sum} ->
        case get_field(event, field) do
          v when is_number(v) -> sum + v
          _ -> sum
        end

      {{:avg, field}, {sum, count}} ->
        case get_field(event, field) do
          v when is_number(v) -> {sum + v, count + 1}
          _ -> {sum, count}
        end

      {{:min, field}, current} ->
        case get_field(event, field) do
          v when is_number(v) -> if current == nil, do: v, else: min(current, v)
          _ -> current
        end

      {{:max, field}, current} ->
        case get_field(event, field) do
          v when is_number(v) -> if current == nil, do: v, else: max(current, v)
          _ -> current
        end
    end)
  end

  defp finalize({:avg, _}, {sum, count}) when count > 0, do: Float.round(sum / count, 2)
  defp finalize({:avg, _}, _), do: nil
  defp finalize(_, value), do: value

  defp extract_group_key(event, group_by) do
    group_by
    |> Enum.map(&get_field(event, &1))
    |> List.to_tuple()
  end

  # --- Helpers ---

  defp safe_decode(line) do
    case Jason.decode(line) do
      {:ok, event} -> event
      {:error, _} -> nil
    end
  end

  defp parse_number(str) do
    str = String.trim(str)

    case Integer.parse(str) do
      {n, ""} -> n
      _ -> String.to_float(str)
    end
  end
end
