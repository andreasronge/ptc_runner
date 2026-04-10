defmodule PtcRunner.Folding.ChallengeSpecTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.ChallengeSpec

  test "valid filter spec" do
    spec = %ChallengeSpec{
      op: :filter,
      source: :products,
      params: %{field: :price, cmp: :>, value: 500}
    }

    assert ChallengeSpec.valid?(spec)
  end

  test "valid truncate spec" do
    spec = %ChallengeSpec{op: :truncate, source: :employees, params: %{count: 5}}
    assert ChallengeSpec.valid?(spec)
  end

  test "valid inject_nulls spec" do
    spec = %ChallengeSpec{
      op: :inject_nulls,
      source: :orders,
      params: %{field: :status, fraction: 0.3}
    }

    assert ChallengeSpec.valid?(spec)
  end

  test "valid swap_field spec" do
    spec = %ChallengeSpec{op: :swap_field, source: :products, params: %{from: :price, to: :stock}}
    assert ChallengeSpec.valid?(spec)
  end

  test "valid scale_values spec" do
    spec = %ChallengeSpec{
      op: :scale_values,
      source: :expenses,
      params: %{field: :amount, factor: 2.0}
    }

    assert ChallengeSpec.valid?(spec)
  end

  test "valid identity spec" do
    spec = %ChallengeSpec{op: :identity, source: :products, params: %{}}
    assert ChallengeSpec.valid?(spec)
  end

  test "invalid: swap same field" do
    spec = %ChallengeSpec{op: :swap_field, source: :products, params: %{from: :price, to: :price}}
    refute ChallengeSpec.valid?(spec)
  end

  test "invalid: truncate count 0" do
    spec = %ChallengeSpec{op: :truncate, source: :products, params: %{count: 0}}
    refute ChallengeSpec.valid?(spec)
  end

  test "invalid: inject_nulls fraction too high" do
    spec = %ChallengeSpec{
      op: :inject_nulls,
      source: :products,
      params: %{field: :price, fraction: 0.9}
    }

    refute ChallengeSpec.valid?(spec)
  end

  test "ops returns all operations" do
    assert length(ChallengeSpec.ops()) == 6
    assert :identity in ChallengeSpec.ops()
    assert :filter in ChallengeSpec.ops()
  end

  test "sources returns all data sources" do
    assert :products in ChallengeSpec.sources()
    assert :employees in ChallengeSpec.sources()
  end
end
