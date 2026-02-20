defmodule Alma.AnalysisTest do
  use ExUnit.Case, async: true

  alias Alma.Analysis
  alias Alma.Environments.GraphWorld

  @goal %{object: "key", destination: "room_C"}

  defp make_result(attrs) do
    Map.merge(
      %{
        success?: false,
        actions: [],
        steps: 0,
        observation_log: [],
        recall_advice: ""
      },
      attrs
    )
  end

  defp make_task(attrs \\ %{}) do
    Map.merge(%{goal: @goal, rooms: %{}, agent_location: "room_A"}, attrs)
  end

  describe "analyze_results/3" do
    test "returns zeroes for empty results" do
      analysis = Analysis.analyze_results([], [], GraphWorld)

      assert analysis.success_rate == 0.0
      assert analysis.avg_steps == 0.0
      assert analysis.recall_provided == 0.0
      assert analysis.avg_recall_length == 0.0
      assert analysis.unique_states == 0.0
      assert analysis.avg_discoveries == 0.0
    end

    test "computes metrics from mixed success/failure results" do
      results = [
        make_result(%{
          success?: true,
          steps: 4,
          recall_advice: "go to room_B for the key",
          observation_log: [
            %{action: "look", result: %{location: "room_A", objects: []}},
            %{action: "look", result: %{location: "room_B", objects: ["key"]}},
            %{action: "move_to", result: %{ok: true, message: "Moved to room_C"}}
          ]
        }),
        make_result(%{
          success?: false,
          steps: 8,
          recall_advice: "",
          observation_log: [
            %{action: "look", result: %{location: "room_A", objects: []}},
            %{action: "look", result: %{location: "room_A", objects: []}},
            %{action: "look", result: %{location: "room_B", objects: []}},
            %{action: "move_to", result: %{ok: true, message: "Moved to room_C"}},
            %{action: "move_to", result: %{ok: true, message: "Moved to room_A"}}
          ]
        })
      ]

      tasks = [make_task(), make_task()]
      analysis = Analysis.analyze_results(results, tasks, GraphWorld)

      assert analysis.success_rate == 0.5
      assert analysis.avg_steps == 6.0
      # First result has recall, second doesn't
      assert analysis.recall_provided == 0.5
      assert analysis.avg_recall_length == String.length("go to room_B for the key") / 2
      # First result: room_A, room_B = 2 unique. Second: room_A, room_B = 2 unique. Avg = 2.0
      assert analysis.unique_states == 2.0
      # First result: found key in room_B = 1 discovery. Second: 0. Avg = 0.5
      assert analysis.avg_discoveries == 0.5
    end

    test "results with no recall advice show recall_provided 0.0" do
      results = [
        make_result(%{
          success?: true,
          steps: 3,
          recall_advice: "",
          observation_log: [
            %{action: "look", result: %{location: "room_A", objects: []}},
            %{action: "move_to", result: %{ok: true, message: "Moved to room_B"}},
            %{action: "put_down", result: %{ok: true, message: "Put down key"}}
          ]
        })
      ]

      analysis = Analysis.analyze_results(results, [make_task()], GraphWorld)
      assert analysis.recall_provided == 0.0
      assert analysis.avg_recall_length == 0.0
    end
  end

  describe "compress_trajectories/3" do
    test "returns empty list for empty results" do
      assert Analysis.compress_trajectories([], [], GraphWorld) == []
    end

    test "produces readable output for a success episode" do
      results = [
        make_result(%{
          success?: true,
          steps: 4,
          recall_advice: "explore systematically",
          observation_log: [
            %{action: "look", result: %{location: "room_A", objects: []}},
            %{action: "look", result: %{location: "room_B", objects: ["key"]}},
            %{action: "pick_up", result: %{ok: true, message: "Picked up key"}},
            %{action: "move_to", result: %{ok: true, message: "Moved to room_C"}}
          ]
        })
      ]

      tasks = [make_task()]
      [episode] = Analysis.compress_trajectories(results, tasks, GraphWorld)

      assert episode =~ "SUCCESS"
      assert episode =~ "4 steps"
      assert episode =~ "Place key in room_C"
      assert episode =~ "explore systematically"
      assert episode =~ "★ look(room_B) [found key!]"
      assert episode =~ "pick_up(key)"
      assert episode =~ "move_to(room_C)"
    end

    test "selects best success and worst failure" do
      results = [
        make_result(%{success?: true, steps: 8, observation_log: []}),
        make_result(%{success?: true, steps: 3, observation_log: []}),
        make_result(%{success?: false, steps: 5, observation_log: []}),
        make_result(%{success?: false, steps: 12, observation_log: []})
      ]

      tasks = Enum.map(1..4, fn _ -> make_task() end)
      episodes = Analysis.compress_trajectories(results, tasks, GraphWorld)

      assert length(episodes) == 2
      assert Enum.at(episodes, 0) =~ "SUCCESS, 3 steps"
      assert Enum.at(episodes, 1) =~ "FAILED, 12 steps"
    end

    test "respects max_episodes option" do
      results = [
        make_result(%{success?: true, steps: 3, observation_log: []}),
        make_result(%{success?: false, steps: 12, observation_log: []}),
        make_result(%{success?: true, steps: 5, observation_log: []})
      ]

      tasks = Enum.map(1..3, fn _ -> make_task() end)
      episodes = Analysis.compress_trajectories(results, tasks, GraphWorld, max_episodes: 1)
      assert length(episodes) == 1
    end
  end

  describe "collapse_loops/1" do
    test "collapses consecutive repeated single actions" do
      actions = ["move_to(A)", "move_to(A)", "move_to(A)", "look(B)"]
      result = Analysis.collapse_loops(actions)
      assert result == ["[loop x3: move_to(A)]", "look(B)"]
    end

    test "collapses consecutive repeated subsequences" do
      actions = [
        "move_to(A)",
        "move_to(B)",
        "move_to(A)",
        "move_to(B)",
        "look(C)"
      ]

      result = Analysis.collapse_loops(actions)
      assert result == ["[loop x2: move_to(A) → move_to(B)]", "look(C)"]
    end

    test "leaves non-repeating actions unchanged" do
      actions = ["look(A)", "move_to(B)", "pick_up(key)"]
      assert Analysis.collapse_loops(actions) == actions
    end
  end

  describe "truncation" do
    test "long traces are truncated to first 10 + omitted + last 3" do
      obs_log =
        Enum.map(1..20, fn i ->
          %{action: "move_to", result: %{ok: true, message: "Moved to room_#{i}"}}
        end)

      results = [make_result(%{success?: false, steps: 20, observation_log: obs_log})]
      tasks = [make_task()]
      [episode] = Analysis.compress_trajectories(results, tasks, GraphWorld)

      assert episode =~ "steps omitted"
    end
  end

  describe "environment-provided summaries" do
    test "GraphWorld summarize_observation extracts location as state_identifier" do
      obs = %{action: "look", result: %{location: "room_X", objects: []}}
      summary = GraphWorld.summarize_observation(obs, @goal)

      assert summary.action_summary == "look(room_X)"
      assert summary.state_identifier == "room_X"
      assert summary.discovery == nil
    end

    test "GraphWorld summarize_observation detects goal object discovery" do
      obs = %{action: "look", result: %{location: "room_B", objects: ["key", "lamp"]}}
      summary = GraphWorld.summarize_observation(obs, @goal)

      assert summary.discovery == "found key!"
    end

    test "GraphWorld summarize_observation for move_to" do
      obs = %{action: "move_to", result: %{ok: true, message: "Moved to room_C"}}
      summary = GraphWorld.summarize_observation(obs, @goal)

      assert summary.action_summary == "move_to(room_C)"
      assert summary.state_identifier == nil
    end

    test "GraphWorld format_goal returns readable string" do
      assert GraphWorld.format_goal(@goal) == "Place key in room_C"
    end
  end
end
