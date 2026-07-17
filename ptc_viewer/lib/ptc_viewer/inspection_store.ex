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

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
