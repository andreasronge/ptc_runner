defmodule PtcViewer.InspectionStore do
  @moduledoc false

  use GenServer

  alias PtcViewer.OwnerStatusRedaction

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

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: OwnerStatusRedaction.format(status)
  else
    def format_status(status), do: OwnerStatusRedaction.format(status)
  end

  @impl GenServer
  def format_status(reason, status), do: OwnerStatusRedaction.format(reason, status)
end
