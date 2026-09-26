defmodule PtcRunner.Kernel.ModelCapabilitiesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.InspectionArtifact.Assembler
  alias PtcRunner.Kernel.InspectionArtifact.Indexes
  alias PtcRunner.Kernel.InspectionArtifact.Limits, as: InspectionLimits
  alias PtcRunner.Kernel.InspectionRecord
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ModelCapabilities
  alias PtcRunner.Kernel.RunState
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

  test "an explicitly classified non-chat model call is hashed, attested and inspected" do
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
end
