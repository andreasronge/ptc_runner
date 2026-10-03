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
  withheld. Enum and const literals are never included.   After static input
  validation, a request `schema` is compiled with
  `PtcRunner.Kernel.JSONSchema.compile_bounded/3` and stored only on the
  private invocation. A schema together with a non-empty `tools` list is
  `invalid_arguments` before reservation. A proven-invalid request schema is
  `invalid_arguments` even when the selected alias declares structured output
  `unsupported`. A live alias whose `structured_output_mode` is `unsupported`
  then refuses a compiled schema request as
  `provider_error/structured_output_unsupported` before reservation.
  Compiler unavailability uses the same
  `capability_unavailable/input_validation_unavailable` category, with no
  dispatch. Provider JSON-object bytes are decoded in a bounded worker
  before the compiled request schema validates the object; only a
  `structured_output` envelope then reaches Lisp. If bounded output
  validation itself becomes unavailable after dispatch, Dispatcher returns
  `capability_unavailable/output_validation_unavailable` rather than treating
  the provider result as invalid. A live `llm-request` also carries one
  absolute `llm_request_deadline_ms` sampled immediately before admission.
  Dispatcher enforces that cutoff through the provider worker and structured
  output validation; when it wins over enclosing run/workflow clocks the
  public result is retryable `timeout/llm_request_timeout`. Replay calls
  receive `nil` and stay on the enclosing provider-worker clocks.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.Dispatcher.LlmResult
  alias PtcRunner.Kernel.Dispatcher.ProviderCall
  alias PtcRunner.Kernel.Dispatcher.Result
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ModelCapabilities
  alias PtcRunner.Kernel.RoutedCapability
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp.AmbiguousArguments

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
         :ok <- Result.validate_size(arguments, capability_argument_limit(state)),
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
           ),
         invocation <-
           %{invocation | model_call_names: Map.get(dispatch_context, :model_call_names, [])},
         {:ok, invocation} <-
           compile_request_schema(
             invocation,
             state,
             environment,
             timeout_ms,
             validation_heap_words,
             validation_deadline_ms
           ),
         invocation <- put_mission_name(invocation, environment, mission_name),
         invocation <-
           bind_llm_deadline(invocation, state, timeout_ms, validation_deadline_ms),
         {:ok, invocation} <-
           attest_llm_reservation(
             invocation,
             state,
             validation_heap_words,
             validation_deadline_ms
           ) do
      validation =
        output_validation(validation_heap_words, validation_deadline_ms, evaluation_lease)

      case RunState.reserve_capability(
             state,
             environment,
             name,
             evaluation_lease,
             route_reservation(invocation)
           ) do
        {:ok, reservation_id} ->
          invoke_with_events(
            state,
            reservation_id,
            name,
            invocation,
            timeout_ms,
            environment,
            {event_sink, inspection_sink},
            validation
          )

        {:error, :route_call_limit} ->
          maybe_merge_error_attributes(
            Result.limit_error(
              state,
              event_sink,
              :capability_quota,
              environment,
              mission_name,
              max_calls_details(invocation)
            ),
            %{status: :error},
            invocation.error_attributes
          )

        {:error, :limit_exceeded} ->
          maybe_merge_error_attributes(
            Result.limit_error(
              state,
              event_sink,
              :capability_quota,
              environment,
              mission_name,
              RunState.capability_quota_details(state, environment, name)
            ),
            %{status: :error},
            invocation.error_attributes
          )

        {:error, :live_task_limit} ->
          Result.limit_error(state, event_sink, :live_provider_tasks, environment, mission_name)

        {:error, :reservation_held} ->
          Result.limit_error(state, event_sink, :reservation_held, environment, mission_name)

        {:error, :llm_output_limit} ->
          _ = Result.mark_terminal_host_failure(state, environment, evaluation_lease)

          %{
            status: :error,
            kind: :capability_unavailable,
            reason: :llm_output_authorization_invalid,
            retryable?: false
          }

        {:error, :llm_total_tokens_limit, details} ->
          Result.limit_error(
            state,
            event_sink,
            :llm_total_tokens,
            environment,
            mission_name,
            details
          )

        {:error, :llm_cost_limit, details} ->
          Result.limit_error(
            state,
            event_sink,
            :llm_cost_microusd,
            environment,
            mission_name,
            details
          )

        {:error, :stale_evaluation} ->
          stale_evaluation_error()

        {:error, :run_closed} ->
          Result.limit_error(state, event_sink, :run_closed, environment, mission_name)
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
        _ = Result.mark_terminal_host_failure(state, environment, evaluation_lease)

        %{
          status: :error,
          kind: :capability_unavailable,
          reason: :input_validation_unavailable,
          retryable?: false
        }

      {:error, :resolver_unavailable} ->
        _ = Result.mark_terminal_host_failure(state, environment, evaluation_lease)

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

      {:error, :run_closed} ->
        Result.limit_error(state, event_sink, :run_closed, environment, mission_name)

      {:error, :structured_output_unsupported, invocation} ->
        maybe_merge_error_attributes(
          %{
            status: :error,
            kind: :provider_error,
            reason: :structured_output_unsupported,
            retryable?: false
          },
          %{status: :error},
          invocation.error_attributes
        )

      {:error, :reservation_attestation_unavailable} ->
        _ = Result.mark_terminal_host_failure(state, environment, evaluation_lease)

        %{
          status: :error,
          kind: :capability_unavailable,
          reason: :reservation_attestation_unavailable,
          retryable?: false
        }
    end
  end

  defp put_mission_name(invocation, :mission, mission_name) when is_binary(mission_name),
    do: %{
      invocation
      | event_attributes: Map.put(invocation.event_attributes, :mission_name, mission_name)
    }

  defp put_mission_name(invocation, _environment, _mission_name), do: invocation

  defp bind_llm_deadline(
         %CapabilityInvocation{request_timeout_ms: request_timeout_ms} = invocation,
         state,
         requested_timeout_ms,
         validation_deadline_ms
       )
       when is_integer(request_timeout_ms) and is_integer(validation_deadline_ms) do
    now = System.monotonic_time(:millisecond)
    limits = Result.state_limits(state)

    enclosing_remaining =
      requested_timeout_ms
      |> min(RunState.remaining_ms(state))
      |> max(0)

    llm_remaining =
      request_timeout_ms
      |> min(limits.llm_request_timeout_ms)
      |> max(0)

    enclosing_deadline_ms = min(now + enclosing_remaining, validation_deadline_ms)

    %{
      invocation
      | enclosing_deadline_ms: enclosing_deadline_ms,
        llm_request_deadline_ms: min(enclosing_deadline_ms, now + llm_remaining)
    }
  end

  defp bind_llm_deadline(
         %CapabilityInvocation{} = invocation,
         _state,
         _requested_timeout_ms,
         _validation_deadline_ms
       ),
       do: %{invocation | llm_request_deadline_ms: nil, enclosing_deadline_ms: nil}

  defp put_llm_requester_deadline(
         %CapabilityInvocation{
           capability: %Capability{name: name},
           llm_request_deadline_ms: deadline
         } = invocation,
         context
       )
       when is_integer(deadline) or is_nil(deadline) do
    if ModelCapabilities.model_call?(name, invocation.model_call_names),
      do: Map.put(context, :llm_request_deadline_ms, deadline),
      else: context
  end

  defp put_llm_requester_deadline(_invocation, context), do: context

  defp route_reservation(%CapabilityInvocation{} = invocation) do
    %{}
    |> maybe_put_route_quota(invocation)
    |> maybe_put_llm_reservation(invocation)
    |> case do
      empty when map_size(empty) == 0 -> nil
      reservation -> reservation
    end
  end

  defp maybe_put_route_quota(route, %CapabilityInvocation{
         route_key: route_key,
         max_calls: max_calls
       })
       when is_binary(route_key) and is_integer(max_calls) and max_calls > 0,
       do: Map.merge(route, %{route_key: route_key, max_calls: max_calls})

  defp maybe_put_route_quota(route, _invocation), do: route

  defp maybe_put_llm_reservation(route, %CapabilityInvocation{llm_source: source} = invocation)
       when source in ["llm", "llm_replay", "decision", "decision_replay"] do
    route
    |> Map.put(:source, source)
    |> maybe_put_positive(:output_tokens, invocation.llm_output_tokens)
    |> maybe_put_attested_bounds(invocation.reservation)
  end

  defp maybe_put_llm_reservation(route, _invocation), do: route

  defp maybe_put_attested_bounds(route, %{total_tokens: total_tokens, cost_microusd: cost}) do
    route
    |> maybe_put_non_negative(:total_tokens, total_tokens)
    |> maybe_put_non_negative(:cost_microusd, cost)
  end

  defp maybe_put_attested_bounds(route, _reservation), do: route

  defp maybe_put_positive(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp maybe_put_positive(map, _key, _value), do: map

  defp maybe_put_non_negative(map, key, value) when is_integer(value) and value >= 0,
    do: Map.put(map, key, value)

  defp maybe_put_non_negative(map, _key, _value), do: map

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
         reservation_id,
         public_name,
         %CapabilityInvocation{} = invocation,
         timeout_ms,
         environment,
         {event_sink, inspection_sink},
         validation
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
                 invocation.event_attributes[:mission_name],
                 invocation.model_call_names
               ) do
            :ok ->
              context =
                invocation
                |> put_llm_requester_deadline(
                  invocation_context(
                    event_sink,
                    inspection_sink,
                    capability_id,
                    invocation.event_attributes[:mission_name],
                    capability.inspection_capture
                  )
                )
                |> Map.put(:provider_run_state, state)

              {ProviderCall.invoke(
                 state,
                 reservation_id,
                 invocation,
                 timeout_ms,
                 context,
                 environment,
                 validation
               ), true}

            {:error, :inspection_sink_error} ->
              {{:settlement, {:adapter_error, :not_dispatched}, inspection_failure(state)}, false}
          end

        {settlement, invocation_result} = split_settlement(invocation_result)
        {result, exception_diagnostic} = split_exception_diagnostic(invocation_result)

        decision_evidence = maybe_put_decision_model(%{}, result, public_name)

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
          result
          |> Result.admit_success_output(state, environment, invocation, validation)
          |> merge_result_attributes(invocation.result_attributes)

        inspection_failed_before_settlement? = inspection_failure?(result)

        settled_result =
          settle_provider_result(
            state,
            reservation_id,
            settlement,
            result,
            environment,
            capability
          )

        result =
          if inspection_failed_before_settlement?,
            do: result,
            else: settled_result

        result = maybe_merge_error_attributes(result, result, invocation.error_attributes)

        result =
          if output_allowed? do
            case inspection_output(
                   inspection_sink,
                   capability_id,
                   environment,
                   public_name,
                   {result, decision_evidence},
                   invocation.event_attributes[:mission_name],
                   capability.inspection_capture,
                   invocation.model_call_names
                 ) do
              :ok ->
                result

              {:error, :inspection_sink_error} ->
                state
                |> inspection_failure()
                |> Result.post_invocation_failure(environment, capability)
            end
          else
            result
          end

        if inspection_failure?(result),
          do: RunState.fail(state, :inspection_sink_error, :inspection_sink_error)

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
          |> maybe_put_settlement_usage(settlement, invocation.usage_projection)
          |> maybe_put_usage_observation(settlement, invocation.usage_projection)
          |> LlmResult.maybe_put_llm_result_metadata(result, invocation.usage_projection)
          |> Map.merge(decision_evidence)
          |> Map.merge(%{
            capability_id: capability_id,
            environment: environment,
            name: public_name,
            status: result.status,
            duration_ms: Events.duration_ms(started_ms)
          })
          |> Events.put_rejection_class(result)

        _ = maybe_record_llm_usage(state, stopped_data, invocation.model_call_names)

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

        maybe_merge_error_attributes(result, result, invocation.error_attributes)

      {:error, :event_sink_error} ->
        _ = RunState.finish_provider(state, reservation_id, {:adapter_error, :not_dispatched})

        Result.limit_error(
          state,
          nil,
          :run_closed,
          environment,
          invocation.event_attributes[:mission_name]
        )
    end
  end

  defp inspection_input(
         nil,
         _capability_id,
         _environment,
         _name,
         _arguments,
         _mission_name,
         _model_call_names
       ),
       do: :ok

  defp inspection_input(
         sink,
         capability_id,
         environment,
         name,
         arguments,
         mission_name,
         model_call_names
       ) do
    InspectionSink.emit(
      sink,
      "capability-input",
      %{capability_id: capability_id},
      capability_inspection_payload(
        environment,
        name,
        :arguments,
        arguments,
        mission_name,
        model_call_names
      )
    )
  end

  defp inspection_output(
         nil,
         _capability_id,
         _environment,
         _name,
         _result,
         _mission_name,
         _capture,
         _model_call_names
       ),
       do: :ok

  defp inspection_output(
         sink,
         capability_id,
         environment,
         name,
         {result, decision_evidence},
         mission_name,
         capture,
         model_call_names
       ) do
    InspectionSink.emit(
      sink,
      "capability-output",
      %{capability_id: capability_id},
      capability_inspection_payload(
        environment,
        name,
        :result,
        result,
        mission_name,
        model_call_names
      )
      |> Map.merge(decision_evidence),
      output_capture(result, capture)
    )
  end

  # Digest capture removes bulk read output. Error envelopes are small and are
  # the record an operator reads when a run fails, so they stay full; so does
  # any result shape full capture would not have admitted as a record. The
  # identity itself is computed by the sink, so this process sends the same
  # message in both modes.
  defp output_capture(%{status: :ok}, :digest_results), do: [capture: :digest_results]
  defp output_capture(_result, _capture), do: []

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
          |> Result.post_invocation_failure(inspection_attempt.environment, capability)

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

  defp capability_inspection_payload(
         environment,
         name,
         key,
         value,
         mission_name,
         model_call_names
       ) do
    environment
    |> capability_inspection_identity(name, mission_name)
    |> Map.put(key, value)
    |> maybe_put_llm_request_hash(environment, name, key, value, model_call_names)
  end

  defp maybe_put_llm_request_hash(
         payload,
         :workflow,
         name,
         :arguments,
         arguments,
         model_call_names
       ) do
    if ModelCapabilities.model_call?(name, model_call_names),
      do: put_model_request_hash(payload, arguments),
      else: payload
  end

  defp maybe_put_llm_request_hash(payload, _environment, _name, _key, _value, _model_call_names),
    do: payload

  defp put_model_request_hash(payload, arguments) do
    case LLMReplay.request_hash(arguments) do
      {:ok, request_hash} -> Map.put(payload, :request_hash, request_hash)
      :error -> payload
    end
  end

  defp capability_inspection_identity(environment, name, mission_name) do
    %{environment: environment, name: name}
    |> then(fn payload ->
      if environment == :mission and is_binary(mission_name),
        do: Map.put(payload, :mission_name, mission_name),
        else: payload
    end)
  end

  defp inspection_failure(_state) do
    %{
      status: :error,
      kind: :inspection_sink_error,
      reason: :inspection_sink_error,
      retryable?: false
    }
  end

  defp inspection_failure?(%{kind: :inspection_sink_error}), do: true
  defp inspection_failure?(_result), do: false

  defp invocation_context(event_sink, inspection_sink, capability_id, mission_name, capture) do
    traceparent =
      case event_sink && EventSink.identity(event_sink) do
        {:ok, %{trace_id: trace_id}} -> Events.traceparent(trace_id, capability_id)
        _unavailable -> nil
      end

    %{
      capability_id: capability_id,
      inspection_sink: inspection_sink,
      traceparent: traceparent,
      inspection_capture: capture
    }
    |> then(fn context ->
      if is_binary(mission_name), do: Map.put(context, :mission_name, mission_name), else: context
    end)
  end

  defp split_exception_diagnostic({:with_exception_diagnostic, result, diagnostic}),
    do: {result, diagnostic}

  defp split_exception_diagnostic(result), do: {result, nil}

  defp split_settlement({:settlement, evidence, result}), do: {evidence, result}

  defp settle_provider_result(
         state,
         reservation_id,
         evidence,
         result,
         environment,
         capability
       ) do
    case RunState.finish_provider(state, reservation_id, evidence) do
      {:ok, :settled} ->
        result

      {:ok, {:overrun, _ledgers}} ->
        _ =
          RunState.record_llm_provider_failure(state, :reservation_bound_exceeded, false)

        Result.post_invocation_failure(
          %{
            status: :error,
            kind: :provider_error,
            reason:
              if(capability.name == "decision-request",
                do: :invalid_result,
                else: :reservation_bound_exceeded
              ),
            retryable?: false
          },
          environment,
          capability
        )

      {:error, :unknown_reservation} ->
        state
        |> Result.limit_error(nil, :run_closed)
        |> Result.post_invocation_failure(environment, capability)
    end
  end

  defp output_validation(heap_words, deadline_ms, evaluation_lease) do
    %{heap_words: heap_words, deadline_ms: deadline_ms, evaluation_lease: evaluation_lease}
  end

  defp compile_request_schema(
         %CapabilityInvocation{capability: %Capability{name: name}} = invocation,
         state,
         environment,
         requested_timeout_ms,
         validation_heap_words,
         validation_deadline_ms
       ) do
    if ModelCapabilities.chat?(name),
      do:
        compile_chat_request_schema(
          invocation,
          state,
          environment,
          requested_timeout_ms,
          validation_heap_words,
          validation_deadline_ms
        ),
      else: {:ok, invocation}
  end

  defp compile_chat_request_schema(
         invocation,
         state,
         environment,
         requested_timeout_ms,
         validation_heap_words,
         validation_deadline_ms
       ) do
    case Map.fetch(invocation.arguments, "schema") do
      :error ->
        {:ok, invocation}

      {:ok, schema} ->
        if tools_with_schema?(invocation.arguments) do
          {:error, :invalid_arguments}
        else
          case compile_live_request_schema(
                 invocation,
                 schema,
                 state,
                 environment,
                 requested_timeout_ms,
                 validation_heap_words,
                 validation_deadline_ms
               ) do
            {:ok, compiled} ->
              refuse_unsupported_structured_output(compiled)

            error ->
              error
          end
        end
    end
  end

  defp attest_llm_reservation(
         %CapabilityInvocation{llm_source: source} = invocation,
         _state,
         _heap,
         _deadline
       )
       when source in ["decision", "decision_replay"], do: {:ok, invocation}

  defp attest_llm_reservation(
         %CapabilityInvocation{llm_source: "llm"} = invocation,
         state,
         validation_heap_words,
         validation_deadline_ms
       ) do
    limits = Result.state_limits(state)

    if is_nil(limits.llm_total_tokens) and is_nil(limits.llm_cost_microusd) do
      {:ok, invocation}
    else
      attest_live_llm_reservation(
        invocation,
        state,
        limits,
        validation_heap_words,
        validation_deadline_ms
      )
    end
  end

  defp attest_llm_reservation(
         %CapabilityInvocation{
           capability: %Capability{name: name},
           llm_source: source
         } = invocation,
         state,
         _heap_words,
         _deadline_ms
       )
       when source != "llm_replay" do
    if ModelCapabilities.model_call?(name, invocation.model_call_names),
      do: attest_unbound_model_reservation(invocation, state),
      else: {:ok, invocation}
  end

  defp attest_llm_reservation(invocation, _state, _heap_words, _deadline_ms),
    do: {:ok, invocation}

  defp attest_unbound_model_reservation(invocation, state) do
    limits = Result.state_limits(state)

    if is_nil(limits.llm_total_tokens) and is_nil(limits.llm_cost_microusd),
      do: {:ok, invocation},
      else: {:error, :reservation_attestation_unavailable}
  end

  defp attest_live_llm_reservation(
         %CapabilityInvocation{reservation_bound: bound} = invocation,
         state,
         limits,
         validation_heap_words,
         validation_deadline_ms
       )
       when is_function(bound, 2) do
    timeout_ms =
      invocation
      |> CapabilityInvocation.clamp_provider_timeout(RunState.remaining_ms(state))
      |> validation_worker_timeout_ms(validation_deadline_ms)

    if timeout_ms <= 0 do
      {:error, :reservation_attestation_unavailable}
    else
      result =
        BoundedWorker.run(
          fn -> bound.(invocation.arguments, invocation.llm_reservation_tariff) end,
          timeout_ms: timeout_ms,
          max_heap_words: validation_heap_words,
          cancel_with_caller: true
        )

      case result do
        {:ok, {:ok, attestation}} ->
          put_reservation_attestation(invocation, attestation, limits)

        _unavailable ->
          {:error, :reservation_attestation_unavailable}
      end
    end
  end

  defp attest_live_llm_reservation(
         _invocation,
         _state,
         _limits,
         _validation_heap_words,
         _validation_deadline_ms
       ),
       do: {:error, :reservation_attestation_unavailable}

  defp put_reservation_attestation(
         invocation,
         %{total_tokens: total_tokens, cost: cost} = attestation,
         limits
       )
       when map_size(attestation) == 2 do
    with true <- valid_attested_integer?(total_tokens),
         true <-
           is_integer(invocation.llm_output_tokens) and
             total_tokens >= invocation.llm_output_tokens,
         {:ok, cost_microusd} <-
           validate_attested_cost(cost, invocation.llm_reservation_tariff, limits) do
      {:ok,
       %{
         invocation
         | reservation: %{total_tokens: total_tokens, cost_microusd: cost_microusd}
       }}
    else
      _invalid -> {:error, :reservation_attestation_unavailable}
    end
  end

  defp put_reservation_attestation(_invocation, _attestation, _limits),
    do: {:error, :reservation_attestation_unavailable}

  defp validate_attested_cost(nil, nil, %{llm_cost_microusd: nil}), do: {:ok, nil}

  defp validate_attested_cost(
         %{currency: "USD", microunits: microunits, tariff_id: tariff_id} = cost,
         %{currency: "USD", id: tariff_id} = tariff,
         %{llm_cost_microusd: limit}
       )
       when map_size(cost) == 3 and map_size(tariff) == 2 and is_integer(limit) and
              is_binary(tariff_id) do
    if valid_attested_integer?(microunits), do: {:ok, microunits}, else: :error
  end

  defp validate_attested_cost(_cost, _tariff, _limits), do: :error

  defp valid_attested_integer?(value),
    do: is_integer(value) and value >= 0 and value <= LLMUsage.maximum_integer()

  defp compile_live_request_schema(
         invocation,
         schema,
         state,
         environment,
         requested_timeout_ms,
         validation_heap_words,
         validation_deadline_ms
       ) do
    compile_timeout_ms =
      request_schema_timeout_ms(
        state,
        environment,
        requested_timeout_ms,
        validation_deadline_ms
      )

    cond do
      compile_timeout_ms == :run_closed ->
        {:error, :run_closed}

      compile_timeout_ms <= 0 ->
        {:error, :input_validation_unavailable}

      true ->
        case JSONSchema.compile_bounded(schema, compile_timeout_ms, validation_heap_words) do
          {:ok, normalized, compiled} ->
            put_compiled_request_schema(invocation, normalized, compiled, state)

          {:error, {:invalid_schema, _rejection}} ->
            {:error, :invalid_arguments}

          {:unavailable, _cause} ->
            {:error, :input_validation_unavailable}
        end
    end
  end

  defp tools_with_schema?(arguments) do
    case Map.get(arguments, "tools") do
      tools when is_list(tools) and tools != [] -> true
      _absent -> false
    end
  end

  defp refuse_unsupported_structured_output(
         %CapabilityInvocation{structured_output_mode: :unsupported} = invocation
       ),
       do: {:error, :structured_output_unsupported, invocation}

  defp refuse_unsupported_structured_output(invocation), do: {:ok, invocation}

  defp put_compiled_request_schema(invocation, normalized, compiled, state) do
    invocation = CapabilityInvocation.put_request_schema(invocation, normalized, compiled)

    case Result.validate_size(invocation.arguments, capability_argument_limit(state)) do
      :ok -> {:ok, invocation}
      {:error, _reason} = error -> error
    end
  end

  defp request_schema_timeout_ms(state, environment, requested_timeout_ms, validation_deadline_ms) do
    limits = Result.state_limits(state)

    dispatch_timeout_ms =
      min(
        requested_timeout_ms,
        min(validation_timeout_ms(limits, environment), RunState.remaining_ms(state))
      )

    if dispatch_timeout_ms <= 0 do
      :run_closed
    else
      validation_worker_timeout_ms(dispatch_timeout_ms, validation_deadline_ms)
    end
  end

  defp validate(
         %Capability{} = capability,
         arguments,
         state,
         environment,
         requested_timeout_ms,
         validation_heap_words,
         validation_deadline_ms
       ) do
    limits = Result.state_limits(state)

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
    limits = Result.state_limits(state)

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
         :ok <- Result.validate_size(invocation.arguments, capability_argument_limit(state)),
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
    limits = Result.state_limits(state)

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

  defp maybe_put_settlement_usage(data, {:adapter_success, {:valid, usage}}, :llm_tokens),
    do: Map.put_new(data, :usage, usage)

  defp maybe_put_settlement_usage(data, _settlement, _usage_projection), do: data

  defp maybe_put_usage_observation(data, settlement, :llm_tokens) do
    observation =
      case settlement do
        {:adapter_success, {:valid, _usage}} -> :reported
        {:adapter_error, :not_dispatched} -> :not_expected
        _missing_or_invalid -> :missing
      end

    Map.put(data, :usage_observation, observation)
  end

  defp maybe_put_usage_observation(data, _settlement, _usage_projection), do: data

  defp merge_result_attributes(%{status: :ok, value: value}, attributes)
       when is_map(value) and is_map(attributes) and map_size(attributes) > 0,
       do: %{status: :ok, value: Map.merge(value, attributes)}

  defp merge_result_attributes(result, _attributes), do: result

  defp maybe_put_decision_model(
         data,
         %{status: :ok, value: %{"model" => model}},
         "decision-request"
       )
       when is_binary(model) and byte_size(model) > 0, do: Map.put(data, :served_model, model)

  defp maybe_put_decision_model(data, _result, _name), do: data

  defp maybe_record_llm_usage(state, data, model_call_names) when is_map(data) do
    name = Map.get(data, :name) || Map.get(data, "name")
    alias_name = Map.get(data, :alias) || Map.get(data, "alias")
    revision = Map.get(data, :installation_revision) || Map.get(data, "installation_revision")
    status = Map.get(data, :status) || Map.get(data, "status")
    usage = Map.get(data, :usage) || Map.get(data, "usage")
    observation = Map.get(data, :usage_observation) || Map.get(data, "usage_observation")

    if llm_spend_identity?(name, alias_name, revision, model_call_names) do
      case spend_status(status, observation) do
        nil -> :ok
        normalized -> RunState.record_llm_usage(state, alias_name, revision, normalized, usage)
      end
    else
      :ok
    end
  end

  defp llm_spend_identity?(name, alias_name, revision, model_call_names)
       when is_binary(alias_name) and is_binary(revision),
       do: ModelCapabilities.model_call?(name, model_call_names)

  defp llm_spend_identity?(_name, _alias_name, _revision, _model_call_names), do: false

  defp spend_status(status, _observation) when status in [:ok, "ok"], do: :ok

  defp spend_status(status, observation)
       when status in [:error, "error"] and observation in [:not_expected, "not_expected"],
       do: :not_dispatched

  defp spend_status(status, _observation) when status in [:error, "error"], do: :error
  defp spend_status(_status, _observation), do: nil

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
        Result.limit_error(
          state,
          event_sink,
          :protocol_errors,
          environment,
          mission_name,
          RunState.protocol_errors_details(state)
        )
    end
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
      Result.limit_event_data(reason, environment, mission_name)
    )
  end

  defp maybe_emit_limit(_state, _event_sink, _result, _environment, _mission_name), do: :ok

  defp capability_argument_limit(state), do: Result.state_limits(state).capability_argument_bytes
end
