defmodule PtcRunner.Kernel.ProviderAdmission do
  @moduledoc """
  VM-wide non-blocking semaphore for provider-task dispatch.

  The owner is claimed at birth into `:persistent_term` and never erased.
  A later owner creation refuses while that claim exists, so owner death
  poisons the VM until restart rather than resetting capacity under live
  leaseholders. `restart: :temporary` is required of the supervisor child
  spec; it is not the whole guarantee.

  When no claim exists, checkout is a no-op so CLI runs are unchanged.
  """

  use GenServer

  @claim_key {__MODULE__, :claim}

  @type checkout :: :not_required | :ok | {:error, :saturated | :poisoned}

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec claimed?() :: boolean()
  def claimed? do
    match?({:ok, _identity}, claim_get())
  end

  @spec checkout(pid()) :: checkout()
  def checkout(leaseholder) when is_pid(leaseholder) do
    case claim_get() do
      :absent ->
        :not_required

      {:ok, _identity} ->
        case Process.whereis(__MODULE__) do
          nil ->
            {:error, :poisoned}

          pid ->
            try do
              GenServer.call(pid, {:checkout, leaseholder}, 5_000)
            catch
              :exit, _reason -> {:error, :poisoned}
            end
        end
    end
  end

  @spec checkin(pid()) :: :ok
  def checkin(leaseholder) when is_pid(leaseholder) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        GenServer.cast(pid, {:checkin, leaseholder})
    end
  end

  @spec ceiling() :: pos_integer() | nil
  def ceiling do
    case Process.whereis(__MODULE__) do
      nil ->
        nil

      pid ->
        try do
          GenServer.call(pid, :ceiling, 5_000)
        catch
          :exit, _reason -> nil
        end
    end
  end

  @spec in_use() :: non_neg_integer()
  def in_use do
    case Process.whereis(__MODULE__) do
      nil ->
        0

      pid ->
        try do
          GenServer.call(pid, :in_use, 5_000)
        catch
          :exit, _reason -> 0
        end
    end
  end

  @impl GenServer
  def init(opts) do
    ceiling = Keyword.fetch!(opts, :ceiling)

    if is_integer(ceiling) and ceiling > 0 do
      case claim() do
        :ok ->
          {:ok, %{ceiling: ceiling, leases: %{}}}

        :error ->
          {:stop, :admission_claimed}
      end
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
        {:reply, {:error, :saturated}, state}

      not Process.alive?(leaseholder) ->
        {:reply, {:error, :saturated}, state}

      true ->
        ref = Process.monitor(leaseholder)
        {:reply, :ok, %{state | leases: Map.put(state.leases, leaseholder, ref)}}
    end
  end

  def handle_call(:ceiling, _from, state), do: {:reply, state.ceiling, state}
  def handle_call(:in_use, _from, state), do: {:reply, map_size(state.leases), state}

  @impl GenServer
  def handle_cast({:checkin, leaseholder}, state) do
    {:noreply, drop_lease(state, leaseholder)}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, leaseholder, _reason}, state) do
    {:noreply, drop_lease(state, leaseholder)}
  end

  defp drop_lease(state, leaseholder) do
    case Map.pop(state.leases, leaseholder) do
      {nil, _leases} ->
        state

      {ref, leases} ->
        Process.demonitor(ref, [:flush])
        %{state | leases: leases}
    end
  end

  defp claim do
    identity = {node(), self(), System.system_time(:native)}

    case claim_get() do
      :absent ->
        :persistent_term.put(@claim_key, identity)

        case :persistent_term.get(@claim_key) do
          ^identity -> :ok
          _other -> :error
        end

      {:ok, _existing} ->
        :error
    end
  end

  defp claim_get do
    case :persistent_term.get(@claim_key, :absent) do
      :absent -> :absent
      identity -> {:ok, identity}
    end
  end
end
