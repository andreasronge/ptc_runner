defmodule PtcRunner.SubAgent.LoopAutoReturnTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  describe "completion_mode: :auto" do
    test "no println auto-returns last expression" do
      agent =
        SubAgent.new(
          prompt: "Calculate something",
          tools: %{},
          max_turns: 5,
          completion_mode: :auto
        )

      llm = fn _ ->
        {:ok, "```clojure\n42\n```"}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == 42
      assert length(step.turns) == 1
    end

    test "println causes continuation, no println on next turn auto-returns" do
      agent =
        SubAgent.new(
          prompt: "Explore then answer",
          tools: %{},
          max_turns: 5,
          completion_mode: :auto
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(println \"exploring\")\n```"}
          2 -> {:ok, "```clojure\n42\n```"}
          _ -> {:ok, "```clojure\n99\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == 42
      assert length(step.turns) == 2
    end

    test "explicit return still works with auto mode" do
      agent =
        SubAgent.new(
          prompt: "Return explicitly",
          tools: %{},
          max_turns: 5,
          completion_mode: :auto
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:result 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert length(step.turns) == 1
    end

    test "explicit fail still works with auto mode" do
      agent =
        SubAgent.new(
          prompt: "Fail explicitly",
          tools: %{},
          max_turns: 5,
          completion_mode: :auto
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
(fail "nope")
```|}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail != nil
    end

    test "signature validation failure continues loop" do
      agent =
        SubAgent.new(
          prompt: "Return wrong type",
          tools: %{},
          max_turns: 3,
          completion_mode: :auto,
          signature: "() -> :int"
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, ~S|```clojure
"not an int"
```|}
          _ -> {:ok, "```clojure\n42\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == 42
      assert length(step.turns) == 2
    end

    test "map return value with auto-return" do
      agent =
        SubAgent.new(
          prompt: "Return a map",
          tools: %{},
          max_turns: 5,
          completion_mode: :auto
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
{:answer 42 :status "done"}
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"answer" => 42, "status" => "done"}
      assert length(step.turns) == 1
    end
  end

  describe "auto-return disabled when plan is present" do
    test "plan agents use explicit return, auto-return does not fire" do
      agent =
        SubAgent.new(
          prompt: "Do steps",
          tools: %{},
          max_turns: 3,
          completion_mode: :auto,
          plan: ["Step one", "Step two"]
        )

      # Turn 1: no println, but plan present → should NOT auto-return, continues
      # Turn 2: explicit return → stops
      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n42\n```"}
          2 -> {:ok, "```clojure\n(return 99)\n```"}
          _ -> {:ok, "```clojure\n0\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # Should NOT have stopped at turn 1 (plan disables auto-return)
      assert length(step.turns) == 2
      assert step.return == 99
    end
  end

  describe "completion_mode: :explicit (default) preserves old behavior" do
    test "no println does not auto-return, loop continues" do
      agent = test_agent(max_turns: 3)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n42\n```"}
          2 -> {:ok, "```clojure\n(return {:result 99})\n```"}
          _ -> {:ok, "```clojure\n0\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # With explicit mode, turn 1 should continue (no auto-return)
      # and turn 2 should return via explicit return
      assert step.return == %{"result" => 99}
      assert length(step.turns) == 2
    end
  end
end
