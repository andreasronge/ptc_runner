defmodule PtcRunner.Kernel.ResultIdentity do
  @moduledoc false

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONValue

  @hash ~r/\Asha256:[0-9a-f]{64}\z/

  @spec hash(term()) :: {:ok, binary()} | {:error, :invalid_json | :duplicate_key}
  def hash(value) do
    with {:ok, encoded} <- DeterministicJSON.encode(value) do
      {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)}
    end
  end

  @spec strict_json_hash(term()) ::
          {:ok, binary()} | {:error, :invalid_json | :duplicate_key}
  def strict_json_hash(value) do
    if JSONValue.value?(value), do: hash(value), else: {:error, :invalid_json}
  end

  @spec valid_hash?(term()) :: boolean()
  def valid_hash?(value), do: is_binary(value) and value =~ @hash
end
