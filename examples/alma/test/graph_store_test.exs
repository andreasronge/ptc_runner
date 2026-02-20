defmodule Alma.GraphStoreTest do
  use ExUnit.Case, async: true

  alias Alma.GraphStore

  describe "new/0" do
    test "returns empty map" do
      assert GraphStore.new() == %{}
    end
  end

  describe "add_edges/2" do
    test "creates bidirectional adjacency" do
      graph = GraphStore.new() |> GraphStore.add_edges([["A", "B"]])
      assert MapSet.member?(graph["A"], "B")
      assert MapSet.member?(graph["B"], "A")
    end

    test "is idempotent" do
      graph =
        GraphStore.new()
        |> GraphStore.add_edges([["A", "B"]])
        |> GraphStore.add_edges([["A", "B"]])

      assert GraphStore.neighbors(graph, "A") == ["B"]
      assert GraphStore.neighbors(graph, "B") == ["A"]
    end
  end

  describe "neighbors/2" do
    test "returns sorted list" do
      graph = GraphStore.new() |> GraphStore.add_edges([["B", "C"], ["B", "A"], ["B", "D"]])
      assert GraphStore.neighbors(graph, "B") == ["A", "C", "D"]
    end

    test "returns [] for unknown node" do
      graph = GraphStore.new() |> GraphStore.add_edges([["A", "B"]])
      assert GraphStore.neighbors(graph, "Z") == []
    end
  end

  describe "shortest_path/3" do
    test "direct neighbor" do
      graph = GraphStore.new() |> GraphStore.add_edges([["A", "B"]])
      assert GraphStore.shortest_path(graph, "A", "B") == ["A", "B"]
    end

    test "multi-hop returns shortest path" do
      # A - B - C
      # |       |
      # D - E - F
      graph =
        GraphStore.new()
        |> GraphStore.add_edges([
          ["A", "B"],
          ["B", "C"],
          ["A", "D"],
          ["D", "E"],
          ["E", "F"],
          ["C", "F"]
        ])

      path = GraphStore.shortest_path(graph, "A", "C")
      # Shortest is A->B->C (length 3), not A->D->E->F->C (length 5)
      assert length(path) == 3
      assert hd(path) == "A"
      assert List.last(path) == "C"
    end

    test "returns nil for disconnected nodes" do
      graph =
        GraphStore.new()
        |> GraphStore.add_edges([["A", "B"], ["C", "D"]])

      assert GraphStore.shortest_path(graph, "A", "C") == nil
    end

    test "returns [from] when from == to" do
      graph = GraphStore.new() |> GraphStore.add_edges([["A", "B"]])
      assert GraphStore.shortest_path(graph, "A", "A") == ["A"]
    end
  end
end
