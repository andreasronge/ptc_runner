defmodule PtcRunner.SubAgent.RunSingleShotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "run/2 - single-shot mode" do
    test "single-shot uses SystemPrompt.generate with same structure as loop mode" do
      # Verify that single-shot mode uses the same prompt generation as loop mode
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      context = %{x: 5, y: 3}

      # Capture what the LLM receives in single-shot mode
      llm = fn input ->
        send(self(), {:llm_input, input})
        {:ok, "```clojure\n(+ data/x data/y)\n```"}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, context: context)

      assert_received {:llm_input, input}
      system_prompt = input.system

      # Single-shot mode should now use full SystemPrompt.generate, which includes:
      assert system_prompt =~ "<role>"
      assert system_prompt =~ "Write one program that accomplish the user's mission"
      refute system_prompt =~ "thinking:"
      assert system_prompt =~ ";; === data/ ==="
      assert system_prompt =~ "data/x"
      assert system_prompt =~ "data/y"
      # Note: no tools configured, so tools section not present
      assert system_prompt =~ "<output_format>"
      assert system_prompt =~ "<mission>"
    end

    test "single-shot with language_spec: :single_shot gets base prompt" do
      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 1,
          system_prompt: %{language_spec: :single_shot}
        )

      llm = fn input ->
        send(self(), {:llm_input, input})
        {:ok, "```clojure\n42\n```"}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      assert_received {:llm_input, input}
      system_prompt = input.system

      # Should use single_shot (base) language spec
      assert system_prompt =~ "<language_reference>"
      assert system_prompt =~ "<common_mistakes>"
      # single_shot should NOT have memory docs
      refute system_prompt =~ "Memory: Persisting Data Between Turns"
    end

    test "single-shot with string override uses custom prompt" do
      custom_prompt = "You are a custom agent."

      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 1,
          system_prompt: custom_prompt
        )

      llm = fn input ->
        send(self(), {:llm_input, input})
        {:ok, "```clojure\n42\n```"}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      assert_received {:llm_input, input}
      # String override bypasses generation entirely
      assert input.system == custom_prompt
    end

    test "executes simple calculation" do
      agent = SubAgent.new(prompt: "Calculate 2 + 3", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ 2 3)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 5
      assert step.fail == nil
      assert is_map(step.usage)
      assert step.usage.duration_ms >= 0
    end

    test "executes with template expansion" do
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ data/x data/y)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{x: 10, y: 5})

      assert step.return == 15
    end

    test "executes with string keys in context" do
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ data/x data/y)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{"x" => 7, "y" => 3})

      assert step.return == 10
    end

    test "handles code without markdown blocks" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)
      llm = fn _input -> {:ok, "(+ 40 2)"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 42
    end

    test "handles lisp code blocks" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)
      llm = fn _input -> {:ok, "```lisp\n(+ 40 2)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 42
    end

    test "propagates errors from Lisp execution" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"} end

      {:error, step} = SubAgent.run(agent, llm: llm)

      assert step.fail.reason == :arithmetic_error
      assert step.return == nil
    end

    test "uses llm from agent struct if not in opts" do
      llm = fn _input -> {:ok, "```clojure\n99\n```"} end
      agent = SubAgent.new(prompt: "Test", llm: llm, max_turns: 1)

      {:ok, step} = SubAgent.run(agent)

      assert step.return == 99
    end

    test "opts llm overrides agent struct llm" do
      agent_llm = fn _input -> {:ok, "```clojure\n1\n```"} end
      opts_llm = fn _input -> {:ok, "```clojure\n2\n```"} end

      agent = SubAgent.new(prompt: "Test", llm: agent_llm, max_turns: 1)

      {:ok, step} = SubAgent.run(agent, llm: opts_llm)

      assert step.return == 2
    end

    test "LLM receives expanded prompt in user message" do
      agent = SubAgent.new(prompt: "Find {{item}}", max_turns: 1)

      # Capture what the LLM receives
      received_input = :erlang.make_ref()

      llm = fn input ->
        send(self(), {:llm_input, received_input, input})
        {:ok, "```clojure\n42\n```"}
      end

      SubAgent.run(agent, llm: llm, context: %{item: "treasure"})

      assert_received {:llm_input, ^received_input, input}
      assert input.system =~ "<language_reference>"
      assert [%{role: :user, content: "Find treasure"}] = input.messages
    end

    test "empty context uses empty map" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n42\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 42
    end

    test "missing context key keeps placeholder unchanged" do
      agent = SubAgent.new(prompt: "Find {{missing}}", max_turns: 1)

      llm = fn %{messages: [%{content: content}]} ->
        # The missing key should remain as {{missing}}
        assert content == "Find {{missing}}"
        {:ok, "```clojure\n42\n```"}
      end

      SubAgent.run(agent, llm: llm, context: %{other: "value"})
    end

    test "collect_messages: false (default) returns nil messages" do
      agent = SubAgent.new(prompt: "Calculate 2 + 3", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ 2 3)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 5
      assert step.messages == nil
    end

    test "collect_messages: true returns messages with system, user, and assistant" do
      agent = SubAgent.new(prompt: "Calculate 2 + 3", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ 2 3)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)

      assert step.return == 5
      assert is_list(step.messages)
      assert length(step.messages) == 3

      roles = Enum.map(step.messages, & &1.role)
      assert roles == [:system, :user, :assistant]

      [system, user, assistant] = step.messages
      assert system.content =~ "<language_reference>"
      assert user.content == "Calculate 2 + 3"
      assert assistant.content =~ "(+ 2 3)"
    end

    test "collect_messages: true with template expansion" do
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ data/x data/y)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{x: 10, y: 5}, collect_messages: true)

      assert step.return == 15
      assert is_list(step.messages)

      [_system, user, _assistant] = step.messages
      # User message should have expanded template
      assert user.content == "Calculate 10 + 5"
    end

    test "collect_messages: true on error returns messages" do
      agent = SubAgent.new(prompt: "Test error", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"} end

      {:error, step} = SubAgent.run(agent, llm: llm, collect_messages: true)

      assert step.fail.reason == :arithmetic_error
      assert is_list(step.messages)
      assert length(step.messages) == 3

      roles = Enum.map(step.messages, & &1.role)
      assert roles == [:system, :user, :assistant]
    end
  end
end
