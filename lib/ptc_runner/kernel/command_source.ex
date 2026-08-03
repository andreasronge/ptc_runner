defmodule PtcRunner.Kernel.CommandSource do
  @moduledoc """
  Closed, path-free provenance for command diagnostics.

  Names are fixed document roles or portable logical application names. A
  filesystem path, provider alias, endpoint, or caller-selected private input
  name is never a command source. Internal byte bounds and optional contract
  authority are attested so callers cannot widen a span or substitute a path
  from another classifying contract by mutating the struct.
  """

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandContractAuthority

  @kinds [
    :host,
    :application,
    :component,
    :input_contract,
    :result_contract,
    :external_input,
    :component_override,
    :runtime
  ]

  @enforce_keys [:kind, :name]
  defstruct [:kind, :name, :byte_size, :contract_authority, :attestation]

  @field_keys Enum.sort([
                :__struct__,
                :kind,
                :name,
                :byte_size,
                :contract_authority,
                :attestation
              ])

  @type kind ::
          :host
          | :application
          | :component
          | :input_contract
          | :result_contract
          | :external_input
          | :component_override
          | :runtime

  @type t :: %__MODULE__{
          kind: kind(),
          name: binary(),
          byte_size: non_neg_integer() | nil,
          contract_authority: CommandContractAuthority.t() | nil,
          attestation: binary()
        }

  @spec new(kind(), binary()) :: {:ok, t()} | {:error, :invalid_command_source}
  def new(kind, name) when kind in @kinds and is_binary(name) do
    if valid_name?(kind, name) do
      source = %__MODULE__{kind: kind, name: name}
      {:ok, attest(source)}
    else
      {:error, :invalid_command_source}
    end
  end

  def new(_kind, _name), do: {:error, :invalid_command_source}

  @spec with_bytes(kind(), binary(), binary()) :: t()
  @doc "Constructs provenance with the exact trusted source-byte bound used by spans."
  def with_bytes(kind, name, bytes) when is_binary(bytes) do
    {:ok, source} = new(kind, name)
    source |> Map.put(:byte_size, byte_size(bytes)) |> attest()
  end

  @spec with_contract(t(), CommandContractAuthority.t()) ::
          {:ok, t()} | {:error, :invalid_command_source}
  @doc false
  def with_contract(
        %__MODULE__{kind: kind} = source,
        %CommandContractAuthority{} = authority
      )
      when kind in [:application, :external_input, :input_contract, :result_contract] do
    if valid?(source) and CommandContractAuthority.valid?(authority) do
      {:ok, source |> Map.put(:contract_authority, authority) |> attest()}
    else
      {:error, :invalid_command_source}
    end
  end

  def with_contract(_source, _authority), do: {:error, :invalid_command_source}

  @spec valid?(term()) :: boolean()
  def valid?(
        %__MODULE__{
          kind: kind,
          name: name,
          byte_size: byte_size,
          contract_authority: contract_authority,
          attestation: attestation
        } = source
      ) do
    Enum.sort(Map.keys(source)) == @field_keys and
      valid_name?(kind, name) and valid_byte_size?(byte_size) and
      valid_contract_authority?(kind, contract_authority) and
      Attestation.valid?(__MODULE__, payload(source), attestation)
  end

  def valid?(_source), do: false

  @spec fixed(kind()) :: t()
  def fixed(:host), do: new!(:host, "ptc-host.json")
  def fixed(:application), do: new!(:application, "ptc.json")
  def fixed(:external_input), do: new!(:external_input, "input.json")

  def fixed(:component_override),
    do: new!(:component_override, "component-override.json")

  def fixed(:runtime), do: new!(:runtime, "ptc-runtime")

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = source) do
    if not valid?(source), do: raise(ArgumentError, "invalid command source")
    %{"kind" => Atom.to_string(source.kind), "name" => source.name}
  end

  defp valid_name?(:host, name), do: name == "ptc-host.json"
  defp valid_name?(:application, name), do: name == "ptc.json"
  defp valid_name?(:external_input, name), do: name == "input.json"
  defp valid_name?(:component_override, name), do: name == "component-override.json"
  defp valid_name?(:runtime, name), do: name == "ptc-runtime"

  defp valid_name?(kind, name) when kind in [:component, :input_contract, :result_contract],
    do: ApplicationSource.valid_name?(name)

  defp valid_name?(_kind, _name), do: false

  defp valid_byte_size?(nil), do: true
  defp valid_byte_size?(byte_size), do: is_integer(byte_size) and byte_size >= 0

  defp valid_contract_authority?(
         kind,
         authority
       )
       when kind in [:application, :external_input, :input_contract, :result_contract],
       do: is_nil(authority) or CommandContractAuthority.valid?(authority)

  defp valid_contract_authority?(_kind, nil), do: true
  defp valid_contract_authority?(_kind, _authority), do: false

  defp new!(kind, name) do
    {:ok, source} = new(kind, name)
    source
  end

  defp attest(source),
    do: %{source | attestation: Attestation.attest(__MODULE__, payload(source))}

  defp payload(source),
    do: {source.kind, source.name, source.byte_size, source.contract_authority}
end
