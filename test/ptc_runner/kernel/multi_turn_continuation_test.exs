defmodule PtcRunner.Kernel.MultiTurnContinuationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Multi-turn continuation memory contract.

  A mission continuation is the one long-lived thing in a run: the sandbox
  process is reaped every evaluation, but `RunState` carries memory, history,
  and counters across every turn of an agent loop. Anything that accumulates
  there accumulates for the life of the run.

  These assertions are all **session-local**, which is what lets them run in
  the default async suite. System-wide measurements — `:erlang.memory`, the
  atom table, the process count — are meaningless next to concurrently running
  tests; those live in `test/soak/kernel_turn_loop_soak_test.exs`, which runs
  alone. This file is the part that runs on every `mix test`.

  Turn count is deliberately modest. The invariants asserted here are the ones
  that must hold at *any* turn count, so 100 turns is enough to catch a
  per-turn accumulation; the soak test exists to run the same shape long.

  That definitions accumulate and are bounded by `evaluation_memory_bytes` is
  the continuation's declared job and is covered where that limit is enforced,
  in `core_contract_test.exs` and `repl_session_test.exs`. What is left here is
  what those do not say: that a turn retaining *nothing* costs nothing, and
  that a failed turn costs nothing either.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunState

  @turns 100

  test "stateless turns do not accumulate continuation memory" do
    {state, environment} = session()

    # A turn that defines nothing: calls a capability, returns a value. The
    # continuation has nothing legitimate to retain, so anything it grows by
    # is retention that should have been released.
    turn = fn index ->
      """
      (do (tool/echo {"turn" #{index}})
          (str "result-" #{index}))
      """
    end

    # Saturate history first. Comparing turn 1 against turn 100 would compare
    # a continuation holding one result against one holding three, and read
    # the difference as a leak.
    warmup = 4
    for index <- 1..warmup, do: run_turn(state, environment, turn.(index))
    baseline = RunState.evaluation_memory_summary(state)

    for index <- (warmup + 1)..@turns, do: run_turn(state, environment, turn.(index))

    final = RunState.evaluation_memory_summary(state)
    measured = @turns - warmup

    assert final.defined_count == 0
    assert final.memory_bytes == baseline.memory_bytes

    # History is a fixed depth of three, so its bytes track the three most
    # recent results and never the turn count. Programs differ only by an
    # index, so a few bytes of drift is the index getting wider.
    assert final.history_count == 3
    assert final.history_bytes - baseline.history_bytes < 64

    assert final.bytes - baseline.bytes < 64,
           """
           continuation grew #{final.bytes - baseline.bytes} bytes over \
           #{measured} turns that defined nothing \
           (#{baseline.bytes} -> #{final.bytes}).
           Something is retained across turns that should not be.
           """
  end

  test "a failed turn leaves the continuation exactly as it was" do
    {state, environment} = session()

    run_turn(state, environment, ~s|(def kept 1)|)
    before = RunState.evaluation_memory_summary(state)

    for index <- 1..@turns do
      result =
        Evaluation.evaluate_source_detailed(
          state,
          environment,
          ~s|(do (def dropped-#{index} #{index}) (undefined-function-#{index}))|,
          5_000
        )

      assert result.continuation_effect == :preserved
    end

    assert RunState.evaluation_memory_summary(state) == before
  end

  defp run_turn(state, environment, source) do
    result = Evaluation.evaluate_source_detailed(state, environment, source, 5_000)
    assert result.outcome in [:continued, :returned], inspect(result)
    result
  end

  defp session do
    {:ok, limits} =
      Limits.new(
        run_duration_ms: 600_000,
        subordinate_evaluations: @turns * 4,
        mission_capability_calls: @turns * 4,
        mission_capability_calls_per_name: @turns * 4
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
