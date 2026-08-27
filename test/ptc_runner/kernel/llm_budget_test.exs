defmodule PtcRunner.Kernel.LLMBudgetTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMBudget

  @available %{
    "total_tokens" => %{
      "state" => "available",
      "limit" => 100,
      "reserved" => 20,
      "charged" => 30,
      "remaining" => 50,
      "refused" => 1
    },
    "cost" => %{
      "state" => "incomplete",
      "currency" => "USD",
      "limit_microusd" => 500,
      "reserved_microusd" => 0,
      "charged_microusd" => 200,
      "remaining_microusd" => 300,
      "refused" => 0
    }
  }

  test "accepts exact disabled and runtime projections" do
    assert {:ok, %{"total_tokens" => nil, "cost" => nil}} =
             LLMBudget.validate_projection(%{"total_tokens" => nil, "cost" => nil})

    assert {:ok, @available} = LLMBudget.validate_projection(@available)
  end

  test "terminal projections reject outstanding reservations" do
    assert {:error, :invalid_llm_budget} = LLMBudget.validate_terminal_projection(@available)

    terminal =
      put_in(@available, ["total_tokens", "reserved"], 0)
      |> put_in(["total_tokens", "remaining"], 70)

    assert {:ok, ^terminal} = LLMBudget.validate_terminal_projection(terminal)
  end

  test "overrun clamps remaining even when charged has not exhausted the aggregate limit" do
    overrun =
      @available
      |> put_in(["total_tokens", "state"], "overrun")
      |> put_in(["total_tokens", "reserved"], 0)
      |> put_in(["total_tokens", "charged"], 60)
      |> put_in(["total_tokens", "remaining"], 0)

    assert {:ok, ^overrun} = LLMBudget.validate_terminal_projection(overrun)
  end

  test "rejects extra fields, inconsistent arithmetic, bad states, and unsafe integers" do
    invalid = [
      Map.put(@available, "extra", nil),
      put_in(@available, ["total_tokens", "remaining"], 51),
      put_in(@available, ["total_tokens", "state"], "unknown"),
      put_in(@available, ["total_tokens", "charged"], -1),
      put_in(@available, ["cost", "currency"], "EUR"),
      put_in(@available, ["cost", "limit_microusd"], 9_007_199_254_740_992)
    ]

    for projection <- invalid do
      assert {:error, :invalid_llm_budget} = LLMBudget.validate_projection(projection)
    end
  end

  test "ledger-owner loss conservatively exhausts enabled terminal budgets" do
    {:ok, limits} = Limits.new(llm_total_tokens: 100, llm_cost_microusd: 500)
    projection = LLMBudget.unavailable_terminal_projection(limits)

    assert projection["total_tokens"] == %{
             "state" => "incomplete",
             "limit" => 100,
             "reserved" => 0,
             "charged" => 100,
             "remaining" => 0,
             "refused" => 0
           }

    assert projection["cost"] == %{
             "state" => "incomplete",
             "currency" => "USD",
             "limit_microusd" => 500,
             "reserved_microusd" => 0,
             "charged_microusd" => 500,
             "remaining_microusd" => 0,
             "refused" => 0
           }

    assert {:ok, ^projection} = LLMBudget.validate_terminal_projection(projection)
  end

  test "preflight projection preserves untouched enabled budgets" do
    {:ok, limits} = Limits.new(llm_total_tokens: 100, llm_cost_microusd: 500)
    projection = LLMBudget.initial_terminal_projection(limits)

    assert projection["total_tokens"] == %{
             "state" => "available",
             "limit" => 100,
             "reserved" => 0,
             "charged" => 0,
             "remaining" => 100,
             "refused" => 0
           }

    assert projection["cost"] == %{
             "state" => "available",
             "currency" => "USD",
             "limit_microusd" => 500,
             "reserved_microusd" => 0,
             "charged_microusd" => 0,
             "remaining_microusd" => 500,
             "refused" => 0
           }

    assert {:ok, ^projection} = LLMBudget.validate_terminal_projection(projection)
  end
end
