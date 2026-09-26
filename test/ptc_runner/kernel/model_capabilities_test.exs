defmodule PtcRunner.Kernel.ModelCapabilitiesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionArtifact.Admission
  alias PtcRunner.Kernel.InspectionArtifact.Assembler
  alias PtcRunner.Kernel.InspectionArtifact.Handle
  alias PtcRunner.Kernel.InspectionArtifact.Indexes
  alias PtcRunner.Kernel.InspectionArtifact.Limits, as: InspectionLimits
  alias PtcRunner.Kernel.InspectionRecord
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ModelCapabilities
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TestSupport.TestHelpers

  test "model and chat classification accepts strings and atoms" do
    for name <- ["llm-request", :"llm-request"] do
      assert ModelCapabilities.model_call?(name)
      assert ModelCapabilities.chat?(name)
      assert ModelCapabilities.reserved_name?(name)
    end

    for name <- ["decision-request", :"decision-request"] do
      refute ModelCapabilities.model_call?(name)
      refute ModelCapabilities.chat?(name)
      assert ModelCapabilities.reserved_name?(name)
    end

    for name <- ["workspace.read", nil, 42] do
      refute ModelCapabilities.model_call?(name)
      refute ModelCapabilities.chat?(name)
      refute ModelCapabilities.reserved_name?(name)
    end
  end

  test "MCP public mappings cannot claim current or future model names" do
    for name <- ["llm-request", "decision-request"] do
      assert_raise ArgumentError, fn ->
        MCPSource.builder(
          transport: {:streamable_http, endpoint: "https://example.com/mcp"},
          tools: %{"upstream" => %{as: name, effect: :read}}
        )
      end
    end
  end

  test "a host-built chat capability retains model-call treatment by name" do
    documents = %{
      "ptc.json" => Jason.encode!(TestHelpers.valid_manifest()),
      "main.clj" => "(ns app) (defn run [input] (return input))"
    }

    assert {:ok, package, _input} = ApplicationPackage.acquire_memory("ptc.json", documents)

    {:ok, capability} =
      Capability.new(
        name: "llm-request",
        input_schema: %{"type" => "object"},
        callback: fn _arguments -> {:ok, %{}} end
      )

    assert {:ok, environment} =
             WorkflowEnvironment.new_for_package([capabilities: [capability]], package)

    assert Map.has_key?(environment.capabilities, "llm-request")
  end

  @tag :tmp_dir
  test "an explicitly classified non-chat model call is hashed, attested and inspected", %{
    tmp_dir: directory
  } do
    name = "classification-fixture-request"
    parent = self()
    refute ModelCapabilities.chat?(name)
    assert ModelCapabilities.model_call?(name, [name])

    {:ok, capability} =
      Capability.new(
        name: name,
        input_schema: %{"type" => "object", "additionalProperties" => true},
        llm_reservation: %{
          source: "llm",
          output_tokens: 5,
          tariff: nil,
          bound: fn arguments, _tariff ->
            send(parent, {:attested, arguments})
            {:ok, %{total_tokens: 10, cost: nil}}
          end
        },
        callback: fn arguments, context ->
          send(parent, {:requester_context, context})
          {:ok, %{"content" => "ok", "questions" => arguments["questions"]}}
        end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new(llm_total_tokens: 50)
    {:ok, state} = RunState.start(limits)

    {:ok, sink} =
      StreamingInspection.start(
        run_id: "model-classification-run",
        trace_id: "model-classification-trace",
        model_call_names: [name]
      )

    arguments = %{
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "questions" => [%{"id" => "q"}],
      "schema" => %{"type" => "not-a-schema"}
    }

    context =
      state
      |> TestHelpers.dispatch_context(:workflow, 500)
      |> Map.put(:model_call_names, [name])

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               name,
               arguments,
               context,
               nil,
               sink
             )

    assert_receive {:attested, ^arguments}
    assert_receive {:requester_context, requester_context}
    assert Map.has_key?(requester_context, :llm_request_deadline_ms)
    assert {:ok, [input, output]} = StreamingInspection.records(sink)
    assert input["payload"]["request_hash"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert input["payload"]["arguments"] == arguments

    assert InspectionRecord.validate(
             input,
             "model-classification-run",
             "model-classification-trace",
             1,
             [name]
           ) == :ok

    indexes = Indexes.create(self())

    assembly =
      Assembler.new(indexes, InspectionLimits.defaults(), %{
        run_id: "model-classification-run",
        trace_id: "model-classification-trace",
        model_call_names: [name]
      })

    {:ok, assembly} =
      Assembler.ingest(
        assembly,
        input,
        0,
        1,
        "input"
      )

    {:ok, assembly} =
      Assembler.ingest(
        assembly,
        output,
        1,
        1,
        "output"
      )

    capability_id = input["correlation"]["capability_id"]

    trace_facts = %{
      "trace_id" => "model-classification-trace",
      "capabilities" => %{
        capability_id => %{"environment" => "workflow", "mission_name" => nil, "name" => name}
      }
    }

    assert {:ok, completed} = Assembler.finish(assembly, trace_facts)

    assert [{_, %{class: :model}}] =
             Indexes.lookup(
               completed.indexes,
               :capability_join,
               {"model-classification-run", capability_id}
             )

    assert [{_, %{"turns" => 0, "model_exchanges" => 1}}] =
             Indexes.lookup(completed.indexes, :counts, {"model-classification-run", :summary})

    path = Path.join(directory, "model-classification.ptcins")
    {:ok, publication} = PublicationHandle.reserve_stream_for(path, :inspection, 0o600, self())

    {:ok, persisted_sink} =
      InspectionSink.start(
        run_id: "model-classification-run",
        trace_id: "model-classification-trace",
        publication_handle: publication,
        model_call_names: [name]
      )

    for record <- [input, output] do
      assert :ok =
               InspectionSink.emit(
                 persisted_sink,
                 record["record_type"],
                 record["correlation"],
                 record["payload"]
               )
    end

    assert {:ok, seal} = InspectionSink.seal(persisted_sink)
    assert :ok = InspectionArtifact.publish_handle(publication, seal)
    assert {:ok, handle} = InspectionArtifact.open(path)

    admitted_trace_facts =
      Map.merge(trace_facts, %{"expected_model_exchange_ids" => [], "terminal?" => true})

    assert {:ok, admitted} =
             Admission.run(
               handle,
               Indexes.create(self()),
               fn _run_id, _trace_id -> {:ok, admitted_trace_facts} end,
               InspectionLimits.defaults(),
               expected_identity: %{
                 run_id: "model-classification-run",
                 trace_id: "model-classification-trace",
                 model_call_names: [name]
               }
             )

    assert admitted.turn_evidence["missing_exchange_count"] == 0
    assert admitted.turn_evidence["complete?"]

    assert [{_, %{"turns" => 0, "model_exchanges" => 1}}] =
             Indexes.lookup(admitted.indexes, :counts, {"model-classification-run", :summary})

    Handle.close(handle)
  end

  test "non-chat model classification requires a reservation attestation under a token ceiling" do
    name = "classification-unbound-request"

    {:ok, capability} =
      Capability.new(
        name: name,
        input_schema: %{"type" => "object"},
        callback: fn _arguments -> {:ok, %{}} end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new(llm_total_tokens: 50)
    {:ok, state} = RunState.start(limits)
    context = TestHelpers.dispatch_context(state, :workflow, 500)

    assert %{status: :ok} =
             Dispatcher.dispatch(state, :workflow, environment, name, %{}, context, nil, nil)

    assert %{status: :error, reason: :reservation_attestation_unavailable} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               name,
               %{},
               Map.put(context, :model_call_names, [name]),
               nil,
               nil
             )
  end

  test "conversation completeness expects only chat exchanges" do
    events = [
      trace_event(1, "run-started", %{"missions" => %{}}),
      trace_event(2, "capability-started", %{
        "capability_id" => "decision-call",
        "environment" => "workflow",
        "name" => "decision-request"
      }),
      trace_event(3, "run-stopped", %{
        "outcome" => "ok",
        "usage" => %{"llm_budget" => %{"total_tokens" => nil, "cost" => nil}}
      })
    ]

    assert ModelCapabilities.model_call?("decision-request", ["decision-request"])
    refute ModelCapabilities.chat?("decision-request")

    assert %{facts_by_run_id: %{"model-classification-run" => facts}} =
             TraceLog.compile_analysis(events, :private)

    assert facts["expected_model_exchange_ids"] == []
  end

  defp trace_event(sequence, type, data) do
    %{
      "schema_version" => 2,
      "run_id" => "model-classification-run",
      "trace_id" => "model-classification-trace",
      "sequence" => sequence,
      "timestamp" => "2026-07-12T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
