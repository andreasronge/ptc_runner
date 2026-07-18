defmodule PtcRunner.Kernel.FileCapabilityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.FileCapability
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @tag :tmp_dir
  test "a root-granted file capability is confined to the mission environment", %{tmp_dir: root} do
    File.write!(Path.join(root, "inside.txt"), "bounded fixture")

    {:ok, capability} = FileCapability.new(root: root, max_bytes: 1_024)

    assert %{
             effect: :read,
             input_schema: %{"additionalProperties" => false, "required" => ["path"]},
             output_schema: %{"additionalProperties" => false}
           } = Capability.metadata(capability)

    {:ok, kernel_component} = Library.component("kernel")
    {:ok, fs_component} = Library.component("fs")
    {:ok, cap_component} = Library.component("cap")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, mission_bundle} = Kernel.compile_bundle([fs_component, cap_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)
    {:ok, mission} = MissionEnvironment.new(bundle: mission_bundle, capabilities: [capability])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "file-capability")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = "(return (kernel/eval (program (return (fs/read \"inside.txt\")))))"

    assert {:ok,
            %{
              value: %{
                outcome: :returned,
                value: %{"bytes" => 15, "content" => "bounded fixture", "path" => "inside.txt"}
              }
            }} = Kernel.run(source, config)

    assert {:error, %{kind: :workflow_failed}} =
             Kernel.run("(return (tool/fs-read {:path \"inside.txt\"}))", config)

    discovery_source = "(return (kernel/eval (program (return (cap/list)))))"

    assert {:ok, %{value: %{outcome: :returned, value: [%{name: "fs-read"}]}}} =
             Kernel.run(discovery_source, config)
  end

  @tag :tmp_dir
  test "file reads reject traversal, symlinks, and oversized content", %{tmp_dir: root} do
    outside = root <> "-outside.txt"
    File.write!(outside, "outside")
    File.write!(Path.join(root, "large.txt"), String.duplicate("x", 17))
    File.ln_s!(outside, Path.join(root, "escape.txt"))
    on_exit(fn -> File.rm(outside) end)

    {:ok, capability} = FileCapability.new(root: root, max_bytes: 16)

    assert {:error, _reason} = capability.validate.(%{})
    assert {:error, _reason} = capability.validate.(%{"path" => "large.txt", "extra" => true})

    assert {:error, %{kind: :denied}} = capability.callback.(%{"path" => "../outside"})
    assert {:error, %{kind: :denied}} = capability.callback.(%{"path" => "escape.txt"})
    assert {:error, %{kind: :invalid_request}} = capability.callback.(%{"path" => "large.txt"})
  end

  test "the fs library requires an explicitly granted file capability" do
    {:ok, fs_component} = Library.component("fs")
    {:ok, bundle} = Kernel.compile_bundle([fs_component])

    assert {:error, {:missing_capability_requirement, ["fs-read"]}} =
             MissionEnvironment.new(bundle: bundle)
  end

  @tag :tmp_dir
  test "file capability visibility is configurable without revoking authority", %{tmp_dir: root} do
    granted_root = Path.join(root, "grant")
    File.mkdir!(granted_root)
    File.write!(Path.join(granted_root, "visible.txt"), "still callable")

    {:ok, capability} =
      FileCapability.new(root: granted_root, max_bytes: 1_024, model_visible: false)

    refute capability.model_visible

    assert {:ok, %{"content" => "still callable"}} =
             capability.callback.(%{"path" => "visible.txt"})

    {:ok, registry} = ProviderRegistry.new()
    {:ok, limits} = Limits.new()

    context = %{
      directory: root,
      destination: :mission,
      owner: self(),
      limits: limits,
      installed_limits: limits
    }

    assert {:ok, %{capabilities: [%{model_visible: false}]}} =
             ProviderRegistry.build(
               registry,
               "file-read",
               %{"root" => "grant", "model_visible" => false},
               context
             )

    {:ok, kernel_component} = Library.component("kernel")
    {:ok, fs_component} = Library.component("fs")
    {:ok, cap_component} = Library.component("cap")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, mission_bundle} = Kernel.compile_bundle([fs_component, cap_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)

    {:ok, mission} =
      MissionEnvironment.new(bundle: mission_bundle, capabilities: [capability])

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "hidden-file-authority")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{outcome: :returned, value: []}}} =
             Kernel.run("(return (kernel/eval-source \"(return (cap/list))\"))", config)

    assert {:ok, %{value: %{outcome: :returned, value: %{"content" => "still callable"}}}} =
             Kernel.run(
               ~S|(return (kernel/eval-source "(return (fs/read \"visible.txt\"))"))|,
               config
             )

    assert {:ok, %{value: %{outcome: :returned, value: %{status: :ok}}}} =
             Kernel.run(
               ~S|(return (kernel/eval-source "(return (tool/fs-read {\"path\" \"visible.txt\"}))"))|,
               config
             )

    {:ok, empty_mission_bundle} = Kernel.compile_bundle([cap_component])
    {:ok, empty_mission} = MissionEnvironment.new(bundle: empty_mission_bundle)

    {:ok, missing_config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: empty_mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{outcome: :evaluation_error, kind: :unknown_tool}}} =
             Kernel.run(
               ~S|(return (kernel/eval-source "(return (tool/fs-read {\"path\" \"visible.txt\"}))"))|,
               missing_config
             )
  end
end
