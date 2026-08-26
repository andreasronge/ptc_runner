defmodule PtcRunner.Kernel.SelectedCanonicalSnapshotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.PrivateRunAnalysisProfile
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture
  alias PtcRunner.TestSupport.StreamingInspection

  @tag :tmp_dir
  test "selected capture ignores malformed and oversized unselected members", %{tmp_dir: root} do
    fixture = fixture!(root)
    File.write!(Path.join(fixture.traces, "broken.jsonl"), "{not-json\n")
    File.write!(Path.join(fixture.traces, "huge.jsonl"), :binary.copy("x", 9_000_001))
    File.write!(Path.join(fixture.inspection, "broken.ptcins"), "not-json\n")

    test_pid = self()
    listed = fn -> send(test_pid, :listed) end

    assert {:ok, resources} =
             PrivateRunAnalysisProfile.capture(
               %{"traces" => fixture.traces, "inspection" => fixture.inspection},
               selected_run_ref: fixture.run_id,
               listing_hook: listed,
               inspection_listing_hook: listed
             )

    on_exit(fn -> AnalysisResources.stop(resources) end)
    refute_received :listed

    traces = AnalysisResources.handle(resources, :traces)
    assert {:ok, info} = TraceSnapshot.info(traces)
    assert info.file_count == 1
    assert info.run_count == 1
    assert {:ok, true} = TraceSnapshot.run_exists?(traces, fixture.run_id)
  end

  @tag :tmp_dir
  test "directory capture isolates an unrelated malformed member", %{tmp_dir: root} do
    fixture = fixture!(root)
    File.write!(Path.join(fixture.traces, "broken.jsonl"), "{not-json\n")

    assert {:ok, snapshot} =
             TraceSnapshot.start({:private_authorized_directory, fixture.traces}, owner: self())

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)
    assert {:ok, %{file_count: 2, run_count: 1}} = TraceSnapshot.info(snapshot)
    assert {:ok, true} = TraceSnapshot.run_exists?(snapshot, fixture.run_id)
    assert {:error, :run_isolated} = TraceSnapshot.run_exists?(snapshot, "broken")
  end

  @tag :tmp_dir
  test "directory inspection capture refuses a symlink member without a selected code", %{
    tmp_dir: root
  } do
    fixture = fixture!(root)
    extra = Path.join(root, "extra.ptcins")
    File.write!(extra, "not-used\n")
    File.ln_s!(extra, Path.join(fixture.inspection, "extra.ptcins"))

    assert {:ok, traces} =
             TraceSnapshot.start({:directory, fixture.traces}, owner: self())

    on_exit(fn -> TraceSnapshot.stop(traces) end)

    assert {:error, :malformed_source} =
             InspectionSnapshot.start({:directory, fixture.inspection}, traces, owner: self())
  end

  @tag :tmp_dir
  test "selected identity differs from a whole-directory snapshot of the same file", %{
    tmp_dir: root
  } do
    fixture = fixture!(root)

    assert {:ok, directory} =
             TraceSnapshot.start({:directory, fixture.traces}, owner: self())

    assert {:ok, selected} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self()
             )

    on_exit(fn ->
      TraceSnapshot.stop(directory)
      TraceSnapshot.stop(selected)
    end)

    assert {:ok, directory_info} = TraceSnapshot.info(directory)
    assert {:ok, selected_info} = TraceSnapshot.info(selected)
    assert directory_info.capture_id != selected_info.capture_id
    assert directory_info.snapshot_hash != selected_info.snapshot_hash
    assert selected_info.file_count == 1
    assert selected_info.source == :ptc_private_trace_snapshot
  end

  @tag :tmp_dir
  test "a selected private file records the private source class", %{tmp_dir: root} do
    fixture = fixture!(root)

    File.rename!(
      Path.join(fixture.traces, "#{fixture.run_id}.jsonl"),
      Path.join(fixture.traces, "#{fixture.run_id}.private.jsonl")
    )

    assert {:ok, snapshot} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self()
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)
    assert {:ok, %{source: :ptc_private_trace_snapshot}} = TraceSnapshot.info(snapshot)
  end

  @tag :tmp_dir
  test "selected inspection capture does not inventory unrelated artifacts", %{tmp_dir: root} do
    fixture = fixture!(root)
    File.write!(Path.join(fixture.inspection, "broken.ptcins"), "not-json\n")

    assert {:ok, traces} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self()
             )

    test_pid = self()
    listed = fn -> send(test_pid, :listed) end

    assert {:ok, inspection} =
             InspectionSnapshot.start(
               {:selected_canonical, fixture.inspection, fixture.run_id},
               traces,
               owner: self(),
               listing_hook: listed
             )

    on_exit(fn ->
      InspectionSnapshot.stop(inspection)
      TraceSnapshot.stop(traces)
    end)

    refute_received :listed
    assert {:ok, %{file_count: 1, run_count: 1}} = InspectionSnapshot.info(inspection)
  end

  @tag :tmp_dir
  test "owner death cancels selected file capture", %{tmp_dir: root} do
    fixture = fixture!(root)
    test = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    starter =
      Task.async(fn ->
        TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
          owner: owner,
          capture_hook: fn ->
            send(test, {:capture_paused, self()})

            receive do
              :continue_capture -> :ok
            end
          end
        )
      end)

    assert_receive {:capture_paused, capture_pid}, 5_000
    capture_ref = Process.monitor(capture_pid)
    Process.exit(owner, :kill)

    assert {:error, :snapshot_unavailable} = Task.await(starter)
    assert_receive {:DOWN, ^capture_ref, :process, ^capture_pid, :killed}, 5_000
  end

  @tag :tmp_dir
  test "an oversized selected file is refused without reading unselected members", %{
    tmp_dir: root
  } do
    fixture = fixture!(root)
    File.write!(Path.join(fixture.traces, "#{fixture.run_id}.jsonl"), :binary.copy("x", 200))
    File.write!(Path.join(fixture.traces, "unrelated.jsonl"), :binary.copy("x", 9_000_001))

    assert {:error, :source_limit_exceeded} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self(),
               max_source_bytes: 64
             )
  end

  @tag :tmp_dir
  test "selected capture refuses an alternate candidate created during capture", %{tmp_dir: root} do
    fixture = fixture!(root)
    selected = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")
    alternate = Path.join(fixture.traces, "#{fixture.run_id}.private.jsonl")

    assert {:error, :ambiguous_selected_trace} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self(),
               capture_hook: fn ->
                 File.cp!(selected, alternate)
                 :ok
               end
             )
  end

  @tag :tmp_dir
  test "selected capture detects truncation and same-size replacement", %{tmp_dir: root} do
    fixture = fixture!(root)
    path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")
    original = File.read!(path)
    test = self()

    truncated =
      Task.async(fn ->
        TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
          owner: test,
          capture_hook: fn ->
            send(test, {:capture_paused, self()})

            receive do
              :continue_capture -> :ok
            end
          end
        )
      end)

    assert_receive {:capture_paused, capture_pid}, 5_000
    File.write!(path, binary_part(original, 0, div(byte_size(original), 2)))
    send(capture_pid, :continue_capture)
    assert {:error, :source_changed} = Task.await(truncated)

    File.write!(path, original)

    replacement = String.replace(original, "2026-07-26T12:00:01Z", "2026-07-26T12:00:11Z")
    assert byte_size(replacement) == byte_size(original)
    assert replacement != original

    replaced =
      Task.async(fn ->
        TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
          owner: test,
          capture_hook: fn ->
            send(test, {:rewrite_paused, self()})

            receive do
              :continue_rewrite -> :ok
            end
          end
        )
      end)

    assert_receive {:rewrite_paused, rewrite_pid}, 5_000
    File.write!(path, replacement)
    send(rewrite_pid, :continue_rewrite)
    assert {:error, :source_changed} = Task.await(replaced)
  end

  @tag :tmp_dir
  test "an oversized selected compiled result fails closed", %{tmp_dir: root} do
    fixture = fixture!(root)

    assert {:ok, snapshot} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self(),
               max_result_bytes: 64
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:error, :result_limit_exceeded} =
             TraceSnapshot.query(snapshot, :get_run, %{"run_id" => fixture.run_id})
  end

  @tag :tmp_dir
  test "selected inspection refuses a mismatched correlated trace id", %{tmp_dir: root} do
    fixture = fixture!(root)
    path = Path.join(fixture.inspection, "#{fixture.run_id}.ptcins")

    {:ok, records} = StreamingInspection.read_path(path)
    rewritten = Enum.map(records, &Map.put(&1, "trace_id", "trace-unrelated"))
    StreamingInspection.rewrite_path(path, rewritten)

    assert {:ok, traces} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self()
             )

    on_exit(fn -> TraceSnapshot.stop(traces) end)

    assert {:error, :inspection_correlation_missing} =
             InspectionSnapshot.start(
               {:selected_canonical, fixture.inspection, fixture.run_id},
               traces,
               owner: self()
             )
  end

  @tag :tmp_dir
  test "an oversized selected inspection is refused without reading unselected members", %{
    tmp_dir: root
  } do
    fixture = fixture!(root)

    File.write!(
      Path.join(fixture.inspection, "#{fixture.run_id}.ptcins"),
      :binary.copy("x", 200)
    )

    File.write!(
      Path.join(fixture.inspection, "unrelated.ptcins"),
      :binary.copy("x", 9_000_001)
    )

    assert {:ok, traces} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self()
             )

    on_exit(fn -> TraceSnapshot.stop(traces) end)

    assert {:error, :source_limit_exceeded} =
             InspectionSnapshot.start(
               {:selected_canonical, fixture.inspection, fixture.run_id},
               traces,
               owner: self(),
               max_source_bytes: 64
             )
  end

  @tag :tmp_dir
  test "an unreadable selected inspection is unavailable rather than changed", %{tmp_dir: root} do
    fixture = fixture!(root)
    path = Path.join(fixture.inspection, "#{fixture.run_id}.ptcins")

    assert {:ok, traces} =
             TraceSnapshot.start({:selected_canonical, fixture.traces, fixture.run_id},
               owner: self()
             )

    on_exit(fn -> TraceSnapshot.stop(traces) end)
    File.chmod!(path, 0o000)

    try do
      assert {:error, :source_unavailable} =
               InspectionSnapshot.start(
                 {:selected_canonical, fixture.inspection, fixture.run_id},
                 traces,
                 owner: self()
               )
    after
      File.chmod!(path, 0o600)
    end
  end

  @tag :tmp_dir
  test "selected capture admits an execute-only directory that cannot be listed", %{tmp_dir: root} do
    fixture = fixture!(root)
    File.chmod!(fixture.traces, 0o111)
    File.chmod!(fixture.inspection, 0o111)

    try do
      assert {:error, :eacces} = File.ls(fixture.traces)
      assert {:error, :eacces} = File.ls(fixture.inspection)

      assert {:ok, resources} =
               PrivateRunAnalysisProfile.capture(
                 %{"traces" => fixture.traces, "inspection" => fixture.inspection},
                 selected_run_ref: fixture.run_id
               )

      on_exit(fn -> AnalysisResources.stop(resources) end)
      traces = AnalysisResources.handle(resources, :traces)
      assert {:ok, true} = TraceSnapshot.run_exists?(traces, fixture.run_id)
    after
      File.chmod!(fixture.traces, 0o700)
      File.chmod!(fixture.inspection, 0o700)
    end
  end

  defp fixture!(root) do
    PrivateInspectionFixture.create!(root, PrivateInspectionFixture.command_run_ref())
  end
end
