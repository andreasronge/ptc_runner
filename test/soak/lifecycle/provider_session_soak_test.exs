defmodule PtcRunner.Soak.ProviderSessionSoakTest do
  @moduledoc """
  Repeated provider acquire/close churn (use-case row 11).

  Acquire/close is the richest lifecycle in the tree, and the one with the most
  places to leave something behind: a session owns scopes, each scope owns a
  controller, a root owner and a reaper, and a committed scope carries a closer
  that must run exactly once.

  Resource model, written down before the workload:

  | resource | creator | owner | authorized user | closer |
  |---|---|---|---|---|
  | `ProviderSession` process | `start_active/2` | itself | its `creator`, or its `lifecycle_owner` when owned | `close/1`, or its `:DOWN` on the lifecycle owner |
  | scope (controller, root, reaper) | `open_registrar/1` | the session | the registrar handle | `commit/2`'s closer at session close, or `abort/1` |
  | committed closer | `commit/2` | the session | nobody | session close, in reverse commit order, once |
  | `ProviderTaskTracker` process | `start/1` | itself | the run state | its `:DOWN` on the run state |

  Behavior on termination:

    * **caller death** — an unowned session's creator is its authority; a
      session whose creator dies cannot be closed by anyone else, which is why
      the owned variant exists.
    * **owner death** — `start_active_owned/4` binds a lifecycle owner; its
      `:DOWN` must take the session and every committed closer with it.
    * **deadline expiry** — the operation budget is anchored at
      `begin_operation/2`, and close spends the *cleanup* budget, not the
      operation's. A session closed after its run deadline has already expired
      must still reap its scopes.

  Every variant asserts the committed closers ran exactly once, because a
  session that leaked a scope and a session that closed one twice both look
  identical to a byte metric.
  """

  use ExUnit.Case, async: false

  @moduletag :soak
  @moduletag timeout: :infinity

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ProviderTaskTracker
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.TestSupport.LifecycleSoak
  alias PtcRunner.TestSupport.MemorySoak

  @threshold_bytes_per_cycle 2_048

  describe "normal completion" do
    test "close/1 reaps every committed scope exactly once" do
      LifecycleSoak.soak!(
        [
          name: "provider session (normal close)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          {:ok, session} = ProviderSession.start_active(limits(), unique_operation())
          {:ok, session} = ProviderSession.begin_operation(session, :run)

          closed = commit_scopes(session, 2)
          assert :ok = ProviderSession.close(session)
          assert_closed_once(closed, 2)

          LifecycleSoak.ledger(processes: [session.pid])
        end
      )
    end

    test "aborted registrars leave nothing for close to reap" do
      LifecycleSoak.soak!(
        [
          name: "provider session (aborted registrar)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          {:ok, session} = ProviderSession.start_active(limits(), unique_operation())
          {:ok, session} = ProviderSession.begin_operation(session, :run)

          {:ok, registrar} = ProviderSession.open_registrar(session)
          assert :ok = ResourceRegistrar.abort(registrar)

          assert :ok = ProviderSession.close(session)

          LifecycleSoak.ledger(processes: [session.pid])
        end
      )
    end
  end

  describe "owner death" do
    test "lifecycle-owner death takes the session and its closers with it" do
      LifecycleSoak.soak!(
        [
          name: "provider session (lifecycle-owner death)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          parent = self()
          owner = spawn(fn -> receive do: (:stop -> :ok) end)

          {:ok, session} =
            ProviderSession.start_active_owned(
              limits(),
              unique_operation(),
              owner,
              fn opened -> send(parent, {:handed_off, opened}) && :ok end
            )

          assert_receive {:handed_off, ^session}
          {:ok, session} = ProviderSession.begin_operation(session, :run)
          closed = commit_scopes(session, 2)

          # No `close/1`. The lifecycle owner's `:DOWN` is the only thing that
          # can reap this session, which is the path where nothing the caller
          # does can compensate for a missed cleanup.
          kill_and_await(owner)
          await_dead(session.pid)
          assert_closed_once(closed, 2)

          LifecycleSoak.ledger(processes: [session.pid, owner])
        end
      )
    end

    test "run-state death drains the provider task tracker" do
      LifecycleSoak.soak!(
        [
          name: "provider task tracker (run-state death)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle
        ],
        fn _cycle ->
          run_state = spawn(fn -> receive do: (:stop -> :ok) end)
          {:ok, tracker} = ProviderTaskTracker.start(run_state)

          lifecycle = spawn(fn -> receive do: (:stop -> :ok) end)
          assert :ok = ProviderTaskTracker.watch(tracker, lifecycle)

          kill_and_await(run_state)
          kill_and_await(lifecycle)
          await_dead(tracker.pid)

          LifecycleSoak.ledger(processes: [tracker.pid, run_state, lifecycle])
        end
      )
    end
  end

  describe "deadline expiry" do
    test "a session closed after its operation deadline still reaps its scopes" do
      LifecycleSoak.soak!(
        [
          name: "provider session (deadline expiry)",
          threshold_bytes_per_cycle: @threshold_bytes_per_cycle,
          # `burn_past/1` spins to the deadline, so each cycle costs its whole
          # budget. Capped so the wider budget above cannot turn a 3000-cycle
          # CI run into a 10-minute spin. The harness prints the count it ran.
          cycles: min(MemorySoak.iteration_count(), 25)
        ],
        fn _cycle ->
          # 1 ms is not a usable budget here, and using it made this the one
          # reproducibly flaky test in the suite. `begin_operation/2` mints the
          # deadline client-side, and the server re-checks `Deadline.live?/1`
          # when it *dequeues* the call (`provider_session.ex:887`), so the
          # whole round trip — plus the `open_registrar`/`activate`/`commit`
          # chain, which must also beat it — has to fit inside the budget. One
          # descheduling and the cycle dies with
          # `{:error, :provider_session_unavailable}`, which is a
          # test-construction failure, not a leak. At CI's 3000 iterations that
          # is near-certain, and it would have kept the very workflow slice 1
          # exists to restore permanently red.
          #
          # 50 ms survives scheduling while still expiring far inside the 5 s
          # cleanup allowance, so the variant still tests what it claims.
          {:ok, limits} = Limits.installed(%{run_duration_ms: 50})
          {:ok, session} = ProviderSession.start_active(limits, unique_operation())
          {:ok, session} = ProviderSession.begin_operation(session, :run)

          closed = commit_scopes(session, 1)
          burn_past(ProviderSession.run_deadline(session))
          assert Deadline.expired?(ProviderSession.run_deadline(session))

          # Two reports are legitimate here and which one appears is a race the
          # machine's load decides, so the assertion is on the resource facts
          # rather than on the report.
          #
          # `Limits.installed/1` keeps the cleanup budget independent of
          # `run_duration_ms`, so a 1 ms operation still gets the full 5 s
          # cleanup allowance — but the session keeps the *earliest* anchor, and
          # when the already-expired run deadline wins that comparison the close
          # call has no budget left and force-terminates instead of confirming a
          # graceful close. It then reports `:provider_cleanup_failed`, which is
          # deliberately fail-closed: "cleanup was not confirmed", not "cleanup
          # did not happen". On an idle machine the graceful path usually wins;
          # under full-suite load it usually does not.
          #
          # What must hold either way — and this is the variant where
          # `terminate/2` never runs, so it is where a leak would survive — is
          # that the scope is reaped exactly once and the session dies. The
          # ledger asserts the second; `assert_closed_once/2` the first.
          report = ProviderSession.close(session)
          assert_closed_once(closed, 1)

          assert report in [:ok, {:error, :provider_cleanup_failed}],
                 "unexpected close report after deadline expiry: #{inspect(report)}"

          LifecycleSoak.ledger(processes: [session.pid])
        end
      )
    end
  end

  # Each committed scope reports its own close, so the assertion can tell a
  # leaked scope from one closed twice.
  defp commit_scopes(session, count) do
    parent = self()
    token = make_ref()

    Enum.each(1..count, fn index ->
      {:ok, registrar} = ProviderSession.open_registrar(session)
      assert :ok = ResourceRegistrar.activate(registrar)
      # The closer must return `:ok`; anything else is reported as
      # `:provider_cleanup_failed`, so `send/2`'s return value cannot be the
      # last expression here.
      assert :ok =
               ResourceRegistrar.commit(registrar, fn ->
                 send(parent, {token, index})
                 :ok
               end)
    end)

    token
  end

  defp assert_closed_once(token, count) do
    observed = collect(token, [])

    assert Enum.sort(observed) == Enum.to_list(1..count),
           "expected each committed scope to close exactly once, saw #{inspect(observed)}"
  end

  defp collect(token, acc) do
    receive do
      {^token, index} -> collect(token, [index | acc])
    after
      0 -> acc
    end
  end

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  end

  defp await_dead(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  end

  # A deadline is an absolute instant, so the only way past it is to reach it.
  # Busy-waiting on the monotonic clock keeps that explicit rather than
  # sleeping for a duration the test would then have to trust.
  defp burn_past(deadline) do
    expires_at = Deadline.expires_at(deadline)
    if System.monotonic_time(:millisecond) <= expires_at, do: burn_past(deadline), else: :ok
  end

  defp limits do
    {:ok, limits} = Limits.installed(%{run_duration_ms: 5_000})
    limits
  end

  # Operation identities must carry entropy: thousands of cycles sharing one
  # identity would make every cycle's session indistinguishable in a trace.
  defp unique_operation, do: "soak-operation-#{System.unique_integer([:positive])}"
end
