defmodule PtcRunner.SubAgent.LoopCompressionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  describe "compression option" do
    test "compression: nil (default) uses uncompressed messages" do
      agent = test_agent(max_turns: 3)

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}

      # Check that turn 2 has accumulated messages (uncompressed)
      log = Agent.get(messages_log, & &1)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)
      # Uncompressed: user, assistant, user (feedback)
      assert length(turn2_messages) == 3
    end

    test "compression: true uses SingleUserCoalesced on turn > 1" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3,
          compression: true
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}

      log = Agent.get(messages_log, & &1)

      # Turn 1 should have 1 message (first user message)
      {1, turn1_messages} = Enum.find(log, fn {turn, _} -> turn == 1 end)
      assert length(turn1_messages) == 1

      # Turn 2 should have only 1 message (compressed USER message)
      # because compression coalesces history into a single user message
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)
      assert length(turn2_messages) == 1
      assert hd(turn2_messages).role == :user
    end

    test "compression: {Strategy, opts} passes custom options" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3,
          compression: {PtcRunner.SubAgent.Compression.SingleUserCoalesced, println_limit: 5}
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
    end

    test "compression: false disables compression" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 3,
          compression: false
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}

      log = Agent.get(messages_log, & &1)

      # Turn 2 should have accumulated messages (uncompressed)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)
      # Uncompressed: user, assistant, user (feedback)
      assert length(turn2_messages) == 3
    end

    test "compression is skipped for max_turns: 1 (SS-001)" do
      # Even with compression enabled, single-shot mode should skip it
      agent =
        SubAgent.new(
          prompt: "Single-shot task",
          tools: %{},
          max_turns: 1,
          compression: true
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{messages: messages} ->
        Agent.update(messages_log, fn log -> [messages | log] end)
        {:ok, "```clojure\n(return {:result 42})\n```"}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}

      # Single turn - only 1 user message
      log = Agent.get(messages_log, & &1)
      assert length(log) == 1
      assert length(hd(log)) == 1
    end

    test "compression includes turns indicator" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn task",
          tools: %{},
          max_turns: 5,
          compression: true
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})

      log = Agent.get(messages_log, & &1)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)

      # Compressed message should include turns indicator
      user_message = hd(turn2_messages)
      assert user_message.content =~ "Turns left:"
    end

    test "compressed view includes execution history" do
      tools = %{
        "get-value" => {fn _ -> 42 end, description: "Gets a value"}
      }

      agent =
        SubAgent.new(
          prompt: "Multi-turn task with tools",
          tools: tools,
          max_turns: 3,
          compression: true
        )

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(tool/get-value {})\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}

      log = Agent.get(messages_log, & &1)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)

      # Compressed message should include execution history with tool call
      user_message = hd(turn2_messages)
      assert user_message.content =~ "get-value"
    end

    test "compression option works with string form of SubAgent.run/2" do
      # Regression test: compression option was being dropped in string form
      tools = %{"get-value" => fn _ -> 42 end}

      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn %{turn: turn, messages: messages} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 -> {:ok, "```clojure\n(tool/get-value {})\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      # Use string form of run/2 with compression: true
      {:ok, step} =
        SubAgent.run(
          "Do multi-turn task",
          tools: tools,
          max_turns: 3,
          compression: true,
          llm: llm
        )

      assert step.return == %{"result" => 42}

      # Verify compression was actually applied - turn 2 should have 1 message
      log = Agent.get(messages_log, & &1)
      {2, turn2_messages} = Enum.find(log, fn {turn, _} -> turn == 2 end)

      # With compression, turn 2 should have exactly 1 user message (compressed)
      assert length(turn2_messages) == 1
      assert hd(turn2_messages).role == :user
    end

    test "return validation error is stored in turn result for compressed mode" do
      # Regression test: validation error message was lost during compression
      # The LLM needs to see the actual error, not just the invalid return value
      agent =
        SubAgent.new(
          prompt: "Return a float",
          signature: "{value :float}",
          max_turns: 3,
          compression: true
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            # Return integer instead of float - should fail validation
            {:ok, "```clojure\n(return {:value 0})\n```"}

          2 ->
            # Check that the error message is in the compressed user message
            user_msg = hd(messages)

            # The compressed message should contain the validation error
            assert user_msg.content =~ "expected float" or
                     user_msg.content =~ "Return type validation failed",
                   "Expected validation error in compressed message, got: #{String.slice(user_msg.content, 0, 500)}"

            # Now return correct type
            {:ok, "```clojure\n(return {:value 1.0})\n```"}

          _ ->
            {:ok, "```clojure\n(return {:value 0.0})\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 1.0}
      assert length(step.turns) == 2

      # Verify turn 1 was marked as failure with proper error info
      [turn1, _turn2] = step.turns
      assert turn1.success? == false
      assert turn1.result.reason == :return_validation_failed
      assert turn1.result.message =~ "expected float"
    end
  end
end
