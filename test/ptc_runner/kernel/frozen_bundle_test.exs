defmodule PtcRunner.Kernel.FrozenBundleTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.Library

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
end
