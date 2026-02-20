defmodule Alma.Environments.GraphWorld.Generator do
  @moduledoc """
  Procedural task generation for GraphWorld environments.

  Generates random but reproducible graph-based navigation tasks
  with configurable room count, object count, and connectivity.
  """

  @object_pool ~w(key book lamp gem scroll compass flask map coin ring
                  torch hammer shield potion dagger crystal lantern rope
                  goblet crown mirror bell horn feather puzzle box orb staff)

  @doc """
  Generates a single task configuration for GraphWorld.

  Config options:
  - `:rooms` - number of rooms (default: 5)
  - `:objects` - number of objects (default: 3)
  - `:connectivity` - probability of edge between rooms (default: 0.4)
  - `:seed` - random seed for reproducibility (default: 42)
  - `:family` - family seed for shared topology (default: nil).
    When set, topology is seeded by `:family` and placement by `:seed`,
    so tasks with the same family share room connectivity.
  """
  def generate_task(config \\ %{}) do
    rooms_count = Map.get(config, :rooms, 5)
    objects_count = Map.get(config, :objects, 3)
    connectivity = Map.get(config, :connectivity, 0.4)
    seed = Map.get(config, :seed, 42)
    family = Map.get(config, :family, nil)

    # Phase 1: topology — seeded by family (or seed if no family)
    topo_seed = family || seed
    :rand.seed(:exsss, {topo_seed, topo_seed, topo_seed})

    room_names = for i <- 0..(rooms_count - 1), do: "room_#{<<?A + i::utf8>>}"
    rooms = build_graph(room_names, connectivity)

    # Phase 2: placement — re-seed with variant seed when family is set
    if family, do: :rand.seed(:exsss, {seed, seed, seed})

    rooms = place_objects(rooms, room_names, objects_count)

    # Pick a random object and a different room as destination
    all_objects = rooms |> Map.values() |> Enum.flat_map(& &1.objects)
    goal_object = Enum.random(all_objects)

    goal_object_room =
      Enum.find(room_names, fn name -> goal_object in rooms[name].objects end)

    destination =
      room_names
      |> List.delete(goal_object_room)
      |> Enum.random()

    agent_location = Enum.random(room_names)

    %{
      rooms: rooms,
      agent_location: agent_location,
      goal: %{object: goal_object, destination: destination}
    }
  end

  @doc """
  Generates a batch of tasks with sequential seeds.
  """
  def generate_batch(count, config \\ %{}) do
    base_seed = Map.get(config, :seed, 42)

    for i <- 0..(count - 1) do
      generate_task(Map.put(config, :seed, base_seed + i))
    end
  end

  @doc """
  Generates a batch where all tasks share the same family topology.

  Uses `:family` from config (or `:seed` as fallback) for the shared topology,
  and increments `:seed` for each task's object/goal/agent placement.
  """
  def generate_family_batch(count, config \\ %{}) do
    family = Map.get(config, :family) || Map.get(config, :seed, 42)
    base_seed = Map.get(config, :seed, 42)

    for i <- 0..(count - 1) do
      generate_task(config |> Map.put(:family, family) |> Map.put(:seed, base_seed + i))
    end
  end

  defp build_graph(room_names, connectivity) do
    # Start with no edges
    rooms = Map.new(room_names, fn name -> {name, %{adjacent: [], objects: []}} end)

    # Add edges based on connectivity probability
    pairs = for a <- room_names, b <- room_names, a < b, do: {a, b}

    rooms =
      Enum.reduce(pairs, rooms, fn {a, b}, acc ->
        if :rand.uniform() < connectivity do
          acc
          |> Map.update!(a, fn r -> %{r | adjacent: [b | r.adjacent]} end)
          |> Map.update!(b, fn r -> %{r | adjacent: [a | r.adjacent]} end)
        else
          acc
        end
      end)

    ensure_connected(rooms, room_names)
  end

  defp ensure_connected(rooms, room_names) do
    # BFS to find connected component from first room
    start = hd(room_names)
    visited = bfs(rooms, [start], MapSet.new([start]))

    if MapSet.size(visited) == length(room_names) do
      rooms
    else
      # Add edges to connect isolated nodes
      unvisited = Enum.reject(room_names, &MapSet.member?(visited, &1))

      Enum.reduce(unvisited, rooms, fn node, acc ->
        # Connect to a random visited node
        target = visited |> MapSet.to_list() |> Enum.random()

        acc
        |> Map.update!(node, fn r -> %{r | adjacent: [target | r.adjacent]} end)
        |> Map.update!(target, fn r -> %{r | adjacent: [node | r.adjacent]} end)
      end)
    end
  end

  defp bfs(_rooms, [], visited), do: visited

  defp bfs(rooms, [current | rest], visited) do
    neighbors = rooms[current].adjacent

    new_neighbors =
      Enum.reject(neighbors, &MapSet.member?(visited, &1))

    bfs(
      rooms,
      rest ++ new_neighbors,
      Enum.reduce(new_neighbors, visited, &MapSet.put(&2, &1))
    )
  end

  defp place_objects(rooms, room_names, objects_count) do
    objects = Enum.take(Enum.shuffle(@object_pool), objects_count)

    Enum.reduce(objects, rooms, fn object, acc ->
      room = Enum.random(room_names)
      Map.update!(acc, room, fn r -> %{r | objects: [object | r.objects]} end)
    end)
  end
end
