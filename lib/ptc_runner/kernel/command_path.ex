defmodule PtcRunner.Kernel.CommandPath do
  @moduledoc """
  Schema-authorized diagnostic path.

  Paths are minted only after every property or index has been walked through
  the host/manifest schema or the exact selected branch of one compiled value
  contract. The attestation prevents a caller-authored segment list from being
  substituted at the diagnostic boundary.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandContractAuthority
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.Manifest

  @max_codepoints 8_192
  @max_bytes 32_768

  @enforce_keys [:segments, :authority, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type segment :: {:property, binary()} | {:index, non_neg_integer()}
  @type t :: %__MODULE__{
          segments: [segment()],
          authority:
            :host | :manifest | :component_override | {:contract, CommandContractAuthority.t()},
          attestation: binary()
        }

  @spec host([segment()]) :: {:ok, t()} | {:error, :invalid_command_path}
  def host(segments), do: authorize(segments, HostConfig.schema(), :host)

  @spec manifest([segment()]) :: {:ok, t()} | {:error, :invalid_command_path}
  def manifest(segments), do: authorize(segments, Manifest.schema(), :manifest)

  @spec component_override([segment()]) :: {:ok, t()} | {:error, :invalid_command_path}
  def component_override(segments),
    do: authorize(segments, ComponentOverride.schema(), :component_override)

  @spec contract(CommandContractAuthority.t(), [segment()]) ::
          {:ok, t()} | {:error, :invalid_command_path}
  def contract(
        %CommandContractAuthority{path_schema: path_schema} = authority,
        segments
      ) do
    if CommandContractAuthority.valid?(authority) and is_map(path_schema),
      do: authorize(segments, path_schema, {:contract, authority}),
      else: {:error, :invalid_command_path}
  end

  def contract(_contract, _segments), do: {:error, :invalid_command_path}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{authority: authority, attestation: attestation} = path),
    do:
      Enum.sort(Map.keys(path)) == @field_keys and
        valid_authority?(authority) and
        Attestation.valid?(__MODULE__, payload(path), attestation)

  def valid?(_path), do: false

  @spec to_pointer(t()) :: binary()
  def to_pointer(%__MODULE__{segments: segments} = path) do
    if not valid?(path), do: raise(ArgumentError, "invalid command path")

    Enum.map_join(segments, "", fn
      {:property, name} -> "/" <> escape_pointer(name)
      {:index, index} -> "/" <> Integer.to_string(index)
    end)
  end

  defp authorize(segments, schema, authority) when is_list(segments) do
    with true <- authorized?(segments, schema),
         pointer <- render(segments),
         true <- byte_size(pointer) <= @max_bytes,
         true <- pointer |> String.to_charlist() |> length() <= @max_codepoints do
      path = %__MODULE__{segments: segments, authority: authority, attestation: <<>>}
      {:ok, %{path | attestation: Attestation.attest(__MODULE__, payload(path))}}
    else
      _invalid -> {:error, :invalid_command_path}
    end
  end

  defp authorize(_segments, _schema, _authority), do: {:error, :invalid_command_path}

  defp valid_authority?(authority) when authority in [:host, :manifest, :component_override],
    do: true

  defp valid_authority?({:contract, %CommandContractAuthority{} = authority}),
    do: CommandContractAuthority.valid?(authority)

  defp valid_authority?(_authority), do: false

  defp authorized?([], _schema), do: true

  defp authorized?([{:property, name} | rest], %{"properties" => properties})
       when is_binary(name) and is_map(properties) do
    case Map.fetch(properties, name) do
      {:ok, child} -> authorized?(rest, child)
      :error -> false
    end
  end

  defp authorized?([{:index, index} | rest], %{"items" => items})
       when is_integer(index) and index >= 0,
       do: authorized?(rest, items)

  defp authorized?(segments, %{"oneOf" => branches}) when is_list(branches),
    do: Enum.any?(branches, &authorized?(segments, &1))

  defp authorized?(_segments, _schema), do: false

  defp render(segments) do
    Enum.map_join(segments, "", fn
      {:property, name} -> "/" <> escape_pointer(name)
      {:index, index} -> "/" <> Integer.to_string(index)
    end)
  end

  defp escape_pointer(name),
    do: name |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp payload(path), do: {path.segments, path.authority}
end
