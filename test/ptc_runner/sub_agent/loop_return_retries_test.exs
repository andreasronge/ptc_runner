defmodule PtcRunner.SubAgent.LoopReturnRetriesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  describe "return_retries option" do
    test "return_retries: 0 (default) uses only work turns" do
      agent =
        SubAgent.new(
          prompt: "Return a value",
          max_turns: 2
        )

      assert agent.return_retries == 0

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :should-not-reach)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert length(step.turns) == 2
      assert step.usage.turns == 2
    end

    test "return_retries gives extra turns after validation failure" do
      agent =
        SubAgent.new(
          prompt: "Return a float",
          signature: "{value :float}",
          max_turns: 2,
          return_retries: 2
        )

      assert agent.return_retries == 2

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          # Turn 1: normal work turn
          1 ->
            {:ok, "```clojure\n(println \"working...\")\n:exploring\n```"}

          # Turn 2: must-return turn (last work turn)
          2 ->
            {:ok, "```clojure\n(return {:value 0})\n```"}

          # Turn 3: retry turn (validation failed, integer instead of float)
          3 ->
            # Should have error feedback about validation
            last_msg = List.last(messages)
            assert last_msg.content =~ "expected float"
            {:ok, "```clojure\n(return {:value 1.0})\n```"}

          _ ->
            {:ok, "```clojure\n(return {:value 0.0})\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 1.0}
      assert length(step.turns) == 3
    end

    test "tools are stripped in must-return mode" do
      tools = %{
        "get-value" => fn _ -> 42 end
      }

      agent =
        SubAgent.new(
          prompt: "Get value and return",
          tools: tools,
          max_turns: 2,
          return_retries: 1
        )

      llm = fn %{turn: turn, tool_names: tool_names} ->
        case turn do
          1 ->
            # Turn 1: normal - tools available
            assert "get-value" in tool_names
            {:ok, "```clojure\n(tool/get-value {})\n```"}

          2 ->
            # Turn 2: must-return - tools stripped
            assert tool_names == []
            {:ok, "```clojure\n(return {:value 42})\n```"}

          _ ->
            {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 42}
    end

    test "retry turns have tools stripped" do
      tools = %{
        "helper" => fn _ -> "help" end
      }

      agent =
        SubAgent.new(
          prompt: "Return a float",
          signature: "{value :float}",
          tools: tools,
          max_turns: 1,
          return_retries: 2
        )

      llm = fn %{turn: turn, tool_names: tool_names} ->
        case turn do
          # Turn 1: must-return (only 1 work turn) - tools stripped
          1 ->
            assert tool_names == []
            {:ok, "```clojure\n(return {:value 0})\n```"}

          # Turn 2: retry - still no tools
          2 ->
            assert tool_names == []
            {:ok, "```clojure\n(return {:value 1.0})\n```"}

          _ ->
            {:ok, "```clojure\n(return {:value 0.0})\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 1.0}
    end

    test "explicit fail bypasses retry mechanism" do
      agent =
        SubAgent.new(
          prompt: "Maybe fail",
          max_turns: 1,
          return_retries: 2
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            # Explicit fail should NOT use retry turns
            {:ok, "```clojure\n(fail {:reason :intentional})\n```"}

          _ ->
            {:ok, "```clojure\n(return :should-not-reach)\n```"}
        end
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :failed
      # Only 1 turn consumed (no retries attempted)
      assert length(step.turns) == 1
    end

    test "budget exhausted when both work and retry turns consumed" do
      agent =
        SubAgent.new(
          prompt: "Return a float",
          signature: "{value :float}",
          max_turns: 1,
          return_retries: 1
        )

      llm = fn _ ->
        # Always return wrong type to exhaust budget
        {:ok, "```clojure\n(return {:value 0})\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :budget_exhausted
      # 1 work turn + 1 retry turn = 2 turns
      assert length(step.turns) == 2
    end

    test "turn types are set correctly" do
      agent =
        SubAgent.new(
          prompt: "Return a float",
          signature: "{value :float}",
          max_turns: 2,
          return_retries: 1
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:value 0})\n```"}
          3 -> {:ok, "```clojure\n(return {:value 1.0})\n```"}
          _ -> {:ok, "```clojure\n(return {:value 0.0})\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert length(step.turns) == 3
      [turn1, turn2, turn3] = step.turns

      # Turn 1: normal work turn
      assert turn1.type == :normal
      # Turn 2: must-return (last work turn)
      assert turn2.type == :must_return
      # Turn 3: retry turn
      assert turn3.type == :retry
    end

    test "feedback shows unified budget info" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn with retries",
          max_turns: 3,
          return_retries: 2
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            {:ok, "```clojure\n(+ 1 2)\n```"}

          2 ->
            # After turn 1, should show work/retry budget info
            last_msg = List.last(messages)
            assert last_msg.content =~ "work turns"
            {:ok, "```clojure\n(return {:done true})\n```"}

          _ ->
            {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"done" => true}
    end

    test "early return failure consumes work turn, not retry turn" do
      # Per spec (docs/specs/return-retries.md lines 87-99):
      # If LLM calls (return ...) before the final turn and it fails validation,
      # consume a work turn, not a retry turn.
      agent =
        SubAgent.new(
          prompt: "Return a valid integer",
          signature: "{x :int}",
          max_turns: 5,
          return_retries: 1
        )

      llm = fn %{turn: turn} ->
        case turn do
          # Turn 1: Early return fails - should consume work turn
          1 -> {:ok, "```clojure\n(return {:x \"bad\"})\n```"}
          # Turn 2: Valid return
          2 -> {:ok, "```clojure\n(return {:x 42})\n```"}
          _ -> flunk("unexpected turn")
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"x" => 42}
      assert length(step.turns) == 2

      # Both should be :normal turns (not :retry) because work budget was used
      [turn1, turn2] = step.turns
      assert turn1.type == :normal
      assert turn2.type == :normal
    end
  end
end
