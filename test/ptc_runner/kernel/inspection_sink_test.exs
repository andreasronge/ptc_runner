defmodule PtcRunner.Kernel.InspectionSinkTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.ViewerAdapter

  @source "(return 42)"
  @source_hash :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)

  test "retains only normalized exact V1 records and fails closed" do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-input",
               %{capability_id: "cap-1"},
               %{environment: :mission, name: "remote.read", arguments: %{"query" => "x"}}
             )

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-output",
               %{"capability_id" => "cap-1"},
               %{environment: :mission, name: "remote.read", result: %{status: :ok, value: 42}}
             )

    assert :ok =
             InspectionSink.emit(
               sink,
               "evaluation-source",
               %{evaluation_id: "eval-1"},
               %{
                 environment: :mission,
                 program_kind: :"ptc-lisp",
                 source: @source,
                 source_hash: @source_hash,
                 source_bytes: byte_size(@source)
               }
             )

    assert :ok =
             InspectionSink.emit(
               sink,
               "prelude-source",
               %{component_id: "tools"},
               %{
                 environment: :workflow,
                 source: @source,
                 source_hash: @source_hash,
                 source_bytes: byte_size(@source)
               }
             )

    assert {:ok, [input, output, source, prelude]} = InspectionSink.records(sink)
    assert Enum.map([input, output, source, prelude], & &1["sequence"]) == [1, 2, 3, 4]
    assert input["payload"]["environment"] == "mission"
    assert output["payload"]["result"] == %{"status" => "ok", "value" => 42}
    assert source["payload"]["source"] == @source
    assert prelude["correlation"] == %{"component_id" => "tools"}
    assert prelude["payload"]["environment"] == "workflow"
    assert prelude["payload"]["source"] == @source

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               sink,
               "capability-input",
               %{capability_id: "cap-2"},
               %{environment: :mission, name: "bad", arguments: %{}, extra: true}
             )

    assert {:error, :inspection_sink_error} = InspectionSink.records(sink)
    assert :ok = InspectionSink.stop(sink)
    assert :ok = InspectionSink.stop(sink)
  end

  test "V2 retains paired MCP exchange records while V1 rejects them" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "read", "arguments" => %{"path" => "README.md"}}
    }

    response = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "result" => %{"content" => [%{"type" => "text", "text" => "hello"}]}
    }

    correlation = %{capability_id: "cap-1", request_id: 7}

    {:ok, v1} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               v1,
               "mcp-request",
               correlation,
               %{transport: :stdio, body: request}
             )

    {:ok, v2} =
      InspectionSink.start(run_id: "run-1", trace_id: "trace-1", schema_version: 2)

    assert :ok =
             InspectionSink.emit(
               v2,
               "mcp-request",
               correlation,
               %{transport: :stdio, body: request}
             )

    assert :ok =
             InspectionSink.emit(
               v2,
               "mcp-response",
               correlation,
               %{transport: :stdio, body: response}
             )

    assert {:ok, [request_record, response_record]} = InspectionSink.records(v2)
    assert request_record["schema_version"] == 2
    assert request_record["payload"]["body"] == request
    assert response_record["payload"]["body"] == response
  end

  test "enforces installed per-record and aggregate encoded byte ceilings" do
    {:ok, record_limited} =
      InspectionSink.start(
        run_id: "run-1",
        trace_id: "trace-1",
        max_record_bytes: 400,
        max_total_bytes: 800
      )

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               record_limited,
               "capability-input",
               %{capability_id: "cap-1"},
               %{
                 environment: :mission,
                 name: "large",
                 arguments: %{"value" => String.duplicate("x", 1_000)}
               }
             )

    {:ok, total_limited} =
      InspectionSink.start(
        run_id: "run-1",
        trace_id: "trace-1",
        max_record_bytes: 1_200,
        max_total_bytes: 1_200
      )

    assert :ok = emit_small(total_limited, "cap-1")

    results = Enum.map(2..10, &emit_small(total_limited, "cap-#{&1}"))
    assert :ok in results
    assert {:error, :inspection_sink_error} in results
  end

  @tag :tmp_dir
  test "artifacts reject duplicate, output-only, and identity-mismatched joins", %{tmp_dir: dir} do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")
    assert :ok = emit_small(sink, "cap-1")

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-output",
               %{capability_id: "cap-1"},
               %{environment: :mission, name: "read", result: %{status: :ok, value: 1}}
             )

    assert {:ok, [input, output]} = InspectionSink.records(sink)

    events = [
      %{
        run_id: "run-1",
        trace_id: "trace-1",
        type: "capability-started",
        data: %{capability_id: "cap-1", environment: :mission, name: "read"}
      }
    ]

    duplicate_input = resequence([input, input])

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.persist(
               Path.join(dir, "duplicate-input.inspection.jsonl"),
               duplicate_input,
               events
             )

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.persist(
               Path.join(dir, "duplicate-output.inspection.jsonl"),
               resequence([input, output, output]),
               events
             )

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.persist(
               Path.join(dir, "output-only.inspection.jsonl"),
               resequence([output]),
               events
             )

    mismatched_output = put_in(output, ["payload", "name"], "other")

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.persist(
               Path.join(dir, "mismatched-pair.inspection.jsonl"),
               [input, mismatched_output],
               events
             )

    wrong_canonical_name = put_in(events, [Access.at(0), :data, :name], "other")

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations([input, output], wrong_canonical_name)

    wrong_canonical_environment =
      put_in(events, [Access.at(0), :data, :environment], :workflow)

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(
               [input, output],
               wrong_canonical_environment
             )

    duplicate_canonical = events ++ events

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(
               [input, output],
               duplicate_canonical
             )

    conflicting_canonical =
      events ++ [put_in(hd(events), [:data, :name], "other")]

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(
               [input, output],
               conflicting_canonical
             )

    {:ok, source_sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    for _index <- 1..2 do
      assert :ok =
               InspectionSink.emit(
                 source_sink,
                 "evaluation-source",
                 %{evaluation_id: "eval-1"},
                 %{
                   environment: :mission,
                   program_kind: :"ptc-lisp",
                   source: @source,
                   source_hash: @source_hash,
                   source_bytes: byte_size(@source)
                 }
               )
    end

    assert {:ok, duplicate_evaluations} = InspectionSink.records(source_sink)

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.persist(
               Path.join(dir, "duplicate-evaluation.inspection.jsonl"),
               duplicate_evaluations,
               []
             )

    {:ok, prelude_sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    for _index <- 1..2 do
      assert :ok =
               InspectionSink.emit(
                 prelude_sink,
                 "prelude-source",
                 %{component_id: "tools"},
                 %{
                   environment: :mission,
                   source: @source,
                   source_hash: @source_hash,
                   source_bytes: byte_size(@source)
                 }
               )
    end

    assert {:ok, duplicate_preludes} = InspectionSink.records(prelude_sink)

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.persist(
               Path.join(dir, "duplicate-prelude.inspection.jsonl"),
               duplicate_preludes,
               []
             )
  end

  test "rejects a non-MCP record above the artifact document-depth ceiling" do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")
    nested = Enum.reduce(1..64, true, fn _level, value -> [value] end)

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               sink,
               "capability-input",
               %{capability_id: "cap-1"},
               %{
                 environment: :mission,
                 name: "remote.read",
                 arguments: %{"nested" => nested}
               }
             )

    assert {:error, :inspection_sink_error} = InspectionSink.records(sink)
  end

  # The retained record wraps the payload at exactly one level, so the ceiling is
  # measured through that envelope. Pinning both sides of the edge keeps a
  # cheaper pre-normalization check from quietly moving it.
  test "retains a record at the document-depth ceiling and rejects the next level" do
    nest = fn levels -> Enum.reduce(1..levels, true, fn _level, value -> [value] end) end

    emit = fn levels ->
      {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

      InspectionSink.emit(
        sink,
        "capability-input",
        %{capability_id: "cap-1"},
        %{environment: :mission, name: "remote.read", arguments: %{"nested" => nest.(levels)}}
      )
    end

    assert :ok = emit.(50)
    assert {:error, :inspection_sink_error} = emit.(51)
  end

  @tag :tmp_dir
  test "persists one exclusive 0600 artifact and validates immutable loading", %{tmp_dir: dir} do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")
    assert :ok = emit_small(sink, "cap-1")
    assert {:ok, records} = InspectionSink.records(sink)

    events = [
      %{
        run_id: "run-1",
        trace_id: "trace-1",
        type: "capability-started",
        data: %{capability_id: "cap-1", environment: :mission, name: "read"}
      }
    ]

    for failure_stage <- [:before_chmod, :before_write] do
      failed_path = Path.join(dir, "#{failure_stage}.inspection.jsonl")

      hook = fn
        ^failure_stage -> {:error, :simulated_write_failure}
        _stage -> :ok
      end

      assert {:error, :inspection_persistence_failed} =
               InspectionArtifact.persist(failed_path, records, events, hook)

      refute File.exists?(failed_path)
    end

    File.cd!(dir, fn ->
      relative_path = "-run.inspection.jsonl"

      assert :ok = InspectionArtifact.persist(relative_path, records, events)
      assert File.regular?(relative_path)
    end)

    path = Path.join(dir, "run.inspection.jsonl")

    assert :ok = InspectionArtifact.persist(path, records, events)
    assert {:ok, ^records} = InspectionArtifact.load(path)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:error, :inspection_destination_exists} =
             InspectionArtifact.persist(path, records, events)

    assert {:error, :invalid_inspection_path} =
             InspectionArtifact.persist(Path.join(dir, "wrong.jsonl"), records, events)

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.persist(
               Path.join(dir, "orphan.inspection.jsonl"),
               records,
               []
             )

    link = Path.join(dir, "link.inspection.jsonl")
    File.ln_s!(path, link)
    assert {:error, :invalid_inspection_source} = InspectionArtifact.load(link)

    duplicate = Path.join(dir, "duplicate.inspection.jsonl")

    duplicate_line =
      records
      |> hd()
      |> Jason.encode!()
      |> String.replace_prefix("{", ~S|{"schema_version":1,|)

    File.write!(duplicate, duplicate_line <> "\n")
    assert {:error, :malformed_inspection_artifact} = InspectionArtifact.load(duplicate)

    invalid = Path.join(dir, "invalid.inspection.jsonl")
    File.write!(invalid, Jason.encode!(Map.put(hd(records), "unknown", true)) <> "\n")
    assert {:error, :invalid_inspection_artifact} = InspectionArtifact.load(invalid)

    empty = Path.join(dir, "empty.inspection.jsonl")
    File.write!(empty, "")
    assert {:error, :invalid_inspection_artifact} = InspectionArtifact.load(empty)

    wrong_type = Path.join(dir, "wrong-type.inspection.jsonl")

    File.write!(
      wrong_type,
      Jason.encode!(Map.put(hd(records), "record_type", "unknown")) <> "\n"
    )

    assert {:error, :invalid_inspection_artifact} = InspectionArtifact.load(wrong_type)

    repeated_sequence = Path.join(dir, "sequence.inspection.jsonl")

    File.write!(
      repeated_sequence,
      Enum.map_join([hd(records), hd(records)], "\n", &Jason.encode!/1)
    )

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.load(repeated_sequence)

    assert {:error, :inspection_source_limit_exceeded} =
             InspectionArtifact.load(path, max_bytes: 1)

    oversized = Path.join(dir, "oversized.inspection.jsonl")

    records
    |> hd()
    |> put_in(["payload", "arguments"], %{"value" => String.duplicate("x", 2_100_000)})
    |> then(&File.write!(oversized, Jason.encode!(&1) <> "\n"))

    assert {:error, :inspection_source_limit_exceeded} = InspectionArtifact.load(oversized)

    trace_path = Path.join(dir, "run.jsonl")
    assert :ok = TraceLog.append_jsonl(trace_path, canonical_events())
    assert {:ok, grant} = ViewerAdapter.pin_inspection(path, {:file, trace_path})
    assert {:error, :inspection_run_mismatch} = ViewerAdapter.inspection(grant, "another-run")

    orphan = Path.join(dir, "pin-orphan.inspection.jsonl")
    orphan_record = put_in(hd(records), ["correlation", "capability_id"], "missing-capability")
    orphan_record = Map.put(orphan_record, "trace_id", "unrelated-trace")
    File.write!(orphan, Jason.encode!(orphan_record) <> "\n")

    assert {:error, :inspection_correlation_missing} =
             ViewerAdapter.pin_inspection(orphan, {:file, trace_path})
  end

  @tag :tmp_dir
  test "viewer startup pins the selected artifact even if its path is replaced", %{tmp_dir: dir} do
    first_path = Path.join(dir, "pinned.inspection.jsonl")
    private_marker = "PRIVATE_VIEWER_MARKER"
    first_records = persisted_records(first_path, private_marker)
    assert :ok = TraceLog.append_jsonl(Path.join(dir, "canonical.jsonl"), canonical_events())

    telemetry_id = "inspection-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_id,
      [[:bandit, :request, :start], [:bandit, :request, :stop]],
      fn event, _measurements, metadata, test_pid ->
        send(test_pid, {:bandit_telemetry, event, metadata})
      end,
      self()
    )

    logger_id = :inspection_logger_probe
    previous_level = Logger.level()
    Logger.configure(level: :info)

    :ok =
      :logger.add_handler(logger_id, PtcRunner.TestSupport.LoggerProbeHandler, %{
        level: :all,
        test_pid: self()
      })

    on_exit(fn ->
      :telemetry.detach(telemetry_id)
      :logger.remove_handler(logger_id)
      Logger.configure(level: previous_level)
    end)

    {:ok, viewer} =
      PtcViewer.start(
        port: 0,
        trace_dir: dir,
        inspection_file: first_path,
        inspection_adapter: ViewerAdapter,
        open: false
      )

    Process.unlink(viewer)
    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)

    File.rm!(first_path)
    replacement_records = persisted_records(first_path, "replacement")
    refute replacement_records == first_records

    assert {:ok, {_address, port}} = PtcViewer.listener_info(viewer)

    response = Req.get!("http://127.0.0.1:#{port}/api/inspection/runs/run-1")
    assert response.status == 200
    assert response.body["records"] == first_records
    assert inspect(response.body) =~ private_marker

    assert_receive {:logger_probe, startup_event}
    refute inspect(startup_event) =~ private_marker

    assert_receive {:bandit_telemetry, [:bandit, :request, :start], start_metadata}
    assert_receive {:bandit_telemetry, [:bandit, :request, :stop], stop_metadata}
    refute inspect(start_metadata) =~ private_marker
    refute inspect(stop_metadata) =~ private_marker
  end

  @tag :tmp_dir
  test "loading rejects a same-size rewrite between bounded reads", %{tmp_dir: dir} do
    path = Path.join(dir, "changing.inspection.jsonl")
    replacement_path = Path.join(dir, "replacement.inspection.jsonl")
    _records = persisted_records(path, "AAAA")
    _replacement_records = persisted_records(replacement_path, "BBBB")
    replacement = File.read!(replacement_path)

    assert byte_size(File.read!(path)) == byte_size(replacement)

    assert {:error, :inspection_source_changed} =
             InspectionArtifact.load(path, [], fn -> File.write!(path, replacement) end)
  end

  @tag :tmp_dir
  test "loading rejects an incomplete short read instead of parsing its prefix", %{tmp_dir: dir} do
    path = Path.join(dir, "short-read.inspection.jsonl")
    _records = persisted_records(path, "PRIVATE_SUFFIX")
    valid_prefix_bytes = path |> File.read!() |> byte_size()
    File.write!(path, File.read!(path) <> String.duplicate(" ", 64))
    read_key = {__MODULE__, make_ref()}

    short_reader = fn device, requested ->
      case Process.get(read_key, :first) do
        :first ->
          Process.put(read_key, :done)
          :file.read(device, min(requested, valid_prefix_bytes))

        :done ->
          :eof
      end
    end

    assert {:error, :inspection_source_changed} =
             InspectionArtifact.load(path, [], nil, short_reader)
  end

  @tag :tmp_dir
  test "loading rejects excessive raw document depth before recursive normalization", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "deep.inspection.jsonl")
    nested = Enum.reduce(1..64, true, fn _level, value -> [value] end)

    record = %{
      "schema_version" => 1,
      "run_id" => "deep",
      "trace_id" => "deep",
      "sequence" => 1,
      "timestamp" => "2026-07-28T12:00:00Z",
      "record_type" => "capability-input",
      "correlation" => %{"capability_id" => "deep-capability"},
      "payload" => %{
        "environment" => "mission",
        "name" => "read",
        "arguments" => %{"nested" => nested}
      }
    }

    File.write!(path, Jason.encode!(record) <> "\n")

    assert {:error, :malformed_inspection_artifact} = InspectionArtifact.load(path)
  end

  @tag :tmp_dir
  test "run builder captures correlated source and capability payloads outside canonical trace",
       %{
         tmp_dir: dir
       } do
    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (do (tool/kernel-eval {"kind" :source "source" (get input "program")}) "done"))|
    )

    program = ~S|(return (tool/native-read {"query" "inspect me"}))|

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{"program" => program}},
      "providers" => %{
        "mission" => [%{"name" => "native", "config" => %{}}]
      },
      "events" => %{"policy" => "private"}
    }

    manifest_path = Path.join(dir, "ptc.json")
    trace_path = Path.join(dir, "run.private.jsonl")
    inspection_path = Path.join(dir, "run.inspection.jsonl")
    result_path = Path.join(dir, "run.result.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    builder = fn %{}, _context ->
      Capability.new(
        name: "native-read",
        effect: :read,
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        },
        output_schema: %{
          "type" => "object",
          "properties" => %{"answer" => %{"type" => "string"}},
          "required" => ["answer"]
        },
        callback: fn %{"query" => query} -> {:ok, %{"answer" => String.upcase(query)}} end
      )
    end

    {:ok, registry} = ProviderRegistry.new(%{"native" => builder})

    assert {:ok, _result} =
             RunBuilder.run(manifest_path, registry,
               trace: trace_path,
               inspect: inspection_path,
               private_output: result_path,
               result_projection: :json
             )

    assert {:ok, [prelude, source, input, output] = records} =
             InspectionArtifact.load(inspection_path)

    assert prelude["record_type"] == "prelude-source"
    assert prelude["correlation"] == %{"component_id" => "app"}
    assert prelude["payload"]["environment"] == "workflow"
    assert prelude["payload"]["source"] =~ "(ns app)"

    assert source["record_type"] == "evaluation-source"
    assert source["payload"]["source"] == program

    assert input["payload"] == %{
             "environment" => "mission",
             "name" => "native-read",
             "arguments" => %{"query" => "inspect me"}
           }

    assert output["payload"]["result"] == %{
             "status" => "ok",
             "value" => %{"answer" => "INSPECT ME"}
           }

    trace_lines = trace_path |> File.read!() |> String.split("\n", trim: true)
    refute Enum.any?(trace_lines, &String.contains?(&1, "inspect me"))
    refute Enum.any?(trace_lines, &String.contains?(&1, program))

    evaluation_started =
      trace_lines
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(
        &(&1["type"] == "evaluation-started" and &1["data"]["environment"] == "mission")
      )

    assert evaluation_started["data"]["source_hash"] == source["payload"]["source_hash"]
    assert evaluation_started["data"]["source_bytes"] == byte_size(program)
    refute Map.has_key?(evaluation_started["data"], "source")

    assert {:ok, private_trace} = TraceLog.new(source: {:private_file, trace_path})

    assert {:ok, turns} =
             TraceLog.query(private_trace, :list_turns, %{"run_id" => source["run_id"]})

    encoded_turns = Jason.encode!(turns)
    refute encoded_turns =~ "inspect me"
    refute encoded_turns =~ program

    assert {:ok, inspection_source} =
             ViewerAdapter.pin_inspection(inspection_path, {:private_file, trace_path})

    {:ok, inspection_store} = PtcViewer.InspectionStore.start(inspection_source)

    on_exit(fn ->
      if Process.alive?(inspection_store), do: PtcViewer.InspectionStore.stop(inspection_store)
    end)

    viewer_opts = [
      trace_dir: dir,
      kernel_trace_adapter: ViewerAdapter,
      inspection_store: inspection_store,
      inspection_adapter: ViewerAdapter
    ]

    response =
      Plug.Test.conn(:get, "/api/inspection/runs/#{source["run_id"]}")
      |> PtcViewer.Router.call(PtcViewer.Router.init(viewer_opts))

    assert response.status == 200
    assert %{"records" => ^records} = Jason.decode!(response.resp_body)
  end

  defp emit_small(sink, capability_id) do
    InspectionSink.emit(
      sink,
      "capability-input",
      %{capability_id: capability_id},
      %{environment: :mission, name: "read", arguments: %{"id" => 1}}
    )
  end

  defp persisted_records(path, value) do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-input",
               %{capability_id: "cap-1"},
               %{environment: :mission, name: "read", arguments: %{"value" => value}}
             )

    assert {:ok, records} = InspectionSink.records(sink)

    events = [
      %{
        run_id: "run-1",
        trace_id: "trace-1",
        type: "capability-started",
        data: %{capability_id: "cap-1", environment: :mission, name: "read"}
      }
    ]

    assert :ok = InspectionArtifact.persist(path, records, events)
    assert :ok = InspectionSink.stop(sink)
    records
  end

  defp canonical_events do
    [
      canonical_event(1, "run-started", %{}),
      canonical_event(2, "capability-started", %{
        "capability_id" => "cap-1",
        "environment" => "mission",
        "name" => "read"
      }),
      canonical_event(3, "capability-stopped", %{
        "capability_id" => "cap-1",
        "environment" => "mission",
        "name" => "read"
      }),
      canonical_event(4, "run-stopped", %{"outcome" => "ok"})
    ]
  end

  defp canonical_event(sequence, type, data) do
    %{
      "schema_version" => 1,
      "run_id" => "run-1",
      "trace_id" => "trace-1",
      "sequence" => sequence,
      "timestamp" => "2026-07-17T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp resequence(records) do
    records
    |> Enum.with_index(1)
    |> Enum.map(fn {record, sequence} -> Map.put(record, "sequence", sequence) end)
  end
end
