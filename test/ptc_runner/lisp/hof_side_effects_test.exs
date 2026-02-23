defmodule PtcRunner.Lisp.HofSideEffectsTest do
  @moduledoc """
  Tests that side effects (tool_calls, prints) inside higher-order functions
  (reduce, map, filter, etc.) are properly captured in the Step result.

  Background: closure_to_fun wraps PTC-Lisp closures into Erlang functions
  for use with Enum.reduce etc. The eval context (containing tool_calls and
  prints) was being discarded after each closure invocation, losing all
  side effects from inside HOF callbacks.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "tool_calls inside reduce" do
    test "tool calls made inside reduce are captured in step.tool_calls" do
      tools = %{
        "store" => {fn args -> "stored:#{args["id"]}" end, "(id :int) -> :string"}
      }

      source = ~S"""
      (reduce (fn [acc x]
        (tool/store {"id" x})
        (+ acc 1))
        0 [1 2 3])
      """

      {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == 3
      assert length(step.tool_calls) == 3

      ids = Enum.map(step.tool_calls, & &1.args["id"])
      assert Enum.sort(ids) == [1, 2, 3]
    end

    test "tool calls in nested reduce are captured" do
      tools = %{
        "store" => {fn _args -> "ok" end, "(text :string) -> :string"}
      }

      source = ~S"""
      (reduce (fn [acc items]
        (reduce (fn [acc2 item]
          (tool/store {"text" item})
          (+ acc2 1))
          acc items))
        0 [["a" "b"] ["c"]])
      """

      {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == 3
      assert length(step.tool_calls) == 3
    end
  end

  describe "tool_calls inside map" do
    test "tool calls made inside map are captured in step.tool_calls" do
      tools = %{
        "transform" => {fn args -> String.upcase(args["text"]) end, "(text :string) -> :string"}
      }

      source = ~S"""
      (map (fn [x] (tool/transform {"text" x})) ["hello" "world"])
      """

      {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == ["HELLO", "WORLD"]
      assert length(step.tool_calls) == 2
    end
  end

  describe "tool_calls inside filter" do
    test "tool calls made inside filter are captured" do
      call_count = :counters.new(1, [:atomics])

      tools = %{
        "check" =>
          {fn args ->
             :counters.add(call_count, 1, 1)
             args["val"] > 2
           end, "(val :int) -> :bool"}
      }

      source = ~S"""
      (filter (fn [x] (tool/check {"val" x})) [1 2 3 4])
      """

      {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == [3, 4]
      # filter calls the tool on all 4 elements
      assert :counters.get(call_count, 1) == 4
      assert length(step.tool_calls) == 4
    end
  end

  describe "prints inside reduce" do
    test "println output inside reduce is captured in step.prints" do
      source = ~S"""
      (reduce (fn [acc x]
        (println (str "processing " x))
        (+ acc x))
        0 [10 20 30])
      """

      {:ok, step} = Lisp.run(source)
      assert step.return == 60
      assert step.prints == ["processing 10", "processing 20", "processing 30"]
    end
  end

  describe "prints inside map" do
    test "println output inside map is captured in step.prints" do
      source = ~S"""
      (map (fn [x] (println (str "item " x)) (* x x)) [1 2 3])
      """

      {:ok, step} = Lisp.run(source)
      assert step.return == [1, 4, 9]
      assert step.prints == ["item 1", "item 2", "item 3"]
    end
  end

  describe "mixed side effects in HOFs" do
    test "tool calls and prints both captured from reduce" do
      tools = %{
        "store" => {fn _args -> "stored" end, "(text :string) -> :string"}
      }

      source = ~S"""
      (reduce (fn [acc x]
        (println (str "storing " x))
        (tool/store {"text" (str "item-" x)})
        (+ acc 1))
        0 [1 2 3])
      """

      {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == 3
      assert length(step.tool_calls) == 3
      assert step.prints == ["storing 1", "storing 2", "storing 3"]
    end
  end
end
