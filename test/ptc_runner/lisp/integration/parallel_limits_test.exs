defmodule PtcRunner.Lisp.Integration.ParallelLimitsTest do
  @moduledoc """
  Lisp-level integration tests for pmap/pcalls resource limits.

  These tests prove the user-visible contract through `Lisp.run/2`.
  Lower-level `ParallelRunner` tests still own deterministic OTP race
  cases such as stale EXIT messages, spawn failures, and cancellation
  ordering.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  @timeout 5_000

  defp barrier_tool(target) do
    {:ok, counter} = start_supervised({Agent, fn -> 0 end})

    fn _ ->
      Agent.update(counter, &(&1 + 1))
      wait_until(fn -> Agent.get(counter, & &1) >= target end)
      :ok
    end
  end

  defp wait_until(fun) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun)
    end
  end

  test "pmap worker heap cap is enforced" do
    program = "(pmap (fn [_] (count (vec (range 0 500000)))) [1 2])"

    assert {:error, step} =
             Lisp.run(program,
               max_heap: 200_000,
               worker_max_heap: 50_000,
               timeout: @timeout,
               pmap_max_concurrency: 2
             )

    assert step.fail.reason == :memory_exceeded
  end

  test "pcalls worker heap cap is enforced" do
    program = "(pcalls (fn [] (count (vec (range 0 500000)))))"

    assert {:error, step} =
             Lisp.run(program,
               max_heap: 200_000,
               worker_max_heap: 50_000,
               timeout: @timeout
             )

    assert step.fail.reason == :memory_exceeded
  end

  test "worker_max_heap is independent from a generous sandbox max_heap" do
    program = "(pmap (fn [_] (count (vec (range 0 500000)))) [1])"

    assert {:error, step} =
             Lisp.run(program,
               max_heap: 1_000_000,
               worker_max_heap: 50_000,
               timeout: @timeout
             )

    assert step.fail.reason == :memory_exceeded
  end

  test "captured closure data is capped at worker spawn" do
    program = "(let [xs (vec (range 0 400000))] (pmap (fn [_] (count xs)) [1]))"

    assert {:error, step} =
             Lisp.run(program,
               max_heap: 300_000,
               worker_max_heap: 50_000,
               timeout: @timeout
             )

    assert step.fail.reason == :memory_exceeded
  end

  test "nested parallelism fails closed when global worker budget is exhausted" do
    tools = %{"barrier" => barrier_tool(2)}

    program = """
    (pmap
      (fn [_]
        (tool/barrier {})
        (pmap inc [1 2 3]))
      [1 2])
    """

    assert {:error, step} =
             Lisp.run(program,
               tools: tools,
               max_heap: 200_000,
               worker_max_heap: 200_000,
               max_parallel_workers: 2,
               timeout: @timeout
             )

    assert step.fail.reason == :parallel_capacity_exceeded
  end

  test "nested pcalls fails closed when global worker budget is exhausted" do
    tools = %{"barrier" => barrier_tool(2)}

    program = """
    (pmap
      (fn [_]
        (tool/barrier {})
        (pcalls (fn [] 1) (fn [] 2)))
      [1 2])
    """

    assert {:error, step} =
             Lisp.run(program,
               tools: tools,
               max_heap: 200_000,
               worker_max_heap: 200_000,
               max_parallel_workers: 2,
               timeout: @timeout
             )

    assert step.fail.reason == :parallel_capacity_exceeded
  end

  test "an indirect saved pmap shares the global worker budget" do
    program = ~S"""
    (let [parallel-map pmap]
      (parallel-map
        (fn [_] (parallel-map inc [1 2]))
        [0]))
    """

    assert {:error, step} =
             Lisp.run(program,
               max_heap: 200_000,
               worker_max_heap: 200_000,
               max_parallel_workers: 1,
               pmap_max_concurrency: 1,
               timeout: @timeout
             )

    assert step.fail.reason == :parallel_capacity_exceeded
    assert Enum.map(step.pmap_calls, &{&1.type, &1.count}) == [{:pmap, 2}, {:pmap, 1}]
  end

  test "max_parallel_workers of one still permits a single non-nested pmap" do
    assert {:ok, step} =
             Lisp.run("(pmap inc [1 2 3])",
               max_heap: 200_000,
               worker_max_heap: 200_000,
               max_parallel_workers: 1,
               pmap_max_concurrency: 3,
               timeout: @timeout
             )

    assert step.return == [2, 3, 4]
  end

  test "ordinary parallel programs still succeed under explicit worker limits" do
    assert {:ok, pmap_step} =
             Lisp.run("(pmap (fn [x] (* x x)) [1 2 3 4])",
               max_heap: 200_000,
               worker_max_heap: 200_000,
               max_parallel_workers: 4,
               timeout: @timeout
             )

    assert pmap_step.return == [1, 4, 9, 16]

    assert {:ok, pcalls_step} =
             Lisp.run("(pcalls (fn [] (+ 1 2)) (fn [] (* 3 4)))",
               max_heap: 200_000,
               worker_max_heap: 200_000,
               max_parallel_workers: 4,
               timeout: @timeout
             )

    assert pcalls_step.return == [3, 12]
  end

  test "parallel timeout remains distinct from memory_exceeded" do
    tools = %{
      "sleep" => fn _ ->
        Process.sleep(50)
        :done
      end
    }

    assert {:error, step} =
             Lisp.run("(pmap (fn [_] (tool/sleep {})) [1])",
               tools: tools,
               max_heap: 200_000,
               worker_max_heap: 200_000,
               timeout: @timeout,
               pmap_timeout: 1
             )

    assert step.fail.reason == :timeout
  end

  # The cap is what stops an operation started late in a run from building a
  # deadline past the run's own: a generous pmap_timeout must lose to it.
  test "the absolute parallel deadline cap clamps a generous pmap_timeout" do
    alias PtcRunner.Lisp.Eval.Abort
    alias PtcRunner.Lisp.Eval.Context, as: EvalContext
    alias PtcRunner.Lisp.Eval.Parallel

    context =
      EvalContext.new(%{}, %{}, %{}, fn _name, _args, _meta -> nil end, [],
        pmap_timeout: 60_000,
        parallel_deadline_cap: System.monotonic_time(:millisecond) + 150
      )

    do_eval = fn _ast, ctx -> {:ok, nil, ctx} end
    parked = fn -> receive do: (:never -> :done), after: (30_000 -> :done) end

    started = System.monotonic_time(:millisecond)

    abort =
      assert_raise Abort, fn ->
        Parallel.eval_pcalls([parked], context, do_eval)
      end

    elapsed = System.monotonic_time(:millisecond) - started
    assert {:error, {:timeout, _message, nil}, _context} = abort.outcome
    assert elapsed < 5_000, "cap must fire long before the 60s pmap_timeout, took #{elapsed}ms"
  end

  test "a cap-bound timeout carries the run-deadline taxonomy, not pmap_timeout's" do
    tools = %{"park" => fn _ -> receive do: (:never -> :ok), after: (2_000 -> :ok) end}

    assert {:error, step} =
             Lisp.run("(pcalls (fn [] (tool/park {})))",
               tools: tools,
               timeout: @timeout,
               pmap_timeout: 60_000,
               parallel_deadline_cap: System.monotonic_time(:millisecond) + 200
             )

    assert step.fail.reason == :timeout

    assert String.ends_with?(
             step.fail.message,
             "the run deadline expired during a parallel operation"
           )
  end

  test "an apply-invoked pcalls retains the run deadline cap" do
    tools = %{"park" => fn _ -> receive do: (:never -> :ok), after: (2_000 -> :ok) end}

    assert {:error, step} =
             Lisp.run("(apply pcalls [(fn [] (tool/park {}))])",
               tools: tools,
               timeout: @timeout,
               pmap_timeout: 60_000,
               parallel_deadline_cap: System.monotonic_time(:millisecond) + 200
             )

    assert step.fail.reason == :timeout
    assert step.fail.message =~ "run deadline expired during a parallel operation"
  end

  # The cap must survive both EvalContext reconstructions in Apply: the
  # ordinary closure-call copy and the HOF-value invocation copy. If either
  # dropped it, the parked pcalls would succeed at ~2s instead of timing out
  # at the ~200ms cap.
  for {label, program} <- [
        {"an ordinary closure call", "(do (defn f [] (pcalls (fn [] (tool/park {})))) (f))"},
        {"a HOF callback", "(first (map (fn [_] (pcalls (fn [] (tool/park {}))))  [1]))"}
      ] do
    test "the parallel deadline cap survives #{label}" do
      tools = %{"park" => fn _ -> receive do: (:never -> :ok), after: (2_000 -> :ok) end}

      assert {:error, step} =
               Lisp.run(unquote(program),
                 tools: tools,
                 timeout: @timeout,
                 pmap_timeout: 60_000,
                 parallel_deadline_cap: System.monotonic_time(:millisecond) + 200
               )

      assert step.fail.reason == :timeout
    end
  end
end
