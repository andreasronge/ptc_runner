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
(return {:value 42})
```|} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"value" => 42}
      assert step.fail == nil
      assert step.usage.turns == 1
    end

    test "executes loop mode with tools" do
      agent = SubAgent.new(prompt: "Test", tools: %{"test" => fn _ -> :ok end})
      llm = fn _input -> {:ok, ~S|```clojure
(return {:value 42})
```|} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"value" => 42}
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

      assert step.return == %{"count" => 5}
    end

    test "accepts tools in opts for string form (triggers loop mode)" do
      tools = %{"test" => fn _ -> :ok end}
      llm = fn _input -> {:ok, ~S|```clojure
(return {:value 42})
```|} end

      # This triggers loop mode
      {:ok, step} = SubAgent.run("Test", tools: tools, llm: llm)

      assert step.return == %{"value" => 42}
    end

    test "accepts max_turns in opts for string form" do
      llm = fn _input -> {:ok, ~S|```clojure
(return {:value 42})
```|} end

      # max_turns: 2 triggers loop mode
      {:ok, step} = SubAgent.run("Test", max_turns: 2, llm: llm)

      assert step.return == %{"value" => 42}
    end

    test "string form with context" do
      llm = fn _input -> {:ok, "```clojure\n(+ data/a data/b)\n```"} end

      {:ok, step} =
        SubAgent.run("Add {{a}} and {{b}}", max_turns: 1, llm: llm, context: %{a: 3, b: 4})

      assert step.return == 7
    end
  end

  describe "run/2 - tool/data conflict validation" do
    test "raises when tool name conflicts with context data key" do
      agent = SubAgent.new(prompt: "test", tools: %{"search" => fn _ -> :ok end})

      assert_raise ArgumentError, ~r/search is both a tool and data/, fn ->
        SubAgent.run(agent, llm: fn _ -> {:ok, "42"} end, context: %{search: "data"})
      end
    end

    test "raises when tool name conflicts with context data key (atom key)" do
      agent = SubAgent.new(prompt: "test", tools: %{"query" => fn _ -> :ok end})

      assert_raise ArgumentError, ~r/query is both a tool and data/, fn ->
        SubAgent.run(agent, llm: fn _ -> {:ok, "42"} end, context: %{query: "value"})
      end
    end

    test "succeeds when tool names don't conflict with context data" do
      agent =
        SubAgent.new(prompt: "Use {{data}}", max_turns: 1, tools: %{"search" => fn _ -> :ok end})

      llm = fn _ -> {:ok, "```clojure\n42\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{data: "value"})
      assert step.return == 42
    end

    test "succeeds with empty tools (no conflict possible)" do
      agent = SubAgent.new(prompt: "Use {{search}}", max_turns: 1)
      llm = fn _ -> {:ok, "```clojure\ndata/search\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{search: "data"})
      assert step.return == "data"
    end

    test "succeeds with empty context (no conflict possible)" do
      agent = SubAgent.new(prompt: "test", max_turns: 1, tools: %{"search" => fn _ -> :ok end})
      llm = fn _ -> {:ok, "```clojure\n42\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{})
      assert step.return == 42
    end

    test "raises on conflict when context is a Step" do
      agent = SubAgent.new(prompt: "test", tools: %{"result" => fn _ -> :ok end})
      step_context = %PtcRunner.Step{return: %{result: 42}, fail: nil, memory: %{}}

      assert_raise ArgumentError, ~r/result is both a tool and data/, fn ->
        SubAgent.run(agent, llm: fn _ -> {:ok, "42"} end, context: step_context)
      end
    end

    test "skips validation for failed Step context" do
      agent = SubAgent.new(prompt: "test", tools: %{"result" => fn _ -> :ok end})

      step_context = %PtcRunner.Step{
        return: nil,
        fail: %{reason: :test_failure, message: "Test failed"},
        memory: %{}
      }

      # Should not raise for tool/data conflict - the chained failure is detected later
      {:error, error_step} =
        SubAgent.run(agent, llm: fn _ -> {:ok, "42"} end, context: step_context)

      assert error_step.fail.reason == :chained_failure
    end
  end

  describe "float_precision" do
    test "default float_precision is 2" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.float_precision == 2
    end

    test "rounds floats to 2 decimals in single-shot mode" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(/ 10 3)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 3.33
    end

    test "rounds floats in nested structures in single-shot mode" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n{:value (/ 10 3) :pi 3.14159}\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"value" => 3.33, "pi" => 3.14}
    end

    test "rounds floats to 2 decimals in loop mode" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)
      llm = fn _input -> {:ok, "```clojure\n(return (/ 10 3))\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 3.33
    end

    test "custom float_precision rounds to specified decimals" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1, float_precision: 4)
      llm = fn _input -> {:ok, "```clojure\n(/ 10 3)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 3.3333
    end

    test "float_precision 0 rounds to integers" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1, float_precision: 0)
      llm = fn _input -> {:ok, "```clojure\n(/ 10 3)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 3.0
    end
  end
end
