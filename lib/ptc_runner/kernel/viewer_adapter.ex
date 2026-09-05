defmodule PtcRunner.Kernel.ViewerAdapter do
  @moduledoc """
  Internal read-only Viewer adapter over owner-bound trace and inspection snapshots.

  The sibling viewer delegates here so it does not create a competing trace
  parser, query model, or source authorization boundary. Inspection admission
  pins and validates the selected V1 artifact once at Viewer startup; requests
  receive an opaque grant backed by bounded ETS indexes and pinned range reads.
  """

  alias PtcRunner.Kernel.{
    ConversationProjection,
    InspectionArtifact,
    InspectionPageCollector,
    InspectionSnapshot,
    TraceLog,
    TraceSnapshot
  }

  @type inspection_trace_source ::
          {:file | :directory | :private_file | :private_directory, binary()}

  @spec query(TraceLog.source(), atom(), map()) :: {:ok, map()} | {:error, atom()}
  @doc "Constructs a bounded TraceLog for the source and executes one query."
  def query(source, operation, arguments) when is_map(arguments) do
    with {:ok, trace_log} <- TraceLog.new(source: source),
         do: TraceLog.query(trace_log, operation, arguments)
  end

  @opaque inspection_grant ::
            {:inspection_v4, binary(), InspectionSnapshot.t(), TraceSnapshot.t()}

  @spec pin_inspection(binary(), inspection_trace_source()) ::
          {:ok, inspection_grant()}
          | {:error, atom()}
  @doc "Pins one artifact only after independent admission against its paired trace snapshot."
  def pin_inspection(path, trace_source) when is_binary(path) do
    case start_trace_snapshot(trace_source) do
      {:ok, trace_snapshot} ->
        with {:ok, run_id} <- artifact_run_id(path, trace_snapshot),
             {:ok, inspection_snapshot} <-
               start_inspection_snapshot(path, run_id, trace_snapshot) do
          {:ok, {:inspection_v4, run_id, inspection_snapshot, trace_snapshot}}
        else
          {:error, _reason} = error ->
            TraceSnapshot.stop(trace_snapshot)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def pin_inspection(_path, _trace_source), do: {:error, :invalid_inspection_query}

  @spec conversation(inspection_grant(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Builds a semantic conversation from the admitted snapshot."
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

  @spec result(inspection_grant(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Returns the pinned run's authorized terminal application result."
  def result({:inspection_v4, granted_run_id, snapshot, _trace_snapshot}, run_id)
      when is_binary(granted_run_id) and is_binary(run_id) do
    cond do
      not InspectionSnapshot.valid?(snapshot) -> {:error, :invalid_inspection_query}
      granted_run_id != run_id -> {:error, :inspection_run_mismatch}
      true -> InspectionSnapshot.query(snapshot, :result, %{"run_id" => run_id})
    end
  end

  def result(_grant, _run_id), do: {:error, :invalid_inspection_query}

  @spec preludes(inspection_grant(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Returns the pinned run's exact effective prelude sources."
  def preludes(grant, run_id), do: inspection_collection(grant, run_id, :effective_preludes)

  @spec execution_errors(inspection_grant(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Returns the pinned run's authorized workflow execution-error records."
  def execution_errors(grant, run_id),
    do: inspection_collection(grant, run_id, :execution_errors)

  @spec explicit_failure_values(inspection_grant(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Returns the pinned run's dedicated explicit-failure-value records."
  def explicit_failure_values(grant, run_id),
    do: inspection_collection(grant, run_id, :explicit_failure_values)

  defp inspection_collection(
         {:inspection_v4, granted_run_id, snapshot, _trace_snapshot},
         run_id,
         operation
       )
       when is_binary(granted_run_id) and is_binary(run_id) do
    cond do
      not InspectionSnapshot.valid?(snapshot) -> {:error, :invalid_inspection_query}
      granted_run_id != run_id -> {:error, :inspection_run_mismatch}
      true -> all_inspection(snapshot, operation, run_id)
    end
  end

  defp inspection_collection(_grant, _run_id, _operation),
    do: {:error, :invalid_inspection_query}

  defp all_inspection(snapshot, operation, run_id) do
    query = &InspectionSnapshot.query(snapshot, operation, &1)

    InspectionPageCollector.collect(
      query,
      operation,
      run_id,
      nil
    )
  end

  defp artifact_run_id(path, trace_snapshot) do
    case InspectionArtifact.identity(path) do
      {:ok, %{run_id: run_id}} -> {:ok, run_id}
      {:error, :malformed_source} -> resolve_empty_run_id(path, trace_snapshot)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_empty_run_id(path, trace_snapshot) do
    with {:ok, %{run_id_sha256: run_hash, trace_id_sha256: trace_hash}} <-
           InspectionArtifact.empty_identity_hashes(path),
         {:ok, %{run_id: run_id}} <-
           TraceSnapshot.resolve_inspection_identity(trace_snapshot, run_hash, trace_hash) do
      {:ok, run_id}
    end
  end

  defp start_trace_snapshot({:directory, directory}),
    do: TraceSnapshot.start({:directory, directory})

  defp start_trace_snapshot({:file, path}),
    do: TraceSnapshot.start({:viewer_file, path})

  defp start_trace_snapshot({:private_directory, directory}),
    do: TraceSnapshot.start({:private_viewer_directory, directory})

  defp start_trace_snapshot({:private_file, path}),
    do: TraceSnapshot.start({:private_viewer_file, path})

  defp start_trace_snapshot(_source), do: {:error, :invalid_inspection_query}

  defp start_inspection_snapshot(path, run_id, trace_snapshot) do
    InspectionSnapshot.start({:viewer_file, path, run_id}, trace_snapshot)
  end
end
