defmodule PtcRunner.Kernel.TraceSnapshotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot

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
    path = Path.join(directory, "normal.jsonl")
    private_path = Path.join(directory, "hidden.private.jsonl")
    inspection_path = Path.join(directory, "hidden.inspection.jsonl")

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
  test "snapshot cursors remain bound to the immutable capture", %{tmp_dir: directory} do
    write_events(Path.join(directory, "a.jsonl"), [event("first", 1, "run-started")])
    write_events(Path.join(directory, "b.jsonl"), [event("second", 1, "run-started")])

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, %{"items" => [_], "next_cursor" => cursor}} =
             TraceSnapshot.query(snapshot, :list_runs, %{"limit" => 1})

    write_events(Path.join(directory, "c.jsonl"), [event("third", 1, "run-started")])

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

    write_events(Path.join(directory, "trace.jsonl"), [oversized])

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
  test "safe metadata is bounded and contains no source path", %{tmp_dir: directory} do
    path = Path.join(directory, "trace.jsonl")
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
    write_events(Path.join(directory, "trace.jsonl"), [event("stable", 1, "run-started")])

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
    path = Path.join(directory, "trace.jsonl")
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
    write_events(Path.join(directory, "trace.jsonl"), [event("bounded", 1, "run-started")])

    assert {:error, :source_retained_limit_exceeded} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               capture_heap_words: 233
             )
  end

  @tag :tmp_dir
  test "construction limits may be lowered but not raised", %{tmp_dir: directory} do
    write_events(Path.join(directory, "trace.jsonl"), [event("bounded", 1, "run-started")])

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
    write_events(Path.join(directory, "trace.jsonl"), [event("bounded", 1, "run-started")])

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
    path = Path.join(directory, "a.jsonl")
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
  test "fails closed on malformed and unsupported canonical input", %{tmp_dir: directory} do
    path = Path.join(directory, "trace.jsonl")
    unsupported = Map.put(event("version", 1, "run-started"), "schema_version", 2)
    write_events(path, [unsupported])

    assert {:error, :unsupported_version} =
             TraceSnapshot.start({:directory, directory}, owner: self())

    File.write!(path, ~s({"schema_version":1,"schema_version":1}\n))

    assert {:error, :malformed_source} =
             TraceSnapshot.start({:directory, directory}, owner: self())
  end

  @tag :tmp_dir
  test "detects a directory file change between inventory and capture", %{tmp_dir: directory} do
    path = Path.join(directory, "trace.jsonl")
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
    path = Path.join(directory, "trace.jsonl")
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
    path = Path.join(directory, "trace.jsonl")
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
    write_events(Path.join(directory, "trace.jsonl"), [event("owned", 1, "run-started")])

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: owner)
    snapshot_ref = Process.monitor(snapshot.pid)
    assert {:ok, capabilities} = TraceCapability.from_snapshot(snapshot)
    list_runs = Enum.find(capabilities, &(&1.name == "trace-list-runs"))

    forged = %{snapshot | token: make_ref()}
    assert {:error, :invalid_snapshot} = TraceSnapshot.info(forged)

    send(owner, :stop)
    assert_receive {:DOWN, ^snapshot_ref, :process, _, :normal}, 5_000
    assert {:error, :snapshot_unavailable} = TraceSnapshot.info(snapshot)
    assert :ok = TraceSnapshot.stop(snapshot)
    assert :ok = TraceSnapshot.stop(snapshot)

    assert {:error, %{kind: :internal, details: "trace source unavailable"} = error} =
             list_runs.callback.(%{})

    refute inspect(error) =~ directory
  end

  @tag :tmp_dir
  test "owner death cancels snapshot construction", %{tmp_dir: directory} do
    write_events(Path.join(directory, "trace.jsonl"), [event("owned", 1, "run-started")])
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
    write_events(Path.join(directory, "trace.jsonl"), [event("owned", 1, "run-started")])
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
    write_events(Path.join(directory, "trace.jsonl"), [event("capability", 1, "run-started")])

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)
    assert {:ok, capabilities} = TraceCapability.from_snapshot(snapshot)

    list_runs = Enum.find(capabilities, &(&1.name == "trace-list-runs"))
    assert {:ok, %{"items" => [%{"run_id" => "capability"}]}} = list_runs.callback.(%{})

    {:env, closure_environment} = :erlang.fun_info(list_runs.callback, :env)
    assert Enum.any?(closure_environment, &match?(%TraceSnapshot{}, &1))
    refute inspect(closure_environment) =~ directory
  end

  test "rejects anything except a host-selected normal directory" do
    assert {:error, :invalid_snapshot} = TraceSnapshot.start({:file, "trace.jsonl"})
    assert {:error, :invalid_snapshot} = TraceSnapshot.start({:private_directory, "traces"})
    assert {:error, :invalid_snapshot} = TraceSnapshot.start("traces")
  end

  defp write_events(path, events) do
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp event(run_id, sequence, type) do
    %{
      "schema_version" => 1,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-19T12:00:00Z",
      "type" => type,
      "data" => if(type == "run-stopped", do: %{"outcome" => "ok"}, else: %{})
    }
  end
end
