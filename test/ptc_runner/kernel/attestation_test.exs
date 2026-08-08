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
end
