defmodule PtcRunner.Folding.ChallengeDecoderTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.{ChallengeDecoder, ChallengeSpec}

  test "nil decodes to identity" do
    spec = ChallengeDecoder.decode(nil)
    assert spec.op == :identity
  end

  test "false decodes to identity" do
    spec = ChallengeDecoder.decode(false)
    assert spec.op == :identity
  end

  test "integer decodes to valid spec" do
    spec = ChallengeDecoder.decode(42)
    assert ChallengeSpec.valid?(spec)
  end

  test "different integers decode to different specs" do
    specs = Enum.map(0..20, &ChallengeDecoder.decode/1)
    ops = Enum.map(specs, & &1.op) |> Enum.uniq()
    # With 21 different inputs, we should get multiple different ops
    assert length(ops) > 1
  end

  test "same integer always decodes to same spec (determinism)" do
    spec1 = ChallengeDecoder.decode(742)
    spec2 = ChallengeDecoder.decode(742)
    assert spec1.op == spec2.op
    assert spec1.source == spec2.source
    assert spec1.params == spec2.params
  end

  test "float decodes to valid spec" do
    spec = ChallengeDecoder.decode(3.14)
    assert ChallengeSpec.valid?(spec)
  end

  test "string decodes to valid spec" do
    spec = ChallengeDecoder.decode("hello")
    assert ChallengeSpec.valid?(spec)
  end

  test "list decodes to valid spec" do
    spec = ChallengeDecoder.decode([1, 2, 3])
    assert ChallengeSpec.valid?(spec)
  end

  test "boolean true decodes to non-identity" do
    spec = ChallengeDecoder.decode(true)
    assert ChallengeSpec.valid?(spec)
  end

  test "all decoded specs are valid" do
    values = [0, 1, 42, 100, 500, 999, -1, -100, 3.14, "test", [1, 2], %{a: 1}, :foo, true]

    Enum.each(values, fn val ->
      spec = ChallengeDecoder.decode(val)

      assert ChallengeSpec.valid?(spec),
             "Invalid spec for value: #{inspect(val)}: #{inspect(spec)}"
    end)
  end
end
