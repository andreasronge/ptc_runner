defmodule PtcRunner.SubAgent.LoopReturnFailTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  describe "(return value) syntactic sugar" do
    test "return shorthand works same as call return" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:result 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert step.fail == nil
    end

    test "return with expression value" do
      agent = test_agent(prompt: "Add numbers")

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:sum (+ data/x data/y)})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{x: 10, y: 5})

      assert step.return == %{"sum" => 15}
    end

    test "return in let binding" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(let [x (+ 1 2)]
  (return {:value x}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 3}
    end

    test "return in conditional" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(if (> data/n 0)
  (return {:sign :positive})
  (return {:sign :non-positive}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{n: 5})

      assert step.return == %{"sign" => :positive}
    end
  end

  describe "(fail error) syntactic sugar" do
    test "fail shorthand produces user error" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(fail {:reason :bad-input})
```|}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :failed
    end

    test "fail with expression value" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(fail {:error (str "code: " data/code)})
```|}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{code: 500})

      assert step.fail.reason == :failed
    end

    test "fail alone in code" do
      agent = test_agent()

      # Test fail without return in the same code
      llm = fn _ ->
        {:ok, ~S|```clojure
(fail {:reason :missing-data})
```|}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :failed
    end

    test "fail in unevaluated conditional branch does not cause failure" do
      # Regression test for bug where (fail ...) in unevaluated branch
      # was detected by static code analysis and incorrectly caused failure
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(if true
  (return "success")
  (fail {:reason :never-called :message "This should never be reached"}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == "success"
    end

    test "return in unevaluated conditional branch does not trigger return" do
      # Regression test for symmetric bug with (return ...) in unevaluated branch
      agent = test_agent(max_turns: 2)
      call_count = :counters.new(1, [:atomics])

      llm = fn _ ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        if count == 1 do
          # First call: return in unevaluated branch, else returns 42
          {:ok, ~S|(if false (return "wrong") 42)|}
        else
          # Second call: explicit return
          {:ok, ~S|(return 42)|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == 42
      # Should have taken 2 turns (first turn didn't trigger return)
      assert :counters.get(call_count, 1) == 2
    end
  end
end
