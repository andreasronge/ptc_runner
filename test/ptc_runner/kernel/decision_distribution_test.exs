defmodule PtcRunner.Kernel.DecisionDistributionTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.DecisionCapability
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

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
      "urgent" => %{"type" => "boolean", "probability" => 0.93, "confidence" => nil}
    }
  end

  defp invoke_with_answers(answers, opts \\ []) do
    response = %{
      "model" => "served-model",
      "answers" => answers,
      "usage" =>
        Keyword.get(opts, :usage, %{"input_tokens" => 2, "output_tokens" => 1, "cost" => 0.01})
    }

    {:ok, capability} =
      DecisionCapability.new(requester: fn _, _ -> {:ok, response} end)

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new([])
    {:ok, state} = RunState.start(limits)

    Dispatcher.dispatch(
      state,
      :workflow,
      environment,
      "decision-request",
      %{
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
      },
      TestHelpers.dispatch_context(state, :workflow, 500),
      nil,
      nil
    )
  end

  test "discovery publishes the nullable discrete boolean contract" do
    {:ok, capability} = DecisionCapability.new(requester: fn _, _ -> {:ok, %{}} end)
    metadata = Capability.metadata(capability)
    {:ok, _, compiled} = JSONSchema.compile(metadata.output_schema)
    response = %{"model" => "fixture", "answers" => valid_answers(), "usage" => %{}}
    assert JSONSchema.valid?(compiled, response)

    for value <- [true, false, nil] do
      assert JSONSchema.valid?(
               compiled,
               put_in(response, ["answers", "urgent", "value"], value)
             )
    end

    for value <- [0, "false", %{}] do
      refute JSONSchema.valid?(
               compiled,
               put_in(response, ["answers", "urgent", "value"], value)
             )
    end
  end

  test "boolean discrete values preserve false and reject other types" do
    for value <- [true, false, nil] do
      answers = put_in(valid_answers(), ["urgent", "value"], value)
      assert %{status: :ok, value: result} = invoke_with_answers(answers)
      assert result["answers"]["urgent"]["value"] == value
      assert result["answers"]["urgent"]["probability"] == 0.93
    end

    assert %{status: :ok, value: result} = invoke_with_answers(valid_answers())
    refute Map.has_key?(result["answers"]["urgent"], "value")

    for value <- [0, 1, "false", [], %{}] do
      assert %{status: :error, kind: :invalid_result} =
               invoke_with_answers(put_in(valid_answers(), ["urgent", "value"], value))
    end
  end

  test "the decision response validates answer and usage boundaries" do
    answers = valid_answers()

    invalid = [
      {"missing answer", Map.delete(answers, "urgent"), []},
      {"extra answer",
       Map.put(answers, "extra", %{"type" => "boolean", "probability" => 0.5, "confidence" => nil}),
       []},
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
      {"score inconsistent", put_in(answers, ["severity", "score"], 1.2), []},
      {"boolean probability", put_in(answers, ["urgent", "probability"], -0.01), []},
      {"provider usage", answers, [usage: %{"input_tokens" => -1, "output_tokens" => 2}]}
    ]

    for {name, candidate, opts} <- invalid do
      assert %{status: :error, kind: :invalid_result, retryable?: false} =
               invoke_with_answers(candidate, opts),
             name
    end

    accepted = [
      answers,
      put_in(answers, ["department", "probabilities"], nil),
      put_in(answers, ["severity", "probabilities"], nil),
      put_in(answers, ["department", "confidence"], nil),
      put_in(answers, ["severity", "confidence"], nil),
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
      assert %{status: :ok} = invoke_with_answers(candidate)
    end
  end
end
