defmodule PtcRunner.Kernel.CommandContractAuthority do
  @moduledoc """
  Sealed behavior and path scope for a classified contract failure.

  The authority travels with bounded classification evidence, independently of
  any selected diagnostic path. A command source can therefore bind to the
  classifying contract before a path is admitted, preventing a path minted
  from another contract or tagged-union branch from certifying itself. Before
  a tagged-union branch matches, only its shared discriminator is in scope.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ValueContractClassification

  @enforce_keys [:behavior_hash, :path_schema, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type t :: %__MODULE__{
          behavior_hash: binary(),
          path_schema: map() | nil,
          attestation: binary()
        }

  @spec new(ValueContractClassification.t()) ::
          {:ok, t()} | {:error, :invalid_contract_classification}
  @doc false
  def new(%ValueContractClassification{} = classification) do
    if ValueContractClassification.valid?(classification),
      do: seal(classification),
      else: {:error, :invalid_contract_classification}
  end

  def new(_classification), do: {:error, :invalid_contract_classification}

  defp seal(classification) do
    authority = %__MODULE__{
      behavior_hash: classification.behavior_hash,
      path_schema: classification.path_schema,
      attestation: <<>>
    }

    {:ok, %{authority | attestation: Attestation.attest(__MODULE__, payload(authority))}}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{behavior_hash: hash, attestation: attestation} = authority),
    do:
      Enum.sort(Map.keys(authority)) == @field_keys and
        is_binary(hash) and byte_size(hash) == 64 and
        (is_nil(authority.path_schema) or is_map(authority.path_schema)) and
        Attestation.valid?(__MODULE__, payload(authority), attestation)

  def valid?(_authority), do: false

  defp payload(authority), do: {authority.behavior_hash, authority.path_schema}
end
