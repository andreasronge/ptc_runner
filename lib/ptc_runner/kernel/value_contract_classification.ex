defmodule PtcRunner.Kernel.ValueContractClassification do
  @moduledoc """
  Internal sealed evidence for one value-contract classification.

  The public classification map deliberately omits branch indexes and schema
  material. This value carries the exact contract behavior and selected path
  schema separately so diagnostic authority can remain branch-specific without
  widening model-facing feedback.
  """

  alias PtcRunner.Kernel.Attestation

  @enforce_keys [:behavior_hash, :path_schema, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type t :: %__MODULE__{
          behavior_hash: binary(),
          path_schema: map() | nil,
          attestation: binary()
        }

  @spec valid?(term()) :: boolean()
  def valid?(
        %__MODULE__{
          behavior_hash: behavior_hash,
          path_schema: path_schema,
          attestation: attestation
        } = classification
      ) do
    Enum.sort(Map.keys(classification)) == @field_keys and
      is_binary(behavior_hash) and byte_size(behavior_hash) == 64 and
      (is_nil(path_schema) or is_map(path_schema)) and
      Attestation.valid?(__MODULE__, {behavior_hash, path_schema}, attestation)
  end

  def valid?(_classification), do: false
end
