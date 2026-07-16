defmodule PtcRunner.Kernel.Dispatcher do
  @moduledoc """
  Internal bounded capability invocation boundary.

  Dispatch validates normalized arguments, atomically reserves environment and
  provider-task budgets in `PtcRunner.Kernel.RunState`, emits canonical attempt
  events, runs the trusted callback in a monitored heap-limited process, and
  constructs the uniform Lisp result envelope. Completion is checked against
  run closure so late results cannot re-enter Lisp.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp.AmbiguousArguments
  alias PtcRunner.Lisp.RetainedSize

  @doc "Dispatches one environment-local capability with optional event collection."
  @spec dispatch(RunState.t(), :workflow | :mission, map(), binary(), map(), non_neg_integer()) ::
          map()
  def dispatch(state, environment, %{capabilities: capabilities}, name, arguments, timeout_ms)
      when environment in [:workflow, :mission] and is_binary(name) and is_map(arguments) and
             is_integer(timeout_ms) do
    dispatch(state, environment, %{capabilities: capabilities}, name, arguments, timeout_ms, nil)
  end

  @spec dispatch(
          RunState.t(),
          :workflow | :mission,
          map(),
          binary(),
          map(),
          non_neg_integer(),
          term()
        ) :: map()
  def dispatch(
        state,
        environment,
        %{capabilities: _capabilities},
        _name,
        %AmbiguousArguments{},
        _timeout_ms,
        event_sink
      )
      when environment in [:workflow, :mission] do
    protocol_error(state, event_sink, :ambiguous_arguments)
  end

  def dispatch(
        state,
        environment,
        %{capabilities: capabilities},
        name,
        arguments,
        timeout_ms,
        event_sink
      )
      when environment in [:workflow, :mission] and is_binary(name) and is_map(arguments) and
             is_integer(timeout_ms) do
    with %Capability{} = capability <- Map.get(capabilities, name),
         :ok <- validate(capability, arguments),
         :ok <- validate_size(arguments, capability_argument_limit(state)),
         :ok <- RunState.reserve_capability(state, environment, name) do
      invoke_with_events(
        state,
        capability,
        arguments,
        timeout_ms,
        environment,
        event_sink
      )
    else
      nil ->
        %{status: :error, kind: :capability_denied, reason: :capability_absent, retryable?: false}

      {:error, :invalid_arguments} ->
        protocol_error(state, event_sink, :invalid_arguments)

      {:error, :argument_exceeded} ->
        protocol_error(state, event_sink, :argument_exceeded)

      {:error, :limit_exceeded} ->
        limit_error(state, event_sink, :capability_quota)

      {:error, :live_task_limit} ->
        limit_error(state, event_sink, :live_provider_tasks)

      {:error, :reservation_held} ->
        limit_error(state, event_sink, :reservation_held)

      {:error, :run_closed} ->
        limit_error(state, event_sink, :run_closed)
    end
  end

  defp invoke_with_events(state, capability, arguments, timeout_ms, environment, event_sink) do
    capability_id = Events.id("capability")
    started_ms = System.monotonic_time(:millisecond)
    data = %{capability_id: capability_id, environment: environment, name: capability.name}

    case Events.emit(state, event_sink, "capability-started", data) do
      :ok ->
        result = invoke(state, capability, arguments, timeout_ms)
        _ = maybe_emit_limit(state, event_sink, result)

        _ =
          Events.emit(state, event_sink, "capability-stopped", %{
            capability_id: capability_id,
            environment: environment,
            name: capability.name,
            status: result.status,
            duration_ms: Events.duration_ms(started_ms)
          })

        result

      {:error, :event_sink_error} ->
        RunState.release_provider_slot(state)
        limit_error(state, nil, :run_closed)
    end
  end

  defp invoke(state, capability, arguments, requested_timeout_ms) do
    remaining = RunState.usage(state).remaining_ms
    timeout_ms = min(requested_timeout_ms, remaining)
    limits = state_limits(state)

    if timeout_ms <= 0 do
      RunState.release_provider_slot(state)
      limit_error(state, nil, :run_deadline)
    else
      parent = self()
      go = make_ref()

      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{
            size: limits.provider_heap_words,
            kill: true,
            error_logger: false
          })

          # Gate: run nothing until the dispatcher has attached this pid to
          # its reservation in RunState. If the dispatching process dies
          # first, exit instead of running the callback as an untracked
          # orphan holding a live provider slot.
          parent_ref = Process.monitor(parent)

          receive do
            ^go ->
              send(
                parent,
                {:provider_result, self(), safely_invoke(capability.callback, arguments)}
              )

            {:DOWN, ^parent_ref, :process, _parent, _reason} ->
              :ok
          end
        end)

      RunState.attach_provider(state, pid)
      send(pid, go)

      receive do
        {:provider_result, ^pid, result} ->
          Process.demonitor(ref, [:flush])

          case RunState.finish_provider(state) do
            :ok -> normalize_result(state, capability, result)
            {:error, :run_closed} -> limit_error(state, nil, :run_closed)
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

  defp normalize_result(state, capability, {:ok, value}) do
    cap = capability_result_limit(state)
    bytes = RetainedSize.bytes_with_cap(value, cap)

    cond do
      not (json_value?(value) and is_integer(bytes) and bytes <= cap) ->
        %{
          status: :error,
          kind: :result_exceeded,
          reason: :provider_result_limit,
          retryable?: false
        }

      not valid_output?(capability, value) ->
        %{
          status: :error,
          kind: :invalid_result,
          reason: :output_schema_mismatch,
          retryable?: false
        }

      true ->
        %{status: :ok, value: value}
    end
  end

  defp normalize_result(_state, _capability, {:error, %ProviderError{} = error}) do
    %{
      status: :error,
      kind: :provider_error,
      reason: error.kind,
      details: error.details,
      retryable?: error.retryable?
    }
  end

  defp normalize_result(_state, _capability, {:raised, reason}),
    do: %{status: :error, kind: :provider_error, reason: reason, retryable?: true}

  defp normalize_result(_state, _capability, _result),
    do: %{
      status: :error,
      kind: :invalid_result,
      reason: :invalid_provider_return,
      retryable?: false
    }

  defp validate(%Capability{} = capability, arguments) do
    if JSONSchema.valid?(capability.input_validator, arguments),
      do: semantic_validate(capability, arguments),
      else: {:error, :invalid_arguments}
  end

  defp semantic_validate(%Capability{validate: nil}, _arguments), do: :ok

  defp semantic_validate(%Capability{validate: validate}, arguments) do
    case validate.(arguments) do
      :ok -> :ok
      _ -> {:error, :invalid_arguments}
    end
  rescue
    _exception -> {:error, :invalid_arguments}
  end

  defp valid_output?(%Capability{output_validator: nil}, _value), do: true

  defp valid_output?(%Capability{output_validator: validator}, value),
    do: JSONSchema.valid?(validator, value)

  defp validate_size(value, cap) do
    case RetainedSize.bytes_with_cap(value, cap) do
      bytes when is_integer(bytes) and bytes <= cap -> :ok
      _ -> {:error, :argument_exceeded}
    end
  end

  defp protocol_error(state, event_sink, reason) do
    case RunState.protocol_error(state) do
      :ok -> %{status: :error, kind: :protocol_error, reason: reason, retryable?: false}
      {:error, :protocol_error_limit} -> limit_error(state, event_sink, :protocol_errors)
    end
  end

  defp limit_error(state, event_sink, reason) do
    _ = Events.emit(state, event_sink, "limit-exceeded", %{reason: reason})
    %{status: :error, kind: :limit_exceeded, reason: reason, retryable?: false}
  end

  defp maybe_emit_limit(state, event_sink, %{kind: kind, reason: reason})
       when kind in [:timeout, :result_exceeded, :limit_exceeded] do
    Events.emit(state, event_sink, "limit-exceeded", %{reason: reason})
  end

  defp maybe_emit_limit(_state, _event_sink, _result), do: :ok

  defp normalize_exit(:killed), do: :provider_heap_exceeded
  defp normalize_exit(_reason), do: :provider_exit
  defp capability_argument_limit(state), do: state_limits(state).capability_argument_bytes
  defp capability_result_limit(state), do: state_limits(state).capability_result_bytes
  defp state_limits(state), do: RunState.limits(state)

  defp json_value?(value), do: JSONValue.value?(value)
end
