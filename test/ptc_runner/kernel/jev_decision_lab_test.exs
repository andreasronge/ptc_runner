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

  test "Jev replaces the fuzzy classification in the first support-triage example" do
    test_pid = self()

    requester = fn body ->
      send(test_pid, {:triage_request, body})

      answers =
        Map.new(~w(T-1001 T-1002 T-1003 T-1004 T-1005 T-1006), fn ticket_id ->
          probability = if ticket_id in ~w(T-1001 T-1004), do: 0.95, else: 0.05
          {ticket_id, %{"type" => "noul", "noul" => probability}}
        end)

      {:ok,
       %{
         status: 200,
         body: %{
           "model" => "typesafe/jev-1.13-20260917",
           "answers" => answers,
           "usage" => %{"input_tokens" => 300, "output_tokens" => 30}
         }
       }}
    end

    assert {:ok, result} = JevDecisionLab.run_refund_triage(requester: requester)
    assert result.value["refund_ticket_ids"] == ["T-1001", "T-1004"]
    assert result.value["model"] == "typesafe/jev-1.13-20260917"

    assert_receive {:triage_request, request}
    assert map_size(request["questions"]) == 6
    assert Enum.all?(request["questions"], fn {_id, question} -> question["type"] == "noul" end)
  end
end
