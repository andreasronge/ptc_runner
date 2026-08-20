defmodule PtcRunner.Kernel.Dispatcher do
  @moduledoc """
  Internal bounded capability invocation boundary.

  Dispatch validates normalized arguments, atomically reserves environment and
  provider-task budgets in `PtcRunner.Kernel.RunState`, emits canonical attempt
  events, runs the trusted callback in a monitored heap-limited process, and
  constructs the uniform Lisp result envelope. An error `capability-stopped`
  event carries the closed envelope `kind` and `reason`; an unrecognized atom
  is retained only as a one-way fingerprint, and details stay off that event.
  Completion is checked against run closure so late results cannot
  re-enter Lisp.

  Mission failures after callback entry are classified with the capability's
  declared effect. Read failures keep an explicit typed provider retry policy.
  Unclassified callback raises, exits, throws, and monitored process deaths
  default to non-retryable in both environments; Dispatcher-owned provider
  timeouts remain retryable. Write and unknown failures are non-retryable and
  carry `mutation_state: :indeterminate` when invocation may have reached
  external state and the outcome is unknown. A trusted `ProviderError` with
  `dispatch_provenance: :not_dispatched` or `:dispatched` preserves its
  specific policy without exposing that internal provenance. Workflow capabilities also
  retain explicit provider-owned retry policy.
  Before a mission provider publishes a terminal policy failure, its monitored
  callback records that classification in RunState so a subsequent evaluator
  kill cannot make the agent repeat the call.

  A pre-callback input-schema rejection may add up to three schema-authored
  argument violations to the Lisp error envelope. The rejected arguments,
  undeclared property names, and opaque semantic-validator reasons remain
  withheld. Enum and const literals are never included. If bounded schema
  validation itself becomes unavailable, Dispatcher returns the distinct
  `capability_unavailable/input_validation_unavailable` category without
  charging protocol or capability-call budgets or emitting capability events.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityExceptionDiagnostic
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RoutedCapability
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp.AmbiguousArguments
  alias PtcRunner.Lisp.RetainedSize

  @validation_handoff_ms 25

  @doc "Dispatches one capability through the bounded, context-aware boundary."
  @spec dispatch(
          RunState.t(),
          :workflow | :mission,
          map(),
          binary(),
          map(),
          map(),
          term(),
          term()
        ) :: map()
  def dispatch(
        state,
        environment,
        %{capabilities: capabilities},
        name,
        arguments,
        %{
          timeout_ms: timeout_ms,
          validation_heap_words: validation_heap_words,
          evaluation_lease: evaluation_lease,
          validation_deadline_ms: validation_deadline_ms,
          mission_name: mission_name
        } = dispatch_context,
        event_sink,
        inspection_sink
      )
      when environment in [:workflow, :mission] and is_binary(name) and is_map(arguments) and
             not is_struct(arguments, AmbiguousArguments) and
             is_integer(timeout_ms) and is_integer(validation_heap_words) and
             validation_heap_words > 0 and
             (is_reference(evaluation_lease) or is_nil(evaluation_lease)) and
             (is_integer(validation_deadline_ms) or is_nil(validation_deadline_ms)) and
             ((environment == :workflow and is_nil(mission_name)) or
                (environment == :mission and is_binary(mission_name))) do
    dispatch_with_context(
      state,
      environment,
      capabilities,
      name,
      arguments,
      dispatch_context,
      event_sink,
      inspection_sink
    )
  end

  def dispatch(
        state,
        environment,
        %{capabilities: _capabilities},
        _name,
        %AmbiguousArguments{},
        %{evaluation_lease: evaluation_lease, mission_name: mission_name},
        event_sink,
        _inspection_sink
      )
      when (environment == :workflow and is_nil(mission_name)) or
             (environment == :mission and is_binary(mission_name)) do
    protocol_error(state, event_sink, :ambiguous_arguments, environment, evaluation_lease)
  end

  defp dispatch_with_context(
         state,
         environment,
         capabilities,
         name,
         arguments,
         %{
           timeout_ms: timeout_ms,
           validation_heap_words: validation_heap_words,
           evaluation_lease: evaluation_lease,
           validation_deadline_ms: validation_deadline_ms
         } = dispatch_context,
         event_sink,
         inspection_sink
       ) do
    mission_name = Map.get(dispatch_context, :mission_name)

    validation_deadline_ms =
      shared_validation_deadline(
        validation_deadline_ms,
        state,
        environment,
        timeout_ms
      )

    # Advisory pre-authentication keeps a dead evaluation's lingering call
    # away from validators and protocol accounting; reserve_capability/4
    # atomically re-checks the same lease.
    with true <- authenticated?(state, environment, evaluation_lease),
         capability
         when is_struct(capability, Capability) or is_struct(capability, RoutedCapability) <-
           Map.get(capabilities, name),
         :ok <- validate_size(arguments, capability_argument_limit(state)),
         :ok <-
           validate(
             capability,
             arguments,
             state,
             environment,
             timeout_ms,
             validation_heap_words,
             validation_deadline_ms
           ),
         {:ok, invocation} <-
           resolve_invocation(
             capability,
             arguments,
             state,
             environment,
             timeout_ms,
             validation_heap_words,
             validation_deadline_ms
           ) do
      invocation = put_mission_name(invocation, environment, mission_name)

      case RunState.reserve_capability(
             state,
             environment,
             name,
             evaluation_lease,
             route_reservation(invocation)
           ) do
        :ok ->
          invoke_with_events(
            state,
            name,
            invocation,
            timeout_ms,
            environment,
            event_sink,
            inspection_sink
          )

        {:error, :route_call_limit} ->
          limit_error(
            state,
            event_sink,
            :capability_quota,
            environment,
            mission_name,
            max_calls_details(invocation)
          )

        {:error, :limit_exceeded} ->
          limit_error(
            state,
            event_sink,
            :capability_quota,
            environment,
            mission_name,
            RunState.capability_quota_details(state, environment, name)
          )

        {:error, :live_task_limit} ->
          limit_error(state, event_sink, :live_provider_tasks, environment, mission_name)

        {:error, :reservation_held} ->
          limit_error(state, event_sink, :reservation_held, environment, mission_name)

        {:error, :stale_evaluation} ->
          stale_evaluation_error()

        {:error, :run_closed} ->
          limit_error(state, event_sink, :run_closed, environment, mission_name)
      end
    else
      nil ->
        %{status: :error, kind: :capability_denied, reason: :capability_absent, retryable?: false}

      {:error, :invalid_arguments, []} ->
        protocol_error(
          state,
          event_sink,
          :invalid_arguments,
          environment,
          evaluation_lease,
          nil,
          mission_name
        )

      {:error, :invalid_arguments, violations} ->
        protocol_error(
          state,
          event_sink,
          :invalid_arguments,
          environment,
          evaluation_lease,
          violations,
          mission_name
        )

      {:error, :invalid_arguments} ->
        protocol_error(
          state,
          event_sink,
          :invalid_arguments,
          environment,
          evaluation_lease,
          nil,
          mission_name
        )

      {:error, :input_validation_unavailable} ->
        _ = mark_terminal_host_failure(state, environment, evaluation_lease)

        %{
          status: :error,
          kind: :capability_unavailable,
          reason: :input_validation_unavailable,
          retryable?: false
        }

      {:error, :resolver_unavailable} ->
        _ = mark_terminal_host_failure(state, environment, evaluation_lease)

        %{
          status: :error,
          kind: :capability_unavailable,
          reason: :resolver_unavailable,
          retryable?: false
        }

      {:error, :argument_exceeded} ->
        protocol_error(
          state,
          event_sink,
          :argument_exceeded,
          environment,
          evaluation_lease,
          nil,
          mission_name
        )

      {:error, reason, details} when is_atom(reason) and is_binary(details) ->
        protocol_error(
          state,
          event_sink,
          reason,
          environment,
          evaluation_lease,
          details,
          mission_name
        )

      false ->
        stale_evaluation_error()

      {:error, :stale_evaluation} ->
        stale_evaluation_error()
    end
  end

  defp put_mission_name(invocation, :mission, mission_name) when is_binary(mission_name),
    do: %{
      invocation
      | event_attributes: Map.put(invocation.event_attributes, :mission_name, mission_name)
    }

  defp put_mission_name(invocation, _environment, _mission_name), do: invocation

  defp route_reservation(%CapabilityInvocation{route_key: route_key, max_calls: max_calls})
       when is_binary(route_key) and is_integer(max_calls) and max_calls > 0,
       do: %{route_key: route_key, max_calls: max_calls}

  defp route_reservation(_invocation), do: nil

  defp max_calls_details(%CapabilityInvocation{route_key: alias_name, max_calls: max_calls})
       when is_binary(alias_name) and is_integer(max_calls) and max_calls > 0,
       do: %{limit: :max_calls, alias: alias_name, limit_value: max_calls}

  defp max_calls_details(_invocation), do: %{}

  defp authenticated?(_state, :workflow, _lease), do: true

  defp authenticated?(state, :mission, lease),
    do: RunState.mission_lease_current?(state, lease)

  defp stale_evaluation_error do
    %{
      status: :error,
      kind: :capability_denied,
      reason: :stale_evaluation,
      retryable?: false
    }
  end

  defp invoke_with_events(
         state,
         public_name,
         %CapabilityInvocation{} = invocation,
         timeout_ms,
         environment,
         event_sink,
         inspection_sink
       ) do
    capability = invocation.capability
    arguments = invocation.arguments
    capability_id = Events.id("capability")
    started_ms = System.monotonic_time(:millisecond)

    data =
      Map.merge(invocation.event_attributes, %{
        capability_id: capability_id,
        environment: environment,
        name: public_name
      })

    :telemetry.execute(
      [:ptc_runner, :capability, :start],
      %{system_time: System.system_time()},
      %{
        name: public_name,
        environment: environment,
        capability_id: capability_id,
        live_run: state.pid
      }
    )

    case Events.emit(state, event_sink, "capability-started", data) do
      :ok ->
        {invocation_result, input_captured?} =
          case inspection_input(
                 inspection_sink,
                 capability_id,
                 environment,
                 public_name,
                 arguments,
                 invocation.event_attributes[:mission_name]
               ) do
            :ok ->
              context =
                invocation_context(
                  event_sink,
                  inspection_sink,
                  capability_id,
                  invocation.event_attributes[:mission_name]
                )

              {invoke(state, capability, arguments, timeout_ms, context, environment), true}

            {:error, :inspection_sink_error} ->
              {inspection_failure(state), false}
          end

        {result, exception_diagnostic} = split_exception_diagnostic(invocation_result)

        inspection_attempt = %{
          sink: inspection_sink,
          capability_id: capability_id,
          environment: environment,
          name: public_name,
          mission_name: invocation.event_attributes[:mission_name]
        }

        {result, output_allowed?} =
          maybe_capture_exception(
            result,
            exception_diagnostic,
            input_captured?,
            state,
            inspection_attempt,
            capability
          )

        result =
          if output_allowed? do
            case inspection_output(
                   inspection_sink,
                   capability_id,
                   environment,
                   public_name,
                   result,
                   invocation.event_attributes[:mission_name]
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

        _ =
          maybe_emit_limit(
            state,
            event_sink,
            result,
            environment,
            invocation.event_attributes[:mission_name]
          )

        stopped_data =
          invocation.event_attributes
          |> maybe_merge_error_attributes(result, invocation.error_attributes)
          |> maybe_put_usage(result, invocation.usage_projection)
          |> Map.merge(%{
            capability_id: capability_id,
            environment: environment,
            name: public_name,
            status: result.status,
            duration_ms: Events.duration_ms(started_ms)
          })
          |> Events.put_rejection_class(result)

        _ = maybe_record_llm_usage(state, stopped_data)

        :telemetry.execute(
          [:ptc_runner, :capability, :stop],
          %{duration_ms: Events.duration_ms(started_ms)},
          %{
            name: public_name,
            environment: environment,
            capability_id: capability_id,
            status: result.status,
            live_run: state.pid
          }
        )

        _ = Events.emit(state, event_sink, "capability-stopped", stopped_data)

        result

      {:error, :event_sink_error} ->
        RunState.release_provider_slot(state)

        limit_error(
          state,
          nil,
          :run_closed,
          environment,
          invocation.event_attributes[:mission_name]
        )
    end
  end

  defp inspection_input(nil, _capability_id, _environment, _name, _arguments, _mission_name),
    do: :ok

  defp inspection_input(sink, capability_id, environment, name, arguments, mission_name) do
    InspectionSink.emit(
      sink,
      "capability-input",
      %{capability_id: capability_id},
      capability_inspection_payload(environment, name, :arguments, arguments, mission_name)
    )
  end

  defp inspection_output(nil, _capability_id, _environment, _name, _result, _mission_name),
    do: :ok

  defp inspection_output(sink, capability_id, environment, name, result, mission_name) do
    InspectionSink.emit(
      sink,
      "capability-output",
      %{capability_id: capability_id},
      capability_inspection_payload(environment, name, :result, result, mission_name)
    )
  end

  defp maybe_capture_exception(
         result,
         _diagnostic,
         false,
         _state,
         _inspection_attempt,
         _capability
       ),
       do: {result, false}

  defp maybe_capture_exception(
         result,
         nil,
         true,
         _state,
         _inspection_attempt,
         _capability
       ),
       do: {result, true}

  defp maybe_capture_exception(
         result,
         diagnostic,
         true,
         state,
         inspection_attempt,
         capability
       ) do
    case inspection_exception(
           inspection_attempt.sink,
           inspection_attempt.capability_id,
           inspection_attempt.environment,
           inspection_attempt.name,
           diagnostic,
           inspection_attempt.mission_name
         ) do
      :ok ->
        {result, true}

      {:error, :inspection_sink_error} ->
        failed =
          state
          |> inspection_failure()
          |> post_invocation_failure(inspection_attempt.environment, capability)

        {failed, false}
    end
  end

  defp inspection_exception(
         sink,
         capability_id,
         environment,
         name,
         diagnostic,
         mission_name
       ) do
    InspectionSink.emit(
      sink,
      "capability-exception",
      %{capability_id: capability_id},
      environment
      |> capability_inspection_identity(name, mission_name)
      |> Map.merge(diagnostic)
    )
  end

  defp capability_inspection_payload(environment, name, key, value, mission_name) do
    environment
    |> capability_inspection_identity(name, mission_name)
    |> Map.put(key, value)
  end

  defp capability_inspection_identity(environment, name, mission_name) do
    %{environment: environment, name: name}
    |> then(fn payload ->
      if environment == :mission and is_binary(mission_name),
        do: Map.put(payload, :mission_name, mission_name),
        else: payload
    end)
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

  defp invocation_context(event_sink, inspection_sink, capability_id, mission_name) do
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
    |> then(fn context ->
      if is_binary(mission_name), do: Map.put(context, :mission_name, mission_name), else: context
    end)
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
              result = safely_invoke(capability.callback, arguments, context, parent)

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

        case RunState.finish_provider(
               state,
               replay_request_hash(result),
               llm_provider_error(capability, result)
             ) do
          :ok ->
            normalize_result(state, environment, capability, result)

          {:error, :run_closed} ->
            cancel_exception_diagnostic(result)

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
      retryable?: false
    }
  end

  defp safely_invoke(callback, arguments, context, diagnostic_owner) do
    if is_function(callback, 2), do: callback.(arguments, context), else: callback.(arguments)
  rescue
    exception -> raised_exception(exception, __STACKTRACE__, context, diagnostic_owner)
  catch
    :exit, _reason -> {:raised, :exit}
    _kind, _reason -> {:raised, :throw}
  end

  defp raised_exception(
         exception,
         stacktrace,
         %{inspection_sink: %InspectionSink{}},
         diagnostic_owner
       ) do
    case CapabilityExceptionDiagnostic.start(exception, stacktrace, diagnostic_owner) do
      {:ok, pid, exception_class} ->
        {:raised, :exception, {:diagnostic_worker, pid, exception_class}}

      {:error, exception_class} ->
        {:raised, :exception, {:diagnostic_unavailable, exception_class}}
    end
  end

  defp raised_exception(_exception, _stacktrace, _context, _diagnostic_owner),
    do: {:raised, :exception}

  defp split_exception_diagnostic({:with_exception_diagnostic, result, diagnostic}),
    do: {result, diagnostic}

  defp split_exception_diagnostic(result), do: {result, nil}

  defp cancel_exception_diagnostic(
         {:raised, :exception, {:diagnostic_worker, pid, _exception_class}}
       ),
       do: CapabilityExceptionDiagnostic.cancel(pid)

  defp cancel_exception_diagnostic(_result), do: :ok

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
      %{status: :error, kind: :provider_error, reason: reason, retryable?: false},
      environment,
      capability
    )
  end

  defp normalize_result(
         state,
         environment,
         capability,
         {:raised, :exception, {:diagnostic_worker, pid, exception_class}}
       ) do
    {:with_exception_diagnostic,
     normalize_result(state, environment, capability, {:raised, :exception}),
     CapabilityExceptionDiagnostic.await(pid, exception_class)}
  end

  defp normalize_result(
         state,
         environment,
         capability,
         {:raised, :exception, {:diagnostic_unavailable, exception_class}}
       ) do
    {:with_exception_diagnostic,
     normalize_result(state, environment, capability, {:raised, :exception}),
     CapabilityExceptionDiagnostic.unavailable(exception_class)}
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
       when effect in [:write, :unknown] and provenance in [nil, :possibly_dispatched] do
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

  defp replay_request_hash({:error, %ProviderError{} = error}) do
    if ProviderError.valid?(error), do: error.replay_request_hash, else: nil
  end

  defp replay_request_hash(_result), do: nil

  defp llm_provider_error(
         %Capability{name: "llm-request"},
         {:error, %ProviderError{} = error}
       ) do
    if ProviderError.valid?(error), do: error, else: nil
  end

  defp llm_provider_error(_capability, _result), do: nil

  defp terminal_provider_failure?({:error, %ProviderError{} = error}) do
    ProviderError.valid?(error) and
      (error.kind == :denied or
         (error.kind == :invalid_result and
            error.details in ["mcp_capability_negotiation_error", "mcp_protocol_error"]))
  end

  defp terminal_provider_failure?(_result), do: false

  defp validate(
         %Capability{} = capability,
         arguments,
         state,
         environment,
         requested_timeout_ms,
         validation_heap_words,
         validation_deadline_ms
       ) do
    limits = state_limits(state)

    dispatch_timeout_ms =
      min(
        requested_timeout_ms,
        min(validation_timeout_ms(limits, environment), RunState.remaining_ms(state))
      )

    validation_timeout_ms =
      validation_worker_timeout_ms(dispatch_timeout_ms, validation_deadline_ms)

    cond do
      dispatch_timeout_ms <= 0 ->
        {:error, :run_closed}

      validation_timeout_ms <= 0 ->
        {:error, :input_validation_unavailable}

      true ->
        case JSONSchema.validate(
               capability.input_validator,
               capability.input_schema,
               arguments,
               validation_timeout_ms,
               validation_heap_words
             ) do
          :ok -> semantic_validate(capability, arguments)
          {:invalid, violations} -> {:error, :invalid_arguments, violations}
          {:unavailable, _internal_cause} -> {:error, :input_validation_unavailable}
        end
    end
  end

  defp validate(
         %RoutedCapability{} = capability,
         arguments,
         state,
         environment,
         requested_timeout_ms,
         validation_heap_words,
         validation_deadline_ms
       ) do
    with {:ok, validation_arguments} <-
           RoutedCapability.validation_arguments(capability, arguments) do
      validate_schema(
        capability,
        validation_arguments,
        state,
        environment,
        requested_timeout_ms,
        validation_heap_words,
        validation_deadline_ms
      )
    end
  end

  defp validate_schema(
         capability,
         arguments,
         state,
         environment,
         requested_timeout_ms,
         validation_heap_words,
         validation_deadline_ms
       ) do
    limits = state_limits(state)

    dispatch_timeout_ms =
      min(
        requested_timeout_ms,
        min(validation_timeout_ms(limits, environment), RunState.remaining_ms(state))
      )

    validation_timeout_ms =
      validation_worker_timeout_ms(dispatch_timeout_ms, validation_deadline_ms)

    cond do
      dispatch_timeout_ms <= 0 ->
        {:error, :run_closed}

      validation_timeout_ms <= 0 ->
        {:error, :input_validation_unavailable}

      true ->
        case JSONSchema.validate(
               capability.input_validator,
               capability.input_schema,
               arguments,
               validation_timeout_ms,
               validation_heap_words
             ) do
          :ok -> :ok
          {:invalid, violations} -> {:error, :invalid_arguments, violations}
          {:unavailable, _internal_cause} -> {:error, :input_validation_unavailable}
        end
    end
  end

  defp validation_timeout_ms(limits, :workflow), do: limits.workflow_timeout_ms
  defp validation_timeout_ms(limits, :mission), do: limits.evaluation_timeout_ms

  defp validation_worker_timeout_ms(timeout_ms, deadline_ms) when is_integer(deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond) - @validation_handoff_ms
    min(timeout_ms, max(remaining_ms, 0))
  end

  defp mark_terminal_host_failure(state, :mission, evaluation_lease)
       when is_reference(evaluation_lease),
       do: RunState.mark_evaluation_terminal_host_failure(state, evaluation_lease)

  defp mark_terminal_host_failure(_state, _environment, _evaluation_lease), do: :ok

  defp semantic_validate(%Capability{validate: nil}, _arguments), do: :ok

  defp semantic_validate(%Capability{validate: validate}, arguments) do
    case validate.(arguments) do
      :ok -> :ok
      _ -> {:error, :invalid_arguments}
    end
  rescue
    _exception -> {:error, :invalid_arguments}
  end

  defp resolve_invocation(
         %Capability{} = capability,
         arguments,
         _state,
         _environment,
         _timeout_ms,
         _validation_heap_words,
         _validation_deadline_ms
       ),
       do: {:ok, CapabilityInvocation.leaf(capability, arguments)}

  defp resolve_invocation(
         %RoutedCapability{} = routed,
         arguments,
         state,
         environment,
         timeout_ms,
         validation_heap_words,
         validation_deadline_ms
       ) do
    with {:ok, %CapabilityInvocation{} = invocation} <-
           RoutedCapability.resolve(routed, arguments),
         :ok <- validate_size(invocation.arguments, capability_argument_limit(state)),
         :ok <-
           validate(
             invocation.capability,
             invocation.arguments,
             state,
             environment,
             timeout_ms,
             validation_heap_words,
             validation_deadline_ms
           ) do
      {:ok, invocation}
    end
  end

  defp shared_validation_deadline(deadline_ms, _state, _environment, _timeout_ms)
       when is_integer(deadline_ms),
       do: deadline_ms

  defp shared_validation_deadline(nil, state, environment, timeout_ms) do
    limits = state_limits(state)

    available_ms =
      min(
        timeout_ms,
        min(validation_timeout_ms(limits, environment), RunState.remaining_ms(state))
      )

    System.monotonic_time(:millisecond) + max(available_ms, 0) + @validation_handoff_ms
  end

  defp maybe_merge_error_attributes(data, %{status: :error}, attributes),
    do: Map.merge(data, attributes)

  defp maybe_merge_error_attributes(data, _result, _attributes), do: data

  defp maybe_put_usage(data, result, :llm_tokens) do
    case LLMUsage.from_response(result) do
      nil -> data
      usage -> Map.put(data, :usage, usage)
    end
  end

  defp maybe_put_usage(data, _result, nil), do: data

  defp maybe_record_llm_usage(state, data) when is_map(data) do
    name = Map.get(data, :name) || Map.get(data, "name")
    alias_name = Map.get(data, :alias) || Map.get(data, "alias")
    revision = Map.get(data, :installation_revision) || Map.get(data, "installation_revision")
    status = Map.get(data, :status) || Map.get(data, "status")
    usage = Map.get(data, :usage) || Map.get(data, "usage")

    if llm_spend_identity?(name, alias_name, revision) do
      case spend_status(status) do
        nil -> :ok
        normalized -> RunState.record_llm_usage(state, alias_name, revision, normalized, usage)
      end
    else
      :ok
    end
  end

  defp llm_spend_identity?(name, alias_name, revision)
       when name in ["llm-request", :"llm-request"] and is_binary(alias_name) and
              is_binary(revision),
       do: true

  defp llm_spend_identity?(_name, _alias_name, _revision), do: false

  defp spend_status(status) when status in [:ok, "ok"], do: :ok
  defp spend_status(status) when status in [:error, "error"], do: :error
  defp spend_status(_status), do: nil

  defp valid_output?(%Capability{output_validator: nil}, _value), do: true

  defp valid_output?(%Capability{output_validator: validator}, value),
    do: JSONSchema.valid?(validator, value)

  defp validate_size(value, cap) do
    case RetainedSize.bytes_with_cap(value, cap) do
      bytes when is_integer(bytes) and bytes <= cap ->
        :ok

      :oversized ->
        if json_value?(value),
          do: {:error, :argument_exceeded},
          else: {:error, :invalid_arguments}

      _ ->
        {:error, :argument_exceeded}
    end
  end

  # Authentication and accounting are one atomic owner operation: a mission
  # call whose evaluation died mid-validation must not spend the next
  # evaluation's shared protocol-error budget.
  defp protocol_error(
         state,
         event_sink,
         reason,
         environment,
         lease,
         details \\ nil,
         mission_name \\ nil
       ) do
    case RunState.protocol_error(state, environment, lease) do
      :ok ->
        result = %{status: :error, kind: :protocol_error, reason: reason, retryable?: false}
        if is_nil(details), do: result, else: Map.put(result, :details, details)

      {:error, :stale_evaluation} ->
        stale_evaluation_error()

      {:error, :protocol_error_limit} ->
        limit_error(
          state,
          event_sink,
          :protocol_errors,
          environment,
          mission_name,
          RunState.protocol_errors_details(state)
        )
    end
  end

  defp limit_error(
         state,
         event_sink,
         reason,
         environment \\ nil,
         mission_name \\ nil,
         extra \\ %{}
       ) do
    data = Map.merge(limit_event_data(reason, environment, mission_name), extra)
    _ = Events.emit(state, event_sink, "limit-exceeded", data)
    envelope = %{status: :error, kind: :limit_exceeded, reason: reason, retryable?: false}

    if extra == %{}, do: envelope, else: Map.put(envelope, :details, extra)
  end

  defp maybe_emit_limit(
         state,
         event_sink,
         %{kind: kind, reason: reason},
         environment,
         mission_name
       )
       when kind in [:timeout, :result_exceeded, :limit_exceeded] do
    Events.emit(
      state,
      event_sink,
      "limit-exceeded",
      limit_event_data(reason, environment, mission_name)
    )
  end

  defp maybe_emit_limit(_state, _event_sink, _result, _environment, _mission_name), do: :ok

  defp limit_event_data(reason, :mission, mission_name) do
    %{reason: reason, environment: :mission, mission_name: mission_name}
  end

  defp limit_event_data(reason, :workflow, _mission_name),
    do: %{reason: reason, environment: :workflow}

  defp limit_event_data(reason, _environment, _mission_name), do: %{reason: reason}

  defp normalize_exit(:killed), do: :provider_heap_exceeded
  defp normalize_exit(_reason), do: :provider_exit
  defp capability_argument_limit(state), do: state_limits(state).capability_argument_bytes
  defp capability_result_limit(state), do: state_limits(state).capability_result_bytes
  defp state_limits(state), do: RunState.limits(state)

  defp json_value?(value) do
    JSONValue.value?(value)
  rescue
    _exception -> false
  end
end
