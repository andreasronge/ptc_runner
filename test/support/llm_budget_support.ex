defmodule PtcRunner.TestSupport.LLMBudgetSupport do
  @moduledoc false

  def settled_projection do
    %{
      "total_tokens" => %{
        "state" => "available",
        "limit" => 100,
        "reserved" => 0,
        "charged" => 18,
        "remaining" => 82,
        "refused" => 0
      },
      "cost" => %{
        "state" => "available",
        "currency" => "USD",
        "limit_microusd" => 500,
        "reserved_microusd" => 0,
        "charged_microusd" => 75,
        "remaining_microusd" => 425,
        "refused" => 0
      }
    }
  end
end
