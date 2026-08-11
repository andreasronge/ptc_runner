defmodule PtcRunner.Kernel.CapabilityInvocation do
  @moduledoc false

  alias PtcRunner.Kernel.Capability

  @enforce_keys [
    :capability,
    :arguments,
    :route_key,
    :event_attributes,
    :error_attributes,
    :usage_projection
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          capability: Capability.t(),
          arguments: map(),
          route_key: binary() | nil,
          event_attributes: map(),
          error_attributes: map(),
          usage_projection: nil | :llm_tokens
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
      usage_projection: nil
    }
  end
end
