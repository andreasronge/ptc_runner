defmodule PtcRunner.Spike.StatemCapabilitiesTest do
  @moduledoc false

  # Spike evidence for `docs/plans/spikes/gen-statem-owner.md`.
  #
  # Each test pairs a `:gen_statem` capability with what the shipped `GenServer`
  # owner shape does in the same situation.

  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.Spike.EffectLog
  alias PtcRunner.TestSupport.Spike.FlagsOwner
  alias PtcRunner.TestSupport.Spike.StrictOwner

  describe "out-of-order events" do
    test "a postponing statem honours an ack that arrives before the result" do
      {:ok, pid} = StrictOwner.start(self())

      send(pid, :handoff_ack)
      send(pid, {:worker_result, {:ok, :value}})

      assert_receive {:owner, {:committed, {:ok, :value}}}, 500
    end

    test "the GenServer owner shape drops the same early ack permanently" do
      log = EffectLog.start()
      {:ok, pid} = FlagsOwner.start(log, self())
      ref = Process.monitor(pid)

      # `handoff_waiting?` is still false, so this lands on the catch-all.
      send(pid, :handoff_ack)
      send(pid, {:worker_result, {:ok, :value}})

      # The ack is gone. Re-delivering it is the caller's problem, and the owner
      # gives no signal that anything was discarded.
      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 200
      refute :commit_authority in EffectLog.effects(log)

      EffectLog.stop(log)
    end
  end

  describe "unhandled events" do
    @tag :capture_log
    test "a statem without a catch-all fails loudly, naming the state and event" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = :gen_statem.start_link(StrictOwner, {self(), 5_000}, [])

      # `:awaiting_handoff` has exactly one clause, for `:handoff_ack`.
      send(pid, {:worker_result, {:ok, :value}})
      send(pid, :worker_down)

      assert_receive {:EXIT, ^pid, reason}, 500

      # The state name is the failing function and the event is its argument, so
      # the crash report localises the gap without any extra instrumentation.
      assert {:function_clause, [{StrictOwner, :awaiting_handoff, args, _location} | _rest]} =
               reason

      assert [:info, :worker_down, _data] = args
    end

    @tag :capture_log
    test "the GenServer owner shape returns :noreply for the same event" do
      log = EffectLog.start()
      {:ok, pid} = FlagsOwner.start(log, self())
      ref = Process.monitor(pid)

      send(pid, {:worker_result, {:ok, :value}})
      send(pid, :worker_down)

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 200
      assert Process.alive?(pid)

      EffectLog.stop(log)
    end
  end

  describe "state timeouts" do
    test "a state timeout fires without any timer bookkeeping in the data" do
      {:ok, _pid} = StrictOwner.start(self(), 20)

      assert_receive {:owner, :execution_deadline}, 500
    end

    test "leaving the state cancels its timeout with no explicit cancel call" do
      {:ok, pid} = StrictOwner.start(self(), 50)

      send(pid, {:worker_result, {:ok, :value}})
      send(pid, :handoff_ack)

      assert_receive {:owner, {:committed, {:ok, :value}}}, 500
      refute_receive {:owner, :execution_deadline}, 200
    end
  end
end
