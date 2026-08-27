defmodule PtcRunner.Kernel.LLMUsageTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.LLMUsage

  @maximum 9_007_199_254_740_991

  test "normalizes USD numbers and decimals to upward-rounded microunits" do
    for {cost, microunits} <- [
          {0, 0},
          {0.1, 100_000},
          {0.000001, 1},
          {0.0000001, 1},
          {"1.2345671", 1_234_568},
          {"1e-7", 1},
          {"9.007199254740991e9", @maximum}
        ] do
      assert {:ok,
              %{
                "input" => 1,
                "output" => 2,
                "total_cost" => %{"currency" => "USD", "microunits" => ^microunits}
              }} = LLMUsage.normalize(%{input: 1, output: 2, total_cost: cost})
    end
  end

  test "accepts exact canonical cost objects without rounding them again" do
    cost = %{"currency" => "USD", "microunits" => @maximum}

    assert {:ok, %{"total_cost" => ^cost}} = LLMUsage.normalize(%{total_cost: cost})

    assert {:ok, %{"total_cost" => ^cost}} =
             LLMUsage.normalize(%{total_cost: %{currency: "USD", microunits: @maximum}})
  end

  test "rejects invalid, negative, overlong, overflowing, and non-canonical costs" do
    invalid = [
      nil,
      -1,
      -0.1,
      ".1",
      "01",
      "1.",
      "+1",
      " 1",
      "1e",
      "1e100",
      String.duplicate("1", 65),
      %{"currency" => "EUR", "microunits" => 1},
      %{"currency" => "USD", "microunits" => @maximum + 1},
      %{"currency" => "USD", "microunits" => 1, "extra" => true},
      %{"currency" => "USD", microunits: 1}
    ]

    for cost <- invalid do
      assert {:error, :invalid_llm_usage} = LLMUsage.normalize(%{total_cost: cost})
    end
  end

  test "enforces exact reporting guarantees without inventing missing usage" do
    token_guarantee = %{tokens: true, cost_currency: nil}
    priced_guarantee = %{tokens: true, cost_currency: "USD"}

    assert {:ok, %{"input" => 0, "output" => 0}} =
             LLMUsage.normalize(%{input: 0, output: 0}, token_guarantee)

    assert {:error, :invalid_llm_usage} = LLMUsage.normalize(%{input: 1}, token_guarantee)
    assert {:error, :invalid_llm_usage} = LLMUsage.normalize(nil, token_guarantee)

    assert {:error, :invalid_llm_usage} =
             LLMUsage.normalize(%{input: 1, output: 2}, priced_guarantee)

    assert {:ok, %{"total_cost" => %{"currency" => "USD", "microunits" => 1}}} =
             LLMUsage.normalize(
               %{input: 1, output: 2, total_cost: "0.0000001"},
               priced_guarantee
             )
  end
end
