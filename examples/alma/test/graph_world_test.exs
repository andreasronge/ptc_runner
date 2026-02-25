defmodule Alma.Environments.GraphWorldTest do
  use ExUnit.Case, async: true

  alias Alma.Environments.GraphWorld
  alias Alma.Environments.GraphWorld.Generator

  describe "reset/1" do
    test "initializes state from config" do
      config = %{
        rooms: %{
          "room_A" => %{adjacent: ["room_B"], objects: ["key"]},
          "room_B" => %{adjacent: ["room_A"], objects: []}
        },
        agent_location: "room_A",
        goal: %{object: "key", destination: "room_B"}
      }

      state = GraphWorld.reset(config)

      assert state.agent_location == "room_A"
      assert state.inventory == []
      assert state.steps == 0
      assert state.max_steps == 20
      assert state.goal == %{object: "key", destination: "room_B"}
    end
  end

  describe "step/2" do
    setup do
      config = %{
        rooms: %{
          "room_A" => %{adjacent: ["room_B"], objects: ["key"]},
          "room_B" => %{adjacent: ["room_A", "room_C"], objects: []},
          "room_C" => %{adjacent: ["room_B"], objects: []}
        },
        agent_location: "room_A",
        goal: %{object: "key", destination: "room_C"}
      }

      %{state: GraphWorld.reset(config)}
    end

    test "move_to adjacent room succeeds", %{state: state} do
      {result, new_state} = GraphWorld.step(state, {:move_to, "room_B"})

      assert result.ok == true
      assert new_state.agent_location == "room_B"
      assert new_state.steps == 1
    end

    test "move_to non-adjacent room fails", %{state: state} do
      {result, new_state} = GraphWorld.step(state, {:move_to, "room_C"})

      assert result.ok == false
      assert new_state.agent_location == "room_A"
    end

    test "pick_up object in current room", %{state: state} do
      {result, new_state} = GraphWorld.step(state, {:pick_up, "key"})

      assert result.ok == true
      assert "key" in new_state.inventory
      assert "key" not in new_state.rooms["room_A"].objects
    end

    test "pick_up object not in room fails", %{state: state} do
      {result, _state} = GraphWorld.step(state, {:pick_up, "gem"})
      assert result.ok == false
    end

    test "put_down object from inventory", %{state: state} do
      {_result, state} = GraphWorld.step(state, {:pick_up, "key"})
      {_result, state} = GraphWorld.step(state, {:move_to, "room_B"})
      {result, state} = GraphWorld.step(state, {:put_down, "key"})

      assert result.ok == true
      assert "key" in state.rooms["room_B"].objects
      assert "key" not in state.inventory
    end

    test "put_down object not in inventory fails", %{state: state} do
      {result, _state} = GraphWorld.step(state, {:put_down, "key"})
      assert result.ok == false
    end

    test "exceeding max_steps fails", %{state: state} do
      state = %{state | steps: 20}
      {result, _state} = GraphWorld.step(state, {:move_to, "room_B"})
      assert result.ok == false
      assert result.message =~ "Max steps"
    end
  end

  describe "observe/1" do
    test "returns current room state" do
      state =
        GraphWorld.reset(%{
          rooms: %{
            "room_A" => %{adjacent: ["room_B"], objects: ["key"]},
            "room_B" => %{adjacent: ["room_A"], objects: []}
          },
          agent_location: "room_A",
          goal: %{object: "key", destination: "room_B"}
        })

      obs = GraphWorld.observe(state)

      assert obs.location == "room_A"
      assert obs.exits == ["room_B"]
      assert obs.objects == ["key"]
      assert obs.inventory == []
      assert obs.goal =~ "key"
      assert obs.goal =~ "room_B"
    end
  end

  describe "success?/1" do
    test "returns true when goal object is at destination" do
      state =
        GraphWorld.reset(%{
          rooms: %{
            "room_A" => %{adjacent: ["room_B"], objects: []},
            "room_B" => %{adjacent: ["room_A"], objects: ["key"]}
          },
          agent_location: "room_A",
          goal: %{object: "key", destination: "room_B"}
        })

      assert GraphWorld.success?(state)
    end

    test "returns false when goal object is elsewhere" do
      state =
        GraphWorld.reset(%{
          rooms: %{
            "room_A" => %{adjacent: ["room_B"], objects: ["key"]},
            "room_B" => %{adjacent: ["room_A"], objects: []}
          },
          agent_location: "room_A",
          goal: %{object: "key", destination: "room_B"}
        })

      refute GraphWorld.success?(state)
    end
  end

  describe "full task solve" do
    test "agent picks up object and delivers to goal" do
      state =
        GraphWorld.reset(%{
          rooms: %{
            "room_A" => %{adjacent: ["room_B"], objects: ["key"]},
            "room_B" => %{adjacent: ["room_A"], objects: []}
          },
          agent_location: "room_A",
          goal: %{object: "key", destination: "room_B"}
        })

      refute GraphWorld.success?(state)

      {_, state} = GraphWorld.step(state, {:pick_up, "key"})
      {_, state} = GraphWorld.step(state, {:move_to, "room_B"})
      {_, state} = GraphWorld.step(state, {:put_down, "key"})

      assert GraphWorld.success?(state)
      assert state.steps == 3
    end
  end

  describe "Generator" do
    test "generate_task is reproducible with same seed" do
      task1 = Generator.generate_task(%{seed: 42})
      task2 = Generator.generate_task(%{seed: 42})

      assert task1 == task2
    end

    test "generate_task creates correct number of rooms" do
      task = Generator.generate_task(%{rooms: 4, seed: 1})
      assert map_size(task.rooms) == 4
    end

    test "generate_task creates correct number of objects" do
      task = Generator.generate_task(%{rooms: 5, objects: 3, seed: 1})
      all_objects = task.rooms |> Map.values() |> Enum.flat_map(& &1.objects)
      assert length(all_objects) == 3
    end

    test "generate_task uses meaningful object names" do
      task = Generator.generate_task(%{rooms: 5, objects: 3, seed: 1})
      all_objects = task.rooms |> Map.values() |> Enum.flat_map(& &1.objects)

      for obj <- all_objects do
        refute String.starts_with?(obj, "item_"), "expected meaningful name, got #{obj}"
      end
    end

    test "generated graph is connected" do
      task = Generator.generate_task(%{rooms: 8, connectivity: 0.2, seed: 7})

      # BFS from first room should reach all rooms
      start = task.agent_location
      visited = bfs(task.rooms, [start], MapSet.new([start]))
      assert MapSet.size(visited) == map_size(task.rooms)
    end

    test "generate_batch creates correct number of tasks" do
      tasks = Generator.generate_batch(5, %{seed: 10})
      assert length(tasks) == 5
    end

    test "generate_batch creates different tasks" do
      tasks = Generator.generate_batch(3, %{seed: 10})
      # Different seeds should produce different tasks (at least in some aspect)
      assert length(Enum.uniq(tasks)) > 1
    end

    test "same family, different seeds share topology" do
      t1 = Generator.generate_task(%{family: 1, seed: 10, rooms: 6})
      t2 = Generator.generate_task(%{family: 1, seed: 20, rooms: 6})

      # Same room adjacency
      for room_name <- Map.keys(t1.rooms) do
        assert Enum.sort(t1.rooms[room_name].adjacent) ==
                 Enum.sort(t2.rooms[room_name].adjacent),
               "Room #{room_name} adjacency differs"
      end

      # Different placement (objects, goal, or agent location)
      all_objects_1 = t1.rooms |> Map.values() |> Enum.flat_map(& &1.objects) |> Enum.sort()
      all_objects_2 = t2.rooms |> Map.values() |> Enum.flat_map(& &1.objects) |> Enum.sort()

      placement_differs =
        all_objects_1 != all_objects_2 ||
          t1.goal != t2.goal ||
          t1.agent_location != t2.agent_location

      assert placement_differs, "Expected different placement with different seeds"
    end

    test "different families produce different topologies" do
      t1 = Generator.generate_task(%{family: 1, seed: 10, rooms: 6})
      t2 = Generator.generate_task(%{family: 2, seed: 10, rooms: 6})

      adj1 =
        Map.new(t1.rooms, fn {k, v} -> {k, Enum.sort(v.adjacent)} end)

      adj2 =
        Map.new(t2.rooms, fn {k, v} -> {k, Enum.sort(v.adjacent)} end)

      assert adj1 != adj2, "Expected different topologies for different families"
    end

    test "no family is backward compatible" do
      task_no_family = Generator.generate_task(%{seed: 42, rooms: 5})
      task_nil_family = Generator.generate_task(%{seed: 42, rooms: 5, family: nil})

      assert task_no_family == task_nil_family
    end

    test "generate_family_batch shares topology" do
      tasks = Generator.generate_family_batch(4, %{family: 7, seed: 100, rooms: 6})

      assert length(tasks) == 4

      # All tasks should have identical adjacency
      [first | rest] = tasks

      reference_adj =
        Map.new(first.rooms, fn {k, v} -> {k, Enum.sort(v.adjacent)} end)

      for task <- rest do
        adj = Map.new(task.rooms, fn {k, v} -> {k, Enum.sort(v.adjacent)} end)
        assert adj == reference_adj
      end

      # But not all tasks should be identical (different placement)
      assert length(Enum.uniq(tasks)) > 1
    end
  end

  describe "Environment callbacks" do
    test "task_prompt returns a non-empty string" do
      prompt = GraphWorld.task_prompt()
      assert is_binary(prompt)
      assert String.length(prompt) > 10
      assert String.contains?(prompt, "{{goal}}")
    end

    test "task_tools returns a map with expected tool names" do
      {:ok, agent_pid} = Agent.start_link(fn -> %{} end)

      try do
        tools = GraphWorld.task_tools(agent_pid, "some advice")
        assert is_map(tools)
        assert Map.has_key?(tools, "look")
        assert Map.has_key?(tools, "move_to")
        assert Map.has_key?(tools, "pick_up")
        assert Map.has_key?(tools, "put_down")
        assert Map.has_key?(tools, "recall")
      after
        Agent.stop(agent_pid)
      end
    end

    test "generate_tasks delegates to Generator" do
      tasks = GraphWorld.generate_tasks(3, %{seed: 42, rooms: 5, objects: 3, connectivity: 0.3})
      assert length(tasks) == 3
      # Verify they're proper task configs
      for task <- tasks do
        assert is_map(task.rooms)
        assert is_binary(task.agent_location)
        assert is_map(task.goal)
      end
    end

    test "generate_family_tasks delegates to Generator" do
      tasks =
        GraphWorld.generate_family_tasks(3, %{
          family: 1,
          seed: 42,
          rooms: 5,
          objects: 3,
          connectivity: 0.3
        })

      assert length(tasks) == 3
    end

    test "seed_design_source returns valid PTC-Lisp source" do
      source = GraphWorld.seed_design_source()
      assert is_binary(source)
      assert String.contains?(source, "mem-update")
      assert String.contains?(source, "recall")

      # Verify it compiles
      assert {:ok, _step} = PtcRunner.Lisp.run(source)
    end

    test "seed_environment compiles GraphWorld baseline into archive" do
      archive =
        Alma.Archive.new()
        |> Alma.Archive.seed_null()
        |> Alma.Archive.seed_environment(GraphWorld)

      assert length(archive.entries) == 2
      seed_entry = Enum.at(archive.entries, 1)
      assert seed_entry.design.name == "spatial_baseline"
      assert is_tuple(seed_entry.design.mem_update)
      assert is_tuple(seed_entry.design.recall)
    end
  end

  defp bfs(_rooms, [], visited), do: visited

  defp bfs(rooms, [current | rest], visited) do
    neighbors = rooms[current].adjacent
    new = Enum.reject(neighbors, &MapSet.member?(visited, &1))
    bfs(rooms, rest ++ new, Enum.reduce(new, visited, &MapSet.put(&2, &1)))
  end
end
