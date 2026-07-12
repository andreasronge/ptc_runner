defmodule PtcRunner.Kernel.TraceLog do
  @moduledoc "Bounded canonical trace loading, derivation, filtering, and pagination."

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.JSONValue

  @default_source_bytes 8_000_000
  @default_result_bytes 1_000_000
  @default_limit 20
  @max_limit 100
  @max_cursor_bytes 1_024
  @max_string_bytes 256
  @event_type ~r/\A[a-z][a-z0-9-]{0,127}\z/
  @event_keys ~w(schema_version run_id trace_id sequence timestamp type data)

  @enforce_keys [:source, :source_kind, :max_source_bytes, :max_result_bytes]
  defstruct [:source, :source_kind, :max_source_bytes, :max_result_bytes]

  @type source :: EventSink.t() | {:file, binary()} | {:directory, binary()}
  @type t :: %__MODULE__{
          source: source(),
          source_kind: :sanitized | :private,
          max_source_bytes: pos_integer(),
          max_result_bytes: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_trace_log}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:source, :max_source_bytes, :max_result_bytes] == [],
         {:ok, source, source_kind} <- validate_source(Keyword.get(opts, :source)),
         max_source_bytes when is_integer(max_source_bytes) and max_source_bytes > 0 <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Keyword.get(opts, :max_result_bytes, @default_result_bytes) do
      {:ok,
       %__MODULE__{
         source: source,
         source_kind: source_kind,
         max_source_bytes: max_source_bytes,
         max_result_bytes: max_result_bytes
       }}
    else
      _ -> {:error, :invalid_trace_log}
    end
  end

  def new(_opts), do: {:error, :invalid_trace_log}

  @spec query(t(), :list_runs | :get_run | :list_turns | :counters, map()) ::
          {:ok, map()} | {:error, atom()}
  def query(%__MODULE__{} = trace_log, operation, arguments)
      when operation in [:list_runs, :get_run, :list_turns, :counters] and is_map(arguments) do
    with {:ok, events, source_id} <- load(trace_log),
         do:
           execute(
             operation,
             events,
             source_id,
             arguments,
             trace_log.max_result_bytes,
             trace_log.source_kind
           )
  end

  def query(_trace_log, _operation, _arguments), do: {:error, :invalid_query}

  @doc """
  Appends canonical events to one admin-selected JSONL file under a total byte
  cap. `private: true` restricts the empty/new or existing file to mode `0600`
  before event bytes are appended.
  """
  @spec append_jsonl(binary(), [map()], keyword()) :: :ok | {:error, atom()}
  def append_jsonl(path, events, opts \\ [])

  def append_jsonl(path, events, opts)
      when is_binary(path) and is_list(events) and is_list(opts) do
    with true <- Keyword.keys(opts) -- [:max_source_bytes, :private] == [],
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Keyword.get(opts, :max_source_bytes, @default_source_bytes),
         private? when is_boolean(private?) <- Keyword.get(opts, :private, false) do
      path = Path.expand(path)

      :global.trans({__MODULE__, path}, fn ->
        append_locked(path, normalize(events), max_bytes, private?)
      end)
    else
      _ -> {:error, :invalid_trace_log}
    end
  end

  def append_jsonl(_path, _events, _opts), do: {:error, :invalid_trace_log}

  defp execute(:list_runs, events, source_id, arguments, max_result_bytes, source_kind) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(limit cursor status run_id trace_id tags name model provider from to)
           ),
         :ok <- validate_run_filters(arguments),
         {:ok, page} <- page_options(arguments, source_id, :list_runs) do
      events
      |> runs(source_kind)
      |> filter_runs(arguments)
      |> paginate(page, source_id, max_result_bytes)
    end
  end

  defp execute(
         :get_run,
         events,
         _source_id,
         %{"run_id" => run_id} = arguments,
         max_result_bytes,
         source_kind
       ) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         :ok <- valid_string(run_id),
         metadata when not is_nil(metadata) <-
           Enum.find(runs(events, source_kind), &(&1["run_id"] == run_id)),
         :ok <- within_result_limit(metadata, max_result_bytes) do
      {:ok, metadata}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(:get_run, _events, _source_id, _arguments, _max_result_bytes, _source_kind),
    do: {:error, :invalid_query}

  defp execute(
         :list_turns,
         events,
         source_id,
         %{"run_id" => run_id} = arguments,
         max_result_bytes,
         _source_kind
       ) do
    with :ok <- validate_keys(arguments, ~w(run_id limit cursor status evaluation_id capability)),
         :ok <- valid_string(run_id),
         :ok <- validate_turn_filters(arguments),
         true <- Enum.any?(events, &(&1["run_id"] == run_id)),
         {:ok, page} <- page_options(arguments, source_id, :list_turns) do
      events
      |> Enum.filter(&(&1["run_id"] == run_id and turn_matches?(&1, arguments)))
      |> Enum.sort_by(& &1["sequence"])
      |> paginate(page, source_id, max_result_bytes)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(:list_turns, _events, _source_id, _arguments, _max_result_bytes, _source_kind),
    do: {:error, :invalid_query}

  defp execute(:counters, events, _source_id, arguments, max_result_bytes, source_kind) do
    with :ok <-
           validate_keys(arguments, ~w(status run_id trace_id tags name model provider from to)),
         :ok <- validate_run_filters(arguments) do
      selected_ids =
        events |> runs(source_kind) |> filter_runs(arguments) |> MapSet.new(& &1["run_id"])

      selected = Enum.filter(events, &MapSet.member?(selected_ids, &1["run_id"]))
      result = counters(selected)

      with :ok <- within_result_limit(result, max_result_bytes), do: {:ok, result}
    end
  end

  defp append_locked(path, events, max_bytes, private?) do
    with :ok <- ensure_trace_file(path, private?),
         {:ok, existing_source} <- read_regular_file(path, max_bytes),
         {:ok, existing_events} <- decode_jsonl(existing_source),
         {:ok, _events, _source_id} <- validate_loaded(existing_events ++ events, max_bytes),
         encoded = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")),
         true <- byte_size(existing_source) + byte_size(encoded) <= max_bytes,
         :ok <- append_regular_file(path, existing_source, encoded, max_bytes) do
      :ok
    else
      false -> {:error, :source_limit_exceeded}
      {:error, _reason} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp ensure_trace_file(path, private?) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> restrict_trace_file(path, private?)
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, :enoent} -> create_trace_file(path, private?)
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp create_trace_file(path, private?) do
    case File.write(path, "", [:exclusive]) do
      :ok ->
        case restrict_trace_file(path, private?) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            File.rm(path)
            error
        end

      {:error, :eexist} ->
        ensure_trace_file(path, private?)

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  defp restrict_trace_file(path, true) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp restrict_trace_file(_path, false), do: :ok

  defp append_regular_file(path, existing_source, encoded, max_bytes) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         true <- expected.size == byte_size(existing_source),
         {:ok, device} <-
           :file.open(String.to_charlist(path), [:read, :append, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular and opened.size == byte_size(existing_source),
             {:ok, 0} <- :file.position(device, :bof),
             {:ok, current_source} <- read_device(device, max_bytes),
             true <- current_source == existing_source,
             true <- byte_size(current_source) + byte_size(encoded) <= max_bytes,
             :ok <- :file.write(device, encoded) do
          :ok
        else
          false -> {:error, :source_changed}
          {:error, _reason} = error -> error
        end
      after
        :file.close(device)
      end
    else
      false -> {:error, :source_changed}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp read_device(device, max_bytes) do
    case :file.read(device, max_bytes + 1) do
      {:ok, source} when byte_size(source) <= max_bytes -> {:ok, source}
      :eof -> {:ok, ""}
      {:ok, _source} -> {:error, :source_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp validate_source(%EventSink{} = sink) do
    case EventSink.policy(sink) do
      :normal -> {:ok, sink, :sanitized}
      _ -> {:error, :invalid_trace_log}
    end
  catch
    :exit, _reason -> {:error, :invalid_trace_log}
  end

  defp validate_source({:private, %EventSink{} = sink}) do
    case EventSink.policy(sink) do
      :private -> {:ok, sink, :private}
      _ -> {:error, :invalid_trace_log}
    end
  catch
    :exit, _reason -> {:error, :invalid_trace_log}
  end

  defp validate_source({:file, path}) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, {:file, Path.expand(path)}, :sanitized}
      _ -> {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:directory, path}) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, {:directory, Path.expand(path)}, :sanitized}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:private_file, path}) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, {:file, Path.expand(path)}, :private}
      _ -> {:error, :invalid_trace_log}
    end
  end

  defp validate_source({:private_directory, path}) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, {:directory, Path.expand(path)}, :private}

      _ ->
        {:error, :invalid_trace_log}
    end
  end

  defp validate_source(_source), do: {:error, :invalid_trace_log}

  defp load(%__MODULE__{source: %EventSink{} = sink} = trace_log) do
    sink
    |> EventSink.events()
    |> normalize()
    |> validate_loaded(trace_log.max_source_bytes)
  catch
    :exit, _reason -> {:error, :source_unavailable}
  end

  defp load(%__MODULE__{source: {:file, path}, max_source_bytes: max_bytes}) do
    with {:ok, source} <- read_regular_file(path, max_bytes),
         {:ok, events} <- decode_jsonl(source),
         do: validate_loaded(events, max_bytes)
  end

  defp load(%__MODULE__{source: {:directory, directory}, max_source_bytes: max_bytes}) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, names} <- File.ls(directory),
         {:ok, events} <- load_files(directory, supported_names(names), max_bytes) do
      validate_loaded(events, max_bytes)
    else
      {:error, reason} = error when reason in [:source_limit_exceeded, :malformed_source] ->
        error

      _ ->
        {:error, :source_unavailable}
    end
  end

  defp supported_names(names) do
    names
    |> Enum.filter(&(Path.basename(&1) == &1 and String.ends_with?(&1, ".jsonl")))
    |> Enum.sort()
  end

  defp load_files(directory, names, max_bytes) do
    Enum.reduce_while(names, {:ok, {[], 0}}, fn name, {:ok, {event_groups, bytes}} ->
      path = Path.join(directory, name)
      remaining = max_bytes - bytes

      with {:ok, source} <- read_regular_file(path, remaining),
           {:ok, events} <- decode_jsonl(source) do
        {:cont, {:ok, {[events | event_groups], bytes + byte_size(source)}}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {event_groups, _bytes}} -> {:ok, event_groups |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp read_regular_file(_path, remaining) when remaining <= 0,
    do: {:error, :source_limit_exceeded}

  defp read_regular_file(path, remaining) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         true <- expected.size <= remaining,
         {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular and opened.size <= remaining do
          case :file.read(device, remaining + 1) do
            {:ok, source} when byte_size(source) <= remaining -> {:ok, source}
            :eof -> {:ok, ""}
            {:ok, _source} -> {:error, :source_limit_exceeded}
            {:error, _reason} -> {:error, :source_unavailable}
          end
        else
          false -> {:error, :source_limit_exceeded}
          {:error, _reason} = error -> error
        end
      after
        :file.close(device)
      end
    else
      false -> {:error, :source_limit_exceeded}
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp same_file(
         %File.Stat{major_device: device, minor_device: minor, inode: inode},
         %File.Stat{major_device: device, minor_device: minor, inode: inode}
       ),
       do: :ok

  defp same_file(_expected, _opened), do: {:error, :source_changed}

  defp decode_jsonl(source) do
    source
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      with {:ok, decoded} <- Jason.decode(line, objects: :ordered_objects),
           {:ok, event} <- ordered_map(decoded),
           true <- is_map(event) do
        {:cont, {:ok, [event | events]}}
      else
        _ -> {:halt, {:error, :malformed_source}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_map(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
        case ordered_map(value) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(map, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_json_key}
    end
  end

  defp ordered_map(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case ordered_map(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_map(value), do: {:ok, value}

  defp validate_loaded(events, max_bytes) when is_list(events) do
    encoded_bytes = Enum.reduce(events, 0, &(&2 + byte_size(Jason.encode!(&1))))

    with true <- encoded_bytes <= max_bytes,
         :ok <- validate_events(events) do
      source_id = digest(events)

      {:ok, events, source_id}
    else
      false -> {:error, :source_limit_exceeded}
      {:error, _reason} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp validate_events(events) do
    initial = %{sequences: %{}, run_traces: %{}, trace_runs: %{}}

    Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
      with :ok <- validate_event(event),
           trace_id = event["trace_id"],
           run_id = event["run_id"],
           sequence = event["sequence"],
           previous = Map.get(state.sequences, trace_id, 0),
           true <- sequence > previous,
           :ok <- same_identity(state, run_id, trace_id) do
        {:cont,
         {:ok,
          %{
            sequences: Map.put(state.sequences, trace_id, sequence),
            run_traces: Map.put(state.run_traces, run_id, trace_id),
            trace_runs: Map.put(state.trace_runs, trace_id, run_id)
          }}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :malformed_source}}
      end
    end)
    |> case do
      {:ok, _sequences} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp same_identity(state, run_id, trace_id) do
    with existing_trace when existing_trace in [nil, trace_id] <-
           Map.get(state.run_traces, run_id),
         existing_run when existing_run in [nil, run_id] <- Map.get(state.trace_runs, trace_id) do
      :ok
    else
      _other -> {:error, :malformed_source}
    end
  end

  defp validate_event(event) when is_map(event) do
    with true <- Enum.sort(Map.keys(event)) == Enum.sort(@event_keys),
         1 <- event["schema_version"],
         :ok <- valid_string(event["run_id"]),
         :ok <- valid_string(event["trace_id"]),
         sequence when is_integer(sequence) and sequence > 0 <- event["sequence"],
         timestamp when is_binary(timestamp) <- event["timestamp"],
         {:ok, _datetime, 0} <- DateTime.from_iso8601(timestamp),
         type when is_binary(type) <- event["type"],
         true <- type =~ @event_type,
         true <- JSONValue.map?(event["data"]) do
      :ok
    else
      version when is_integer(version) and version != 1 -> {:error, :unsupported_version}
      _ -> {:error, :malformed_source}
    end
  end

  defp validate_event(_event), do: {:error, :malformed_source}

  defp runs(events, source_kind) do
    events
    |> Enum.group_by(& &1["run_id"])
    |> Enum.map(fn {run_id, run_events} -> run_metadata(run_id, run_events, source_kind) end)
    |> Enum.sort(fn left, right ->
      {timestamp_sort_value(left["start_timestamp"]), left["run_id"]} >=
        {timestamp_sort_value(right["start_timestamp"]), right["run_id"]}
    end)
  end

  defp run_metadata(run_id, events, source_kind) do
    started = Enum.find(events, &(&1["type"] == "run-started"))
    stopped = events |> Enum.filter(&(&1["type"] == "run-stopped")) |> List.last()
    labels = event_data(started, "labels", %{})
    workflow_calls = capability_call_count(events, "workflow")
    mission_calls = capability_call_count(events, "mission")

    %{
      "run_id" => run_id,
      "trace_id" => event_value(started || List.first(events), "trace_id"),
      "start_timestamp" => event_value(started, "timestamp"),
      "stop_timestamp" => event_value(stopped, "timestamp"),
      "status" => stringify(event_data(stopped, "outcome")),
      "terminal_reason" => event_data(stopped, "reason"),
      "labels" => labels,
      "tags" => Map.get(labels, "tags", %{}),
      "name" => Map.get(labels, "name"),
      "model" => Map.get(labels, "model"),
      "provider" => Map.get(labels, "provider"),
      "subordinate_evaluations" => evaluation_count(events, "mission"),
      "workflow_capability_calls" => workflow_calls,
      "mission_capability_calls" => mission_calls,
      "llm_calls" => capability_name_count(events, "llm-request"),
      "error_count" => Enum.count(events, &error_event?/1),
      "duration_ms" => duration_ms(started, stopped),
      "workflow_prelude" => event_data(started, "workflow_prelude", empty_prelude()),
      "mission_prelude" => event_data(started, "mission_prelude", empty_prelude()),
      "complete" => not is_nil(stopped),
      "truncated" => Enum.any?(events, &(&1["type"] == "events-dropped")),
      "schema_version" => 1,
      "source" => Atom.to_string(source_kind)
    }
  end

  defp empty_prelude, do: %{"component_ids" => [], "hash" => nil}

  defp filter_runs(items, arguments) do
    Enum.filter(items, fn item ->
      equal_filter?(item, arguments, "status") and equal_filter?(item, arguments, "run_id") and
        equal_filter?(item, arguments, "trace_id") and equal_filter?(item, arguments, "name") and
        equal_filter?(item, arguments, "model") and equal_filter?(item, arguments, "provider") and
        tags_match?(item["tags"], arguments["tags"]) and
        after_or_equal?(item["start_timestamp"], arguments["from"]) and
        before_or_equal?(item["start_timestamp"], arguments["to"])
    end)
  end

  defp equal_filter?(item, arguments, key),
    do: is_nil(arguments[key]) or item[key] == arguments[key]

  defp tags_match?(_tags, nil), do: true

  defp tags_match?(tags, expected),
    do: Enum.all?(expected, fn {key, value} -> tags[key] == value end)

  defp after_or_equal?(_timestamp, nil), do: true
  defp after_or_equal?(nil, _from), do: false
  defp after_or_equal?(timestamp, from), do: compare_timestamp(timestamp, from) != :lt
  defp before_or_equal?(_timestamp, nil), do: true
  defp before_or_equal?(nil, _to), do: false
  defp before_or_equal?(timestamp, to), do: compare_timestamp(timestamp, to) != :gt

  defp compare_timestamp(left, right) do
    {:ok, left_at, 0} = DateTime.from_iso8601(left)
    {:ok, right_at, 0} = DateTime.from_iso8601(right)
    DateTime.compare(left_at, right_at)
  end

  defp timestamp_sort_value(nil), do: -1

  defp timestamp_sort_value(timestamp) do
    {:ok, datetime, 0} = DateTime.from_iso8601(timestamp)
    DateTime.to_unix(datetime, :microsecond)
  end

  defp turn_matches?(event, arguments) do
    status = stringify(event_data(event, "status") || event_data(event, "outcome"))

    (is_nil(arguments["status"]) or status == arguments["status"]) and
      (is_nil(arguments["evaluation_id"]) or
         event_data(event, "evaluation_id") == arguments["evaluation_id"]) and
      (is_nil(arguments["capability"]) or event_data(event, "name") == arguments["capability"])
  end

  defp counters(events) do
    %{
      "events" => length(events),
      "runs" => events |> Enum.map(& &1["run_id"]) |> Enum.uniq() |> length(),
      "errors" => Enum.count(events, &error_event?/1),
      "evaluations" => Enum.count(events, &(&1["type"] == "evaluation-started")),
      "workflow_capability_calls" => capability_call_count(events, "workflow"),
      "mission_capability_calls" => capability_call_count(events, "mission")
    }
  end

  defp capability_call_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "capability-started" and
        stringify(event_data(event, "environment")) == environment
    end)
  end

  defp capability_name_count(events, name) do
    Enum.count(events, &(&1["type"] == "capability-started" and event_data(&1, "name") == name))
  end

  defp evaluation_count(events, environment) do
    Enum.count(events, fn event ->
      event["type"] == "evaluation-started" and
        stringify(event_data(event, "environment")) == environment
    end)
  end

  defp error_event?(event) do
    event["type"] == "limit-exceeded" or
      stringify(event_data(event, "status") || event_data(event, "outcome")) == "error"
  end

  defp duration_ms(nil, _stopped), do: nil
  defp duration_ms(_started, nil), do: nil

  defp duration_ms(started, stopped) do
    with {:ok, started_at, 0} <- DateTime.from_iso8601(started["timestamp"]),
         {:ok, stopped_at, 0} <- DateTime.from_iso8601(stopped["timestamp"]) do
      max(DateTime.diff(stopped_at, started_at, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp page_options(arguments, source_id, operation) do
    limit = Map.get(arguments, "limit", @default_limit)
    query_id = digest({operation, Map.drop(arguments, ["cursor", "limit"])})

    with true <- is_integer(limit) and limit in 1..@max_limit,
         {:ok, offset} <- cursor_offset(Map.get(arguments, "cursor"), source_id, query_id) do
      {:ok, %{limit: limit, offset: offset, query_id: query_id}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_query}
    end
  end

  defp cursor_offset(nil, _source_id, _query_id), do: {:ok, 0}

  defp cursor_offset(cursor, source_id, query_id)
       when is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{"offset" => offset, "source" => cursor_source, "query" => cursor_query} = payload} <-
           Jason.decode(encoded),
         true <- map_size(payload) == 3,
         true <- is_integer(offset) and offset >= 0,
         true <- is_binary(cursor_source) and is_binary(cursor_query) do
      cond do
        cursor_source != source_id -> {:error, :source_changed}
        cursor_query != query_id -> {:error, :invalid_query}
        true -> {:ok, offset}
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp cursor_offset(_cursor, _source_id, _query_id), do: {:error, :invalid_query}

  defp paginate(
         items,
         %{limit: limit, offset: offset, query_id: query_id},
         source_id,
         max_result_bytes
       ) do
    selected = items |> Enum.drop(offset) |> Enum.take(limit)
    fit_page(selected, items, offset, source_id, query_id, max_result_bytes)
  end

  defp fit_page(selected, all_items, offset, source_id, query_id, max_result_bytes) do
    next_offset = offset + length(selected)
    more? = next_offset < length(all_items)

    result = %{
      "items" => selected,
      "next_cursor" => if(more?, do: encode_cursor(next_offset, source_id, query_id), else: nil),
      "truncated" => more?,
      "omitted_count" => max(length(all_items) - next_offset, 0)
    }

    case within_result_limit(result, max_result_bytes) do
      :ok ->
        {:ok, result}

      {:error, :result_limit_exceeded} when selected != [] ->
        fit_page(
          Enum.drop(selected, -1),
          all_items,
          offset,
          source_id,
          query_id,
          max_result_bytes
        )

      {:error, :result_limit_exceeded} ->
        {:error, :result_limit_exceeded}
    end
  end

  defp encode_cursor(offset, source_id, query_id) do
    %{"offset" => offset, "source" => source_id, "query" => query_id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp within_result_limit(value, max_result_bytes) do
    if byte_size(Jason.encode!(value)) <= max_result_bytes,
      do: :ok,
      else: {:error, :result_limit_exceeded}
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp validate_run_filters(arguments) do
    with :ok <-
           optional_strings(arguments, ~w(status run_id trace_id name model provider from to)),
         :ok <- valid_tags(arguments["tags"]),
         :ok <- valid_timestamp(arguments["from"]) do
      valid_timestamp(arguments["to"])
    end
  end

  defp validate_turn_filters(arguments),
    do: optional_strings(arguments, ~w(status evaluation_id capability))

  defp optional_strings(arguments, keys) do
    if Enum.all?(keys, &(is_nil(arguments[&1]) or valid_string(arguments[&1]) == :ok)),
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp valid_string(value)
       when is_binary(value) and byte_size(value) in 1..@max_string_bytes,
       do: if(String.valid?(value), do: :ok, else: {:error, :invalid_query})

  defp valid_string(_value), do: {:error, :invalid_query}
  defp valid_tags(nil), do: :ok

  defp valid_tags(tags) when is_map(tags) and map_size(tags) <= 16 do
    if Enum.all?(tags, fn {key, value} -> valid_string(key) == :ok and JSONValue.value?(value) end),
       do: :ok,
       else: {:error, :invalid_query}
  end

  defp valid_tags(_tags), do: {:error, :invalid_query}
  defp valid_timestamp(nil), do: :ok

  defp valid_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _datetime, 0} -> :ok
      _ -> {:error, :invalid_query}
    end
  end

  defp valid_timestamp(_timestamp), do: {:error, :invalid_query}

  defp validate_keys(arguments, allowed) do
    if JSONValue.map?(arguments) and Map.keys(arguments) -- allowed == [],
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp event_data(nil, _key), do: nil
  defp event_data(event, key), do: get_in(event, ["data", key])
  defp event_data(nil, _key, default), do: default
  defp event_data(event, key, default), do: get_in(event, ["data", key]) || default
  defp event_value(nil, _key), do: nil
  defp event_value(event, key), do: event[key]
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp normalize(value) when is_struct(value, DateTime), do: DateTime.to_iso8601(value)
  defp normalize(nil), do: nil
  defp normalize(value) when is_boolean(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)

  defp normalize(value), do: value
end
