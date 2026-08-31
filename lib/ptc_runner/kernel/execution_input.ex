defmodule PtcRunner.Kernel.ExecutionInput do
  @moduledoc """
  Sealed selected application input and its authority class.

  Input bytes, source names, and digests are intentionally absent. They do not
  enter application content identity. The authority class remains explicit
  because it controls later provider and publication policy. A contract
  rejection carries only `ValueContract.classify/2`'s bounded structural
  classification and a sealed authority for its exact contract behavior hash
  and selected tagged-union branch, or only the shared discriminator before a
  branch matches; the rejected input never enters the error.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.ValueContractDiagnostic

  @enforce_keys [:value, :authority]
  defstruct [:value, :authority, :attestation]
  @field_keys Enum.sort([:__struct__, :value, :authority, :attestation])

  @type authority :: :normal | :private
  @type t :: %__MODULE__{value: map(), authority: authority(), attestation: binary() | nil}

  @spec new(term(), authority(), ValueContract.t() | nil) ::
          {:ok, t()} | {:error, :invalid_input | {:input_contract_failed, map()}}
  @doc "Admits, validates, and seals one selected input value."
  def new(value, authority, contract \\ nil)

  def new(value, authority, contract) when authority in [:normal, :private] do
    with {:ok, value} <- StrictJSON.admit(value),
         true <- is_map(value) and not is_struct(value),
         :ok <- validate_contract(contract, value) do
      input = %__MODULE__{value: value, authority: authority}
      {:ok, %{input | attestation: Attestation.attest(__MODULE__, payload(input))}}
    else
      false -> {:error, :invalid_input}
      {:error, {:input_contract_failed, _classification}} = error -> error
      {:error, _reason} -> {:error, :invalid_input}
    end
  end

  def new(_value, _authority, _contract), do: {:error, :invalid_input}

  @spec valid?(term()) :: boolean()
  @doc "Checks the input's in-VM construction attestation."
  def valid?(%__MODULE__{} = input),
    do: Attestation.valid_struct?(__MODULE__, input, @field_keys, fn -> payload(input) end)

  def valid?(_input), do: false

  defp validate_contract(nil, _value), do: :ok

  defp validate_contract(%ValueContract{} = contract, value) do
    cond do
      not ValueContract.sealed?(contract) ->
        {:error, :invalid_input}

      ValueContract.valid?(contract, value) ->
        :ok

      true ->
        case ValueContractDiagnostic.classify(contract, value) do
          {:ok, classification} ->
            {:error, {:input_contract_failed, classification}}

          {:error, :invalid_contract_classification} ->
            {:error, :invalid_input}
        end
    end
  end

  defp validate_contract(_contract, _value), do: {:error, :invalid_input}

  defp payload(input), do: {input.value, input.authority}
end
