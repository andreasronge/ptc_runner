defmodule PtcRunner.Kernel.ViewerAdapter do
  @moduledoc """
  Internal read-only viewer adapter over the shared TraceLog query layer.

  The sibling viewer delegates here so it does not create a competing trace
  parser, query model, or source authorization boundary.
  """

  alias PtcRunner.Kernel.{InspectionArtifact, TraceLog}

  @spec query(TraceLog.source(), atom(), map()) :: {:ok, map()} | {:error, atom()}
  @doc "Constructs a bounded TraceLog for the source and executes one query."
  def query(source, operation, arguments) when is_map(arguments) do
    with {:ok, trace_log} <- TraceLog.new(source: source),
         do: TraceLog.query(trace_log, operation, arguments)
  end

  @spec inspection(binary(), binary()) :: {:ok, map()} | {:error, atom()}
  @doc "Loads one fixed private artifact and returns records for its exact run identity."
  def inspection(path, run_id) when is_binary(path) and is_binary(run_id) do
    with {:ok, records} <- InspectionArtifact.load(path),
         true <- Enum.all?(records, &(&1["run_id"] == run_id)) do
      {:ok, %{"run_id" => run_id, "records" => records}}
    else
      false -> {:error, :inspection_run_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def inspection(_path, _run_id), do: {:error, :invalid_inspection_query}
end
