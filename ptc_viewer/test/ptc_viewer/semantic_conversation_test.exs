defmodule PtcViewer.SemanticConversationTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "renders unavailable, incomplete, and ambiguous evidence states", %{tmp_dir: directory} do
    unavailable =
      render(directory, %{
        "available?" => false,
        "status" => 503,
        "reason" => "inspection source unavailable"
      })

    assert unavailable =~ "Unavailable (HTTP 503)"
    assert unavailable =~ "Private conversation unavailable: inspection source unavailable."

    unconfigured =
      render(directory, %{
        "available?" => false,
        "status" => 404,
        "reason" => "inspection_not_configured"
      })

    refute unconfigured =~ "HTTP"
    assert unconfigured =~ "Not recorded"
    assert unconfigured =~ "This project does not record inspection artifacts."
    assert unconfigured =~ "ptc-project.json"

    # Withheld by the project and absent for this run are different states
    # with different next actions, so they do not share a sentence.
    unrecorded_run =
      render(directory, %{
        "available?" => false,
        "status" => 404,
        "reason" => "inspection_run_not_recorded"
      })

    refute unrecorded_run =~ "HTTP"
    assert unrecorded_run =~ "Not recorded for this run"
    assert unrecorded_run =~ "run the project again to record one"

    other_run =
      render(directory, %{
        "available?" => false,
        "status" => 404,
        "reason" => "inspection_run_mismatch"
      })

    refute other_run =~ "HTTP"
    assert other_run =~ "Other run"
    assert other_run =~ "Start it for this run"

    incomplete =
      render(directory, %{
        "complete?" => false,
        "missing_exchange_count" => 2,
        "streams" => []
      })

    assert incomplete =~ "Incomplete private evidence. 2 expected model exchange(s) are missing."
    refute incomplete =~ "No model exchanges were captured"

    ambiguous =
      render(directory, %{
        "complete?" => false,
        "ambiguous?" => true,
        "missing_exchange_count" => 0,
        "streams" => []
      })

    assert ambiguous =~ "Ambiguous conversation branches were not guessed into a stream."
  end

  test "a rendered turn shows the system prompt that shaped it", %{tmp_dir: directory} do
    rendered =
      render(directory, %{
        "complete?" => true,
        "ambiguous?" => false,
        "missing_exchange_count" => 0,
        "streams" => [
          %{
            "stream_id" => "stream-1",
            "turns" => [
              %{
                "turn" => 1,
                "request_sequence" => 1,
                "system" => "you price orders in cents",
                "messages_added" => [%{"role" => "user", "content" => "price it"}],
                "outcome" => "ok"
              },
              %{
                "turn" => 2,
                "request_sequence" => 3,
                "messages_added" => [%{"role" => "user", "content" => "again"}],
                "outcome" => "ok"
              }
            ]
          }
        ]
      })

    assert rendered =~ "you price orders in cents"

    # An unchanged prompt is carried once per stream, so the second turn
    # renders without repeating it rather than showing an empty field.
    refute rendered =~ ~s("system": null)
    assert rendered =~ "System prompt unchanged from the previous turn."
  end

  test "distinguishes no prompt, de-duplicates feedback, and withholds ambiguous joins", %{
    tmp_dir: directory
  } do
    rendered =
      render(directory, %{
        "complete?" => false,
        "ambiguous?" => true,
        "streams" => [
          %{
            "stream_id" => "stream-ambiguous",
            "turns" => [
              %{
                "turn" => 1,
                "system" => nil,
                "messages_added" => [
                  %{"role" => "tool", "tool_call_id" => "call-1", "content" => "once"}
                ],
                "feedback" => [
                  %{"role" => "tool", "tool_call_id" => "call-1", "content" => "once"}
                ],
                "generated" => [
                  %{
                    "mission_name" => "wrong-if-guessed",
                    "source" => "(return :ambiguous)",
                    "association_ambiguous?" => true
                  }
                ],
                "outcome" => "ok"
              }
            ]
          }
        ]
      })

    assert rendered =~ "No system prompt was sent."
    assert length(Regex.scan(~r/class="kt-msg kt-msg-tool"/, rendered)) == 1
    assert rendered =~ "1 generated source had an ambiguous turn association"
    refute rendered =~ "Generated programs"
    refute rendered =~ ">wrong-if-guessed</strong>"
    assert rendered =~ "(return :ambiguous)"
  end

  test "presents model sessions and generated programs before the raw record", %{
    tmp_dir: directory
  } do
    rendered =
      render(directory, %{
        "complete?" => true,
        "streams" => [
          %{
            "stream_id" => "stream-7",
            "turns" => [
              %{
                "turn" => 1,
                "request_sequence" => 4,
                "messages_added" => [%{"role" => "user", "content" => "check this"}],
                "generated" => [
                  %{
                    "mission_name" => "review",
                    "evaluation_id" => "eval-7",
                    "source" => ~S|(+ 1 2)|
                  }
                ],
                "outcome" => "ok"
              }
            ]
          }
        ]
      })

    assert rendered =~ "Model sessions &amp; programs"
    assert rendered =~ "One turn means the model was called once"
    assert rendered =~ ">review</strong>"
    assert rendered =~ "stream-7"
    assert rendered =~ "Input added this turn"
    assert rendered =~ "Generated programs"
    assert rendered =~ "eval-7"
    assert rendered =~ "Raw turn record"
    assert rendered =~ "check this"
  end

  test "labels the response install alias and its resolved model", %{tmp_dir: directory} do
    rendered =
      render(
        directory,
        %{
          "complete?" => true,
          "streams" => [
            %{
              "stream_id" => "stream-1",
              "turns" => [
                %{
                  "turn" => 1,
                  "response" => %{
                    "value" => %{
                      "content" => "ordinary answer",
                      "model" => "deepseek"
                    }
                  },
                  "assistant" => %{
                    "role" => "assistant",
                    "content" => "ordinary answer"
                  }
                },
                %{
                  "turn" => 2,
                  "response" => %{
                    "value" => %{
                      "content" => nil,
                      "model" => "deepseek",
                      "tool_calls" => [%{"id" => "call-1", "args" => %{}}]
                    }
                  },
                  "assistant" => %{
                    "role" => "assistant",
                    "content" => nil,
                    "tool_calls" => [%{"id" => "call-1", "args" => %{}}]
                  }
                },
                %{
                  "turn" => 3,
                  "response" => %{
                    "value" => %{
                      "model" => "deepseek",
                      "structured_output" => %{"owner" => "Priya"}
                    }
                  },
                  "assistant" => %{
                    "role" => "assistant",
                    "content" => %{
                      "model" => "deepseek",
                      "structured_output" => %{"owner" => "Priya"}
                    }
                  }
                }
              ]
            }
          ]
        },
        %{
          "connector_snapshots" => [
            %{
              "declaration" => %{"name" => "deepseek", "source" => "llm"},
              "acquisition" => %{
                "source" => "llm",
                "resolved_model" => "openrouter:nex-agi/nex-n2-pro"
              }
            }
          ]
        }
      )

    assert rendered =~ "Install alias"
    assert rendered =~ "deepseek"
    assert rendered =~ "Configured model"
    assert rendered =~ "openrouter:nex-agi/nex-n2-pro"
    assert rendered =~ "ordinary answer"
    assert length(Regex.scan(~r/<strong>Install alias<\/strong> deepseek/, rendered)) == 3
    assert rendered =~ ~s(&quot;alias&quot;: &quot;deepseek&quot;)
    assert rendered =~ ~s(&quot;model&quot;: &quot;deepseek&quot;)
  end

  defp render(directory, conversation, metadata \\ %{}) do
    metadata_path = Path.join(directory, "metadata.json")
    turns_path = Path.join(directory, "turns.json")
    conversation_path = Path.join(directory, "conversation.json")
    File.write!(metadata_path, Jason.encode!(metadata))
    File.write!(turns_path, Jason.encode!(%{"items" => []}))
    File.write!(conversation_path, Jason.encode!(conversation))

    script = Path.expand("../render_semantic_viewer.mjs", __DIR__)

    assert {rendered, 0} =
             System.cmd("node", [script, metadata_path, turns_path, conversation_path],
               stderr_to_stdout: true
             )

    rendered
  end
end
