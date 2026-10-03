defmodule PtcRunner.Kernel.Dispatcher.Result do
  @moduledoc "Internal bounded output admission and uniform failure envelopes."

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityExceptionDiagnostic
  alias PtcRunner.Kernel.Dispatcher.LlmResult
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp.RetainedSize

  def llm_request_timeout do
    %{status: :error, kind: :timeout, reason: :llm_request_timeout, retryable?: true}
  end

  defp provider_error_result(
         environment,
         invocation,
         %ProviderError{} = error,
         completed_at_ms
       ) do
    if error.kind == :timeout and LlmResult.llm_deadline_wins?(invocation, completed_at_ms) do
      post_invocation_failure(
        llm_request_timeout(),
        environment,
        invocation.capability,
        error.dispatch_provenance
      )
    else
      %{
        status: :error,
        kind: :provider_error,
        reason: error.kind,
        details: error.details,
        retryable?: error.retryable?
      }
      |> maybe_put_mutation_state(error.mutation_state)
      |> post_invocation_failure(environment, invocation.capability, error.dispatch_provenance)
    end
  end

  def normalize_result(
        _state,
        environment,
        invocation,
        _validation,
        {:provider_completed, completed_at_ms, {:error, %ProviderError{} = error}}
      ) do
    capability = invocation.capability

    if ProviderError.valid?(error) do
      provider_error_result(environment, invocation, error, completed_at_ms)
    else
      invalid_provider_result(environment, capability)
    end
  end

  def normalize_result(
        state,
        environment,
        invocation,
        validation,
        {:provider_completed, _completed_at_ms, result}
      ),
      do: normalize_result(state, environment, invocation, validation, result)

  def normalize_result(_state, _environment, _invocation, _validation, {:ok, value}) do
    %{status: :ok, value: value}
  end

  def normalize_result(_state, environment, invocation, _validation, {:raised, reason}) do
    post_invocation_failure(
      %{status: :error, kind: :provider_error, reason: reason, retryable?: false},
      environment,
      invocation.capability
    )
  end

  def normalize_result(
        state,
        environment,
        invocation,
        validation,
        {:raised, :exception, {:diagnostic_worker, pid, exception_class}}
      ) do
    {:with_exception_diagnostic,
     normalize_result(state, environment, invocation, validation, {:raised, :exception}),
     CapabilityExceptionDiagnostic.await(pid, exception_class)}
  end

  def normalize_result(
        state,
        environment,
        invocation,
        validation,
        {:raised, :exception, {:diagnostic_unavailable, exception_class}}
      ) do
    {:with_exception_diagnostic,
     normalize_result(state, environment, invocation, validation, {:raised, :exception}),
     CapabilityExceptionDiagnostic.unavailable(exception_class)}
  end

  def normalize_result(_state, environment, invocation, _validation, _result),
    do: invalid_provider_result(environment, invocation.capability)

  defp admit_output(state, environment, invocation, validation, value, stages) do
    capability = invocation.capability
    cap = capability_result_limit(state)
    bytes = RetainedSize.bytes_with_cap(value, cap)

    if json_value?(value) and is_integer(bytes) and bytes <= cap do
      case validate_output_stages(invocation, validation, value, stages) do
        :ok ->
          %{status: :ok, value: RetainedSize.detach_binaries(value)}

        {:error, reason} ->
          output_admission_error(state, environment, invocation, validation, reason)
      end
    else
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
    end
  end

  defp validate_output_stages(invocation, validation, value, stages) do
    Enum.reduce_while(stages, :ok, fn stage, :ok ->
      case validate_output_stage(invocation, validation, value, stage) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_output_stage(invocation, validation, value, :request) do
    case LlmResult.request_schema_value(invocation, value) do
      {:ok, candidate} ->
        validate_compiled_output(
          invocation.request_validator,
          invocation.request_schema,
          candidate,
          invocation,
          validation
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_output_stage(invocation, validation, value, :static) do
    capability = invocation.capability

    validate_compiled_output(
      capability.output_validator,
      capability.output_schema,
      value,
      invocation,
      validation
    )
  end

  defp validate_compiled_output(nil, _schema, _value, _invocation, _validation), do: :ok

  defp validate_compiled_output(validator, schema, value, invocation, validation)
       when is_map(schema) and not is_struct(schema) do
    timeout_ms = LlmResult.remaining_output_validation_ms(invocation, validation)

    if timeout_ms <= 0 do
      {:error, LlmResult.output_clock_failure(invocation, validation)}
    else
      case JSONSchema.validate(validator, schema, value, timeout_ms, validation.heap_words) do
        :ok -> :ok
        {:invalid, _violations} -> {:error, :output_schema_mismatch}
        {:unavailable, _cause} -> {:error, LlmResult.output_clock_failure(invocation, validation)}
      end
    end
  end

  def record_llm_timeout_evidence(state) do
    _ =
      RunState.record_llm_provider_failure(
        state,
        ProviderError.new(:timeout, "LLM request deadline elapsed", retryable?: true)
      )

    :ok
  end

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

  def post_invocation_failure(result, environment, capability, provenance \\ nil)

  def post_invocation_failure(
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

  def post_invocation_failure(result, _environment, _capability, _provenance) do
    if Map.get(result, :mutation_state) == :indeterminate,
      do: Map.put(result, :retryable?, false),
      else: result
  end

  defp maybe_put_mutation_state(result, :indeterminate),
    do: Map.put(result, :mutation_state, :indeterminate)

  defp maybe_put_mutation_state(result, nil), do: result

  def terminal_provider_failure?({:error, %ProviderError{} = error}) do
    ProviderError.valid?(error) and
      (error.kind == :denied or
         (error.kind == :invalid_result and
            error.details in ["mcp_capability_negotiation_error", "mcp_protocol_error"]))
  end

  def terminal_provider_failure?(_result), do: false

  def mark_terminal_host_failure(state, :mission, evaluation_lease)
      when is_reference(evaluation_lease),
      do: RunState.mark_evaluation_terminal_host_failure(state, evaluation_lease)

  def mark_terminal_host_failure(_state, _environment, _evaluation_lease), do: :ok

  def admit_success_output(
        %{status: :ok, value: value},
        state,
        environment,
        invocation,
        validation
      ) do
    case LlmResult.normalize_structured_output(invocation, value, validation) do
      {:ok, value} ->
        admit_output(state, environment, invocation, validation, value, [:request, :static])

      {:error, reason} ->
        output_admission_error(state, environment, invocation, validation, reason)
    end
  end

  def admit_success_output(result, _state, _environment, _invocation, _validation), do: result

  defp output_admission_error(state, environment, invocation, validation, reason) do
    case reason do
      :output_schema_mismatch ->
        post_invocation_failure(
          %{
            status: :error,
            kind: :invalid_result,
            reason: :output_schema_mismatch,
            retryable?: false
          },
          environment,
          invocation.capability
        )

      :output_validation_unavailable ->
        _ = mark_terminal_host_failure(state, environment, validation.evaluation_lease)

        post_invocation_failure(
          %{
            status: :error,
            kind: :capability_unavailable,
            reason: :output_validation_unavailable,
            retryable?: false
          },
          environment,
          invocation.capability
        )

      :llm_request_timeout ->
        record_llm_timeout_evidence(state)
        post_invocation_failure(llm_request_timeout(), environment, invocation.capability)
    end
  end

  def validate_size(value, cap) do
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

  def limit_error(
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

  def limit_event_data(reason, :mission, mission_name) do
    %{reason: reason, environment: :mission, mission_name: mission_name}
  end

  def limit_event_data(reason, :workflow, _mission_name),
    do: %{reason: reason, environment: :workflow}

  def limit_event_data(reason, _environment, _mission_name), do: %{reason: reason}

  def normalize_exit(:killed), do: :provider_heap_exceeded
  def normalize_exit(_reason), do: :provider_exit
  defp capability_result_limit(state), do: state_limits(state).capability_result_bytes
  def state_limits(state), do: RunState.limits(state)

  defp json_value?(value) do
    JSONValue.value?(value)
  rescue
    _exception -> false
  end

  def await_timeout_result(invocation) do
    if LlmResult.llm_deadline_wins?(invocation) do
      llm_request_timeout()
    else
      %{status: :error, kind: :timeout, reason: :provider_timeout, retryable?: true}
    end
  end
end
