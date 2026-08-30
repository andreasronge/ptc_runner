defmodule PtcRunner.Kernel.InspectionValueIdentity do
  @moduledoc false

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONValue

  @domain "ptc.inspection-value.v1\0"
  @encoding "ptc-deterministic-json-v1"
  @hash ~r/\Asha256:[0-9a-f]{64}\z/

  @doc """
  Identifies a value by the digest of its deterministic JSON encoding.

  The value is first normalized the way a retained record would have been, so a
  capability result carrying atom keys and an MCP body decoded from the wire
  identify the same JSON document. Colliding keys and values outside the JSON
  model are rejected rather than hashed.
  """
  @spec identity(term()) :: {:ok, map()} | {:error, :invalid_json | :duplicate_key}
  def identity(value) do
    with {:ok, normalized} <- normalize(value),
         {:ok, encoded} <- DeterministicJSON.encode(normalized) do
      digest = :crypto.hash(:sha256, [@domain, <<byte_size(encoded)::unsigned-big-64>>, encoded])

      {:ok,
       %{
         "encoding" => @encoding,
         "sha256" => "sha256:" <> Base.encode16(digest, case: :lower),
         "encoded_bytes" => byte_size(encoded)
       }}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%{"encoding" => @encoding, "sha256" => hash, "encoded_bytes" => bytes} = value) do
    map_size(value) == 3 and is_binary(hash) and hash =~ @hash and is_integer(bytes) and
      bytes >= 0
  end

  def valid?(_value), do: false

  defp normalize(value) do
    case JSONValue.normalize(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_json}
    end
  end
end
