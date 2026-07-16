defmodule PtcRunner.Kernel.ViewerAdapter do
  @moduledoc """
  Internal read-only viewer adapter over the shared TraceLog query layer.

  The sibling viewer delegates here so it does not create a competing trace
  parser, query model, or source authorization boundary. Inspection artifacts
  are loaded and validated once at Viewer startup; requests receive an opaque
  immutable grant and never reopen the configured path.
  """

  alias PtcRunner.Kernel.{InspectionArtifact, TraceLog}

  @spec query(TraceLog.source(), atom(), map()) :: {:ok, map()} | {:error, atom()}
  @doc "Constructs a bounded TraceLog for the source and executes one query."
  def query(source, operation, arguments) when is_map(arguments) do
    with {:ok, trace_log} <- TraceLog.new(source: source),
         do: TraceLog.query(trace_log, operation, arguments)
  end

  @opaque inspection_grant :: {:inspection_v1, binary(), [map()]}

  @spec pin_inspection(binary()) :: {:ok, inspection_grant()} | {:error, atom()}
  @doc "Loads and pins one private artifact as an immutable Viewer grant."
  def pin_inspection(path) when is_binary(path) do
    with {:ok, [%{"run_id" => run_id} | _rest] = records} <- InspectionArtifact.load(path) do
      {:ok, {:inspection_v1, run_id, records}}
    end
  end

  def pin_inspection(_path), do: {:error, :invalid_inspection_query}

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
end
