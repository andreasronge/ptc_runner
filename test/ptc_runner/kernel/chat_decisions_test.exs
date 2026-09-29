defmodule PtcRunner.Kernel.ChatDecisionsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ChatDecisions
  alias PtcRunner.Kernel.DecisionContract

  @questions %{
    "yes" => %{"type" => "boolean", "instructions" => "Is the condition satisfied?"},
    "no" => %{"type" => "boolean", "instructions" => "Is the other condition satisfied?"},
    "option" => %{
      "type" => "choice",
      "instructions" => "Select an option",
      "criteria" => %{"a" => "First", "b" => "Second"}
    },
    "level" => %{
      "type" => "score",
      "instructions" => "Select a level",
      "criteria" => ["Low", "High"]
    }
  }
  @request %{"state" => %{"condition" => true}, "questions" => @questions}
  @object %{"yes" => true, "no" => false, "option" => "b", "level" => 1}

  test "one structured chat request supplies discrete answers without measurements" do
    parent = self()

    chat = fn request, context ->
      send(parent, {:request, request, context})
      {:ok, %{object: @object, tokens: %{input: 10, output: 4, total_cost: 0.0002}}}
    end

    requester = ChatDecisions.requester(chat, "served-chat")
    assert {:ok, result} = requester.(@request, %{llm_request_deadline_ms: 123})
    assert DecisionContract.valid_response?(result, @questions)
    assert result["answers"]["yes"]["value"] == true
    assert result["answers"]["no"]["value"] == false
    assert result["answers"]["option"]["choice"] == "b"
    assert result["answers"]["level"]["score"] == 1

    for answer <- Map.values(result["answers"]) do
      assert answer["confidence"] == nil
      assert answer["probability"] == nil
      assert answer["probabilities"] == nil
    end

    assert_receive {:request, request, %{llm_request_deadline_ms: 123}}
    assert [%{role: :user, content: content}] = request.messages
    assert Jason.decode!(content) == @request
    assert request.schema["properties"]["option"]["enum"] == ["a", "b"]
    assert request.schema["properties"]["level"]["enum"] == [0, 1]
    refute_receive {:request, _, _}
  end

  test "an unsupported schema refuses before sending chat" do
    parent = self()

    requester =
      ChatDecisions.requester(
        fn _, _ ->
          send(parent, :sent)
          {:ok, %{}}
        end,
        "chat"
      )

    questions =
      Map.new(1..129, fn i ->
        {Integer.to_string(i), %{"type" => "boolean", "instructions" => "Evaluate"}}
      end)

    assert {:error, %{kind: :invalid_request}} =
             requester.(%{"state" => %{}, "questions" => questions}, %{})

    refute_received :sent
  end

  test "malformed structured output preserves usage for settlement" do
    for object <- [
          Map.delete(@object, "no"),
          Map.put(@object, "no", "false"),
          Map.put(@object, "option", "other"),
          Map.put(@object, "level", 0.5)
        ] do
      requester =
        ChatDecisions.requester(
          fn _, _ ->
            {:ok, %{object: object, tokens: %{input: 10, output: 4}}}
          end,
          "chat"
        )

      assert {:ok, result} = requester.(@request, %{})
      refute Map.has_key?(result, "answers")
      assert result["usage"] == %{"input_tokens" => 10, "output_tokens" => 4}
    end
  end
end
