defmodule PtcRunner.Kernel.SelectedCanonicalSetSnapshotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.InspectionArtifact.Indexes
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.PrivateRunAnalysisProfile
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @tag :tmp_dir
  test "captures a sorted mixed-source cohort without listing or opening unselected artifacts", %{
    tmp_dir: root
  } do
    {first, second} = cohort!(root)

    File.rename!(
      trace_path(second),
      Path.join(second.traces, "#{second.run_id}.private.jsonl")
    )

    File.write!(Path.join(first.traces, "unselected.jsonl"), "{malformed\n")
    File.cp!(inspection_path(first), Path.join(first.inspection, "unselected.ptcins"))

    test_pid = self()
    listed = fn -> send(test_pid, :listed) end

    assert {:ok, resources} =
             PrivateRunAnalysisProfile.capture(
               %{"traces" => first.traces, "inspection" => first.inspection},
               selected_run_refs: [second.run_id, first.run_id],
               listing_hook: listed,
               inspection_listing_hook: listed
             )

    on_exit(fn -> AnalysisResources.stop(resources) end)
    refute_received :listed

    traces = AnalysisResources.handle(resources, :traces)
    inspection = AnalysisResources.handle(resources, :inspection)

    assert {:ok, %{file_count: 2, run_count: 2}} = TraceSnapshot.info(traces)
    assert {:ok, %{file_count: 2, run_count: 2}} = InspectionSnapshot.info(inspection)
    assert {:ok, true} = TraceSnapshot.run_exists?(traces, first.run_id)
    assert {:ok, true} = TraceSnapshot.run_exists?(traces, second.run_id)
  end

  @tag :tmp_dir
  test "selected-set identity is argument-order independent and distinct for the one-run set", %{
    tmp_dir: root
  } do
    {first, second} = cohort!(root)

    assert {:ok, forward} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self()
             )

    assert {:ok, reverse} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [second.run_id, first.run_id]},
               owner: self()
             )

    assert {:ok, singleton_set} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id]},
               owner: self()
             )

    assert {:ok, singular} =
             TraceSnapshot.start({:selected_canonical, first.traces, first.run_id}, owner: self())

    on_exit(fn ->
      Enum.each([forward, reverse, singleton_set, singular], &TraceSnapshot.stop/1)
    end)

    assert {:ok, forward_info} = TraceSnapshot.info(forward)
    assert {:ok, reverse_info} = TraceSnapshot.info(reverse)
    assert {:ok, singleton_info} = TraceSnapshot.info(singleton_set)
    assert {:ok, singular_info} = TraceSnapshot.info(singular)

    assert forward_info.snapshot_hash == reverse_info.snapshot_hash
    assert singleton_info.snapshot_hash != singular_info.snapshot_hash
  end

  @tag :tmp_dir
  test "trace and inspection source byte ceilings are aggregate across the selected set", %{
    tmp_dir: root
  } do
    {first, second} = cohort!(root)
    trace_limit = File.stat!(trace_path(first)).size + File.stat!(trace_path(second)).size - 1

    assert {:error, :source_limit_exceeded} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self(),
               max_source_bytes: trace_limit
             )

    assert {:error, :source_limit_exceeded} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self(),
               max_trace_files: 1
             )

    assert {:ok, traces} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self()
             )

    on_exit(fn -> TraceSnapshot.stop(traces) end)

    inspection_limit =
      File.stat!(inspection_path(first)).size + File.stat!(inspection_path(second)).size - 1

    assert {:error, :source_limit_exceeded} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self(),
               max_source_bytes: inspection_limit
             )

    assert {:error, :source_limit_exceeded} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self(),
               max_files: 1
             )
  end

  @tag :tmp_dir
  test "the inspection record ceiling remains per artifact in one shared selected-set admission",
       %{
         tmp_dir: root
       } do
    first_run = PrivateInspectionFixture.command_run_ref(11)
    second_run = PrivateInspectionFixture.command_run_ref(12)

    first =
      PrivateInspectionFixture.create_result!(
        Path.join(root, "first"),
        %{"value" => 1},
        first_run
      )

    second_source =
      PrivateInspectionFixture.create_result!(
        Path.join(root, "second"),
        %{"value" => 2},
        second_run
      )

    File.cp!(trace_path(second_source), Path.join(first.traces, "#{second_run}.jsonl"))

    File.cp!(
      inspection_path(second_source),
      Path.join(first.inspection, "#{second_run}.ptcins")
    )

    second = %{second_source | traces: first.traces, inspection: first.inspection}

    assert {:ok, traces} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self()
             )

    assert {:ok, inspection} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self(),
               limits: [max_records: 1]
             )

    on_exit(fn ->
      InspectionSnapshot.stop(inspection)
      TraceSnapshot.stop(traces)
    end)

    assert {:ok, %{run_count: 2}} = InspectionSnapshot.info(inspection)
  end

  @tag :tmp_dir
  test "duplicate selected inspection identity fails while an unselected duplicate is invisible",
       %{
         tmp_dir: root
       } do
    {first, second} = cohort!(root)

    assert {:ok, traces} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self()
             )

    on_exit(fn -> TraceSnapshot.stop(traces) end)

    unselected = PrivateInspectionFixture.command_run_ref(99)
    File.cp!(inspection_path(first), Path.join(first.inspection, "#{unselected}.ptcins"))

    assert {:ok, selected} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self()
             )

    InspectionSnapshot.stop(selected)
    File.cp!(inspection_path(first), inspection_path(second))

    assert {:error, :duplicate_inspection_run} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self()
             )
  end

  @tag :tmp_dir
  test "combined capture refuses alternate trace creation and inspection path replacement", %{
    tmp_dir: root
  } do
    {first, second} = cohort!(root)
    alternate = Path.join(first.traces, "#{second.run_id}.private.jsonl")

    assert {:error, :ambiguous_selected_trace} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self(),
               capture_hook: fn ->
                 File.cp!(trace_path(second), alternate)
                 :ok
               end
             )

    File.rm!(alternate)

    assert {:ok, traces} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self()
             )

    on_exit(fn -> TraceSnapshot.stop(traces) end)
    path = inspection_path(second)
    replacement = Path.join(root, "replacement.ptcins")

    assert {:error, :source_changed} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self(),
               capture_hook: fn ->
                 File.rename!(path, replacement)
                 File.cp!(replacement, path)
                 :ok
               end
             )
  end

  @tag :tmp_dir
  test "combined capture detects selected truncation and embedded identity mismatch", %{
    tmp_dir: root
  } do
    {first, second} = cohort!(root)
    run_refs = [first.run_id, second.run_id]
    path = trace_path(second)
    original = File.read!(path)
    test_pid = self()

    starter =
      Task.async(fn ->
        TraceSnapshot.start({:selected_canonical_set, first.traces, run_refs},
          owner: test_pid,
          capture_hook: fn -> pause(test_pid, :trace_truncation_paused) end
        )
      end)

    assert_receive {:trace_truncation_paused, capture_pid}, 5_000
    File.write!(path, binary_part(original, 0, div(byte_size(original), 2)))
    send(capture_pid, :continue)
    assert {:error, :source_changed} = Task.await(starter)
    File.write!(path, original)

    backup = Path.join(root, "selected-trace-backup.jsonl")

    assert {:error, :source_changed} =
             TraceSnapshot.start({:selected_canonical_set, first.traces, run_refs},
               owner: self(),
               capture_hook: fn ->
                 File.rename!(path, backup)
                 File.mkdir!(path)
                 :ok
               end
             )

    File.rmdir!(path)
    File.rename!(backup, path)

    third =
      PrivateInspectionFixture.create!(
        Path.join(root, "third"),
        PrivateInspectionFixture.command_run_ref(3)
      )

    File.cp!(inspection_path(third), inspection_path(second))

    assert {:ok, traces} =
             TraceSnapshot.start({:selected_canonical_set, first.traces, run_refs}, owner: self())

    on_exit(fn -> TraceSnapshot.stop(traces) end)

    assert {:error, :selected_run_mismatch} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, run_refs},
               traces,
               owner: self()
             )
  end

  @tag :tmp_dir
  test "selected malformed, duplicate-identity, and foreign-version traces fail closed", %{
    tmp_dir: root
  } do
    malformed_root = Path.join(root, "malformed")
    {malformed_first, malformed_second} = cohort!(malformed_root)
    File.write!(trace_path(malformed_second), "{malformed\n")

    assert {:error, :malformed_source} =
             TraceSnapshot.start(
               {:selected_canonical_set, malformed_first.traces,
                [malformed_first.run_id, malformed_second.run_id]},
               owner: self()
             )

    duplicate_root = Path.join(root, "duplicate")
    {duplicate_first, duplicate_second} = cohort!(duplicate_root)
    File.cp!(trace_path(duplicate_first), trace_path(duplicate_second))

    assert {:ok, disambiguated} =
             TraceSnapshot.start(
               {:selected_canonical_set, duplicate_first.traces, [duplicate_first.run_id]},
               owner: self()
             )

    TraceSnapshot.stop(disambiguated)

    assert {:error, :selected_run_mismatch} =
             TraceSnapshot.start(
               {:selected_canonical_set, duplicate_first.traces,
                [duplicate_first.run_id, duplicate_second.run_id]},
               owner: self()
             )

    version_root = Path.join(root, "version")
    {version_first, version_second} = cohort!(version_root)
    rewrite_trace_schema!(trace_path(version_second), 999)

    assert {:error, :unsupported_schema} =
             PrivateRunAnalysisProfile.capture(
               %{"traces" => version_first.traces, "inspection" => version_first.inspection},
               selected_run_refs: [version_first.run_id, version_second.run_id]
             )
  end

  @tag :tmp_dir
  test "selected foreign inspection version is unsupported while corrupt evidence is malformed",
       %{
         tmp_dir: root
       } do
    {first, second} = cohort!(root)

    assert {:ok, traces} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, [first.run_id, second.run_id]},
               owner: self()
             )

    on_exit(fn -> TraceSnapshot.stop(traces) end)
    path = inspection_path(second)
    rewrite_inspection_schema!(path, 999)

    assert {:error, :unsupported_schema} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self()
             )

    <<header::binary-size(16), _current_footer_and_evidence::binary>> = File.read!(path)
    File.write!(path, header <> "foreign-layout-without-a-current-footer")

    assert {:error, :unsupported_schema} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self()
             )

    File.write!(path, "malformed")

    assert {:error, :malformed_source} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, [first.run_id, second.run_id]},
               traces,
               owner: self()
             )
  end

  @tag :tmp_dir
  test "trace retention and inspection index ceilings are aggregate across the selected set", %{
    tmp_dir: root
  } do
    {first, second} = cohort!(root)
    run_refs = [first.run_id, second.run_id]

    trace_retained =
      Enum.map(run_refs, fn run_ref ->
        assert {:ok, snapshot} =
                 TraceSnapshot.start(
                   {:selected_canonical_set, first.traces, [run_ref]},
                   owner: self()
                 )

        assert {:ok, %{retained_bytes: retained_bytes}} = TraceSnapshot.info(snapshot)
        TraceSnapshot.stop(snapshot)
        retained_bytes
      end)
      |> Enum.max()

    assert {:error,
            {:source_retained_limit_exceeded,
             %{source: :ptc_private_trace_snapshot, limit_bytes: ^trace_retained}}} =
             TraceSnapshot.start(
               {:selected_canonical_set, first.traces, run_refs},
               owner: self(),
               max_retained_bytes: trace_retained
             )

    assert {:ok, traces} =
             TraceSnapshot.start({:selected_canonical_set, first.traces, run_refs}, owner: self())

    on_exit(fn -> TraceSnapshot.stop(traces) end)

    accounting =
      Enum.map(run_refs, &singleton_accounting!(first.inspection, &1, traces))
      |> Enum.reduce(fn right, left ->
        %{
          logical_entries: max(left.logical_entries, right.logical_entries),
          logical_bytes: max(left.logical_bytes, right.logical_bytes),
          charged_retained_bytes: max(left.charged_retained_bytes, right.charged_retained_bytes)
        }
      end)

    assert {:error, :max_index_entries} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, run_refs},
               traces,
               owner: self(),
               limits: [max_index_entries: accounting.logical_entries]
             )

    assert {:error, :max_logical_index_bytes} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, run_refs},
               traces,
               owner: self(),
               limits: [max_logical_index_bytes: accounting.logical_bytes]
             )

    assert {:error,
            {:source_retained_limit_exceeded,
             %{source: :ptc_inspection_snapshot, limit_bytes: retained_limit}}} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, run_refs},
               traces,
               owner: self(),
               max_retained_bytes: accounting.charged_retained_bytes
             )

    assert retained_limit == accounting.charged_retained_bytes
  end

  @tag :tmp_dir
  test "owner death cancels combined trace capture and inspection admission", %{tmp_dir: root} do
    {first, second} = cohort!(root)
    test_pid = self()
    run_refs = [first.run_id, second.run_id]

    trace_owner = waiting_owner()

    trace_starter =
      Task.async(fn ->
        TraceSnapshot.start({:selected_canonical_set, first.traces, run_refs},
          owner: trace_owner,
          capture_hook: fn -> pause(test_pid, :trace_capture_paused) end
        )
      end)

    assert_receive {:trace_capture_paused, capture_pid}, 5_000
    capture_ref = Process.monitor(capture_pid)
    Process.exit(trace_owner, :kill)
    assert {:error, :snapshot_unavailable} = Task.await(trace_starter)
    assert_receive {:DOWN, ^capture_ref, :process, ^capture_pid, _reason}, 5_000

    assert {:ok, traces} =
             TraceSnapshot.start({:selected_canonical_set, first.traces, run_refs}, owner: self())

    on_exit(fn -> TraceSnapshot.stop(traces) end)
    inspection_owner = waiting_owner()

    inspection_starter =
      Task.async(fn ->
        InspectionSnapshot.start(
          {:selected_canonical_set, first.inspection, run_refs},
          traces,
          owner: inspection_owner,
          admission_hook: fn :before_frames -> pause(test_pid, :inspection_admission_paused) end
        )
      end)

    assert_receive {:inspection_admission_paused, admission_pid}, 5_000
    admission_ref = Process.monitor(admission_pid)
    Process.exit(inspection_owner, :kill)
    assert {:error, :snapshot_unavailable} = Task.await(inspection_starter)
    assert_receive {:DOWN, ^admission_ref, :process, ^admission_pid, _reason}, 5_000
  end

  @tag :tmp_dir
  test "failure after partial selected admission deletes every shared index table", %{
    tmp_dir: root
  } do
    {first, second} = cohort!(root)
    run_refs = [first.run_id, second.run_id]

    assert {:ok, traces} =
             TraceSnapshot.start({:selected_canonical_set, first.traces, run_refs}, owner: self())

    on_exit(fn -> TraceSnapshot.stop(traces) end)
    test_pid = self()

    hook = fn
      :before_frames ->
        count = Process.get(:selected_admission_count, 0) + 1
        Process.put(:selected_admission_count, count)

        if count == 2 do
          owned_tables =
            :ets.all()
            |> Enum.flat_map(fn table ->
              try do
                if :ets.info(table, :owner) == self(),
                  do: [{table, :ets.info(table, :size)}],
                  else: []
              catch
                _kind, _reason -> []
              end
            end)

          send(test_pid, {:partial_indexes, owned_tables})
          {:error, :malformed_source}
        else
          :ok
        end

      _checkpoint ->
        :ok
    end

    assert {:error, :malformed_source} =
             InspectionSnapshot.start(
               {:selected_canonical_set, first.inspection, run_refs},
               traces,
               owner: self(),
               admission_hook: hook
             )

    assert_received {:partial_indexes, tables}
    assert length(tables) >= 13
    assert Enum.any?(tables, fn {_table, size} -> size > 0 end)
    assert Enum.all?(tables, fn {table, _size} -> :ets.info(table) == :undefined end)
  end

  defp cohort!(root) do
    first_run = PrivateInspectionFixture.command_run_ref(1)
    second_run = PrivateInspectionFixture.command_run_ref(2)
    first = PrivateInspectionFixture.create!(Path.join(root, "first"), first_run)
    second_source = PrivateInspectionFixture.create!(Path.join(root, "second"), second_run)
    File.cp!(trace_path(second_source), Path.join(first.traces, "#{second_run}.jsonl"))

    File.cp!(
      inspection_path(second_source),
      Path.join(first.inspection, "#{second_run}.ptcins")
    )

    second = %{second_source | traces: first.traces, inspection: first.inspection}
    {first, second}
  end

  defp trace_path(fixture), do: Path.join(fixture.traces, "#{fixture.run_id}.jsonl")

  defp inspection_path(fixture),
    do: Path.join(fixture.inspection, "#{fixture.run_id}.ptcins")

  defp rewrite_trace_schema!(path, schema_version) do
    rewritten =
      path
      |> File.stream!()
      |> Enum.map_join("\n", fn line ->
        line |> Jason.decode!() |> Map.put("schema_version", schema_version) |> Jason.encode!()
      end)

    File.write!(path, rewritten <> "\n")
  end

  defp rewrite_inspection_schema!(path, schema_version) do
    bytes = File.read!(path)
    footer_offset = byte_size(bytes) - 192

    <<header_magic::binary-size(8), format::unsigned-big-16, _schema::unsigned-big-16,
      header_rest::binary-size(4), body::binary-size(^footer_offset - 16),
      footer_magic::binary-size(8), footer_format::unsigned-big-16,
      _footer_schema::unsigned-big-16, footer_rest::binary>> = bytes

    File.write!(
      path,
      <<header_magic::binary, format::unsigned-big-16, schema_version::unsigned-big-16,
        header_rest::binary, body::binary, footer_magic::binary, footer_format::unsigned-big-16,
        schema_version::unsigned-big-16, footer_rest::binary>>
    )
  end

  defp singleton_accounting!(directory, run_ref, traces) do
    assert {:ok, snapshot} =
             InspectionSnapshot.start(
               {:selected_canonical_set, directory, [run_ref]},
               traces,
               owner: self()
             )

    accounting = snapshot.pid |> :sys.get_state() |> Map.fetch!(:indexes) |> Indexes.accounting()
    InspectionSnapshot.stop(snapshot)
    accounting
  end

  defp waiting_owner do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp pause(test_pid, message) do
    send(test_pid, {message, self()})

    receive do
      :continue -> :ok
    end
  end
end
