defmodule PtcRunner.LLM.PreparedModel do
  @moduledoc """
  Immutable result of preparing a configured LLM selector.

  The value seals the adapter, original selector, adapter-owned request target,
  catalog status, requested requirements, and adapter attestation. Hosts pass it
  to `PtcRunner.LLM.callback/2`. `PtcRunner.LLM.prepare/2` is the sole supported
  constructor; copied or mutated structs fail `valid?/1`.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.LLM.Requirements

  @statuses [:cataloged, :uncataloged, :unavailable]
  @enforce_keys [
    :adapter,
    :selector,
    :target,
    :catalog_status,
    :requirements,
    :attestation,
    :construction
  ]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type catalog_status :: :cataloged | :uncataloged | :unavailable
  @type t :: %__MODULE__{
          adapter: module(),
          selector: String.t(),
          target: term(),
          catalog_status: catalog_status(),
          requirements: Requirements.t(),
          attestation: Requirements.t(),
          construction: binary()
        }

  @doc false
  @spec new(module(), String.t(), term(), catalog_status(), Requirements.t(), Requirements.t()) ::
          {:ok, t()} | {:error, :invalid_prepared_model}
  def new(adapter, selector, target, catalog_status, requirements, attestation)
      when is_atom(adapter) and is_binary(selector) and catalog_status in @statuses do
    prepared = %__MODULE__{
      adapter: adapter,
      selector: selector,
      target: target,
      catalog_status: catalog_status,
      requirements: requirements,
      attestation: attestation,
      construction: <<>>
    }

    sealed = %{prepared | construction: Attestation.attest(__MODULE__, payload(prepared))}

    if valid?(sealed), do: {:ok, sealed}, else: {:error, :invalid_prepared_model}
  end

  def new(_adapter, _selector, _target, _catalog_status, _requirements, _attestation),
    do: {:error, :invalid_prepared_model}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = prepared) do
    Enum.sort(Map.keys(prepared)) == @field_keys and is_atom(prepared.adapter) and
      is_binary(prepared.selector) and byte_size(prepared.selector) in 1..256 and
      String.valid?(prepared.selector) and prepared.catalog_status in @statuses and
      match?({:ok, _canonical}, Requirements.canonical(prepared.requirements)) and
      match?({:ok, _canonical}, Requirements.canonical(prepared.attestation)) and
      Requirements.equal?(prepared.requirements, prepared.attestation) and
      Attestation.valid?(__MODULE__, payload(prepared), prepared.construction)
  end

  def valid?(_prepared), do: false

  defp payload(%__MODULE__{} = prepared) do
    {
      prepared.adapter,
      prepared.selector,
      prepared.target,
      prepared.catalog_status,
      prepared.requirements,
      prepared.attestation
    }
  end
end
