defmodule PtcRunner.Kernel.ViewerAdapter do
  @moduledoc """
  Internal read-only viewer adapter over the shared TraceLog query layer.

  The sibling viewer delegates here so it does not create a competing trace
  parser, query model, or source authorization boundary. Inspection artifacts
  are loaded and validated once at Viewer startup; requests receive an opaque
  immutable grant and never reopen the configured path.
  """

  alias PtcRunner.Kernel.{InspectionArtifact, TraceLog}

  @spec query(TraceLog.source(), atom(), map()) ::
          {:ok, map()} | {:error, atom() | TraceLog.query_error()}
  @doc "Constructs a bounded TraceLog for the source and executes one query."
  def query(source, operation, arguments) when is_map(arguments) do
    with {:ok, trace_log} <- TraceLog.new(source: source),
         do: TraceLog.query(trace_log, operation, arguments)
  end

  @opaque inspection_grant :: {:inspection_v1, binary(), [map()]}

  @spec pin_inspection(binary(), TraceLog.source()) ::
          {:ok, inspection_grant()} | {:error, atom()}
  @doc "Pins one artifact only after validating it against its canonical run."
  def pin_inspection(path, trace_source) when is_binary(path) do
    with {:ok, [%{"run_id" => run_id, "trace_id" => trace_id} | _rest] = records} <-
           InspectionArtifact.load(path),
         {:ok, trace_log} <- TraceLog.new(source: trace_source),
         {:ok, %{"trace_id" => ^trace_id}} <-
           TraceLog.query(trace_log, :get_run, %{"run_id" => run_id}),
         {:ok, events} <- all_turns(trace_log, run_id),
         :ok <- InspectionArtifact.validate_correlations(records, events) do
      {:ok, {:inspection_v1, run_id, records}}
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

  @spec inspection(inspection_grant(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Returns pinned records only for the grant's exact run identity."
  def inspection({:inspection_v1, granted_run_id, records}, run_id)
      when is_binary(granted_run_id) and is_list(records) and is_binary(run_id) do
    if granted_run_id == run_id do
      {:ok, %{"run_id" => run_id, "records" => records}}
    else
      {:error, :inspection_run_mismatch}
    end
  end

  def inspection(_grant, _run_id), do: {:error, :invalid_inspection_query}

  defp all_turns(trace_log, run_id), do: all_turns(trace_log, run_id, nil, [], 0)

  defp all_turns(_trace_log, _run_id, _cursor, _events, 10_000),
    do: {:error, :source_limit_exceeded}

  defp all_turns(trace_log, run_id, cursor, events, pages) do
    arguments = %{"run_id" => run_id, "limit" => 100}
    arguments = if cursor, do: Map.put(arguments, "cursor", cursor), else: arguments

    with {:ok, %{"items" => items, "next_cursor" => next_cursor}} <-
           TraceLog.query(trace_log, :list_turns, arguments) do
      events = [events, items]

      if next_cursor,
        do: all_turns(trace_log, run_id, next_cursor, events, pages + 1),
        else: {:ok, List.flatten(events)}
    end
  end
end
