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
