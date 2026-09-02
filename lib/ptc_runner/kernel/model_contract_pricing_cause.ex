defmodule PtcRunner.Kernel.ModelContractPricingCause do
  @moduledoc false

  alias PtcRunner.Kernel.Attestation

  @enforce_keys [:public_model, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type t :: %__MODULE__{public_model: binary() | nil, attestation: binary()}

  @spec new(module(), binary()) :: t()
  def new(adapter, model) when is_atom(adapter) and is_binary(model) do
    public_model = PtcRunner.LLM.attested_public_model(adapter, model)

    %__MODULE__{
      public_model: public_model,
      attestation: Attestation.attest(__MODULE__, public_model)
    }
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{public_model: public_model} = cause)
      when is_binary(public_model) or is_nil(public_model) do
    Attestation.valid_struct?(__MODULE__, cause, @field_keys, fn -> public_model end)
  end

  def valid?(_cause), do: false
end
