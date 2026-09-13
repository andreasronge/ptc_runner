defmodule PtcRunner.Kernel.AdapterCancellationWitness do
  @moduledoc false

  @key {__MODULE__, :request}

  @spec install(pid(), reference(), :atomics.atomics_ref()) :: :ok
  def install(guardian, gate, state)
      when is_pid(guardian) and is_reference(gate) do
    Process.put(@key, {guardian, gate, state})
    :ok
  end

  @spec run((-> term())) :: term()
  def run(operation) when is_function(operation, 0) do
    case Process.get(@key) do
      {guardian, gate, state} -> run_witnessed(operation, guardian, gate, state)
      nil -> operation.()
    end
  end

  defp run_witnessed(operation, guardian, gate, state) do
    case :atomics.compare_exchange(state, 1, 1, 2) do
      :ok -> run_registered(operation, guardian, gate, state)
      _cancellation_claimed -> {:error, :cancelled}
    end
  end

  defp run_registered(operation, guardian, gate, state) do
    caller = self()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          result = invoke(operation)
          send(caller, {:adapter_request_result, gate, self(), result, checkout_pools(self())})
        end,
        provider_spawn_options()
      )

    receive do
      {:adapter_request_result, ^gate, ^worker, result, pools} ->
        receive do
          {:DOWN, ^monitor, :process, ^worker, :normal} ->
            await_checkout_return(pools, worker)
            :atomics.put(state, 1, 3)
            unwrap(result)

          {:DOWN, ^monitor, :process, ^worker, reason} ->
            exit(reason)
        end

      {:cancel_adapter_request, ^gate, ^guardian} ->
        pools = suspend_checkout_pools(worker)
        Process.unlink(worker)
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} ->
            pools = completed_checkout_pools(gate, worker) ++ pools
            await_checkout_return(Enum.uniq(pools), worker)
            send(guardian, {:adapter_request_drained, gate, self()})
            {:error, :cancelled}
        end
    end
  end

  # Finch HTTP/1 checkin and client-DOWN reclamation are asynchronous in
  # NimblePool. Worker death alone is not evidence that its checkout returned.
  # Freeze the worker before inspecting both sides of its monitor relationships:
  # queued clients monitor the pool, while checked-out clients are monitored by it.
  defp suspend_checkout_pools(worker) do
    :erlang.suspend_process(worker)
    checkout_pools(worker)
  rescue
    ArgumentError -> []
  end

  defp checkout_pools(worker) do
    case Process.info(worker, [:monitors, :monitored_by]) do
      nil ->
        []

      info ->
        monitored = for {:process, pid} <- info[:monitors], is_pid(pid), do: pid

        (monitored ++ info[:monitored_by])
        |> Enum.uniq()
        |> Enum.filter(&(:proc_lib.translate_initial_call(&1) == {NimblePool, :init, 1}))
    end
  end

  defp completed_checkout_pools(gate, worker) do
    receive do
      {:adapter_request_result, ^gate, ^worker, _result, pools} -> pools
    after
      0 -> []
    end
  end

  defp await_checkout_return(pools, worker) do
    Enum.each(pools, &await_pool_reclamation(&1, worker))
  end

  defp await_pool_reclamation(pool, worker) do
    # Inspect the owning pool, rather than aggregate availability: another caller
    # may already have acquired the returned capacity. This also works with metrics
    # disabled. The guardian's existing absolute deadline bounds its wait for us;
    # a suspended or unresponsive pool cannot produce an early acknowledgement.
    case :sys.get_state(pool) do
      %{requests: requests} ->
        if Enum.any?(requests, fn {_ref, request} -> elem(request, 0) == worker end) do
          await_pool_reclamation(pool, worker)
        end
    end
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:normal, _call} -> :ok
    :exit, {:shutdown, _call} -> :ok
  end

  defp invoke(operation) do
    {:ok, operation.()}
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:raised, exception, stacktrace}), do: reraise(exception, stacktrace)
  defp unwrap({:caught, kind, reason}), do: :erlang.raise(kind, reason, [])

  defp provider_spawn_options do
    max_heap_size = Process.info(self(), :max_heap_size) |> elem(1)
    [:link, :monitor, {:max_heap_size, max_heap_size}]
  end
end
