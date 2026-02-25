defmodule Alma.Environments.ALFWorldTest do
  use ExUnit.Case, async: true

  alias Alma.Environments.ALFWorld

  describe "summarize_observation/2" do
    test "go to action" do
      obs = %{
        action: "go to desk 1",
        result: %{obs: "On the desk 1, you see a mug.", done: false}
      }

      summary = ALFWorld.summarize_observation(obs, %{goal: "put mug in shelf"})

      assert summary.action_summary == "go_to(desk 1)"
      assert summary.state_identifier == "desk 1"
      assert summary.discovery == nil
    end

    test "take action with success" do
      obs = %{
        action: "take mug 1 from desk 1",
        result: %{obs: "You pick up the mug 1 from the desk 1.", done: false}
      }

      summary = ALFWorld.summarize_observation(obs, %{goal: "put mug in shelf"})

      assert summary.action_summary == "take(mug 1)"
      assert summary.state_identifier == nil
      assert summary.discovery == "took mug 1"
    end

    test "take action with failure" do
      obs = %{
        action: "take mug 1 from desk 1",
        result: %{obs: "Nothing happens.", done: false}
      }

      summary = ALFWorld.summarize_observation(obs, %{goal: "put mug in shelf"})

      assert summary.action_summary == "take(mug 1)"
      assert summary.discovery == nil
    end

    test "put action" do
      obs = %{
        action: "put mug 1 in/on shelf 1",
        result: %{obs: "You put the mug 1 in/on the shelf 1.", done: true}
      }

      summary = ALFWorld.summarize_observation(obs, %{goal: "put mug in shelf"})

      assert summary.action_summary == "put(mug 1 in/on shelf 1)"
      assert summary.state_identifier == nil
    end

    test "open action with discovery" do
      obs = %{
        action: "open fridge 1",
        result: %{
          obs: "You open the fridge 1. The fridge 1 is open. In it, you see an egg 1.",
          done: false
        }
      }

      summary = ALFWorld.summarize_observation(obs, %{goal: "heat egg"})

      assert summary.action_summary == "open(fridge 1)"
      assert summary.discovery == "opened fridge 1"
    end

    test "recall action" do
      obs = %{action: "recall", result: %{}}
      summary = ALFWorld.summarize_observation(obs, %{goal: "any"})

      assert summary.action_summary == "recall"
    end

    test "unknown action" do
      obs = %{action: "examine painting", result: %{obs: "A nice painting.", done: false}}
      summary = ALFWorld.summarize_observation(obs, %{goal: "any"})

      assert summary.action_summary == "examine painting"
    end
  end

  describe "format_goal/1" do
    test "extracts goal from map with :goal key" do
      assert ALFWorld.format_goal(%{goal: "put mug on shelf"}) == "put mug on shelf"
    end

    test "returns string goal directly" do
      assert ALFWorld.format_goal("clean the mug") == "clean the mug"
    end
  end

  describe "context_schema/0" do
    test "returns expected shape" do
      schema = ALFWorld.context_schema()
      assert is_map(schema)
      assert Map.has_key?(schema, "mem_update")
      assert Map.has_key?(schema, "recall")
      assert Map.has_key?(schema["mem_update"], "data/task")
      assert Map.has_key?(schema["recall"], "data/task")
    end
  end

  describe "task_prompt/0" do
    test "returns prompt with goal placeholder" do
      prompt = ALFWorld.task_prompt()
      assert is_binary(prompt)
      assert String.contains?(prompt, "{{goal}}")
    end
  end

  describe "task_mode/0" do
    test "returns :text" do
      assert ALFWorld.task_mode() == :text
    end
  end

  describe "format_step_result/1" do
    test "formats observation map as text" do
      result = %{
        obs: "You are in the kitchen.",
        admissible_commands: ["go to fridge 1", "take mug 1"],
        done: false,
        score: 0
      }

      text = ALFWorld.format_step_result(result)
      assert String.contains?(text, "You are in the kitchen.")
      assert String.contains?(text, "- go to fridge 1")
      assert String.contains?(text, "- take mug 1")
      assert String.contains?(text, "Done: false")
    end
  end

  describe "parse_action/2" do
    test "exact match" do
      state = %{admissible_commands: ["go to desk 1", "take mug 1"]}
      assert ALFWorld.parse_action("go to desk 1", state) == "go to desk 1"
    end

    test "extracts command from longer response" do
      state = %{admissible_commands: ["go to desk 1", "take mug 1"]}
      assert ALFWorld.parse_action("I should go to desk 1 next", state) == "go to desk 1"
    end

    test "returns invalid tuple for unrecognized command" do
      state = %{admissible_commands: ["go to desk 1", "take mug 1"]}
      assert ALFWorld.parse_action("go to desk1", state) == {:invalid, "go to desk1"}
    end
  end

  describe "success?/1" do
    test "returns true when done and score > 0" do
      assert ALFWorld.success?(%{done: true, score: 1.0})
    end

    test "returns false when not done" do
      refute ALFWorld.success?(%{done: false, score: 0})
    end

    test "returns false when done but score is 0" do
      refute ALFWorld.success?(%{done: true, score: 0})
    end
  end

  describe "seed_design_source/0" do
    test "returns nil" do
      assert ALFWorld.seed_design_source() == nil
    end
  end
end
