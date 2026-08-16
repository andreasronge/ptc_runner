defmodule PtcRunner.Kernel.LibraryResolutionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Library

  test "lists every shipped component in lexical order" do
    assert Library.component_ids() ==
             ~w(agent.core agent.feedback agent.main agent.native agent.prompt agent.retry analysis cap debug.nav kernel llm result runtime workflow.event)

    assert {:ok, components} = Library.components(Library.component_ids())
    assert Enum.map(components, & &1.id) == Library.component_ids()
  end

  test "expands installed dependencies into lexical acquisition order" do
    assert {:ok, components} =
             Library.resolve_components([{:library, "agent.core"}, {:library, "agent.feedback"}])

    assert Enum.map(components, & &1.id) == [
             "agent.core",
             "agent.feedback",
             "agent.native",
             "agent.prompt",
             "agent.retry",
             "kernel",
             "llm",
             "result",
             "workflow.event"
           ]
  end

  test "rejects repeated explicit selections, unknown IDs, and local collisions" do
    assert {:error, :duplicate_library_selection} =
             Library.resolve_components([{:library, "kernel"}, {:library, "kernel"}])

    assert {:error, :unknown_library} =
             Library.resolve_components([{:library, "not-installed"}])

    {:ok, local_kernel} =
      Component.new(id: "kernel", source: "(ns local.kernel)", origin: "local.clj")

    assert {:error, :local_library_collision} =
             Library.resolve_components([local_kernel, {:library, "kernel"}])
  end

  test "retains local graph failures for bounded bundle compilation" do
    {:ok, missing} =
      Component.new(
        id: "local.missing",
        source: "(ns local.missing)",
        dependencies: ["absent"]
      )

    {:ok, first} =
      Component.new(id: "local.first", source: "(ns local.first)", dependencies: ["local.second"])

    {:ok, second} =
      Component.new(
        id: "local.second",
        source: "(ns local.second)",
        dependencies: ["local.first"]
      )

    assert {:ok, [^missing]} = Library.resolve_components([missing])

    assert {:error, %{reason: :missing_component_dependency}} =
             PtcRunner.Kernel.compile_bundle([missing])

    assert {:ok, [^first, ^second]} = Library.resolve_components([first, second])

    assert {:error, %{reason: :component_cycle}} =
             PtcRunner.Kernel.compile_bundle([first, second])
  end
end
