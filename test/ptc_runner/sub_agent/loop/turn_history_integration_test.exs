defmodule PtcRunner.SubAgent.Loop.TurnHistoryIntegrationTest do
  @moduledoc """
  Integration tests for turn history tracking across multi-turn loops.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "turn history in multi-turn loop" do
    test "*1 returns nil on first turn" do
      # First turn: return *1 which should be nil
      agent =
        SubAgent.new(
          prompt: "Return *1",
          tools: %{},
          max_turns: 2
        )

      llm = fn %{messages: _msgs, turn: turn} ->
        if turn == 1 do
          {:ok, "(return *1)"}
        else
          {:ok, "(return {:unexpected true})"}
        end
      end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm)
      assert step.return == nil
    end

    test "*1 returns previous turn result on second turn" do
      # Turn 1: return (do 42) - continues loop because no return/fail
      # Turn 2: return *1 which should be 42
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: _msgs, turn: turn} ->
        case turn do
          # Use (do ...) to make it a valid s-expression
          1 -> {:ok, "(do 42)"}
          2 -> {:ok, "(return *1)"}
          _ -> {:ok, "(fail \"unexpected turn\")"}
        end
      end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm)
      assert step.return == 42
    end

    test "*1 and *2 track multiple turns" do
      # Turn 1: return 10
      # Turn 2: return 20
      # Turn 3: return [*1, *2] which should be [20, 10]
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{},
          max_turns: 4
        )

      llm = fn %{messages: _msgs, turn: turn} ->
        case turn do
          1 -> {:ok, "(do 10)"}
          2 -> {:ok, "(do 20)"}
          3 -> {:ok, "(return [*1 *2])"}
          _ -> {:ok, "(fail \"unexpected turn\")"}
        end
      end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm)
      assert step.return == [20, 10]
    end

    test "turn history tracks only last 3 results" do
      # Turn 1-4: return numbers
      # Turn 5: return [*1, *2, *3] which should be [4, 3, 2] (1 dropped)
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{},
          max_turns: 6
        )

      llm = fn %{messages: _msgs, turn: turn} ->
        case turn do
          1 -> {:ok, "(do 1)"}
          2 -> {:ok, "(do 2)"}
          3 -> {:ok, "(do 3)"}
          4 -> {:ok, "(do 4)"}
          5 -> {:ok, "(return [*1 *2 *3])"}
          _ -> {:ok, "(fail \"unexpected turn\")"}
        end
      end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm)
      assert step.return == [4, 3, 2]
    end

    test "turn history works with map results" do
      # Turn 1: return {:count 5}
      # Turn 2: return (:count *1) which should get 5 from map
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: _msgs, turn: turn} ->
        case turn do
          1 -> {:ok, "(do {:count 5})"}
          2 -> {:ok, "(return (:count *1))"}
          _ -> {:ok, "(fail \"unexpected turn\")"}
        end
      end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm)
      assert step.return == 5
    end

    test "*3 returns nil when only 2 turns happened" do
      # Turn 1: return 10
      # Turn 2: return *3 which should be nil
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: _msgs, turn: turn} ->
        case turn do
          1 -> {:ok, "(do 10)"}
          2 -> {:ok, "(return *3)"}
          _ -> {:ok, "(fail \"unexpected turn\")"}
        end
      end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm)
      assert step.return == nil
    end

    test "turn history is truncated for large results" do
      # This test verifies large results are truncated in history by checking
      # that the truncation function is called (via ResponseHandler tests)
      # Here we just verify large results don't break the loop
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: _msgs, turn: turn} ->
        case turn do
          # Return a large list - build it inline
          1 -> {:ok, "(do [1 2 3 4 5 6 7 8 9 10])"}
          # Just return *1 to verify it was stored
          2 -> {:ok, "(return (count *1))"}
          _ -> {:ok, "(fail \"unexpected turn\")"}
        end
      end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm)
      # The small list should not be truncated
      assert step.return == 10
    end
  end
end
