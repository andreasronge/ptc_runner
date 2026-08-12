defmodule PtcRunner.TestSupport.PrivateInspectionFixture do
  @moduledoc false

  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink

  @source "(return 42)"
  @source_hash :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)

  def create!(root, run_id \\ "private-run") do
    traces = Path.join(root, "traces")
    inspection = Path.join(root, "inspection")
    output = Path.join(root, "analysis-traces")

    Enum.each([traces, inspection, output], &File.mkdir_p!/1)

    events = canonical_events(run_id)
    File.write!(Path.join(traces, "#{run_id}.jsonl"), encode_jsonl(events))
    write_inspection!(inspection, run_id, events)

    %{traces: traces, inspection: inspection, output: output, run_id: run_id}
  end

  def canonical_events(run_id) do
    [
      event(run_id, 1, "run-started", %{
        "missions" => %{"default" => %{}},
        "workflow_prelude" => %{
          "component_ids" => ["component-#{run_id}"],
          "dependency_indices" => [],
          "hash" => "prelude-hash"
        }
      }),
      event(run_id, 2, "capability-started", %{
        "capability_id" => "llm-#{run_id}",
        "environment" => "workflow",
        "name" => "llm-request"
      }),
      event(run_id, 3, "capability-started", %{
        "capability_id" => "tool-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "workspace.read"
      }),
      event(run_id, 4, "evaluation-started", %{
        "evaluation_id" => "eval-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "program_kind" => "ptc-lisp",
        "source_hash" => @source_hash,
        "source_bytes" => byte_size(@source)
      }),
      workflow_evaluation_event(run_id, 5),
      event(run_id, 6, "run-stopped", %{"outcome" => "failed"})
    ]
  end

  defp write_inspection!(directory, run_id, events) do
    {:ok, sink} = InspectionSink.start(run_id: run_id, trace_id: "trace-#{run_id}")

    emit!(sink, "capability-input", %{capability_id: "llm-#{run_id}"}, %{
      environment: :workflow,
      name: "llm-request",
      arguments: %{"messages" => [%{"content" => "private-prompt-#{run_id}"}]}
    })

    emit!(sink, "capability-output", %{capability_id: "llm-#{run_id}"}, %{
      environment: :workflow,
      name: "llm-request",
      result: %{status: :ok, value: %{"answer" => "private-answer-#{run_id}"}}
    })

    emit!(sink, "capability-input", %{capability_id: "tool-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      arguments: %{"path" => "private-#{run_id}.txt"}
    })

    emit!(sink, "mcp-request", %{capability_id: "tool-#{run_id}", request_id: 7}, %{
      mission_name: "default",
      transport: :stdio,
      body: %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{
          "name" => "read",
          "arguments" => %{"path" => "private-#{run_id}.txt"}
        }
      }
    })

    emit!(sink, "mcp-response", %{capability_id: "tool-#{run_id}", request_id: 7}, %{
      mission_name: "default",
      transport: :stdio,
      body: %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "result" => %{
          "content" => [%{"type" => "text", "text" => "private-tool-result-#{run_id}"}]
        }
      }
    })

    emit!(sink, "capability-output", %{capability_id: "tool-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      result: %{status: :ok, value: %{"text" => "private-tool-result-#{run_id}"}}
    })

    emit!(sink, "evaluation-source", %{evaluation_id: "eval-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      program_kind: :"ptc-lisp",
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    })

    emit!(sink, "prelude-source", %{component_id: "component-#{run_id}"}, %{
      environment: :workflow,
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    })

    emit_execution_diagnostics!(sink, run_id)

    {:ok, records} = InspectionSink.records(sink)
    path = Path.join(directory, "#{run_id}.inspection.jsonl")
    :ok = InspectionArtifact.persist(path, records, events)
    :ok = InspectionSink.stop(sink)
  end

  def emit_execution_diagnostics!(sink, run_id) do
    emit!(sink, "execution-prints", %{evaluation_id: "workflow-eval-#{run_id}"}, %{
      environment: :workflow,
      prints: ["private-print-#{run_id}"],
      truncated: false
    })

    emit!(sink, "execution-error", %{evaluation_id: "workflow-eval-#{run_id}"}, %{
      environment: :workflow,
      kind: :limit_exceeded,
      reason: :timeout,
      details: %{"limit" => "run_duration_ms", "limit_ms" => 1_000}
    })
  end

  def workflow_evaluation_event(run_id, sequence) do
    event(run_id, sequence, "evaluation-started", %{
      "evaluation_id" => "workflow-eval-#{run_id}",
      "environment" => "workflow",
      "program_kind" => "ptc-lisp",
      "source_hash" => @source_hash,
      "source_bytes" => byte_size(@source)
    })
  end

  defp emit!(sink, type, correlation, payload),
    do: :ok = InspectionSink.emit(sink, type, correlation, payload)

  defp event(run_id, sequence, type, data) do
    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-26T12:00:0#{sequence}Z",
      "type" => type,
      "data" => data
    }
  end

  defp encode_jsonl(events), do: Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
end
