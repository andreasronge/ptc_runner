lab = Path.expand("../../../scripts/labs/jev-decision/support/lab.exs", __DIR__)
Code.require_file(lab)

defmodule PtcRunner.Kernel.JevDecisionLabTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Examples.JevDecisionLab

  test "the decision prelude normalizes a batched Jev request and response" do
    test_pid = self()

    requester = fn body ->
      send(test_pid, {:request, body})

      {:ok,
       %{
         status: 200,
         body: %{
           "model" => "typesafe/jev-1.13-20260917",
           "answers" => %{
             "department" => %{
               "type" => "choice",
               "choice" => "billing",
               "probabilities" => %{"billing" => 0.9, "sales" => 0.01, "support" => 0.09},
               "confidence" => 0.81
             },
             "severity" => %{
               "type" => "score",
               "score" => 1.2,
               "legend" => %{"0" => "low", "1" => "medium", "2" => "high", "3" => "critical"},
               "probabilities" => %{"0" => 0.1, "1" => 0.6, "2" => 0.2, "3" => 0.1},
               "confidence" => 0.6
             },
             "urgent" => %{"type" => "noul", "noul" => 0.93}
           },
           "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "cost" => 0.0042}
         }
       }}
    end

    assert {:ok, result} = JevDecisionLab.run(requester: requester)
    assert result.value["model"] == "typesafe/jev-1.13-20260917"
    assert result.value["answers"]["department"]["choice"] == "billing"
    assert result.value["answers"]["severity"]["score"] == 1.2

    assert result.value["answers"]["urgent"] == %{
             "type" => "boolean",
             "probability" => 0.93
           }

    assert result.value["usage"] == %{
             "input_tokens" => 100,
             "output_tokens" => 20,
             "cost" => 0.0042
           }

    assert_receive {:request, request}
    assert request["model"] == "typesafe/jev-1.13"
    assert request["questions"]["urgent"]["type"] == "noul"
    assert request["questions"]["department"]["type"] == "choice"
    assert request["questions"]["severity"]["type"] == "score"
  end
end
