defmodule Mix.Tasks.PtcTranscriptTest do
  use ExUnit.Case, async: true

  alias PtcRunner.MixCommandAdapter
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @tag :tmp_dir
  test "one command writes an exact private conversation without record-shape knowledge", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    output_directory = Path.join(root, "transcript")
    File.mkdir!(output_directory)
    output = Path.join(output_directory, "transcript.private.json")

    presentation =
      MixCommandAdapter.execute([
        "transcript",
        fixture.run_id,
        "--traces",
        fixture.traces,
        "--inspection",
        fixture.inspection,
        "--private-unattended",
        "--private-output",
        output
      ])

    assert presentation.exit_status == 0
    assert presentation.stdout == ""
    assert presentation.stderr == ""

    assert %{
             "schema_version" => 1,
             "run_id" => run_id,
             "conversation" => %{
               "complete?" => true,
               "streams" => [
                 %{
                   "turns" => [
                     %{
                       "messages_added" => [%{"content" => prompt}],
                       "response" => %{"value" => %{"answer" => answer}}
                     }
                   ]
                 }
               ]
             }
           } = output |> File.read!() |> Jason.decode!()

    assert run_id == fixture.run_id
    assert prompt == "private-prompt-#{run_id}"
    assert answer == "private-answer-#{run_id}"
    assert File.stat!(output).mode |> Bitwise.band(0o777) == 0o600
  end

  @tag :tmp_dir
  test "reports an unsupported private artifact schema without publishing output", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root, "old-schema")
    PrivateInspectionFixture.rewrite_schema!(fixture.inspection, 4)
    output_directory = Path.join(root, "transcript")
    File.mkdir!(output_directory)
    output = Path.join(output_directory, "transcript.private.json")

    presentation =
      MixCommandAdapter.execute([
        "transcript",
        fixture.run_id,
        "--traces",
        fixture.traces,
        "--inspection",
        fixture.inspection,
        "--private-unattended",
        "--private-output",
        output
      ])

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "error: transcript/unsupported_schema:"
    assert presentation.stderr =~ "schema version 4 is unsupported"
    assert presentation.stderr =~ "supports version 5"
    refute File.exists?(output)
  end

  test "the unattended accident guard and private destination are mandatory" do
    for argv <- [
          [
            "transcript",
            "run",
            "--traces",
            "traces",
            "--inspection",
            "inspection",
            "--private-output",
            "out.json"
          ],
          [
            "transcript",
            "run",
            "--traces",
            "traces",
            "--inspection",
            "inspection",
            "--private-unattended"
          ]
        ] do
      assert %{exit_status: 2} = MixCommandAdapter.execute(argv)
    end
  end
end
