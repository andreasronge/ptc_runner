defmodule PtcRunner.Kernel.SelectedCanonicalSourceTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.SelectedCanonicalSource
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  test "validates and canonically orders a bounded selected run set" do
    first = PrivateInspectionFixture.command_run_ref(1)
    second = PrivateInspectionFixture.command_run_ref(2)

    assert {:ok, [^first, ^second]} =
             SelectedCanonicalSource.validate_run_refs([second, first])

    assert {:error, :invalid_run_reference} =
             SelectedCanonicalSource.validate_run_refs([first, "not-a-command-run"])

    assert {:error, :duplicate_selected_run} =
             SelectedCanonicalSource.validate_run_refs([first, first])

    oversized = Enum.map(1..17, &PrivateInspectionFixture.command_run_ref/1)

    assert {:error, :selected_set_limit_exceeded} =
             SelectedCanonicalSource.validate_run_refs(oversized)
  end

  @tag :tmp_dir
  test "resolves exactly one normal or private trace candidate without listing", %{tmp_dir: root} do
    run_ref = PrivateInspectionFixture.command_run_ref()
    traces = Path.join(root, "traces")
    File.mkdir!(traces)
    File.touch!(Path.join(traces, "#{run_ref}.jsonl"))
    File.touch!(Path.join(traces, "unrelated.jsonl"))

    expected = Path.expand(Path.join(traces, "#{run_ref}.jsonl"))

    # Resolution constructs exact paths; listing the directory would fail here.
    File.chmod!(traces, 0o111)

    try do
      assert {:error, :eacces} = File.ls(traces)

      assert {:ok, {:file, ^expected, ^run_ref}} =
               SelectedCanonicalSource.resolve_trace(traces, run_ref)
    after
      File.chmod!(traces, 0o700)
    end

    File.rm!(expected)
    File.touch!(Path.join(traces, "#{run_ref}.private.jsonl"))

    assert {:ok, {:private_authorized_file, private, ^run_ref}} =
             SelectedCanonicalSource.resolve_trace(traces, run_ref)

    assert Path.basename(private) == "#{run_ref}.private.jsonl"
  end

  @tag :tmp_dir
  test "refuses missing, ambiguous, and non-regular selected traces", %{tmp_dir: root} do
    run_ref = PrivateInspectionFixture.command_run_ref()
    traces = Path.join(root, "traces")
    File.mkdir!(traces)

    assert {:error, :selected_trace_missing} =
             SelectedCanonicalSource.resolve_trace(traces, run_ref)

    File.touch!(Path.join(traces, "#{run_ref}.jsonl"))
    File.touch!(Path.join(traces, "#{run_ref}.private.jsonl"))

    assert {:error, :ambiguous_selected_trace} =
             SelectedCanonicalSource.resolve_trace(traces, run_ref)

    File.rm!(Path.join(traces, "#{run_ref}.private.jsonl"))
    File.rm!(Path.join(traces, "#{run_ref}.jsonl"))
    File.mkdir!(Path.join(traces, "#{run_ref}.jsonl"))

    assert {:error, :selected_trace_not_regular} =
             SelectedCanonicalSource.resolve_trace(traces, run_ref)
  end

  @tag :tmp_dir
  test "resolves the exact inspection candidate and refuses a symlink", %{tmp_dir: root} do
    run_ref = PrivateInspectionFixture.command_run_ref()
    inspection = Path.join(root, "inspection")
    File.mkdir!(inspection)
    path = Path.join(inspection, "#{run_ref}.ptcins")
    File.touch!(path)

    assert {:ok, resolved} = SelectedCanonicalSource.resolve_inspection(inspection, run_ref)
    assert resolved == Path.expand(path)

    File.rm!(path)
    File.ln_s!(Path.join(root, "missing"), path)

    assert {:error, :selected_inspection_not_regular} =
             SelectedCanonicalSource.resolve_inspection(inspection, run_ref)
  end

  test "refuses a noncanonical selector before joining a path" do
    assert {:error, :invalid_run_reference} =
             SelectedCanonicalSource.resolve_trace("/tmp", "../cmd-00000000000000000000000000")

    assert {:error, :invalid_run_reference} =
             SelectedCanonicalSource.resolve_inspection("/tmp", "private-run")
  end

  test "proves embedded run and trace identity without disclosing a mismatch" do
    run_ref = PrivateInspectionFixture.command_run_ref()
    other = PrivateInspectionFixture.command_run_ref(1)

    events = [
      %{"run_id" => run_ref, "trace_id" => "trace-#{run_ref}"},
      %{"run_id" => run_ref, "trace_id" => "trace-#{run_ref}"}
    ]

    assert {:ok, "trace-" <> ^run_ref} =
             SelectedCanonicalSource.prove_trace_events(events, run_ref)

    assert {:error, :selected_run_mismatch} =
             SelectedCanonicalSource.prove_trace_events(
               [%{"run_id" => other, "trace_id" => "trace-#{other}"}],
               run_ref
             )
  end

  test "selected identity commits to selector, source class, digest, and trace id" do
    run_ref = PrivateInspectionFixture.command_run_ref()
    other = PrivateInspectionFixture.command_run_ref(1)

    first =
      SelectedCanonicalSource.trace_source_id(
        run_ref,
        :ptc_private_trace_snapshot,
        :sanitized,
        "digest-a",
        "trace-1"
      )

    assert first !=
             SelectedCanonicalSource.trace_source_id(
               other,
               :ptc_private_trace_snapshot,
               :sanitized,
               "digest-a",
               "trace-1"
             )

    assert first !=
             SelectedCanonicalSource.trace_source_id(
               run_ref,
               :ptc_private_trace_snapshot,
               :private,
               "digest-a",
               "trace-1"
             )

    assert first !=
             SelectedCanonicalSource.trace_source_id(
               run_ref,
               :ptc_private_trace_snapshot,
               :sanitized,
               "digest-b",
               "trace-1"
             )

    assert first !=
             SelectedCanonicalSource.trace_source_id(
               run_ref,
               :ptc_private_trace_snapshot,
               :sanitized,
               "digest-a",
               "trace-2"
             )
  end
end
