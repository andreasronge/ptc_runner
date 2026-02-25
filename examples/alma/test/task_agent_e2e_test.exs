defmodule Alma.TaskAgentE2ETest do
  @moduledoc """
  End-to-end test for TaskAgent with the refactored environment option.

  Requires an LLM API key. Run with:

      mix test --include e2e
  """
  use ExUnit.Case

  alias Alma.TaskAgent
  alias Alma.Environments.GraphWorld

  @tag :e2e
  test "TaskAgent.run with environment: GraphWorld completes a task" do
    llm = LLMClient.callback("bedrock:haiku")

    task_config =
      GraphWorld.generate_tasks(1, %{rooms: 4, objects: 2, connectivity: 0.5, seed: 99})
      |> hd()

    result = TaskAgent.run(task_config, "", llm: llm, environment: GraphWorld)

    assert is_map(result)
    assert is_boolean(result.success?)
    assert is_list(result.actions)
    assert is_integer(result.steps)
    assert is_list(result.observation_log)
    assert length(result.actions) > 0, "Agent should have taken at least one action"
  end

  @tag :e2e
  test "TaskAgent.run with recall knowledge flows through" do
    llm = LLMClient.callback("bedrock:haiku")

    task_config = %{
      rooms: %{
        "room_A" => %{adjacent: ["room_B"], objects: ["key"]},
        "room_B" => %{adjacent: ["room_A"], objects: []}
      },
      agent_location: "room_A",
      goal: %{object: "key", destination: "room_B"}
    }

    knowledge = "The key is in room_A. Pick it up and deliver to room_B."
    result = TaskAgent.run(task_config, knowledge, llm: llm, environment: GraphWorld)

    assert is_map(result)
    assert is_boolean(result.success?)
    # With clear knowledge, the agent should succeed on this simple task
    assert result.success?, "Agent should succeed with direct knowledge on a 2-room task"
  end

  @tag :e2e
  test "MemoryHarness.evaluate_collection passes environment through" do
    llm = LLMClient.callback("bedrock:haiku")

    tasks =
      GraphWorld.generate_tasks(2, %{rooms: 4, objects: 2, connectivity: 0.5, seed: 77})

    design = Alma.MemoryHarness.null_design()

    {results, _memory, _errors} =
      Alma.MemoryHarness.evaluate_collection(design, tasks,
        llm: llm,
        environment: GraphWorld
      )

    assert length(results) == 2

    for result <- results do
      assert is_boolean(result.success?)
      assert is_list(result.actions)
    end
  end
end
