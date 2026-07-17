defmodule PtcViewer.InspectionStore do
  @moduledoc false

  use GenServer

  def start(source), do: GenServer.start(__MODULE__, source)
  def attach(store, owner), do: GenServer.call(store, {:attach, owner})
  def fetch(store), do: GenServer.call(store, :fetch)
  def stop(store), do: GenServer.stop(store)

  @impl GenServer
  def init(source), do: {:ok, %{source: source, owner_ref: nil}}

  @impl GenServer
  def handle_call({:attach, owner}, _from, %{owner_ref: nil} = state) when is_pid(owner) do
    {:reply, :ok, %{state | owner_ref: Process.monitor(owner)}}
  end

  def handle_call(:fetch, _from, state), do: {:reply, {:ok, state.source}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}
end
