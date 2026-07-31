defmodule PtcRunner.Kernel.ExecutionInput do
  @moduledoc """
  Sealed selected application input and its authority class.

  Input bytes, source names, and digests are intentionally absent. They do not
  enter application content identity. The authority class remains explicit
  because it controls later provider and publication policy.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.ValueContract

  @enforce_keys [:value, :authority]
  defstruct [:value, :authority, :attestation]

  @type authority :: :normal | :private
  @type t :: %__MODULE__{value: map(), authority: authority(), attestation: binary() | nil}

  @spec new(term(), authority(), ValueContract.t() | nil) ::
          {:ok, t()} | {:error, :invalid_input | :input_contract_failed}
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
      {:error, :input_contract_failed} = error -> error
      {:error, _reason} -> {:error, :invalid_input}
    end
  end

  def new(_value, _authority, _contract), do: {:error, :invalid_input}

  @spec valid?(term()) :: boolean()
  @doc "Checks the input's in-VM construction attestation."
  def valid?(%__MODULE__{attestation: attestation} = input),
    do: Attestation.valid?(__MODULE__, payload(input), attestation)

  def valid?(_input), do: false

  defp validate_contract(nil, _value), do: :ok

  defp validate_contract(%ValueContract{} = contract, value) do
    if ValueContract.valid?(contract, value),
      do: :ok,
      else: {:error, :input_contract_failed}
  end

  defp validate_contract(_contract, _value), do: {:error, :input_contract_failed}

  defp payload(input), do: {input.value, input.authority}
end
