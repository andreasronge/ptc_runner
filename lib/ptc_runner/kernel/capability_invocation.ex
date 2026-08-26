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
                enclosing_deadline_ms: nil
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
          enclosing_deadline_ms: integer() | nil
        }

  @doc false
  @spec leaf(Capability.t(), map()) :: t()
  def leaf(%Capability{} = capability, arguments) when is_map(arguments) do
    %__MODULE__{
      capability: capability,
      arguments: arguments,
      route_key: nil,
      event_attributes: %{},
      error_attributes: %{},
      result_attributes: %{},
      usage_projection: nil
    }
  end

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
end
