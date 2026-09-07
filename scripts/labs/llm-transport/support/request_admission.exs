defmodule PtcRunner.Labs.RequestAdmission do
  @moduledoc false
  use GenServer

  # Counts disposable request workers, including preparation and publication.
  # No resource cleanup is owned here: the worker must be dead before reuse.
  # RunAdmission independently holds execution capacity through provider cleanup.
  def child_spec(capacity),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [capacity]}, restart: :temporary}

  def start_link(capacity) when is_integer(capacity) and capacity > 0,
    do: GenServer.start_link(__MODULE__, capacity)

  def snapshot(host), do: call(host, :snapshot)

  def run(host, callback) do
    with :ok <- call(host, :admit), do: callback.()
  end

  defp call(host, message) do
    GenServer.call(host, message)
  catch
    :exit, _ -> {:error, :request_admission_unavailable}
  end

  @impl true
  def init(capacity), do: {:ok, %{capacity: capacity, workers: %{}}}

  @impl true
  def handle_call(:snapshot, _, state),
    do: {:reply, %{capacity: state.capacity, in_use: map_size(state.workers)}, state}

  def handle_call(:admit, {worker, _}, state) do
    cond do
      Map.has_key?(state.workers, worker) ->
        {:reply, {:error, :request_admission_unavailable}, state}

      map_size(state.workers) >= state.capacity ->
        {:reply, {:error, :request_capacity_exhausted}, state}

      true ->
        ref = Process.monitor(worker)
        {:reply, :ok, %{state | workers: Map.put(state.workers, worker, ref)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, worker, _}, state) do
    workers =
      if state.workers[worker] == ref, do: Map.delete(state.workers, worker), else: state.workers

    {:noreply, %{state | workers: workers}}
  end
end
