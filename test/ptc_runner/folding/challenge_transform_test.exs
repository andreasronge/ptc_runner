defmodule PtcRunner.Folding.ChallengeTransformTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.{ChallengeSpec, ChallengeTransform}

  @context %{
    "products" => [
      %{"price" => 100, "stock" => 10, "status" => "active"},
      %{"price" => 600, "stock" => 5, "status" => "active"},
      %{"price" => 300, "stock" => 20, "status" => "discontinued"}
    ],
    "employees" => [
      %{"name" => "Alice", "department" => "engineering"},
      %{"name" => "Bob", "department" => "sales"}
    ]
  }

  test "identity returns context unchanged" do
    spec = %ChallengeSpec{op: :identity, source: :products, params: %{}}
    assert ChallengeTransform.apply_challenge(spec, @context) == @context
  end

  test "filter removes matching items" do
    spec = %ChallengeSpec{
      op: :filter,
      source: :products,
      params: %{field: :price, cmp: :>, value: 500}
    }

    result = ChallengeTransform.apply_challenge(spec, @context)
    # Rejects items where price > 500, keeping price=100 and price=300
    assert length(result["products"]) == 2
    assert Enum.all?(result["products"], fn p -> p["price"] <= 500 end)
    # Employees unchanged
    assert result["employees"] == @context["employees"]
  end

  test "truncate keeps first N items" do
    spec = %ChallengeSpec{op: :truncate, source: :products, params: %{count: 2}}
    result = ChallengeTransform.apply_challenge(spec, @context)
    assert length(result["products"]) == 2
    assert result["employees"] == @context["employees"]
  end

  test "inject_nulls sets field to nil deterministically" do
    spec = %ChallengeSpec{
      op: :inject_nulls,
      source: :products,
      params: %{field: :status, fraction: 0.5}
    }

    result = ChallengeTransform.apply_challenge(spec, @context)
    # With fraction 0.5, every 2nd item (index 0, 2) gets nulled
    assert Enum.at(result["products"], 0)["status"] == nil
    assert Enum.at(result["products"], 1)["status"] == "active"
    assert Enum.at(result["products"], 2)["status"] == nil
  end

  test "swap_field exchanges two field values" do
    spec = %ChallengeSpec{op: :swap_field, source: :products, params: %{from: :price, to: :stock}}
    result = ChallengeTransform.apply_challenge(spec, @context)
    first = Enum.at(result["products"], 0)
    assert first["price"] == 10
    assert first["stock"] == 100
  end

  test "scale_values multiplies numeric field" do
    spec = %ChallengeSpec{
      op: :scale_values,
      source: :products,
      params: %{field: :price, factor: 2.0}
    }

    result = ChallengeTransform.apply_challenge(spec, @context)
    assert Enum.at(result["products"], 0)["price"] == 200
    assert Enum.at(result["products"], 1)["price"] == 1200
  end

  test "scale_values skips non-numeric fields" do
    spec = %ChallengeSpec{
      op: :scale_values,
      source: :products,
      params: %{field: :status, factor: 2.0}
    }

    result = ChallengeTransform.apply_challenge(spec, @context)
    # status is a string, should be unchanged
    assert Enum.at(result["products"], 0)["status"] == "active"
  end

  test "only target source is modified" do
    spec = %ChallengeSpec{op: :truncate, source: :products, params: %{count: 1}}
    result = ChallengeTransform.apply_challenge(spec, @context)
    assert length(result["products"]) == 1
    assert length(result["employees"]) == 2
  end
end
