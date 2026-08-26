defmodule PtcRunner.Kernel.InspectionSinkTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.InspectionArtifact.Indexes
  alias PtcRunner.Kernel.InspectionArtifact.Limits
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  test "production format and admission maxima are exact" do
    assert %{
             max_record_bytes: 2_000_000,
             max_evidence_bytes: 536_870_912,
             max_artifact_bytes: 536_871_120,
             default_max_records: 16_384,
             maintained_max_records: 65_536,
             max_retained_bytes: 128_000_000
           } = InspectionArtifact.format_contract()

    assert {:ok, %{max_records: 65_536}} = Limits.merge(max_records: 65_536)
    assert {:error, :invalid_limits} = Limits.merge(max_records: 65_537)
    assert {:ok, %{max_record_bytes: 2_000_000}} = Limits.merge(max_record_bytes: 2_000_000)
    assert {:error, :invalid_limits} = Limits.merge(max_record_bytes: 2_000_001)

    assert {:ok, %{max_total_bytes: 536_870_912}} =
             Limits.merge(max_total_bytes: 536_870_912)

    assert {:error, :invalid_limits} = Limits.merge(max_total_bytes: 536_870_913)
    assert {:ok, %{cleanup_deadline_ms: 5_000}} = Limits.merge(cleanup_deadline_ms: 5_000)
    assert {:error, :invalid_limits} = Limits.merge(cleanup_deadline_ms: 5_001)
  end

  @tag :tmp_dir
  test "streams the V1 header, framed evidence, and sealed footer to the reservation", %{
    tmp_dir: root
  } do
    path = Path.join(root, "streamed.ptcins")
    {sink, handle} = start_sink!(path, max_records: 3)

    assert :ok = emit_prints(sink, "evaluation-1", ["private output"])
    refute File.exists?(path)
    refute function_exported?(InspectionSink, :records, 1)

    assert {:ok, seal} = InspectionSink.seal(sink)
    assert seal.record_count == 1
    assert seal.evidence_bytes > 8
    assert seal.total_bytes == 16 + seal.evidence_bytes + 192
    assert :ok = InspectionArtifact.publish_handle(handle, seal)
    assert :ok = InspectionSink.stop(sink)

    bytes = File.read!(path)
    assert binary_part(bytes, 0, 16) == Format.encode_header()
    footer = binary_part(bytes, byte_size(bytes) - 192, 192)
    assert {:ok, decoded} = Format.decode_footer(footer)
    assert decoded.total_bytes == byte_size(bytes)
    assert decoded.record_count == 1
    assert decoded.first_sequence == 1
    assert decoded.last_sequence == 1
    assert decoded.artifact_digest == seal.artifact_digest
  end

  @tag :tmp_dir
  test "writer failure cannot publish a partial destination", %{tmp_dir: root} do
    path = Path.join(root, "partial.ptcins")

    hook = fn
      :before_footer -> {:error, :injected}
      _stage -> :ok
    end

    {sink, _handle} = start_sink!(path, writer_hook: hook)
    assert :ok = emit_prints(sink, "evaluation-1", [])
    assert {:error, :inspection_sink_error} = InspectionSink.seal(sink)
    refute File.exists?(path)
    assert :ok = InspectionSink.stop(sink)
  end

  @tag :tmp_dir
  test "publication re-authenticates the synchronized staging bytes", %{tmp_dir: root} do
    path = Path.join(root, "mutated-before-publication.ptcins")
    {sink, handle} = start_sink!(path, [])
    assert :ok = emit_prints(sink, "evaluation-1", ["private output"])
    assert {:ok, seal} = InspectionSink.seal(sink)

    hook = fn :before_publish ->
      File.write!(handle.staging_path, <<0>>, [:append])
      :ok
    end

    assert {:error, :publication_collision} =
             InspectionArtifact.publish_handle(handle, seal, hook)

    refute File.exists?(path)
    assert :ok = InspectionSink.stop(sink)
  end

  @tag :tmp_dir
  test "record quota refusal poisons the stream before publication", %{tmp_dir: root} do
    path = Path.join(root, "quota.ptcins")
    {sink, _handle} = start_sink!(path, max_records: 2)

    assert :ok = emit_prints(sink, "evaluation-1", [])
    assert :ok = emit_prints(sink, "evaluation-2", [])
    assert {:error, :inspection_sink_error} = emit_prints(sink, "evaluation-3", [])
    assert {:error, :inspection_sink_error} = InspectionSink.seal(sink)
    refute File.exists?(path)
    assert :ok = InspectionSink.stop(sink)
  end

  @tag :tmp_dir
  test "malformed framing, append, and truncation fail closed", %{tmp_dir: root} do
    malformed = PrivateInspectionFixture.create!(Path.join(root, "malformed"), "malformed-run")
    malformed_path = Path.join(malformed.inspection, "malformed-run.ptcins")
    bytes = File.read!(malformed_path)

    footer_bytes =
      binary_part(bytes, byte_size(bytes) - Format.footer_size(), Format.footer_size())

    assert {:ok, footer} = Format.decode_footer(footer_bytes)
    {:ok, io} = :file.open(malformed_path, [:read, :write, :binary])
    :ok = :file.pwrite(io, Format.header_size(), <<footer.evidence_bytes::unsigned-big-64>>)
    :ok = :file.close(io)
    {:ok, malformed_trace} = TraceSnapshot.start({:directory, malformed.traces}, owner: self())

    assert {:error, :malformed_source} =
             InspectionSnapshot.start(
               {:directory, malformed.inspection},
               malformed_trace,
               owner: self()
             )

    TraceSnapshot.stop(malformed_trace)

    changed = PrivateInspectionFixture.create!(Path.join(root, "changed"), "changed-run")
    changed_path = Path.join(changed.inspection, "changed-run.ptcins")
    original = File.read!(changed_path)
    {trace, snapshot} = start_snapshots!(changed)

    File.write!(changed_path, <<0>>, [:append])
    assert {:error, :source_changed} = InspectionSnapshot.query(snapshot, :list_runs, %{})
    InspectionSnapshot.stop(snapshot)
    TraceSnapshot.stop(trace)

    File.write!(changed_path, original)
    {trace, snapshot} = start_snapshots!(changed)
    File.write!(changed_path, binary_part(original, 0, byte_size(original) - 1))
    assert {:error, :source_changed} = InspectionSnapshot.query(snapshot, :list_runs, %{})
    InspectionSnapshot.stop(snapshot)
    TraceSnapshot.stop(trace)
  end

  @tag :tmp_dir
  test "query caller death cancels range work without killing the snapshot", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root, "query-lifecycle")
    test = self()
    calls = :atomics.new(1, signed: false)

    hook = fn :before_query ->
      if :atomics.add_get(calls, 1, 1) == 1 do
        send(test, {:query_worker, self()})

        receive do
          :release_query -> :ok
        end
      end
    end

    {:ok, trace} = TraceSnapshot.start({:directory, fixture.traces}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, fixture.inspection}, trace,
        owner: self(),
        query_hook: hook
      )

    caller = spawn(fn -> InspectionSnapshot.query(snapshot, :list_runs, %{}) end)
    caller_ref = Process.monitor(caller)
    assert_receive {:query_worker, worker}, 5_000
    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 5_000

    assert {:ok, %{"items" => [%{"run_id" => "query-lifecycle"}]}} =
             InspectionSnapshot.query(snapshot, :list_runs, %{})

    InspectionSnapshot.stop(snapshot)
    TraceSnapshot.stop(trace)
  end

  @tag :tmp_dir
  test "omitted_count is exact ETS cardinality and omitted frames are not reread", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create_model_exchanges!(root, 5, "omitted-run")
    {trace, snapshot} = start_snapshots!(fixture)

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace)
    end)

    assert {:ok,
            %{
              "items" => [%{"capability_id" => "llm-1-omitted-run"}],
              "next_cursor" => cursor,
              "omitted_count" => 4,
              "truncated" => true
            }} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{
               "run_id" => "omitted-run",
               "limit" => 1
             })

    state = :sys.get_state(snapshot.pid)

    [{_key, {_type, offset, _length, _digest}}] =
      Indexes.lookup(state.indexes, :records, {"omitted-run", 3})

    path = Path.join(fixture.inspection, "omitted-run.ptcins")
    {:ok, io} = :file.open(path, [:read, :write, :binary])
    :ok = :file.pwrite(io, offset, "[")
    :ok = :file.close(io)

    assert {:ok, %{"omitted_count" => 4}} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{
               "run_id" => "omitted-run",
               "limit" => 1
             })

    assert {:error, :source_changed} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{
               "run_id" => "omitted-run",
               "limit" => 1,
               "cursor" => cursor
             })
  end

  @tag :tmp_dir
  test "large streamed artifacts admit and query without an eager record collection", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create_model_exchanges!(root, 120, "large-run")
    path = Path.join(fixture.inspection, "large-run.ptcins")
    assert File.stat!(path).size > 500_000

    {trace, snapshot} = start_snapshots!(fixture)

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace)
    end)

    assert {:ok, %{"record_count" => 240, "counts" => counts}} =
             InspectionSnapshot.query(snapshot, :get_run, %{"run_id" => "large-run"})

    assert counts["model_exchanges"] == 120

    assert {:ok, %{"items" => items, "omitted_count" => 110}} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{
               "run_id" => "large-run",
               "limit" => 10
             })

    assert length(items) == 10
  end

  @tag :tmp_dir
  test "admitted collections preserve all production query families", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root, "parity-run")
    {trace, snapshot} = start_snapshots!(fixture)

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace)
    end)

    expected_nonempty = [
      list_runs: %{},
      get_run: %{"run_id" => "parity-run"},
      turns: %{"run_id" => "parity-run"},
      model_exchanges: %{"run_id" => "parity-run"},
      capability_calls: %{"run_id" => "parity-run"},
      generated_sources: %{"run_id" => "parity-run"},
      effective_preludes: %{"run_id" => "parity-run"},
      provider_exchanges: %{"run_id" => "parity-run"},
      execution_prints: %{"run_id" => "parity-run"},
      execution_errors: %{"run_id" => "parity-run"},
      explicit_failure_values: %{"run_id" => "parity-run"}
    ]

    Enum.each(expected_nonempty, fn {operation, arguments} ->
      assert {:ok, result} = InspectionSnapshot.query(snapshot, operation, arguments)
      assert operation == :get_run or result["items"] != []
    end)

    assert {:error, :result_not_found} =
             InspectionSnapshot.query(snapshot, :result, %{"run_id" => "parity-run"})
  end

  defp emit_prints(sink, evaluation_id, prints) do
    InspectionSink.emit(sink, "execution-prints", %{evaluation_id: evaluation_id}, %{
      environment: :workflow,
      prints: prints,
      truncated: false
    })
  end

  defp start_sink!(path, opts) do
    {:ok, handle} = PublicationHandle.reserve_stream_for(path, :inspection, 0o600, self())

    {:ok, sink} =
      InspectionSink.start(
        [
          run_id: "stream-run",
          trace_id: "stream-trace",
          publication_handle: handle
        ] ++ opts
      )

    {sink, handle}
  end

  defp start_snapshots!(fixture) do
    {:ok, trace} = TraceSnapshot.start({:directory, fixture.traces}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, fixture.inspection}, trace, owner: self())

    {trace, snapshot}
  end
end
