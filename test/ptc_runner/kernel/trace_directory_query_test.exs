defmodule PtcRunner.Kernel.TraceDirectoryQueryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Lisp.RetainedSize

  @tag :tmp_dir
  test "direct and snapshot queries share one isolated directory admission", %{tmp_dir: directory} do
    write_events(directory, "healthy.jsonl", [event("healthy", "trace-healthy", 1)])
    File.write!(Path.join(directory, "broken.jsonl"), "not-json\n")
    File.write!(Path.join(directory, "private.private.jsonl"), "not-json\n")

    assert {:ok, trace_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    for {operation, arguments} <- [
          {:list_runs, %{}},
          {:get_run, %{"run_id" => "healthy"}},
          {:list_turns, %{"run_id" => "healthy"}},
          {:counters, %{}}
        ] do
      assert {:ok, direct} = TraceLog.query(trace_log, operation, arguments)
      assert {:ok, frozen} = TraceSnapshot.query(snapshot, operation, arguments)
      assert Map.delete(frozen, "snapshot_hash") == direct
    end

    for operation <- [:get_run, :list_turns] do
      assert {:error, :run_isolated} =
               TraceLog.query(trace_log, operation, %{"run_id" => "broken"})

      assert {:error, :run_isolated} =
               TraceSnapshot.query(snapshot, operation, %{"run_id" => "broken"})

      assert {:error, :not_found} =
               TraceLog.query(trace_log, operation, %{"run_id" => "absent"})

      assert {:error, :not_found} =
               TraceSnapshot.query(snapshot, operation, %{"run_id" => "absent"})

      assert {:error, :not_found} =
               TraceLog.query(trace_log, operation, %{"run_id" => "private"})

      assert {:error, :not_found} =
               TraceSnapshot.query(snapshot, operation, %{"run_id" => "private"})
    end

    assert {:error, :run_isolated} = TraceSnapshot.run_exists?(snapshot, "broken")

    assert {:ok, capabilities} = RunAnalysisCapability.from_snapshots(snapshot)
    open = Enum.find(capabilities, &(&1.name == "analysis-open"))
    read = Enum.find(capabilities, &(&1.name == "analysis-read"))

    for {capability, arguments} <- [
          {open, %{"run_id" => "broken"}},
          {read, %{"run_id" => "broken", "collection" => "turns"}}
        ] do
      assert {:error,
              %ProviderError{
                kind: :unavailable,
                details: "analysis run is isolated by damaged trace evidence",
                retryable?: false
              }} = capability.callback.(arguments)
    end
  end

  @tag :tmp_dir
  test "direct cursors bind isolation evidence while snapshot cursors stay frozen", %{
    tmp_dir: directory
  } do
    write_events(directory, "a.jsonl", [event("a", "trace-a", 1)])
    write_events(directory, "b.jsonl", [event("b", "trace-b", 1)])
    File.write!(Path.join(directory, "broken.jsonl"), "bad\n")

    assert {:ok, trace_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, %{"next_cursor" => direct_cursor}} =
             TraceLog.query(trace_log, :list_runs, %{"limit" => 1})

    assert {:ok, %{"next_cursor" => snapshot_cursor}} =
             TraceSnapshot.query(snapshot, :list_runs, %{"limit" => 1})

    File.write!(Path.join(directory, "broken.jsonl"), "different-bad\n")

    assert {:error, :source_changed} =
             TraceLog.query(trace_log, :list_runs, %{"limit" => 1, "cursor" => direct_cursor})

    assert {:ok, %{"items" => [_]}} =
             TraceSnapshot.query(snapshot, :list_runs, %{
               "limit" => 1,
               "cursor" => snapshot_cursor
             })
  end

  @tag :tmp_dir
  test "direct directory construction and admission share the hard ceilings", %{
    tmp_dir: directory
  } do
    for {option, value} <- [
          {:max_source_bytes, 8_000_001},
          {:max_retained_bytes, 32_000_001},
          {:max_result_bytes, 1_000_001},
          {:max_directory_entries, 4_097},
          {:max_trace_files, 1_025}
        ] do
      assert {:error, :invalid_trace_log} =
               TraceLog.new([{:source, {:directory, directory}}, {option, value}])
    end

    write_events(directory, "one.jsonl", [event("one", "trace-one", 1)])
    write_events(directory, "two.jsonl", [event("two", "trace-two", 1)])

    assert {:ok, entry_limited} =
             TraceLog.new(source: {:directory, directory}, max_directory_entries: 1)

    assert {:error, :source_limit_exceeded} = TraceLog.query(entry_limited, :list_runs, %{})

    assert {:ok, file_limited} =
             TraceLog.new(source: {:directory, directory}, max_trace_files: 1)

    assert {:error, :source_limit_exceeded} = TraceLog.query(file_limited, :list_runs, %{})

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)
    assert {:ok, %{retained_bytes: retained_bytes}} = TraceSnapshot.info(snapshot)

    assert {:ok, exact} =
             TraceLog.new(
               source: {:directory, directory},
               max_retained_bytes: retained_bytes
             )

    assert {:ok, %{"items" => [_, _]}} = TraceLog.query(exact, :list_runs, %{})

    assert {:ok, too_small} =
             TraceLog.new(
               source: {:directory, directory},
               max_retained_bytes: retained_bytes - 1
             )

    assert {:error, :source_retained_limit_exceeded} =
             TraceLog.query(too_small, :list_runs, %{})
  end

  @tag :tmp_dir
  test "directory-only limits do not change explicit file and sink construction", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "aggregate.any-name.jsonl")
    write_events(directory, Path.basename(path), [event("one", "trace-one", 1)])

    for source <- [{:file, path}, start_sink()] do
      if match?(%EventSink{}, source), do: on_exit(fn -> EventSink.stop(source) end)

      assert {:ok, _trace_log} =
               TraceLog.new(
                 source: source,
                 max_source_bytes: 8_000_001,
                 max_result_bytes: 1_000_001
               )

      for option <- [:max_retained_bytes, :max_directory_entries, :max_trace_files] do
        assert {:error, :invalid_trace_log} =
                 TraceLog.new([{:source, source}, {option, 1}])
      end
    end
  end

  @tag :tmp_dir
  test "direct and snapshot pages reserve the same exact result budget", %{tmp_dir: directory} do
    for index <- 1..4 do
      rich_event =
        event("run-#{index}", "trace-#{index}", 1)
        |> put_in(["data", "labels"], %{
          "name" => String.duplicate("n", 128),
          "tags" => %{"suite" => "integration", "stage" => "validating"}
        })

      write_events(directory, "run-#{index}.jsonl", [rich_event])
    end

    assert {:ok, unbounded} = TraceLog.new(source: {:directory, directory})
    assert {:ok, full_direct} = TraceLog.query(unbounded, :list_runs, %{})

    exact_direct_bytes =
      max(byte_size(Jason.encode!(full_direct)), RetainedSize.bytes(full_direct))

    assert {:ok, direct} =
             TraceLog.new(
               source: {:directory, directory},
               max_result_bytes: exact_direct_bytes
             )

    assert {:ok, snapshot} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_result_bytes: exact_direct_bytes
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, direct_page} = TraceLog.query(direct, :list_runs, %{})
    assert {:ok, snapshot_page} = TraceSnapshot.query(snapshot, :list_runs, %{})
    assert Map.delete(snapshot_page, "snapshot_hash") == direct_page
    assert length(direct_page["items"]) < 4
  end

  @tag :tmp_dir
  test "direct admission does not trap an arbitrary caller's linked exits", %{tmp_dir: directory} do
    write_events(directory, "healthy.jsonl", [event("healthy", "trace-healthy", 1)])
    assert {:ok, trace_log} = TraceLog.new(source: {:directory, directory})
    test = self()
    linked = spawn(fn -> receive do: (:fail -> exit(:linked_failure)) end)

    caller =
      spawn(fn ->
        Process.link(linked)

        receive do
          :query -> send(test, {:query_result, TraceLog.query(trace_log, :list_runs, %{})})
        end
      end)

    caller_ref = Process.monitor(caller)
    :erlang.trace(caller, true, [:procs, :set_on_spawn])
    send(caller, :query)

    assert_receive {:trace, ^caller, :spawn, guard, _spawned}, 5_000
    assert_receive {:trace, ^guard, :spawn, worker, _spawned}, 5_000
    worker_ref = Process.monitor(worker)
    true = :erlang.suspend_process(worker)
    send(linked, :fail)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :linked_failure}, 5_000
    refute_receive {:query_result, _result}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 5_000
  end

  defp write_events(directory, name, events) do
    encoded = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
    File.write!(Path.join(directory, name), encoded)
  end

  defp start_sink do
    {:ok, sink} = EventSink.start(:normal, Limits.defaults())
    sink
  end

  defp event(run_id, trace_id, sequence) do
    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => trace_id,
      "sequence" => sequence,
      "timestamp" => "2026-08-26T00:00:00Z",
      "type" => "run-started",
      "data" => %{"missions" => %{}}
    }
  end
end
