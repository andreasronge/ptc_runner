defmodule PtcRunner.Kernel.MissionInventoryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @expected ~S|{"schema_version":2,"exports":[{"ref":"tools/ping","kind":"function","call":"(tools/ping value)","doc":"Ping.","effect":"unknown","contract":null}],"capabilities":[{"name":"native.read","call":"(tool/native.read arguments)","description":"Read","effect":"read","input_schema":{"additionalProperties":false,"properties":{"query":{"type":"string"}},"required":["query"],"type":"object"},"output_schema":null}],"limits":{"evaluation_timeout_ms":1000,"subordinate_source_bytes":131072,"mission_capability_calls":128,"mission_capability_calls_per_name":32,"capability_argument_bytes":262144,"capability_result_bytes":1000000}}|
  @expected_model ~S|{"schema_version":1,"mission_api":[{"call":"(tools/ping value)","doc":"Ping."}],"direct_capabilities":[{"call":"(tool/native.read arguments)","description":"Read","input_schema":{"additionalProperties":false,"properties":{"query":{"type":"string"}},"required":["query"],"type":"object"},"output_schema":null}],"limits":{"evaluation_timeout_ms":1000,"subordinate_source_bytes":131072,"mission_capability_calls":128,"mission_capability_calls_per_name":32,"capability_argument_bytes":262144,"capability_result_bytes":1000000}}|

  test "renders and hashes the exact versioned frozen inventory" do
    {:ok, mission, limits} = mission_fixture()

    assert {:ok, inventory} = MissionInventory.build(mission, limits)
    assert inventory.rendered == @expected
    assert inventory.bytes == byte_size(@expected)

    assert inventory.hash ==
             :crypto.hash(:sha256, @expected) |> Base.encode16(case: :lower)

    assert inventory.model_schema_version == 1
    assert inventory.model_rendered == @expected_model
    assert inventory.model_bytes == byte_size(@expected_model)

    assert inventory.model_hash ==
             :crypto.hash(:sha256, @expected_model) |> Base.encode16(case: :lower)

    assert {:ok, repeated} = MissionInventory.build(mission, limits)
    assert repeated == inventory

    assert {:error, :mission_inventory_exceeded} =
             MissionInventory.build(mission, limits, max_bytes: byte_size(@expected) - 1)
  end

  test "normal run and REPL expose identical inventory and compact model context" do
    {:ok, mission, limits} = mission_fixture()
    {:ok, kernel_component} = Library.component("kernel")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mission-inventory")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert config.mission_inventory.rendered == @expected

    assert {:ok, %{value: @expected}} =
             Kernel.run("(return (kernel/mission-inventory))", config)

    assert {:ok, %{value: @expected_model}} =
             Kernel.run("(return (kernel/mission-model-context))", config)

    started = Enum.find(EventSink.events(sink), &(&1.type == "run-started"))
    assert started.data.mission_inventory_hash == config.mission_inventory.hash
    assert started.data.mission_inventory_bytes == byte_size(@expected)
    assert started.data.mission_model_context_hash == config.mission_inventory.model_hash
    assert started.data.mission_model_context_bytes == byte_size(@expected_model)

    # Both emitters send the one prebuilt payload, so the compact dependency
    # projection is identical for Runner and REPL by construction.
    assert started.data.workflow_prelude == %{
             component_ids: ["kernel"],
             dependency_indices: [[]],
             hash: workflow_bundle.hash
           }

    assert started.data == config.run_started_metadata

    {:ok, repl} = ReplSession.new(config: config)

    assert {:ok, %{return: @expected}, repl} =
             ReplSession.eval(repl, "(kernel/mission-inventory)")

    assert {:ok, %{return: @expected_model}, repl} =
             ReplSession.eval(repl, "(kernel/mission-model-context)")

    assert {:ok, _events} = ReplSession.close(repl)
  end

  test "hidden exports and capabilities are excluded" do
    source = """
    (ns visible "Visible" {:visibility :prompt})
    (defn shown [] 1)
    (ns hidden "Hidden" {:visibility :discoverable})
    (defn omitted [] 2)
    """

    {:ok, component} = Component.new(id: "visibility", source: source)
    {:ok, bundle} = Kernel.compile_bundle([component])

    {:ok, hidden_capability} =
      Capability.new(
        name: "hidden",
        input_schema: %{"type" => "object"},
        model_visible: false,
        callback: fn _ -> {:ok, %{}} end
      )

    {:ok, mission} =
      MissionEnvironment.new(bundle: bundle, capabilities: [hidden_capability])

    {:ok, inventory} = MissionInventory.build(mission, Limits.defaults())
    decoded = Jason.decode!(inventory.rendered)

    assert Enum.map(decoded["exports"], & &1["ref"]) == ["visible/shown"]
    assert decoded["capabilities"] == []

    model = Jason.decode!(inventory.model_rendered)
    assert Enum.map(model["mission_api"], & &1["call"]) == ["(visible/shown)"]
    assert model["direct_capabilities"] == []
  end

  test "compact context accepts every capability inventory within the installed ceiling" do
    large_text = String.duplicate("x", 65_400)
    schema = %{"type" => "object", "description" => large_text}

    {:ok, capability} =
      Capability.new(
        name: "large",
        input_schema: schema,
        output_schema: schema,
        callback: fn _ -> {:ok, %{}} end
      )

    {:ok, mission} = MissionEnvironment.new(capabilities: [capability])

    assert {:ok, inventory} = MissionInventory.build(mission, Limits.defaults())
    assert inventory.bytes > 128 * 1_024
    assert inventory.bytes <= 256 * 1_024
    assert inventory.model_bytes <= 256 * 1_024
  end

  defp mission_fixture do
    source = """
    (ns tools "Tools." {:visibility :prompt})
    (defn ping "Ping." [value] value)
    """

    {:ok, component} = Component.new(id: "tools", source: source)
    {:ok, bundle} = Kernel.compile_bundle([component])

    {:ok, capability} =
      Capability.new(
        name: "native.read",
        description: "Read",
        input_schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        },
        effect: :read,
        callback: fn _ -> {:ok, %{}} end
      )

    {:ok, mission} = MissionEnvironment.new(bundle: bundle, capabilities: [capability])
    {:ok, limits} = Limits.new()
    {:ok, mission, limits}
  end
end
