defmodule PtcRunner.SubAgent.LoopTurnFeedbackTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  describe "turn feedback format" do
    test "shows correct turn number and remaining count" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            {:ok, "```clojure\n(+ 1 2)\n```"}

          2 ->
            # After turn 1, feedback should say "Turn 2 of 5 (4 remaining)"
            last_message = List.last(messages)
            assert last_message.content =~ "Turn 2 of 5 (4 remaining)"
            {:ok, "```clojure\n(+ 3 4)\n```"}

          3 ->
            # After turn 2, feedback should say "Turn 3 of 5 (3 remaining)"
            last_message = List.last(messages)
            assert last_message.content =~ "Turn 3 of 5 (3 remaining)"
            {:ok, "```clojure\n(return 42)\n```"}

          _ ->
            {:ok, "```clojure\n(return 99)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == 42
      assert step.usage.turns == 3
    end

    test "shows FINAL TURN warning on last turn" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            {:ok, "```clojure\n(+ 1 2)\n```"}

          2 ->
            {:ok, "```clojure\n(+ 3 4)\n```"}

          3 ->
            # After turn 2 with max_turns=3, should show FINAL TURN warning
            last_message = List.last(messages)
            assert last_message.content =~ "FINAL TURN"
            {:ok, "```clojure\n(return 42)\n```"}

          _ ->
            {:ok, "```clojure\n(return 99)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == 42
    end

    test "feedback shows only println output, not expression results" do
      agent =
        SubAgent.new(
          prompt: "Search task",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            # Return a large list without println - should NOT appear in feedback
            {:ok, "```clojure\n[1 2 3 4 5 6 7 8 9 10]\n```"}

          2 ->
            # After turn 1, feedback should NOT contain the list result
            last_message = List.last(messages)
            refute last_message.content =~ "[1 2 3"
            # Use println to see output
            {:ok, "```clojure\n(println \"count:\" 42)\n:done\n```"}

          3 ->
            # After turn 2, feedback should contain println output but not :done
            last_message = List.last(messages)
            assert last_message.content =~ "count: 42"
            refute last_message.content =~ ":done"
            {:ok, "```clojure\n(return :finished)\n```"}

          _ ->
            {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == :finished
    end

    test "println output is truncated when exceeding feedback_max_chars" do
      agent =
        SubAgent.new(
          prompt: "Test task",
          tools: %{},
          max_turns: 3,
          # Small limit to trigger truncation
          format_options: [feedback_max_chars: 50]
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            # Print a lot of output that exceeds 50 chars
            {:ok,
             ~S"""
             ```clojure
             (println "Line 1: some text here")
             (println "Line 2: more text here")
             (println "Line 3: even more text")
             :done
             ```
             """}

          2 ->
            # Verify truncation hint appears
            last_message = List.last(messages)
            assert last_message.content =~ "Line 1"
            assert last_message.content =~ "truncated"
            {:ok, "```clojure\n(return :done)\n```"}

          _ ->
            {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == :done
    end
  end
end
