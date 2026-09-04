defmodule Mix.Tasks.PtcTranscriptTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.MixCommandAdapter
  alias PtcRunner.TestSupport.PrivateInspectionFixture
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TranscriptFrontend

  defp canonical_create!(root, seed \\ 0) do
    PrivateInspectionFixture.create!(root, PrivateInspectionFixture.command_run_ref(seed))
  end

  @tag :tmp_dir
  test "one command writes an exact private conversation without record-shape knowledge", %{
    tmp_dir: root
  } do
    fixture = canonical_create!(root)
    output_directory = Path.join(root, "transcript")
    File.mkdir!(output_directory)
    output = Path.join(output_directory, "transcript.private.json")
    envelope = Path.join(output_directory, "transcript-envelope.json")
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
        relative_output,
        "--envelope",
        envelope
      ])

    assert presentation.exit_status == 0
    assert presentation.stderr == ""

    assert %{
             "command" => "transcript",
             "run_ref" => run_id,
             "path" => path,
             "turns" => 1
           } = Jason.decode!(presentation.stdout)

    assert run_id == fixture.run_id
    assert path == Path.expand(relative_output)

    assert %{
             "schema_version" => 4,
             "command" => "transcript",
             "status" => "ok",
             "result" => %{
               "command" => "transcript",
               "run_ref" => ^run_id,
               "path" => ^path,
               "turns" => 1
             }
           } = envelope |> File.read!() |> Jason.decode!()

    assert %{
             "schema_version" => 2,
             "run_id" => ^run_id,
             "complete_scope" => "model_conversation",
             "not_included" => ["prelude_sources", "capability_schemas", "result"],
             "conversation" => %{
               "complete?" => true,
               "streams" => [
                 %{
                   "turns" => [
                     %{
                       "request_hash" => request_hash,
                       "system" => system,
                       "messages_added" => [%{"content" => prompt}],
                       "response" => %{"value" => %{"answer" => answer}}
                     }
                   ]
                 }
               ]
             }
           } = output |> File.read!() |> Jason.decode!()

    # A transcript that certifies its own completeness cannot omit the
    # instructions that shaped the run.
    assert system == "private-system-#{run_id}"
    assert prompt == "private-prompt-#{run_id}"
    assert answer == "private-answer-#{run_id}"

    assert {:ok, ^request_hash} =
             LLMReplay.request_hash(%{
               "messages" => [%{"content" => prompt}],
               "system" => system
             })

    assert File.stat!(output).mode |> Bitwise.band(0o777) == 0o600
  end

  @tag :tmp_dir
  test "an ambiguous reconstruction names ambiguity and its count, not incompleteness", %{
    tmp_dir: root
  } do
    fixture =
      PrivateInspectionFixture.create_ambiguous!(root, PrivateInspectionFixture.command_run_ref())

    output = Path.join(fixture.output, "ambiguous.private.json")
    envelope = Path.join(fixture.output, "ambiguous-envelope.json")

    presentation =
      MixCommandAdapter.execute(transcript_argv(fixture, output) ++ ["--envelope", envelope])

    assert presentation.exit_status == 1
    # The refusal is correct; naming incompleteness for it is not. Nothing is
    # missing here, so a user told "incomplete" hunts for artifacts they have.
    assert presentation.stderr =~ "transcript/ambiguous_evidence"
    refute presentation.stderr =~ "incomplete_evidence"
    assert presentation.stderr =~ "is ambiguous: 1 turn or generated-source association"
    assert_ungated_repl_hint(presentation.stderr)
    refute File.exists?(output)
    refute File.exists?(envelope)
  end

  @tag :tmp_dir
  test "a complete transcript accepts identical programs from different turns", %{tmp_dir: root} do
    fixture =
      PrivateInspectionFixture.create_repeated_source!(
        root,
        PrivateInspectionFixture.command_run_ref()
      )

    output = Path.join(fixture.output, "repeated.private.json")
    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 0
    assert presentation.stderr == ""

    assert %{"conversation" => %{"complete?" => true, "streams" => [%{"turns" => turns}]}} =
             output |> File.read!() |> Jason.decode!()

    assert Enum.map(turns, fn turn ->
             Enum.map(turn["generated"], & &1["evaluation_id"])
           end) == [
             ["eval-1-#{fixture.run_id}"],
             ["eval-2-#{fixture.run_id}"]
           ]
  end

  @tag :tmp_dir
  test "an uncaptured model exchange reports incompleteness and its count", %{tmp_dir: root} do
    fixture =
      PrivateInspectionFixture.create_interrupted!(
        root,
        PrivateInspectionFixture.command_run_ref()
      )

    output = Path.join(fixture.output, "interrupted.private.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/incomplete_evidence"
    assert presentation.stderr =~ "1 model exchange the canonical trace expects"
    assert presentation.stderr =~ "not captured under --inspection"
    assert presentation.stderr =~ "0 ambiguous associations"
    assert_ungated_repl_hint(presentation.stderr)
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a nonterminal trace reports canonical incompleteness and its counts", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    trace_path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")

    trace_without_terminal_event =
      trace_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.drop(-1)
      |> Enum.join("\n")

    File.write!(trace_path, trace_without_terminal_event <> "\n")
    output = Path.join(fixture.output, "nonterminal.private.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/incomplete_evidence"
    assert presentation.stderr =~ "canonical trace records no terminal run event"
    assert presentation.stderr =~ "0 missing model exchanges"
    assert presentation.stderr =~ "0 ambiguous associations"
    assert_ungated_repl_hint(presentation.stderr)
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "destination failures identify --private-output without echoing its path", %{tmp_dir: root} do
    fixture = canonical_create!(root)
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
  test "the envelope cannot replace the transcript destination", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    output = Path.join(fixture.output, "same-destination.json")

    presentation =
      MixCommandAdapter.execute(transcript_argv(fixture, output) ++ ["--envelope", output])

    assert presentation.exit_status == 2
    assert presentation.stderr =~ "arguments/conflicting_arguments"
    assert presentation.stderr =~ "--private-output"
    assert presentation.stderr =~ "--envelope"
    refute File.exists?(output)
  end

  test "an invalid envelope destination names its switch" do
    for path <- ["", "-"] do
      presentation =
        MixCommandAdapter.execute([
          "transcript",
          PrivateInspectionFixture.command_run_ref(),
          "--traces",
          "traces",
          "--inspection",
          "inspection",
          "--private-unattended",
          "--private-output",
          "transcript.json",
          "--envelope",
          path
        ])

      assert presentation.exit_status == 2
      assert presentation.stderr =~ "arguments/invalid_arguments"
      assert presentation.stderr =~ "invalid destination: --envelope"
    end
  end

  @tag :tmp_dir
  test "each --private-output rule is refused under its own code and names the rule", %{
    tmp_dir: root
  } do
    fixture = canonical_create!(root)

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
    fixture = canonical_create!(root)
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
    fixture = canonical_create!(root)

    missing_traces = Path.join(root, "missing-traces")
    missing_output = Path.join(fixture.output, "missing-traces.json")

    missing =
      MixCommandAdapter.execute(transcript_argv(fixture, missing_output, traces: missing_traces))

    assert missing.exit_status == 1
    assert missing.stderr =~ "transcript/source_unavailable"
    assert missing.stderr =~ "--traces"
    assert missing.stderr =~ "existing"
    refute missing.stderr =~ root
    refute File.exists?(missing_output)

    swapped_output = Path.join(fixture.output, "swapped-sources.json")

    swapped =
      MixCommandAdapter.execute(
        transcript_argv(fixture, swapped_output,
          traces: fixture.inspection,
          inspection: fixture.traces
        )
      )

    assert swapped.exit_status == 1
    assert swapped.stderr =~ "transcript/selected_trace_missing"
    assert swapped.stderr =~ "RUN_ID"
    assert swapped.stderr =~ "--traces"
    refute swapped.stderr =~ fixture.run_id
    refute swapped.stderr =~ root
    refute File.exists?(swapped_output)
  end

  @tag :tmp_dir
  test "a noncanonical RUN_ID is refused before path derivation", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    output = Path.join(fixture.output, "noncanonical-run.json")

    presentation =
      MixCommandAdapter.execute(
        transcript_argv(fixture, output, run_id: "caller-private-unknown-run")
      )

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/invalid_run_reference"
    assert presentation.stderr =~ "RUN_ID"
    assert presentation.stderr =~ "canonical PTC command run reference"
    refute presentation.stderr =~ "caller-private-unknown-run"
    refute presentation.stderr =~ root
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a traversal-shaped RUN_ID is refused before path derivation", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    output = Path.join(fixture.output, "traversal-run.json")
    selector = "../#{fixture.run_id}"

    presentation =
      MixCommandAdapter.execute(transcript_argv(fixture, output, run_id: selector))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/invalid_run_reference"
    assert presentation.stderr =~ "RUN_ID"
    refute presentation.stderr =~ selector
    refute presentation.stderr =~ ".."
    refute presentation.stderr =~ root
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a missing selected canonical pair names the absent source", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    missing = PrivateInspectionFixture.command_run_ref(1)
    output = Path.join(fixture.output, "missing-selected.json")

    presentation =
      MixCommandAdapter.execute(transcript_argv(fixture, output, run_id: missing))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/selected_trace_missing"
    assert presentation.stderr =~ "RUN_ID"
    assert presentation.stderr =~ "--traces"
    refute presentation.stderr =~ missing
    refute presentation.stderr =~ root
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "reports a non-V1 private artifact as malformed without a legacy reader", %{
    tmp_dir: root
  } do
    fixture = canonical_create!(root)
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
    assert presentation.stderr =~ "error: transcript/malformed_source:"
    assert presentation.stderr =~ "selected transcript source is malformed"
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "preserves capture-time source changes without publishing output", %{tmp_dir: root} do
    fixture = canonical_create!(root)
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
    fixture = canonical_create!(root)
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
    [inspection_path] = Path.wildcard(Path.join(fixture.inspection, "*.ptcins"))

    assert {:error, :source_changed, "analysis source changed during capture"} =
             TranscriptFrontend.run(entry.arguments, CommandRuntime.standalone(),
               inspection_artifact_verification_hook: fn ->
                 File.write!(inspection_path, "\n", [:append])
               end
             )

    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a pinned selected inspection survives path removal during admission", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    output = Path.join(fixture.output, "removed-inspection.json")
    argv = transcript_argv(fixture, output)
    assert {:ok, entry} = CommandEntry.open(argv, :standalone)
    inspection_path = Path.join(fixture.inspection, "#{fixture.run_id}.ptcins")

    assert {:ok, _result} =
             TranscriptFrontend.run(entry.arguments, CommandRuntime.standalone(),
               inspection_artifact_verification_hook: fn -> File.rm!(inspection_path) end
             )

    assert File.regular?(output)
    refute File.exists?(inspection_path)
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

  @tag :tmp_dir
  test "unrelated mixed history is not listed or admitted for a selected run", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    extra = PrivateInspectionFixture.create!(Path.join(root, "extra"), "trace-only-history")

    File.cp!(
      Path.join(extra.traces, "trace-only-history.jsonl"),
      Path.join(fixture.traces, "trace-only-history.jsonl")
    )

    File.write!(Path.join(fixture.traces, "broken.jsonl"), "{not-json\n")

    File.write!(
      Path.join(fixture.inspection, "broken.ptcins"),
      ~s({"schema_version":4}\n)
    )

    File.write!(Path.join(fixture.traces, "oversized.jsonl"), :binary.copy("x", 9_000_001))

    test_pid = self()
    listed = fn -> send(test_pid, :listed) end
    output = Path.join(fixture.output, "selected-mixed.private.json")

    assert {:ok, entry} = CommandEntry.open(transcript_argv(fixture, output), :standalone)

    assert {:ok, _result} =
             TranscriptFrontend.run(entry.arguments, CommandRuntime.standalone(),
               listing_hook: listed,
               inspection_listing_hook: listed
             )

    assert %{"run_id" => run_id} = output |> File.read!() |> Jason.decode!()
    assert run_id == fixture.run_id
    refute_received :listed
  end

  @tag :tmp_dir
  test "a selected healthy run ignores an adjacent legacy-cost artifact", %{tmp_dir: root} do
    healthy = canonical_create!(root)
    damaged_run_id = PrivateInspectionFixture.command_run_ref(1)

    damaged =
      PrivateInspectionFixture.create!(Path.join(root, "damaged"), damaged_run_id)

    PrivateInspectionFixture.rewrite_legacy_float_cost!(damaged)

    File.cp!(
      Path.join(damaged.traces, "#{damaged_run_id}.jsonl"),
      Path.join(healthy.traces, "#{damaged_run_id}.jsonl")
    )

    File.cp!(
      Path.join(damaged.inspection, "#{damaged_run_id}.ptcins"),
      Path.join(healthy.inspection, "#{damaged_run_id}.ptcins")
    )

    output = Path.join(healthy.output, "healthy-among-damaged.private.json")
    presentation = MixCommandAdapter.execute(transcript_argv(healthy, output))

    assert presentation.exit_status == 0
    assert presentation.stderr == ""
    assert %{"run_id" => run_id} = output |> File.read!() |> Jason.decode!()
    assert run_id == healthy.run_id

    damaged_output = Path.join(healthy.output, "damaged.private.json")

    damaged_presentation =
      MixCommandAdapter.execute(transcript_argv(healthy, damaged_output, run_id: damaged_run_id))

    assert damaged_presentation.exit_status == 1
    assert damaged_presentation.stderr =~ "transcript/malformed_source"
    refute File.exists?(damaged_output)
  end

  @tag :tmp_dir
  test "the private canonical trace suffix works when it is the only candidate", %{tmp_dir: root} do
    fixture = canonical_create!(root)

    File.rename!(
      Path.join(fixture.traces, "#{fixture.run_id}.jsonl"),
      Path.join(fixture.traces, "#{fixture.run_id}.private.jsonl")
    )

    output = Path.join(fixture.output, "private-candidate.private.json")
    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 0
    assert %{"run_id" => run_id} = output |> File.read!() |> Jason.decode!()
    assert run_id == fixture.run_id
  end

  @tag :tmp_dir
  test "both canonical trace candidates fail closed as ambiguous", %{tmp_dir: root} do
    fixture = canonical_create!(root)

    File.cp!(
      Path.join(fixture.traces, "#{fixture.run_id}.jsonl"),
      Path.join(fixture.traces, "#{fixture.run_id}.private.jsonl")
    )

    output = Path.join(fixture.output, "ambiguous-candidates.json")
    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/ambiguous_selected_trace"
    assert presentation.stderr =~ "RUN_ID"
    assert presentation.stderr =~ "--traces"
    refute presentation.stderr =~ fixture.run_id
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a missing selected inspection is distinct from a missing selected trace", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    File.rm!(Path.join(fixture.inspection, "#{fixture.run_id}.ptcins"))
    output = Path.join(fixture.output, "missing-inspection.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/selected_inspection_missing"
    assert presentation.stderr =~ "RUN_ID"
    assert presentation.stderr =~ "--inspection"
    refute presentation.stderr =~ "selected_trace_missing"
    refute presentation.stderr =~ fixture.run_id
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a selected symlink is refused without disclosing the path", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    real = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")
    linked = Path.join(root, "linked.jsonl")
    File.rename!(real, linked)
    File.ln_s!(linked, real)
    output = Path.join(fixture.output, "symlink-trace.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/selected_trace_not_regular"
    assert presentation.stderr =~ "--traces"
    refute presentation.stderr =~ linked
    refute presentation.stderr =~ fixture.run_id
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "embedded run identity remains authoritative over the selected filename", %{tmp_dir: root} do
    embedded = canonical_create!(root, 1)
    selector = PrivateInspectionFixture.command_run_ref(2)

    File.rename!(
      Path.join(embedded.traces, "#{embedded.run_id}.jsonl"),
      Path.join(embedded.traces, "#{selector}.jsonl")
    )

    File.rename!(
      Path.join(embedded.inspection, "#{embedded.run_id}.ptcins"),
      Path.join(embedded.inspection, "#{selector}.ptcins")
    )

    output = Path.join(embedded.output, "mismatch.json")

    presentation =
      MixCommandAdapter.execute(transcript_argv(embedded, output, run_id: selector))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/selected_run_mismatch"
    assert presentation.stderr =~ "RUN_ID"
    refute presentation.stderr =~ selector
    refute presentation.stderr =~ embedded.run_id
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a malformed selected trace fails without publishing output", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    File.write!(Path.join(fixture.traces, "#{fixture.run_id}.jsonl"), "{not-json\n")
    output = Path.join(fixture.output, "malformed-selected.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/malformed_source"
    refute presentation.stderr =~ fixture.run_id
    refute presentation.stderr =~ root
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a malformed selected inspection fails without publishing output", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    File.write!(Path.join(fixture.inspection, "#{fixture.run_id}.ptcins"), "not-json\n")
    output = Path.join(fixture.output, "malformed-inspection.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/malformed_source"
    refute presentation.stderr =~ fixture.run_id
    refute presentation.stderr =~ root
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a selected inspection symlink is refused without disclosing the path", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    real = Path.join(fixture.inspection, "#{fixture.run_id}.ptcins")
    linked = Path.join(root, "linked.ptcins")
    File.rename!(real, linked)
    File.ln_s!(linked, real)
    output = Path.join(fixture.output, "symlink-inspection.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/selected_inspection_not_regular"
    assert presentation.stderr =~ "--inspection"
    refute presentation.stderr =~ linked
    refute presentation.stderr =~ fixture.run_id
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "an unsupported selected trace schema fails without publishing output", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")

    rewritten =
      path
      |> File.stream!()
      |> Enum.map_join(fn line ->
        line
        |> Jason.decode!()
        |> Map.put("schema_version", 3)
        |> Jason.encode!()
        |> Kernel.<>("\n")
      end)

    File.write!(path, rewritten)
    output = Path.join(fixture.output, "unsupported-trace.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/unsupported_schema"
    refute presentation.stderr =~ fixture.run_id
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "a selected correlation mismatch fails without disclosing identities", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    path = Path.join(fixture.inspection, "#{fixture.run_id}.ptcins")

    {:ok, records} = StreamingInspection.read_path(path)
    rewritten = Enum.map(records, &Map.put(&1, "trace_id", "trace-unrelated"))
    StreamingInspection.rewrite_path(path, rewritten)
    output = Path.join(fixture.output, "correlation-mismatch.json")

    presentation = MixCommandAdapter.execute(transcript_argv(fixture, output))

    assert presentation.exit_status == 1
    assert presentation.stderr =~ "transcript/inspection_correlation_missing"
    refute presentation.stderr =~ "trace-unrelated"
    refute presentation.stderr =~ fixture.run_id
    refute presentation.stderr =~ root
    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "truncating the selected trace during capture fails closed", %{tmp_dir: root} do
    fixture = canonical_create!(root)
    output = Path.join(fixture.output, "truncated-selected.json")
    argv = transcript_argv(fixture, output)
    assert {:ok, entry} = CommandEntry.open(argv, :standalone)
    trace_path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")

    assert {:error, :source_changed, "analysis source changed during capture"} =
             TranscriptFrontend.run(entry.arguments, CommandRuntime.standalone(),
               capture_hook: fn ->
                 content = File.read!(trace_path)
                 File.write!(trace_path, binary_part(content, 0, div(byte_size(content), 2)))
               end
             )

    refute File.exists?(output)
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

  defp assert_ungated_repl_hint(message) do
    assert message =~
             "The same reconstruction is ungated in ptc repl --profile private-run-analysis-v2"

    assert message =~ "ptc docs repl"
    refute message =~ "/api/"
    refute message =~ "Viewer"
  end
end
