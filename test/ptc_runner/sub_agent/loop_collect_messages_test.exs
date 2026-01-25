defmodule PtcRunner.SubAgent.LoopCollectMessagesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  describe "collect_messages option" do
    test "collect_messages: false (default) returns nil messages" do
      agent = test_agent()
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.messages == nil
    end

    test "collect_messages: true returns messages with system prompt" do
      agent = test_agent()
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert is_list(step.messages)
      assert length(step.messages) == 3

      # First message is system prompt
      [system_msg, user_msg, assistant_msg] = step.messages
      assert system_msg.role == :system
      assert system_msg.content =~ "PTC-Lisp"

      # Second is user (prompt)
      assert user_msg.role == :user

      # Third is assistant (response)
      assert assistant_msg.role == :assistant
    end

    test "multi-turn conversation captures full history" do
      agent =
        SubAgent.new(
          prompt: "Multi-turn test",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:result 42})\n```"}
          _ -> {:ok, "```clojure\n(return :done)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      # System + user + assistant + user (feedback) + assistant (return)
      assert length(step.messages) == 5

      roles = Enum.map(step.messages, & &1.role)
      assert roles == [:system, :user, :assistant, :user, :assistant]
    end

    test "single-shot mode with collect_messages: true works" do
      agent = test_agent(max_turns: 1)
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert is_list(step.messages)
      assert length(step.messages) == 3

      [system_msg, user_msg, assistant_msg] = step.messages
      assert system_msg.role == :system
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end

    test "error path (max_turns exceeded) collects messages" do
      # Uses a signature that the expression result doesn't match, preventing
      # the fallback recovery from triggering (fallback validates against signature)
      agent = test_agent(max_turns: 2, signature: "{result :string}")

      llm = fn _ ->
        # Returns integer, doesn't match {result :string} signature
        {:ok, "```clojure\n(+ 1 2)\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert step.fail.reason == :max_turns_exceeded
      assert is_list(step.messages)
      # System + user + assistant + user (feedback) + assistant + user (feedback)
      # = 6 messages (turn 1 and turn 2 both complete with assistant + feedback)
      assert length(step.messages) == 6
    end

    test "error path (LLM error) collects messages" do
      agent = test_agent()

      llm = fn _ ->
        {:error, :network_timeout}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert step.fail.reason == :llm_error
      assert is_list(step.messages)
      # User only (LLM failed before responding, system prompt not captured yet)
      assert length(step.messages) == 1
    end

    test "error path (explicit fail) collects messages" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, "```clojure\n(fail {:reason :bad-input})\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, collect_messages: true)

      assert step.fail.reason == :failed
      assert is_list(step.messages)
      # System + user + assistant
      assert length(step.messages) == 3
    end
  end
end
