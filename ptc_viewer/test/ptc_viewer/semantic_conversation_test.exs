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
  end

  defp render(directory, conversation) do
    metadata_path = Path.join(directory, "metadata.json")
    turns_path = Path.join(directory, "turns.json")
    conversation_path = Path.join(directory, "conversation.json")
    File.write!(metadata_path, Jason.encode!(%{}))
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
