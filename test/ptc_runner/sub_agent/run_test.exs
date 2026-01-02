defmodule PtcRunner.SubAgent.RunTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "run/2 - error cases" do
    test "returns error when llm is missing" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      {:error, step} = SubAgent.run(agent)

      assert step.fail.reason == :llm_required
      assert step.fail.message == "llm option is required"
      assert step.return == nil
      assert is_map(step.usage)
      assert step.usage.duration_ms >= 0
    end

    test "returns error when llm is missing (with context)" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      {:error, step} = SubAgent.run(agent, context: %{x: 1})

      assert step.fail.reason == :llm_required
    end

    test "returns error when LLM call fails" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:error, :network_timeout} end

      {:error, step} = SubAgent.run(agent, llm: llm)

      assert step.fail.reason == :llm_error
      assert step.fail.message =~ "LLM call failed"
      assert step.fail.message =~ "network_timeout"
    end

    test "returns error when no code found in LLM response" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:ok, "Just plain text, no code"} end

      {:error, step} = SubAgent.run(agent, llm: llm)

      assert step.fail.reason == :no_code_found
      assert step.fail.message == "No PTC-Lisp code found in LLM response"
    end

    test "executes loop mode with max_turns > 1" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{value: 42}
      assert step.fail == nil
      assert step.usage.turns == 1
    end

    test "executes loop mode with tools" do
      agent = SubAgent.new(prompt: "Test", tools: %{"test" => fn _ -> :ok end})
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{value: 42}
      assert step.fail == nil
    end
  end

  describe "run/2 - string convenience form" do
    test "creates agent from string prompt" do
      llm = fn _input -> {:ok, "```clojure\n42\n```"} end

      {:ok, step} = SubAgent.run("Return 42", max_turns: 1, llm: llm)

      assert step.return == 42
    end

    test "accepts signature in opts for string form" do
      llm = fn _input -> {:ok, "```clojure\n{:count 5}\n```"} end

      {:ok, step} =
        SubAgent.run("Count items", signature: "() -> {count :int}", max_turns: 1, llm: llm)

      assert step.return == %{count: 5}
    end

    test "accepts tools in opts for string form (triggers loop mode)" do
      tools = %{"test" => fn _ -> :ok end}
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|} end

      # This triggers loop mode
      {:ok, step} = SubAgent.run("Test", tools: tools, llm: llm)

      assert step.return == %{value: 42}
    end

    test "accepts max_turns in opts for string form" do
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|} end

      # max_turns: 2 triggers loop mode
      {:ok, step} = SubAgent.run("Test", max_turns: 2, llm: llm)

      assert step.return == %{value: 42}
    end

    test "string form with context" do
      llm = fn _input -> {:ok, "```clojure\n(+ ctx/a ctx/b)\n```"} end

      {:ok, step} =
        SubAgent.run("Add {{a}} and {{b}}", max_turns: 1, llm: llm, context: %{a: 3, b: 4})

      assert step.return == 7
    end
  end
end
