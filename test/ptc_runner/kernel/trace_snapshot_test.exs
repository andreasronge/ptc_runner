defmodule PtcRunner.Kernel.TraceSnapshotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Lisp.RetainedSize

  @tag :tmp_dir
  test "the accepted minimum result ceiling can return an empty page", %{
    tmp_dir: directory
  } do
    File.write!(Path.join(directory, "empty.jsonl"), "")

    assert {:ok, snapshot} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_result_bytes: HostConfig.minimum_snapshot_result_bytes()
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok,
            %{
              "items" => [],
              "next_cursor" => nil,
              "omitted_count" => 0,
              "truncated" => false,
              "snapshot_hash" => "sha256:" <> _
            }} = TraceSnapshot.query(snapshot, :list_runs, %{})
  end

  @tag :tmp_dir
  test "captures one immutable normal directory and reuses canonical queries", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "first.jsonl")
    private_path = Path.join(directory, "hidden.private.jsonl")
    inspection_path = Path.join(directory, "hidden.ptcins")

    write_events(path, [event("first", 1, "run-started"), event("first", 2, "run-stopped")])
    write_events(private_path, [event("private", 1, "run-started")])
    write_events(inspection_path, [event("inspection", 1, "run-started")])

    assert {:ok, live_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)
    assert {:ok, %{snapshot_hash: snapshot_hash}} = TraceSnapshot.info(snapshot)
    assert snapshot_hash =~ ~r/\Asha256:[0-9a-f]{64}\z/

    assert {:ok, expected_runs} = TraceLog.query(live_log, :list_runs, %{})
    assert {:ok, snapshot_runs} = TraceSnapshot.query(snapshot, :list_runs, %{})
    assert Map.delete(snapshot_runs, "snapshot_hash") == expected_runs
    assert snapshot_runs["snapshot_hash"] == snapshot_hash

    assert {:ok, expected_run} = TraceLog.query(live_log, :get_run, %{"run_id" => "first"})
    assert {:ok, snapshot_run} = TraceSnapshot.query(snapshot, :get_run, %{"run_id" => "first"})
    assert Map.delete(snapshot_run, "snapshot_hash") == expected_run
    assert snapshot_run["snapshot_hash"] == snapshot_hash

    assert {:ok, expected_turns} =
             TraceLog.query(live_log, :list_turns, %{"run_id" => "first"})

    assert {:ok, snapshot_turns} =
             TraceSnapshot.query(snapshot, :list_turns, %{"run_id" => "first"})

    assert Map.delete(snapshot_turns, "snapshot_hash") == expected_turns
    assert snapshot_turns["snapshot_hash"] == snapshot_hash

    assert {:ok, expected_counters} = TraceLog.query(live_log, :counters, %{})
    assert {:ok, snapshot_counters} = TraceSnapshot.query(snapshot, :counters, %{})
    assert Map.delete(snapshot_counters, "snapshot_hash") == expected_counters
    assert snapshot_counters["snapshot_hash"] == snapshot_hash

    write_events(path, [event("changed", 1, "run-started")])
    write_events(Path.join(directory, "later.jsonl"), [event("later", 1, "run-started")])

    assert {:ok, frozen_runs} = TraceSnapshot.query(snapshot, :list_runs, %{})
    assert Map.delete(frozen_runs, "snapshot_hash") == expected_runs
    assert frozen_runs["snapshot_hash"] == snapshot_hash

    assert {:ok, %{"items" => live_items}} = TraceLog.query(live_log, :list_runs, %{})
    assert Enum.sort(Enum.map(live_items, & &1["run_id"])) == ["changed", "later"]
  end

  @tag :tmp_dir
  test "private-authorized capture is a mixed immutable superset with per-run provenance", %{
    tmp_dir: directory
  } do
    normal_path = Path.join(directory, "normal.jsonl")
    private_path = Path.join(directory, "private.private.jsonl")
    inspection_path = Path.join(directory, "ignored.ptcins")

    write_events(normal_path, [event("normal", 1, "run-started")])
    write_events(private_path, [event("private", 1, "run-started")])
    write_events(inspection_path, [event("inspection", 1, "run-started")])

    assert {:ok, snapshot} =
             TraceSnapshot.start({:private_authorized_directory, directory}, owner: self())

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok,
            %{
              source: :ptc_private_trace_snapshot,
              file_count: 2,
              run_count: 2,
              snapshot_hash: snapshot_hash
            }} = TraceSnapshot.info(snapshot)

    assert {:ok, %{"items" => items, "snapshot_hash" => ^snapshot_hash}} =
             TraceSnapshot.query(snapshot, :list_runs, %{})

    assert Map.new(items, &{&1["run_id"], &1["source"]}) == %{
             "normal" => "sanitized",
             "private" => "private"
           }

    write_events(normal_path, [event("changed", 1, "run-started")])
    File.rm!(private_path)

    assert {:ok, %{"items" => frozen}} = TraceSnapshot.query(snapshot, :list_runs, %{})
    assert Enum.map(frozen, & &1["run_id"]) |> Enum.sort() == ["normal", "private"]
  end

  @tag :tmp_dir
  test "a sanitized snapshot names the private trace files it did not read", %{
    tmp_dir: directory
  } do
    write_events(Path.join(directory, "normal.jsonl"), [event("normal", 1, "run-started")])
    write_events(Path.join(directory, "one.private.jsonl"), [event("one", 1, "run-started")])
    write_events(Path.join(directory, "two.private.jsonl"), [event("two", 1, "run-started")])

    write_events(Path.join(directory, "ignored.ptcins"), [
      event("inspection", 1, "run-started")
    ])

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, %{"items" => [%{"run_id" => "normal"}]} = page} =
             TraceSnapshot.query(snapshot, :list_runs, %{})

    # Inspection artifacts are a different artifact class, not runs this
    # source kind withheld, so they are never counted as excluded.
    assert page["excluded_private_trace_files"] == 2

    assert {:ok, run} = TraceSnapshot.query(snapshot, :get_run, %{"run_id" => "normal"})
    refute Map.has_key?(run, "excluded_private_trace_files")

    # The private-authorized capture is a superset of the sanitized one, so it
    # withholds nothing and claims no exclusion.
    assert {:ok, private_snapshot} =
             TraceSnapshot.start({:private_authorized_directory, directory}, owner: self())

    on_exit(fn -> TraceSnapshot.stop(private_snapshot) end)

    assert {:ok, private_page} = TraceSnapshot.query(private_snapshot, :list_runs, %{})
    refute Map.has_key?(private_page, "excluded_private_trace_files")
    refute Map.has_key?(private_page, "excluded_sanitized_trace_files")
  end

  @tag :tmp_dir
  test "private-authorized capture isolates one run split across source classes", %{
    tmp_dir: directory
  } do
    write_events(Path.join(directory, "split.jsonl"), [event("split", 1, "run-started")])

    write_events(Path.join(directory, "split.private.jsonl"), [
      event("split", 2, "run-stopped")
    ])

    assert {:ok, snapshot} =
             TraceSnapshot.start({:private_authorized_directory, directory}, owner: self())

    assert {:ok, %{run_count: 0, file_count: 2}} = TraceSnapshot.info(snapshot)
    assert :ok = TraceSnapshot.stop(snapshot)
  end

  @tag :tmp_dir
  test "private capture bounds the combined normal and private catalog", %{tmp_dir: directory} do
    write_events(Path.join(directory, "normal.jsonl"), [event("normal", 1, "run-started")])

    write_events(Path.join(directory, "private.private.jsonl"), [
      event("private", 1, "run-started")
    ])

    assert {:error, :source_limit_exceeded} =
             TraceSnapshot.start({:private_authorized_directory, directory},
               owner: self(),
               max_trace_files: 1
             )

    assert {:error,
            {:source_retained_limit_exceeded,
             %{source: :ptc_private_trace_snapshot, measured_bytes: measured, limit_bytes: 1}}} =
             TraceSnapshot.start({:private_authorized_directory, directory},
               owner: self(),
               max_retained_bytes: 1
             )

    assert measured > 1
  end

  @tag :tmp_dir
  test "snapshot cursors remain bound to the immutable capture", %{tmp_dir: directory} do
    write_events(Path.join(directory, "first.jsonl"), [event("first", 1, "run-started")])
    write_events(Path.join(directory, "second.jsonl"), [event("second", 1, "run-started")])

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, %{"items" => [_], "next_cursor" => cursor}} =
             TraceSnapshot.query(snapshot, :list_runs, %{"limit" => 1})

    write_events(Path.join(directory, "third.jsonl"), [event("third", 1, "run-started")])

    assert {:ok, %{"items" => [_], "next_cursor" => nil}} =
             TraceSnapshot.query(snapshot, :list_runs, %{"limit" => 1, "cursor" => cursor})

    assert {:error, :invalid_query} =
             TraceSnapshot.query(snapshot, :list_turns, %{
               "run_id" => "first",
               "cursor" => cursor
             })
  end

  @tag :tmp_dir
  test "an individually oversized trace item fails instead of returning a stalled cursor", %{
    tmp_dir: directory
  } do
    oversized =
      "oversized"
      |> event(1, "run-started")
      |> put_in(["data", "labels"], %{"name" => String.duplicate("x", 1_024)})

    write_events(Path.join(directory, "oversized.jsonl"), [oversized])

    assert {:ok, snapshot} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_result_bytes: 512
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:error, :result_limit_exceeded} =
             TraceSnapshot.query(snapshot, :list_runs, %{"limit" => 1})
  end

  @tag :tmp_dir
  test "trace pages fit encoded and retained result ceilings", %{tmp_dir: directory} do
    events =
      Enum.map(1..40, fn index ->
        tags = Map.new(1..12, &{"tag-#{&1}", "value-#{index}-#{&1}"})

        "run-#{index}"
        |> event(1, "run-started")
        |> put_in(["data", "labels"], %{"name" => "run-#{index}", "tags" => tags})
      end)

    Enum.each(events, fn event ->
      write_events(Path.join(directory, event["run_id"] <> ".jsonl"), [event])
    end)

    assert {:ok, trace_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, raw_page} = TraceLog.query(trace_log, :list_runs, %{})

    sized_page =
      Map.put(raw_page, "snapshot_hash", "sha256:" <> String.duplicate("0", 64))

    encoded_bytes = byte_size(Jason.encode!(sized_page))
    retained_bytes = RetainedSize.bytes(sized_page)
    assert retained_bytes > encoded_bytes

    max_result_bytes =
      encoded_bytes + min(10_000, div(retained_bytes - encoded_bytes, 2))

    assert {:ok, snapshot} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_result_bytes: max_result_bytes
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok,
            %{
              "items" => first_items,
              "next_cursor" => cursor,
              "truncated" => true
            } = first_page} = TraceSnapshot.query(snapshot, :list_runs, %{})

    assert first_items != []
    assert length(first_items) < 40
    assert is_binary(cursor)
    assert byte_size(Jason.encode!(first_page)) <= max_result_bytes
    assert RetainedSize.bytes(first_page) <= max_result_bytes

    runs = collect_runs(snapshot, first_page, max_result_bytes)
    assert length(runs) == 40
    assert Enum.uniq_by(runs, & &1["run_id"]) == runs
  end

  @tag :tmp_dir
  test "safe metadata is bounded and contains no source path", %{tmp_dir: directory} do
    path = Path.join(directory, "visible.jsonl")
    write_events(path, [event("visible", 1, "run-started")])

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok,
            %{
              capture_id: capture_id,
              captured_at: %DateTime{},
              run_count: 1,
              source_bytes: source_bytes,
              retained_bytes: retained_bytes
            } = info} = TraceSnapshot.info(snapshot)

    assert capture_id =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert source_bytes == File.stat!(path).size
    assert is_integer(retained_bytes) and retained_bytes > 0
    refute Map.has_key?(info, :path)
    refute inspect(info) =~ directory
    status = inspect(:sys.get_status(snapshot.pid))
    refute status =~ directory
    refute status =~ "did not return a map"
    refute status =~ capture_id
  end

  @tag :tmp_dir
  test "unexpected calls, casts, and messages do not terminate the snapshot", %{
    tmp_dir: directory
  } do
    write_events(Path.join(directory, "stable.jsonl"), [event("stable", 1, "run-started")])

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:error, :invalid_snapshot} = GenServer.call(snapshot.pid, :unexpected)
    GenServer.cast(snapshot.pid, :unexpected)
    send(snapshot.pid, :unexpected)

    assert {:ok, %{"items" => [%{"run_id" => "stable"}]}} =
             TraceSnapshot.query(snapshot, :list_runs, %{})
  end

  @tag :tmp_dir
  test "encoded and retained capture ceilings fail independently", %{tmp_dir: directory} do
    path = Path.join(directory, "bounded.jsonl")
    write_events(path, [event("bounded", 1, "run-started")])

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    assert {:ok, %{retained_bytes: expected_retained_bytes}} = TraceSnapshot.info(snapshot)
    assert :ok = TraceSnapshot.stop(snapshot)

    assert {:error, :source_limit_exceeded} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_source_bytes: 1
             )

    assert {:error,
            {:source_retained_limit_exceeded,
             %{
               source: :ptc_trace_snapshot,
               measured_bytes: measured_bytes,
               limit_bytes: 1
             }}} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_retained_bytes: 1
             )

    assert measured_bytes == expected_retained_bytes
  end

  @tag :tmp_dir
  test "capture heap exhaustion returns a stable retained-limit error", %{tmp_dir: directory} do
    write_events(Path.join(directory, "bounded.jsonl"), [event("bounded", 1, "run-started")])

    assert {:error, :source_retained_limit_exceeded} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               capture_heap_words: 233
             )
  end

  @tag :tmp_dir
  test "construction limits may be lowered but not raised", %{tmp_dir: directory} do
    write_events(Path.join(directory, "bounded.jsonl"), [event("bounded", 1, "run-started")])

    raised_limits = [
      max_source_bytes: 8_000_001,
      max_retained_bytes: 32_000_001,
      max_result_bytes: 1_000_001,
      max_directory_entries: 4_097,
      max_trace_files: 1_025,
      capture_heap_words: 10_000_001
    ]

    for {option, value} <- raised_limits do
      assert {:error, :invalid_snapshot} =
               TraceSnapshot.start({:directory, directory}, [{option, value}])
    end
  end

  @tag :tmp_dir
  test "directory entry and trace file ceilings bound capture work", %{tmp_dir: directory} do
    File.write!(Path.join(directory, "ignored-a"), "")
    File.write!(Path.join(directory, "ignored-b"), "")
    write_events(Path.join(directory, "bounded.jsonl"), [event("bounded", 1, "run-started")])

    assert {:error, :source_limit_exceeded} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_directory_entries: 2
             )

    File.rm!(Path.join(directory, "ignored-a"))
    File.rm!(Path.join(directory, "ignored-b"))
    File.write!(Path.join(directory, "empty.jsonl"), "")

    assert {:error, :source_limit_exceeded} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_trace_files: 1
             )
  end

  @tag :tmp_dir
  test "snapshot and live directories agree at the exact source byte ceiling", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "exact.jsonl")
    write_events(path, [event("exact", 1, "run-started")])
    File.write!(Path.join(directory, "z.jsonl"), "")
    source_bytes = File.stat!(path).size

    assert {:ok, live_log} =
             TraceLog.new(source: {:directory, directory}, max_source_bytes: source_bytes)

    assert {:ok, snapshot} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_source_bytes: source_bytes
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, expected} = TraceLog.query(live_log, :list_runs, %{})
    assert {:ok, actual} = TraceSnapshot.query(snapshot, :list_runs, %{})
    assert Map.delete(actual, "snapshot_hash") == expected
  end

  @tag :tmp_dir
  test "isolates malformed and unsupported canonical input", %{tmp_dir: directory} do
    path = Path.join(directory, "version.jsonl")
    unsupported = Map.put(event("version", 1, "run-started"), "schema_version", 3)
    write_events(path, [unsupported])

    assert {:ok, unsupported_snapshot} =
             TraceSnapshot.start({:directory, directory}, owner: self())

    assert {:ok, %{run_count: 0}} = TraceSnapshot.info(unsupported_snapshot)
    assert :ok = TraceSnapshot.stop(unsupported_snapshot)

    File.write!(path, ~s({"schema_version":2,"schema_version":2}\n))

    assert {:ok, malformed_snapshot} =
             TraceSnapshot.start({:directory, directory}, owner: self())

    assert {:ok, %{run_count: 0}} = TraceSnapshot.info(malformed_snapshot)
    assert :ok = TraceSnapshot.stop(malformed_snapshot)
  end

  @tag :tmp_dir
  test "detects a directory file change between inventory and capture", %{tmp_dir: directory} do
    path = Path.join(directory, "before.jsonl")
    write_events(path, [event("before", 1, "run-started")])
    test = self()

    starter =
      Task.async(fn ->
        TraceSnapshot.start({:directory, directory},
          owner: test,
          capture_hook: fn ->
            send(test, {:inventory_captured, self()})

            receive do
              :continue_capture -> :ok
            end
          end
        )
      end)

    assert_receive {:inventory_captured, capture_pid}, 5_000
    write_events(path, [event("after-with-different-size", 1, "run-started")])
    send(capture_pid, :continue_capture)

    assert {:error, :source_changed} = Task.await(starter)
  end

  @tag :tmp_dir
  test "detects a same-size rewrite after the baseline content read", %{tmp_dir: directory} do
    path = Path.join(directory, "before.jsonl")
    before = event("before", 1, "run-started")
    after_rewrite = event("change", 1, "run-started")
    assert byte_size(Jason.encode!(before)) == byte_size(Jason.encode!(after_rewrite))
    write_events(path, [before])
    test = self()

    starter =
      Task.async(fn ->
        TraceSnapshot.start({:directory, directory},
          owner: test,
          capture_hook: fn ->
            send(test, {:baseline_captured, self()})

            receive do
              :continue_capture -> :ok
            end
          end
        )
      end)

    assert_receive {:baseline_captured, capture_pid}, 5_000
    write_events(path, [after_rewrite])
    send(capture_pid, :continue_capture)

    assert {:error, :source_changed} = Task.await(starter)
  end

  @tag :tmp_dir
  test "detects a same-size rewrite during the final inventory", %{tmp_dir: directory} do
    path = Path.join(directory, "before.jsonl")
    before = event("before", 1, "run-started")
    after_rewrite = event("change", 1, "run-started")
    assert byte_size(Jason.encode!(before)) == byte_size(Jason.encode!(after_rewrite))
    write_events(path, [before])
    test = self()

    starter =
      Task.async(fn ->
        TraceSnapshot.start({:directory, directory},
          owner: test,
          listing_hook: fn ->
            send(test, {:inventory_listing, self()})

            receive do
              :continue_listing -> :ok
            end
          end
        )
      end)

    for _inventory <- 1..2 do
      assert_receive {:inventory_listing, listing_pid}, 5_000
      send(listing_pid, :continue_listing)
    end

    assert_receive {:inventory_listing, final_listing_pid}, 5_000
    write_events(path, [after_rewrite])
    send(final_listing_pid, :continue_listing)

    assert {:error, :source_changed} = Task.await(starter)
  end

  @tag :tmp_dir
  test "the token and owner control snapshot lifetime", %{tmp_dir: directory} do
    write_events(Path.join(directory, "owned.jsonl"), [event("owned", 1, "run-started")])

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: owner)
    snapshot_ref = Process.monitor(snapshot.pid)
    assert {:ok, capabilities} = RunAnalysisCapability.from_snapshots(snapshot)
    list_runs = Enum.find(capabilities, &(&1.name == "analysis-runs"))

    forged = %{snapshot | token: make_ref()}
    assert {:error, :invalid_snapshot} = TraceSnapshot.info(forged)

    send(owner, :stop)
    assert_receive {:DOWN, ^snapshot_ref, :process, _, :normal}, 5_000
    assert {:error, :snapshot_unavailable} = TraceSnapshot.info(snapshot)
    assert :ok = TraceSnapshot.stop(snapshot)
    assert :ok = TraceSnapshot.stop(snapshot)

    assert {:error, %{kind: :internal, details: "analysis snapshot unavailable"} = error} =
             list_runs.callback.(%{})

    refute inspect(error) =~ directory
  end

  @tag :tmp_dir
  test "owner death cancels snapshot construction", %{tmp_dir: directory} do
    write_events(Path.join(directory, "owned.jsonl"), [event("owned", 1, "run-started")])
    test = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    starter =
      Task.async(fn ->
        TraceSnapshot.start({:directory, directory},
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

    dead_owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    dead_ref = Process.monitor(dead_owner)
    send(dead_owner, :stop)
    assert_receive {:DOWN, ^dead_ref, :process, ^dead_owner, :normal}, 5_000

    assert {:error, :snapshot_unavailable} =
             TraceSnapshot.start({:directory, directory}, owner: dead_owner)
  end

  @tag :tmp_dir
  test "owner death cancels bounded directory enumeration", %{tmp_dir: directory} do
    write_events(Path.join(directory, "owned.jsonl"), [event("owned", 1, "run-started")])
    test = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    starter =
      Task.async(fn ->
        TraceSnapshot.start({:directory, directory},
          owner: owner,
          listing_hook: fn ->
            send(test, {:listing_paused, self()})

            receive do
              :continue_listing -> :ok
            end
          end
        )
      end)

    assert_receive {:listing_paused, listing_pid}, 5_000
    listing_ref = Process.monitor(listing_pid)
    Process.exit(owner, :kill)

    assert {:error, :snapshot_unavailable} = Task.await(starter)
    assert_receive {:DOWN, ^listing_ref, :process, ^listing_pid, :killed}, 5_000
  end

  @tag :tmp_dir
  test "snapshot-backed capabilities retain only the opaque handle", %{tmp_dir: directory} do
    write_events(Path.join(directory, "capability.jsonl"), [event("capability", 1, "run-started")])

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)
    assert {:ok, capabilities} = RunAnalysisCapability.from_snapshots(snapshot)

    list_runs = Enum.find(capabilities, &(&1.name == "analysis-runs"))
    assert {:ok, %{"items" => [%{"run_id" => "capability"}]}} = list_runs.callback.(%{})

    {:env, closure_environment} = :erlang.fun_info(list_runs.callback, :env)

    assert Enum.any?(closure_environment, fn
             %PtcRunner.Kernel.RunAnalysis{traces: %TraceSnapshot{}} -> true
             _other -> false
           end)

    refute inspect(closure_environment) =~ directory
  end

  test "rejects unknown snapshot sources" do
    assert {:error, :invalid_snapshot} = TraceSnapshot.start({:private_directory, "traces"})
    assert {:error, :invalid_snapshot} = TraceSnapshot.start("traces")
    assert {:error, :invalid_snapshot} = TraceSnapshot.start({:file, "trace.jsonl"})
  end

  defp write_events(path, events) do
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp collect_runs(snapshot, first_page, max_result_bytes) do
    collect_runs(snapshot, first_page["next_cursor"], first_page["items"], max_result_bytes)
  end

  defp collect_runs(_snapshot, nil, items, _max_result_bytes), do: items

  defp collect_runs(snapshot, cursor, items, max_result_bytes) do
    assert {:ok, page} = TraceSnapshot.query(snapshot, :list_runs, %{"cursor" => cursor})
    assert page["items"] != []
    assert byte_size(Jason.encode!(page)) <= max_result_bytes
    assert RetainedSize.bytes(page) <= max_result_bytes

    collect_runs(snapshot, page["next_cursor"], items ++ page["items"], max_result_bytes)
  end

  defp event(run_id, sequence, type) do
    data =
      case type do
        "run-started" -> %{"missions" => %{}}
        "run-stopped" -> %{"outcome" => "ok"}
        _other -> %{}
      end

    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-19T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
