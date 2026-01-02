defmodule PtcRunner.SubAgent.RunChainingTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "run!/2" do
    test "returns Step directly on success" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n42\n```"} end

      step = SubAgent.run!(agent, llm: llm)

      assert %PtcRunner.Step{} = step
      assert step.return == 42
      assert step.fail == nil
    end

    test "raises SubAgentError on failure" do
      agent = SubAgent.new(prompt: "Fail", max_turns: 2)
      llm = fn _input -> {:ok, ~S|```clojure
(call "fail" {:reason :test_failure :message "Intentional failure"})
```|} end

      assert_raise PtcRunner.SubAgentError, ~r/failed/, fn ->
        SubAgent.run!(agent, llm: llm)
      end
    end

    test "SubAgentError contains step for inspection" do
      agent = SubAgent.new(prompt: "Fail", max_turns: 2)
      llm = fn _input -> {:ok, ~S|```clojure
(call "fail" {:reason :custom_error :message "Test error"})
```|} end

      try do
        SubAgent.run!(agent, llm: llm)
        flunk("Expected SubAgentError to be raised")
      rescue
        e in PtcRunner.SubAgentError ->
          assert e.step.fail.reason == :failed
          assert e.step.fail.message =~ "custom_error"
          assert e.step.fail.message =~ "Test error"
          assert e.message =~ "failed"
      end
    end

    test "raises when llm is missing" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      assert_raise PtcRunner.SubAgentError, ~r/llm_required/, fn ->
        SubAgent.run!(agent)
      end
    end
  end

  describe "then!/2" do
    test "chains successful steps" do
      doubler =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          max_turns: 1
        )

      adder =
        SubAgent.new(
          prompt: "Add 10 to {{result}}",
          signature: "(result :int) -> {final :int}",
          max_turns: 1
        )

      mock_llm = fn %{messages: msgs} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Double" ->
            {:ok, ~S|```clojure
{:result (* 2 ctx/n)}
```|}

          content =~ "Add 10" ->
            {:ok, ~S|```clojure
{:final (+ ctx/result 10)}
```|}
        end
      end

      result =
        SubAgent.run!(doubler, llm: mock_llm, context: %{n: 5})
        |> SubAgent.then!(adder, llm: mock_llm)

      assert result.return.final == 20
    end

    test "passes previous step return as context" do
      first = SubAgent.new(prompt: "Return data", max_turns: 1)
      second = SubAgent.new(prompt: "Use {{value}}", max_turns: 1)

      mock_llm = fn %{messages: msgs} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Return data" ->
            {:ok, ~S|```clojure
{:value 99}
```|}

          content =~ "Use 99" ->
            {:ok, ~S|```clojure
{:result (* 2 ctx/value)}
```|}

          true ->
            {:ok, ~S|```clojure
42
```|}
        end
      end

      result =
        SubAgent.run!(first, llm: mock_llm)
        |> SubAgent.then!(second, llm: mock_llm)

      assert result.return.result == 198
    end

    test "short-circuits on chained failure" do
      failing = SubAgent.new(prompt: "Fail", max_turns: 2)
      never_runs = SubAgent.new(prompt: "Never", max_turns: 2)

      mock_llm = fn _input ->
        {:ok, ~S|```clojure
(call "fail" {:reason :test_failure :message "Intentional"})
```|}
      end

      # First agent fails with :failed reason (from loop mode)
      # Second agent should detect the failure and raise :chained_failure
      assert_raise PtcRunner.SubAgentError, fn ->
        SubAgent.run!(failing, llm: mock_llm)
        |> SubAgent.then!(never_runs, llm: mock_llm)
      end
    end

    test "chained failure includes upstream details" do
      failing = SubAgent.new(prompt: "Fail", max_turns: 2)
      second = SubAgent.new(prompt: "Second", max_turns: 2)

      mock_llm = fn _input ->
        {:ok, ~S|```clojure
(call "fail" {:reason :upstream_error :message "First agent failed"})
```|}
      end

      # Get the failed step first (without raising)
      {:error, failed_step} = SubAgent.run(failing, llm: mock_llm)

      # Now try to chain - this should raise with :chained_failure
      try do
        SubAgent.then!(failed_step, second, llm: mock_llm)
        flunk("Expected SubAgentError to be raised")
      rescue
        e in PtcRunner.SubAgentError ->
          # Chaining detects upstream failure and converts to :chained_failure
          assert e.step.fail.reason == :chained_failure
          assert e.step.fail.message =~ "Upstream agent failed"
          assert e.step.fail.message =~ "failed"
          assert e.step.fail.details.upstream.reason == :failed
      end
    end

    test "handles nil return value from previous step" do
      first = SubAgent.new(prompt: "Return nothing explicit", max_turns: 1)
      second = SubAgent.new(prompt: "Process", max_turns: 1)

      mock_llm = fn %{messages: _msgs} ->
        {:ok, ~S|```clojure
42
```|}
      end

      result =
        SubAgent.run!(first, llm: mock_llm)
        |> SubAgent.then!(second, llm: mock_llm)

      # Second agent should receive empty context when first returns nil
      assert result.return == 42
    end

    test "pipeline with multiple steps" do
      step1 = SubAgent.new(prompt: "Start with {{x}}", max_turns: 1)
      step2 = SubAgent.new(prompt: "Double {{value}}", max_turns: 1)
      step3 = SubAgent.new(prompt: "Add 5 to {{doubled}}", max_turns: 1)

      mock_llm = fn %{messages: msgs} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Start with" ->
            {:ok, ~S|```clojure
{:value ctx/x}
```|}

          content =~ "Double" ->
            {:ok, ~S|```clojure
{:doubled (* 2 ctx/value)}
```|}

          content =~ "Add 5" ->
            {:ok, ~S|```clojure
{:final (+ ctx/doubled 5)}
```|}
        end
      end

      result =
        SubAgent.run!(step1, llm: mock_llm, context: %{x: 10})
        |> SubAgent.then!(step2, llm: mock_llm)
        |> SubAgent.then!(step3, llm: mock_llm)

      assert result.return.final == 25
    end
  end
end
