defmodule PtcRunner.Kernel.MCPOAuth.ManagerCleanup do
  @moduledoc """
  Bounded cleanup owner for token managers left by failed provider acquisition.

  This owner serializes adoption and gives each manager exactly one linked
  cleanup worker, including across concurrent or repeated adoption attempts.
  The worker retries bounded close calls with capped exponential backoff.
  Consecutive close timeouts have a finite cleanup-slot budget and reclaim a
  manager abnormally when it is exhausted. A persistence failure resets that
  timeout streak and remains retryable without a cleanup deadline. If this
  owner restarts, OTP terminates the linked workers, which in turn terminate
  their linked managers rather than leaving unreachable credential owners
  alive.
  Provider cleanup uses `adopt/2` to confirm both worker ownership and removal
  from the registrar's force-close set as one caller-visible handoff. Worker
  registration is serialized here, while registrar calls run as deduplicated
  asynchronous operations so a stalled scope cannot block unrelated cleanup.
  Callers add no competing timeout; each registrar handoff remains bounded by
  its local five-second limit.
  """

  use GenServer

  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorker
  alias PtcRunner.Kernel.MCPOAuth.TokenManager
  alias PtcRunner.Kernel.ResourceRegistrar

  @max_managers 128

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts),
    do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec adopt(TokenManager.t()) :: :ok | {:error, :cleanup_unavailable}
  def adopt(%TokenManager{pid: pid} = manager) do
    GenServer.call(__MODULE__, {:adopt, manager}, :infinity)
  catch
    :exit, _reason -> if(Process.alive?(pid), do: {:error, :cleanup_unavailable}, else: :ok)
  end

  @doc false
  @spec adopted_worker(pid()) :: {:ok, pid()} | :error
  def adopted_worker(manager_pid) when is_pid(manager_pid) do
    GenServer.call(__MODULE__, {:adopted_worker, manager_pid})
  catch
    :exit, _reason -> :error
  end

  @doc false
  @spec adopt(TokenManager.t(), ResourceRegistrar.t() | nil) ::
          :ok | {:error, :cleanup_unavailable | :scope_unavailable}
  def adopt(%TokenManager{pid: pid} = manager, registrar) do
    GenServer.call(__MODULE__, {:adopt, manager, registrar}, :infinity)
  catch
    :exit, _reason -> if(Process.alive?(pid), do: {:error, :cleanup_unavailable}, else: :ok)
  end

  @impl GenServer
  def init(:ok) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       workers: %{},
       monitor_refs: %{},
       handoffs: %{},
       pending_handoffs: %{},
       handoff_pids: %{}
     }}
  end

  @impl GenServer
  def handle_call({:adopt, %TokenManager{} = manager}, _from, state) do
    case ensure_worker(manager, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:complete, state} -> {:reply, :ok, state}
      {{:error, :cleanup_unavailable} = error, state} -> {:reply, error, state}
    end
  end

  def handle_call(
        {:adopt, %TokenManager{pid: manager_pid} = manager, registrar},
        from,
        state
      ) do
    case ensure_worker(manager, state) do
      {:ok, state} ->
        begin_handoff(manager_pid, registrar, from, state)

      {:complete, state} ->
        {:reply, :ok, state}

      {{:error, :cleanup_unavailable} = error, state} ->
        {:reply, error, state}
    end
  end

  def handle_call({:adopted_worker, manager_pid}, _from, state) do
    case Map.fetch(state.workers, manager_pid) do
      {:ok, worker} when is_pid(worker) -> {:reply, {:ok, worker}, state}
      :error -> {:reply, :error, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _worker, _reason}, state) do
    case Map.pop(state.monitor_refs, monitor_ref) do
      {nil, _monitor_refs} ->
        {:noreply, state}

      {manager_pid, monitor_refs} ->
        {:noreply,
         %{
           state
           | workers: Map.delete(state.workers, manager_pid),
             monitor_refs: monitor_refs,
             handoffs: Map.delete(state.handoffs, manager_pid)
         }}
    end
  end

  def handle_info({__MODULE__, :handoff_finished, handoff_pid, result}, state) do
    case Map.pop(state.handoff_pids, handoff_pid) do
      {nil, _handoff_pids} ->
        {:noreply, state}

      {key, handoff_pids} ->
        finish_handoff(key, result, %{state | handoff_pids: handoff_pids})
    end
  end

  def handle_info({:EXIT, handoff_pid, _reason}, state) do
    case Map.pop(state.handoff_pids, handoff_pid) do
      {nil, _handoff_pids} ->
        {:noreply, state}

      {key, handoff_pids} ->
        finish_handoff(
          key,
          {:error, :resource_registrar_unavailable},
          %{state | handoff_pids: handoff_pids}
        )
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_worker(%TokenManager{pid: manager_pid} = manager, state) do
    case Map.fetch(state.workers, manager_pid) do
      {:ok, worker} when is_pid(worker) ->
        if Process.alive?(worker),
          do: {:ok, state},
          else: start_worker(manager, drop_worker(state, manager_pid))

      :error ->
        start_worker(manager, state)
    end
  end

  defp start_worker(%TokenManager{pid: manager_pid} = manager, state) do
    cond do
      not Process.alive?(manager_pid) ->
        {:complete, state}

      map_size(state.workers) >= @max_managers ->
        {{:error, :cleanup_unavailable}, state}

      true ->
        case ManagerCleanupWorker.start_link(manager) do
          {:ok, worker} ->
            monitor_ref = Process.monitor(worker)

            {:ok,
             %{
               state
               | workers: Map.put(state.workers, manager_pid, worker),
                 monitor_refs: Map.put(state.monitor_refs, monitor_ref, manager_pid)
             }}

          :ignore ->
            {:complete, state}

          {:error, _reason} ->
            result =
              if Process.alive?(manager_pid),
                do: {:error, :cleanup_unavailable},
                else: :complete

            {result, state}
        end
    end
  end

  defp begin_handoff(manager_pid, registrar, from, state) do
    completed = Map.get(state.handoffs, manager_pid, MapSet.new())
    key = {manager_pid, registrar}

    cond do
      MapSet.member?(completed, registrar) ->
        {:reply, :ok, state}

      pending = Map.get(state.pending_handoffs, key) ->
        pending = %{pending | waiters: [from | pending.waiters]}
        {:noreply, put_in(state.pending_handoffs[key], pending)}

      true ->
        owner = self()

        handoff_pid =
          spawn_link(fn ->
            result = ResourceRegistrar.handoff_root(registrar, manager_pid)
            send(owner, {__MODULE__, :handoff_finished, self(), result})
          end)

        pending = %{pid: handoff_pid, waiters: [from]}

        {:noreply,
         %{
           state
           | pending_handoffs: Map.put(state.pending_handoffs, key, pending),
             handoff_pids: Map.put(state.handoff_pids, handoff_pid, key)
         }}
    end
  end

  defp finish_handoff({manager_pid, registrar} = key, raw_result, state) do
    case Map.pop(state.pending_handoffs, key) do
      {nil, _pending_handoffs} ->
        {:noreply, state}

      {%{waiters: waiters}, pending_handoffs} ->
        result = normalize_handoff_result(raw_result, manager_pid)
        Enum.each(waiters, &GenServer.reply(&1, result))

        state = %{state | pending_handoffs: pending_handoffs}

        state =
          if result == :ok and Map.has_key?(state.workers, manager_pid) do
            completed = Map.get(state.handoffs, manager_pid, MapSet.new())
            put_in(state.handoffs[manager_pid], MapSet.put(completed, registrar))
          else
            state
          end

        {:noreply, state}
    end
  end

  defp normalize_handoff_result(:ok, _manager_pid), do: :ok

  defp normalize_handoff_result({:error, _reason}, manager_pid),
    do: if(Process.alive?(manager_pid), do: {:error, :scope_unavailable}, else: :ok)

  defp drop_worker(state, manager_pid) do
    case Map.pop(state.workers, manager_pid) do
      {nil, _workers} ->
        state

      {worker, workers} ->
        monitor_refs =
          Map.reject(state.monitor_refs, fn {_monitor_ref, owner_pid} ->
            owner_pid == manager_pid
          end)

        if Process.alive?(worker), do: Process.exit(worker, :kill)

        %{
          state
          | workers: workers,
            monitor_refs: monitor_refs,
            handoffs: Map.delete(state.handoffs, manager_pid)
        }
    end
  end
end
