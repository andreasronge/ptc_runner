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

          send(
            caller,
            {:adapter_request_result, gate, self(), result, checkout_obligations(self())}
          )
        end,
        provider_spawn_options()
      )

    receive do
      {:adapter_request_result, ^gate, ^worker, result, obligations} ->
        receive do
          {:DOWN, ^monitor, :process, ^worker, :normal} ->
            await_checkout_return(obligations, guardian, gate, :infinity)
            :atomics.put(state, 1, 3)
            unwrap(result)

          {:DOWN, ^monitor, :process, ^worker, reason} ->
            exit(reason)
        end

      {:cancel_adapter_request, ^gate, ^guardian, deadline} ->
        obligations = suspend_checkout_obligations(worker)
        Process.unlink(worker)
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} ->
            obligations = completed_checkout_obligations(gate, worker) ++ obligations
            await_checkout_return(Enum.uniq(obligations), guardian, gate, deadline)
            send(guardian, {:adapter_request_drained, gate, self()})
            {:error, :cancelled}
        end
    end
  end

  # Finch HTTP/1 checkin and client-DOWN reclamation are asynchronous in
  # NimblePool. Freeze the worker before inspecting both monitor directions:
  # callers monitor the pool; processed clients are monitored by it.
  defp suspend_checkout_obligations(worker) do
    :erlang.suspend_process(worker)
    checkout_obligations(worker)
  rescue
    ArgumentError -> []
  end

  defp checkout_obligations(worker) do
    {pools, monitored} = checkout_owners(worker)
    direct = Enum.map(pools, &{:pool, &1, worker})

    resources =
      Enum.map(monitored, fn owner ->
        # ssl.recv monitors the socket process. Unlike shared OAuth callbacks,
        # this socket belongs to the checked-out connection and closes on client
        # death. Its termination and pool reclamation are independent barriers.
        if :proc_lib.translate_initial_call(owner) == {:ssl_gen_statem, :init, 1},
          do: {:socket, owner},
          else: {:unproven, owner}
      end)

    direct ++ resources
  end

  defp checkout_owners(owner) do
    case Process.info(owner, [:monitors, :monitored_by]) do
      nil ->
        {[], []}

      info ->
        monitored = for {:process, pid} <- info[:monitors], is_pid(pid), do: pid
        {pool_calls, resources} = Enum.split_with(monitored, &pool?/1)
        checked_out_pools = Enum.filter(info[:monitored_by], &pool?/1)
        # A call still in the pool's mailbox has no requests entry. System
        # queries can overtake it while the pool is suspended, so only the
        # pool's own client monitor positively proves checkout processing.
        unattested_calls = pool_calls -- checked_out_pools
        {Enum.uniq(checked_out_pools), resources ++ unattested_calls}
    end
  end

  defp pool?(pid), do: :proc_lib.translate_initial_call(pid) == {NimblePool, :init, 1}

  defp completed_checkout_obligations(gate, worker) do
    receive do
      {:adapter_request_result, ^gate, ^worker, _result, obligations} -> obligations
    after
      0 -> []
    end
  end

  defp await_checkout_return([], _guardian, _gate, _deadline), do: :ok

  defp await_checkout_return([obligation | rest] = obligations, guardian, gate, deadline) do
    deadline = receive_cleanup_deadline(guardian, gate, deadline)
    timeout = cleanup_wait_ms(deadline)
    if timeout == 0, do: abandon_witness(guardian)

    case checkout_status(obligation, timeout) do
      :returned ->
        await_checkout_return(rest, guardian, gate, deadline)

      :unproven ->
        abandon_witness(guardian)

      :pending ->
        # A suspended NimblePool still services system messages. Park between
        # observations and stop at the guardian's absolute deadline, rather than
        # spinning forever after the guardian has stopped waiting for us.
        receive do
          {:cancel_adapter_request, ^gate, ^guardian, cleanup_deadline} ->
            await_checkout_return(obligations, guardian, gate, cleanup_deadline)

          {:DOWN, _monitor, :process, ^guardian, _reason} ->
            abandon_witness(guardian)
        after
          cleanup_wait_ms(deadline) ->
            await_checkout_return(obligations, guardian, gate, deadline)
        end
    end
  end

  defp receive_cleanup_deadline(guardian, gate, deadline) do
    receive do
      {:cancel_adapter_request, ^gate, ^guardian, cleanup_deadline} -> cleanup_deadline
    after
      0 -> deadline
    end
  end

  defp cleanup_wait_ms(:infinity), do: 10

  defp cleanup_wait_ms(deadline),
    do: min(max(deadline - System.monotonic_time(:millisecond), 0), 10)

  defp checkout_status({:unproven, _owner}, _timeout), do: :unproven

  defp checkout_status({:pool, pool, owner}, timeout) do
    # Exact ownership, rather than aggregate availability, remains valid even
    # when another caller immediately takes the returned capacity or metrics
    # are disabled. Unsupported pool state must never acknowledge drain.
    case owner_response(pool, fn -> :sys.get_state(pool, timeout) end) do
      {:ok, %{requests: requests}} ->
        if Enum.any?(requests, fn {_ref, request} -> elem(request, 0) == owner end),
          do: :pending,
          else: :returned

      {:ok, _unsupported} ->
        :unproven

      status ->
        status
    end
  end

  defp checkout_status({:socket, owner}, _timeout) do
    if Process.alive?(owner), do: :pending, else: :returned
  end

  defp owner_response(owner, operation) do
    {:ok, operation.()}
  catch
    :exit, _reason -> if Process.alive?(owner), do: :pending, else: :returned
  end

  defp abandon_witness(guardian) do
    # The requester catches ordinary exits and marks a normal return completed.
    # An untrappable, unlinked exit preserves the existing :uncertain outcome
    # without leaving an orphan requester or marking unproved cleanup complete.
    Process.unlink(guardian)
    Process.exit(self(), :kill)
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
