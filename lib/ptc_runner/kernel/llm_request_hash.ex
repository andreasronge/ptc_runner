defmodule PtcRunner.Kernel.LLMRequestHash do
  @moduledoc """
  Deterministic provider-neutral request identity for replay and private evidence.

  Encoding and hashing are process-free and do not depend on replay execution.
  """

  alias PtcRunner.Kernel.DeterministicJSON

  @doc "Hashes a provider-neutral request for fixture keys and inspection correlation."
  @spec request_hash(map()) :: {:ok, binary()} | :error
  def request_hash(request) when is_map(request) do
    case DeterministicJSON.encode(request) do
      {:ok, encoded} ->
        {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)}

      _other ->
        :error
    end
  end

  def request_hash(_request), do: :error
end
