defmodule PtcRunner.Lisp.ToolCacheBoundaryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Primitive

  test "rejects caller-supplied cache state before invoking a tool provider" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "cached" =>
        {fn arguments ->
           :atomics.add(provider_calls, 1, 1)
           arguments
         end, cache: true}
    }

    imported_cache = %{
      {"cached", %{"x" => 1}} => %{
        result: "imported",
        child_step: nil,
        child_trace_id: nil
      }
    }

    assert_raise ArgumentError, ~r/:tool_cache option is not supported/, fn ->
      Lisp.run(~S|(tool/cached {"x" 1})|, tools: tools, tool_cache: imported_cache)
    end

    assert :atomics.get(provider_calls, 1) == 0
  end

  test "an imported hit cannot bypass Java tool-result projection" do
    assert {:ok, callable} = Callable.new(:boolean_parse_boolean)
    provider_calls = :atomics.new(1, [])

    tools = %{
      "cached" =>
        {fn _arguments ->
           :atomics.add(provider_calls, 1, 1)
           callable
         end, cache: true}
    }

    assert {:error, fresh_step} = Lisp.run("(tool/cached {})", tools: tools)
    assert fresh_step.fail.reason == :tool_error
    assert :atomics.get(provider_calls, 1) == 1

    imported_cache = %{
      {"cached", %{}} => %{
        result: callable,
        child_step: nil,
        child_trace_id: nil
      }
    }

    assert_raise ArgumentError, ~r/:tool_cache option is not supported/, fn ->
      Lisp.run("(tool/cached {})", tools: tools, tool_cache: imported_cache)
    end

    assert :atomics.get(provider_calls, 1) == 1
  end

  test "cache entries are reused only within one evaluation" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "cached" =>
        {fn arguments ->
           :atomics.add(provider_calls, 1, 1)
           arguments["x"]
         end, cache: true}
    }

    source = ~S|(do (tool/cached {"x" 1}) (tool/cached {"x" 1}))|

    assert {:ok, first_step} = Lisp.run(source, tools: tools)
    assert first_step.return == 1
    assert Enum.map(first_step.tool_calls, &Map.get(&1, :cached, false)) == [false, true]
    assert :atomics.get(provider_calls, 1) == 1

    assert {:ok, second_step} = Lisp.run(source, tools: tools)
    assert second_step.return == 1
    assert Enum.map(second_step.tool_calls, &Map.get(&1, :cached, false)) == [false, true]
    assert :atomics.get(provider_calls, 1) == 2
  end

  test "public and native results do not expose an evaluator cache field" do
    tools = %{"cached" => {fn _arguments -> "cache-result-sentinel" end, cache: true}}
    source = ~S|(tool/cached {"value" "cache-argument-sentinel"})|

    assert {:ok, public_step} = Lisp.run(source, tools: tools)
    assert {:ok, native_step} = Lisp.run_native(source, tools: tools)

    refute Map.has_key?(public_step, :tool_cache)
    refute Map.has_key?(native_step, :tool_cache)
  end

  test "cache identity uses arguments prepared for the callback" do
    assert {:ok, primitive} = Primitive.new(:long, 7)
    provider_calls = :atomics.new(1, [])

    tools = %{
      "cached" =>
        {fn arguments ->
           :atomics.add(provider_calls, 1, 1)
           arguments["value"]
         end, signature: "(value :int) -> :int", cache: true}
    }

    source = ~S|(do (tool/cached {:value p}) (tool/cached {:value 7}))|

    assert {:ok, step} = Lisp.run(source, memory: %{"p" => primitive}, tools: tools)
    assert step.return == 7
    assert Enum.map(step.tool_calls, &Map.get(&1, :cached, false)) == [false, true]
    assert :atomics.get(provider_calls, 1) == 1
  end

  test "cache identity preserves exact quoted-symbol key spelling" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "cached" => {fn _arguments -> :atomics.add_get(provider_calls, 1, 1) end, cache: true}
    }

    source = ~S|(do (tool/cached {'foo-bar 1}) (tool/cached {'foo_bar 1}))|

    assert {:ok, step} = Lisp.run(source, tools: tools)
    assert step.return == 2
    assert Enum.map(step.tool_calls, &Map.get(&1, :cached, false)) == [false, false]
    assert :atomics.get(provider_calls, 1) == 2
  end

  test "later parallel inputs win cache conflicts before sequential reuse" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "cached" => {fn _arguments -> :atomics.add_get(provider_calls, 1, 1) end, cache: true}
    }

    source = ~S"""
    (do
      (pmap (fn [_] (tool/cached {"key" 1})) [0 1])
      (tool/cached {"key" 1}))
    """

    assert {:ok, step} =
             Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.return == 2
    assert Enum.map(step.tool_calls, & &1.result) == [1, 2, 2]
    assert Enum.map(step.tool_calls, &Map.get(&1, :cached, false)) == [false, false, true]
    assert :atomics.get(provider_calls, 1) == 2
  end

  test "non-cacheable tools invoke the provider for every call" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "plain" => fn arguments ->
        :atomics.add(provider_calls, 1, 1)
        arguments["x"]
      end
    }

    assert {:ok, step} =
             Lisp.run(~S|(do (tool/plain {"x" 1}) (tool/plain {"x" 1}))|, tools: tools)

    assert Enum.all?(step.tool_calls, &(Map.get(&1, :cached, false) == false))
    assert :atomics.get(provider_calls, 1) == 2
  end
end
