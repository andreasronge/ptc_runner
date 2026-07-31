defmodule PtcRunner.Kernel.Attestation do
  @moduledoc """
  Internal in-VM construction attestation for sealed Kernel values.

  This detects accidental or caller-authored struct mutation across trusted
  construction boundaries. It is not a security boundary against trusted code
  running in the same VM.
  """

  import Bitwise, only: [bor: 2, bxor: 2]

  @spec attest(module(), term()) :: binary()
  def attest(owner, payload) when is_atom(owner) do
    :crypto.mac(:hmac, :sha256, key(owner), :erlang.term_to_binary(payload, [:deterministic]))
  end

  @spec valid?(module(), term(), term()) :: boolean()
  def valid?(owner, payload, attestation) when is_atom(owner) and is_binary(attestation),
    do: secure_compare(attestation, attest(owner, payload))

  def valid?(_owner, _payload, _attestation), do: false

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, difference ->
      bor(difference, bxor(left_byte, right_byte))
    end)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false

  defp key(owner) do
    storage_key = {__MODULE__, owner}

    case :persistent_term.get(storage_key, :missing) do
      :missing ->
        :global.trans({storage_key, self()}, fn ->
          case :persistent_term.get(storage_key, :missing) do
            :missing ->
              secret = :crypto.strong_rand_bytes(32)
              :persistent_term.put(storage_key, secret)
              secret

            secret ->
              secret
          end
        end)

      secret ->
        secret
    end
  end
end
