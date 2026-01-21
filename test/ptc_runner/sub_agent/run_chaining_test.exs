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
(fail {:reason :test_failure :message "Intentional failure"})
```|} end

      assert_raise PtcRunner.SubAgentError, ~r/failed/, fn ->
        SubAgent.run!(agent, llm: llm)
      end
    end

    test "SubAgentError contains step for inspection" do
      agent = SubAgent.new(prompt: "Fail", max_turns: 2)
      llm = fn _input -> {:ok, ~S|```clojure
(fail {:reason :custom_error :message "Test error"})
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
{:result (* 2 data/n)}
```|}

          content =~ "Add 10" ->
            {:ok, ~S|```clojure
{:final (+ data/result 10)}
```|}
        end
      end

      result =
        SubAgent.run!(doubler, llm: mock_llm, context: %{n: 5})
        |> SubAgent.then!(adder, llm: mock_llm)

      assert result.return["final"] == 20
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
{:result (* 2 data/value)}
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

      assert result.return["result"] == 198
    end

    test "short-circuits on chained failure" do
      failing = SubAgent.new(prompt: "Fail", max_turns: 2)
      never_runs = SubAgent.new(prompt: "Never", max_turns: 2)

      mock_llm = fn _input ->
        {:ok, ~S|```clojure
(fail {:reason :test_failure :message "Intentional"})
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
(fail {:reason :upstream_error :message "First agent failed"})
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
{:value data/x}
```|}

          content =~ "Double" ->
            {:ok, ~S|```clojure
{:doubled (* 2 data/value)}
```|}

          content =~ "Add 5" ->
            {:ok, ~S|```clojure
{:final (+ data/doubled 5)}
```|}
        end
      end

      result =
        SubAgent.run!(step1, llm: mock_llm, context: %{x: 10})
        |> SubAgent.then!(step2, llm: mock_llm)
        |> SubAgent.then!(step3, llm: mock_llm)

      assert result.return["final"] == 25
    end

    test "step.field_descriptions is populated from agent" do
      agent =
        SubAgent.new(
          prompt: "Return 42",
          signature: "() -> {answer :int}",
          field_descriptions: %{answer: "The answer to everything"},
          max_turns: 1
        )

      llm = fn _input -> {:ok, "```clojure\n{:answer 42}\n```"} end

      step = SubAgent.run!(agent, llm: llm)

      assert step.return == %{"answer" => 42}
      assert step.field_descriptions == %{answer: "The answer to everything"}
    end

    test "then!/2 propagates field_descriptions from previous step" do
      agent_a =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          field_descriptions: %{result: "The doubled value"},
          max_turns: 1
        )

      agent_b =
        SubAgent.new(
          prompt: "Add 10",
          signature: "(result :int) -> {final :int}",
          field_descriptions: %{final: "The final computed value"},
          max_turns: 1
        )

      # Track what agent_b sees in its prompt
      mock_llm = fn %{messages: msgs, system: system} ->
        content = msgs |> List.last() |> Map.get(:content)

        if content =~ "Double" do
          {:ok, "```clojure\n{:result (* 2 data/n)}\n```"}
        else
          # Verify description appears in system prompt (from agent_a's output)
          assert system =~ "The doubled value",
                 "Expected 'The doubled value' description in system prompt"

          {:ok, "```clojure\n{:final (+ data/result 10)}\n```"}
        end
      end

      step_a = SubAgent.run!(agent_a, llm: mock_llm, context: %{n: 5})
      assert step_a.field_descriptions == %{result: "The doubled value"}

      step_b = SubAgent.then!(step_a, agent_b, llm: mock_llm)
      assert step_b.return["final"] == 20
      assert step_b.field_descriptions == %{final: "The final computed value"}
    end

    test "descriptions flow through 3-agent chain" do
      agent_a =
        SubAgent.new(
          prompt: "Return value",
          signature: "() -> {x :int}",
          field_descriptions: %{x: "Description from A"},
          max_turns: 1
        )

      agent_b =
        SubAgent.new(
          prompt: "Double",
          signature: "(x :int) -> {y :int}",
          field_descriptions: %{y: "Description from B"},
          max_turns: 1
        )

      agent_c =
        SubAgent.new(
          prompt: "Triple",
          signature: "(y :int) -> {z :int}",
          field_descriptions: %{z: "Description from C"},
          max_turns: 1
        )

      descriptions_seen = :ets.new(:descriptions_seen, [:set, :public])

      mock_llm = fn %{messages: msgs, system: system} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Return value" ->
            {:ok, "```clojure\n{:x 10}\n```"}

          content =~ "Double" ->
            if system =~ "Description from A" do
              :ets.insert(descriptions_seen, {:b_saw_a, true})
            end

            {:ok, "```clojure\n{:y (* 2 data/x)}\n```"}

          content =~ "Triple" ->
            if system =~ "Description from B" do
              :ets.insert(descriptions_seen, {:c_saw_b, true})
            end

            {:ok, "```clojure\n{:z (* 3 data/y)}\n```"}
        end
      end

      result =
        SubAgent.run!(agent_a, llm: mock_llm)
        |> SubAgent.then!(agent_b, llm: mock_llm)
        |> SubAgent.then!(agent_c, llm: mock_llm)

      assert result.return["z"] == 60
      assert result.field_descriptions == %{z: "Description from C"}
      assert :ets.lookup(descriptions_seen, :b_saw_a) == [{:b_saw_a, true}]
      assert :ets.lookup(descriptions_seen, :c_saw_b) == [{:c_saw_b, true}]

      :ets.delete(descriptions_seen)
    end

    test "nil field_descriptions from upstream is handled gracefully" do
      agent_a =
        SubAgent.new(
          prompt: "Return value",
          signature: "() -> {x :int}",
          # No field_descriptions
          max_turns: 1
        )

      agent_b =
        SubAgent.new(
          prompt: "Double",
          signature: "(x :int) -> {y :int}",
          field_descriptions: %{y: "Double of x"},
          max_turns: 1
        )

      mock_llm = fn %{messages: msgs} ->
        content = msgs |> List.last() |> Map.get(:content)

        if content =~ "Return value" do
          {:ok, "```clojure\n{:x 5}\n```"}
        else
          {:ok, "```clojure\n{:y (* 2 data/x)}\n```"}
        end
      end

      step_a = SubAgent.run!(agent_a, llm: mock_llm)
      assert step_a.field_descriptions == nil

      step_b = SubAgent.then!(step_a, agent_b, llm: mock_llm)
      assert step_b.return["y"] == 10
      assert step_b.field_descriptions == %{y: "Double of x"}
    end
  end

  describe "then!/2 chain key validation" do
    test "raises when required input key missing from previous step output" do
      step = %PtcRunner.Step{return: %{x: 1}, fail: nil, memory: %{}}
      agent = SubAgent.new(prompt: "test", signature: "(y :int) -> :int")

      assert_raise ArgumentError, ~r/Chain mismatch.*\["y"\]/, fn ->
        SubAgent.then!(step, agent, llm: fn _ -> {:ok, "42"} end)
      end
    end

    test "succeeds when output keys are superset of input keys" do
      step = %PtcRunner.Step{return: %{x: 1, y: 2, extra: 3}, fail: nil, memory: %{}}

      agent =
        SubAgent.new(
          prompt: "Use {{x}} and {{y}}",
          signature: "(x :int, y :int) -> :int",
          max_turns: 1
        )

      mock_llm = fn _ -> {:ok, "```clojure\n(+ data/x data/y)\n```"} end

      # Should not raise
      result = SubAgent.then!(step, agent, llm: mock_llm)
      assert result.return == 3
    end

    test "skips validation when agent has no signature" do
      step = %PtcRunner.Step{return: %{anything: 1}, fail: nil, memory: %{}}
      agent = SubAgent.new(prompt: "Process", max_turns: 1)

      mock_llm = fn _ -> {:ok, "```clojure\n42\n```"} end

      # Should not raise - no signature means no key requirements
      result = SubAgent.then!(step, agent, llm: mock_llm)
      assert result.return == 42
    end

    test "skips validation when previous step failed" do
      step = %PtcRunner.Step{
        return: nil,
        fail: %{reason: :test_failure, message: "Test failed"},
        memory: %{}
      }

      agent = SubAgent.new(prompt: "test", signature: "(y :int) -> :int")

      # Should not raise for key validation - the chained failure
      # is detected during run/2 and results in :chained_failure
      assert_raise PtcRunner.SubAgentError, ~r/chained_failure/, fn ->
        SubAgent.then!(step, agent, llm: fn _ -> {:ok, "42"} end)
      end
    end

    test "raises with all missing keys listed" do
      step = %PtcRunner.Step{return: %{}, fail: nil, memory: %{}}
      agent = SubAgent.new(prompt: "test", signature: "(a :int, b :int, c :int) -> :int")

      assert_raise ArgumentError, ~r/Chain mismatch.*\["a", "b", "c"\]/, fn ->
        SubAgent.then!(step, agent, llm: fn _ -> {:ok, "42"} end)
      end
    end

    test "handles non-map return value from previous step" do
      step = %PtcRunner.Step{return: 42, fail: nil, memory: %{}}
      agent = SubAgent.new(prompt: "test", signature: "(x :int) -> :int")

      assert_raise ArgumentError, ~r/Chain mismatch.*\["x"\]/, fn ->
        SubAgent.then!(step, agent, llm: fn _ -> {:ok, "42"} end)
      end
    end

    test "handles atom vs string key normalization" do
      # Step has atom keys, signature has string param names
      step = %PtcRunner.Step{return: %{foo: 1, bar: 2}, fail: nil, memory: %{}}
      agent = SubAgent.new(prompt: "Use {{foo}}", signature: "(foo :int) -> :int", max_turns: 1)

      mock_llm = fn _ -> {:ok, "```clojure\ndata/foo\n```"} end

      # Should work - atom :foo should match signature param "foo"
      result = SubAgent.then!(step, agent, llm: mock_llm)
      assert result.return == 1
    end
  end
end
