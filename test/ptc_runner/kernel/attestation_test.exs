defmodule PtcRunner.Kernel.AttestationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Attestation

  test "attestations are bound to their owner and exact payload" do
    payload = {:sealed, %{value: 1}}
    attestation = Attestation.attest(__MODULE__, payload)

    assert Attestation.valid?(__MODULE__, payload, attestation)
    refute Attestation.valid?(__MODULE__.Other, payload, attestation)
    refute Attestation.valid?(__MODULE__, {:sealed, %{value: 2}}, attestation)
  end

  test "invalid and unequal-length attestations fail closed" do
    payload = {:sealed, 1}
    attestation = Attestation.attest(__MODULE__, payload)

    refute Attestation.valid?(__MODULE__, payload, nil)
    refute Attestation.valid?(__MODULE__, payload, <<0>>)
    refute Attestation.valid?(__MODULE__, payload, :binary.copy(<<0>>, byte_size(attestation)))
  end

  test "a validation cache retains exact-payload checks and stays process scoped" do
    payload = {:sealed, %{value: 1}}
    attestation = Attestation.attest(__MODULE__, payload)

    assert :uncached ==
             Attestation.with_validation_cache(fn ->
               assert Attestation.valid?(__MODULE__, payload, attestation)

               assert Attestation.valid?(
                        __MODULE__,
                        :erlang.binary_to_term(:erlang.term_to_binary(payload)),
                        attestation
                      )

               refute Attestation.valid?(__MODULE__, {:sealed, %{value: 2}}, attestation)

               assert Attestation.valid_value?(__MODULE__, payload, attestation, fn -> true end)

               assert Attestation.valid_value?(__MODULE__, payload, attestation, fn ->
                        flunk("an exact cached value must not be revalidated")
                      end)

               refute Attestation.valid_value?(
                        __MODULE__,
                        {:sealed, %{value: 2}},
                        attestation,
                        fn -> true end
                      )

               task = Task.async(fn -> Attestation.validation_cache_enabled?() end)
               refute Task.await(task)
               :uncached
             end)

    refute Attestation.validation_cache_enabled?()
  end

  test "an explicitly enabled cache lasts for the one-shot owner process" do
    refute Attestation.validation_cache_enabled?()
    assert :ok = Attestation.enable_validation_cache()
    assert Attestation.validation_cache_enabled?()
  end
end
