defmodule PtcRunner.Kernel.InspectionSinkTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
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

    assert {:ok, [input, output, source]} = InspectionSink.records(sink)
    assert Enum.map([input, output, source], & &1["sequence"]) == [1, 2, 3]
    assert input["payload"]["environment"] == "mission"
    assert output["payload"]["result"] == %{"status" => "ok", "value" => 42}
    assert source["payload"]["source"] == @source

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
  test "persists one exclusive 0600 artifact and validates immutable loading", %{tmp_dir: dir} do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")
    assert :ok = emit_small(sink, "cap-1")
    assert {:ok, records} = InspectionSink.records(sink)

    events = [%{run_id: "run-1", trace_id: "trace-1", data: %{capability_id: "cap-1"}}]
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

    assert {:error, :inspection_run_mismatch} = ViewerAdapter.inspection(path, "another-run")
  end

  @tag :tmp_dir
  test "run builder captures correlated source and capability payloads outside canonical trace",
       %{
         tmp_dir: dir
       } do
    File.write!(
      Path.join(dir, "workflow.lisp"),
      ~S|(ns app) (defn run [input] (return (tool/kernel-eval {"kind" :source "source" (get input "program")})))|
    )

    program = ~S|(return (tool/native-read {"query" "inspect me"}))|

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.lisp"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{"program" => program}},
      "providers" => %{
        "mission" => [%{"name" => "native", "config" => %{}}]
      }
    }

    manifest_path = Path.join(dir, "ptc.json")
    trace_path = Path.join(dir, "run.jsonl")
    inspection_path = Path.join(dir, "run.inspection.jsonl")
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
               inspect: inspection_path
             )

    assert {:ok, [source, input, output] = records} = InspectionArtifact.load(inspection_path)
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

    viewer_opts = [
      trace_dir: dir,
      kernel_trace_adapter: ViewerAdapter,
      inspection_file: inspection_path,
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
end
