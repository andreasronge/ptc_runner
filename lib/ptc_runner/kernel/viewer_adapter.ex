defmodule PtcRunner.Kernel.ViewerAdapter do
  @moduledoc """
  Internal read-only viewer adapter over the shared TraceLog query layer.

  The sibling viewer delegates here so it does not create a competing trace
  parser, query model, or source authorization boundary. Inspection artifacts
  are loaded and validated once at Viewer startup; requests receive an opaque
  immutable grant and never reopen the configured path.
  """

  alias PtcRunner.Kernel.{
    InspectionArtifact,
    InspectionQuery,
    RunAnalysis,
    SafeMetadata,
    TraceLog
  }

  @type inspection_trace_source ::
          {:file | :directory | :private_file | :private_directory, binary()}

  @spec query(TraceLog.source(), atom(), map()) :: {:ok, map()} | {:error, atom()}
  @doc "Constructs a bounded TraceLog for the source and executes one query."
  def query(source, operation, arguments) when is_map(arguments) do
    with {:ok, trace_log} <- TraceLog.new(source: source),
         do: TraceLog.query(trace_log, operation, arguments)
  end

  @opaque inspection_grant :: {:inspection_v2, binary(), map(), [map()], binary()}

  @spec pin_inspection(binary(), inspection_trace_source()) ::
          {:ok, inspection_grant()}
          | {:error, atom() | InspectionArtifact.unsupported_schema_error()}
  @doc "Pins one artifact only after validating it against an immutable path source."
  def pin_inspection(path, trace_source) when is_binary(path) do
    with {:ok, [%{"run_id" => run_id, "trace_id" => trace_id} | _rest] = records} <-
           InspectionArtifact.load(path),
         {:ok, capture} <- capture_trace(trace_source),
         {:ok, %{"trace_id" => ^trace_id}} <-
           trace_query(capture, :get_run, %{"run_id" => run_id}),
         {:ok, trace_page} <- all_turns(capture, run_id),
         :ok <- InspectionArtifact.validate_correlations(records, trace_page["items"]) do
      {:ok, {:inspection_v2, run_id, trace_page, records, capture.source_id}}
    else
      {:error, reason} when reason in [:not_found, :invalid_query] ->
        {:error, :inspection_correlation_missing}

      {:ok, %{"trace_id" => _other_trace}} ->
        {:error, :inspection_correlation_missing}

      {:error, _reason} = error ->
        error
    end
  end

  def pin_inspection(_path, _trace_source), do: {:error, :invalid_inspection_query}

  @spec conversation(inspection_grant(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Builds a semantic conversation from the pinned, already validated records."
  def conversation({:inspection_v2, granted_run_id, trace_page, records, trace_source_id}, run_id)
      when is_binary(granted_run_id) and is_map(trace_page) and is_list(records) and
             is_binary(trace_source_id) and is_binary(run_id) do
    if granted_run_id == run_id do
      with {:ok, compiled} <- InspectionQuery.compile([records], trace_source_id),
           {:ok, exchanges} <- all_inspection(compiled, :model_exchanges, run_id),
           {:ok, programs} <- all_inspection(compiled, :generated_sources, run_id),
           result = RunAnalysis.conversation_result(trace_page, exchanges, programs),
           true <- byte_size(Jason.encode!(result)) <= 1_000_000 do
        {:ok, result}
      else
        false -> {:error, :result_limit_exceeded}
        {:error, _reason} = error -> error
      end
    else
      {:error, :inspection_run_mismatch}
    end
  end

  def conversation(_grant, _run_id), do: {:error, :invalid_inspection_query}

  defp all_inspection(compiled, operation, run_id),
    do: all_inspection(compiled, operation, run_id, nil, [], nil, 0)

  defp all_inspection(_compiled, _operation, _run_id, _cursor, _items, _hash, 1_000),
    do: {:error, :result_limit_exceeded}

  defp all_inspection(compiled, operation, run_id, cursor, items, hash, pages) do
    arguments = %{"run_id" => run_id, "limit" => 1_000}
    arguments = if cursor, do: Map.put(arguments, "cursor", cursor), else: arguments

    with {:ok, page} <-
           InspectionQuery.query(
             compiled.collections,
             compiled.source_id,
             operation,
             arguments,
             1_000_000
           ),
         next_items = items ++ page["items"],
         true <- byte_size(Jason.encode!(next_items)) <= 1_000_000 do
      case page["next_cursor"] do
        nil ->
          {:ok,
           %{
             "items" => next_items,
             "next_cursor" => nil,
             "omitted_count" => 0,
             "truncated" => false,
             "snapshot_hash" => hash || SafeMetadata.fingerprint(compiled.source_id)
           }}

        next ->
          all_inspection(
            compiled,
            operation,
            run_id,
            next,
            next_items,
            hash || SafeMetadata.fingerprint(compiled.source_id),
            pages + 1
          )
      end
    else
      false -> {:error, :result_limit_exceeded}
      {:error, _reason} = error -> error
    end
  end

  defp capture_trace({:directory, directory}), do: TraceLog.capture_directory(directory)

  defp capture_trace({:file, path}) when is_binary(path),
    do: TraceLog.capture_file(path)

  defp capture_trace({:private_directory, directory}),
    do: TraceLog.capture_directory(directory, source_kind: :private, include_sanitized: false)

  defp capture_trace({:private_file, path}) when is_binary(path),
    do: TraceLog.capture_file(path, source_kind: :private)

  defp capture_trace(_source), do: {:error, :invalid_inspection_query}

  defp trace_query(capture, operation, arguments) do
    TraceLog.query_loaded(
      capture.events,
      capture.source_id,
      operation,
      arguments,
      1_000_000,
      capture.run_sources
    )
  end

  defp all_turns(capture, run_id), do: all_turns(capture, run_id, nil, [], 0)

  defp all_turns(_capture, _run_id, _cursor, _events, 10_000),
    do: {:error, :source_limit_exceeded}

  defp all_turns(capture, run_id, cursor, events, pages) do
    arguments = %{"run_id" => run_id, "limit" => 100}
    arguments = if cursor, do: Map.put(arguments, "cursor", cursor), else: arguments

    with {:ok, %{"items" => items, "next_cursor" => next_cursor}} <-
           trace_query(capture, :list_turns, arguments) do
      events = [events, items]

      if next_cursor,
        do: all_turns(capture, run_id, next_cursor, events, pages + 1),
        else:
          {:ok,
           %{
             "items" => List.flatten(events),
             "next_cursor" => nil,
             "omitted_count" => 0,
             "truncated" => false,
             "snapshot_hash" => SafeMetadata.fingerprint(capture.source_id)
           }}
    end
  end
end
