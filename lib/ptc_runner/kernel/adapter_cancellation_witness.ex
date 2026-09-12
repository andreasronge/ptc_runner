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
          send(caller, {:adapter_request_result, gate, self(), result})
        end,
        provider_spawn_options()
      )

    receive do
      {:adapter_request_result, ^gate, ^worker, result} ->
        receive do
          {:DOWN, ^monitor, :process, ^worker, :normal} ->
            :atomics.put(state, 1, 3)
            unwrap(result)

          {:DOWN, ^monitor, :process, ^worker, reason} ->
            exit(reason)
        end

      {:cancel_adapter_request, ^gate, ^guardian} ->
        Process.unlink(worker)
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} ->
            send(guardian, {:adapter_request_drained, gate, self()})
            {:error, :cancelled}
        end
    end
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
