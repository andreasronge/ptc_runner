defmodule Mix.Tasks.PtcTranscriptTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.MixCommandAdapter
  alias PtcRunner.TestSupport.PrivateInspectionFixture
  alias PtcRunner.TranscriptFrontend

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

  @tag :tmp_dir
  test "preserves capture-time source changes without publishing output", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root, "changed-source")
    output_directory = Path.join(root, "transcript")
    File.mkdir!(output_directory)
    output = Path.join(output_directory, "transcript.private.json")

    argv = [
      "transcript",
      fixture.run_id,
      "--traces",
      fixture.traces,
      "--inspection",
      fixture.inspection,
      "--private-unattended",
      "--private-output",
      output
    ]

    assert {:ok, entry} = CommandEntry.open(argv, :standalone)
    trace_path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")

    assert {:error, :source_changed, "analysis source changed during capture"} =
             TranscriptFrontend.run(entry.arguments, CommandRuntime.standalone(),
               capture_hook: fn -> File.write!(trace_path, File.read!(trace_path) <> "\n") end
             )

    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "preserves inspection changes during artifact verification", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root, "changed-inspection")
    output_directory = Path.join(root, "transcript")
    File.mkdir!(output_directory)
    output = Path.join(output_directory, "transcript.private.json")

    argv = [
      "transcript",
      fixture.run_id,
      "--traces",
      fixture.traces,
      "--inspection",
      fixture.inspection,
      "--private-unattended",
      "--private-output",
      output
    ]

    assert {:ok, entry} = CommandEntry.open(argv, :standalone)
    [inspection_path] = Path.wildcard(Path.join(fixture.inspection, "*.inspection.jsonl"))

    assert {:error, :source_changed, "analysis source changed during capture"} =
             TranscriptFrontend.run(entry.arguments, CommandRuntime.standalone(),
               inspection_artifact_verification_hook: fn ->
                 File.write!(inspection_path, "\n", [:append])
               end
             )

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
