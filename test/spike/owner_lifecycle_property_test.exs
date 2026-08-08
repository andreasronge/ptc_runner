defmodule PtcRunner.Spike.OwnerLifecyclePropertyTest do
  @moduledoc false

  # Spike evidence for `docs/plans/spikes/gen-statem-owner.md`.
  #
  # Both spike owners are driven through the same randomized event sequences and
  # checked against the ownership invariants the shipped owners are expected to
  # hold. The pure `ExecutionLifecycle` model is the oracle for the phase each
  # sequence should end in.

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcRunner.TestSupport.Spike.EffectLog
  alias PtcRunner.TestSupport.Spike.ExecutionLifecycle
  alias PtcRunner.TestSupport.Spike.FlagsOwner
  alias PtcRunner.TestSupport.Spike.StatemOwner

  @owners [FlagsOwner, StatemOwner]

  defp event_generator do
    StreamData.one_of([
      StreamData.constant(:await),
      StreamData.constant({:worker_result, {:ok, :value}}),
      StreamData.constant({:worker_result, {:error, :kernel_failed}}),
      StreamData.constant(:worker_down),
      StreamData.constant(:handoff_ack),
      StreamData.constant(:caller_down)
    ])
  end

  # Runs one sequence against one owner in a dedicated caller process, so
  # `:caller_down` is a genuine monitored exit rather than a simulated message.
  defp run(owner, events) do
    log = EffectLog.start()
    test = self()

    caller =
      spawn(fn ->
        {:ok, pid} = owner.start(log, self())
        send(test, {:owner, pid})

        # `send_request/2` posts the call from *this* process, so an await keeps
        # its position in the sequence relative to the plain sends. A spawned
        # `GenServer.call` would race them and make the run non-deterministic.
        Enum.each(events, fn
          :await -> owner.send_await(pid)
          :caller_down -> exit(:normal)
          event -> send(pid, event)
        end)

        send(test, :sequence_done)
        receive do: (:release -> :ok)
      end)

    owner_pid = receive do: ({:owner, pid} -> pid)
    ref = Process.monitor(owner_pid)
    caller_ref = Process.monitor(caller)

    await_settled(ref, caller_ref)
    Process.exit(caller, :kill)

    effects = EffectLog.effects(log)
    EffectLog.stop(log)
    effects
  end

  # Settles when the owner has stopped, or when the sequence has been fully
  # delivered and the mailbox has drained — whichever happens first.
  defp await_settled(owner_ref, caller_ref) do
    receive do
      {:DOWN, ^owner_ref, :process, _pid, _reason} -> :ok
      {:DOWN, ^caller_ref, :process, _pid, _reason} -> drain(owner_ref)
      :sequence_done -> drain(owner_ref)
    after
      500 -> :ok
    end
  end

  defp drain(owner_ref) do
    receive do
      {:DOWN, ^owner_ref, :process, _pid, _reason} -> :ok
    after
      100 -> :ok
    end
  end

  defp model_phase(events) do
    events
    |> Enum.reduce(ExecutionLifecycle.new(), fn event, machine ->
      {next, _effects} = ExecutionLifecycle.step(machine, model_event(event))
      next
    end)
    |> ExecutionLifecycle.phase()
  end

  defp model_event(:await), do: {:await, :from}
  defp model_event(event), do: event

  property "the model never leaves a run without resolving its authority" do
    check all(events <- StreamData.list_of(event_generator(), min_length: 1, max_length: 8)) do
      {machine, effects} =
        Enum.reduce(events, {ExecutionLifecycle.new(), []}, fn event, {machine, acc} ->
          {next, new_effects} = ExecutionLifecycle.step(machine, model_event(event))
          {next, acc ++ new_effects}
        end)

      commits = Enum.count(effects, &(&1 == :commit_authority))
      aborts = Enum.count(effects, &(&1 == :abort_authority))

      # An authority is resolved at most once, and never both ways.
      assert commits <= 1
      assert commits == 0 or aborts == 0

      # Reaching :closed means the authority was resolved exactly one way.
      if ExecutionLifecycle.phase(machine) == :closed do
        assert commits + aborts >= 1
      end
    end
  end

  for owner <- @owners do
    @owner owner

    property "#{inspect(owner)} finalizes sinks at most once" do
      check all(
              events <- StreamData.list_of(event_generator(), min_length: 1, max_length: 8),
              max_runs: 150
            ) do
        effects = run(@owner, events)

        assert Enum.count(effects, &(&1 == :finalize_sinks)) <= 1,
               """
               sinks finalized #{Enum.count(effects, &(&1 == :finalize_sinks))} times
               events:  #{inspect(events)}
               effects: #{inspect(effects)}
               """
      end
    end

    property "#{inspect(owner)} never both commits and aborts the same authority" do
      check all(
              events <- StreamData.list_of(event_generator(), min_length: 1, max_length: 8),
              max_runs: 150
            ) do
        effects = run(@owner, events)

        refute :commit_authority in effects and :abort_authority in effects,
               """
               authority resolved both ways
               events:  #{inspect(events)}
               effects: #{inspect(effects)}
               """
      end
    end

    test "#{inspect(owner)} unwinds a caller death during execution exactly once" do
      effects = run(@owner, [:caller_down])

      assert Enum.count(effects, &(&1 == :finalize_sinks)) == 1
      assert Enum.count(effects, &(&1 == :abort_authority)) == 1
      assert :stop_worker in effects
    end

    test "#{inspect(owner)} commits the authority on the normal handoff path" do
      effects = run(@owner, [:await, {:worker_result, {:ok, :value}}, :handoff_ack])

      assert :commit_authority in effects
      refute :abort_authority in effects
      refute :finalize_sinks in effects
    end
  end

  test "the model and both owners agree that a stray ack cannot commit an authority" do
    assert model_phase([:handoff_ack]) == :executing

    for owner <- @owners do
      effects = run(owner, [:handoff_ack])
      refute :commit_authority in effects, "#{inspect(owner)} committed on a stray ack"
    end
  end
end
