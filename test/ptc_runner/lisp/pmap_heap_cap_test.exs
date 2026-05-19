defmodule PtcRunner.Lisp.PmapHeapCapTest do
  @moduledoc """
  Security regression tests for finding H1 (issue #987).

  `max_heap_size` is a *spawn-time* BEAM option, so it can only bound a
  worker if the worker is created with it. `Task.async_stream` creates
  the worker process itself, so the captured closure (e.g. a large `let`
  binding) lands on an uncapped heap before any worker line runs — a
  setting applied from inside the worker body is too late.

  The fix replaces `Task.async_stream` in the `pmap`/`pcalls` paths with
  `PtcRunner.Lisp.Eval.ParallelRunner`, which spawns every worker with a
  FIXED `max_heap_size` creation option already in force, and bounds the
  number of workers alive at once — at every nesting depth — with a
  shared `PtcRunner.Lisp.Eval.ParallelBudget` slot semaphore. A worker
  that exceeds its per-worker heap cap is killed (`:memory_exceeded`); a
  run that cannot get a worker slot fails closed
  (`:parallel_capacity_exceeded`). Aggregate live parallel heap is
  bounded by `max_parallel_workers × worker_max_heap`.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  # Per-worker heap cap (in words) so a worker allocating a large list
  # blows the FIXED `worker_max_heap` (which defaults to `:max_heap`).
  # With a generous timeout the run cannot pass by timing out instead —
  # it must be the heap limit doing the work.
  @small_max_heap 200_000
  @generous_timeout 5_000

  # A per-element function that allocates a large list — far more than
  # the @small_max_heap per-worker cap.
  @big_alloc_fn "(fn [x] (count (vec (range 0 500000))))"

  describe "pmap worker heap cap (H1)" do
    test "worker allocating past its per-worker budget fails with :memory_exceeded" do
      program = "(pmap #{@big_alloc_fn} [1 2 3 4])"

      assert {:error, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 4
               )

      # Deterministic now that ParallelRunner classifies a `:killed`
      # worker exit as `:memory_exceeded`.
      assert step.fail.reason == :memory_exceeded
    end

    test "pcalls thunk allocating past its budget fails with :memory_exceeded" do
      program =
        "(pcalls (fn [] (count (vec (range 0 500000)))) " <>
          "(fn [] (count (vec (range 0 500000)))))"

      assert {:error, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 4
               )

      assert step.fail.reason == :memory_exceeded
    end

    test "pmap worker accounts for shared binary memory" do
      tools = %{
        "big-binary" => fn _ -> String.duplicate("x", 20_000_000) end
      }

      assert {:error, step} =
               Lisp.run("(pmap (fn [_] (count (tool/big-binary {}))) [1])",
                 tools: tools,
                 max_heap: @small_max_heap,
                 worker_max_heap: 1_000,
                 timeout: @generous_timeout
               )

      assert step.fail.reason == :memory_exceeded
    end

    test "pcalls worker accounts for shared binary memory" do
      tools = %{
        "big-binary" => fn _ -> String.duplicate("x", 20_000_000) end
      }

      assert {:error, step} =
               Lisp.run("(pcalls (fn [] (count (tool/big-binary {}))))",
                 tools: tools,
                 max_heap: @small_max_heap,
                 worker_max_heap: 1_000,
                 timeout: @generous_timeout
               )

      assert step.fail.reason == :memory_exceeded
    end

    test "closure-copy pressure: a large captured env is capped at worker birth" do
      # Codex's exact repro. `xs` is a large vector bound by an enclosing
      # `let`; the pmap closure `(fn [_] (count xs))` captures it. Each
      # worker therefore receives a copy of `xs` on its heap *before* its
      # body runs. Under `Task.async_stream` the copy landed on an
      # uncapped heap (bypass). With ParallelRunner the worker is spawned
      # with `max_heap_size` already set, so the oversized closure copy
      # is killed at birth.
      #
      # `xs` = range 0 400000 (multi-MB) vs a per-worker budget of
      # `200_000 / min(32, 4) = 50_000` words.
      program = "(let [xs (vec (range 0 400000))] (pmap (fn [_] (count xs)) (range 0 32)))"

      assert {:error, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 4
               )

      assert step.fail.reason == :memory_exceeded
    end

    test "nested pmap inside a pmap worker also heap-caps its inner workers" do
      program = "(pmap (fn [x] (pmap #{@big_alloc_fn} [1 2])) [1 2])"

      assert {:error, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 4
               )

      assert step.fail.reason == :memory_exceeded
    end

    test "nested pcalls inside a pmap worker also heap-caps its inner workers" do
      program =
        "(pmap (fn [x] (pcalls (fn [] (count (vec (range 0 500000)))))) [1 2])"

      assert {:error, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 4
               )

      assert step.fail.reason == :memory_exceeded
    end

    test "a regular HOF wrapping a heap-exceeding pmap fails with :memory_exceeded" do
      # Round-5 P2-a regression. `map` is a regular HOF — its apply path
      # rescues closure errors. The closure runs a nested `pmap` whose
      # workers blow the heap budget. The nested heap kill is raised as
      # an ExecutionError; the HOF apply path must surface its stable
      # `:memory_exceeded` reason rather than let it crash the sandbox
      # as a generic `:execution_error`.
      program = "(map (fn [_] (pmap #{@big_alloc_fn} [1 2 3 4])) [1 2])"

      assert {:error, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 4
               )

      assert step.fail.reason == :memory_exceeded
    end

    test "a regular HOF wrapping a heap-exceeding pcalls fails with :memory_exceeded" do
      # Same as above for `filter` + nested `pcalls`.
      program =
        "(filter (fn [_] (pcalls (fn [] (count (vec (range 0 500000)))))) [1 2])"

      assert {:error, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 4
               )

      assert step.fail.reason == :memory_exceeded
    end

    test "nested pmap fails with :parallel_capacity_exceeded when the slot budget is small" do
      # Round-7 model: the global worker-slot budget — not heap division
      # — bounds aggregate parallelism. With `max_parallel_workers: 2`,
      # two outer workers fill the budget; their nested pmaps cannot get
      # a slot and fail closed with `:parallel_capacity_exceeded` rather
      # than spawning unbounded nested workers.
      program = "(pmap (fn [x] (pmap (fn [y] (* y 2)) [1 2 3])) [1 2 3])"

      assert {:error, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 max_parallel_workers: 2
               )

      assert step.fail.reason == :parallel_capacity_exceeded
      # The message must render cleanly (round-7 P3 — no garbled
      # "... bytes exceeded" from the numeric-limit formatter).
      assert step.fail.message =~ "parallel worker budget"
      refute step.fail.message =~ "bytes"
    end

    test "nested pmap succeeds when the slot budget is large enough" do
      # Same nesting shape, ample budget — the global cap does not
      # reject legitimate nested parallelism.
      program = "(pmap (fn [x] (pmap (fn [y] (* y 2)) [1 2])) [1 2])"

      assert {:ok, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 max_parallel_workers: 32
               )

      assert step.return == [[2, 4], [2, 4]]
    end

    test "total live parallel workers never exceed max_parallel_workers" do
      # Each worker level observes the live worker count via a
      # tool-backed shared counter; the peak must never exceed the
      # global cap, even with nested pmap at multiple depths.
      {:ok, agent} = start_supervised({Agent, fn -> {0, 0} end})

      tools = %{
        "enter" => fn _ ->
          Agent.update(agent, fn {live, peak} -> {live + 1, max(peak, live + 1)} end)
          Process.sleep(10)
          :ok
        end,
        "leave" => fn _ ->
          Agent.update(agent, fn {live, peak} -> {live - 1, peak} end)
          :ok
        end
      }

      # Outer pmap of 2; each runs an inner pmap of 2. Instrument both
      # levels and assert the run succeeds so the counter proves the
      # cap on a real nested parallel execution rather than only
      # observing a pre-failure subset of inner workers.
      program = """
      (pmap (fn [x]
              (tool/enter {})
              (pmap (fn [y]
                      (tool/enter {})
                      (tool/leave {})
                      y)
                    [1 2])
              (tool/leave {})
              x)
            [1 2])
      """

      assert {:ok, step} =
               Lisp.run(program,
                 tools: tools,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 max_parallel_workers: 6
               )

      assert step.return == [1, 2]

      {_live, peak} = Agent.get(agent, & &1)
      assert peak <= 6
    end
  end

  describe "timeout classification is distinct from memory_exceeded" do
    test "a slow pmap worker yields :timeout, not :memory_exceeded" do
      tools = %{
        "sleep" => fn _ ->
          Process.sleep(50)
          :done
        end
      }

      # Keep the outer sandbox timeout generous and trip the shared
      # pmap deadline directly. Using the outer timeout here makes the
      # assertion depend on scheduler timing rather than ParallelRunner's
      # timeout classification path.
      slow_program = "(pmap (fn [_] (tool/sleep {})) [1 2 3 4])"

      assert {:error, step} =
               Lisp.run(slow_program,
                 tools: tools,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_timeout: 1,
                 pmap_max_concurrency: 4
               )

      assert step.fail.reason == :timeout
    end
  end

  describe "normal pmap/pcalls behavior is unchanged" do
    test "small pmap program runs successfully under a normal heap cap" do
      assert {:ok, step} =
               Lisp.run("(pmap (fn [x] (* x x)) [1 2 3 4 5])",
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout
               )

      assert step.return == [1, 4, 9, 16, 25]
    end

    test "small pcalls program runs successfully under a normal heap cap" do
      assert {:ok, step} =
               Lisp.run("(pcalls (fn [] (+ 1 2)) (fn [] (* 3 4)))",
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout
               )

      assert step.return == [3, 12]
    end

    test "pmap works with the default heap cap" do
      assert {:ok, step} = Lisp.run("(pmap (fn [x] (inc x)) [10 20 30])")
      assert step.return == [11, 21, 31]
    end

    test "pmap preserves input ordering" do
      # Workers finish out of order but results stay aligned to input.
      assert {:ok, step} = Lisp.run("(pmap (fn [x] (* x 10)) [5 1 4 2 3])")
      assert step.return == [50, 10, 40, 20, 30]
    end

    test "single-item pmap gets the full heap budget, not max_heap/concurrency" do
      # P2: the per-worker budget divides by the live worker count (1),
      # not the configured `pmap_max_concurrency` (8).
      program = "(pmap (fn [x] (count (vec (range 0 8000)))) [1])"

      assert {:ok, step} =
               Lisp.run(program,
                 max_heap: @small_max_heap,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 8
               )

      assert step.return == [8000]

      # Contrast: the same program under a heap cap equal to the pre-fix
      # /8 slice genuinely exceeds the budget — proving the program is a
      # real boundary test, not trivially small.
      assert {:error, slice_step} =
               Lisp.run(program,
                 max_heap: 25_000,
                 timeout: @generous_timeout,
                 pmap_max_concurrency: 1
               )

      assert slice_step.fail.reason == :memory_exceeded
    end
  end
end
