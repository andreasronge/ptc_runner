defmodule PtcRunner.Kernel.FileCapabilityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.FileCapability
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @tag :tmp_dir
  test "a root-granted file capability is confined to the mission environment", %{tmp_dir: root} do
    File.write!(Path.join(root, "inside.txt"), "bounded fixture")

    {:ok, capability} = FileCapability.new(root: root, max_bytes: 1_024)
    {:ok, kernel_component} = Library.component("kernel")
    {:ok, fs_component} = Library.component("fs")
    {:ok, cap_component} = Library.component("cap")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, mission_bundle} = Kernel.compile_bundle([fs_component, cap_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)
    {:ok, mission} = MissionEnvironment.new(bundle: mission_bundle, capabilities: [capability])
    {:ok, limits} = Limits.new()
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
end
