defmodule PtcRunner.Kernel.ProjectViewerAdapter do
  @moduledoc false

  alias PtcRunner.Kernel.ConversationProjection
  alias PtcRunner.Kernel.InspectionPageCollector
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.TraceSnapshot

  @spec query(
          {:trace_snapshot, TraceSnapshot.t()},
          :list_runs | :get_run | :list_turns | :counters,
          map()
        ) :: {:ok, map()} | {:error, atom()}
  def query({:trace_snapshot, snapshot}, operation, arguments),
    do: TraceSnapshot.query(snapshot, operation, arguments)

  def query(_source, _operation, _arguments), do: {:error, :invalid_query}

  @spec conversation({:inspection_snapshot, InspectionSnapshot.t()}, binary()) ::
          {:ok, map()} | {:error, atom()}
  def conversation({:inspection_snapshot, snapshot}, run_id) do
    with {:ok, page} <- collect(snapshot, :turns, run_id),
         result = ConversationProjection.present_page(page),
         true <- byte_size(Jason.encode!(result)) <= 1_000_000 do
      {:ok, result}
    else
      false -> {:error, :result_limit_exceeded}
      {:error, _reason} = error -> error
    end
  end

  def conversation(_source, _run_id), do: {:error, :invalid_inspection_query}

  @spec preludes({:inspection_snapshot, InspectionSnapshot.t()}, binary()) ::
          {:ok, map()} | {:error, atom()}
  def preludes({:inspection_snapshot, snapshot}, run_id),
    do: collect(snapshot, :effective_preludes, run_id)

  def preludes(_source, _run_id), do: {:error, :invalid_inspection_query}

  @spec collect(InspectionSnapshot.t(), :turns | :effective_preludes, binary()) ::
          {:ok, map()} | {:error, atom()}
  defp collect(snapshot, operation, run_id) do
    query = &InspectionSnapshot.query(snapshot, operation, &1)
    InspectionPageCollector.collect(query, operation, run_id)
  end
end
