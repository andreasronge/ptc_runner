defmodule PtcRunner.Kernel.TraceDirectoryQueryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.TestSupport.TraceQuery

  @tag :tmp_dir
  test "direct and snapshot queries share one isolated directory admission", %{tmp_dir: directory} do
    write_events(directory, "healthy.jsonl", [event("healthy", "trace-healthy", 1)])
    File.write!(Path.join(directory, "broken.jsonl"), "not-json\n")
    File.write!(Path.join(directory, "private.private.jsonl"), "not-json\n")

    assert {:ok, trace_log} = TraceQuery.new(source: {:directory, directory})
    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    for {operation, arguments} <- [
          {:list_runs, %{}},
          {:get_run, %{"run_id" => "healthy"}},
          {:list_turns, %{"run_id" => "healthy"}},
          {:counters, %{}}
        ] do
      assert {:ok, direct} = TraceQuery.query(trace_log, operation, arguments)
      assert {:ok, frozen} = TraceSnapshot.query(snapshot, operation, arguments)
      assert Map.delete(frozen, "snapshot_hash") == direct
    end

    for operation <- [:get_run, :list_turns] do
      assert {:error, :run_isolated} =
               TraceQuery.query(trace_log, operation, %{"run_id" => "broken"})

      assert {:error, :run_isolated} =
               TraceSnapshot.query(snapshot, operation, %{"run_id" => "broken"})

      assert {:error, :not_found} =
               TraceQuery.query(trace_log, operation, %{"run_id" => "absent"})

      assert {:error, :not_found} =
               TraceSnapshot.query(snapshot, operation, %{"run_id" => "absent"})

      assert {:error, :not_found} =
               TraceQuery.query(trace_log, operation, %{"run_id" => "private"})

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
  test "directory catalog queries report exact bounded isolation evidence", %{
    tmp_dir: directory
  } do
    write_events(directory, "healthy.jsonl", [event("healthy", "trace-healthy", 1)])
    write_events(directory, "healthy-two.jsonl", [event("healthy-two", "trace-healthy-two", 1)])
    File.write!(Path.join(directory, "broken.jsonl"), "not-json\n")

    write_events(directory, "alpha.jsonl", [event("shared", "trace-alpha", 1)])
    write_events(directory, "beta.jsonl", [event("shared", "trace-beta", 1)])

    expected = %{
      "component_count" => 2,
      "source_count" => 3,
      "known_run_count" => 4,
      "reasons" => [
        %{"reason" => "malformed_jsonl", "component_count" => 1, "source_count" => 1},
        %{
          "reason" => "filename_run_mismatch",
          "component_count" => 1,
          "source_count" => 2
        },
        %{
          "reason" => "run_identity_conflict",
          "component_count" => 1,
          "source_count" => 2
        }
      ],
      "examples" => [
        %{
          "sources" => ["alpha.jsonl", "beta.jsonl"],
          "source_count" => 2,
          "sources_omitted_count" => 0,
          "reasons" => ["filename_run_mismatch", "run_identity_conflict"]
        },
        %{
          "sources" => ["broken.jsonl"],
          "source_count" => 1,
          "sources_omitted_count" => 0,
          "reasons" => ["malformed_jsonl"]
        }
      ],
      "examples_omitted_count" => 0
    }

    assert {:ok, trace_log} = TraceQuery.new(source: {:directory, directory})
    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    for {operation, arguments} <- [
          {:list_runs, %{"limit" => 1}},
          {:list_runs, %{"status" => "absent"}},
          {:counters, %{"status" => "absent"}}
        ] do
      assert {:ok, %{"isolation" => ^expected} = direct} =
               TraceQuery.query(trace_log, operation, arguments)

      assert {:ok, %{"isolation" => ^expected} = frozen} =
               TraceSnapshot.query(snapshot, operation, arguments)

      assert Map.delete(frozen, "snapshot_hash") == direct
    end

    assert {:ok, %{"next_cursor" => cursor}} =
             TraceSnapshot.query(snapshot, :list_runs, %{"limit" => 1})

    assert {:ok, %{"isolation" => ^expected, "items" => [_]}} =
             TraceSnapshot.query(snapshot, :list_runs, %{"limit" => 1, "cursor" => cursor})

    assert {:ok, run} = TraceQuery.query(trace_log, :get_run, %{"run_id" => "healthy"})
    refute Map.has_key?(run, "isolation")

    assert {:ok, turns} = TraceSnapshot.query(snapshot, :list_turns, %{"run_id" => "healthy"})
    refute Map.has_key?(turns, "isolation")
  end

  @tag :tmp_dir
  test "isolation examples and source names have deterministic presentation caps", %{
    tmp_dir: directory
  } do
    for index <- 1..18 do
      File.write!(
        Path.join(directory, "broken-#{String.pad_leading(to_string(index), 2, "0")}.jsonl"),
        "bad\n"
      )
    end

    File.write!(Path.join(directory, "!.jsonl"), "bad\n")

    for index <- 1..10 do
      write_events(directory, "a-joined-#{index}.jsonl", [event("shared", "trace-#{index}", 1)])
    end

    assert {:ok, trace_log} = TraceQuery.new(source: {:directory, directory})
    assert {:ok, %{"isolation" => isolation}} = TraceQuery.query(trace_log, :list_runs, %{})

    assert isolation["component_count"] == 20
    assert isolation["source_count"] == 29
    assert isolation["known_run_count"] == 29
    assert length(isolation["examples"]) == 16
    assert isolation["examples_omitted_count"] == 4

    invalid = hd(isolation["examples"])
    assert invalid["sources"] == []
    assert invalid["source_count"] == 1
    assert invalid["sources_omitted_count"] == 1

    joined = Enum.find(isolation["examples"], &(&1["source_count"] == 10))
    assert length(joined["sources"]) == 8
    assert joined["sources"] == Enum.sort(joined["sources"])
    assert joined["sources_omitted_count"] == 2
  end

  @tag :tmp_dir
  test "result fitting drops isolation examples before canonical run items", %{
    tmp_dir: directory
  } do
    write_events(directory, "healthy.jsonl", [event("healthy", "trace-healthy", 1)])

    for index <- 1..4 do
      name = "#{String.duplicate("damaged", 12)}-#{index}.jsonl"
      File.write!(Path.join(directory, name), "bad\n")
    end

    assert {:ok, unbounded} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(unbounded) end)
    assert {:ok, full_page} = TraceSnapshot.query(unbounded, :list_runs, %{})
    assert length(full_page["isolation"]["examples"]) == 4

    fitted_isolation =
      full_page["isolation"]
      |> Map.put("examples", [])
      |> Map.put("examples_omitted_count", 4)

    expected_page = Map.put(full_page, "isolation", fitted_isolation)
    exact_bytes = max(byte_size(Jason.encode!(expected_page)), RetainedSize.bytes(expected_page))

    assert {:ok, snapshot} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_result_bytes: exact_bytes
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, ^expected_page} = TraceSnapshot.query(snapshot, :list_runs, %{})

    assert {:ok, direct} =
             TraceQuery.new(source: {:directory, directory}, max_result_bytes: exact_bytes)

    assert {:ok, direct_page} = TraceQuery.query(direct, :list_runs, %{})
    assert direct_page == Map.delete(expected_page, "snapshot_hash")

    assert {:ok, full_counters} = TraceSnapshot.query(unbounded, :counters, %{})

    expected_counters = Map.put(full_counters, "isolation", fitted_isolation)

    exact_counter_bytes =
      max(byte_size(Jason.encode!(expected_counters)), RetainedSize.bytes(expected_counters))

    assert {:ok, counter_snapshot} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_result_bytes: exact_counter_bytes
             )

    on_exit(fn -> TraceSnapshot.stop(counter_snapshot) end)
    assert {:ok, ^expected_counters} = TraceSnapshot.query(counter_snapshot, :counters, %{})

    assert {:ok, counter_direct} =
             TraceQuery.new(
               source: {:directory, directory},
               max_result_bytes: exact_counter_bytes
             )

    assert {:ok, direct_counters} = TraceQuery.query(counter_direct, :counters, %{})
    assert direct_counters == Map.delete(expected_counters, "snapshot_hash")

    assert {:ok, impossible} =
             TraceQuery.new(source: {:directory, directory}, max_result_bytes: 1)

    assert {:error, :result_limit_exceeded} = TraceQuery.query(impossible, :list_runs, %{})
    assert {:error, :result_limit_exceeded} = TraceQuery.query(impossible, :counters, %{})
  end

  @tag :tmp_dir
  test "direct cursors bind isolation evidence while snapshot cursors stay frozen", %{
    tmp_dir: directory
  } do
    write_events(directory, "a.jsonl", [event("a", "trace-a", 1)])
    write_events(directory, "b.jsonl", [event("b", "trace-b", 1)])
    File.write!(Path.join(directory, "broken.jsonl"), "bad\n")

    assert {:ok, trace_log} = TraceQuery.new(source: {:directory, directory})
    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, %{"next_cursor" => direct_cursor}} =
             TraceQuery.query(trace_log, :list_runs, %{"limit" => 1})

    assert {:ok, %{"next_cursor" => snapshot_cursor}} =
             TraceSnapshot.query(snapshot, :list_runs, %{"limit" => 1})

    File.write!(Path.join(directory, "broken.jsonl"), "different-bad\n")

    assert {:error, :source_changed} =
             TraceQuery.query(trace_log, :list_runs, %{"limit" => 1, "cursor" => direct_cursor})

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
    write_events(directory, "one.jsonl", [event("one", "trace-one", 1)])
    write_events(directory, "two.jsonl", [event("two", "trace-two", 1)])

    assert {:ok, entry_limited} =
             TraceQuery.new(source: {:directory, directory}, max_directory_entries: 1)

    assert {:error, :source_limit_exceeded} = TraceQuery.query(entry_limited, :list_runs, %{})

    assert {:ok, file_limited} =
             TraceQuery.new(source: {:directory, directory}, max_trace_files: 1)

    assert {:error, :source_limit_exceeded} = TraceQuery.query(file_limited, :list_runs, %{})

    assert {:ok, snapshot} = TraceSnapshot.start({:directory, directory}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(snapshot) end)
    assert {:ok, %{retained_bytes: retained_bytes}} = TraceSnapshot.info(snapshot)

    assert {:ok, exact} =
             TraceQuery.new(
               source: {:directory, directory},
               max_retained_bytes: retained_bytes
             )

    assert {:ok, %{"items" => [_, _]}} = TraceQuery.query(exact, :list_runs, %{})

    assert {:ok, too_small} =
             TraceQuery.new(
               source: {:directory, directory},
               max_retained_bytes: retained_bytes - 1
             )

    assert {:error, :source_retained_limit_exceeded} =
             TraceQuery.query(too_small, :list_runs, %{})
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

    assert {:ok, unbounded} = TraceQuery.new(source: {:directory, directory})
    assert {:ok, full_direct} = TraceQuery.query(unbounded, :list_runs, %{})

    exact_direct_bytes =
      max(byte_size(Jason.encode!(full_direct)), RetainedSize.bytes(full_direct))

    assert {:ok, direct} =
             TraceQuery.new(
               source: {:directory, directory},
               max_result_bytes: exact_direct_bytes
             )

    assert {:ok, snapshot} =
             TraceSnapshot.start({:directory, directory},
               owner: self(),
               max_result_bytes: exact_direct_bytes
             )

    on_exit(fn -> TraceSnapshot.stop(snapshot) end)

    assert {:ok, direct_page} = TraceQuery.query(direct, :list_runs, %{})
    assert {:ok, snapshot_page} = TraceSnapshot.query(snapshot, :list_runs, %{})
    assert Map.delete(snapshot_page, "snapshot_hash") == direct_page
    assert length(direct_page["items"]) < 4
  end

  @tag :tmp_dir
  test "direct admission does not trap an arbitrary caller's linked exits", %{tmp_dir: directory} do
    write_events(directory, "healthy.jsonl", [event("healthy", "trace-healthy", 1)])
    assert {:ok, trace_log} = TraceQuery.new(source: {:directory, directory})
    test = self()
    linked = spawn(fn -> receive do: (:fail -> exit(:linked_failure)) end)

    caller =
      spawn(fn ->
        Process.link(linked)

        receive do
          :query -> send(test, {:query_result, TraceQuery.query(trace_log, :list_runs, %{})})
        end
      end)

    caller_ref = Process.monitor(caller)
    :erlang.trace(caller, true, [:procs, :set_on_spawn])
    send(caller, :query)

    assert_receive {:trace, ^caller, :spawn, _guard, _spawned}, 5_000
    assert_receive {:trace, ^caller, :spawn, worker, _spawned}, 5_000
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
