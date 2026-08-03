defmodule PtcRunner.Kernel.ProviderSnapshot do
  @moduledoc """
  Builds the closed selector-safe public identity for an acquired provider.

  The declaration projection is operator-authored safe behavior identity. The
  acquisition projection contains only bounded facts captured from the active
  provider. Raw selectors, endpoints, commands, paths, credentials, OAuth
  authority, and identifiers derived from secret-bearing values are never
  admitted. Audited executable and launcher content digests may be included as
  non-secret build identity without exposing their paths.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.ProviderDescriptor

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

  defp json_map?(value) do
    case DeterministicJSON.encode(value) do
      {:ok, _encoded} -> true
      {:error, _reason} -> false
    end
  end

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
