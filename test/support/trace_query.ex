defmodule PtcRunner.TestSupport.TraceQuery do
  @moduledoc false

  # Test-only live-source convenience around the production capture and query APIs.
  alias PtcRunner.Kernel.{
    BoundedWorker,
    EventSink,
    QueryCursor,
    SafeMetadata,
    TraceEventValidation,
    TraceLog
  }

  alias PtcRunner.Lisp.RetainedSize
  @default_source_bytes 8_000_000
  @default_retained_bytes 32_000_000
  @default_result_bytes 1_000_000
  @default_capture_directory_entries 4_096
  @default_capture_trace_files 1_024
  @direct_capture_timeout_ms 15_000
  @direct_capture_heap_words 10_000_000

  @enforce_keys [
    :source,
    :source_kind,
    :max_source_bytes,
    :max_retained_bytes,
    :max_result_bytes,
    :max_directory_entries,
    :max_trace_files
  ]
  defstruct @enforce_keys

  @type source :: EventSink.t() | {:file, binary()} | {:directory, binary()}
  @type t :: %__MODULE__{
          source: source(),
          source_kind: :sanitized | :private,
          max_source_bytes: pos_integer(),
          max_retained_bytes: pos_integer(),
          max_result_bytes: pos_integer(),
          max_directory_entries: pos_integer(),
          max_trace_files: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_trace_log}
  def new(opts) when is_list(opts) do
    with {:ok, source, source_kind} <- validate_source(Keyword.get(opts, :source)),
         {:ok, limits} <- trace_log_limits(source, opts) do
      {:ok,
       %__MODULE__{
         source: source,
         source_kind: source_kind,
         max_source_bytes: limits.max_source_bytes,
         max_retained_bytes: limits.max_retained_bytes,
         max_result_bytes: limits.max_result_bytes,
         max_directory_entries: limits.max_directory_entries,
         max_trace_files: limits.max_trace_files
       }}
    else
      _ -> {:error, :invalid_trace_log}
    end
  end

  def new(_opts), do: {:error, :invalid_trace_log}

  defp trace_log_limits({:directory, _path}, opts) do
    allowed = [
      :source,
      :max_source_bytes,
      :max_retained_bytes,
      :max_result_bytes,
      :max_directory_entries,
      :max_trace_files
    ]

    with true <- Keyword.keys(opts) -- allowed == [],
         {:ok, max_source_bytes} <-
           bounded_limit(opts, :max_source_bytes, @default_source_bytes),
         {:ok, max_retained_bytes} <-
           bounded_limit(opts, :max_retained_bytes, @default_retained_bytes),
         {:ok, max_result_bytes} <-
           bounded_limit(opts, :max_result_bytes, @default_result_bytes),
         {:ok, max_directory_entries} <-
           bounded_limit(opts, :max_directory_entries, @default_capture_directory_entries),
         {:ok, max_trace_files} <-
           bounded_limit(opts, :max_trace_files, @default_capture_trace_files) do
      {:ok,
       %{
         max_source_bytes: max_source_bytes,
         max_retained_bytes: max_retained_bytes,
         max_result_bytes: max_result_bytes,
         max_directory_entries: max_directory_entries,
         max_trace_files: max_trace_files
       }}
    else
      _invalid -> {:error, :invalid_trace_log}
    end
  end

  defp trace_log_limits(_source, opts) do
    with true <- Keyword.keys(opts) -- [:source, :max_source_bytes, :max_result_bytes] == [],
         {:ok, max_source_bytes} <- positive_limit(opts, :max_source_bytes, @default_source_bytes),
         {:ok, max_result_bytes} <- positive_limit(opts, :max_result_bytes, @default_result_bytes) do
      {:ok,
       %{
         max_source_bytes: max_source_bytes,
         max_retained_bytes: @default_retained_bytes,
         max_result_bytes: max_result_bytes,
         max_directory_entries: @default_capture_directory_entries,
         max_trace_files: @default_capture_trace_files
       }}
    else
      _invalid -> {:error, :invalid_trace_log}
    end
  end

  defp bounded_limit(opts, key, maximum) do
    case Keyword.get(opts, key, maximum) do
      value when is_integer(value) and value in 1..maximum//1 -> {:ok, value}
      _invalid -> {:error, :invalid_trace_log}
    end
  end

  defp positive_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, :invalid_trace_log}
    end
  end

  @spec query(t(), :list_runs | :get_run | :list_turns | :counters, map()) ::
          {:ok, map()} | {:error, atom()}
  def query(%__MODULE__{} = trace_log, operation, arguments)
      when operation in [:list_runs, :get_run, :list_turns, :counters] and is_map(arguments) do
    with {:ok, events, source_id, source_kind, source_metadata, known_isolated_run_ids} <-
           load(trace_log) do
      result_metadata =
        operation
        |> TraceLog.source_presence_metadata(source_metadata)
        |> reserve_snapshot_hash(trace_log.source, source_id)

      TraceLog.query_loaded(
        events,
        source_id,
        operation,
        arguments,
        trace_log.max_result_bytes,
        source_kind,
        result_metadata,
        known_isolated_run_ids
      )
      |> strip_reserved_snapshot_hash(trace_log.source)
    end
  end

  def query(_trace_log, _operation, _arguments), do: {:error, :invalid_query}

  defp reserve_snapshot_hash(metadata, {:directory, _path}, source_id),
    do: Map.put(metadata, "snapshot_hash", SafeMetadata.fingerprint(source_id))

  defp reserve_snapshot_hash(metadata, _source, _source_id), do: metadata

  defp strip_reserved_snapshot_hash({:ok, result}, {:directory, _path}),
    do: {:ok, Map.delete(result, "snapshot_hash")}

  defp strip_reserved_snapshot_hash(result, _source), do: result

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
    case {reserved_path?(path), File.lstat(path)} do
      {true, _stat} ->
        {:error, :invalid_trace_log}

      {false, {:ok, %File.Stat{type: :regular}}} ->
        {:ok, {:file, Path.expand(path)}, :sanitized}

      _ ->
        {:error, :invalid_trace_log}
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
    case {private_path?(path), File.lstat(path)} do
      {true, {:ok, %File.Stat{type: :regular}}} ->
        {:ok, {:file, Path.expand(path)}, :private}

      _ ->
        {:error, :invalid_trace_log}
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
    |> Jason.encode!()
    |> Jason.decode!()
    |> validate_loaded(trace_log.max_source_bytes)
    |> with_source_metadata(trace_log.source_kind, %{})
  catch
    :exit, _reason -> {:error, :source_unavailable}
  end

  defp load(%__MODULE__{source: {:file, path}} = trace_log) do
    with {:ok, capture} <-
           TraceLog.capture_file(path,
             max_source_bytes: trace_log.max_source_bytes,
             source_kind: trace_log.source_kind
           ) do
      {:ok, capture.events, capture.source_id, trace_log.source_kind, %{}, MapSet.new()}
    end
  end

  defp load(%__MODULE__{source: {:directory, directory}} = trace_log) do
    case BoundedWorker.run(
           fn -> load_directory_admission(directory, trace_log) end,
           timeout_ms: @direct_capture_timeout_ms,
           max_heap_words: @direct_capture_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, :heap_exceeded} -> {:error, :source_retained_limit_exceeded}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  defp load_directory_admission(directory, trace_log) do
    with {:ok, capture} <-
           TraceLog.capture_directory(directory,
             max_source_bytes: trace_log.max_source_bytes,
             max_directory_entries: trace_log.max_directory_entries,
             max_trace_files: trace_log.max_trace_files,
             source_kind: trace_log.source_kind,
             include_sanitized: false
           ),
         {:ok, capture} <- retain_transient_directory(capture, trace_log.max_retained_bytes) do
      {:ok, capture.events, capture.source_id, capture.run_sources,
       TraceLog.directory_source_metadata(capture), capture.known_isolated_run_ids}
    end
  end

  defp with_source_metadata({:ok, events, source_id}, source_kind, metadata),
    do: {:ok, events, source_id, source_kind, metadata, MapSet.new()}

  defp with_source_metadata({:error, _reason} = error, _source_kind, _metadata), do: error

  defp retain_transient_directory(capture, max_retained_bytes) do
    retained_capture = RetainedSize.detach_binaries(capture)

    case RetainedSize.bytes(retained_capture) do
      retained_bytes when is_integer(retained_bytes) and retained_bytes <= max_retained_bytes ->
        {:ok, retained_capture}

      retained_bytes when is_integer(retained_bytes) ->
        {:error, :source_retained_limit_exceeded}

      :oversized ->
        {:error, :source_retained_limit_exceeded}
    end
  end

  defp validate_loaded(events, max_bytes) when is_list(events) do
    encoded_bytes = Enum.reduce(events, 0, &(&2 + byte_size(Jason.encode!(&1))))

    with true <- encoded_bytes <= max_bytes,
         :ok <- TraceEventValidation.validate(events) do
      source_id = QueryCursor.query_digest(events)

      {:ok, events, source_id}
    else
      false -> {:error, :source_limit_exceeded}
      {:error, _reason} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  defp private_path?(path), do: String.ends_with?(path, ".private.jsonl")
  defp inspection_path?(path), do: String.ends_with?(path, ".ptcins")
  defp reserved_path?(path), do: private_path?(path) or inspection_path?(path)
end
