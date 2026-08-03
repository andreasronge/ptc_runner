defmodule PtcRunner.Kernel.FrozenBundleTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.Library

  test "bundle hash includes direct dependency edges" do
    base = component!("base", "(ns base) (def value 1)")
    main = component!("main", "(ns main) (def value 2)")

    assert {:ok, disconnected} = Kernel.compile_bundle([base, main])

    assert {:ok, connected} =
             Kernel.compile_bundle([base, %{main | dependencies: ["base"]}])

    assert Enum.map(disconnected.components, &{&1.id, &1.source_hash}) ==
             Enum.map(connected.components, &{&1.id, &1.source_hash})

    refute disconnected.hash == connected.hash
  end

  test "bundle hash matches the canonical V2 golden vectors" do
    main = component!("main", "(ns main) (def value 1)")
    dependency = component!("z", "(ns z) (def value 1)")
    dependent = component!("a", "(ns a) (def value 2)", ["z"])

    assert {:ok, single} = Kernel.compile_bundle([main])
    assert single.hash == "8c7bf79153b10e72d4bfd53e6796babfaf5f01a067eef5d6a9d133bf45e00902"

    assert {:ok, graph} = Kernel.compile_bundle([dependent, dependency])
    assert graph.component_ids == ["z", "a"]
    assert graph.hash == "2d046027f6893dc714343b2bcf6f486e0b949bf8be8cf8a9aa41b8929dd90066"
  end

  test "trace_metadata projects aligned dependency indices in frozen order" do
    assert {:ok, %{component_ids: [], dependency_indices: [], hash: nil}} =
             FrozenBundle.trace_metadata(nil)

    {:ok, components} =
      Library.components(~w(agent.feedback agent.native agent.prompt agent.retry kernel llm result
        workflow.event agent.core))

    {:ok, bundle} = Kernel.compile_bundle(components)
    assert {:ok, metadata} = FrozenBundle.trace_metadata(bundle)

    assert metadata.component_ids == bundle.component_ids
    assert metadata.hash == bundle.hash
    assert length(metadata.dependency_indices) == length(metadata.component_ids)

    positions = metadata.component_ids |> Enum.with_index() |> Map.new()
    agent_core_position = Map.fetch!(positions, "agent.core")
    agent_core_indices = Enum.at(metadata.dependency_indices, agent_core_position)

    expected =
      ~w(agent.feedback agent.native agent.prompt agent.retry kernel llm result workflow.event)
      |> Enum.map(&Map.fetch!(positions, &1))
      |> Enum.sort()

    assert agent_core_indices == expected

    for {indices, position} <- Enum.with_index(metadata.dependency_indices) do
      assert indices == Enum.sort(Enum.uniq(indices))
      assert Enum.all?(indices, &(&1 >= 0 and &1 < position))
    end

    # Leaf components carry no edges.
    assert Enum.at(metadata.dependency_indices, Map.fetch!(positions, "kernel")) == []
  end

  test "concurrent first seals share one attestation key" do
    storage_key = {FrozenBundle, :attestation_key}
    :persistent_term.erase(storage_key)
    parent = self()
    component = Library.component("kernel") |> elem(1)

    tasks =
      for _index <- 1..64 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:seal -> Kernel.compile_bundle([component]))
        end)
      end

    pids =
      for _index <- 1..64 do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :seal))

    bundles = Enum.map(tasks, fn task -> task |> Task.await(30_000) |> elem(1) end)
    assert Enum.all?(bundles, &FrozenBundle.valid?/1)
  end

  defp component!(id, source, dependencies \\ []) do
    {:ok, component} =
      Component.new(id: id, source: source, dependencies: dependencies)

    component
  end
end
