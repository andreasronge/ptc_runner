defmodule PtcRunner.Lisp.ParallelEffectsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  test "successful pmap workers preserve tool calls, prints, and cache entries" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "echo" =>
        {fn arguments ->
           :atomics.add(provider_calls, 1, 1)
           arguments
         end, signature: "(x :int) -> :map", cache: true}
    }

    source = """
    (do
      (pmap (fn [x] (do (println x) (tool/echo {"x" x}))) [1 2])
      (tool/echo {"x" 1}))
    """

    assert {:ok, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.return == %{"x" => 1}
    assert Enum.sort(step.prints) == ["1", "2"]
    assert Enum.sort(Enum.map(step.tool_calls, & &1.args["x"])) == [1, 1, 2]
    assert Enum.count(step.tool_calls, &Map.get(&1, :cached, false)) == 1
    assert map_size(step.tool_cache) == 2
    assert :atomics.get(provider_calls, 1) == 2
  end

  test "successful pcalls workers preserve tool, print, and nested parallel effects" do
    tools = %{"echo" => {fn arguments -> arguments end, "(x :int) -> :map"}}

    source = """
    (pcalls
      (fn [] (do (println "called") (tool/echo {"x" 1})))
      (fn [] (pmap inc [1 2])))
    """

    assert {:ok, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 2)

    assert step.return == [%{"x" => 1}, [2, 3]]
    assert step.prints == ["called"]
    assert [%{args: %{"x" => 1}}] = step.tool_calls
    assert Enum.sort(Enum.map(step.pmap_calls, & &1.type)) == [:pcalls, :pmap]
  end

  test "pmap shares max_tool_calls across workers and retains the completed call" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "touch" => fn arguments ->
        :atomics.add(provider_calls, 1, 1)
        arguments
      end
    }

    source = ~S|(pmap (fn [x] (tool/touch {"x" x})) [1 2])|

    assert {:error, step} =
             Lisp.run(source,
               tools: tools,
               max_tool_calls: 1,
               pmap_max_concurrency: 1
             )

    assert step.fail.reason == :pmap_error
    assert step.fail.message =~ "tool_call_limit_exceeded"
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
    assert :atomics.get(provider_calls, 1) == 1
  end

  test "pcalls shares max_tool_calls across workers and retains the completed call" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "touch" => fn arguments ->
        :atomics.add(provider_calls, 1, 1)
        arguments
      end
    }

    source = ~S"""
    (pcalls
      (fn [] (tool/touch {"x" 1}))
      (fn [] (tool/touch {"x" 2})))
    """

    assert {:error, step} =
             Lisp.run(source,
               tools: tools,
               max_tool_calls: 1,
               pmap_max_concurrency: 1
             )

    assert step.fail.reason == :pcalls_error
    assert step.fail.message =~ "tool_call_limit_exceeded"
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
    assert :atomics.get(provider_calls, 1) == 1
  end

  test "concurrent pmap workers reserve max_tool_calls atomically" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "touch" => fn arguments ->
        :atomics.add(provider_calls, 1, 1)
        arguments
      end
    }

    source = ~S|(pmap (fn [x] (tool/touch {"x" x})) [1 2 3 4])|

    assert {:error, step} =
             Lisp.run(source,
               tools: tools,
               max_tool_calls: 1,
               pmap_max_concurrency: 4
             )

    assert step.fail.message =~ "tool_call_limit_exceeded"
    assert :atomics.get(provider_calls, 1) == 1
  end

  test "nested parallel calls share the program-wide max_tool_calls budget" do
    provider_calls = :atomics.new(1, [])

    tools = %{
      "touch" => fn arguments ->
        :atomics.add(provider_calls, 1, 1)
        arguments
      end
    }

    source = ~S|(pmap (fn [xs] (pmap (fn [x] (tool/touch {"x" x})) xs)) [[1 2]])|

    assert {:error, step} =
             Lisp.run(source,
               tools: tools,
               max_tool_calls: 1,
               pmap_max_concurrency: 1
             )

    assert step.fail.message =~ "tool_call_limit_exceeded"
    assert :atomics.get(provider_calls, 1) == 1
  end

  test "nested capacity failure records every post-scheduling non-success" do
    source = ~S|(pmap (fn [_] (pmap inc [1 2])) [0])|

    assert {:error, step} =
             Lisp.run(source,
               max_parallel_workers: 1,
               pmap_max_concurrency: 1
             )

    assert step.fail.reason == :parallel_capacity_exceeded

    assert [inner, outer] = step.pmap_calls
    assert %{type: :pmap, count: 2, success_count: 0, error_count: 2} = inner
    assert %{type: :pmap, count: 1, success_count: 0, error_count: 1} = outer
  end

  test "generic pmap failure retains completed worker audit effects" do
    tools = %{"touch" => fn arguments -> arguments end}

    source = ~S"""
    (pmap
      (fn [x]
        (if (= x 1)
          (do (println "completed") (tool/touch {"x" x}))
          (inc "bad")))
      [1 2])
    """

    assert {:error, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.fail.reason == :pmap_error
    assert step.prints == ["completed"]
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
  end

  test "generic pcalls failure retains completed worker audit effects" do
    tools = %{"touch" => fn arguments -> arguments end}

    source = ~S"""
    (pcalls
      (fn [] (do (println "completed") (tool/touch {"x" 1})))
      (fn [] (inc "bad")))
    """

    assert {:error, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.fail.reason == :pcalls_error
    assert step.prints == ["completed"]
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
  end

  test "lower-index failure preserves input-order effects and higher-index cache precedence" do
    coordinator = spawn_link(fn -> coordinate_parallel_release(nil, false) end)

    tools = %{
      "cache" =>
        {fn _arguments -> inspect(self()) end, signature: "(key :int) -> :string", cache: true},
      "wait" => fn _arguments ->
        send(coordinator, {:wait, self()})

        receive do
          :go -> inspect(self())
        end
      end,
      "release" => fn _arguments ->
        send(coordinator, {:release_on_down, self()})
        inspect(self())
      end
    }

    source = ~S"""
    (pmap
      (fn [x]
        (let [cached (tool/cache {"key" 1})]
          (if (= x 0)
            (do (tool/wait {"x" x}) (inc "bad"))
            (do (tool/release {"x" x}) cached))))
      [0 1])
    """

    assert {:error, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 2)

    [lower_cache, higher_cache] = Enum.filter(step.tool_calls, &(&1.name == "cache"))
    wait_call = Enum.find(step.tool_calls, &(&1.name == "wait"))
    release_call = Enum.find(step.tool_calls, &(&1.name == "release"))

    assert lower_cache.result == wait_call.result
    assert higher_cache.result == release_call.result
    assert [%{result: cached_result}] = Map.values(step.tool_cache)
    assert cached_result == higher_cache.result
  end

  test "generic pmap failure retains effects from the failing worker itself" do
    tools = %{"touch" => fn arguments -> arguments end}

    source = ~S"""
    (pmap
      (fn [x]
        (do
          (println "before failure")
          (tool/touch {"x" x})
          (inc "bad")))
      [1])
    """

    assert {:error, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.fail.reason == :pmap_error
    assert step.prints == ["before failure"]
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
  end

  test "failed pmap records every retained child including the failing worker" do
    tools = %{
      "child" => fn %{"x" => x} ->
        child_step = %PtcRunner.Lisp.Result{return: x, trace_id: "child-#{x}"}

        %{
          __child_trace_id__: "child-#{x}",
          __child_step__: child_step,
          value: x
        }
      end
    }

    source = ~S"""
    (pmap
      (fn [x]
        (do
          (tool/child {"x" x})
          (if (= x 1) x (inc "bad"))))
      [1 2])
    """

    assert {:error, step} =
             Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert [call] = step.pmap_calls
    assert call.type == :pmap
    assert call.count == 2
    assert call.success_count == 1
    assert call.error_count == 1
    assert call.child_trace_ids == ["child-1", "child-2"]

    assert step.child_steps |> Enum.map(& &1.trace_id) |> Enum.frequencies() == %{
             "child-1" => 2,
             "child-2" => 2
           }
  end

  test "generic pcalls failure retains effects from the failing worker itself" do
    tools = %{"touch" => fn arguments -> arguments end}

    source = ~S"""
    (pcalls
      (fn []
        (do
          (println "before failure")
          (tool/touch {"x" 1})
          (inc "bad"))))
    """

    assert {:error, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.fail.reason == :pcalls_error
    assert step.prints == ["before failure"]
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
  end

  test "failed pcalls records every retained child including the failing worker" do
    tools = %{
      "child" => fn %{"x" => x} ->
        child_step = %PtcRunner.Lisp.Result{return: x, trace_id: "child-#{x}"}

        %{
          __child_trace_id__: "child-#{x}",
          __child_step__: child_step,
          value: x
        }
      end
    }

    source = ~S"""
    (pcalls
      (fn [] (tool/child {"x" 1}))
      (fn [] (do (tool/child {"x" 2}) (inc "bad"))))
    """

    assert {:error, step} =
             Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert [call] = step.pmap_calls
    assert call.type == :pcalls
    assert call.count == 2
    assert call.success_count == 1
    assert call.error_count == 1
    assert call.child_trace_ids == ["child-1", "child-2"]
  end

  test "pmap return signal retains effects from the failing worker" do
    tools = %{"touch" => fn arguments -> arguments end}
    source = ~S|(pmap (fn [x] (do (tool/touch {"x" x}) (return x))) [1])|

    assert {:error, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.fail.reason == :pmap_error
    assert step.fail.message =~ "return called inside pmap"
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
  end

  test "pcalls fail signal retains effects from the failing worker" do
    tools = %{"touch" => fn arguments -> arguments end}
    source = ~S|(pcalls (fn [] (do (tool/touch {"x" 1}) (fail "bad"))))|

    assert {:error, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.fail.reason == :pcalls_error
    assert step.fail.message =~ "fail called inside pcalls"
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
  end

  test "nested parallel failure retains effects from earlier ordinary HOF iterations" do
    tools = %{"touch" => fn arguments -> arguments end}

    source = ~S"""
    (map
      (fn [x]
        (if (= x 1)
          (do (println "completed") (tool/touch {"x" x}))
          (pmap (fn [_] (inc "bad")) [0])))
      [1 2])
    """

    assert {:error, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)

    assert step.fail.reason == :pmap_error
    assert step.prints == ["completed"]
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1]
  end

  defp coordinate_parallel_release(waiter, released?) do
    receive do
      {:wait, pid} ->
        if released? do
          send(pid, :go)
        else
          coordinate_parallel_release(pid, false)
        end

      {:release_on_down, pid} ->
        Process.monitor(pid)
        coordinate_parallel_release(waiter, released?)

      {:DOWN, _ref, :process, _pid, _reason} ->
        if waiter do
          send(waiter, :go)
        else
          coordinate_parallel_release(nil, true)
        end
    end
  end
end
