defmodule PtcRunner.Kernel.InspectionValueIdentity do
  @moduledoc false

  alias PtcRunner.Kernel.DeterministicJSON

  @domain "ptc.inspection-value.v1\0"
  @encoding "ptc-deterministic-json-v1"
  @hash ~r/\Asha256:[0-9a-f]{64}\z/

  @spec identity(term()) :: {:ok, map()} | {:error, :invalid_json | :duplicate_key}
  def identity(value) do
    with {:ok, encoded} <- DeterministicJSON.encode(value) do
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
end
