defmodule PtcGateway.RequestAdmission do
  @moduledoc false
  use GenServer

  def start_link(maximum), do: GenServer.start_link(__MODULE__, maximum)

  def acquire(owner) do
    GenServer.call(owner, {:acquire, self()}, :infinity)
  catch
    :exit, _ -> :unavailable
  end

  def release(owner, lease) do
    GenServer.call(owner, {:release, self(), lease}, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(maximum), do: {:ok, %{maximum: maximum, leases: %{}}}

  @impl true
  def handle_call({:acquire, pid}, _from, state) when map_size(state.leases) < state.maximum do
    lease = make_ref()
    monitor = Process.monitor(pid)
    {:reply, {:ok, lease}, %{state | leases: Map.put(state.leases, lease, {pid, monitor})}}
  end

  def handle_call({:acquire, _pid}, _from, state), do: {:reply, :full, state}

  def handle_call({:release, pid, lease}, _from, state) do
    case Map.pop(state.leases, lease) do
      {{^pid, monitor}, leases} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | leases: leases}}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    leases = Map.reject(state.leases, fn {_lease, owner} -> owner == {pid, monitor} end)
    {:noreply, %{state | leases: leases}}
  end
end
