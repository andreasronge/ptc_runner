defmodule Alma.GraphStore do
  @moduledoc """
  In-process undirected graph store backed by an adjacency map.

  Nodes are strings. Edges are bidirectional. Provides BFS shortest-path.
  """

  @doc "Returns an empty graph."
  def new, do: %{}

  @doc """
  Adds undirected edges to the graph. Each edge is `[node_a, node_b]`.

  Returns the updated graph.
  """
  def add_edges(graph, edges) do
    Enum.reduce(edges, graph, fn [a, b], g ->
      g
      |> Map.update(a, MapSet.new([b]), &MapSet.put(&1, b))
      |> Map.update(b, MapSet.new([a]), &MapSet.put(&1, a))
    end)
  end

  @doc """
  Returns a sorted list of neighbors for the given node, or `[]` if unknown.
  """
  def neighbors(graph, node) do
    case Map.get(graph, node) do
      nil -> []
      set -> set |> MapSet.to_list() |> Enum.sort()
    end
  end

  @doc """
  Finds the shortest path between `from` and `to` using BFS.

  Returns a list of nodes `[from, ..., to]`, or `nil` if disconnected.
  Returns `[from]` when `from == to`.
  """
  def shortest_path(_graph, from, to) when from == to, do: [from]

  def shortest_path(graph, from, to) do
    queue = :queue.from_list([{from, [from]}])
    visited = MapSet.new([from])
    bfs(graph, to, queue, visited)
  end

  defp bfs(graph, target, queue, visited) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, {current, path}}, rest} ->
        neighbors = Map.get(graph, current, MapSet.new())

        Enum.reduce_while(MapSet.to_list(neighbors), {rest, visited}, fn neighbor,
                                                                        {q, vis} ->
          if neighbor == target do
            {:halt, {:found, Enum.reverse([neighbor | Enum.reverse(path)])}}
          else
            if MapSet.member?(vis, neighbor) do
              {:cont, {q, vis}}
            else
              new_q = :queue.in({neighbor, path ++ [neighbor]}, q)
              {:cont, {new_q, MapSet.put(vis, neighbor)}}
            end
          end
        end)
        |> case do
          {:found, path} -> path
          {new_queue, new_visited} -> bfs(graph, target, new_queue, new_visited)
        end
    end
  end
end
