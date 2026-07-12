defmodule PtcRunner.Kernel.Dispatcher do
  @moduledoc "Bounded capability invocation with late-result invalidation."

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp.RetainedSize

  @spec dispatch(RunState.t(), :workflow | :mission, map(), binary(), map(), non_neg_integer()) ::
          map()
  def dispatch(state, environment, %{capabilities: capabilities}, name, arguments, timeout_ms)
      when environment in [:workflow, :mission] and is_binary(name) and is_map(arguments) and
             is_integer(timeout_ms) do
    with %Capability{} = capability <- Map.get(capabilities, name),
         :ok <- validate(capability, arguments),
         :ok <- validate_size(arguments, capability_argument_limit(state)),
         :ok <- RunState.reserve_capability(state, environment, name) do
      invoke(state, capability, arguments, timeout_ms)
    else
      nil ->
        %{status: :error, kind: :capability_denied, reason: :capability_absent, retryable?: false}

      {:error, :invalid_arguments} ->
        protocol_error(state, :invalid_arguments)

      {:error, :argument_exceeded} ->
        protocol_error(state, :argument_exceeded)

      {:error, :limit_exceeded} ->
        limit_error(:capability_quota)

      {:error, :live_task_limit} ->
        limit_error(:live_provider_tasks)

      {:error, :run_closed} ->
        limit_error(:run_closed)
    end
  end

  defp invoke(state, capability, arguments, requested_timeout_ms) do
    remaining = RunState.usage(state).remaining_ms
    timeout_ms = min(requested_timeout_ms, remaining)
    limits = state_limits(state)

    if timeout_ms <= 0 do
      RunState.release_provider_slot(state)
      limit_error(:run_deadline)
    else
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{
            size: limits.provider_heap_words,
            kill: true,
            error_logger: false
          })

          send(parent, {:provider_result, self(), safely_invoke(capability.callback, arguments)})
        end)

      receive do
        {:provider_result, ^pid, result} ->
          Process.demonitor(ref, [:flush])

          case RunState.finish_provider(state) do
            :ok -> normalize_result(state, result)
            {:error, :run_closed} -> limit_error(:run_closed)
          end

        {:DOWN, ^ref, :process, ^pid, reason} ->
          RunState.release_provider_slot(state)

          %{
            status: :error,
            kind: :provider_error,
            reason: normalize_exit(reason),
            retryable?: true
          }
      after
        timeout_ms ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            0 -> :ok
          end

          RunState.release_provider_slot(state)
          %{status: :error, kind: :timeout, reason: :provider_timeout, retryable?: true}
      end
    end
  end

  defp safely_invoke(callback, arguments) do
    callback.(arguments)
  rescue
    _exception -> {:raised, :exception}
  catch
    :exit, _reason -> {:raised, :exit}
    _kind, _reason -> {:raised, :throw}
  end

  defp normalize_result(state, {:ok, value}) do
    cap = capability_result_limit(state)
    bytes = RetainedSize.bytes_with_cap(value, cap)

    if json_value?(value) and is_integer(bytes) and bytes <= cap do
      %{status: :ok, value: value}
    else
      %{status: :error, kind: :result_exceeded, reason: :provider_result_limit, retryable?: false}
    end
  end

  defp normalize_result(_state, {:error, %ProviderError{} = error}) do
    %{
      status: :error,
      kind: :provider_error,
      reason: error.kind,
      details: error.details,
      retryable?: error.retryable?
    }
  end

  defp normalize_result(_state, {:raised, reason}),
    do: %{status: :error, kind: :provider_error, reason: reason, retryable?: true}

  defp normalize_result(_state, _result),
    do: %{
      status: :error,
      kind: :invalid_result,
      reason: :invalid_provider_return,
      retryable?: false
    }

  defp validate(%Capability{validate: nil}, _arguments), do: :ok

  defp validate(%Capability{validate: validate}, arguments) do
    case validate.(arguments) do
      :ok -> :ok
      _ -> {:error, :invalid_arguments}
    end
  rescue
    _exception -> {:error, :invalid_arguments}
  end

  defp validate_size(value, cap) do
    case RetainedSize.bytes_with_cap(value, cap) do
      bytes when is_integer(bytes) and bytes <= cap -> :ok
      _ -> {:error, :argument_exceeded}
    end
  end

  defp protocol_error(state, reason) do
    case RunState.protocol_error(state) do
      :ok -> %{status: :error, kind: :protocol_error, reason: reason, retryable?: false}
      {:error, :protocol_error_limit} -> limit_error(:protocol_errors)
    end
  end

  defp limit_error(reason),
    do: %{status: :error, kind: :limit_exceeded, reason: reason, retryable?: false}

  defp normalize_exit(:killed), do: :provider_heap_exceeded
  defp normalize_exit(_reason), do: :provider_exit
  defp capability_argument_limit(state), do: state_limits(state).capability_argument_bytes
  defp capability_result_limit(state), do: state_limits(state).capability_result_bytes
  defp state_limits(state), do: RunState.limits(state)

  defp json_value?(value), do: JSONValue.value?(value)
end
