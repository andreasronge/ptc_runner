defmodule PtcRunner.Kernel.HostCredentialLease do
  @moduledoc false

  use GenServer

  @max_leases 128
  @operation_timeout_ms 1_000
  @reply_timeout_ms 1_100

  @spec start(pid()) :: {:ok, pid(), :atomics.atomics_ref(), :ets.tid()} | {:error, term()}
  def start(authority_owner) when is_pid(authority_owner) do
    fence = :atomics.new(1, signed: false)
    :ok = :atomics.put(fence, 1, 1)

    table =
      :ets.new(__MODULE__, [
        :set,
        :public,
        {:heir, authority_owner, :credential_leases},
        read_concurrency: true
      ])

    case GenServer.start(__MODULE__, {authority_owner, fence, table}) do
      {:ok, lease_owner} ->
        true = :ets.give_away(table, lease_owner, :credential_leases)
        {:ok, lease_owner, fence, table}

      {:error, _reason} = error ->
        :ets.delete(table)
        error
    end
  end

  def start(_authority_owner), do: {:error, :invalid_host_credential_lease}

  @doc false
  @spec reference_handle?(term()) :: boolean()
  def reference_handle?(handle), do: is_reference(handle)

  @spec bound_to?(pid(), pid(), :atomics.atomics_ref(), :ets.tid()) :: boolean()
  def bound_to?(lease_owner, authority_owner, fence, table)
      when is_pid(lease_owner) and is_pid(authority_owner) do
    reference_handle?(fence) and reference_handle?(table) and
      GenServer.call(lease_owner, {:bound_to, authority_owner, fence, table}, 1_000) == true
  catch
    :exit, _reason -> false
  end

  def bound_to?(_lease_owner, _authority_owner, _fence, _table), do: false

  @spec claim(pid(), :atomics.atomics_ref(), :ets.tid()) ::
          {:ok, reference()} | {:error, :credential_resolution_failed}
  def claim(lease_owner, fence, table)
      when is_pid(lease_owner) do
    if reference_handle?(fence) and reference_handle?(table) do
      deadline = System.monotonic_time(:millisecond) + @operation_timeout_ms
      GenServer.call(lease_owner, {:claim, deadline, fence, table}, @reply_timeout_ms)
    else
      {:error, :credential_resolution_failed}
    end
  catch
    :exit, _reason -> {:error, :credential_resolution_failed}
  end

  def claim(_lease_owner, _fence, _table), do: {:error, :credential_resolution_failed}

  @spec release(pid(), :ets.tid(), reference(), pid()) ::
          :ok | {:error, :credential_resolution_failed} | no_return()
  def release(lease_owner, table, lease, worker)
      when is_pid(lease_owner) and is_reference(lease) and is_pid(worker) do
    if reference_handle?(table) do
      case GenServer.call(lease_owner, {:release, table, lease, worker}, @reply_timeout_ms) do
        :ok -> :ok
        _unacknowledged -> terminate_unreleased_worker()
      end
    else
      {:error, :credential_resolution_failed}
    end
  catch
    :exit, _reason -> terminate_unreleased_worker()
  end

  def release(_lease_owner, _table, _lease, _worker),
    do: {:error, :credential_resolution_failed}

  @spec close(pid(), :atomics.atomics_ref(), :ets.tid()) :: :ok
  def close(lease_owner, fence, table)
      when is_pid(lease_owner) do
    if reference_handle?(fence) and reference_handle?(table) do
      close_fence(fence)
      lease_monitor = Process.monitor(lease_owner)

      result =
        if Process.alive?(lease_owner) do
          try do
            GenServer.call(lease_owner, {:close, fence, table}, @reply_timeout_ms)
          catch
            :exit, _reason -> :force
          end
        else
          :force
        end

      case result do
        :ok -> await_down(lease_owner, lease_monitor)
        :force -> force_close(lease_owner, lease_monitor, table)
      end
    else
      :ok
    end
  end

  def close(_lease_owner, _fence, _table), do: :ok

  @impl GenServer
  def init({authority_owner, fence, table}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       authority_owner: authority_owner,
       authority_monitor: Process.monitor(authority_owner),
       fence: fence,
       table: table,
       leases: %{},
       closing?: false,
       close_waiters: []
     }}
  end

  @impl GenServer
  def handle_call({:bound_to, authority_owner, fence, table}, _from, state) do
    bound? =
      state.authority_owner == authority_owner and state.fence == fence and
        state.table == table and not state.closing? and open?(fence)

    {:reply, bound?, state}
  end

  def handle_call({:claim, deadline, fence, table}, {worker, _tag}, state) do
    if deadline_live?(deadline) and not state.closing? and state.fence == fence and
         state.table == table and open?(fence) and map_size(state.leases) < @max_leases and
         Process.alive?(worker) and not worker_leased?(state.leases, worker) do
      admit_worker(state, worker)
    else
      {:reply, {:error, :credential_resolution_failed}, state}
    end
  end

  def handle_call({:close, fence, table}, from, state) do
    if state.fence == fence and state.table == table do
      close_fence(fence)
      state = %{state | closing?: true, close_waiters: [from | state.close_waiters]}
      stop_workers(state.leases)
      maybe_finish_close(state)
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:release, table, lease, worker}, _from, %{closing?: false} = state) do
    if state.table == table do
      release_worker(state, lease, worker)
    else
      {:reply, {:error, :credential_resolution_failed}, state}
    end
  end

  def handle_call({:release, _table, _lease, _worker}, _from, state),
    do: {:reply, {:error, :credential_resolution_failed}, state}

  @impl GenServer
  def handle_info(
        {:DOWN, monitor, :process, _authority_owner, _reason},
        %{authority_monitor: monitor} = state
      ) do
    close_fence(state.fence)
    state = %{state | closing?: true}
    stop_workers(state.leases)
    maybe_finish_close(state)
  end

  def handle_info({:DOWN, monitor, :process, worker, _reason}, state) do
    case lease_by_monitor(state.leases, monitor, worker) do
      {lease, {_worker, ^monitor}} ->
        Process.unlink(worker)
        delete_lease(state.table, lease)
        state = %{state | leases: Map.delete(state.leases, lease)}
        maybe_finish_close(state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _worker, _reason}, state), do: {:noreply, state}

  def handle_info({:"ETS-TRANSFER", table, _from, :credential_leases}, %{table: table} = state),
    do: {:noreply, state}

  defp admit_worker(state, worker) do
    lease = make_ref()
    monitor = Process.monitor(worker)
    Process.link(worker)

    if insert_lease(state.table, lease, worker) and open?(state.fence) do
      leases = Map.put(state.leases, lease, {worker, monitor})
      {:reply, {:ok, lease}, %{state | leases: leases}}
    else
      Process.unlink(worker)
      Process.demonitor(monitor, [:flush])
      delete_lease(state.table, lease)
      {:reply, {:error, :credential_resolution_failed}, state}
    end
  end

  defp release_worker(state, lease, worker) do
    case Map.pop(state.leases, lease) do
      {{^worker, monitor}, leases} ->
        Process.unlink(worker)
        Process.demonitor(monitor, [:flush])
        delete_lease(state.table, lease)
        {:reply, :ok, %{state | leases: leases}}

      {_missing_or_other_worker, _leases} ->
        {:reply, {:error, :credential_resolution_failed}, state}
    end
  end

  defp worker_leased?(leases, worker),
    do: Enum.any?(leases, fn {_lease, {leased_worker, _monitor}} -> leased_worker == worker end)

  defp lease_by_monitor(leases, monitor, worker) do
    Enum.find(leases, fn {_lease, {leased_worker, lease_monitor}} ->
      leased_worker == worker and lease_monitor == monitor
    end)
  end

  defp stop_workers(leases) do
    Enum.each(leases, fn {_lease, {worker, _monitor}} -> Process.exit(worker, :kill) end)
  end

  defp force_close(lease_owner, lease_monitor, table) do
    workers = tracked_workers(table)
    monitors = Enum.map(workers, &{&1, Process.monitor(&1)})

    if Process.alive?(lease_owner), do: Process.exit(lease_owner, :kill)
    Enum.each(workers, &Process.exit(&1, :kill))

    await_down(lease_owner, lease_monitor)
    Enum.each(monitors, fn {worker, monitor} -> await_down(worker, monitor) end)
    Enum.each(table_leases(table), &delete_lease(table, &1))
    :ok
  end

  defp await_down(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  defp tracked_workers(table) do
    table
    |> table_entries()
    |> Enum.map(fn {_lease, worker} -> worker end)
    |> Enum.uniq()
  end

  defp table_leases(table), do: Enum.map(table_entries(table), &elem(&1, 0))

  defp table_entries(table) do
    :ets.tab2list(table)
  catch
    :error, _reason -> []
  end

  defp insert_lease(table, lease, worker) do
    :ets.insert_new(table, {lease, worker})
  catch
    :error, _reason -> false
  end

  defp delete_lease(table, lease) do
    :ets.delete(table, lease)
    :ok
  catch
    :error, _reason -> :ok
  end

  defp delete_table(table) do
    :ets.delete(table)
    :ok
  catch
    :error, _reason -> :ok
  end

  @spec terminate_unreleased_worker() :: no_return()
  defp terminate_unreleased_worker do
    Process.exit(self(), :kill)

    receive do
    after
      :infinity -> :ok
    end
  end

  defp deadline_live?(deadline),
    do: is_integer(deadline) and System.monotonic_time(:millisecond) <= deadline

  defp open?(fence), do: :atomics.get(fence, 1) == 1

  defp close_fence(fence) do
    :ok = :atomics.put(fence, 1, 0)
  catch
    :error, _reason -> :ok
  end

  defp maybe_finish_close(%{closing?: true, leases: leases} = state)
       when map_size(leases) == 0 do
    delete_table(state.table)
    Enum.each(state.close_waiters, &GenServer.reply(&1, :ok))
    {:stop, :normal, %{state | close_waiters: []}}
  end

  defp maybe_finish_close(state), do: {:noreply, state}
end
