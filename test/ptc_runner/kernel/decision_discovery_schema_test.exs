defmodule PtcRunner.Kernel.DecisionDiscoverySchemaTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.DecisionCapability
  alias PtcRunner.Kernel.DecisionContract
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.WorkflowEnvironment

  @questions %{
    "b" => %{"type" => "boolean", "instructions" => "Evaluate"},
    "c" => %{"type" => "choice", "instructions" => "Select", "criteria" => %{"a" => "A"}},
    "s" => %{"type" => "score", "instructions" => "Rate", "criteria" => ["Low", "High"]}
  }
  @request %{"state" => %{}, "questions" => @questions}
  @response %{
    "model" => "fixture",
    "answers" => %{
      "b" => %{"type" => "boolean", "probability" => nil, "confidence" => nil, "value" => false},
      "c" => %{"type" => "choice", "choice" => "a", "probabilities" => nil, "confidence" => nil},
      "s" => %{
        "type" => "score",
        "score" => 1,
        "legend" => %{"0" => "Low", "1" => "High"},
        "probabilities" => nil,
        "confidence" => nil
      }
    },
    "usage" => %{"input_tokens" => 0, "output_tokens" => 1, "extension" => true}
  }

  setup do
    {:ok, capability} = DecisionCapability.new(requester: fn _, _ -> {:ok, @response} end)
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, state} = RunState.start(Limits.defaults())
    tools = RuntimeTools.tools(state, environment, nil, :workflow)
    metadata = tools["cap-describe"].(%{"name" => "decision-request"})
    {:ok, _, input} = JSONSchema.compile(metadata.input_schema)
    {:ok, _, output} = JSONSchema.compile(metadata.output_schema)
    %{input: input, output: output}
  end

  test "discovery validates all question types and nullable or measured answers", %{
    input: input,
    output: output
  } do
    assert JSONSchema.valid?(input, @request)
    assert :ok = DecisionContract.validate_request(@request)

    for value <- [true, false, nil] do
      response = put_in(@response, ["answers", "b", "value"], value)
      assert JSONSchema.valid?(output, response)
      assert DecisionContract.valid_response?(response, @questions)
    end

    measured =
      @response
      |> put_in(["answers", "b", "probability"], 0.5)
      |> put_in(["answers", "c", "probabilities"], %{"a" => 1})
      |> put_in(["answers", "s", "probabilities"], %{"0" => 0, "1" => 1})

    assert JSONSchema.valid?(output, measured)
    assert DecisionContract.valid_response?(measured, @questions)
  end

  test "structural request mistakes agree with runtime rejection", %{input: input} do
    for question <- [
          %{"type" => "boolean"},
          %{"type" => "other", "instructions" => "Evaluate"},
          %{"type" => "boolean", "instructions" => ""},
          %{"type" => "boolean", "instructions" => 1},
          %{"type" => "boolean", "instructions" => "Evaluate", "unknown" => true}
        ] do
      request = put_in(@request, ["questions", "b"], question)
      refute JSONSchema.valid?(input, request)
      assert {:error, _} = DecisionContract.validate_request(request)
    end
  end

  test "structural response mistakes agree with runtime rejection", %{output: output} do
    responses = [
      put_in(@response, ["model"], ""),
      put_in(@response, ["answers", "b", "value"], 1),
      put_in(@response, ["answers", "b", "probability"], 2),
      put_in(@response, ["answers", "c", "choice"], false),
      put_in(@response, ["answers", "s", "score"], "1"),
      put_in(@response, ["answers", "s", "legend"], %{"0" => 1}),
      put_in(@response, ["usage", "input_tokens"], -1),
      put_in(@response, ["usage", "output_tokens"], 0.5),
      Map.put(@response, "usage", %{})
    ]

    for response <- responses do
      refute JSONSchema.valid?(output, response)
      refute DecisionContract.valid_response?(response, @questions)
    end
  end

  test "criteria and nonempty questions remain runtime checks", %{input: input} do
    for questions <- [
          %{},
          put_in(@questions, ["c", "criteria"], []),
          put_in(@questions, ["s", "criteria"], ["Only"])
        ] do
      request = Map.put(@request, "questions", questions)
      assert JSONSchema.valid?(input, request)
      assert {:error, _} = DecisionContract.validate_request(request)
    end
  end

  test "per-type fields and request-dependent semantics remain runtime checks", %{output: output} do
    responses = [
      update_in(@response, ["answers", "b"], &Map.delete(&1, "probability")),
      update_in(@response, ["answers", "c"], &Map.delete(&1, "choice")),
      update_in(@response, ["answers", "s"], &Map.delete(&1, "legend")),
      update_in(@response, ["answers"], &Map.delete(&1, "b")),
      put_in(@response, ["answers", "c", "choice"], "unknown"),
      put_in(@response, ["answers", "s", "legend"], %{}),
      put_in(@response, ["answers", "c", "probabilities"], %{"a" => 0.5}),
      put_in(@response, ["answers", "s", "probabilities"], %{"0" => 1, "1" => 0}),
      put_in(@response, ["usage", "cost"], "invalid")
    ]

    for response <- responses do
      assert JSONSchema.valid?(output, response)
      refute DecisionContract.valid_response?(response, @questions)
    end
  end
end
