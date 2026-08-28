defmodule PtcRunner.Kernel.RunCatalogSnapshotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.RunCatalog
  alias PtcRunner.Kernel.RunCatalogSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @tag :tmp_dir
  test "a paired cohort lists safe metadata without opening either payload", %{tmp_dir: root} do
    first = fixture!(root, 1)
    second = fixture!(root, 2)

    rows = rows!(root)

    assert Enum.map(rows, & &1["run_id"]) == Enum.sort([first.run_id, second.run_id])

    row = row!(rows, first.run_id)

    assert row["trace_id"] == "trace-#{first.run_id}"
    assert row["trace_present"] == "sanitized"
    assert row["inspection_present"] == true
    assert row["correlation"] == "paired"
    assert row["state"] == "admissible"
    assert row["isolation_reason"] == nil
    assert row["trace_schema_version"] == 2
    assert row["inspection_format_version"] == Format.format_version()
    assert row["inspection_schema_version"] == Format.schema_version()
    assert row["status"] == "failed"
    assert row["complete"] == true
    assert row["start_timestamp"] == "2026-07-26T12:00:01Z"
    assert row["stop_timestamp"] == "2026-07-26T12:00:08Z"
    assert row["duration_ms"] == 7_000
    assert row["inspection_record_count"] > 0
    assert row["inspection_bytes"] == File.stat!(inspection_path(root, first.run_id)).size
    assert row["trace_bytes"] == File.stat!(trace_path(root, first.run_id)).size
    assert row["artifact_digest"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  @tag :tmp_dir
  test "rows carry no private payload content and no filesystem path", %{tmp_dir: root} do
    fixture = fixture!(root, 3)
    encoded = root |> rows!() |> Jason.encode!()

    for secret <- [
          "private-prompt-#{fixture.run_id}",
          "private-answer-#{fixture.run_id}",
          "private-system-#{fixture.run_id}",
          "private-tool-result-#{fixture.run_id}",
          "private-print-#{fixture.run_id}",
          "(return 42)"
        ] do
      refute encoded =~ secret
    end

    refute encoded =~ root
    refute encoded =~ "traces"
    refute encoded =~ ".ptcins"
  end

  @tag :tmp_dir
  test "a row reports a missing half instead of refusing the generation", %{tmp_dir: root} do
    paired = fixture!(root, 4)
    trace_only = fixture!(root, 5)
    inspection_only = fixture!(root, 6)

    File.rm!(inspection_path(root, trace_only.run_id))
    File.rm!(trace_path(root, inspection_only.run_id))

    rows = rows!(root)

    assert row!(rows, paired.run_id)["correlation"] == "paired"

    trace_only_row = row!(rows, trace_only.run_id)
    assert trace_only_row["correlation"] == "trace_only"
    assert trace_only_row["state"] == "admissible"
    assert trace_only_row["inspection_present"] == false
    assert trace_only_row["inspection_bytes"] == nil

    inspection_only_row = row!(rows, inspection_only.run_id)
    assert inspection_only_row["correlation"] == "inspection_only"
    assert inspection_only_row["state"] == "admissible"
    assert inspection_only_row["trace_id"] == nil
    assert inspection_only_row["trace_present"] == "absent"
    assert inspection_only_row["inspection_record_count"] > 0
  end

  @tag :tmp_dir
  test "both trace filename variants isolate one row and no other", %{tmp_dir: root} do
    healthy = fixture!(root, 7)
    ambiguous = fixture!(root, 8)

    path = trace_path(root, ambiguous.run_id)
    File.cp!(path, Path.join(root, "traces/#{ambiguous.run_id}.private.jsonl"))

    rows = rows!(root)

    assert row!(rows, healthy.run_id)["state"] == "admissible"

    row = row!(rows, ambiguous.run_id)
    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "ambiguous_trace"
    assert row["trace_present"] == "unreadable"
  end

  @tag :tmp_dir
  test "an unsupported sealed schema shows its versions and isolates the row", %{tmp_dir: root} do
    fixture = fixture!(root, 9)
    rewrite_sealed_schema!(inspection_path(root, fixture.run_id), Format.schema_version() + 1)

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "unsupported_schema"
    assert row["inspection_schema_version"] == Format.schema_version() + 1
    assert row["inspection_format_version"] == Format.format_version()
    assert row["inspection_record_count"] == nil
    assert row["artifact_digest"] == nil
  end

  @tag :tmp_dir
  test "a header and footer that disagree about the schema isolate the row", %{tmp_dir: root} do
    fixture = fixture!(root, 33)
    PrivateInspectionFixture.rewrite_schema!(Path.join(root, "inspection"), 1)

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "malformed_metadata"
    assert row["inspection_schema_version"] == nil
  end

  @tag :tmp_dir
  test "an unsupported trace schema isolates the row", %{tmp_dir: root} do
    fixture = fixture!(root, 10)
    rewrite_trace!(root, fixture.run_id, &Map.put(&1, "schema_version", 3))

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "unsupported_schema"
    assert row["trace_schema_version"] == 3
  end

  @tag :tmp_dir
  test "a schema version of the wrong shape isolates the row", %{tmp_dir: root} do
    fixture = fixture!(root, 36)

    rewrite_trace!(
      root,
      fixture.run_id,
      &Map.put(&1, "schema_version", String.duplicate("2", 4_000))
    )

    row = root |> rows!() |> row!(fixture.run_id)

    # A version that is not a number is not a version this build cannot read —
    # it is an event the canonical reader rejects outright, so the row reports
    # the malformation and projects no version at all.
    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "malformed_metadata"
    assert row["trace_schema_version"] == nil
    assert byte_size(Jason.encode!(row)) <= RunCatalog.max_row_bytes()
  end

  @tag :tmp_dir
  test "a malformed head line isolates the row", %{tmp_dir: root} do
    healthy = fixture!(root, 11)
    broken = fixture!(root, 12)
    File.write!(trace_path(root, broken.run_id), "{not-json\n")

    rows = rows!(root)

    assert row!(rows, healthy.run_id)["state"] == "admissible"

    row = row!(rows, broken.run_id)
    assert row["isolation_reason"] == "malformed_metadata"
    assert row["trace_present"] == "unreadable"
    assert row["correlation"] == "unavailable"
  end

  @tag :tmp_dir
  test "a truncated sealed artifact isolates the row", %{tmp_dir: root} do
    fixture = fixture!(root, 13)
    path = inspection_path(root, fixture.run_id)
    bytes = File.read!(path)
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1))

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "malformed_metadata"
  end

  @tag :tmp_dir
  test "a filename that routes to another run isolates the row", %{tmp_dir: root} do
    fixture = fixture!(root, 14)
    impostor = PrivateInspectionFixture.command_run_ref(15)

    File.rename!(trace_path(root, fixture.run_id), trace_path(root, impostor))
    File.rm!(inspection_path(root, fixture.run_id))

    row = root |> rows!() |> row!(impostor)

    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "filename_run_mismatch"
  end

  @tag :tmp_dir
  test "two entries claiming one trace identity isolate both", %{tmp_dir: root} do
    first = fixture!(root, 16)
    second = fixture!(root, 17)

    rewrite_trace!(root, second.run_id, &Map.put(&1, "trace_id", "trace-#{first.run_id}"))

    rows = rows!(root)

    for run_id <- [first.run_id, second.run_id] do
      row = row!(rows, run_id)
      assert row["state"] == "isolated"
      assert row["isolation_reason"] == "duplicate_run_identity"
    end
  end

  @tag :tmp_dir
  test "a trace and artifact that disagree about the trace report a mismatch", %{tmp_dir: root} do
    fixture = fixture!(root, 18)
    rewrite_trace!(root, fixture.run_id, &Map.put(&1, "trace_id", "trace-unrelated"))

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["correlation"] == "mismatch"
    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "inspection_correlation_missing"
  end

  @tag :tmp_dir
  test "an unbounded but well-formed timestamp cannot grow a row", %{tmp_dir: root} do
    fixture = fixture!(root, 34)
    padded = "2026-07-26T12:00:01." <> String.duplicate("1", 5_000) <> "Z"
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(padded)
    rewrite_trace!(root, fixture.run_id, &Map.put(&1, "timestamp", padded))

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["start_timestamp"] == nil
    assert row["duration_ms"] == nil
    assert byte_size(Jason.encode!(row)) <= RunCatalog.max_row_bytes()
  end

  @tag :tmp_dir
  test "a label of the wrong shape reads as absent, never as a row field", %{tmp_dir: root} do
    fixture = fixture!(root, 35)

    rewrite_trace!(root, fixture.run_id, fn event ->
      if event["type"] == "run-started" do
        put_in(event, ["data", "labels"], %{"name" => %{"nested" => true}, "tags" => "not-a-map"})
      else
        event
      end
    end)

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["name"] == nil
    assert row["tags"] == %{}
    assert row["state"] == "admissible"
  end

  @tag :tmp_dir
  test "files without a canonical stem are counted, never listed as rows", %{tmp_dir: root} do
    fixture = fixture!(root, 19)
    assert {:ok, %{excluded_files: baseline}} = RunCatalogSnapshot.info(capture!(root))

    File.write!(Path.join(root, "traces/notes.txt"), "ignored\n")
    File.write!(Path.join(root, "traces/.hidden.jsonl"), "ignored\n")
    File.write!(Path.join(root, "inspection/leftover.tmp"), "ignored\n")

    snapshot = capture!(root)

    assert {:ok, %{row_count: 1, excluded_files: excluded}} = RunCatalogSnapshot.info(snapshot)
    assert excluded == baseline + 3
    assert {:ok, [%{"run_id" => run_id}]} = RunCatalogSnapshot.rows(snapshot)
    assert run_id == fixture.run_id
  end

  @tag :tmp_dir
  test "an open generation is unchanged by a run published after its capture", %{tmp_dir: root} do
    first = fixture!(root, 20)

    open = capture!(root)
    assert {:ok, %{catalog_digest: digest, row_count: 1}} = RunCatalogSnapshot.info(open)

    second = fixture!(root, 21)

    assert {:ok, %{catalog_digest: ^digest, row_count: 1}} = RunCatalogSnapshot.info(open)
    assert {:ok, [%{"run_id" => only}]} = RunCatalogSnapshot.rows(open)
    assert only == first.run_id

    later = capture!(root)
    assert {:ok, %{catalog_digest: later_digest, row_count: 2}} = RunCatalogSnapshot.info(later)
    refute later_digest == digest
    assert Enum.sort([first.run_id, second.run_id]) == Enum.map(rows!(root), & &1["run_id"])
  end

  @tag :tmp_dir
  test "an unchanged root captures to the same generation digest", %{tmp_dir: root} do
    fixture!(root, 22)

    assert {:ok, %{catalog_digest: digest}} = RunCatalogSnapshot.info(capture!(root))
    assert {:ok, %{catalog_digest: ^digest}} = RunCatalogSnapshot.info(capture!(root))
  end

  @tag :tmp_dir
  test "rewriting an artifact in place changes the next generation digest", %{tmp_dir: root} do
    fixture = fixture!(root, 23)

    assert {:ok, %{catalog_digest: digest}} = RunCatalogSnapshot.info(capture!(root))

    rewrite_trace!(root, fixture.run_id, &Map.put(&1, "timestamp", "2026-07-26T13:00:00Z"))

    assert {:ok, %{catalog_digest: changed}} = RunCatalogSnapshot.info(capture!(root))
    refute changed == digest
  end

  @tag :tmp_dir
  test "a cohort beyond the stem bound refuses the whole capture", %{tmp_dir: root} do
    fixture!(root, 24)
    fixture!(root, 25)

    assert {:error, :catalog_limit_exceeded} =
             RunCatalogSnapshot.start(catalog_source(root), owner: self(), max_files: 1)
  end

  @tag :tmp_dir
  test "a listing beyond its entry bound refuses the whole capture", %{tmp_dir: root} do
    fixture!(root, 26)
    fixture!(root, 27)

    assert {:error, :catalog_limit_exceeded} =
             RunCatalogSnapshot.start(catalog_source(root),
               owner: self(),
               max_directory_entries: 1
             )
  end

  @tag :tmp_dir
  test "a retained projection beyond its bound refuses the whole capture", %{tmp_dir: root} do
    fixture!(root, 28)

    assert {:error, :catalog_limit_exceeded} =
             RunCatalogSnapshot.start(catalog_source(root), owner: self(), max_retained_bytes: 1)
  end

  @tag :tmp_dir
  test "an unusable root refuses the whole capture", %{tmp_dir: root} do
    fixture!(root, 29)

    assert {:error, :source_unavailable} =
             RunCatalogSnapshot.start(
               {:private_authorized_catalog, Path.join(root, "traces"),
                Path.join(root, "absent")},
               owner: self()
             )
  end

  @tag :tmp_dir
  test "an owner's exit stops its generation", %{tmp_dir: root} do
    fixture!(root, 30)
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, snapshot} = RunCatalogSnapshot.start(catalog_source(root), owner: self())
        send(test_pid, {:captured, snapshot})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:captured, snapshot}
    assert RunCatalogSnapshot.alive?(snapshot)

    owner_ref = Process.monitor(owner)
    send(owner, :release)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}

    assert {:error, :catalog_unavailable} = await_stopped(snapshot)
  end

  @tag :tmp_dir
  test "an explicit stop releases the generation", %{tmp_dir: root} do
    fixture!(root, 31)
    snapshot = capture!(root)

    assert :ok = RunCatalogSnapshot.stop(snapshot)
    assert {:error, :catalog_unavailable} = RunCatalogSnapshot.info(snapshot)
    assert :ok = RunCatalogSnapshot.stop(snapshot)
  end

  test "a source that is not a catalog pair is refused" do
    assert {:error, :invalid_catalog} = RunCatalogSnapshot.start({:directory, "/tmp"})
    assert {:error, :invalid_catalog} = RunCatalogSnapshot.rows(:not_a_snapshot)
    assert {:error, :invalid_catalog} = RunCatalogSnapshot.info(:not_a_snapshot)
  end

  @tag :tmp_dir
  test "capture bounds may be lowered but never raised", %{tmp_dir: root} do
    fixture!(root, 32)

    assert {:error, :invalid_catalog} =
             RunCatalogSnapshot.start(catalog_source(root), owner: self(), max_files: 1_025)

    assert {:error, :invalid_catalog} =
             RunCatalogSnapshot.start(catalog_source(root),
               owner: self(),
               max_retained_bytes: RunCatalogSnapshot.default_retained_bytes() + 1
             )

    assert {:error, :invalid_catalog} =
             RunCatalogSnapshot.start(catalog_source(root), owner: self(), unsupported: true)
  end

  @tag :tmp_dir
  test "a probed event that is not a canonical trace event isolates the row", %{tmp_dir: root} do
    fixture = fixture!(root, 37)

    rewrite_trace!(root, fixture.run_id, fn event ->
      if event["type"] == "run-stopped", do: Map.delete(event, "trace_id"), else: event
    end)

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "malformed_metadata"
    refute row["complete"]
  end

  @tag :tmp_dir
  test "a run-stopped whose result hash contradicts its outcome isolates the row", %{
    tmp_dir: root
  } do
    fixture = fixture!(root, 38)

    rewrite_trace!(root, fixture.run_id, fn event ->
      if event["type"] == "run-stopped",
        do: put_in(event, ["data", "result_hash"], "not-a-hash"),
        else: event
    end)

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "malformed_metadata"
  end

  @tag :tmp_dir
  test "a rewritten footer field changes the next generation digest", %{tmp_dir: root} do
    fixture = fixture!(root, 39)
    path = inspection_path(root, fixture.run_id)

    assert {:ok, %{catalog_digest: digest}} = RunCatalogSnapshot.info(capture!(root))
    before_count = row!(rows!(root), fixture.run_id)["inspection_record_count"]

    rewrite_footer_record_count!(path, before_count + 1)

    assert {:ok, %{catalog_digest: changed}} = RunCatalogSnapshot.info(capture!(root))
    refute changed == digest
    assert row!(rows!(root), fixture.run_id)["inspection_record_count"] == before_count + 1
  end

  @tag :tmp_dir
  test "a current-version header with invalid geometry isolates the row", %{tmp_dir: root} do
    fixture = fixture!(root, 40)
    path = inspection_path(root, fixture.run_id)
    <<prefix::binary-size(12), _declared::unsigned-big-32, rest::binary>> = File.read!(path)
    File.write!(path, <<prefix::binary, 17::unsigned-big-32, rest::binary>>)

    row = root |> rows!() |> row!(fixture.run_id)

    assert row["state"] == "isolated"
    assert row["isolation_reason"] == "malformed_metadata"
  end

  @tag :tmp_dir
  test "an artifact claiming another run's identity isolates every claimant", %{tmp_dir: root} do
    first = fixture!(root, 41)
    second = fixture!(root, 42)

    File.cp!(inspection_path(root, first.run_id), inspection_path(root, second.run_id))

    rows = rows!(root)

    # Both claimants are isolated, never only the impersonator: the run whose
    # identity was copied is no longer selectable either. The impostor reports
    # the more specific defect it also has — its bytes are not the run its name
    # claims — while the impersonated run reports the duplication alone.
    for run_id <- [first.run_id, second.run_id] do
      assert row!(rows, run_id)["state"] == "isolated"
    end

    assert row!(rows, first.run_id)["isolation_reason"] == "duplicate_run_identity"
    assert row!(rows, second.run_id)["isolation_reason"] == "filename_run_mismatch"
  end

  defp await_stopped(snapshot) do
    if RunCatalogSnapshot.alive?(snapshot) do
      await_stopped(snapshot)
    else
      RunCatalogSnapshot.info(snapshot)
    end
  end

  defp capture!(root) do
    assert {:ok, snapshot} = RunCatalogSnapshot.start(catalog_source(root), owner: self())
    on_exit(fn -> RunCatalogSnapshot.stop(snapshot) end)
    snapshot
  end

  defp rows!(root) do
    assert {:ok, rows} = root |> capture!() |> RunCatalogSnapshot.rows()
    rows
  end

  defp row!(rows, run_id) do
    assert row = Enum.find(rows, &(&1["run_id"] == run_id))
    row
  end

  defp catalog_source(root),
    do: {:private_authorized_catalog, Path.join(root, "traces"), Path.join(root, "inspection")}

  defp fixture!(root, seed),
    do: PrivateInspectionFixture.create!(root, PrivateInspectionFixture.command_run_ref(seed))

  defp trace_path(root, run_id), do: Path.join(root, "traces/#{run_id}.jsonl")
  defp inspection_path(root, run_id), do: Path.join(root, "inspection/#{run_id}.ptcins")

  # Rewrites both declared schema versions, so the container stays internally
  # consistent and states a version this build does not support - which is the
  # state a real version bump produces, and a different one from corruption.
  defp rewrite_sealed_schema!(path, schema_version) do
    bytes = File.read!(path)

    <<header_magic::binary-size(8), format::unsigned-big-16, _schema::unsigned-big-16,
      header_rest::binary-size(4), body::binary>> = bytes

    footer_size = Format.footer_size()
    body_size = byte_size(body) - footer_size

    <<evidence::binary-size(^body_size), footer_magic::binary-size(8),
      footer_format::unsigned-big-16, _footer_schema::unsigned-big-16, footer_rest::binary>> =
      body

    File.write!(path, [
      header_magic,
      <<format::unsigned-big-16, schema_version::unsigned-big-16>>,
      header_rest,
      evidence,
      footer_magic,
      <<footer_format::unsigned-big-16, schema_version::unsigned-big-16>>,
      footer_rest
    ])
  end

  # Rewrites one footer field and nothing else. The footer's stored
  # `artifact_digest` is a claim, not a recomputation, so this leaves that claim
  # intact — which is exactly the case a commitment must still distinguish.
  defp rewrite_footer_record_count!(path, record_count) do
    bytes = File.read!(path)
    footer_offset = byte_size(bytes) - Format.footer_size()
    record_count_offset = footer_offset + 40

    <<head::binary-size(^record_count_offset), _count::unsigned-big-64, rest::binary>> = bytes

    File.write!(path, <<head::binary, record_count::unsigned-big-64, rest::binary>>)
  end

  defp rewrite_trace!(root, run_id, transform) do
    path = trace_path(root, run_id)

    events =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(transform)

    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end
end
