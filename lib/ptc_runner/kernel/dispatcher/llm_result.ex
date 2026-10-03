defmodule PtcRunner.Kernel.Dispatcher.LlmResult do
  @moduledoc "Internal LLM structured-output interpretation, usage evidence and deadline calculations."

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.LLMUsage
  alias PtcRunner.Kernel.ModelCapabilities
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.LLM.OutputLimit

  def llm_deadline_wins?(
        %CapabilityInvocation{
          llm_request_deadline_ms: llm_deadline,
          enclosing_deadline_ms: enclosing_deadline
        },
        observed_at_ms
      )
      when is_integer(llm_deadline) and is_integer(enclosing_deadline),
      do:
        observed_at_ms >= llm_deadline and
          llm_deadline < enclosing_deadline

  def llm_deadline_wins?(_invocation, _observed_at_ms), do: false

  def llm_deadline_wins?(invocation),
    do: llm_deadline_wins?(invocation, System.monotonic_time(:millisecond))

  def settlement_evidence({:ok, value}) when is_map(value) and not is_struct(value) do
    case Map.fetch(value, "tokens") do
      :error ->
        case LLMUsage.decision_usage(Map.get(value, "usage")) do
          nil -> {:adapter_success, :missing}
          usage -> {:adapter_success, {:valid, usage}}
        end

      {:ok, usage} ->
        case LLMUsage.normalize(usage) do
          {:ok, canonical} -> {:adapter_success, {:valid, canonical}}
          {:error, :invalid_llm_usage} -> {:adapter_success, :invalid}
        end
    end
  end

  def settlement_evidence({:ok, _value}), do: {:adapter_success, :invalid}

  def settlement_evidence({:error, %ProviderError{dispatch_provenance: :not_dispatched} = error}) do
    if ProviderError.valid?(error),
      do: {:adapter_error, :not_dispatched},
      else: {:adapter_error, :provider_error}
  end

  def settlement_evidence(_error), do: {:adapter_error, :provider_error}

  def remaining_output_validation_ms(invocation, validation) do
    CapabilityInvocation.clamp_provider_timeout(
      invocation,
      shared_output_validation_ms(validation)
    )
  end

  defp shared_output_validation_ms(%{deadline_ms: deadline_ms}) do
    # Input validation reserves `@validation_handoff_ms` so a refusal can still
    # persist terminal host provenance. Output admission runs after dispatch,
    # so that reserve must not turn a still-open deadline into unavailability.
    # Once the shared deadline has expired, remaining time is zero and the
    # value is not admitted.
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  def output_clock_failure(invocation, validation) do
    if llm_output_deadline_wins?(invocation, validation),
      do: :llm_request_timeout,
      else: :output_validation_unavailable
  end

  defp llm_output_deadline_wins?(
         %CapabilityInvocation{llm_request_deadline_ms: llm_deadline} = invocation,
         %{deadline_ms: validation_deadline}
       )
       when is_integer(llm_deadline) and is_integer(validation_deadline),
       do: llm_deadline_wins?(invocation) and llm_deadline < validation_deadline

  defp llm_output_deadline_wins?(_invocation, _validation), do: false

  def request_schema_value(%CapabilityInvocation{request_validator: nil}, value),
    do: {:ok, value}

  def request_schema_value(
        %CapabilityInvocation{capability: %Capability{name: name}},
        value
      ) do
    if ModelCapabilities.chat?(name), do: chat_request_schema_value(value), else: {:ok, value}
  end

  def request_schema_value(_invocation, value), do: {:ok, value}

  defp chat_request_schema_value(value) do
    case Map.get(value, "structured_output") do
      object when is_map(object) and not is_struct(object) -> {:ok, object}
      _missing -> {:error, :output_schema_mismatch}
    end
  end

  def normalize_structured_output(
        %CapabilityInvocation{request_validator: validator} = invocation,
        value,
        validation
      )
      when validator != nil do
    case structured_provider_object(invocation, value, validation) do
      {:ok, object} -> promote_structured_output(object, value)
      {:error, _reason} = error -> error
    end
  end

  def normalize_structured_output(
        %CapabilityInvocation{capability: %Capability{name: name}, arguments: arguments},
        value,
        _validation
      )
      when is_map(value) do
    # Tool requests retain incomplete turns for the agent's protocol recovery.
    if ModelCapabilities.chat?(name) and not match?([_ | _], arguments["tools"]) and
         Map.has_key?(value, "content") and
         not is_binary(value["content"]) and
         not match?([_ | _], value["tool_calls"]),
       do: {:error, :output_schema_mismatch},
       else: {:ok, value}
  end

  def normalize_structured_output(_invocation, value, _validation), do: {:ok, value}

  defp structured_provider_object(invocation, value, validation) do
    case {invocation.structured_output_mode, value} do
      {:json_schema, %{"object" => object}} ->
        admitted_object(object)

      {:json_object, %{"json" => json}} ->
        decode_structured_json(json, invocation, validation)

      {nil, %{"structured_output" => object}} ->
        admitted_object(object)

      {nil, %{"object" => object}} ->
        admitted_object(object)

      {nil, %{"json" => json}} ->
        decode_structured_json(json, invocation, validation)

      _wrong_branch ->
        {:error, :output_schema_mismatch}
    end
  end

  defp admitted_object(object) when is_map(object) and not is_struct(object), do: {:ok, object}
  defp admitted_object(_value), do: {:error, :output_schema_mismatch}

  defp decode_structured_json(json, invocation, validation) when is_binary(json) do
    timeout_ms = remaining_output_validation_ms(invocation, validation)

    if timeout_ms <= 0 do
      {:error, output_clock_failure(invocation, validation)}
    else
      case StrictJSON.decode_classified(json,
             timeout_ms: timeout_ms,
             max_heap_words: validation.heap_words
           ) do
        {:ok, object} ->
          admitted_object(object)

        {:invalid, _reason} ->
          {:error, :output_schema_mismatch}

        {:unavailable, _cause} ->
          {:error, output_clock_failure(invocation, validation)}
      end
    end
  end

  defp decode_structured_json(_json, _invocation, _validation),
    do: {:error, :output_schema_mismatch}

  defp promote_structured_output(object, value) do
    envelope = %{"structured_output" => object}

    case Map.fetch(value, "tokens") do
      :error -> {:ok, envelope}
      {:ok, tokens} -> {:ok, Map.put(envelope, "tokens", tokens)}
    end
  end

  def maybe_put_llm_result_metadata(data, %{status: :ok, value: value}, :llm_tokens)
      when is_map(value) do
    data
    |> maybe_put_finish_reason(value)
    |> maybe_put_output_limit(value)
  end

  def maybe_put_llm_result_metadata(data, _result, _projection), do: data

  defp maybe_put_finish_reason(data, value) do
    case Map.get(value, "finish_reason", Map.get(value, :finish_reason)) do
      reason when reason in ["stop", "length", "tool_calls", "content_filter", "error"] ->
        Map.put(data, :finish_reason, String.to_existing_atom(reason))

      reason when reason in [:stop, :length, :tool_calls, :content_filter, :error] ->
        Map.put(data, :finish_reason, reason)

      _unknown ->
        data
    end
  end

  defp maybe_put_output_limit(data, value) do
    if Map.get(data, :finish_reason) == :length do
      case OutputLimit.normalize(Map.get(value, "output_limit", Map.get(value, :output_limit))) do
        {:ok, limit} -> Map.put(data, :output_limit, stringify_output_limit(limit))
        :error -> data
      end
    else
      data
    end
  end

  defp stringify_output_limit(limit) do
    %{
      "name" => Atom.to_string(limit.name),
      "value" => limit.value,
      "bindings" => Enum.map(limit.bindings, &Atom.to_string/1)
    }
  end
end
