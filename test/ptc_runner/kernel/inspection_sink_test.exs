defmodule PtcRunner.Kernel.InspectionSinkTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.RunAnalysis
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Kernel.ViewerAdapter
  alias PtcRunner.Lisp.Format.SymbolRef
  alias PtcRunner.TestSupport.RunLifecycle
  alias PtcRunner.TestSupport.TestHelpers

  @source "(return 42)"
  @source_hash :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)
  @checkpoint_workflow_source ~S|(ns app) (defn run [input] (return {"seen" input}))|

  test "retains only normalized exact current records and fails closed" do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-input",
               %{capability_id: "cap-1"},
               %{
                 environment: :mission,
                 mission_name: "default",
                 name: "remote.read",
                 arguments: %{"query" => "x"}
               }
             )

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-output",
               %{"capability_id" => "cap-1"},
               %{
                 environment: :mission,
                 mission_name: "default",
                 name: "remote.read",
                 result: %{status: :ok, value: 42}
               }
             )

    emit!(
      sink,
      "evaluation-source",
      %{evaluation_id: "eval-1"},
      mission_evaluation_source_payload()
    )

    emit!(
      sink,
      "evaluation-analysis",
      %{evaluation_id: "eval-1"},
      %{
        environment: :mission,
        mission_name: "default",
        prelude_calls: [%{ref: "remote/read", component_id: "tools"}]
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

    assert {:ok, [input, output, source, analysis, prelude]} = InspectionSink.records(sink)

    assert Enum.map([input, output, source, analysis, prelude], & &1["sequence"]) == [
             1,
             2,
             3,
             4,
             5
           ]

    assert Enum.all?([input, output, source, analysis, prelude], &(&1["schema_version"] == 6))
    assert input["payload"]["environment"] == "mission"
    assert output["payload"]["result"] == %{"status" => "ok", "value" => 42}
    assert source["payload"]["source"] == @source

    assert analysis["payload"]["prelude_calls"] == [
             %{"ref" => "remote/read", "component_id" => "tools"}
           ]

    assert prelude["correlation"] == %{"component_id" => "tools"}
    assert prelude["payload"]["environment"] == "workflow"
    assert prelude["payload"]["source"] == @source

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               sink,
               "capability-input",
               %{capability_id: "cap-2"},
               %{
                 environment: :mission,
                 mission_name: "default",
                 name: "bad",
                 arguments: %{},
                 extra: true
               }
             )

    assert {:error, :inspection_sink_error} = InspectionSink.records(sink)
    assert :ok = InspectionSink.stop(sink)
    assert :ok = InspectionSink.stop(sink)
  end

  test "retains an MCP request and response through one atomic sink operation" do
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

    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit_mcp_exchange(
               sink,
               correlation,
               %{transport: :stdio, body: request},
               %{transport: :stdio, body: response}
             )

    assert {:ok, [request_record, response_record]} = InspectionSink.records(sink)
    assert request_record["schema_version"] == 6
    assert request_record["payload"]["body"] == request
    assert response_record["payload"]["body"] == response
  end

  test "rejects malformed MCP exchange records" do
    correlation = %{capability_id: "cap-1", request_id: 7}

    for {record_type, payload} <- [
          {"mcp-request",
           %{
             transport: :invalid,
             body: %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call", "params" => %{}}
           }},
          {"mcp-response",
           %{transport: :stdio, body: %{"jsonrpc" => "2.0", "id" => 8, "result" => %{}}}}
        ] do
      {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

      assert {:error, :inspection_sink_error} =
               InspectionSink.emit(sink, record_type, correlation, payload)
    end
  end

  test "retains correlated execution prints and errors" do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(
               sink,
               "execution-prints",
               %{evaluation_id: "eval-1"},
               %{environment: :workflow, prints: ["CHECKPOINT"], truncated: false}
             )

    assert :ok =
             InspectionSink.emit(
               sink,
               "execution-error",
               %{evaluation_id: "eval-1"},
               %{
                 environment: :workflow,
                 kind: :workflow_failed,
                 reason: :invalid_result_projection,
                 details: %{result_projection: true, projection_error: "some inspected reason"}
               }
             )

    assert {:ok, [prints_record, error_record]} = InspectionSink.records(sink)
    assert prints_record["schema_version"] == 6
    assert prints_record["correlation"] == %{"evaluation_id" => "eval-1"}

    assert prints_record["payload"] == %{
             "environment" => "workflow",
             "prints" => ["CHECKPOINT"],
             "truncated" => false
           }

    assert error_record["payload"] == %{
             "environment" => "workflow",
             "kind" => "workflow_failed",
             "reason" => "invalid_result_projection",
             "details" => %{
               "result_projection" => true,
               "projection_error" => "some inspected reason"
             }
           }

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               sink,
               "execution-prints",
               %{evaluation_id: "eval-2"},
               %{environment: :mission, prints: ["nope"], truncated: false}
             )
  end

  @tag :tmp_dir
  test "rejects malformed reserved boundary producer evidence", %{tmp_dir: dir} do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    payload = %{
      environment: :workflow,
      kind: :limit_exceeded,
      reason: :terminal_result_exceeded,
      details: %{
        boundary_producer: %{complete?: true, evaluation_ids: ["mission-eval"]}
      }
    }

    assert :ok =
             InspectionSink.emit(
               sink,
               "execution-error",
               %{evaluation_id: "workflow-eval"},
               payload
             )

    assert {:ok, [record]} = InspectionSink.records(sink)

    malformed_payload =
      put_in(payload, [:details, :boundary_producer, :complete?], "not-a-boolean")

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               sink,
               "execution-error",
               %{evaluation_id: "other-workflow-eval"},
               malformed_payload
             )

    malformed_record =
      put_in(record, ["payload", "details", "boundary_producer", "complete?"], "not-a-boolean")

    path = Path.join(dir, "malformed-boundary.inspection.jsonl")
    File.write!(path, Jason.encode!(malformed_record) <> "\n")

    assert {:error, :invalid_inspection_artifact} = InspectionArtifact.load(path)
  end

  test "current records require and correlate exact mission identity" do
    {:ok, missing_name} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               missing_name,
               "capability-input",
               %{capability_id: "cap-1"},
               %{environment: :mission, name: "read", arguments: %{}}
             )

    {:ok, workflow_name} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               workflow_name,
               "capability-input",
               %{capability_id: "cap-1"},
               %{environment: :workflow, mission_name: "reader", name: "read", arguments: %{}}
             )

    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-input",
               %{capability_id: "cap-1"},
               %{
                 environment: :mission,
                 mission_name: "reader",
                 name: "read",
                 arguments: %{}
               }
             )

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-output",
               %{capability_id: "cap-1"},
               %{
                 environment: :mission,
                 mission_name: "reader",
                 name: "read",
                 result: %{status: :ok, value: 1}
               }
             )

    assert {:ok, records} = InspectionSink.records(sink)

    event = %{
      run_id: "run-1",
      trace_id: "trace-1",
      type: "capability-started",
      data: %{
        capability_id: "cap-1",
        environment: :mission,
        mission_name: "reader",
        name: "read"
      }
    }

    assert :ok = InspectionArtifact.validate_correlations(records, [event])

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(
               records,
               [put_in(event, [:data, :mission_name], "writer")]
             )
  end

  test "retains exactly one strict-JSON run result" do
    value = %{"answer" => [42, true, nil]}
    {:ok, encoded} = DeterministicJSON.encode(value)
    hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)

    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(sink, "run-result", %{}, %{result_hash: hash, value: value})

    assert {:ok, [record]} = InspectionSink.records(sink)
    assert record["schema_version"] == 6
    assert record["correlation"] == %{}
    assert record["payload"] == %{"result_hash" => hash, "value" => value}

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(sink, "run-result", %{}, %{result_hash: hash, value: value})
  end

  test "rejects native run results before generic inspection normalization" do
    {:ok, atom_value} =
      InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               atom_value,
               "run-result",
               %{},
               %{result_hash: result_hash("native"), value: :native}
             )

    {:ok, atom_key} =
      InspectionSink.start(run_id: "run-2", trace_id: "trace-2")

    assert {:error, :inspection_sink_error} =
             InspectionSink.emit(
               atom_key,
               "run-result",
               %{},
               %{result_hash: result_hash(%{"answer" => 42}), value: %{answer: 42}}
             )
  end

  @tag :tmp_dir
  test "artifacts self-validate result hashes and bind them to canonical completion", %{
    tmp_dir: dir
  } do
    value = %{"answer" => 42}
    {:ok, encoded} = DeterministicJSON.encode(value)
    hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)

    {:ok, sink} =
      InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(sink, "run-result", %{}, %{result_hash: hash, value: value})

    assert {:ok, [record] = records} = InspectionSink.records(sink)

    events = [
      canonical_event(1, "run-started", %{}),
      canonical_event(2, "run-stopped", %{
        "outcome" => "ok",
        "result_hash" => hash
      })
    ]

    path = Path.join(dir, "result.inspection.jsonl")
    assert :ok = InspectionArtifact.validate_correlations(records, events)
    assert :ok = InspectionArtifact.persist(path, records, events)
    assert {:ok, ^records} = InspectionArtifact.load(path)

    tampered_path = Path.join(dir, "tampered.inspection.jsonl")
    tampered = put_in(record, ["payload", "value"], %{"answer" => 43})
    File.write!(tampered_path, Jason.encode!(tampered) <> "\n")
    assert {:error, :invalid_inspection_artifact} = InspectionArtifact.load(tampered_path)

    mismatched =
      put_in(events, [Access.at(1), "data", "result_hash"], result_hash(%{"answer" => 0}))

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(records, mismatched)

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(records, [hd(events)])
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
                 mission_name: "default",
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
               %{
                 environment: :mission,
                 mission_name: "default",
                 name: "read",
                 result: %{status: :ok, value: 1}
               }
             )

    assert {:ok, [input, output]} = InspectionSink.records(sink)

    events = [
      %{
        run_id: "run-1",
        trace_id: "trace-1",
        type: "capability-started",
        data: %{
          capability_id: "cap-1",
          environment: :mission,
          mission_name: "default",
          name: "read"
        }
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

    # ex_dna:disable-for-next-line — Identical duplicate emission is the behavior under test.
    for _index <- 1..2 do
      emit!(
        source_sink,
        "evaluation-source",
        %{evaluation_id: "eval-1"},
        mission_evaluation_source_payload()
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
                   mission_name: "default",
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

  @tag :tmp_dir
  test "artifacts accept only correlations proven missing by canonical dropped-event counts", %{
    tmp_dir: dir
  } do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")
    assert :ok = emit_small(sink, "cap-1")
    assert :ok = emit_small(sink, "cap-2")
    assert {:ok, records} = InspectionSink.records(sink)

    partial_events = dropped_events(%{"capability-started" => 2})
    path = Path.join(dir, "partial.inspection.jsonl")

    conflicting_terminal_counts =
      put_in(
        partial_events,
        [Access.at(2), "data", "usage", "events_dropped"],
        %{"capability-started" => 1}
      )

    intervening_event =
      List.insert_at(partial_events, 2, canonical_event(3, "workflow-annotation", %{}))

    reversed_terminal_events =
      [Enum.at(partial_events, 0), Enum.at(partial_events, 2), Enum.at(partial_events, 1)]

    assert :ok = InspectionArtifact.validate_correlations(records, partial_events)
    assert :ok = InspectionArtifact.persist(path, records, partial_events)
    assert {:ok, ^records} = InspectionArtifact.load(path)

    for events <- [
          dropped_events(%{"capability-started" => 1}),
          dropped_events(%{"capability-stopped" => 2}),
          conflicting_terminal_counts,
          intervening_event,
          reversed_terminal_events,
          Enum.reject(partial_events, &(&1["type"] == "events-dropped")),
          Enum.reject(partial_events, &(&1["type"] == "run-stopped"))
        ] do
      assert {:error, :inspection_correlation_missing} =
               InspectionArtifact.validate_correlations(records, events)
    end

    conflicting =
      canonical_event(2, "capability-started", %{
        "capability_id" => "cap-1",
        "environment" => "workflow",
        "name" => "other"
      })

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(records, [conflicting | partial_events])

    assert :ok = InspectionSink.stop(sink)

    {:ok, evaluation_sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(
               evaluation_sink,
               "evaluation-source",
               %{evaluation_id: "eval-mission"},
               %{
                 environment: :mission,
                 mission_name: "default",
                 program_kind: :"ptc-lisp",
                 source: @source,
                 source_hash: @source_hash,
                 source_bytes: byte_size(@source)
               }
             )

    assert :ok =
             InspectionSink.emit(
               evaluation_sink,
               "execution-prints",
               %{evaluation_id: "eval-workflow"},
               %{environment: :workflow, prints: ["partial"], truncated: false}
             )

    assert :ok =
             InspectionSink.emit(
               evaluation_sink,
               "evaluation-analysis",
               %{evaluation_id: "eval-mission"},
               %{environment: :mission, mission_name: "other", prelude_calls: []}
             )

    assert {:ok, evaluation_records} = InspectionSink.records(evaluation_sink)
    evaluation_events = dropped_events(%{"evaluation-started" => 2})

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(evaluation_records, evaluation_events)

    matching_evaluation_records =
      Enum.map(evaluation_records, fn
        %{"record_type" => "evaluation-analysis"} = record ->
          put_in(record, ["payload", "mission_name"], "default")

        record ->
          record
      end)

    assert :ok =
             InspectionArtifact.validate_correlations(
               matching_evaluation_records,
               evaluation_events
             )

    conflicting_evaluation_records =
      Enum.map(matching_evaluation_records, fn record ->
        put_in(record, ["correlation", "evaluation_id"], "eval-shared")
      end)

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(
               conflicting_evaluation_records,
               dropped_events(%{"evaluation-started" => 1})
             )

    assert :ok = InspectionSink.stop(evaluation_sink)
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
                 mission_name: "default",
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
        %{
          environment: :mission,
          mission_name: "default",
          name: "remote.read",
          arguments: %{"nested" => nest.(levels)}
        }
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
        data: %{
          capability_id: "cap-1",
          environment: :mission,
          mission_name: "default",
          name: "read"
        }
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
      |> String.replace_prefix("{", ~S|{"schema_version":6,|)

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

    unsupported = Path.join(dir, "unsupported.inspection.jsonl")

    File.write!(
      unsupported,
      Enum.map_join(records, "\n", fn record ->
        record |> Map.put("schema_version", 4) |> Jason.encode!()
      end) <> "\n"
    )

    assert {:error,
            {:unsupported_inspection_schema_version, %{artifact_version: 4, supported_version: 6}}} =
             InspectionArtifact.load(unsupported)

    mixed = Path.join(dir, "mixed-schema.inspection.jsonl")
    first = records |> hd() |> Map.put("schema_version", 4)
    second = Map.put(hd(records), "sequence", 2)
    File.write!(mixed, Enum.map_join([first, second], "\n", &Jason.encode!/1) <> "\n")
    assert {:error, :invalid_inspection_artifact} = InspectionArtifact.load(mixed)

    capability_input = %{
      "schema_version" => 6,
      "run_id" => "run-1",
      "trace_id" => "trace-1",
      "sequence" => 1,
      "timestamp" => "2026-07-28T12:00:00Z",
      "record_type" => "capability-input",
      "correlation" => %{"capability_id" => "cap-1"},
      "payload" => %{"environment" => "workflow", "name" => "remote.read", "arguments" => %{}}
    }

    valid_mcp_request = %{
      capability_input
      | "sequence" => 2,
        "record_type" => "mcp-request",
        "correlation" => %{"capability_id" => "cap-1", "request_id" => 7},
        "payload" => %{
          "transport" => "stdio",
          "body" => %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/call", "params" => %{}}
        }
    }

    invalid_mcp_request = %{
      valid_mcp_request
      | "sequence" => 2,
        "payload" => %{
          "transport" => "stdio",
          "body" => %{"jsonrpc" => "2.0", "id" => 8, "method" => "tools/call", "params" => %{}}
        }
    }

    invalid_mcp_response = %{
      invalid_mcp_request
      | "sequence" => 3,
        "record_type" => "mcp-response",
        "payload" => %{
          "transport" => "stdio",
          "body" => %{"jsonrpc" => "2.0", "id" => 8, "result" => %{}}
        }
    }

    invalid_mcp_request_path = Path.join(dir, "invalid-mcp-request.inspection.jsonl")

    File.write!(
      invalid_mcp_request_path,
      Enum.map_join([capability_input, invalid_mcp_request], "\n", &Jason.encode!/1) <> "\n"
    )

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.load(invalid_mcp_request_path)

    invalid_mcp_response_path = Path.join(dir, "invalid-mcp-response.inspection.jsonl")

    File.write!(
      invalid_mcp_response_path,
      Enum.map_join(
        [capability_input, valid_mcp_request, invalid_mcp_response],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    assert {:error, :invalid_inspection_artifact} =
             InspectionArtifact.load(invalid_mcp_response_path)

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
    assert {:error, :inspection_run_mismatch} = ViewerAdapter.conversation(grant, "another-run")

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

    assert :ok =
             TraceLog.append_jsonl(Path.join(dir, "canonical.jsonl"), canonical_model_events())

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

    response =
      Req.get!("http://127.0.0.1:#{port}/api/analysis/runs/run-1/conversation")

    assert response.status == 200
    assert inspect(response.body) =~ private_marker
    refute inspect(response.body) =~ "replacement"

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
      "schema_version" => 6,
      "run_id" => "deep",
      "trace_id" => "deep",
      "sequence" => 1,
      "timestamp" => "2026-07-28T12:00:00Z",
      "record_type" => "capability-input",
      "correlation" => %{"capability_id" => "deep-capability"},
      "payload" => %{
        "environment" => "mission",
        "mission_name" => "default",
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
      ~S|(ns app) (defn run [input] (do (tool/kernel-eval {"mission" "default" "kind" :source "source" (get input "program")}) "done"))|
    )

    File.write!(
      Path.join(dir, "mission.clj"),
      ~S|(ns helper {:visibility :prompt}) (defn read [query] (tool/native-read {"query" query}))|
    )

    program = ~S|(return (helper/read "inspect me"))|

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{"program" => program}},
      "missions" => %{
        "default" => %{
          "components" => [%{"id" => "mission-helper", "path" => "mission.clj"}],
          "providers" => ["native"]
        }
      },
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
      with {:ok, capability} <-
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
               callback: fn %{"query" => query} ->
                 {:ok, %{"answer" => String.upcase(query)}}
               end
             ),
           do: {:ok, %{capabilities: [capability]}}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{"native" => TestHelpers.staged_provider(builder)})

    assert {:ok, _result} =
             manifest_path
             |> ApplicationPackage.request_directory(
               inspection_capture: true,
               result_projection: :json,
               installed_limits: registry.installed_limits
             )
             |> RunLifecycle.build(registry,
               trace_path: trace_path,
               inspect: inspection_path,
               private_output: result_path
             )
             |> RunLifecycle.execute()

    assert {:ok, [prelude, mission_prelude, source, input, output, analysis, result]} =
             InspectionArtifact.load(inspection_path)

    assert prelude["record_type"] == "prelude-source"
    assert prelude["correlation"] == %{"component_id" => "app"}
    assert prelude["payload"]["environment"] == "workflow"
    assert prelude["payload"]["source"] =~ "(ns app)"

    assert mission_prelude["record_type"] == "prelude-source"
    assert mission_prelude["correlation"] == %{"component_id" => "mission-helper"}
    assert mission_prelude["payload"]["mission_name"] == "default"

    assert source["record_type"] == "evaluation-source"
    assert source["payload"]["source"] == program

    assert input["payload"] == %{
             "environment" => "mission",
             "mission_name" => "default",
             "name" => "native-read",
             "arguments" => %{"query" => "inspect me"}
           }

    assert output["payload"]["mission_name"] == "default"

    assert output["payload"]["result"] == %{
             "status" => "ok",
             "value" => %{"answer" => "INSPECT ME"}
           }

    assert analysis["record_type"] == "evaluation-analysis"
    assert analysis["correlation"] == source["correlation"]

    assert analysis["payload"]["prelude_calls"] == [
             %{"component_id" => "mission-helper", "ref" => "helper/read"}
           ]

    assert {:ok, trace_snapshot} =
             TraceSnapshot.start({:private_authorized_directory, dir})

    assert {:ok, inspection_snapshot} =
             InspectionSnapshot.start({:directory, dir}, trace_snapshot)

    assert {:ok, run_analysis} = RunAnalysis.new(trace_snapshot, inspection_snapshot)

    assert {:ok,
            %{
              "items" => [
                %{
                  "source" => ^program,
                  "prelude_calls_available?" => true,
                  "prelude_calls" => [
                    %{"component_id" => "mission-helper", "ref" => "helper/read"}
                  ]
                }
              ]
            }} =
             RunAnalysis.query(run_analysis, :read, %{
               "run_id" => source["run_id"],
               "collection" => "generated_sources",
               "prelude_call" => "helper/read"
             })

    assert {:ok, %{"items" => []}} =
             RunAnalysis.query(run_analysis, :read, %{
               "run_id" => source["run_id"],
               "collection" => "generated_sources",
               "prelude_component" => "other-component"
             })

    assert {:error, :invalid_query} =
             RunAnalysis.query(run_analysis, :read, %{
               "run_id" => source["run_id"],
               "collection" => "execution_errors",
               "prelude_call" => "helper/read"
             })

    assert :ok = InspectionSnapshot.stop(inspection_snapshot)
    assert :ok = TraceSnapshot.stop(trace_snapshot)

    assert result["record_type"] == "run-result"
    assert result["payload"]["value"] == "done"

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

    assert {:ok, %{"complete?" => true, "streams" => []}} =
             ViewerAdapter.conversation(inspection_source, source["run_id"])

    refute function_exported?(ViewerAdapter, :inspection, 2)
  end

  @tag :tmp_dir
  test "a provider-free execution failure captures prints and error detail outside canonical trace",
       %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (println "CHECKPOINT" {:seen input}) #{1 2 3})|
    )

    manifest_path = Path.join(dir, "ptc.json")
    trace_path = Path.join(dir, "run.private.jsonl")
    inspection_path = Path.join(dir, "run.inspection.jsonl")
    File.write!(manifest_path, Jason.encode!(checkpoint_manifest()))

    assert {:error, %Error{kind: :workflow_failed}} =
             execute_checkpoint(manifest_path, trace_path, inspection_path)

    assert {:ok, records} = InspectionArtifact.load(inspection_path)

    prints_record = Enum.find(records, &(&1["record_type"] == "execution-prints"))
    error_record = Enum.find(records, &(&1["record_type"] == "execution-error"))

    assert prints_record["payload"] == %{
             "environment" => "workflow",
             "prints" => [~S|CHECKPOINT {:seen {"seen" "checkpoint-input"}}|],
             "truncated" => false
           }

    assert error_record["payload"]["environment"] == "workflow"
    assert error_record["payload"]["kind"] == "workflow_failed"
    assert is_map(error_record["payload"]["details"])
    assert map_size(error_record["payload"]["details"]) > 0

    trace_lines = trace_path |> File.read!() |> String.split("\n", trim: true)
    refute Enum.any?(trace_lines, &String.contains?(&1, "CHECKPOINT"))
    refute Enum.any?(trace_lines, &String.contains?(&1, "checkpoint-input"))

    evaluation_started =
      trace_lines
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(
        &(&1["type"] == "evaluation-started" and &1["data"]["environment"] == "workflow")
      )

    assert evaluation_started["data"]["evaluation_id"] ==
             prints_record["correlation"]["evaluation_id"]

    assert evaluation_started["data"]["evaluation_id"] ==
             error_record["correlation"]["evaluation_id"]

    assert {:ok, inspection_source} =
             ViewerAdapter.pin_inspection(inspection_path, {:private_file, trace_path})

    assert {:ok, %{"complete?" => true, "streams" => []}} =
             ViewerAdapter.conversation(inspection_source, evaluation_started["run_id"])
  end

  @tag :tmp_dir
  test "a provider-free execution success still captures its println output",
       %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (println "CHECKPOINT" {:seen input}) (return {"ok" true}))|
    )

    manifest_path = Path.join(dir, "ptc.json")
    trace_path = Path.join(dir, "run.private.jsonl")
    inspection_path = Path.join(dir, "run.inspection.jsonl")
    result_path = Path.join(dir, "run.result.json")
    File.write!(manifest_path, Jason.encode!(checkpoint_manifest()))

    {:ok, registry} = ProviderRegistry.new(%{})

    assert {:ok, %Result{value: %{"ok" => true}}} =
             manifest_path
             |> ApplicationPackage.request_directory(
               inspection_capture: true,
               result_projection: :json,
               installed_limits: registry.installed_limits
             )
             |> RunLifecycle.build(registry,
               trace_path: trace_path,
               inspect: inspection_path,
               private_output: result_path
             )
             |> RunLifecycle.execute()

    assert {:ok, records} = InspectionArtifact.load(inspection_path)

    prints_record = Enum.find(records, &(&1["record_type"] == "execution-prints"))
    result_record = Enum.find(records, &(&1["record_type"] == "run-result"))
    refute Enum.any?(records, &(&1["record_type"] == "execution-error"))

    assert prints_record["payload"] == %{
             "environment" => "workflow",
             "prints" => [~S|CHECKPOINT {:seen {"seen" "checkpoint-input"}}|],
             "truncated" => false
           }

    assert result_record["payload"]["value"] == %{"ok" => true}

    trace_lines = trace_path |> File.read!() |> String.split("\n", trim: true)
    refute Enum.any?(trace_lines, &String.contains?(&1, "CHECKPOINT"))
    refute Enum.any?(trace_lines, &String.contains?(&1, "checkpoint-input"))

    evaluation_started =
      trace_lines
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(
        &(&1["type"] == "evaluation-started" and &1["data"]["environment"] == "workflow")
      )

    run_stopped =
      trace_lines
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["type"] == "run-stopped"))

    assert result_record["payload"]["result_hash"] == run_stopped["data"]["result_hash"]

    assert {:ok, trace_log} = TraceLog.new(source: {:private_file, trace_path})

    assert {:ok, %{"result_hash" => result_hash}} =
             TraceLog.query(trace_log, :get_run, %{"run_id" => run_stopped["run_id"]})

    assert result_hash == result_record["payload"]["result_hash"]

    assert evaluation_started["data"]["evaluation_id"] ==
             prints_record["correlation"]["evaluation_id"]
  end

  @tag :tmp_dir
  test "an escape-heavy terminal result fails inspection and withholds result publication", %{
    tmp_dir: dir
  } do
    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app)
         (defn run [input]
           (return (replace (get input "value") #"x" (json/parse-string "\"\\u0000\""))))|
    )

    value = String.duplicate("x", 400_000)
    File.write!(Path.join(dir, "input.json"), Jason.encode!(%{"value" => value}))

    manifest =
      checkpoint_manifest()
      |> Map.put("input", %{"path" => "input.json"})
      |> Map.put("limits", %{"workflow_heap_words" => 32_000_000})

    manifest_path = Path.join(dir, "ptc.json")
    trace_path = Path.join(dir, "run.private.jsonl")
    inspection_path = Path.join(dir, "run.inspection.jsonl")
    result_path = Path.join(dir, "run.result.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    {:ok, installed_limits} =
      Limits.new(workflow_heap_words: 32_000_000)

    {:ok, registry} = ProviderRegistry.new(%{}, installed_limits: installed_limits)

    assert {:error,
            {:inspection_persistence_failed, :inspection_sink_error,
             {:ok, %Result{value: :redacted}}}} =
             manifest_path
             |> ApplicationPackage.request_directory(
               inspection_capture: true,
               result_projection: :json,
               installed_limits: registry.installed_limits
             )
             |> RunLifecycle.build(registry,
               trace_path: trace_path,
               inspect: inspection_path,
               private_output: result_path
             )
             |> RunLifecycle.execute()

    escape_heavy_result = :binary.copy(<<0>>, 400_000)
    assert :erlang.external_size(escape_heavy_result) < 1_000_000
    assert byte_size(Jason.encode!(escape_heavy_result)) > 2_000_000
    assert File.regular?(trace_path)

    assert trace_path
           |> File.stream!()
           |> Enum.map(&Jason.decode!/1)
           |> Enum.any?(
             &(&1["type"] == "run-stopped" and &1["data"]["outcome"] == "ok" and
                 is_binary(&1["data"]["result_hash"]))
           )

    refute File.exists?(inspection_path)
    refute File.exists?(result_path)
  end

  @tag :tmp_dir
  test "an inspected native symbol result remains successful without a result record", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "workflow.clj"), ~S|(ns app) (defn run [_input] (return 'answer))|)
    manifest_path = Path.join(dir, "ptc.json")
    File.write!(manifest_path, Jason.encode!(checkpoint_manifest()))
    {:ok, registry} = ProviderRegistry.new(%{})

    assert {:ok, built} =
             manifest_path
             |> ApplicationPackage.request_directory(
               inspection_capture: true,
               result_projection: :native,
               installed_limits: registry.installed_limits
             )
             |> RunLifecycle.build(registry,
               trace_path: Path.join(dir, "run.private.jsonl"),
               inspect: Path.join(dir, "run.inspection.jsonl")
             )

    authority = built.publication_authority
    on_exit(fn -> PublicationAuthority.abort(authority) end)

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:ok,
            %{
              result: {:ok, %Result{value: %SymbolRef{name: "answer"}}},
              inspection: {:ok, records},
              terminal_batch: {:ok, terminal_events}
            }} = ExecutionOutcome.open(outcome, authority)

    refute Enum.any?(records, &(&1["record_type"] == "run-result"))

    assert Enum.any?(
             terminal_events,
             &(&1.type == "run-stopped" and is_binary(&1.data.result_hash))
           )
  end

  @tag :tmp_dir
  test "a normal workflow inspection retains a safe prelude type error", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (> (get input "missing") 1))|
    )

    manifest_path = Path.join(dir, "ptc.json")
    trace_path = Path.join(dir, "run.jsonl")
    inspection_path = Path.join(dir, "run.inspection.jsonl")
    File.write!(manifest_path, Jason.encode!(checkpoint_manifest("normal")))

    assert {:error, %Error{kind: :workflow_failed}} =
             execute_checkpoint(manifest_path, trace_path, inspection_path)

    assert {:ok, records} = InspectionArtifact.load(inspection_path)
    error_record = Enum.find(records, &(&1["record_type"] == "execution-error"))

    assert error_record["payload"]["details"]["message"] ==
             "type_error: app/run: >: expected number arguments, got nil, number"

    refute trace_path |> File.read!() |> String.contains?("expected number arguments")
  end

  defp execute_checkpoint(manifest_path, trace_path, inspection_path) do
    {:ok, registry} = ProviderRegistry.new(%{})

    manifest_path
    |> ApplicationPackage.request_directory(
      inspection_capture: true,
      result_projection: :json,
      installed_limits: registry.installed_limits
    )
    |> RunLifecycle.build(registry, trace_path: trace_path, inspect: inspection_path)
    |> RunLifecycle.execute()
  end

  test "prelude source is proven against the canonical bundle identity" do
    {:ok, bundle} = compiled_bundle()
    events = [run_started_event(bundle)]

    assert :ok =
             InspectionArtifact.validate_correlations(
               prelude_records(effective_sources()),
               events
             )

    forged = %{effective_sources() | "main" => "(ns main) (def value 99)"}

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(prelude_records(forged), events)
  end

  test "prelude proof requires the exact canonical set and one canonical projection" do
    {:ok, bundle} = compiled_bundle()
    events = [run_started_event(bundle)]
    sources = effective_sources()
    [_first | incomplete] = prelude_records(sources)

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(incomplete, events)

    unlisted = prelude_records(Map.put(sources, "ghost", "(ns ghost)"))

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(unlisted, events)

    widening =
      canonical_event(2, "capability-started", %{
        "capability_id" => "cap-1",
        "environment" => "workflow",
        "name" => "read",
        "workflow_prelude" => %{
          "component_ids" => ["base", "main", "ghost"],
          "dependency_indices" => [[], [0], []],
          "hash" => bundle.hash
        }
      })

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(unlisted, events ++ [widening])

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(
               prelude_records(sources),
               events ++ [run_started_event(bundle, 3)]
             )
  end

  test "an environment that compiled no component is proven, not excused" do
    {:ok, identity} = FrozenBundle.identity([])

    events = [
      canonical_event(1, "run-started", %{
        "missions" => %{},
        "workflow_prelude" => %{
          "component_ids" => [],
          "dependency_indices" => [],
          "hash" => identity
        }
      }),
      canonical_event(2, "capability-started", %{
        "capability_id" => "cap-1",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "read"
      })
    ]

    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")
    assert :ok = emit_small(sink, "cap-1")
    assert {:ok, unrelated} = InspectionSink.records(sink)

    # Nothing to prove, and the committed identity is the empty one.
    assert :ok = InspectionArtifact.validate_correlations(unrelated, events)

    mismatched = put_in(events, [Access.at(0), "data", "workflow_prelude", "hash"], @source_hash)

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(unrelated, mismatched)

    invented = unrelated ++ prelude_records(%{"base" => "(ns base) (def value 1)"})

    assert {:error, :inspection_correlation_missing} =
             InspectionArtifact.validate_correlations(invented, events)
  end

  # An artifact must not be publishable against a projection the canonical
  # trace would itself refuse to load.
  test "prelude correlation refuses a projection the trace log would reject" do
    {:ok, bundle} = compiled_bundle()
    records = prelude_records(effective_sources())
    [%{"data" => %{"workflow_prelude" => projection}} = started] = [run_started_event(bundle)]

    incomplete = [
      %{},
      Map.delete(projection, "component_ids"),
      Map.delete(projection, "dependency_indices"),
      Map.delete(projection, "hash"),
      %{projection | "dependency_indices" => [[], [1]]},
      %{projection | "component_ids" => ["base", "base"]}
    ]

    for candidate <- incomplete do
      events = [put_in(started, ["data", "workflow_prelude"], candidate)]

      assert {:error, :inspection_correlation_missing} =
               InspectionArtifact.validate_correlations(records, events),
             "expected #{inspect(candidate)} to fail closed"
    end
  end

  @tag :tmp_dir
  test "an overridden component proves its candidate source, not the manifest source", %{
    tmp_dir: dir
  } do
    manifest = checkpoint_manifest()
    candidate = ~S|(ns app) (defn run [input] (return {"overridden" true}))|

    descriptor = %{
      "target" => %{"environment" => "workflow"},
      "component_id" => "app",
      "base_source_hash" => ComponentOverride.hash(@checkpoint_workflow_source),
      "source_hash" => ComponentOverride.hash(candidate),
      "path" => "candidate.clj"
    }

    manifest_path = Path.join(dir, "ptc.json")
    inspection_path = Path.join(dir, "run.inspection.jsonl")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(Path.join(dir, "workflow.clj"), @checkpoint_workflow_source)
    File.write!(Path.join(dir, "candidate.clj"), candidate)
    File.write!(Path.join(dir, "override.json"), Jason.encode!(descriptor))

    {:ok, registry} = ProviderRegistry.new(%{})

    assert {:ok, _result} =
             manifest_path
             |> ApplicationPackage.request_directory(
               inspection_capture: true,
               result_projection: :json,
               component_override_descriptor: Path.join(dir, "override.json"),
               installed_limits: registry.installed_limits
             )
             |> RunLifecycle.build(registry,
               trace_path: Path.join(dir, "run.private.jsonl"),
               inspect: inspection_path,
               private_output: Path.join(dir, "run.result.json")
             )
             |> RunLifecycle.execute()

    assert {:ok, records} = InspectionArtifact.load(inspection_path)
    prelude = Enum.find(records, &(&1["record_type"] == "prelude-source"))
    assert prelude["payload"]["source"] == candidate
  end

  defp compiled_bundle do
    sources = effective_sources()

    {:ok, base} = Component.new(id: "base", source: sources["base"], dependencies: [])
    {:ok, main} = Component.new(id: "main", source: sources["main"], dependencies: ["base"])

    PtcRunner.Kernel.compile_bundle([base, main])
  end

  defp effective_sources,
    do: %{"base" => "(ns base) (def value 1)", "main" => "(ns main) (def value 2)"}

  defp run_started_event(bundle, sequence \\ 1) do
    {:ok, projection} = FrozenBundle.trace_metadata(bundle)

    canonical_event(sequence, "run-started", %{
      "missions" => %{},
      "workflow_prelude" => %{
        "component_ids" => projection.component_ids,
        "dependency_indices" => projection.dependency_indices,
        "hash" => projection.hash
      }
    })
  end

  # Frozen order places dependencies first, which is the order a run captures.
  defp prelude_records(sources) do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    for id <- ["base", "main", "ghost"], source = sources[id], source != nil do
      emit!(sink, "prelude-source", %{component_id: id}, %{
        environment: :workflow,
        source: source,
        source_hash: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
        source_bytes: byte_size(source)
      })
    end

    {:ok, records} = InspectionSink.records(sink)
    records
  end

  defp checkpoint_manifest(event_policy \\ "private") do
    %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{"seen" => "checkpoint-input"}},
      "events" => %{"policy" => event_policy}
    }
  end

  defp emit_small(sink, capability_id) do
    InspectionSink.emit(
      sink,
      "capability-input",
      %{capability_id: capability_id},
      %{environment: :mission, mission_name: "default", name: "read", arguments: %{"id" => 1}}
    )
  end

  defp emit!(sink, type, correlation, payload),
    do: :ok = InspectionSink.emit(sink, type, correlation, payload)

  defp mission_evaluation_source_payload do
    %{
      environment: :mission,
      mission_name: "default",
      program_kind: :"ptc-lisp",
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    }
  end

  defp persisted_records(path, value) do
    {:ok, sink} = InspectionSink.start(run_id: "run-1", trace_id: "trace-1")

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-input",
               %{capability_id: "cap-1"},
               %{
                 environment: :workflow,
                 name: :"llm-request",
                 arguments: %{
                   system: "system",
                   messages: [%{role: :user, content: value}]
                 }
               }
             )

    assert :ok =
             InspectionSink.emit(
               sink,
               "capability-output",
               %{capability_id: "cap-1"},
               %{
                 environment: :workflow,
                 name: :"llm-request",
                 result: %{status: :ok, value: %{content: "answer"}}
               }
             )

    assert {:ok, records} = InspectionSink.records(sink)

    events = [
      %{
        run_id: "run-1",
        trace_id: "trace-1",
        type: "capability-started",
        data: %{
          capability_id: "cap-1",
          environment: :workflow,
          name: "llm-request"
        }
      },
      %{
        run_id: "run-1",
        trace_id: "trace-1",
        type: "capability-stopped",
        data: %{
          capability_id: "cap-1",
          environment: :workflow,
          name: "llm-request"
        }
      }
    ]

    assert :ok = InspectionArtifact.persist(path, records, events)
    assert :ok = InspectionSink.stop(sink)
    records
  end

  defp canonical_events do
    [
      canonical_event(1, "run-started", %{"missions" => %{"default" => %{}}}),
      canonical_event(2, "capability-started", %{
        "capability_id" => "cap-1",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "read"
      }),
      canonical_event(3, "capability-stopped", %{
        "capability_id" => "cap-1",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "read"
      }),
      canonical_event(4, "run-stopped", %{"outcome" => "ok"})
    ]
  end

  defp canonical_model_events do
    [
      canonical_event(1, "run-started", %{"missions" => %{"default" => %{}}}),
      canonical_event(2, "capability-started", %{
        "capability_id" => "cap-1",
        "environment" => "workflow",
        "name" => "llm-request"
      }),
      canonical_event(3, "capability-stopped", %{
        "capability_id" => "cap-1",
        "environment" => "workflow",
        "name" => "llm-request"
      }),
      canonical_event(4, "run-stopped", %{"outcome" => "ok"})
    ]
  end

  defp dropped_events(counts) do
    [
      canonical_event(1, "run-started", %{"missions" => %{"default" => %{}}}),
      canonical_event(2, "events-dropped", %{"counts" => counts}),
      canonical_event(3, "run-stopped", %{
        "outcome" => "ok",
        "reason" => nil,
        "usage" => %{"events_dropped" => counts}
      })
    ]
  end

  defp canonical_event(sequence, type, data) do
    %{
      "schema_version" => 2,
      "run_id" => "run-1",
      "trace_id" => "trace-1",
      "sequence" => sequence,
      "timestamp" => "2026-07-17T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp result_hash(value) do
    {:ok, encoded} = DeterministicJSON.encode(value)
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
  end

  defp resequence(records) do
    records
    |> Enum.with_index(1)
    |> Enum.map(fn {record, sequence} -> Map.put(record, "sequence", sequence) end)
  end
end
