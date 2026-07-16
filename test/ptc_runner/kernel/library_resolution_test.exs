defmodule PtcRunner.Kernel.LibraryResolutionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Library

  test "expands installed dependencies before dependants with lexical tie breaking" do
    assert {:ok, components} =
             Library.resolve_components([{:library, "agent.core"}, {:library, "agent.feedback"}])

    assert Enum.map(components, & &1.id) == [
             "agent.feedback",
             "agent.native",
             "agent.retry",
             "kernel",
             "llm",
             "result",
             "workflow.event",
             "agent.core"
           ]
  end

  test "rejects repeated explicit selections, unknown IDs, and local collisions" do
    assert {:error, :duplicate_library_selection} =
             Library.resolve_components([{:library, "kernel"}, {:library, "kernel"}])

    assert {:error, :unknown_library} =
             Library.resolve_components([{:library, "not-installed"}])

    {:ok, local_kernel} =
      Component.new(id: "kernel", source: "(ns local.kernel)", origin: "local.lisp")

    assert {:error, :local_library_collision} =
             Library.resolve_components([local_kernel, {:library, "kernel"}])
  end

  test "rejects missing local dependencies and cycles before compilation" do
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

    assert {:error, :missing_component_dependency} = Library.resolve_components([missing])
    assert {:error, :component_cycle} = Library.resolve_components([first, second])
  end
end
