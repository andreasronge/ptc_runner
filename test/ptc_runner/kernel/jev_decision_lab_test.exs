lab = Path.expand("../../../scripts/labs/jev-decision/support/lab.exs", __DIR__)
Code.require_file(lab)

defmodule PtcRunner.Kernel.JevDecisionLabTest do
  use ExUnit.Case, async: true
  @moduletag :operator

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
           "answers" => valid_answers(),
           "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "cost" => 0.0042}
         }
       }}
    end

    assert {:ok, result} =
             JevDecisionLab.run(requester: requester, recorder: fn _record -> :ok end)

    assert result.value["model"] == "typesafe/jev-1.13-20260917"
    assert result.value["answers"]["department"]["choice"] == "billing"
    assert result.value["answers"]["severity"]["score"] == 1.3

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
        Map.new(Map.keys(body["questions"]), fn answer_id ->
          probability = if answer_id in ~w(T_1001 T_1004), do: 0.95, else: 0.05
          {answer_id, %{"type" => "noul", "noul" => probability}}
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

    assert {:ok, result} =
             JevDecisionLab.run_refund_triage(
               requester: requester,
               recorder: fn _record -> :ok end
             )

    assert result.value["refund_ticket_ids"] == ["T-1001", "T-1004"]
    assert result.value["model"] == "typesafe/jev-1.13-20260917"

    assert_receive {:triage_request, request}
    assert map_size(request["questions"]) == 6
    assert Enum.all?(request["questions"], fn {_id, question} -> question["type"] == "noul" end)
  end

  defp response(answers, usage \\ %{"input_tokens" => 2, "output_tokens" => 1, "cost" => 0.01}) do
    %{"model" => "typesafe/jev-1.13", "answers" => answers, "usage" => usage}
  end

  defp valid_answers do
    %{
      "department" => %{
        "type" => "choice",
        "choice" => "billing",
        "probabilities" => %{"billing" => 0.5, "sales" => 0.5, "support" => 0.0},
        "confidence" => 0.5
      },
      "severity" => %{
        "type" => "score",
        "score" => 1.3,
        "legend" => %{"0" => "low", "1" => "medium", "2" => "high", "3" => "critical"},
        "probabilities" => %{"0" => 0.1, "1" => 0.6, "2" => 0.2, "3" => 0.1},
        "confidence" => 0.6
      },
      "urgent" => %{"type" => "noul", "noul" => 0.93}
    }
  end

  defp invoke_with_answers(answers, opts \\ []) do
    requester = fn _ ->
      {:ok,
       %{
         status: 200,
         headers: Keyword.get(opts, :headers, %{}),
         body:
           response(
             answers,
             Keyword.get(opts, :usage, %{
               "input_tokens" => 2,
               "output_tokens" => 1,
               "cost" => 0.01
             })
           )
       }}
    end

    capability_opts =
      if Keyword.get(opts, :default_recorder, false) do
        [
          requester: requester,
          record_directory:
            Keyword.get(
              opts,
              :record_directory,
              Path.expand("../../../tmp/jev-decision-attempts", __DIR__)
            )
        ]
      else
        [requester: requester, recorder: Keyword.get(opts, :recorder, fn _ -> :ok end)]
      end

    {:ok, capability} = JevDecisionLab.capability(capability_opts)

    capability.callback.(%{
      "state" => %{},
      "questions" => %{
        "department" => %{
          "type" => "choice",
          "instructions" => "Pick",
          "criteria" => %{"billing" => "Billing", "sales" => "Sales", "support" => "Support"}
        },
        "severity" => %{
          "type" => "score",
          "instructions" => "Rate",
          "criteria" => ["low", "medium", "high", "critical"]
        },
        "urgent" => %{"type" => "boolean", "instructions" => "Urgent?"}
      }
    })
  end

  test "direct maps reject malformed criteria before requester dispatch" do
    parent = self()

    {:ok, capability} =
      JevDecisionLab.capability(requester: fn _ -> send(parent, :dispatched) end)

    base = %{
      "state" => %{},
      "questions" => %{
        "q" => %{"type" => "choice", "instructions" => "Pick", "criteria" => %{"a" => "A"}}
      }
    }

    assert :ok = capability.validate.(base)

    assert :ok =
             capability.validate.(
               put_in(base, ["questions", "q"], %{
                 "type" => "boolean",
                 "instructions" => "Yes?",
                 "criteria" => %{"true" => "yes", "false" => "no"}
               })
             )

    invalid_requests =
      Enum.map([%{}, Map.new(1..256, &{Integer.to_string(&1), "x"})], fn criteria ->
        put_in(base, ["questions", "q", "criteria"], criteria)
      end) ++
        Enum.map([["one"], Enum.map(1..11, &Integer.to_string/1)], fn criteria ->
          put_in(base, ["questions", "q"], %{
            "type" => "score",
            "instructions" => "Rate",
            "criteria" => criteria
          })
        end) ++
        [
          put_in(base, ["questions", "q"], %{
            "type" => "boolean",
            "instructions" => "Yes?",
            "criteria" => %{"true" => "yes"}
          })
        ]

    for request <- invalid_requests do
      assert {:error, _} = capability.validate.(request)

      assert {:ok, result} =
               JevDecisionLab.run_request(request,
                 requester: fn _ -> send(parent, :dispatched) end,
                 recorder: fn _ -> :ok end
               )

      assert result.value["reason"] == "invalid_arguments"
    end

    refute_received :dispatched
  end

  test "the Kernel request seam preserves legal requests larger than four kilobytes" do
    parent = self()
    criteria = Map.new(1..255, &{"option_#{&1}", String.duplicate("description ", 4)})

    request = %{
      "state" => %{"context" => String.duplicate("state ", 800)},
      "questions" => %{
        "large" => %{"type" => "choice", "instructions" => "Pick", "criteria" => criteria}
      }
    }

    assert byte_size(Jason.encode!(request)) > 4_096

    assert {:ok, result} =
             JevDecisionLab.run_request(request,
               requester: fn _body ->
                 send(parent, :dispatched)
                 {:ok, %{status: 503}}
               end,
               recorder: fn _ -> :ok end
             )

    assert result.value["reason"] == "unavailable"
    assert_received :dispatched
  end

  test "malformed dispatched answers retain known and unknown accounting privately" do
    for usage <- [
          %{"input_tokens" => 2, "output_tokens" => 1, "cost" => 0.01},
          %{"input_tokens" => 2, "output_tokens" => 1, "cost" => "bad"},
          %{"input_tokens" => "bad"}
        ] do
      parent = self()

      assert {:error, error} =
               invoke_with_answers(%{},
                 usage: usage,
                 headers: %{"x-generation-id" => ["gen-1"], "authorization" => ["secret"]},
                 recorder: fn record -> send(parent, {:record, record}) end
               )

      assert error.kind == :invalid_result
      assert error.dispatch_provenance == :dispatched
      assert error.retryable? == false
      refute inspect(error) =~ "secret"
      assert_receive {:record, record}
      assert record.outcome == :invalid_result
      assert record.response["answers"] == %{}
      assert record.request["questions"]["urgent"]["type"] == "noul"
      assert record.headers == %{"x-generation-id" => "gen-1"}

      expected_usage =
        cond do
          not is_integer(usage["input_tokens"]) -> :unknown
          is_number(usage["cost"]) -> usage
          true -> Map.take(usage, ~w(input_tokens output_tokens))
        end

      assert record.usage == expected_usage
      assert record.cost == if(is_number(usage["cost"]), do: usage["cost"], else: :unknown)
    end
  end

  test "default records are written only inside an owner-only directory" do
    dir = Path.expand("../../../tmp/jev-decision-attempts", __DIR__)
    before = dir |> Path.join("attempt-*.term") |> Path.wildcard() |> MapSet.new()

    assert {:ok, _result} = invoke_with_answers(valid_answers(), default_recorder: true)

    after_paths = dir |> Path.join("attempt-*.term") |> Path.wildcard() |> MapSet.new()
    [path] = MapSet.to_list(MapSet.difference(after_paths, before))
    on_exit(fn -> File.rm(path) end)

    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert is_map(path |> File.read!() |> :erlang.binary_to_term([:safe]))
  end

  test "default recording creates a private hierarchy when its parent is absent" do
    root = Path.join(System.tmp_dir!(), "jev-decision-#{System.unique_integer([:positive])}")
    dir = Path.join(root, "attempts")
    refute File.exists?(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, _result} =
             invoke_with_answers(valid_answers(),
               default_recorder: true,
               record_directory: dir
             )

    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    assert [path] = Path.wildcard(Path.join(dir, "attempt-*.term"))
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "the decision response validates answer and usage boundaries" do
    answers = valid_answers()
    parent = self()

    invalid = [
      {"missing answer", Map.delete(answers, "urgent"), []},
      {"extra answer", Map.put(answers, "extra", %{"type" => "noul", "noul" => 0.5}), []},
      {"wrong wire type", put_in(answers, ["urgent", "type"], "choice"), []},
      {"choice options",
       put_in(answers, ["department", "probabilities"], %{
         "billing" => 0.5,
         "sales" => 0.5,
         "other" => 0.0
       }), []},
      {"choice range", put_in(answers, ["department", "probabilities", "billing"], 1.1), []},
      {"choice sum",
       put_in(answers, ["department", "probabilities"], %{
         "billing" => 0.45,
         "sales" => 0.45,
         "support" => 0.0
       }), []},
      {"choice maximum",
       answers
       |> put_in(["department", "choice"], "support")
       |> put_in(["department", "probabilities"], %{
         "billing" => 0.8,
         "sales" => 0.1,
         "support" => 0.1
       }), []},
      {"choice confidence", put_in(answers, ["department", "confidence"], 1.01), []},
      {"score legend", put_in(answers, ["severity", "legend", "3"], "blocker"), []},
      {"score levels",
       put_in(answers, ["severity", "probabilities"], %{
         "0" => 0.1,
         "1" => 0.6,
         "2" => 0.3
       }), []},
      {"score probability", put_in(answers, ["severity", "probabilities", "0"], -0.1), []},
      {"score range", put_in(answers, ["severity", "score"], 4.0), []},
      {"score weighted mean", put_in(answers, ["severity", "score"], 1.32), []},
      {"score finite confidence", put_in(answers, ["severity", "confidence"], 1.0e308), []},
      {"score inconsistent", put_in(answers, ["severity", "score"], 1.2),
       [recorder: fn record -> send(parent, {:record, record}) end]},
      {"boolean probability", put_in(answers, ["urgent", "noul"], -0.01), []},
      {"provider usage", answers, [usage: %{"input_tokens" => -1, "output_tokens" => 2}]}
    ]

    for {name, candidate, opts} <- invalid do
      assert {:error, %{kind: :invalid_result, dispatch_provenance: :dispatched}} =
               invoke_with_answers(candidate, opts),
             name
    end

    assert_receive {:record, %{outcome: :invalid_result}}

    accepted = [
      answers,
      put_in(answers, ["department", "probabilities"], %{
        "billing" => 0.504,
        "sales" => 0.505,
        "support" => 0.0
      }),
      put_in(answers, ["department", "probabilities"], %{
        "billing" => 0.33,
        "sales" => 0.34,
        "support" => 0.32
      }),
      put_in(answers, ["severity", "score"], 1.309),
      put_in(answers, ["severity", "score"], 1.31)
    ]

    for candidate <- accepted do
      assert {:ok, _result} = invoke_with_answers(candidate)
    end

    requester = fn _ -> {:ok, %{status: 200, body: response(%{})}} end

    assert {:ok, result} =
             JevDecisionLab.run_refund_triage(
               requester: requester,
               recorder: fn _ -> :ok end
             )

    assert result.value["reason"] == "invalid_result"
  end
end
