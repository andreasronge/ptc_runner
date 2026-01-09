defmodule PtcRunner.SubAgent.TraceToolCallsTest do
  @moduledoc """
  Tests for tool call capture in trace entries.

  Verifies that tool execution details (name, args, result, duration_ms, timestamp)
  are captured in trace entries during SubAgent execution.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  describe "tool calls in trace entries" do
    test "captures single tool call with all fields" do
      tools = %{
        "add" => fn %{a: a, b: b} -> a + b end
      }

      agent =
        SubAgent.new(
          prompt: "Add numbers",
          tools: tools,
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(return (ctx/add {:a 5 :b 3}))
```|}

          _ ->
            {:ok, ~S|```clojure
(return nil)
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == 8
      assert length(step.trace) == 1

      [trace_entry] = step.trace
      assert length(trace_entry.tool_calls) == 1

      [tool_call] = trace_entry.tool_calls
      assert tool_call.name == "add"
      assert tool_call.args == %{a: 5, b: 3}
      assert tool_call.result == 8
      assert tool_call.error == nil
      assert is_integer(tool_call.duration_ms)
      assert tool_call.duration_ms >= 0
      assert %DateTime{} = tool_call.timestamp
    end

    test "captures multiple tool calls in single turn" do
      tools = %{
        "add" => fn %{a: a, b: b} -> a + b end,
        "multiply" => fn %{a: a, b: b} -> a * b end
      }

      agent =
        SubAgent.new(
          prompt: "Calculate",
          tools: tools,
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(let [sum (ctx/add {:a 2 :b 3})
      product (ctx/multiply {:a sum :b 4})]
  (return {:sum sum :product product}))
```|}

          _ ->
            {:ok, ~S|```clojure
(return nil)
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{sum: 5, product: 20}
      assert length(step.trace) == 1

      [trace_entry] = step.trace
      assert length(trace_entry.tool_calls) == 2

      # Tool calls are in execution order (add first, then multiply)
      [add_call, multiply_call] = trace_entry.tool_calls

      assert add_call.name == "add"
      assert add_call.args == %{a: 2, b: 3}
      assert add_call.result == 5

      assert multiply_call.name == "multiply"
      assert multiply_call.args == %{a: 5, b: 4}
      assert multiply_call.result == 20
    end

    test "captures tool calls across multiple turns" do
      call_counter = :counters.new(1, [:atomics])

      tools = %{
        "get_data" => fn _ ->
          :counters.add(call_counter, 1, 1)
          %{value: :counters.get(call_counter, 1)}
        end
      }

      agent =
        SubAgent.new(
          prompt: "Get data twice",
          tools: tools,
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(ctx/get_data {})
```|}

          2 ->
            {:ok, ~S|```clojure
(return (ctx/get_data {}))
```|}

          _ ->
            {:ok, ~S|```clojure
(return nil)
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert length(step.trace) == 2

      # First turn
      [turn1, turn2] = step.trace

      assert length(turn1.tool_calls) == 1
      [turn1_call] = turn1.tool_calls
      assert turn1_call.name == "get_data"

      # Second turn
      assert length(turn2.tool_calls) == 1
      [turn2_call] = turn2.tool_calls
      assert turn2_call.name == "get_data"
    end

    test "empty tool_calls when no tools are called" do
      agent =
        SubAgent.new(
          prompt: "Calculate",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: _turn} ->
        {:ok, ~S|```clojure
(return (+ 1 2))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == 3
      assert length(step.trace) == 1

      [trace_entry] = step.trace
      assert trace_entry.tool_calls == []
    end

    test "captures tool calls on error turn" do
      tools = %{
        "get_value" => fn _ -> 42 end
      }

      agent =
        SubAgent.new(
          prompt: "Get value and fail",
          tools: tools,
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(do
  (ctx/get_value {})
  (/ 1 0))
```|}

          2 ->
            {:ok, ~S|```clojure
(return 42)
```|}

          _ ->
            {:ok, ~S|```clojure
(return nil)
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # First turn had an error but tool was still called
      assert length(step.trace) == 2

      [error_turn, _success_turn] = step.trace
      assert length(error_turn.tool_calls) == 1
      [tool_call] = error_turn.tool_calls
      assert tool_call.name == "get_value"
      assert tool_call.result == 42
    end
  end

  describe "tool call timing" do
    test "records non-zero duration for slow tools" do
      tools = %{
        "slow_tool" => fn _ ->
          Process.sleep(10)
          :done
        end
      }

      agent =
        SubAgent.new(
          prompt: "Call slow tool",
          tools: tools,
          max_turns: 3
        )

      llm = fn %{turn: _turn} ->
        {:ok, ~S|```clojure
(return (ctx/slow_tool {}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      [trace_entry] = step.trace
      [tool_call] = trace_entry.tool_calls

      assert tool_call.duration_ms >= 10
    end
  end
end
