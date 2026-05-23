defmodule PtcRunner.Lisp.RuntimeCallableTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.RuntimeCallable

  defp clear_runtime_callable_process_state! do
    Process.delete(:__ptc_runtime_callable_context)
    Process.delete(:__ptc_hof_stack)

    on_exit(fn ->
      Process.delete(:__ptc_runtime_callable_context)
      Process.delete(:__ptc_hof_stack)
    end)
  end

  defp assert_runtime_callable_process_state_clean do
    assert Process.get(:__ptc_runtime_callable_context) == nil
    assert Process.get(:__ptc_hof_stack, []) == []
  end

  defp assert_no_persisted_runtime_context!(memory) do
    offenders = collect_persisted_runtime_context(memory)
    assert offenders == []
  end

  defp collect_persisted_runtime_context(value) do
    do_collect_persisted_runtime_context(value, MapSet.new(), [])
    |> Enum.reverse()
  end

  defp do_collect_persisted_runtime_context(%EvalContext{}, _seen, offenders) do
    [:eval_context | offenders]
  end

  defp do_collect_persisted_runtime_context(
         %RuntimeCallable{eval_ctx: %EvalContext{}} = callable,
         seen,
         offenders
       ) do
    callable
    |> Map.from_struct()
    |> do_collect_persisted_runtime_context(seen, [:bound_runtime_callable | offenders])
  end

  defp do_collect_persisted_runtime_context(
         %RuntimeCallable{do_eval: do_eval} = callable,
         seen,
         offenders
       )
       when is_function(do_eval) do
    callable
    |> Map.from_struct()
    |> do_collect_persisted_runtime_context(seen, [:callable_with_do_eval | offenders])
  end

  defp do_collect_persisted_runtime_context(%RuntimeCallable{}, _seen, offenders), do: offenders

  defp do_collect_persisted_runtime_context(tuple, seen, offenders) when is_tuple(tuple) do
    id = {:tuple, :erlang.phash2(tuple)}

    if MapSet.member?(seen, id) do
      offenders
    else
      tuple
      |> Tuple.to_list()
      |> Enum.reduce(
        offenders,
        &do_collect_persisted_runtime_context(&1, MapSet.put(seen, id), &2)
      )
    end
  end

  defp do_collect_persisted_runtime_context(values, seen, offenders) when is_list(values) do
    Enum.reduce(values, offenders, &do_collect_persisted_runtime_context(&1, seen, &2))
  end

  defp do_collect_persisted_runtime_context(%MapSet{} = set, seen, offenders) do
    set
    |> MapSet.to_list()
    |> do_collect_persisted_runtime_context(seen, offenders)
  end

  defp do_collect_persisted_runtime_context(map, seen, offenders) when is_map(map) do
    id = {:map, :erlang.phash2(map)}

    if MapSet.member?(seen, id) do
      offenders
    else
      map
      |> Map.to_list()
      |> Enum.reduce(
        offenders,
        &do_collect_persisted_runtime_context(&1, MapSet.put(seen, id), &2)
      )
    end
  end

  defp do_collect_persisted_runtime_context(_value, _seen, offenders), do: offenders

  describe "analysis" do
    test "tool namespace symbols in value position lower to runtime callables" do
      raw = {:list, [{:symbol, :map}, {:ns_symbol, :tool, :echo}, {:symbol, :calls}]}

      assert {:ok, {:call, {:var, :map}, [{:runtime_callable, :tool, :echo}, {:var, :calls}]}} =
               Analyze.analyze(raw)
    end

    test "catalog namespace symbols in value position lower to runtime callables" do
      raw = {:list, [{:symbol, :map}, {:ns_symbol, :catalog, :"search-tools"}, {:symbol, :qs}]}

      assert {:ok,
              {:call, {:var, :map}, [{:runtime_callable, :catalog, :"search-tools"}, {:var, :qs}]}} =
               Analyze.analyze(raw)
    end
  end

  describe "tool runtime callables" do
    test "map can invoke a bare tool callable" do
      clear_runtime_callable_process_state!()

      tools = %{
        "echo" => fn args -> args["text"] end
      }

      source = ~S|(map tool/echo [{:text "a"} {:text "b"}])|

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == ["a", "b"]
      assert Enum.map(step.tool_calls, & &1.args) == [%{"text" => "a"}, %{"text" => "b"}]
      assert_runtime_callable_process_state_clean()
    end

    test "indirect invocation is equivalent to direct tool call" do
      tools = %{
        "echo" => fn args -> args end
      }

      assert {:ok, direct} = Lisp.run(~S|(tool/echo :x 1)|, tools: tools)
      assert {:ok, indirect} = Lisp.run(~S|((identity tool/echo) :x 1)|, tools: tools)

      assert indirect.return == direct.return
      assert Enum.map(indirect.tool_calls, & &1.args) == Enum.map(direct.tool_calls, & &1.args)
    end

    test "def can use a runtime callable during the same turn but it is not persisted" do
      tools = %{
        "echo" => fn args -> args["text"] end
      }

      source = ~S"""
      (def f tool/echo)
      (f {:text "ok"})
      """

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == "ok"
      refute Map.has_key?(step.memory, "f")
    end

    test "runtime callable map participates in tool caching" do
      calls = :counters.new(1, [:atomics])

      tools = %{
        "cached" =>
          {fn args ->
             :counters.add(calls, 1, 1)
             args["x"] * 10
           end, signature: "(x :int) -> :int", cache: true}
      }

      source = ~S|(map tool/cached [{:x 1} {:x 1}])|

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == [10, 10]
      assert :counters.get(calls, 1) == 1
      assert Enum.map(step.tool_calls, &Map.get(&1, :cached, false)) == [false, true]
    end

    test "runtime callable map enforces max_tool_calls across invocations" do
      tools = %{
        "echo" => fn args -> args end
      }

      source = ~S|(map tool/echo [{:x 1} {:x 2}])|

      assert {:error, step} = Lisp.run(source, tools: tools, max_tool_calls: 1)
      assert step.fail.reason == :tool_call_limit_exceeded
      assert step.fail.message =~ "tool_call_limit_exceeded"
    end

    test "saved runtime callable HOF invocation uses call-time max_tool_calls state" do
      tools = %{
        "echo" => fn args -> args end
      }

      source = ~S"""
      (def g tool/echo)
      (tool/echo {:x 0})
      (map g [{:x 1}])
      """

      assert {:error, step} = Lisp.run(source, tools: tools, max_tool_calls: 1)
      assert step.fail.reason == :tool_call_limit_exceeded
    end

    test "saved runtime callable HOF invocation uses call-time cache state" do
      calls = :counters.new(1, [:atomics])

      tools = %{
        "cached" =>
          {fn args ->
             :counters.add(calls, 1, 1)
             args["x"] * 10
           end, signature: "(x :int) -> :int", cache: true}
      }

      source = ~S"""
      (def g tool/cached)
      (tool/cached {:x 1})
      (map g [{:x 1}])
      """

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == [10]
      assert :counters.get(calls, 1) == 1
      assert Enum.map(step.tool_calls, &Map.get(&1, :cached, false)) == [false, true]
    end

    test "runtime callable HOF side effects do not duplicate prior tool calls" do
      tools = %{
        "echo" => fn args -> args["x"] end
      }

      source = ~S"""
      (tool/echo {:x 0})
      (map tool/echo [{:x 1} {:x 2}])
      """

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == [1, 2]
      assert Enum.map(step.tool_calls, & &1.args["x"]) == [0, 1, 2]
    end

    test "unknown runtime tool callable is caught by tool preflight" do
      clear_runtime_callable_process_state!()

      tools = %{"other" => fn args -> args end}

      assert {:error, step} = Lisp.run(~S|(map tool/missing [{}])|, tools: tools)
      assert step.fail.reason == :unknown_tool
      assert step.fail.message =~ "Unknown tool: missing"
      assert_runtime_callable_process_state_clean()
    end

    test "runtime callable captured in persisted closure uses next run tool context" do
      tools = %{
        "echo" => fn args -> args["x"] end
      }

      source = ~S"""
      (def f
        (let [g tool/echo]
          (fn [xs] (map g xs))))
      """

      assert {:ok, first} = Lisp.run(source, tools: tools)
      assert_no_persisted_runtime_context!(first.memory)

      assert {:error, second} = Lisp.run(~S|(f [{:x 7}])|, memory: first.memory, tools: %{})

      assert second.fail.reason == :unknown_tool
      assert second.fail.message =~ "Unknown tool: echo"
    end

    test "runtime callable captured by persisted comp uses next run tool context" do
      tools = %{
        "echo" => fn args -> args["x"] end
      }

      assert {:ok, first} = Lisp.run(~S|(def f (comp tool/echo identity))|, tools: tools)
      assert Map.has_key?(first.memory, "f")
      assert_no_persisted_runtime_context!(first.memory)

      assert {:error, second} = Lisp.run(~S|(f {:x 7})|, memory: first.memory, tools: %{})

      assert second.fail.reason == :unknown_tool
      assert second.fail.message =~ "Unknown tool: echo"
    end

    test "runtime callable captured by comp still works in same run" do
      clear_runtime_callable_process_state!()

      tools = %{
        "echo" => fn args -> args["x"] end
      }

      source = ~S"""
      (def f (comp tool/echo identity))
      (f {:x 7})
      """

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert step.return == 7
      assert Enum.map(step.tool_calls, & &1.args["x"]) == [7]
      assert_runtime_callable_process_state_clean()
    end

    test "runtime callable combinators do not persist bound evaluator state" do
      tools = %{
        "echo" => fn args -> args["x"] end,
        "check" => fn args -> args["x"] > 0 end
      }

      programs = [
        ~S|(def f (let [g tool/echo] (fn [xs] (map g xs))))|,
        ~S|(def f (comp tool/echo identity))|,
        ~S|(def f (partial tool/echo))|,
        ~S|(def f (complement tool/check))|
      ]

      for source <- programs do
        assert {:ok, step} = Lisp.run(source, tools: tools)
        assert_no_persisted_runtime_context!(step.memory)
      end
    end

    test "callable-heavy persisted memory stays compact" do
      tools = %{
        "echo" => fn args -> args["x"] end,
        "check" => fn args -> args["x"] > 0 end
      }

      source = ~S"""
      (def f1 (let [g tool/echo] (fn [xs] (map g xs))))
      (def f2 (comp tool/echo identity))
      (def f3 (partial tool/echo))
      (def f4 (complement tool/check))
      """

      assert {:ok, step} = Lisp.run(source, tools: tools)
      assert_no_persisted_runtime_context!(step.memory)
      assert :erlang.external_size(step.memory) < 50_000
    end
  end

  describe "catalog runtime callables" do
    test "map can invoke catalog/search-tools" do
      catalog_exec = fn
        :search_tools, [query] -> {:ok, [%{query: query}]}
      end

      source = ~S|(map catalog/search-tools ["calendar" "gmail"])|

      assert {:ok, step} = Lisp.run(source, catalog_exec: catalog_exec)
      assert step.return == [[%{query: "calendar"}], [%{query: "gmail"}]]
      assert Enum.map(step.catalog_ops, & &1.operation) == [:search_tools, :search_tools]
    end
  end
end
