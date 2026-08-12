defmodule PtcRunner.Kernel.ProviderSnapshot do
  @moduledoc """
  Builds the closed selector-safe public identity for an acquired provider.

  The declaration projection is operator-authored safe behavior identity. The
  acquisition projection contains only bounded facts captured from the active
  provider. Unattested selectors, endpoints, commands, paths, credentials,
  OAuth authority, and identifiers derived from secret-bearing values are never
  admitted. An adapter may explicitly attest its exact model target as public.
  Audited executable and launcher content digests may be included as non-secret
  build identity without exposing their paths.

  `llm_identity/1` tolerantly extracts model attribution from a complete current
  LLM snapshot. It verifies the closed shape and both identity hashes; malformed
  or legacy snapshots simply provide no attribution and remain loadable by the
  canonical trace boundary.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ProviderDescriptor

  @llm_snapshot_keys ~w(acquisition acquisition_identity_hash declaration provider snapshot_hash)
  @llm_declaration_keys ~w(accepts_data authorization_mode config data_class installation_revision name source)
  @llm_acquisition_keys ~w(resolved_model source)
  @llm_config_keys ~w(default max_request_bytes max_response_bytes)
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @hash ~r/\A[0-9a-f]{64}\z/

  @spec build(ProviderDescriptor.t(), binary(), map(), map(), binary() | nil) ::
          {:ok, map()} | {:error, :invalid_provider_snapshot}
  def build(descriptor, name, config, acquisition, content_snapshot_hash \\ nil)

  def build(
        %ProviderDescriptor{} = descriptor,
        name,
        config,
        acquisition,
        content_snapshot_hash
      )
      when is_binary(name) and is_map(config) and is_map(acquisition) and
             (is_nil(content_snapshot_hash) or is_binary(content_snapshot_hash)) do
    declaration = ProviderDescriptor.public_projection(descriptor, name, config)

    with true <- ProviderDescriptor.valid?(descriptor),
         true <- json_map?(acquisition),
         true <- valid_content_hash?(content_snapshot_hash),
         acquisition <- maybe_put_content_hash(acquisition, content_snapshot_hash),
         {:ok, acquisition_bytes} <- DeterministicJSON.encode(acquisition),
         acquisition_hash = sha256(acquisition_bytes),
         identity = %{
           "declaration" => declaration,
           "acquisition" => acquisition,
           "acquisition_identity_hash" => acquisition_hash
         },
         identity <- maybe_put_content_hash(identity, content_snapshot_hash),
         {:ok, identity_bytes} <- DeterministicJSON.encode(identity) do
      snapshot =
        identity
        |> Map.put("provider", name)
        |> Map.put("snapshot_hash", sha256(identity_bytes))

      {:ok, snapshot}
    else
      _invalid -> {:error, :invalid_provider_snapshot}
    end
  end

  def build(_descriptor, _name, _config, _acquisition, _content_snapshot_hash),
    do: {:error, :invalid_provider_snapshot}

  @doc """
  Extracts `{alias, installation revision, resolved model}` from one valid
  current LLM provider snapshot.

  Hash verification detects inconsistent or edited trace data; the hashes are
  not signatures. Invalid, private, and legacy snapshots return `:error`.
  """
  @spec llm_identity(term()) ::
          {:ok, %{alias: binary(), installation_revision: binary(), resolved_model: binary()}}
          | :error
  def llm_identity(snapshot) when is_map(snapshot) do
    with true <- exact_keys?(snapshot, @llm_snapshot_keys),
         %{} = declaration <- snapshot["declaration"],
         %{} = acquisition <- snapshot["acquisition"],
         true <- exact_keys?(declaration, @llm_declaration_keys),
         true <- exact_keys?(acquisition, @llm_acquisition_keys),
         name when is_binary(name) <- declaration["name"],
         true <- snapshot["provider"] == name and valid_name?(name),
         revision when is_binary(revision) <- declaration["installation_revision"],
         true <- valid_name?(revision),
         true <- valid_llm_declaration?(declaration),
         model when is_binary(model) <- acquisition["resolved_model"],
         true <- valid_model?(model),
         true <- acquisition["source"] == "llm",
         true <- valid_hash?(snapshot["acquisition_identity_hash"]),
         true <- valid_hash?(snapshot["snapshot_hash"]),
         {:ok, acquisition_bytes} <- DeterministicJSON.encode(acquisition),
         true <- sha256(acquisition_bytes) == snapshot["acquisition_identity_hash"],
         identity = Map.take(snapshot, ~w(acquisition acquisition_identity_hash declaration)),
         {:ok, identity_bytes} <- DeterministicJSON.encode(identity),
         true <- sha256(identity_bytes) == snapshot["snapshot_hash"] do
      {:ok,
       %{
         alias: :binary.copy(name),
         installation_revision: :binary.copy(revision),
         resolved_model: :binary.copy(model)
       }}
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  def llm_identity(_snapshot), do: :error

  defp json_map?(value) do
    case DeterministicJSON.encode(value) do
      {:ok, _encoded} -> true
      {:error, _reason} -> false
    end
  end

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == keys

  defp valid_llm_declaration?(declaration) do
    declaration["source"] == "llm" and
      declaration["data_class"] in ["normal", "private_inspection"] and
      declaration["authorization_mode"] == "none" and
      valid_accepts_data?(declaration["accepts_data"]) and
      valid_llm_config?(declaration["config"])
  end

  defp valid_llm_config?(config) when is_map(config) do
    exact_keys?(config, @llm_config_keys) and is_boolean(config["default"]) and
      valid_llm_ceiling?(config["max_request_bytes"]) and
      valid_llm_ceiling?(config["max_response_bytes"])
  end

  defp valid_llm_config?(_config), do: false

  defp valid_llm_ceiling?(value), do: is_integer(value) and value in 1..1_048_576

  defp valid_accepts_data?(classes) when is_list(classes) and classes != [] do
    classes == Enum.sort(Enum.uniq(classes)) and
      Enum.all?(classes, &(&1 in ["normal", "private_inspection"]))
  end

  defp valid_accepts_data?(_classes), do: false

  defp valid_name?(value),
    do: byte_size(value) in 1..128 and String.valid?(value) and value =~ @name

  defp valid_model?(value), do: byte_size(value) in 1..256 and String.valid?(value)

  defp valid_hash?(value), do: is_binary(value) and value =~ @hash

  defp valid_content_hash?(nil), do: true

  defp valid_content_hash?("sha256:" <> <<hash::binary-size(64)>>),
    do: hash =~ ~r/\A[0-9a-f]{64}\z/

  defp valid_content_hash?(_hash), do: false

  defp maybe_put_content_hash(snapshot, nil), do: snapshot

  defp maybe_put_content_hash(snapshot, content_snapshot_hash),
    do: Map.put(snapshot, "content_snapshot_hash", content_snapshot_hash)

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
