defmodule PtcRunner.SubAgent.ChatTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "chat/3" do
    test "basic chat returns {:ok, text, messages}" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          system_prompt: "You are helpful."
        )

      llm = fn _input -> {:ok, "Hello! How can I help?"} end

      {:ok, reply, messages} = SubAgent.chat(agent, "Hi there", llm: llm)

      assert reply == "Hello! How can I help?"
      assert is_list(messages)
      # system + user + assistant
      assert length(messages) == 3
      assert Enum.at(messages, 0).role == :system
      assert Enum.at(messages, 1).role == :user
      assert Enum.at(messages, 1).content == "Hi there"
      assert Enum.at(messages, 2).role == :assistant
      assert Enum.at(messages, 2).content == "Hello! How can I help?"
    end

    test "history threading — LLM receives prior messages" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          system_prompt: "You are helpful."
        )

      prior_messages = [
        %{role: :system, content: "You are helpful."},
        %{role: :user, content: "What is Elixir?"},
        %{role: :assistant, content: "Elixir is a functional language."}
      ]

      llm = fn %{messages: messages} ->
        # Should have prior user+assistant (system stripped) + new user
        assert length(messages) == 3
        assert Enum.at(messages, 0).role == :user
        assert Enum.at(messages, 0).content == "What is Elixir?"
        assert Enum.at(messages, 1).role == :assistant
        assert Enum.at(messages, 1).content == "Elixir is a functional language."
        assert Enum.at(messages, 2).role == :user
        assert Enum.at(messages, 2).content == "Tell me more"
        {:ok, "It runs on the BEAM VM."}
      end

      {:ok, reply, _messages} =
        SubAgent.chat(agent, "Tell me more", llm: llm, messages: prior_messages)

      assert reply == "It runs on the BEAM VM."
    end

    test "streaming with on_chunk fires per-token" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          system_prompt: "You are helpful."
        )

      test_pid = self()

      on_chunk = fn chunk ->
        send(test_pid, {:chunk, chunk})
      end

      llm = fn %{stream: stream_fn} ->
        # Simulate streaming
        stream_fn.(%{delta: "Hello"})
        stream_fn.(%{delta: " world"})
        {:ok, %{content: "Hello world", tokens: %{input: 5, output: 3}}}
      end

      {:ok, reply, _messages} =
        SubAgent.chat(agent, "Hi", llm: llm, on_chunk: on_chunk)

      assert reply == "Hello world"
      assert_received {:chunk, %{delta: "Hello"}}
      assert_received {:chunk, %{delta: " world"}}
    end

    test "chat with tools — on_chunk fires on final answer" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          system_prompt: "You are helpful.",
          tools: %{
            "lookup" =>
              {fn _args -> "42" end,
               signature: "(query :string) -> :string", description: "Look up a value"}
          },
          max_turns: 5
        )

      test_pid = self()

      on_chunk = fn chunk ->
        send(test_pid, {:chunk, chunk})
      end

      call_count = :counters.new(1, [])

      llm = fn _input ->
        :counters.add(call_count, 1, 1)
        turn = :counters.get(call_count, 1)

        case turn do
          1 ->
            # First turn: tool call
            {:ok,
             %{
               tool_calls: [%{id: "tc_1", name: "lookup", args: %{"query" => "answer"}}],
               content: nil,
               tokens: %{input: 10, output: 5}
             }}

          _ ->
            # Second turn: final text answer
            {:ok, %{content: "The answer is 42", tokens: %{input: 15, output: 4}}}
        end
      end

      {:ok, reply, _messages} =
        SubAgent.chat(agent, "What is the answer?", llm: llm, on_chunk: on_chunk)

      assert reply == "The answer is 42"
      # on_chunk fires once with full content for tool-variant final answer
      assert_received {:chunk, %{delta: "The answer is 42"}}
    end

    test "error handling returns {:error, reason}" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          system_prompt: "You are helpful."
        )

      llm = fn _input -> {:error, :timeout} end

      {:error, _reason} = SubAgent.chat(agent, "Hi", llm: llm)
    end

    test "system prompt not duplicated across calls" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          system_prompt: "You are helpful."
        )

      # First call
      llm1 = fn %{system: system, messages: messages} ->
        assert system == "You are helpful."
        # No system message in messages list
        refute Enum.any?(messages, fn m -> m.role == :system end)
        {:ok, "First reply"}
      end

      {:ok, _reply, messages} = SubAgent.chat(agent, "Hello", llm: llm1)

      # Second call with history — system should still not be in messages
      llm2 = fn %{system: system, messages: messages} ->
        assert system == "You are helpful."
        # Prior messages should not include system role
        refute Enum.any?(messages, fn m -> m.role == :system end)
        {:ok, "Second reply"}
      end

      {:ok, _reply2, _messages2} =
        SubAgent.chat(agent, "Follow up", llm: llm2, messages: messages)
    end

    test "multi-turn: pass messages from first call to second call" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          system_prompt: "You are helpful."
        )

      llm = fn _input -> {:ok, "Response"} end

      {:ok, reply1, messages1} = SubAgent.chat(agent, "First message", llm: llm)
      assert reply1 == "Response"

      {:ok, reply2, messages2} =
        SubAgent.chat(agent, "Second message", llm: llm, messages: messages1)

      assert reply2 == "Response"

      # messages2 should contain the full conversation
      # system + prior_user + prior_assistant + new_user + new_assistant
      assert length(messages2) == 5

      roles = Enum.map(messages2, & &1.role)
      assert roles == [:system, :user, :assistant, :user, :assistant]
    end

    test "signature is cleared — always returns plain text" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          signature: "{score :float}",
          system_prompt: "You are helpful."
        )

      # Without clearing, TextMode would try to parse this as JSON and fail
      llm = fn _input -> {:ok, "Just a plain text response"} end

      {:ok, reply, _messages} = SubAgent.chat(agent, "Rate this", llm: llm)

      assert is_binary(reply)
      assert reply == "Just a plain text response"
    end
  end
end
