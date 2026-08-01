defmodule PtcRunner.KernelTurnLoopSoakTest do
  @moduledoc """
  Soak test: a long-lived mission continuation driven for many turns.

  The other soak tests drive `Lisp.run/2` and watch the *host* process. This
  one drives the Kernel's own long-lived state — one `RunState` carrying
  continuation memory, history, and counters across every turn of an agent
  loop, the way a real run accumulates it. The sandbox process is reaped each
  turn; `RunState` is not.

  What only this file can see: the system-wide signals. Each turn compiles a
  *distinct* program with distinct symbols and string literals, so an atom
  interned per turn, a process left behind per turn, or a refc binary pinned
  per turn shows up here and nowhere else. `mix test`'s async suite makes those
  measurements meaningless, which is why the per-turn continuation assertions
  live in `test/ptc_runner/kernel/multi_turn_continuation_test.exs` and run on
  every commit, while this one runs alone and long.

  Baseline at 1,000 turns (2026-08-01, OTP 29): continuation 196 -> 199 bytes,
  history pinned at depth 3, atom count exactly flat, process count flat.

  ## Run

      mix test --only soak test/soak/kernel_turn_loop_soak_test.exs

      PTC_SOAK_ITERATIONS=10000 \\
        mix test --only soak test/soak/kernel_turn_loop_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.TestSupport.MemorySoak

  @moduletag :soak
  @moduletag timeout: :infinity

  # Explicit so the evaluation budget below can account for it.
  @warmup 10

  setup do
    {:ok, iters: MemorySoak.iteration_count()}
  end

  test "one continuation stays flat across many turns", %{iters: iters} do
    {state, environment} = session(iters)

    turn = fn label, index ->
      source = """
      (do (tool/echo {"turn" #{index}})
          (let [rows (map (fn [n] {"i" n "tag" (str "#{label}-#{index}-" n)}) (range 0 50))]
            (count rows)))
      """

      result = Evaluation.evaluate_source_detailed(state, environment, source, 5_000)
      assert result.outcome == :continued, inspect(result)
      assert result.value == 50
    end

    {before, mid, aft} =
      MemorySoak.measure3(iters, [warmup: @warmup], fn {phase, index} ->
        turn.(phase, index)
      end)

    MemorySoak.gc_everywhere()

    IO.puts("before:\n" <> MemorySoak.format(before))
    IO.puts("after:\n" <> MemorySoak.format(aft))

    # Atoms never GC, so a per-turn intern is unbounded by construction: each
    # turn compiles distinct symbols and string literals, and none may become
    # an atom. The rate is what matters, not the total — the first measured
    # turn interns a fixed ~75 atoms of lazily loaded modules whatever the
    # turn count (verified flat at 200, 400, and 800 turns), and `measure3`
    # excludes exactly that from the rate.
    MemorySoak.assert_atoms_per_iter_strict!(before, mid, aft, iters, max_per_iter: 0.0)

    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 10)
    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 10)

    assert aft.procs <= before.procs,
           "process count grew #{before.procs} -> #{aft.procs} across #{iters} turns"

    summary = RunState.evaluation_memory_summary(state)
    assert summary.defined_count == 0
    assert summary.history_count == 3
  end

  defp session(iters) do
    budget = (iters + @warmup + 16) * 4

    {:ok, limits} =
      Limits.new(
        run_duration_ms: 86_400_000,
        subordinate_evaluations: budget,
        mission_capability_calls: budget,
        mission_capability_calls_per_name: budget
      )

    {:ok, state} = RunState.start(limits)

    {:ok, capability} =
      Capability.new(
        name: "echo",
        input_schema: %{"type" => "object", "additionalProperties" => true},
        effect: :read,
        callback: fn arguments -> {:ok, %{"seen" => map_size(arguments)}} end
      )

    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])

    {state, environment}
  end
end
