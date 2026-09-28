defmodule PtcRunner.Kernel.OpenRouterDecisionsTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Kernel.DecisionContract

  alias PtcRunner.Kernel.OpenRouterDecisions
  @routing %{"zdr" => true, "data_collection" => "deny", "allow_fallbacks" => false}
  @request %{
    "state" => %{"number" => 2},
    "questions" => %{
      "positive" => %{"type" => "boolean", "instructions" => "Is the number positive?"}
    }
  }

  test "wire normalization and routing remain in the adapter" do
    parent = self()

    http = fn endpoint, opts ->
      send(parent, {:request, endpoint, opts})

      {:ok,
       %{
         status: 200,
         body: %{
           "model" => "served-v2",
           "answers" => %{"positive" => %{"type" => "noul", "noul" => 0.9}},
           "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "cost" => 0.001},
           "id" => "private-id"
         }
       }}
    end

    requester = OpenRouterDecisions.requester("configured", "credential", @routing, 30_000, http)
    assert {:ok, response} = requester.(@request, %{llm_request_deadline_ms: nil})

    assert response["answers"]["positive"] == %{
             "type" => "boolean",
             "probability" => 0.9,
             "confidence" => nil
           }

    refute Map.has_key?(response, "id")
    assert_receive {:request, "https://openrouter.ai/api/alpha/decisions", opts}
    assert opts[:json]["provider"] == @routing
    assert opts[:json]["questions"]["positive"]["type"] == "noul"
    assert opts[:retry] == false
  end

  @tag :e2e
  test "live Jev accepts the required privacy routing" do
    key = System.fetch_env!("OPENROUTER_API_KEY")
    requester = OpenRouterDecisions.requester("typesafe/jev-1.13", key, @routing, 30_000)

    assert {:ok, response} =
             requester.(@request, %{
               llm_request_deadline_ms: System.monotonic_time(:millisecond) + 30_000
             })

    assert DecisionContract.valid_response?(response, @request["questions"])
    assert response["model"] =~ "typesafe/jev-1.13"
    assert response["answers"]["positive"]["probability"] >= 0.9
  end
end
