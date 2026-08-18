defmodule PtcGateway.Admission do
  @moduledoc """
  Non-blocking in-flight call admission for one gateway instance.

  Saturation yields `:saturated` immediately. Release is exactly-once: checkout
  monitors the leaseholder, and checkin or owner death frees the slot.
  """

  use GenServer

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec checkout(pid(), pid()) :: :ok | :saturated
  def checkout(server, leaseholder) when is_pid(server) and is_pid(leaseholder) do
    GenServer.call(server, {:checkout, leaseholder})
  end

  @spec checkin(pid(), pid()) :: :ok
  def checkin(server, leaseholder) when is_pid(server) and is_pid(leaseholder) do
    GenServer.cast(server, {:checkin, leaseholder})
  end

  @impl GenServer
  def init(opts) do
    ceiling = Keyword.fetch!(opts, :ceiling)

    if is_integer(ceiling) and ceiling > 0 do
      {:ok, %{ceiling: ceiling, leases: %{}}}
    else
      {:stop, :invalid_admission_ceiling}
    end
  end

  @impl GenServer
  def handle_call({:checkout, leaseholder}, _from, state) do
    cond do
      Map.has_key?(state.leases, leaseholder) ->
        {:reply, :ok, state}

      map_size(state.leases) >= state.ceiling ->
        {:reply, :saturated, state}

      true ->
        ref = Process.monitor(leaseholder)
        {:reply, :ok, %{state | leases: Map.put(state.leases, leaseholder, ref)}}
    end
  end

  @impl GenServer
  def handle_cast({:checkin, leaseholder}, state) do
    {:noreply, release(state, leaseholder)}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, release(state, pid)}
  end

  defp release(state, leaseholder) do
    case Map.pop(state.leases, leaseholder) do
      {nil, _leases} ->
        state

      {ref, leases} ->
        Process.demonitor(ref, [:flush])
        %{state | leases: leases}
    end
  end
end
