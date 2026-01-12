defmodule PtcRunner.StepTurnsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.{Step, SubAgent, Turn}
  alias PtcRunner.SubAgent.Loop

  @moduledoc """
  Tests for Step.turns field - dual-write phase of Step.trace → Step.turns migration.

  Verifies that both trace and turns are populated during SubAgent execution.
  """

  describe "Step.turns field population" do
    test "single turn populates both trace and turns" do
      agent =
        SubAgent.new(
          mission: "Calculate result",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{messages: _} ->
        {:ok, ~S|```clojure
(return {:result 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # Both trace and turns should be populated
      assert is_list(step.trace)
      assert is_list(step.turns)
      assert length(step.trace) == 1
      assert length(step.turns) == 1

      # Verify Turn struct
      [turn] = step.turns
      assert %Turn{} = turn
      assert turn.number == 1
      assert turn.success? == true
      assert turn.result == %{result: 42}
      assert turn.program == "(return {:result 42})"
      assert is_binary(turn.raw_response)
      assert turn.raw_response =~ "```clojure"
    end

    test "multi-turn loop populates both trace and turns" do
      agent =
        SubAgent.new(
          mission: "Do multi-step work",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n{:step 1}\n```"}
          2 -> {:ok, "```clojure\n{:step 2}\n```"}
          3 -> {:ok, ~S|```clojure
(return {:done true})
```|}
          _ -> {:ok, "```clojure\n99\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert length(step.trace) == 3
      assert length(step.turns) == 3

      # Verify turn ordering (chronological)
      [turn1, turn2, turn3] = step.turns
      assert turn1.number == 1
      assert turn2.number == 2
      assert turn3.number == 3

      # First two turns are successful continuations
      assert turn1.success? == true
      assert turn2.success? == true
      assert turn3.success? == true
    end

    test "Turn captures raw_response from LLM" do
      agent =
        SubAgent.new(
          mission: "Test",
          tools: %{},
          max_turns: 2
        )

      response_with_reasoning = """
      I'll calculate the result.

      ```clojure
      (return {:value 123})
      ```
      """

      llm = fn _ -> {:ok, response_with_reasoning} end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      [turn] = step.turns
      assert turn.raw_response == response_with_reasoning
    end

    test "Turn captures memory state" do
      agent =
        SubAgent.new(
          mission: "Build up memory",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        case turn do
          # First turn uses def to store value in memory
          1 -> {:ok, "```clojure\n(def counter 1)\n```"}
          # Second turn accesses memory value (plain symbol) and returns
          2 -> {:ok, ~S|```clojure
(return {:final (+ counter 10)})
```|}
          _ -> {:ok, "```clojure\n99\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      [turn1, turn2] = step.turns

      # After turn 1, memory should have counter (via def)
      assert turn1.memory == %{counter: 1}
      # Turn 2 inherits memory from turn 1
      assert turn2.memory == %{counter: 1}
    end

    test "Turn captures tool calls" do
      # Tools are functions that receive atom-keyed maps
      add_tool = fn %{a: a, b: b} -> a + b end

      agent =
        SubAgent.new(
          mission: "Use a tool",
          tools: %{"add" => add_tool},
          max_turns: 2
        )

      # Tools are called via ctx/ namespace
      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:sum (ctx/add {:a 3 :b 4})})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      [turn] = step.turns
      assert length(turn.tool_calls) == 1

      [tool_call] = turn.tool_calls
      assert tool_call.name == "add"
      assert tool_call.args == %{a: 3, b: 4}
      assert tool_call.result == 7
    end

    test "Turn captures println output" do
      agent =
        SubAgent.new(
          mission: "Print something",
          tools: %{},
          max_turns: 2
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
(do
  (println "Hello, world!")
  (return {:done true}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      [turn] = step.turns
      assert turn.prints == ["Hello, world!"]
    end
  end

  describe "Turn failure tracking" do
    test "execution error creates failure Turn" do
      agent =
        SubAgent.new(
          mission: "Cause error",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        case turn do
          # Unbound variable error
          1 -> {:ok, "```clojure\n(+ undefined_var 1)\n```"}
          # Success after retry
          2 -> {:ok, ~S|```clojure
(return {:recovered true})
```|}
          _ -> {:ok, "```clojure\n99\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert length(step.turns) == 2
      [turn1, turn2] = step.turns

      # First turn failed due to unbound variable
      assert turn1.success? == false
      assert turn1.result.reason == :unbound_var

      # Second turn succeeded
      assert turn2.success? == true
      assert turn2.result == %{recovered: true}
    end

    test "explicit fail creates failure Turn with args" do
      agent =
        SubAgent.new(
          mission: "Fail explicitly",
          tools: %{},
          max_turns: 2
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
(fail {:reason :not_found :id 123})
```|}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      [turn] = step.turns
      assert turn.success? == false
      assert turn.result == %{reason: :not_found, id: 123}
    end

    test "max_turns exceeded preserves accumulated turns" do
      agent =
        SubAgent.new(
          mission: "Loop forever",
          tools: %{},
          max_turns: 2
        )

      # Always return something that continues the loop
      llm = fn _ -> {:ok, "```clojure\n{:keep :going}\n```"} end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :max_turns_exceeded
      # Should have 2 turns from before max_turns was exceeded
      assert length(step.turns) == 2

      [turn1, turn2] = step.turns
      assert turn1.number == 1
      assert turn2.number == 2
    end
  end

  describe "trace filtering applies to turns" do
    test "trace: false returns nil for both trace and turns" do
      agent =
        SubAgent.new(
          mission: "Test filtering",
          tools: %{},
          max_turns: 2
        )

      llm = fn _ -> {:ok, "```clojure\n(return {:done true})\n```"} end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, trace: false)

      assert step.trace == nil
      assert step.turns == nil
    end

    test "trace: :on_error returns turns only on error" do
      agent =
        SubAgent.new(
          mission: "Test filtering",
          tools: %{},
          max_turns: 2
        )

      # Success case
      llm_success = fn _ -> {:ok, "```clojure\n(return {:done true})\n```"} end
      {:ok, success_step} = Loop.run(agent, llm: llm_success, context: %{}, trace: :on_error)

      assert success_step.trace == nil
      assert success_step.turns == nil

      # Error case
      llm_fail = fn _ -> {:ok, "```clojure\n(fail {:error true})\n```"} end
      {:error, error_step} = Loop.run(agent, llm: llm_fail, context: %{}, trace: :on_error)

      assert is_list(error_step.trace)
      assert is_list(error_step.turns)
    end
  end

  describe "Step constructors initialize turns to nil" do
    test "Step.ok/2 initializes turns to nil" do
      step = Step.ok(%{value: 1}, %{})
      assert step.turns == nil
    end

    test "Step.error/3 initializes turns to nil" do
      step = Step.error(:test_error, "test message", %{})
      assert step.turns == nil
    end

    test "Step.error/4 initializes turns to nil" do
      step = Step.error(:test_error, "test message", %{}, %{detail: 1})
      assert step.turns == nil
    end
  end
end
