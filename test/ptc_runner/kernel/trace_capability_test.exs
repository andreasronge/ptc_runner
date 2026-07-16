defmodule PtcRunner.Kernel.TraceCapabilityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "log.core requires source-scoped query capabilities" do
    assert {:ok, component} = Library.component("log.core")
    assert {:ok, bundle} = Kernel.compile_bundle([component])

    assert {:error,
            {:missing_capability_requirement,
             ["trace-counters", "trace-get-run", "trace-list-runs", "trace-list-turns"]}} =
             MissionEnvironment.new(bundle: bundle)
  end

  test "an in-memory grant exposes canonical metadata, turns, counters, and stable pages" do
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "visible", trace_id: "trace-visible")
    run_kernel(sink, limits)

    assert {:ok, capabilities} = TraceCapability.new(source: sink, max_result_bytes: 100_000)

    assert Enum.all?(capabilities, fn capability ->
             match?(
               %{
                 effect: :read,
                 input_schema: %{"additionalProperties" => true},
                 output_schema: %{"additionalProperties" => true}
               },
               Capability.metadata(capability)
             )
           end)

    callbacks = Map.new(capabilities, &{&1.name, &1.callback})

    assert {:ok, first_page} = callbacks["trace-list-runs"].(%{"limit" => 1})
    assert [%{"run_id" => "visible"} = metadata] = first_page["items"]
    assert metadata["trace_id"] == "trace-visible"
    assert metadata["status"] == "ok"
    assert metadata["complete"]
    assert metadata["subordinate_evaluations"] == 0
    assert metadata["workflow_capability_calls"] == 0
    assert metadata["mission_capability_calls"] == 0
    assert metadata["error_count"] == 0
    assert is_integer(metadata["duration_ms"])
    assert metadata["workflow_prelude"] == %{"component_ids" => [], "hash" => nil}
    assert metadata["mission_prelude"] == %{"component_ids" => [], "hash" => nil}
    assert first_page["next_cursor"] == nil

    assert {:ok, turns} =
             callbacks["trace-list-turns"].(%{
               "run_id" => "visible",
               "status" => "ok",
               "limit" => 10
             })

    assert Enum.map(turns["items"], & &1["type"]) == ["evaluation-stopped", "run-stopped"]

    assert {:ok,
            %{
              "events" => 4,
              "runs" => 1,
              "errors" => 0,
              "evaluations" => 1,
              "workflow_capability_calls" => 0,
              "mission_capability_calls" => 0
            }} = callbacks["trace-counters"].(%{"run_id" => "visible"})

    assert {:error, %{kind: :invalid_request}} =
             callbacks["trace-list-runs"].(%{"cursor" => 1})
  end

  test "a trace grant never discovers runs in another sink" do
    {:ok, limits} = Limits.new()
    {:ok, visible} = EventSink.start(:normal, limits, run_id: "visible")
    {:ok, hidden} = EventSink.start(:normal, limits, run_id: "hidden")
    run_kernel(visible, limits)
    run_kernel(hidden, limits)

    {:ok, capabilities} = TraceCapability.new(source: visible)
    list_runs = Enum.find(capabilities, &(&1.name == "trace-list-runs"))

    assert {:ok, %{"items" => [%{"run_id" => "visible"}]}} = list_runs.callback.(%{})
  end

  test "private memory traces require a distinct explicit grant" do
    {:ok, limits} = Limits.new()
    {:ok, private_sink} = EventSink.start(:private, limits, run_id: "private")
    run_kernel(private_sink, limits)

    assert {:error, :invalid_trace_capability} = TraceCapability.new(source: private_sink)
    assert {:ok, capabilities} = TraceCapability.new(source: {:private, private_sink})
    list_runs = Enum.find(capabilities, &(&1.name == "trace-list-runs"))

    assert {:ok, %{"items" => [%{"source" => "private"}]}} = list_runs.callback.(%{})
  end

  test "log.core queries the granted source from a mission without workflow inheritance" do
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, source_sink} = EventSink.start(:normal, limits, run_id: "source-run")
    run_kernel(source_sink, limits)

    {:ok, trace_capabilities} = TraceCapability.new(source: source_sink)
    {:ok, kernel_component} = Library.component("kernel")
    {:ok, log_component} = Library.component("log.core")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, mission_bundle} = Kernel.compile_bundle([log_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)

    {:ok, mission} =
      MissionEnvironment.new(bundle: mission_bundle, capabilities: trace_capabilities)

    {:ok, run_sink} = EventSink.start(:normal, limits, run_id: "query-run")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: run_sink
      )

    assert {:ok, %{value: %{outcome: :returned, value: %{"items" => [metadata]}}}} =
             Kernel.run(
               "(return (kernel/eval (program (return (log/runs {\"limit\" 1})))))",
               config
             )

    assert metadata["run_id"] == "source-run"

    assert {:error, %{kind: :workflow_failed}} =
             Kernel.run("(return (tool/trace-list-runs {}))", config)
  end

  @tag :tmp_dir
  test "canonical JSONL append and reload preserves event order", %{tmp_dir: directory} do
    path = Path.join(directory, "trace.jsonl")
    first = decoded_event("append", 1, "run-started")
    second = decoded_event("append", 2, "run-stopped", %{"outcome" => "ok"})

    assert :ok = TraceLog.append_jsonl(path, [first])
    assert :ok = TraceLog.append_jsonl(path, [second])
    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"items" => [%{"run_id" => "append", "complete" => true}]}} =
             TraceLog.query(trace_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "private JSONL sources require reserved names and explicit grants", %{tmp_dir: directory} do
    normal_path = Path.join(directory, "normal.jsonl")
    private_path = Path.join(directory, "secret.private.jsonl")
    normal_event = decoded_event("normal", 1, "run-started")
    private_event = decoded_event("private", 1, "run-started")

    assert :ok = TraceLog.append_jsonl(normal_path, [normal_event])
    assert :ok = TraceLog.append_jsonl(private_path, [private_event], private: true)

    assert {:error, :invalid_trace_log} =
             TraceLog.append_jsonl(normal_path, [private_event], private: true)

    assert {:error, :invalid_trace_log} = TraceLog.append_jsonl(private_path, [normal_event])
    assert {:error, :invalid_trace_log} = TraceLog.new(source: {:file, private_path})
    assert {:ok, private_log} = TraceLog.new(source: {:private_file, private_path})
    assert {:ok, normal_log} = TraceLog.new(source: {:directory, directory})

    assert {:ok, private_directory_log} =
             TraceLog.new(source: {:private_directory, directory})

    assert {:ok, %{"items" => [%{"run_id" => "normal", "source" => "sanitized"}]}} =
             TraceLog.query(normal_log, :list_runs, %{})

    assert {:ok, %{"items" => [%{"run_id" => "private", "source" => "private"}]}} =
             TraceLog.query(private_log, :list_runs, %{})

    assert {:ok, %{"items" => [%{"run_id" => "private", "source" => "private"}]}} =
             TraceLog.query(private_directory_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "inspection artifacts are never accepted as canonical or private trace sources", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "run.inspection.jsonl")
    File.write!(path, jsonl_event("inspection", 1, "run-started"))

    assert {:error, :invalid_trace_log} = TraceLog.new(source: {:file, path})
    assert {:error, :invalid_trace_log} = TraceLog.new(source: {:private_file, path})

    assert {:ok, normal_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, private_log} = TraceLog.new(source: {:private_directory, directory})
    assert {:ok, %{"items" => []}} = TraceLog.query(normal_log, :list_runs, %{})
    assert {:ok, %{"items" => []}} = TraceLog.query(private_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "file and directory grants reject malformed, duplicate, changed, and oversized sources", %{
    tmp_dir: directory
  } do
    first = Path.join(directory, "a.jsonl")
    second = Path.join(directory, "b.jsonl")
    malformed = Path.join(directory, "c.jsonl")

    File.write!(first, jsonl_event("first", 1, "run-started"))
    File.write!(second, jsonl_event("second", 1, "run-started"))

    {:ok, capabilities} = TraceCapability.new(source: {:directory, directory})
    list_runs = Enum.find(capabilities, &(&1.name == "trace-list-runs"))

    assert {:ok, %{"items" => items}} = list_runs.callback.(%{"limit" => 1})
    assert length(items) == 1

    assert {:ok, %{"next_cursor" => cursor}} = list_runs.callback.(%{"limit" => 1})
    assert is_binary(cursor)

    File.write!(second, jsonl_event("changed", 1, "run-started"))

    assert {:error, %{kind: :invalid_request, details: "trace source changed"}} =
             list_runs.callback.(%{"limit" => 1, "cursor" => cursor})

    File.write!(malformed, ~s({"schema_version":1,"schema_version":1}\n))

    assert {:error, %{kind: :invalid_request, details: "malformed trace source"}} =
             list_runs.callback.(%{})

    assert {:ok, file_capabilities} =
             TraceCapability.new(source: {:file, first}, max_source_bytes: 1)

    file_runs = Enum.find(file_capabilities, &(&1.name == "trace-list-runs"))

    assert {:error, %{kind: :invalid_request, details: "trace source limit exceeded"}} =
             file_runs.callback.(%{})
  end

  @tag :tmp_dir
  test "cursors are bound to their operation and filters", %{tmp_dir: directory} do
    File.write!(Path.join(directory, "a.jsonl"), jsonl_event("first", 1, "run-started"))
    File.write!(Path.join(directory, "b.jsonl"), jsonl_event("second", 1, "run-started"))

    {:ok, trace_log} = TraceLog.new(source: {:directory, directory})

    assert {:ok, %{"next_cursor" => cursor}} =
             TraceLog.query(trace_log, :list_runs, %{"limit" => 1})

    assert {:error, :invalid_query} =
             TraceLog.query(trace_log, :list_runs, %{
               "limit" => 1,
               "status" => "ok",
               "cursor" => cursor
             })

    assert {:error, :invalid_query} =
             TraceLog.query(trace_log, :list_turns, %{
               "run_id" => "first",
               "cursor" => cursor
             })
  end

  @tag :tmp_dir
  test "canonical validation preserves version failures and rejects mixed run identity", %{
    tmp_dir: directory
  } do
    version_path = Path.join(directory, "version.jsonl")
    mixed_path = Path.join(directory, "mixed.jsonl")
    shared_trace_path = Path.join(directory, "shared-trace.jsonl")
    unsupported = Map.put(decoded_event("version", 1, "run-started"), "schema_version", 2)
    mixed = [decoded_event("same", 1, "run-started"), decoded_event("same", 1, "run-stopped")]
    mixed = put_in(mixed, [Access.at(1), "trace_id"], "different-trace")

    shared_trace = [
      decoded_event("first", 1, "run-started"),
      decoded_event("second", 2, "run-started")
    ]

    shared_trace = put_in(shared_trace, [Access.at(1), "trace_id"], "trace-first")
    File.write!(version_path, Jason.encode!(unsupported) <> "\n")
    File.write!(mixed_path, Enum.map_join(mixed, "", &(Jason.encode!(&1) <> "\n")))
    File.write!(shared_trace_path, Enum.map_join(shared_trace, "", &(Jason.encode!(&1) <> "\n")))

    {:ok, version_log} = TraceLog.new(source: {:file, version_path})
    {:ok, mixed_log} = TraceLog.new(source: {:file, mixed_path})
    {:ok, shared_trace_log} = TraceLog.new(source: {:file, shared_trace_path})
    assert {:error, :unsupported_version} = TraceLog.query(version_log, :list_runs, %{})
    assert {:error, :malformed_source} = TraceLog.query(mixed_log, :list_runs, %{})
    assert {:error, :malformed_source} = TraceLog.query(shared_trace_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "timestamp filters compare instants rather than timestamp spelling", %{tmp_dir: directory} do
    path = Path.join(directory, "timestamp.jsonl")
    event = %{decoded_event("time", 1, "run-started") | "timestamp" => "2026-07-12T12:00:00.1Z"}
    File.write!(path, Jason.encode!(event) <> "\n")
    {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"items" => [%{"run_id" => "time"}]}} =
             TraceLog.query(trace_log, :list_runs, %{"to" => "2026-07-12T12:00:00.10Z"})
  end

  defp run_kernel(sink, limits) do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, _result} = Kernel.run("(return 42)", config)
  end

  defp jsonl_event(run_id, sequence, type) do
    Jason.encode!(decoded_event(run_id, sequence, type)) <> "\n"
  end

  defp decoded_event(run_id, sequence, type, data \\ %{}) do
    %{
      "schema_version" => 1,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-12T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
