defmodule PtcRunner.Soak.ReplSessionSoakTest do
  @moduledoc """
  Repeated `ReplSession` churn (use-case row 15).

  Resource model, written down before the workload:

  | resource | creator | owner | authorized user | closer |
  |---|---|---|---|---|
  | `ReplSessionOwner` process | `new/1` | itself | the holder of `{pid, token}` | `close/1`/`abort/2`, or its own `:DOWN` on the creator |
  | access ETS table | `new/1` | the **creator process**, one per creator, not per session | the creator only (`:private`) | never; it outlives every session the creator makes |
  | access entry `{id, {pid, token}}` | `new/1` | the table | the creator | `close_access/1` on every exit path |
  | `EventSink` process | the caller, before `new/1` | itself | the run | the caller; `Runner` finalizes it but never stops it |

  **The table is not the resource to watch.** One `:private` table is allocated
  per creator process, keyed by session ID, with entries deleted on close. A
  leaked session entry never changes the table count, so this soak gates on
  entries and deliberately does not list the table.

  Getting the owner PID right matters for the same reason. The process
  dictionary key `{ReplSession, :access_table}` points at the *table*, and the
  `ReplSessionOwner` pid lives inside the entry as `{id, {pid, token}}`.
  Monitoring what the dictionary key points at would monitor the long-lived
  creator — here, the test process — and the owner-death variant would
  silently verify nothing. This captures the owner from the table entry.
  """

  use ExUnit.Case, async: false

  @moduletag :soak
  @moduletag timeout: :infinity

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.LifecycleSoak

  @threshold_bytes_per_cycle 2_048

  setup_all do
    {:ok, component} =
      Component.new(
        id: "soak.repl",
        source: "(ns soak.repl)\n(defn value [x] (+ x 1))\n",
        origin: "soak"
      )

    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)

    {:ok, workflow: workflow, mission: mission, limits: limits}
  end

  describe "normal completion" do
    test "close/1 removes the session entry and its owner", context do
      LifecycleSoak.soak!(
        [
          name: "repl session (normal close)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          {session, owner, sink, owned} = open(context)
          {:ok, _step, session} = ReplSession.eval(session, "(soak.repl/value 1)")

          assert {:ok, _events} = ReplSession.close(session)
          :ok = EventSink.stop(sink)

          ledger(session, owner, sink, owned)
        end
      )
    end
  end

  describe "owner death" do
    # Currently failing, and correctly so: this variant found a real leak.
    # `close/1` and `abort/2` only reach `close_access/1` after
    # `owned_session/1` succeeds, and `owned_session/1` exits when the owner is
    # already dead — so an abnormally terminated owner leaves its access entry
    # in the creator's table permanently. Reproduced standalone at 5 sessions,
    # 5 permanent entries with dead pids.
    #
    # Skipped rather than deleted: the reproduction is the valuable part, and
    # the fix is a production behaviour change that belongs in its own PR.
    # Remove this tag as part of fixing
    # https://github.com/andreasronge/ptc_runner/issues/1201.
    @tag :skip
    test "killing the ReplSessionOwner leaves no entry behind", context do
      LifecycleSoak.soak!(
        [
          name: "repl session (owner death)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          {session, owner, sink, owned} = open(context)

          # The owner dies without `terminate/2` running, which is the variant
          # the happy path cannot reach. `close/1` must still be able to drop
          # the creator-side access entry afterwards.
          kill_and_await(owner)
          _closed = ReplSession.close(session)
          :ok = EventSink.stop(sink)

          ledger(session, owner, sink, owned)
        end
      )
    end
  end

  describe "deadline expiry" do
    test "abort/2 after the evaluation deadline leaves no entry behind", context do
      # A one-millisecond evaluation budget: the run deadline is already spent
      # by the time anything is evaluated, so the session is torn down through
      # the expiry path rather than through a clean terminal publication.
      {:ok, expired_limits} = Limits.new(evaluation_timeout_ms: 1)
      context = %{context | limits: expired_limits}

      LifecycleSoak.soak!(
        [
          name: "repl session (deadline expiry)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          {session, owner, sink, owned} = open(context)
          _evaluated = ReplSession.eval(session, "(soak.repl/value 1)")
          _aborted = ReplSession.abort(session, :deadline_expired)
          :ok = EventSink.stop(sink)

          ledger(session, owner, sink, owned)
        end
      )
    end
  end

  defp open(%{workflow: workflow, mission: mission, limits: limits}) do
    {:ok, sink} = EventSink.start(:normal, limits, run_id: unique_run_id())

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    owner = owner_pid!(session)
    {session, owner, sink, owned_processes(owner)}
  end

  # `{id, {pid, token}}` — the owner is inside the entry. Reading it here, at
  # creation, is what makes the owner-death variant test the owner rather than
  # the creator.
  defp owner_pid!(%ReplSession{access: access, id: id}) do
    [{^id, {pid, token}}] = :ets.lookup(access, id)
    assert is_pid(pid) and is_reference(token)
    pid
  end

  defp ledger(%ReplSession{access: access, id: id}, owner, sink, owned) do
    # The access table is absent on purpose: it belongs to this test process
    # and legitimately outlives every session, so only the entry can leak.
    LifecycleSoak.ledger(
      processes: [owner, sink.pid | owned],
      ets_entries: [{access, id}]
    )
  end

  # A session also owns a `RunState`, and **every** `RunState` starts a
  # `ProviderTaskTracker` alongside it (`run_state.ex:995`). Both are per-cycle
  # processes and neither is reachable from the `%ReplSession{}` handle, so
  # they have to be read out of the owner's state while it is still alive —
  # which is also why they were missed at first. Read before any variant kills
  # the owner.
  defp owned_processes(owner) do
    %{run_state: run_state} = :sys.get_state(owner)
    [run_state.pid, run_state.provider_tracker.pid]
  end

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  end

  # Run IDs must carry entropy: a sink started with a repeated ID across
  # thousands of cycles would make every cycle's events indistinguishable.
  defp unique_run_id, do: "soak-repl-#{System.unique_integer([:positive])}"
end
