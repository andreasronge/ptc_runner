defmodule PtcRunner.Kernel.InstallationConfigDigest do
  @moduledoc """
  Configuration identity for one decoded host installation.

  The digest is SHA-256 over `"ptc.installation-config.v1\\0"`, the
  big-endian `u64` byte length, and a TJCS projection of the complete
  `install.<alias>` declaration after ordinary host decoding. A matching
  digest means the same normalized installation declaration was selected. It
  does not prove that a local process, remote endpoint, credential, filesystem
  path, or server still grants the same effective authority.

  The projection applies schema defaults by hashing the decoded installation
  map, omits `installation_revision` and the digest field itself, and never
  includes the alias name, resolved credential bytes, ambient environment
  values, remote or discovered server state, or machine-local resolved paths.
  Credential *binding names* and environment *variable names* remain. Unknown
  structs fail closed. Set-valued declaration fields such as `accepts_data`
  and OAuth `redirect_uris` are ordered canonically before encoding, so author
  order is not configuration drift. Ordered lists such as transport `args`
  and HTTP `auth` keep their written sequence.
  """

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.TypedCanonicalJSON

  @domain <<"ptc.installation-config.v1", 0>>
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @data_class_rank %{"normal" => 0, "private_inspection" => 1}
  @set_valued_keys ~w(
    additional_origins
    default_scopes
    grant_types
    private_network_origins
    redirect_uris
    scope_ceiling
  )

  @doc false
  @spec compute(map()) :: {:ok, binary()} | {:error, :invalid_installation_config}
  def compute(installation) when is_map(installation) and not is_struct(installation) do
    projection =
      Map.drop(installation, [:installation_revision, :installation_config_digest])

    with {:ok, payload} <- json_safe(projection),
         {:ok, encoded} <- TypedCanonicalJSON.encode(payload) do
      {:ok, "sha256:" <> TypedCanonicalJSON.sha256(@domain, encoded)}
    else
      _invalid -> {:error, :invalid_installation_config}
    end
  end

  def compute(_installation), do: {:error, :invalid_installation_config}

  @doc false
  @spec attach_all(map()) :: {:ok, map()} | {:error, :invalid_installation_config}
  def attach_all(installations) when is_map(installations) and not is_struct(installations) do
    Enum.reduce_while(installations, {:ok, %{}}, fn {name, installation}, {:ok, acc} ->
      case compute(installation) do
        {:ok, digest} ->
          {:cont,
           {:ok, Map.put(acc, name, Map.put(installation, :installation_config_digest, digest))}}

        {:error, :invalid_installation_config} = error ->
          {:halt, error}
      end
    end)
  end

  def attach_all(_installations), do: {:error, :invalid_installation_config}

  @doc false
  @spec map(map()) :: map()
  def map(installations) when is_map(installations) do
    Map.new(installations, fn {name, installation} ->
      {name, Map.fetch!(installation, :installation_config_digest)}
    end)
  end

  @doc false
  @spec selected(map(), [map()]) :: map()
  def selected(digest_map, declarations)
      when is_map(digest_map) and not is_struct(digest_map) and is_list(declarations) do
    names = MapSet.new(declarations, & &1.name)

    Map.new(for {name, digest} <- digest_map, MapSet.member?(names, name), do: {name, digest})
  end

  @doc false
  @spec valid_digest?(term()) :: boolean()
  def valid_digest?(digest) when is_binary(digest), do: digest =~ @digest
  def valid_digest?(_digest), do: false

  @doc false
  @spec valid_map?(term(), [map()] | MapSet.t()) :: boolean()
  def valid_map?(digests, declarations) when is_list(declarations) do
    valid_map?(digests, MapSet.new(declarations, & &1.name))
  end

  def valid_map?(digests, %MapSet{} = names)
      when is_map(digests) and not is_struct(digests) do
    Enum.all?(digests, fn {name, digest} ->
      is_binary(name) and MapSet.member?(names, name) and valid_digest?(digest)
    end)
  end

  def valid_map?(_digests, _names), do: false

  defp json_safe(%Authority{} = authority),
    do: json_safe(Authority.declared_projection(authority))

  defp json_safe(value) when is_atom(value) and not is_boolean(value) and value != nil,
    do: {:ok, Atom.to_string(value)}

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp json_safe(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case json_safe(value) do
        {:ok, json} -> {:cont, {:ok, [json | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp json_safe(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      with {:ok, json_key} <- json_key(key),
           {:ok, json_item} <- json_safe(item) do
        {:cont, {:ok, Map.put(acc, json_key, canonicalize_field(json_key, json_item))}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp json_safe(_value), do: {:error, :invalid_installation_config}

  defp json_key(key) when is_binary(key), do: {:ok, key}
  defp json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp json_key(_key), do: {:error, :invalid_installation_config}

  defp canonicalize_field("accepts_data", values) when is_list(values) do
    Enum.sort_by(values, &Map.get(@data_class_rank, &1, &1))
  end

  defp canonicalize_field(key, values)
       when is_list(values) and key in @set_valued_keys do
    Enum.sort(values)
  end

  defp canonicalize_field(_key, value), do: value
end
