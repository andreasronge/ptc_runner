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
    relative_output = Path.relative_to(output, File.cwd!())

    assert Path.type(relative_output) == :relative

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
        relative_output
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
                       "system" => system,
                       "messages_added" => [%{"content" => prompt}],
                       "response" => %{"value" => %{"answer" => answer}}
                     }
                   ]
                 }
               ]
             }
           } = output |> File.read!() |> Jason.decode!()

    assert run_id == fixture.run_id

    # A transcript that certifies its own completeness cannot omit the
    # instructions that shaped the run.
    assert system == "private-system-#{run_id}"
    assert prompt == "private-prompt-#{run_id}"
    assert answer == "private-answer-#{run_id}"
    assert File.stat!(output).mode |> Bitwise.band(0o777) == 0o600
  end

  @tag :tmp_dir
  test "an ambiguous reconstruction names ambiguity and its count, not incompleteness", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create_ambiguous!(root)
    output = Path.join(fixture.output, "ambiguous.private.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    # The refusal is correct; naming incompleteness for it is not. Nothing is
    # missing here, so a user told "incomplete" hunts for artifacts they have.
    assert presentation.stderr =~ "transcript/ambiguous_evidence"
    refute presentation.stderr =~ "incomplete_evidence"
    assert presentation.stderr =~ "is ambiguous: 1 turn or generated-source association"
    assert presentation.stderr =~ "viewer.private"
    assert presentation.stderr =~ "/api/analysis/runs/RUN_ID/conversation"
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "an uncaptured model exchange reports incompleteness and its count", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create_interrupted!(root)
    output = Path.join(fixture.output, "interrupted.private.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/incomplete_evidence"
    assert presentation.stderr =~ "1 model exchange the canonical trace expects"
    assert presentation.stderr =~ "not captured under --inspection"
    assert presentation.stderr =~ "0 ambiguous associations"
    assert presentation.stderr =~ "/api/analysis/runs/RUN_ID/conversation"
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "destination failures identify --private-output without echoing its path", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    output = Path.join(fixture.output, "occupied.private.json")
    File.write!(output, "original")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/destination_exists"
    assert presentation.stderr =~ "--private-output"
    assert presentation.stderr =~ "already exists"
    refute presentation.stderr =~ output
    assert File.read!(output) == "original"
  end

  @tag :tmp_dir
  test "each --private-output rule is refused under its own code and names the rule", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)

    missing_parent = Path.join([fixture.output, "absent", "out.private.json"])

    parent_is_file = Path.join(root, "regular-file")
    File.write!(parent_is_file, "not a directory")

    world_writable = Path.join(root, "world-writable")
    File.mkdir_p!(world_writable)
    File.chmod!(world_writable, 0o777)

    real_parent = Path.join(root, "real-parent")
    File.mkdir_p!(real_parent)
    symlinked_parent = Path.join(root, "linked-parent")
    File.ln_s!(real_parent, symlinked_parent)

    # Four filesystem rules, four causes. Three testers met two of these
    # through one message and each inferred a different rule.
    cases = [
      {missing_parent, "destination_directory_missing", "does not exist"},
      {Path.join(parent_is_file, "out.private.json"), "destination_parent_unavailable",
       "not an existing directory"},
      {Path.join(world_writable, "out.private.json"), "destination_parent_unsafe",
       "group- or world-writable"},
      {Path.join(symlinked_parent, "out.private.json"), "destination_parent_unavailable",
       "symbolic link"}
    ]

    for {output, code, rule} <- cases do
      presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

      assert presentation.exit_status == 1
      assert presentation.stderr =~ "transcript/#{code}"
      assert presentation.stderr =~ "--private-output"
      assert presentation.stderr =~ rule
      refute presentation.stderr =~ root
      refute File.exists?(output)
    end
  end

  @tag :tmp_dir
  test "physical source and output collisions identify the conflicting switches", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    alias_root = Path.join(root, "root-alias")
    File.ln_s!(root, alias_root)
    aliased_traces = Path.join(alias_root, "traces")
    nested_inspection = Path.join(fixture.traces, "nested-inspection")
    File.mkdir!(nested_inspection)

    cases = [
      {fixture.traces, fixture.traces, Path.join(fixture.output, "same-source.json"),
       "directories for --traces and --inspection must be physically separate; " <>
         "they resolve to the same physical directory"},
      {fixture.traces, aliased_traces, Path.join(fixture.output, "aliased-source.json"),
       "directories for --traces and --inspection must be physically separate; " <>
         "they resolve to the same physical directory"},
      {fixture.traces, nested_inspection, Path.join(fixture.output, "nested-source.json"),
       "directories for --traces and --inspection must be physically separate; " <>
         "--traces contains --inspection"},
      {fixture.traces, fixture.inspection, Path.join(root, "ancestor-output.json"),
       "directories for --traces and --private-output must be physically separate; " <>
         "--private-output contains --traces"}
    ]

    for {traces, inspection, output, message} <- cases do
      presentation =
        MixCommandAdapter.execute(
          transcript_argv(fixture, output, traces: traces, inspection: inspection)
        )

      assert presentation.exit_status == 1
      assert presentation.stderr =~ "transcript/source_separation_failed"
      assert presentation.stderr =~ message
      refute presentation.stderr =~ root
      refute File.exists?(output)
    end
  end

  @tag :tmp_dir
  test "unavailable and swapped sources identify the declared source switch", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)

    cases = [
      {Path.join(root, "missing-traces"), fixture.inspection, "--traces", "existing"},
      {fixture.inspection, fixture.traces, "--traces", "canonical trace"}
    ]

    for {traces, inspection, switch, cause} <- cases do
      output = Path.join(fixture.output, "source-#{System.unique_integer([:positive])}.json")

      presentation =
        MixCommandAdapter.execute(
          transcript_argv(fixture, output, traces: traces, inspection: inspection)
        )

      assert presentation.exit_status == 1
      assert presentation.stderr =~ "transcript/source_unavailable"
      assert presentation.stderr =~ switch
      assert presentation.stderr =~ cause
      refute presentation.stderr =~ root
      refute File.exists?(output)
    end
  end

  @tag :tmp_dir
  test "an unknown RUN_ID identifies the selector and correlated source switches", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    output = Path.join(fixture.output, "unknown-run.json")

    presentation =
      MixCommandAdapter.execute(
        transcript_argv(fixture, output, run_id: "caller-private-unknown-run")
      )

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/run_not_found"
    assert presentation.stderr =~ "RUN_ID"
    assert presentation.stderr =~ "--traces"
    assert presentation.stderr =~ "--inspection"
    refute presentation.stderr =~ "caller-private-unknown-run"
    refute presentation.stderr =~ root
    refute File.exists?(output)
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
    assert presentation.stderr =~ "supports version 7"
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

  test "every missing required argument reports the complete transcript command shape" do
    complete = [
      "transcript",
      "caller-run",
      "--traces",
      "caller-traces",
      "--inspection",
      "caller-inspection",
      "--private-unattended",
      "--private-output",
      "caller-output.json"
    ]

    for argv <- [
          List.delete_at(complete, 1),
          without_option(complete, "--traces"),
          without_option(complete, "--inspection"),
          List.delete(complete, "--private-unattended"),
          without_option(complete, "--private-output")
        ] do
      presentation = MixCommandAdapter.execute(argv)

      assert presentation.exit_status == 2
      assert presentation.stderr =~ "RUN_ID"
      assert presentation.stderr =~ "--traces"
      assert presentation.stderr =~ "--inspection"
      assert presentation.stderr =~ "--private-unattended"
      assert presentation.stderr =~ "--private-output"
      refute presentation.stderr =~ "caller-run"
      refute presentation.stderr =~ "caller-traces"
      refute presentation.stderr =~ "caller-inspection"
      refute presentation.stderr =~ "caller-output.json"
    end
  end

  defp transcript_argv(fixture, output, overrides \\ []) do
    [
      "transcript",
      Keyword.get(overrides, :run_id, fixture.run_id),
      "--traces",
      Keyword.get(overrides, :traces, fixture.traces),
      "--inspection",
      Keyword.get(overrides, :inspection, fixture.inspection),
      "--private-unattended",
      "--private-output",
      output
    ]
  end

  defp without_option(argv, switch) do
    index = Enum.find_index(argv, &(&1 == switch))
    argv |> List.delete_at(index) |> List.delete_at(index)
  end
end
