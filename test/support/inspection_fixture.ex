defmodule PtcRunner.TestSupport.InspectionFixture do
  @moduledoc false

  alias PtcRunner.Kernel.{
    InspectionArtifact,
    InspectionSnapshot,
    TraceSnapshot
  }

  @type inspection_trace_source ::
          {:file | :directory | :private_file | :private_directory, binary()}

  @type inspection_grant :: %{inspection: term(), trace: term()}

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
          {:ok,
           %{
             inspection: {:inspection_snapshot, inspection_snapshot},
             trace: {:trace_snapshot, trace_snapshot}
           }}
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
