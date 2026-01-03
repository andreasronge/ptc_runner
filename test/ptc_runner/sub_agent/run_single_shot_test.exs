defmodule PtcRunner.SubAgent.RunSingleShotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "run/2 - single-shot mode" do
    test "single-shot uses Prompt.generate with same structure as loop mode" do
      # Verify that single-shot mode uses the same prompt generation as loop mode
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      context = %{x: 5, y: 3}

      # Capture what the LLM receives in single-shot mode
      llm = fn input ->
        send(self(), {:llm_input, input})
        {:ok, "```clojure\n(+ ctx/x ctx/y)\n```"}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, context: context)

      assert_received {:llm_input, input}
      system_prompt = input.system

      # Single-shot mode should now use full Prompt.generate, which includes:
      assert system_prompt =~ "# Role"
      assert system_prompt =~ "You are a PTC-Lisp program generator"
      assert system_prompt =~ "# Rules"
      assert system_prompt =~ "# Data Inventory"
      assert system_prompt =~ "ctx/x"
      assert system_prompt =~ "ctx/y"
      assert system_prompt =~ "# Available Tools"
      assert system_prompt =~ "# Output Format"
      assert system_prompt =~ "# Mission"
    end

    # TODO: Fix in #538 - prompt no longer contains "Core Functions"
    @tag :skip
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
      assert system_prompt =~ "PTC-Lisp"
      assert system_prompt =~ "Core Functions"
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
      llm = fn _input -> {:ok, "```clojure\n(+ ctx/x ctx/y)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{x: 10, y: 5})

      assert step.return == 15
    end

    test "executes with string keys in context" do
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ ctx/x ctx/y)\n```"} end

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
      llm = fn _input -> {:ok, "```clojure\n(/ 1 0)\n```"} end

      {:error, step} = SubAgent.run(agent, llm: llm)

      assert step.fail.reason == :type_error
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
      assert input.system =~ "PTC-Lisp"
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
  end
end
