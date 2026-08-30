defmodule PtcRunner.Kernel.CapabilityInvocation do
  @moduledoc false

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.JSONSchema

  @enforce_keys [
    :capability,
    :arguments,
    :route_key,
    :event_attributes,
    :error_attributes,
    :result_attributes,
    :usage_projection
  ]
  defstruct @enforce_keys ++
              [
                max_calls: nil,
                request_schema: nil,
                request_validator: nil,
                structured_output_mode: nil,
                request_timeout_ms: nil,
                llm_request_deadline_ms: nil,
                enclosing_deadline_ms: nil,
                llm_source: nil,
                llm_output_tokens: nil,
                llm_reservation_tariff: nil,
                reservation_bound: nil,
                reservation: nil
              ]

  @type t :: %__MODULE__{
          capability: Capability.t(),
          arguments: map(),
          route_key: binary() | nil,
          max_calls: pos_integer() | nil,
          event_attributes: map(),
          error_attributes: map(),
          result_attributes: map(),
          usage_projection: nil | :llm_tokens,
          request_schema: map() | nil,
          request_validator: JSONSchema.compiled() | nil,
          structured_output_mode: :json_schema | :json_object | :unsupported | nil,
          request_timeout_ms: pos_integer() | nil,
          llm_request_deadline_ms: integer() | nil,
          enclosing_deadline_ms: integer() | nil,
          llm_source: binary() | nil,
          llm_output_tokens: pos_integer() | nil,
          llm_reservation_tariff: map() | nil,
          reservation_bound: function() | nil,
          reservation: map() | nil
        }

  @doc false
  @spec leaf(Capability.t(), map()) :: t()
  def leaf(%Capability{} = capability, arguments) when is_map(arguments) do
    invocation = %__MODULE__{
      capability: capability,
      arguments: arguments,
      route_key: nil,
      event_attributes: %{},
      error_attributes: %{},
      result_attributes: %{},
      usage_projection: nil
    }

    put_llm_reservation(invocation, capability.llm_reservation)
  end

  defp put_llm_reservation(
         invocation,
         %{source: "llm", output_tokens: output_tokens, tariff: tariff, bound: bound}
       ) do
    %{
      invocation
      | llm_source: "llm",
        llm_output_tokens: output_tokens,
        llm_reservation_tariff: tariff,
        reservation_bound: bound
    }
  end

  defp put_llm_reservation(invocation, %{source: "llm_replay"}),
    do: %{invocation | llm_source: "llm_replay"}

  defp put_llm_reservation(invocation, _reservation), do: invocation

  @doc false
  @spec put_request_schema(t(), map(), JSONSchema.compiled()) :: t()
  def put_request_schema(%__MODULE__{} = invocation, schema, validator)
      when is_map(schema) and not is_struct(schema) do
    %{
      invocation
      | arguments: Map.put(invocation.arguments, "schema", schema),
        request_schema: schema,
        request_validator: validator
    }
  end

  @doc false
  @spec clamp_provider_timeout(t(), non_neg_integer()) :: non_neg_integer()
  def clamp_provider_timeout(
        %__MODULE__{llm_request_deadline_ms: deadline},
        timeout_ms
      )
      when is_integer(deadline) and is_integer(timeout_ms) and timeout_ms >= 0 do
    min(timeout_ms, max(deadline - System.monotonic_time(:millisecond), 0))
  end

  def clamp_provider_timeout(%__MODULE__{llm_request_deadline_ms: nil}, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0,
      do: timeout_ms
end
