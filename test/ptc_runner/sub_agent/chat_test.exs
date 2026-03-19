defmodule PtcRunner.SubAgent.ChatTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "chat/3 text mode" do
    test "basic chat returns {:ok, text, messages, memory}" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :text,
          system_prompt: "You are helpful."
        )

      llm = fn _input -> {:ok, "Hello! How can I help?"} end

      {:ok, reply, messages, memory} = SubAgent.chat(agent, "Hi there", llm: llm)

      assert reply == "Hello! How can I help?"
      assert is_list(messages)
      assert memory == %{}
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

      {:ok, reply, _messages, _memory} =
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

      {:ok, reply, _messages, _memory} =
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

      {:ok, reply, _messages, _memory} =
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

      {:ok, _reply, messages, _memory} = SubAgent.chat(agent, "Hello", llm: llm1)

      # Second call with history — system should still not be in messages
      llm2 = fn %{system: system, messages: messages} ->
        assert system == "You are helpful."
        # Prior messages should not include system role
        refute Enum.any?(messages, fn m -> m.role == :system end)
        {:ok, "Second reply"}
      end

      {:ok, _reply2, _messages2, _memory} =
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

      {:ok, reply1, messages1, _memory} = SubAgent.chat(agent, "First message", llm: llm)
      assert reply1 == "Response"

      {:ok, reply2, messages2, _memory} =
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

      {:ok, reply, _messages, _memory} = SubAgent.chat(agent, "Rate this", llm: llm)

      assert is_binary(reply)
      assert reply == "Just a plain text response"
    end
  end

  describe "chat/3 PTC-Lisp mode" do
    test "basic PTC-Lisp chat returns structured result and memory" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :ptc_lisp,
          system_prompt: "You are a helpful assistant."
        )

      llm = fn _input ->
        {:ok, %{content: "(return {:answer \"hello\"})", tokens: %{input: 10, output: 5}}}
      end

      {:ok, result, messages, memory} = SubAgent.chat(agent, "Greet me", llm: llm)

      assert result == %{"answer" => "hello"}
      assert is_list(messages)
      assert is_map(memory)
    end

    test "memory threading — initial memory is accessible via def'd variables" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :ptc_lisp,
          system_prompt: "You are a helpful assistant."
        )

      # First call: LLM defines a variable
      llm1 = fn _input ->
        {:ok,
         %{
           content: "(def counter 42)\n(return {:value counter})",
           tokens: %{input: 10, output: 5}
         }}
      end

      {:ok, result1, messages1, memory1} = SubAgent.chat(agent, "Set counter", llm: llm1)

      assert result1 == %{"value" => 42}
      assert memory1[:counter] == 42

      # Second call: LLM receives previous memory and can use the variable
      llm2 = fn _input ->
        {:ok,
         %{
           content: "(return {:value (+ counter 1)})",
           tokens: %{input: 10, output: 5}
         }}
      end

      {:ok, result2, _messages2, _memory2} =
        SubAgent.chat(agent, "Increment counter",
          llm: llm2,
          messages: messages1,
          memory: memory1
        )

      assert result2 == %{"value" => 43}
    end

    test "history threading — initial_messages are prepended in PTC-Lisp mode" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :ptc_lisp,
          system_prompt: "You are a helpful assistant."
        )

      prior_messages = [
        %{role: :user, content: "prior question"},
        %{role: :assistant, content: "(return {:answer \"prior\"})"}
      ]

      llm = fn %{messages: messages} ->
        # Should have prior messages prepended before the first_user_message
        assert length(messages) >= 3
        assert Enum.at(messages, 0).role == :user
        assert Enum.at(messages, 0).content == "prior question"
        assert Enum.at(messages, 1).role == :assistant

        {:ok, %{content: "(return {:ok true})", tokens: %{input: 10, output: 5}}}
      end

      {:ok, _result, _messages, _memory} =
        SubAgent.chat(agent, "Follow up",
          llm: llm,
          messages: prior_messages
        )
    end

    test "memory visible in Data Inventory on first turn" do
      agent =
        SubAgent.new(
          prompt: "placeholder",
          output: :ptc_lisp,
          system_prompt: "You are a helpful assistant."
        )

      initial_memory = %{counter: 42, name: "test"}

      llm = fn %{messages: messages} ->
        # The first user message should contain the Data Inventory with memory variables
        first_user = Enum.find(messages, fn m -> m.role == :user end)
        assert first_user.content =~ "counter"

        {:ok, %{content: "(return {:value counter})", tokens: %{input: 10, output: 5}}}
      end

      {:ok, _result, _messages, _memory} =
        SubAgent.chat(agent, "Use the counter",
          llm: llm,
          memory: initial_memory
        )
    end
  end
end
