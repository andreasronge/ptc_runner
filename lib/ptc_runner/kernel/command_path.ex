defmodule PtcRunner.Kernel.CommandPath do
  @moduledoc """
  Schema-authorized diagnostic path.

  Paths are minted only after every property or index has been walked through
  the host/manifest schema, the exact selected branch of one compiled value
  contract, the shared discriminator projection when no tagged-union branch
  matches, or — for a contract schema rejected before it compiles — the
  submitted document itself. The attestation prevents a caller-authored segment
  list from being substituted at the diagnostic boundary, and carries the
  authority that admitted it so a path cannot be moved to another document.
  """

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandContractAuthority
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.Manifest

  @max_codepoints 8_192
  @max_bytes 32_768

  # A member of an open map is named by its author, and a diagnostic never
  # echoes one. Eliding it rather than truncating there keeps the closed schema
  # beneath it addressable: `install` is caller-keyed, but `ceilings`,
  # `transport`, and `tools` under one installation are not.
  #
  # The placeholder is only sound where the map's own `propertyNames` proves no
  # admissible member could render as it. `install/*/tools` carries upstream
  # tool names and admits `*` itself, so it keeps truncating -- an ambiguous
  # pointer would be worse than a short one.
  @elision "*"
  @max_property_names_pattern 512

  @enforce_keys [:segments, :authority, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @type segment :: {:property, binary()} | {:index, non_neg_integer()}
  @type t :: %__MODULE__{
          segments: [segment()],
          authority:
            :host
            | :manifest
            | :component_override
            | {:value_contract_schema, binary()}
            | {:contract, CommandContractAuthority.t()},
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

  @doc """
  Locates a fault inside a value-contract schema document that failed to compile.

  A rejected contract has no compiled path schema to authorize against, so the
  submitted document is the authority: a pointer is minted only when every
  segment resolves in the document the author wrote. The pointer therefore
  always names a key or index that file actually carries.

  The document's logical name is attested with the segments. A diagnostic
  boundary requires it to equal the source it names, so a pointer minted for
  one contract file cannot be attached to a diagnostic about another.
  """
  @spec value_contract_schema(binary(), map(), [segment()]) ::
          {:ok, t()} | {:error, :invalid_command_path}
  def value_contract_schema(name, document, segments)
      when is_binary(name) and is_map(document) and not is_struct(document) and is_list(segments) do
    if ApplicationSource.valid_name?(name),
      do: attest(segments, {:value_contract_schema, name}, resolves?(segments, document)),
      else: {:error, :invalid_command_path}
  end

  def value_contract_schema(_name, _document, _segments), do: {:error, :invalid_command_path}

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

  defp authorize(segments, schema, authority) when is_list(segments),
    do: attest(segments, authority, authorized?(segments, schema))

  defp authorize(_segments, _schema, _authority), do: {:error, :invalid_command_path}

  defp attest(segments, authority, true) do
    with pointer <- render(segments),
         true <- byte_size(pointer) <= @max_bytes,
         true <- pointer |> String.to_charlist() |> length() <= @max_codepoints do
      path = %__MODULE__{segments: segments, authority: authority, attestation: <<>>}
      {:ok, %{path | attestation: Attestation.attest(__MODULE__, payload(path))}}
    else
      _invalid -> {:error, :invalid_command_path}
    end
  end

  defp attest(_segments, _authority, false), do: {:error, :invalid_command_path}

  defp valid_authority?(authority) when authority in [:host, :manifest, :component_override],
    do: true

  defp valid_authority?({:value_contract_schema, name}) when is_binary(name),
    do: ApplicationSource.valid_name?(name)

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

  defp authorized?([{:property, @elision} | rest], schema) do
    case elidable_child(schema) do
      {:ok, child} -> authorized?(rest, child)
      :error -> false
    end
  end

  defp authorized?(_segments, _schema), do: false

  @doc false
  @spec elision() :: binary()
  def elision, do: @elision

  @doc false
  @spec elidable_child(term()) :: {:ok, map()} | :error
  def elidable_child(%{
        "additionalProperties" => child,
        "propertyNames" => %{"pattern" => pattern}
      })
      when is_map(child) and is_binary(pattern) and
             byte_size(pattern) <= @max_property_names_pattern do
    case Regex.compile(pattern) do
      {:ok, regex} -> if Regex.match?(regex, @elision), do: :error, else: {:ok, child}
      {:error, _reason} -> :error
    end
  end

  def elidable_child(_schema), do: :error

  defp resolves?([], _node), do: true

  defp resolves?([{:property, name} | rest], node)
       when is_binary(name) and is_map(node) and not is_struct(node) do
    case Map.fetch(node, name) do
      {:ok, child} -> resolves?(rest, child)
      :error -> false
    end
  end

  defp resolves?([{:index, index} | rest], node)
       when is_integer(index) and index >= 0 and is_list(node) do
    case Enum.fetch(node, index) do
      {:ok, child} -> resolves?(rest, child)
      :error -> false
    end
  end

  defp resolves?(_segments, _node), do: false

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
