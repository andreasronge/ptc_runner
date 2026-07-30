defmodule PtcRunner.Kernel.Dispatcher do
  @moduledoc """
  Internal bounded capability invocation boundary.

  Dispatch validates normalized arguments, atomically reserves environment and
  provider-task budgets in `PtcRunner.Kernel.RunState`, emits canonical attempt
  events, runs the trusted callback in a monitored heap-limited process, and
  constructs the uniform Lisp result envelope. Completion is checked against
  run closure so late results cannot re-enter Lisp.

  Mission failures after callback entry are classified with the capability's
  declared effect. Read failures keep their provider retry policy. Write and
  unknown failures are non-retryable and carry
  `mutation_state: :indeterminate` when invocation may have reached external
  state. A trusted `ProviderError` with `dispatch_provenance: :not_dispatched`
  preserves its specific pre-dispatch policy without exposing that internal
  provenance. Workflow capabilities retain their provider-owned retry policy.
  Before a mission provider publishes a terminal policy failure, its monitored
  callback records that classification in RunState so a subsequent evaluator
  kill cannot make the agent repeat the call.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
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
        environment_value,
        name,
        arguments,
        timeout_ms,
        event_sink
      ) do
    dispatch(
      state,
      environment,
      environment_value,
      name,
      arguments,
      timeout_ms,
      event_sink,
      nil
    )
  end

  def dispatch(
        state,
        environment,
        %{capabilities: _capabilities},
        _name,
        %AmbiguousArguments{},
        _timeout_ms,
        event_sink,
        _inspection_sink
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
        event_sink,
        inspection_sink
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
        event_sink,
        inspection_sink
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

  defp invoke_with_events(
         state,
         capability,
         arguments,
         timeout_ms,
         environment,
         event_sink,
         inspection_sink
       ) do
    capability_id = Events.id("capability")
    started_ms = System.monotonic_time(:millisecond)
    data = %{capability_id: capability_id, environment: environment, name: capability.name}

    case Events.emit(state, event_sink, "capability-started", data) do
      :ok ->
        {result, input_captured?} =
          case inspection_input(
                 inspection_sink,
                 capability_id,
                 environment,
                 capability.name,
                 arguments
               ) do
            :ok ->
              context = invocation_context(event_sink, inspection_sink, capability_id)
              {invoke(state, capability, arguments, timeout_ms, context, environment), true}

            {:error, :inspection_sink_error} ->
              {inspection_failure(state), false}
          end

        result =
          if input_captured? do
            case inspection_output(
                   inspection_sink,
                   capability_id,
                   environment,
                   capability.name,
                   result
                 ) do
              :ok ->
                result

              {:error, :inspection_sink_error} ->
                state
                |> inspection_failure()
                |> post_invocation_failure(environment, capability)
            end
          else
            result
          end

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

  defp inspection_input(nil, _capability_id, _environment, _name, _arguments), do: :ok

  defp inspection_input(sink, capability_id, environment, name, arguments) do
    InspectionSink.emit(
      sink,
      "capability-input",
      %{capability_id: capability_id},
      %{environment: environment, name: name, arguments: arguments}
    )
  end

  defp inspection_output(nil, _capability_id, _environment, _name, _result), do: :ok

  defp inspection_output(sink, capability_id, environment, name, result) do
    InspectionSink.emit(
      sink,
      "capability-output",
      %{capability_id: capability_id},
      %{environment: environment, name: name, result: result}
    )
  end

  defp inspection_failure(state) do
    :ok = RunState.fail(state, :inspection_sink_error, :inspection_sink_error)

    %{
      status: :error,
      kind: :inspection_sink_error,
      reason: :inspection_sink_error,
      retryable?: false
    }
  end

  defp invocation_context(event_sink, inspection_sink, capability_id) do
    traceparent =
      case event_sink && EventSink.identity(event_sink) do
        {:ok, %{trace_id: trace_id}} -> Events.traceparent(trace_id, capability_id)
        _unavailable -> nil
      end

    %{
      capability_id: capability_id,
      inspection_sink: inspection_sink,
      traceparent: traceparent
    }
  end

  defp invoke(state, capability, arguments, requested_timeout_ms, context, environment) do
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
              result = safely_invoke(capability.callback, arguments, context)

              if terminal_provider_failure?(result),
                do: RunState.mark_evaluation_terminal_provider_failure(state)

              send(parent, {:provider_result, self(), result})

            {:DOWN, ^parent_ref, :process, _parent, _reason} ->
              :ok
          end
        end)

      case RunState.attach_provider(state, pid) do
        :ok ->
          send(pid, go)
          await_provider(state, capability, pid, ref, timeout_ms, environment)

        {:error, :provider_down} ->
          reason = await_down(pid, ref)
          RunState.release_provider_slot(state)

          # The provider died before the gate opened, so the callback never
          # ran and no effect can have reached the outside world.
          post_invocation_failure(
            provider_exit(reason),
            environment,
            capability,
            :not_dispatched
          )

        {:error, :closed} ->
          await_down(pid, ref)
          RunState.release_provider_slot(state)
          limit_error(state, nil, :run_closed)
      end
    end
  end

  defp await_provider(state, capability, pid, ref, timeout_ms, environment) do
    receive do
      {:provider_result, ^pid, result} ->
        await_down(pid, ref)

        case RunState.finish_provider(state) do
          :ok ->
            normalize_result(state, environment, capability, result)

          {:error, :run_closed} ->
            state
            |> limit_error(nil, :run_closed)
            |> post_invocation_failure(environment, capability)
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        RunState.release_provider_slot(state)
        post_invocation_failure(provider_exit(reason), environment, capability)
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        await_down(pid, ref)
        RunState.release_provider_slot(state)

        post_invocation_failure(
          %{status: :error, kind: :timeout, reason: :provider_timeout, retryable?: true},
          environment,
          capability
        )
    end
  end

  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end

  defp provider_exit(reason) do
    %{
      status: :error,
      kind: :provider_error,
      reason: normalize_exit(reason),
      retryable?: true
    }
  end

  defp safely_invoke(callback, arguments, context) do
    if is_function(callback, 2), do: callback.(arguments, context), else: callback.(arguments)
  rescue
    _exception -> {:raised, :exception}
  catch
    :exit, _reason -> {:raised, :exit}
    _kind, _reason -> {:raised, :throw}
  end

  defp normalize_result(state, environment, capability, {:ok, value}) do
    cap = capability_result_limit(state)
    bytes = RetainedSize.bytes_with_cap(value, cap)

    cond do
      not (json_value?(value) and is_integer(bytes) and bytes <= cap) ->
        post_invocation_failure(
          %{
            status: :error,
            kind: :result_exceeded,
            reason: :provider_result_limit,
            retryable?: false
          },
          environment,
          capability
        )

      not valid_output?(capability, value) ->
        post_invocation_failure(
          %{
            status: :error,
            kind: :invalid_result,
            reason: :output_schema_mismatch,
            retryable?: false
          },
          environment,
          capability
        )

      true ->
        %{status: :ok, value: RetainedSize.detach_binaries(value)}
    end
  end

  defp normalize_result(
         _state,
         environment,
         capability,
         {:error, %ProviderError{} = error}
       ) do
    if ProviderError.valid?(error) do
      %{
        status: :error,
        kind: :provider_error,
        reason: error.kind,
        details: error.details,
        retryable?: error.retryable?
      }
      |> maybe_put_mutation_state(error.mutation_state)
      |> post_invocation_failure(environment, capability, error.dispatch_provenance)
    else
      invalid_provider_result(environment, capability)
    end
  end

  defp normalize_result(_state, environment, capability, {:raised, reason}) do
    post_invocation_failure(
      %{status: :error, kind: :provider_error, reason: reason, retryable?: true},
      environment,
      capability
    )
  end

  defp normalize_result(_state, environment, capability, _result),
    do: invalid_provider_result(environment, capability)

  defp invalid_provider_result(environment, capability) do
    post_invocation_failure(
      %{
        status: :error,
        kind: :invalid_result,
        reason: :invalid_provider_return,
        retryable?: false
      },
      environment,
      capability
    )
  end

  defp post_invocation_failure(result, environment, capability, provenance \\ nil)

  defp post_invocation_failure(
         result,
         :mission,
         %Capability{effect: effect},
         provenance
       )
       when effect in [:write, :unknown] and provenance != :not_dispatched do
    result
    |> Map.put(:retryable?, false)
    |> Map.put(:mutation_state, :indeterminate)
  end

  defp post_invocation_failure(result, _environment, _capability, _provenance) do
    if Map.get(result, :mutation_state) == :indeterminate,
      do: Map.put(result, :retryable?, false),
      else: result
  end

  defp maybe_put_mutation_state(result, :indeterminate),
    do: Map.put(result, :mutation_state, :indeterminate)

  defp maybe_put_mutation_state(result, nil), do: result

  defp terminal_provider_failure?({:error, %ProviderError{} = error}) do
    ProviderError.valid?(error) and
      (error.kind == :denied or
         (error.kind == :invalid_result and
            error.details in ["mcp_capability_negotiation_error", "mcp_protocol_error"]))
  end

  defp terminal_provider_failure?(_result), do: false

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
