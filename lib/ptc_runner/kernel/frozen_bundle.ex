defmodule PtcRunner.Kernel.FrozenBundle do
  @moduledoc "An immutable, deterministically ordered bundle compilation result."
  import Bitwise, only: [bor: 2, bxor: 2]
  @enforce_keys [:components, :component_ids, :hash, :prelude]
  defstruct [:components, :component_ids, :hash, :prelude, :attestation]

  @type t :: %__MODULE__{
          components: [map()],
          component_ids: [binary()],
          hash: binary(),
          prelude: PtcRunner.Lisp.Prelude.t(),
          attestation: binary() | nil
        }

  @spec seal(t()) :: t()
  def seal(%__MODULE__{} = bundle), do: %{bundle | attestation: attest(bundle)}

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = bundle) when is_binary(attestation),
    do: secure_compare(attestation, attest(bundle))

  def valid?(_bundle), do: false

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

  defp attest(bundle) do
    :crypto.mac(:hmac, :sha256, key(), canonical(bundle))
  end

  defp canonical(bundle) do
    :erlang.term_to_binary(
      {bundle.components, bundle.component_ids, bundle.hash, bundle.prelude},
      [:deterministic]
    )
  end

  defp key do
    storage_key = {__MODULE__, :attestation_key}

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
