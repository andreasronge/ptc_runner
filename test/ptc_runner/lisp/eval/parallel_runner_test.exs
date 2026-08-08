defmodule PtcRunner.Lisp.Eval.ParallelRunnerTest do
  @moduledoc """
  Unit tests for `ParallelRunner` — the heap-capped worker runner that
  replaces `Task.async_stream` in the untrusted pmap/pcalls paths.

  These exercise the runner directly (no Lisp layer) so the lifecycle
  guarantees — heap cap at spawn, ordering, deadline, error
  classification, orphan cleanup — are pinned independently.

  Worker synchronisation uses message passing and monitors (never
  `Process.sleep` as test scaffolding).
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.Effects
  alias PtcRunner.Lisp.Eval.ParallelBudget
  alias PtcRunner.Lisp.Eval.ParallelRunner
  alias PtcRunner.Lisp.Eval.ParallelRunner.Envelope

  # A far-future deadline for tests that should not time out.
  defp far_deadline, do: System.monotonic_time(:millisecond) + 60_000

  defp base_opts(extra \\ []) do
    Keyword.merge(
      [
        worker_max_heap: nil,
        max_concurrency: 4,
        budget: nil,
        deadline_mono: far_deadline(),
        trace_ctx: nil
      ],
      extra
    )
  end

  # Block a worker until the test sends it `:go` (so the test controls
  # completion ordering without sleeps).
  defp wait_for_go do
    receive do
      :go -> :ok
    end
  end

  defp queued_result_spawn_fun(counter) do
    fn worker, opts ->
      runner = self()
      index = :atomics.add_get(counter, 1, 1) - 1

      case index do
        0 ->
          Process.spawn(
            fn ->
              worker.()
              send(runner, :failure_sent)
              wait_for_go()
            end,
            opts
          )

        1 ->
          receive do
            :failure_sent -> :ok
          end

          spawned =
            Process.spawn(
              fn ->
                worker.()
                send(runner, :success_sent)
                wait_for_go()
              end,
              opts
            )

          receive do
            :success_sent -> :ok
          end

          spawned
      end
    end
  end

  defp unwrap_runner_result({:ok, envelopes}) do
    {:ok, Enum.map(envelopes, fn %Envelope{outcome: {:ok, value}} -> value end)}
  end

  defp unwrap_runner_result({:error, envelopes}) do
    %Envelope{index: index, outcome: {:error, reason}} =
      Enum.find(envelopes, &(not Envelope.success?(&1)))

    reason =
      case reason do
        :memory_exceeded -> {:memory_exceeded, index}
        :timeout -> {:timeout, index}
        {:runtime_error, detail} -> {:runtime_error, index, detail}
        other -> other
      end

    {:error, reason}
  end

  describe "basic execution" do
    test "empty input returns {:ok, []}" do
      assert {:ok, []} = ParallelRunner.run([], fn x -> {:ok, x} end, base_opts())
    end

    test "maps fun over items and preserves input ordering" do
      # Each worker announces itself, then waits for an explicit `:go`.
      # The test releases them in REVERSE order; results must still be
      # aligned to the input positions.
      test_pid = self()

      fun = fn item ->
        send(test_pid, {:ready, item, self()})
        wait_for_go()
        {:ok, item}
      end

      parent =
        spawn(fn ->
          result = ParallelRunner.run([:a, :b, :c, :d], fun, base_opts())
          send(test_pid, {:result, unwrap_runner_result(result)})
        end)

      _ref = Process.monitor(parent)

      workers =
        Map.new(
          for _ <- 1..4 do
            assert_receive {:ready, item, pid}
            {item, pid}
          end
        )

      # Release in reverse input order.
      for item <- [:d, :c, :b, :a], do: send(workers[item], :go)

      assert_receive {:result, {:ok, [:a, :b, :c, :d]}}
    end

    test "respects max_concurrency (never more than N workers alive)" do
      # Each worker reports the live count it observed; the peak must
      # not exceed max_concurrency.
      {:ok, agent} = start_supervised({Agent, fn -> {0, 0} end})

      fun = fn _ ->
        Agent.update(agent, fn {live, peak} -> {live + 1, max(peak, live + 1)} end)
        Agent.update(agent, fn {live, peak} -> {live - 1, peak} end)
        {:ok, :done}
      end

      assert {:ok, results} =
               ParallelRunner.run(Enum.to_list(1..12), fun, base_opts(max_concurrency: 3))
               |> unwrap_runner_result()

      assert length(results) == 12
      {_live, peak} = Agent.get(agent, & &1)
      assert peak <= 3
    end

    test "an {:error, _} returned by fun is surfaced verbatim" do
      fun = fn
        2 -> {:error, :boom}
        x -> {:ok, x}
      end

      assert {:error, :boom} =
               ParallelRunner.run([1, 2, 3], fun, base_opts())
               |> unwrap_runner_result()
    end

    test "a failure repeatedly retains a successful result queued before cancellation" do
      fun = fn
        :failure -> {:error, :worker_reason}
        :success -> {:ok, :completed_audit_payload}
      end

      for iteration <- 1..100 do
        counter = :atomics.new(1, [])

        assert {:error,
                [
                  %Envelope{index: 0, outcome: {:error, :worker_reason}},
                  %Envelope{index: 1, outcome: {:ok, :completed_audit_payload}}
                ]} =
                 ParallelRunner.run(
                   [:failure, :success],
                   fun,
                   base_opts(
                     max_concurrency: 2,
                     spawn_fun: queued_result_spawn_fun(counter)
                   )
                 ),
               "iteration #{iteration} dropped or reordered a retained envelope"
      end
    end
  end

  describe "heap cap at spawn time" do
    test "a worker whose work exceeds worker_max_heap is killed -> :memory_exceeded" do
      fun = fn _ ->
        _huge = Enum.to_list(1..2_000_000)
        {:ok, :should_not_reach}
      end

      assert {:error, {:memory_exceeded, 0}} =
               ParallelRunner.run([:a], fun, base_opts(worker_max_heap: 50_000))
               |> unwrap_runner_result()
    end

    test "the cap is in force before the worker body runs (closure copy)" do
      # The captured `big` lands on the worker heap at spawn. With the
      # cap set as a creation option, the oversized closure copy is
      # killed even though the body itself never allocates.
      big = Enum.to_list(1..2_000_000)
      fun = fn _ -> {:ok, length(big)} end

      assert {:error, {:memory_exceeded, 0}} =
               ParallelRunner.run([:a], fun, base_opts(worker_max_heap: 50_000))
               |> unwrap_runner_result()
    end
  end

  describe "spawn failure partway through filling the window" do
    test "a raise mid-fill leaks no worker and no budget slot" do
      # Round-8 P2: the initial `fill_window/1` runs inside `run/3`'s
      # `try ... after`. A spawn that raises after earlier workers in the
      # same fill already spawned + acquired slots must still trigger the
      # kill-all-workers + slot-release cleanup.
      #
      # `:spawn_fun` is a fault-injection seam: it spawns normally for
      # the first 3 workers, then raises on the 4th — simulating a VM
      # process-limit failure partway through the window.
      test_pid = self()
      budget = ParallelBudget.new(8)

      {:ok, counter} = start_supervised({Agent, fn -> 0 end})

      spawn_fun = fn worker, opts ->
        n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        if n >= 4, do: raise("injected spawn failure")
        {pid, ref} = Process.spawn(worker, opts)
        send(test_pid, {:spawned, pid})
        {pid, ref}
      end

      # Workers block forever — so if any survived the cleanup, they
      # would still be alive when we check.
      fun = fn _ -> wait_for_go() end

      opts =
        base_opts(
          budget: budget,
          max_concurrency: 8,
          spawn_fun: spawn_fun
        )

      # `run/3` re-raises the injected failure after its `after`-block
      # cleanup; the caller sees the raise.
      assert_raise RuntimeError, ~r/injected spawn failure/, fn ->
        ParallelRunner.run([:a, :b, :c, :d, :e], fun, opts)
      end

      # The 3 workers that DID spawn before the failure must all be dead
      # — killed by the `after`-block sweep, not orphaned.
      spawned = collect_pids(:spawned, [])
      assert length(spawned) == 3
      refs = Enum.map(spawned, &Process.monitor/1)
      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 1_000)

      # Every acquired budget slot must have been released.
      assert ParallelBudget.held(budget) == 0
    end

    test "a raise on the very first spawn leaks no slot" do
      # The slot for worker 0 is acquired by `fill_window/1` before
      # `spawn_one/2` calls `spawn_fun`; a raise there must still release
      # it (covered by `spawn_one/2`'s own rescue, before any worker is
      # registered for the sweep).
      budget = ParallelBudget.new(4)

      spawn_fun = fn _worker, _opts -> raise "injected immediate failure" end

      assert_raise RuntimeError, ~r/injected immediate failure/, fn ->
        ParallelRunner.run(
          [:a, :b],
          fn _ -> {:ok, :x} end,
          base_opts(budget: budget, spawn_fun: spawn_fun)
        )
      end

      assert ParallelBudget.held(budget) == 0
    end

    test "pending abnormal worker EXIT does not mask a later spawn failure" do
      # Regression: the after-block cleanup used to delete the
      # append-only worker pid set before the final worker-signal drain.
      # If worker 1 had already exited abnormally and worker 2's spawn
      # then raised, the pending `{:EXIT, worker1, :boom}` was
      # misclassified as non-worker cancellation and `run/3` exited
      # :boom, masking the real spawn failure.
      budget = ParallelBudget.new(4)
      {:ok, state} = start_supervised({Agent, fn -> %{count: 0, first_ref: nil} end})

      spawn_fun = fn _worker, opts ->
        {n, first_ref} =
          Agent.get_and_update(state, fn %{count: count, first_ref: first_ref} = state ->
            {{count + 1, first_ref}, %{state | count: count + 1}}
          end)

        if n == 1 do
          {pid, ref} = Process.spawn(fn -> exit(:boom) end, opts)
          Agent.update(state, &%{&1 | first_ref: ref})
          {pid, ref}
        else
          receive do
            {:DOWN, ^first_ref, :process, _pid, :boom} ->
              :ok
          after
            1_000 ->
              raise "first worker did not exit"
          end

          raise "injected spawn failure"
        end
      end

      assert_raise RuntimeError, ~r/injected spawn failure/, fn ->
        ParallelRunner.run(
          [:first, :second],
          fn _ -> {:ok, :unused} end,
          base_opts(budget: budget, max_concurrency: 2, spawn_fun: spawn_fun)
        )
      end

      assert ParallelBudget.held(budget) == 0
    end
  end

  describe "worker lifecycle: slot released on termination, not result (P2-a)" do
    # `:spawn_fun` seam that makes every worker LINGER after it has
    # delivered its `{:worker_result, ...}`: the wrapper runs the real
    # worker fn (which sends the result) and then blocks on a `:release`
    # message before letting the process exit. So between "result
    # delivered" and "process terminated" the worker is provably alive —
    # exactly the window P2-a is about.
    defp lingering_spawn_fun(test_pid) do
      fn worker, opts ->
        wrapped = fn ->
          worker.()
          send(test_pid, {:worker_lingering, self()})

          receive do
            :release -> :ok
          end
        end

        Process.spawn(wrapped, opts)
      end
    end

    test "a completed-but-lingering worker keeps its slot; fill_window cannot exceed the budget" do
      # Budget 2, window 4, 4 items. With P2-a the slot is released only
      # on the worker's `:DOWN` — so while workers 0 and 1 have delivered
      # results but their processes still linger, NO slot is free and
      # `fill_window` cannot start workers 2 and 3. The budget stays
      # fully held; live workers never exceed `max_parallel_workers`.
      #
      # WITHOUT P2-a (slot released on result receipt) `fill_window`
      # would spawn replacements while the lingering workers are still
      # alive — 3+ live at once, breaking the bound.
      test_pid = self()
      budget = ParallelBudget.new(2)

      runner =
        spawn(fn ->
          send(
            test_pid,
            {:result,
             ParallelRunner.run(
               [0, 1, 2, 3],
               fn x -> {:ok, x} end,
               base_opts(
                 budget: budget,
                 max_concurrency: 4,
                 spawn_fun: lingering_spawn_fun(test_pid)
               )
             )
             |> unwrap_runner_result()}
          )
        end)

      _ = Process.monitor(runner)

      # Exactly 2 workers (the budget) reach the lingering point. A 3rd
      # would only appear if a slot were wrongly freed on result receipt.
      first = collect_pids(:worker_lingering, [])
      assert length(first) == 2, "expected exactly 2 lingering workers, got #{length(first)}"

      # Both slots are still held while those 2 workers linger — the run
      # has their results but cannot free capacity until they terminate.
      assert ParallelBudget.held(budget) == 2

      # Release the 2 lingering workers; their `:DOWN` frees the slots,
      # and only THEN do workers 2 and 3 get to run.
      for pid <- first, do: send(pid, :release)

      second = collect_pids(:worker_lingering, [])
      assert length(second) == 2

      # Still never more than `max_parallel_workers` (2) live at once.
      assert ParallelBudget.held(budget) == 2
      for pid <- second, do: send(pid, :release)

      assert_receive {:result, {:ok, [0, 1, 2, 3]}}, 2_000
      assert ParallelBudget.held(budget) == 0
    end
  end

  describe "deadline" do
    test "a received final envelope completes even while its worker is still exiting" do
      runner = self()
      effects = Effects.empty() |> Effects.record_print("completed")

      spawn_fun = fn worker, opts ->
        Process.spawn(
          fn ->
            worker.()
            send(runner, :result_sent)
            wait_for_go()
          end,
          opts
        )
      end

      envelope =
        Envelope.success(:done,
          effects: effects,
          child_trace_id: "completed-child",
          child_step: %{id: "completed-step"}
        )

      deadline = System.monotonic_time(:millisecond) + 50

      assert {:ok, [%Envelope{} = completed]} =
               ParallelRunner.run(
                 [:item],
                 fn :item -> envelope end,
                 base_opts(deadline_mono: deadline, spawn_fun: spawn_fun)
               )

      assert completed == Envelope.attach_index(envelope, 0)
    end

    test "deadline success releases its budget slot only after monitor-confirmed termination" do
      test_pid = self()
      budget = ParallelBudget.new(1)

      spawn_fun = fn worker, opts ->
        Process.spawn(
          fn ->
            worker.()
            wait_for_go()
          end,
          opts
        )
      end

      runner =
        spawn(fn ->
          receive do
            :run ->
              result =
                ParallelRunner.run(
                  [:item],
                  fn :item -> Envelope.success(:done) end,
                  base_opts(
                    budget: budget,
                    deadline_mono: System.monotonic_time(:millisecond) + 50,
                    spawn_fun: spawn_fun
                  )
                )

              send(test_pid, {:deadline_result, result})
          end
        end)

      :erlang.trace(runner, true, [:receive])
      send(runner, :run)

      assert_receive {:trace, ^runner, :receive, {:DOWN, _, :process, _, :killed}}, 1_000
      assert_receive {:deadline_result, {:ok, [%Envelope{outcome: {:ok, :done}}]}}, 1_000
      assert ParallelBudget.held(budget) == 0
    end

    test "timeout retains a successful envelope from a still-live sibling" do
      counter = :atomics.new(1, [])
      effects = Effects.empty() |> Effects.record_print("retained")

      # A monitor-based rendezvous instead of a wall-clock margin: the
      # :blocked worker waits for `gate` to go down (the :success worker
      # stops it right after `worker.()` -- and so its `:worker_result` --
      # has been sent) before it starts genuinely blocking.
      # `Process.monitor/1` delivers an immediate `:DOWN` for an
      # already-dead process, so this is race-free regardless of
      # scheduling. Both waits happen inside the SPAWNED processes, not in
      # `spawn_fun` itself, so neither can block `fill_window/1` and eat
      # into the shared deadline the way the old message-based handshake
      # did.
      #
      # `spawn_fun` (not `fun`) is what keeps the :success worker alive
      # after sending its result via `wait_for_go/0` -- required so its
      # entry is still in `state.live`, tagged with a completed result, when
      # the shared deadline fires for the :blocked sibling. That is the
      # "still-live sibling" this test is named for: without it, the
      # :success worker would exit immediately, its result would already be
      # in `state.results` by the time of the timeout, and this would stop
      # covering the code path it claims to.
      {:ok, gate} = Agent.start_link(fn -> :ok end)

      spawn_fun = fn worker, opts ->
        case :atomics.add_get(counter, 1, 1) - 1 do
          0 ->
            Process.spawn(
              fn ->
                worker.()
                Agent.stop(gate)
                wait_for_go()
              end,
              opts
            )

          1 ->
            Process.spawn(
              fn ->
                gate_ref = Process.monitor(gate)

                receive do
                  {:DOWN, ^gate_ref, :process, ^gate, _reason} -> :ok
                end

                worker.()
              end,
              opts
            )
        end
      end

      fun = fn
        :success ->
          Envelope.success(:done,
            effects: effects,
            child_trace_id: "retained-child",
            child_step: %{id: "retained-step"}
          )

        :blocked ->
          wait_for_go()
      end

      deadline = System.monotonic_time(:millisecond) + 250

      assert {:error,
              [
                %Envelope{
                  index: 0,
                  outcome: {:ok, :done},
                  effects: ^effects,
                  child_trace_id: "retained-child",
                  child_step: %{id: "retained-step"}
                },
                %Envelope{index: 1, outcome: {:error, :timeout}}
              ]} =
               ParallelRunner.run(
                 [:success, :blocked],
                 fun,
                 base_opts(max_concurrency: 2, deadline_mono: deadline, spawn_fun: spawn_fun)
               )
    end

    test "a worker past the shared deadline yields :timeout" do
      # Worker blocks forever (until killed); deadline is in the past.
      fun = fn _ -> wait_for_go() end
      deadline = System.monotonic_time(:millisecond) + 30

      assert {:error, {:timeout, _index}} =
               ParallelRunner.run([:a, :b], fun, base_opts(deadline_mono: deadline))
               |> unwrap_runner_result()
    end

    test "timeout is distinct from memory_exceeded" do
      fun = fn _ -> wait_for_go() end
      deadline = System.monotonic_time(:millisecond) + 30

      assert {:error, {:timeout, _}} =
               ParallelRunner.run([:a], fun, base_opts(deadline_mono: deadline))
               |> unwrap_runner_result()
    end

    test "deadline_passed? gates spawning before vs after the deadline" do
      # Round-6 P2 fix, pinned deterministically. `fill_window/1` calls
      # `deadline_passed?/1` before every spawn; this is the exact
      # branch that stops a worker from starting past the deadline.
      now = System.monotonic_time(:millisecond)

      # Comfortably in the future -> not passed, spawning still allowed.
      refute ParallelRunner.deadline_passed?(now + 60_000)

      # In the past -> passed, no further worker may start.
      assert ParallelRunner.deadline_passed?(now - 1_000)

      # The window/total predicate is independent of the deadline.
      assert ParallelRunner.spawn_next?(0, 4, 0, 4)
      refute ParallelRunner.spawn_next?(4, 4, 0, 4)
      refute ParallelRunner.spawn_next?(0, 4, 4, 4)
    end

    test "an already-expired deadline spawns ZERO workers and returns :timeout" do
      # End-to-end: a nested pmap/pcalls may enter `run/3` with an
      # inherited `deadline_mono` that has already passed. With the
      # round-6 fix `fill_window/1` spawns nothing and `collect/1`
      # returns `:timeout`; no item's `fun` ever runs.
      #
      # Deterministic: the deadline is set in the PAST, so the spawn
      # guard fails on the very first `fill_window/1` evaluation. Each
      # worker, if it were ever spawned and run, would announce itself.
      test_pid = self()

      fun = fn item ->
        send(test_pid, {:worker_started, item})
        {:ok, item}
      end

      expired = System.monotonic_time(:millisecond) - 1_000

      assert {:error, {:timeout, _index}} =
               ParallelRunner.run([:a, :b, :c, :d], fun,
                 worker_max_heap: nil,
                 max_concurrency: 4,
                 deadline_mono: expired,
                 trace_ctx: nil
               )
               |> unwrap_runner_result()

      # No worker's `fun` may have run.
      refute_receive {:worker_started, _}, 100
    end
  end

  describe "error classification" do
    test "an abnormal worker crash maps to :runtime_error" do
      fun = fn _ -> raise "kaboom" end

      assert {:error, {:runtime_error, 0, _reason}} =
               ParallelRunner.run([:a], fun, base_opts())
               |> unwrap_runner_result()
    end
  end

  describe "global worker-slot budget" do
    test "fails closed with :parallel_capacity_exceeded when no slot is free" do
      # Budget pre-exhausted: every slot already held by something else.
      budget = ParallelBudget.new(2)
      assert :ok = ParallelBudget.try_acquire(budget)
      assert :ok = ParallelBudget.try_acquire(budget)

      fun = fn x -> {:ok, x} end

      # The run cannot start a single worker — fail fast, do not block,
      # do not fall back to sequential.
      assert {:error, :parallel_capacity_exceeded} =
               ParallelRunner.run([:a, :b], fun, base_opts(budget: budget))
               |> unwrap_runner_result()
    end

    test "never exceeds capacity, and frees every slot on normal completion" do
      test_pid = self()
      budget = ParallelBudget.new(3)
      {:ok, agent} = start_supervised({Agent, fn -> {0, 0} end})

      fun = fn _ ->
        Agent.update(agent, fn {live, peak} -> {live + 1, max(peak, live + 1)} end)
        send(test_pid, {:worker_ready, self()})
        wait_for_go()
        Agent.update(agent, fn {live, peak} -> {live - 1, peak} end)
        {:ok, :done}
      end

      runner =
        spawn(fn ->
          send(
            test_pid,
            {:result,
             ParallelRunner.run(
               Enum.to_list(1..6),
               fun,
               base_opts(budget: budget, max_concurrency: 10)
             )
             |> unwrap_runner_result()}
          )
        end)

      _ref = Process.monitor(runner)

      first = collect_pids(:worker_ready, [])
      assert length(first) == 3
      for pid <- first, do: send(pid, :go)

      second = collect_pids(:worker_ready, [])
      assert length(second) == 3
      for pid <- second, do: send(pid, :go)

      assert_receive {:result, {:ok, results}}, 2_000

      assert length(results) == 6
      {live, peak} = Agent.get(agent, & &1)
      assert live == 0
      assert peak <= 3
      # Every slot released on normal completion.
      assert ParallelBudget.held(budget) == 0
    end

    test "frees every slot after a worker heap kill" do
      budget = ParallelBudget.new(3)

      fun = fn _ ->
        _huge = Enum.to_list(1..2_000_000)
        {:ok, :unreached}
      end

      assert {:error, {:memory_exceeded, _}} =
               ParallelRunner.run(
                 [:a, :b],
                 fun,
                 base_opts(budget: budget, worker_max_heap: 50_000)
               )
               |> unwrap_runner_result()

      assert ParallelBudget.held(budget) == 0
    end

    test "frees every slot after a deadline timeout" do
      budget = ParallelBudget.new(3)
      fun = fn _ -> wait_for_go() end
      deadline = System.monotonic_time(:millisecond) + 30

      assert {:error, {:timeout, _}} =
               ParallelRunner.run(
                 [:a, :b],
                 fun,
                 base_opts(budget: budget, deadline_mono: deadline)
               )
               |> unwrap_runner_result()

      assert ParallelBudget.held(budget) == 0
    end

    test "frees every slot after parent cancellation" do
      # A `link: true`-style cancellation: kill the runner's caller and
      # assert the shared budget returns to full capacity.
      budget = ParallelBudget.new(3)
      test_pid = self()

      runner_proc =
        spawn(fn ->
          caller = receive(do: ({:caller, c} -> c))
          Process.link(caller)

          fun = fn _ ->
            send(test_pid, {:worker, self()})
            wait_for_go()
          end

          ParallelRunner.run([:a, :b], fun, base_opts(budget: budget))
        end)

      runner_ref = Process.monitor(runner_proc)
      caller = spawn(fn -> wait_for_go() end)
      send(runner_proc, {:caller, caller})

      workers = collect_pids(:worker, [])
      worker_refs = Enum.map(workers, &Process.monitor/1)

      Process.exit(caller, :shutdown)

      assert_receive {:DOWN, ^runner_ref, :process, _, :shutdown}, 1_000
      for ref <- worker_refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 1_000)

      # Every worker slot released despite the abnormal teardown.
      assert ParallelBudget.held(budget) == 0
    end

    test "a worker can spawn a nested run when slots remain (no deadlock)" do
      # The parent worker holds one slot for its whole body; a nested
      # run inside it acquires a second. Try-acquire is non-blocking, so
      # this completes — it does not hang waiting on a slot.
      budget = ParallelBudget.new(2)

      nested_fun = fn x -> {:ok, x * 10} end

      fun = fn _ ->
        # Inside this worker (1 slot held), run a nested operation.
        result =
          ParallelRunner.run([1, 2], nested_fun, base_opts(budget: budget))
          |> unwrap_runner_result()

        {:ok, result}
      end

      assert {:ok, [{:ok, [10, 20]}]} =
               ParallelRunner.run([:outer], fun, base_opts(budget: budget))
               |> unwrap_runner_result()

      assert ParallelBudget.held(budget) == 0
    end

    test "a worker attempting a nested run with no slot fails fast, not hangs" do
      # Capacity 1: the single outer worker holds the only slot. Its
      # nested run cannot get one — it must fail fast with
      # `:parallel_capacity_exceeded`, never block on a slot that can
      # only free when the outer worker itself finishes.
      budget = ParallelBudget.new(1)

      fun = fn _ ->
        nested =
          ParallelRunner.run([1, 2], fn x -> {:ok, x} end, base_opts(budget: budget))
          |> unwrap_runner_result()

        {:ok, nested}
      end

      # The outer worker completes; its `fun` returns the nested run's
      # result verbatim — a fast `{:error, :parallel_capacity_exceeded}`,
      # never a hang.
      assert {:ok, [{:error, :parallel_capacity_exceeded}]} =
               ParallelRunner.run([:outer], fun, base_opts(budget: budget))
               |> unwrap_runner_result()

      assert ParallelBudget.held(budget) == 0
    end
  end

  describe "orphan cleanup" do
    test "a worker failure kills all sibling workers" do
      # Sibling workers announce their pid then block forever. The
      # runner fails fast on worker 0; siblings must be killed.
      test_pid = self()

      fun = fn
        0 ->
          {:error, :fail_fast}

        _ ->
          send(test_pid, {:sibling, self()})
          wait_for_go()
      end

      # Spawn the runner so we can collect sibling pids while it runs.
      runner =
        spawn(fn ->
          result = ParallelRunner.run([0, 1, 2, 3], fun, base_opts())
          send(test_pid, {:result, unwrap_runner_result(result)})
        end)

      _ = Process.monitor(runner)

      # Collect siblings (best-effort: 0 fails fast, up to 3 siblings).
      siblings = collect_pids(:sibling, [])
      refs = Enum.map(siblings, &Process.monitor/1)

      assert_receive {:result, {:error, :fail_fast}}

      # Every sibling must terminate (killed by the runner's cleanup).
      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 1_000)
    end

    test "killing the calling process tears down all live workers (link)" do
      # Workers are linked to the runner's caller. Killing that caller
      # mid-run must take the workers down with it.
      test_pid = self()

      caller =
        spawn(fn ->
          fun = fn _ ->
            send(test_pid, {:worker, self()})
            wait_for_go()
          end

          ParallelRunner.run([:a, :b, :c], fun, base_opts(max_concurrency: 3))
        end)

      workers = collect_pids(:worker, [])
      assert length(workers) == 3
      refs = Enum.map(workers, &Process.monitor/1)

      Process.exit(caller, :kill)

      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 1_000)
    end

    test "an abnormal non-worker EXIT is not swallowed by the temporary trap_exit" do
      # Regression for round-4 P1. `run/3` enables `trap_exit` for the
      # duration of the call. A `link: true` sandbox is linked to its
      # caller; if that caller dies abnormally (with a reason OTHER than
      # `:kill`, so it arrives as a trapped `{:EXIT, _, _}` message
      # rather than an untrappable signal), the runner must NOT treat it
      # as a harmless non-worker exit. It must kill the workers and
      # re-propagate, so the runner (sandbox) process dies too.
      test_pid = self()

      # `runner_proc` stands in for the sandbox process: it links to a
      # `caller` and then runs the parallel operation.
      runner_proc =
        spawn(fn ->
          caller = receive(do: ({:caller, c} -> c))
          Process.link(caller)

          fun = fn _ ->
            send(test_pid, {:worker, self()})
            wait_for_go()
          end

          ParallelRunner.run([:a, :b, :c], fun, base_opts(max_concurrency: 3))
        end)

      runner_ref = Process.monitor(runner_proc)

      # The caller blocks until we kill it.
      caller = spawn(fn -> wait_for_go() end)
      send(runner_proc, {:caller, caller})

      workers = collect_pids(:worker, [])
      assert length(workers) == 3
      worker_refs = Enum.map(workers, &Process.monitor/1)

      # Abnormal exit, NOT :kill — so the runner traps it as a message.
      Process.exit(caller, :shutdown)

      # The runner (sandbox stand-in) must die — its exit reason
      # propagated, not swallowed.
      assert_receive {:DOWN, ^runner_ref, :process, _, :shutdown}, 1_000

      # ...and every worker must be torn down, not orphaned.
      for ref <- worker_refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 1_000)
    end

    test "the finish-path drain re-propagates a non-worker cancellation EXIT" do
      # Regression for round-5 P2-b. The finish-path / `after`-block
      # signal drain previously consumed EVERY `{:EXIT, ...}` message,
      # swallowing a linked caller's cancellation that lands during
      # cleanup. The drain now classifies each EXIT via
      # `classify_drain_exit/3`.
      #
      # The live drain runs in a microsecond window with no external
      # hook, so its decision table is pinned here directly and
      # deterministically. The cases mirror the cond in the drain.
      worker = spawn(fn -> :ok end)
      non_worker = spawn(fn -> :ok end)
      workers = MapSet.new([worker])

      # An EXIT from one of our own workers is drained (consumed).
      assert :drain = ParallelRunner.classify_drain_exit(worker, :killed, workers)
      assert :drain = ParallelRunner.classify_drain_exit(worker, :normal, workers)

      # A `:normal` EXIT from a non-worker is harmless — drained.
      assert :drain = ParallelRunner.classify_drain_exit(non_worker, :normal, workers)

      # An ABNORMAL EXIT from a non-worker is a linked caller's
      # cancellation — it must be re-propagated, NOT swallowed.
      assert {:cancel, :shutdown} =
               ParallelRunner.classify_drain_exit(non_worker, :shutdown, workers)

      assert {:cancel, :some_crash} =
               ParallelRunner.classify_drain_exit(non_worker, :some_crash, workers)
    end

    test "cancellation while the runner runs tears down the runner and workers" do
      # End-to-end companion to the round-4 test: a `link: true` sandbox
      # stand-in is cancelled (abnormally, non-`:kill`) while `run/3` is
      # active. Whichever cleanup path observes it — `handle_exit/3` or
      # the finish-path drain — the cancellation must not be swallowed:
      # the runner dies with the reason and every worker is torn down.
      test_pid = self()

      runner_proc =
        spawn(fn ->
          caller = receive(do: ({:caller, c} -> c))
          Process.link(caller)

          fun = fn _ ->
            send(test_pid, {:worker, self()})
            wait_for_go()
          end

          ParallelRunner.run([:a, :b], fun, base_opts(max_concurrency: 2))
        end)

      runner_ref = Process.monitor(runner_proc)

      caller = spawn(fn -> wait_for_go() end)
      send(runner_proc, {:caller, caller})

      workers = collect_pids(:worker, [])
      assert length(workers) == 2
      worker_refs = Enum.map(workers, &Process.monitor/1)

      Process.exit(caller, :shutdown)

      assert_receive {:DOWN, ^runner_ref, :process, _, :shutdown}, 1_000
      for ref <- worker_refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 1_000)
    end
  end

  describe "concurrency stress" do
    # Round-8: a round-7 combined-suite run had one transient single
    # failure that did not reproduce. Rather than dismiss it, these
    # tight-loop tests hammer the most race-prone paths — slot churn,
    # worker EXIT/DOWN signal interleaving, and ordering under a
    # constrained budget — so any residual race surfaces deterministically
    # here (in CI) instead of as an occasional flake.

    @stress_iterations 300

    test "budget-constrained churn: slots always return to zero, results stay ordered" do
      # `max_concurrency` (10) deliberately exceeds the budget (3): every
      # iteration churns slots — workers complete, free a slot, the next
      # item acquires it — exercising the
      # complete -> drop_worker -> fill_window -> collect path and the
      # trailing {:worker_result}/{:DOWN}/{:EXIT} interleaving.
      for i <- 1..@stress_iterations do
        budget = ParallelBudget.new(3)
        items = Enum.to_list(1..20)

        assert {:ok, results} =
                 ParallelRunner.run(
                   items,
                   fn x -> {:ok, x * 2} end,
                   base_opts(budget: budget, max_concurrency: 10)
                 )
                 |> unwrap_runner_result(),
               "iteration #{i} did not complete cleanly"

        # Input ordering preserved despite out-of-order completion.
        assert results == Enum.map(items, &(&1 * 2)), "iteration #{i}: results out of order"
        # Every slot released — no leak across the churn.
        assert ParallelBudget.held(budget) == 0, "iteration #{i}: slot leak"
      end
    end

    test "heap-kill churn: a killed worker never leaks a slot or orphans a sibling" do
      # Every iteration: one worker heap-kills while siblings run, then
      # the run fails fast and kills the siblings. The killed worker's
      # `{:DOWN, :killed}` / `{:EXIT, :killed}` race the sibling kills
      # and the drain. Slots must always return to zero.
      for i <- 1..@stress_iterations do
        budget = ParallelBudget.new(4)

        fun = fn
          0 -> (fn -> _h = Enum.to_list(1..2_000_000) end).()
          _ -> {:ok, :ran}
        end

        assert {:error, {:memory_exceeded, _}} =
                 ParallelRunner.run(
                   [0, 1, 2, 3],
                   fun,
                   base_opts(budget: budget, worker_max_heap: 50_000, max_concurrency: 4)
                 )
                 |> unwrap_runner_result(),
               "iteration #{i}: expected a heap-kill failure"

        assert ParallelBudget.held(budget) == 0, "iteration #{i}: slot leak after heap kill"
      end
    end

    test "nested-run churn: shared budget always returns to zero" do
      # Every iteration runs nested parallelism on a shared budget that
      # is exercised at two depths; the budget must always settle at 0.
      for i <- 1..@stress_iterations do
        budget = ParallelBudget.new(8)

        nested_fun = fn x -> {:ok, x + 1} end

        fun = fn _ ->
          nested = ParallelRunner.run([1, 2, 3], nested_fun, base_opts(budget: budget))
          {:ok, unwrap_runner_result(nested)}
        end

        assert {:ok, _} =
                 ParallelRunner.run(
                   [:a, :b],
                   fun,
                   base_opts(budget: budget, max_concurrency: 2)
                 )
                 |> unwrap_runner_result(),
               "iteration #{i}: nested run did not complete"

        assert ParallelBudget.held(budget) == 0, "iteration #{i}: shared-budget slot leak"
      end
    end

    test "cancellation racing run/3 teardown is never swallowed (P2-b)" do
      # Round-9 P2-b: a linked caller exiting WHILE `run/3` is running —
      # in particular in the old `drain -> restore trap_exit` window —
      # must not be trapped-into-a-message and dropped.
      #
      # The runner mirrors the REAL sandbox: after `run/3` it does NOT
      # exit — it blocks (`receive`-ing), the way `do_eval` keeps
      # evaluating the rest of the program after a `pmap`. So:
      #
      #   - if `run/3` itself handles the cancellation -> exit :shutdown
      #   - if a cancellation signal is still in flight after `run/3`,
      #     it is delivered against the restored (false) `trap_exit` and
      #     KILLS the still-linked, still-running runner -> exit :shutdown
      #   - ONLY a genuine swallow (cancellation converted to a message
      #     inside `run/3` and dropped) lets the runner survive into its
      #     post-`run/3` `receive` -> it reports `:survived`, the bug.
      #
      # The caller is killed while `run/3` is provably mid-flight (both
      # workers blocked), and the workers are then released so `run/3`
      # races to completion against the cancellation. Repeated under the
      # stress loop to exercise the timing-sensitive interleaving.
      for i <- 1..@stress_iterations do
        test_pid = self()

        runner =
          spawn(fn ->
            caller = receive(do: ({:caller, c} -> c))
            Process.link(caller)
            send(test_pid, :linked)

            fun = fn _item ->
              send(test_pid, {:worker_up, self()})
              receive(do: (:release -> :ok))
              {:ok, :done}
            end

            _ = ParallelRunner.run([1, 2], fun, base_opts(max_concurrency: 2))

            # Mirror the real sandbox continuing to run after the pmap.
            # If we are still alive here, no cancellation killed us and
            # `run/3` did not propagate one — i.e. it was swallowed.
            send(test_pid, :survived_run)
            receive(do: (:never -> :ok))
          end)

        runner_ref = Process.monitor(runner)
        caller = spawn(fn -> receive(do: (:never -> :ok)) end)
        send(runner, {:caller, caller})
        assert_receive :linked, 1_000

        assert_receive {:worker_up, w1}
        assert_receive {:worker_up, w2}

        # Kill the caller WHILE run/3 is in flight, then release the
        # workers so run/3 races to completion against the cancellation.
        Process.exit(caller, :shutdown)
        send(w1, :release)
        send(w2, :release)

        # The runner must die from the cancellation — never survive into
        # its post-`run/3` continuation.
        receive do
          {:DOWN, ^runner_ref, :process, _, reason} ->
            assert reason == :shutdown,
                   "iteration #{i}: P2-b — cancellation surfaced as #{inspect(reason)}"

          :survived_run ->
            flunk(
              "iteration #{i}: P2-b — cancellation swallowed: runner survived `run/3` " <>
                "into its continuation despite its linked caller dying :shutdown mid-run"
            )
        after
          2_000 -> flunk("iteration #{i}: runner neither died nor reported survival")
        end
      end
    end
  end

  # Collect `{tag, pid}` messages until a short quiet period.
  defp collect_pids(tag, acc) do
    receive do
      {^tag, pid} -> collect_pids(tag, [pid | acc])
    after
      300 -> acc
    end
  end
end
