defmodule PtcRunner.Kernel.ViewerAdapter do
  @moduledoc """
  Internal read-only viewer adapter over the shared TraceLog query layer.

  The sibling viewer delegates here so it does not create a competing trace
  parser, query model, or source authorization boundary. Inspection artifacts
  are loaded and validated once at Viewer startup; requests receive an opaque
  immutable grant and never reopen the configured path.
  """

  alias PtcRunner.Kernel.{
    ConversationProjection,
    InspectionArtifact,
    InspectionPageCollector,
    InspectionQuery,
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

  @opaque inspection_grant :: {:inspection_v3, binary(), map()}

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
         :ok <- InspectionArtifact.validate_correlations(records, trace_page["items"]),
         {:ok, compiled} <- compile_inspection(records, trace_page, capture.source_id) do
      {:ok, {:inspection_v3, run_id, compiled}}
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
  def conversation(grant, run_id) do
    with {:ok, turns} <- inspection_collection(grant, run_id, :turns),
         result = ConversationProjection.present_page(turns),
         true <- byte_size(Jason.encode!(result)) <= 1_000_000 do
      {:ok, result}
    else
      false -> {:error, :result_limit_exceeded}
      {:error, _reason} = error -> error
    end
  end

  @spec preludes(inspection_grant(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Returns the pinned run's exact effective prelude sources."
  def preludes(grant, run_id), do: inspection_collection(grant, run_id, :effective_preludes)

  defp inspection_collection({:inspection_v3, granted_run_id, compiled}, run_id, operation)
       when is_binary(granted_run_id) and is_map(compiled) and is_binary(run_id) do
    if granted_run_id == run_id do
      all_inspection(compiled, operation, run_id)
    else
      {:error, :inspection_run_mismatch}
    end
  end

  defp inspection_collection(_grant, _run_id, _operation),
    do: {:error, :invalid_inspection_query}

  defp compile_inspection(records, trace_page, trace_source_id) do
    trace_analysis = TraceLog.compile_analysis(trace_page["items"], :private)

    analysis_facts = %{
      "trace_snapshot_hash" => trace_page["snapshot_hash"],
      "runs" => trace_analysis.facts_by_run_id
    }

    InspectionQuery.compile([records], trace_source_id, analysis_facts)
  end

  defp all_inspection(compiled, operation, run_id) do
    query = fn arguments ->
      InspectionQuery.query(
        compiled.collections,
        compiled.source_id,
        operation,
        arguments,
        1_000_000
      )
    end

    InspectionPageCollector.collect(
      query,
      operation,
      run_id,
      SafeMetadata.fingerprint(compiled.source_id)
    )
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
