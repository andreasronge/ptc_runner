defmodule PtcRunner.ProjectViewerAdapter do
  @moduledoc false

  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.ViewerSnapshotProjection
  alias PtcRunner.ViewerSnapshotStore

  @spec query(
          {:trace_snapshot, TraceSnapshot.t()}
          | {:viewer_snapshot_store, ViewerSnapshotStore.t()},
          :list_runs | :get_run | :list_turns | :counters,
          map()
        ) :: {:ok, map()} | {:error, atom()}
  def query({:trace_snapshot, snapshot}, operation, arguments),
    do: ViewerSnapshotProjection.query({:trace_snapshot, snapshot}, operation, arguments)

  def query({:viewer_snapshot_store, store}, operation, arguments),
    do: ViewerSnapshotStore.query(store, operation, arguments)

  def query(_source, _operation, _arguments), do: {:error, :invalid_query}

  @spec conversation(
          {:inspection_snapshot, InspectionSnapshot.t()}
          | {:viewer_snapshot_store, ViewerSnapshotStore.t()},
          binary()
        ) ::
          {:ok, map()} | {:error, atom()}
  def conversation({:inspection_snapshot, snapshot}, run_id),
    do: ViewerSnapshotProjection.conversation({:inspection_snapshot, snapshot}, run_id)

  def conversation({:viewer_snapshot_store, store}, run_id),
    do: ViewerSnapshotStore.conversation(store, run_id)

  def conversation(_source, _run_id), do: {:error, :invalid_inspection_query}

  @spec generated_sources(
          {:inspection_snapshot, InspectionSnapshot.t()}
          | {:viewer_snapshot_store, ViewerSnapshotStore.t()},
          binary()
        ) :: {:ok, map()} | {:error, atom()}
  def generated_sources({:inspection_snapshot, snapshot}, run_id),
    do: ViewerSnapshotProjection.generated_sources({:inspection_snapshot, snapshot}, run_id)

  def generated_sources({:viewer_snapshot_store, store}, run_id),
    do: ViewerSnapshotStore.generated_sources(store, run_id)

  def generated_sources(_source, _run_id), do: {:error, :invalid_inspection_query}

  @spec result(
          {:inspection_snapshot, InspectionSnapshot.t()}
          | {:viewer_snapshot_store, ViewerSnapshotStore.t()},
          binary()
        ) ::
          {:ok, map()} | {:error, atom()}
  def result({:inspection_snapshot, snapshot}, run_id),
    do: ViewerSnapshotProjection.result({:inspection_snapshot, snapshot}, run_id)

  def result({:viewer_snapshot_store, store}, run_id),
    do: ViewerSnapshotStore.result(store, run_id)

  def result(_source, _run_id), do: {:error, :invalid_inspection_query}

  @spec preludes(
          {:inspection_snapshot, InspectionSnapshot.t()}
          | {:viewer_snapshot_store, ViewerSnapshotStore.t()},
          binary()
        ) ::
          {:ok, map()} | {:error, atom()}
  def preludes({:inspection_snapshot, snapshot}, run_id),
    do: ViewerSnapshotProjection.preludes({:inspection_snapshot, snapshot}, run_id)

  def preludes({:viewer_snapshot_store, store}, run_id),
    do: ViewerSnapshotStore.preludes(store, run_id)

  def preludes(_source, _run_id), do: {:error, :invalid_inspection_query}

  @spec execution_errors(
          {:inspection_snapshot, InspectionSnapshot.t()}
          | {:viewer_snapshot_store, ViewerSnapshotStore.t()},
          binary()
        ) ::
          {:ok, map()} | {:error, atom()}
  def execution_errors({:inspection_snapshot, snapshot}, run_id),
    do: ViewerSnapshotProjection.execution_errors({:inspection_snapshot, snapshot}, run_id)

  def execution_errors({:viewer_snapshot_store, store}, run_id),
    do: ViewerSnapshotStore.execution_errors(store, run_id)

  def execution_errors(_source, _run_id), do: {:error, :invalid_inspection_query}

  @spec explicit_failure_values(
          {:inspection_snapshot, InspectionSnapshot.t()}
          | {:viewer_snapshot_store, ViewerSnapshotStore.t()},
          binary()
        ) ::
          {:ok, map()} | {:error, atom()}
  def explicit_failure_values({:inspection_snapshot, snapshot}, run_id),
    do: ViewerSnapshotProjection.explicit_failure_values({:inspection_snapshot, snapshot}, run_id)

  def explicit_failure_values({:viewer_snapshot_store, store}, run_id),
    do: ViewerSnapshotStore.explicit_failure_values(store, run_id)

  def explicit_failure_values(_source, _run_id), do: {:error, :invalid_inspection_query}
end
