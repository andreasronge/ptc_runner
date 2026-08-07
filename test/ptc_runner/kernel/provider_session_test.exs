defmodule PtcRunner.Kernel.ProviderSessionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderScopeOwner
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ProviderTaskTracker
  alias PtcRunner.Kernel.ResourceRegistrar

  test "a wedged session cannot outrun the operation deadline" do
    # `:sys.suspend/1` wedges the session deterministically, with no timing
    # margin: the call cannot be served at all until it is resumed. Before this
    # slice `open_registrar/1` waited a fixed five seconds and activate, commit,
    # and abort waited `:infinity`, so a short operation budget bought nothing.
    {:ok, limits} = Limits.installed(%{run_duration_ms: 200})
    {:ok, session} = ProviderSession.start_active(limits, "wedged-operation")
    on_exit(fn -> Process.exit(session.pid, :kill) end)
    {:ok, session} = ProviderSession.begin_operation(session, :run)

    assert :ok = :sys.suspend(session.pid)

    started_at_ms = System.monotonic_time(:millisecond)
    assert {:error, :provider_session_unavailable} = ProviderSession.open_registrar(session)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    assert Deadline.expired?(ProviderSession.run_deadline(session))

    # The error alone proves nothing — a fixed timeout returns the same value,
    # just later. The bound is the claim, so the elapsed time is the assertion.
    # 200ms of budget against the 5s this used to wait leaves no ambiguity.
    assert elapsed_ms < 1_000

    assert :ok = :sys.resume(session.pid)
  end

  test "a scope refused after its deadline leaves nothing behind" do
    # The caller gave up, so the reply is worthless — but the handler would
    # still have created a controller, a root owner, and a reaper, and put the
    # scope in `scope_order` where only session close would ever reap it. Both
    # sides fence on the same absolute instant instead.
    {:ok, limits} = Limits.installed(%{run_duration_ms: 200})
    {:ok, session} = ProviderSession.start_active(limits, "fenced-operation")
    on_exit(fn -> ProviderSession.close(session) end)
    {:ok, session} = ProviderSession.begin_operation(session, :run)

    assert :ok = :sys.suspend(session.pid)
    assert {:error, :provider_session_unavailable} = ProviderSession.open_registrar(session)
    assert :ok = :sys.resume(session.pid)

    # The request is still queued and is served now, after the deadline. It must
    # not become a scope nothing holds a handle to.
    assert %{scopes: scopes, scope_order: order} = :sys.get_state(session.pid)
    assert scopes == %{}
    assert order == []
  end

  test "a stale pre-operation handle cannot open an unbounded scope" do
    # `begin_operation/2` returns a new sealed handle and the pre-begin one
    # stays valid with `run_deadline: nil`. If the fence trusted the caller's
    # copy of the deadline, that stale handle would send `nil` and open a scope
    # with no bound at all, after the operation had already expired.
    {:ok, limits} = Limits.installed(%{run_duration_ms: 200})
    {:ok, stale} = ProviderSession.start_active(limits, "stale-handle")
    on_exit(fn -> ProviderSession.close(stale) end)
    {:ok, begun} = ProviderSession.begin_operation(stale, :run)

    assert ProviderSession.run_deadline(stale) == nil
    assert Deadline.valid?(ProviderSession.run_deadline(begun))

    burn_until(Deadline.expires_at(ProviderSession.run_deadline(begun)) + 5)

    assert {:error, :provider_session_unavailable} = ProviderSession.open_registrar(stale)
    assert %{scopes: %{}, scope_order: []} = :sys.get_state(stale.pid)
  end

  test "an active session hands out no scope before its operation starts" do
    # Between `start_active/2` and `begin_operation/2` the session has an
    # identity but no anchored budget. Sealing that would have the server itself
    # mint the unbounded handle the sealed-budget rule exists to prevent, so the
    # scope is refused until the operation it belongs to has started.
    {:ok, limits} = Limits.installed(%{run_duration_ms: 2_000})
    {:ok, session} = ProviderSession.start_active(limits, "pre-begin")
    on_exit(fn -> ProviderSession.close(session) end)

    assert ProviderSession.run_deadline(session) == nil
    assert {:error, :provider_session_unavailable} = ProviderSession.open_registrar(session)
    assert %{scopes: %{}, scope_order: []} = :sys.get_state(session.pid)

    # Once the operation is anchored the same session opens scopes normally.
    {:ok, begun} = ProviderSession.begin_operation(session, :run)
    assert {:ok, _registrar} = ProviderSession.open_registrar(begun)
  end

  test "an embedding session without an operation still opens scopes" do
    # A session with no identity at all is a direct embedding, which keeps the
    # synchronous semantics it has always had. The refusal above must not catch
    # it, or every embedded acquisition breaks.
    {:ok, session} = ProviderSession.start(limits())
    on_exit(fn -> ProviderSession.close(session) end)

    assert ProviderSession.run_deadline(session) == nil
    assert {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    assert :ok = ResourceRegistrar.abort(registrar)
  end

  test "a stale handle cannot mint a registrar with no budget" do
    # The fence being server-authoritative is not enough on its own. During a
    # live operation the pre-begin handle passes that fence, so if the budget
    # sealed into the registrar came from the caller's copy it would be `nil` —
    # a legitimately attested handle whose activate and commit wait forever.
    # The sealed budget therefore comes back from the session too.
    {:ok, limits} = Limits.installed(%{run_duration_ms: 2_000})
    {:ok, stale} = ProviderSession.start_active(limits, "stale-budget")
    on_exit(fn -> Process.exit(stale.pid, :kill) end)
    {:ok, begun} = ProviderSession.begin_operation(stale, :run)

    assert ProviderSession.run_deadline(stale) == nil
    assert Deadline.valid?(ProviderSession.run_deadline(begun))

    # The operation is live, so opening through the stale handle succeeds.
    assert {:ok, registrar} = ProviderSession.open_registrar(stale)

    # ...and the handle it produced still carries the operation's budget, so a
    # wedged session cannot make its activate wait forever.
    assert :ok = :sys.suspend(stale.pid)
    started_at_ms = System.monotonic_time(:millisecond)
    assert {:error, :resource_registrar_unavailable} = ResourceRegistrar.activate(registrar)
    # Wide on purpose. The bound only has to separate "spends the 2s budget"
    # from "waits forever", and the unsealed-budget mutation never returns at
    # all, so a tight margin buys nothing and flakes under load.
    assert System.monotonic_time(:millisecond) - started_at_ms < 10_000
  end

  test "an invalid registrar handle is refused rather than raising" do
    # The budgets are read from the handle, so a tampered one must be proved
    # before either field is touched: an invalid deadline would otherwise raise
    # in `Deadline.remaining/1` and a nonpositive cleanup budget in
    # `Deadline.new/1`, crashing the caller instead of failing closed.
    {:ok, session} = ProviderSession.start(limits())
    on_exit(fn -> ProviderSession.close(session) end)
    {:ok, registrar} = ProviderSession.open_registrar(session)

    # A well-formed but widened deadline is only rejected; a malformed one is
    # what proves the ordering, because reading it at all raises.
    garbled = %{registrar | operation_deadline: :not_a_deadline}
    refute ResourceRegistrar.valid?(garbled)

    assert {:error, :resource_registrar_unavailable} = ResourceRegistrar.activate(garbled)
    assert {:error, :resource_registrar_unavailable} = ResourceRegistrar.commit(garbled, nil)

    widened = %{registrar | operation_deadline: Deadline.new(600_000)}
    refute ResourceRegistrar.valid?(widened)
    assert {:error, :resource_registrar_unavailable} = ResourceRegistrar.activate(widened)

    # `Deadline.new/1` refuses a nonpositive budget, so abort reads it only
    # after the handle is proved.
    zeroed = %{registrar | cleanup_timeout_ms: 0}
    refute ResourceRegistrar.valid?(zeroed)
    assert {:error, :provider_cleanup_failed} = ResourceRegistrar.abort(zeroed)
  end

  test "an abort spends its own cleanup budget, not the operation's" do
    # Abort commonly begins because the operation deadline expired. Spending
    # that deadline would hand cleanup a zero remainder and skip cooperative
    # release, so each abort episode anchors one fresh cleanup budget.
    #
    # This guards the invariant rather than evidencing a change: the session
    # already anchored a fresh budget per abort before the deadline classes
    # existed, so it passes at the base commit too.
    {:ok, limits} = Limits.installed(%{run_duration_ms: 200, provider_cleanup_timeout_ms: 5_000})
    {:ok, session} = ProviderSession.start_active(limits, "abort-budget")
    on_exit(fn -> ProviderSession.close(session) end)
    {:ok, session} = ProviderSession.begin_operation(session, :run)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    burn_until(Deadline.expires_at(ProviderSession.run_deadline(session)) + 5)
    assert Deadline.expired?(ProviderSession.run_deadline(session))

    # The operation budget is gone and the abort still settles cooperatively.
    assert :ok = ResourceRegistrar.abort(registrar)
    assert %{scopes: %{}, scope_order: []} = :sys.get_state(session.pid)
  end

  test "a wedged session cannot leave a committed closer ambiguously owned" do
    # A session that never answers is the case a reply grace cannot decide. The
    # commit keeps its request alive, spends one cleanup budget waiting for the
    # truth, and then settles the question with an event rather than a duration:
    # the session is killed, and a brutal kill runs no terminate callback, so a
    # session that never replied has never run and never will run this closer.
    # Ownership therefore falls to the caller, provably once.
    {:ok, closed} = Agent.start_link(fn -> 0 end)

    {:ok, limits} =
      Limits.installed(%{run_duration_ms: 200, provider_cleanup_timeout_ms: 300})

    {:ok, session} = ProviderSession.start_active(limits, "wedged-commit")
    {:ok, session} = ProviderSession.begin_operation(session, :run)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    parent = self()
    close = fn -> Agent.update(closed, &(&1 + 1)) && :ok end
    reference = Process.monitor(session.pid)

    # Suspended and never resumed: the commit can never be served.
    assert :ok = :sys.suspend(session.pid)
    spawn(fn -> send(parent, {:commit, ResourceRegistrar.commit(registrar, close)}) end)

    # The caller is told it owns the closer, rather than being left to guess.
    assert_receive {:commit, {:error, :resource_registrar_unavailable}}, 5_000

    # And it was told so by an event: the wedged session was killed, so nothing
    # else can ever run this closer.
    assert_receive {:DOWN, ^reference, :process, _pid, _reason}, 5_000
    assert Agent.get(closed, & &1) == 0
  end

  test "a commit refused after its deadline leaves the closer with its caller" do
    # A commit that landed after its caller gave up would be owned twice: the
    # session would close it, and the caller's unregistered-closer recovery
    # would run it as well. The session refuses ownership past the same instant
    # the caller stops waiting, so the closer stays with exactly one owner.
    {:ok, closed} = Agent.start_link(fn -> 0 end)
    {:ok, limits} = Limits.installed(%{run_duration_ms: 200})
    {:ok, session} = ProviderSession.start_active(limits, "commit-fence")
    on_exit(fn -> ProviderSession.close(session) end)
    {:ok, session} = ProviderSession.begin_operation(session, :run)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    burn_until(Deadline.expires_at(ProviderSession.run_deadline(session)) + 5)

    close = fn -> Agent.update(closed, &(&1 + 1)) && :ok end
    assert {:error, :resource_registrar_unavailable} = ResourceRegistrar.commit(registrar, close)

    # The session took no ownership, so closing it runs nothing...
    assert :ok = ProviderSession.close(session)
    assert Agent.get(closed, & &1) == 0

    # ...and the caller still holds the only copy.
    assert :ok = close.()
    assert Agent.get(closed, & &1) == 1
  end

  test "committed scopes close once in reverse commit order" do
    {:ok, order} = Agent.start_link(fn -> [] end)
    {:ok, session} = ProviderSession.start(limits())
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)

    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)
    assert :ok = ResourceRegistrar.commit(first, record_close(order, :first))
    assert :ok = ResourceRegistrar.commit(second, record_close(order, :second))

    session_monitor = Process.monitor(session.pid)
    assert :ok = ProviderSession.close(session)
    assert_receive {:DOWN, ^session_monitor, :process, _, :normal}
    assert [:second, :first] = Agent.get(order, &Enum.reverse/1)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert [:second, :first] = Agent.get(order, &Enum.reverse/1)
  end

  test "invalid limits cannot create a provider session" do
    invalid = %{limits() | provider_cleanup_timeout_ms: 0}

    assert {:error, :invalid_provider_session} = ProviderSession.start(invalid)
  end

  test "an invalid active operation identity fails closed" do
    assert {:error, :invalid_provider_session} = ProviderSession.start_active(limits(), nil)
  end

  test "owned active sessions keep execution authority while fixing lifecycle ownership" do
    parent = self()
    lifecycle_owner = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:ok, session} =
             ProviderSession.start_active_owned(
               limits(),
               "prepared-operation",
               lifecycle_owner,
               fn opened ->
                 send(parent, {:session_handed_off, opened})
                 :ok
               end
             )

    assert_receive {:session_handed_off, ^session}
    assert ProviderSession.lifecycle_owner(session) == lifecycle_owner
    assert {:ok, session} = ProviderSession.begin_operation(session, :run)
    assert {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.abort(registrar)

    run_state = spawn(fn -> receive do: (:stop -> :ok) end)

    assert :ok =
             ProviderSession.bind_lifecycle(session, self(), run_state, task_tracker(run_state))

    assert ProviderSession.lifecycle_owner(session) == lifecycle_owner

    session_ref = Process.monitor(session.pid)
    send(lifecycle_owner, :stop)
    assert_receive {:DOWN, ^session_ref, :process, _, :normal}
    send(run_state, :stop)
  end

  test "owned active session handoff failure closes the provisional session" do
    lifecycle_owner = spawn(fn -> receive do: (:stop -> :ok) end)
    parent = self()

    assert {:error, :provider_session_unavailable} =
             ProviderSession.start_active_owned(
               limits(),
               "prepared-operation",
               lifecycle_owner,
               fn session ->
                 send(parent, {:provisional_session, session})
                 {:error, :owner_unavailable}
               end
             )

    assert_receive {:provisional_session, session}
    session_ref = Process.monitor(session.pid)
    assert_receive {:DOWN, ^session_ref, :process, _, reason}
    assert reason in [:normal, :noproc]
    send(lifecycle_owner, :stop)
  end

  @tag timeout: 15_000
  test "a timed-out begin request cannot mutate a suspended session later" do
    {:ok, session} = ProviderSession.start_active(limits(), "prepared-operation")
    monitor = Process.monitor(session.pid)
    parent = self()

    suspender =
      spawn(fn ->
        true = :erlang.suspend_process(session.pid)
        send(parent, :session_suspended)

        receive do
          :resume -> true = :erlang.resume_process(session.pid)
        end
      end)

    assert_receive :session_suspended
    Process.send_after(suspender, :resume, 5_250)

    assert {:error, :provider_session_unavailable} =
             ProviderSession.begin_operation(session, :run)

    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    refute ProviderSession.alive?(session)
  end

  test "claimed operation remains claimed after lifecycle ownership transfers" do
    identity = "prepared-operation"
    limits = limits()
    {:ok, session} = ProviderSession.start_active(limits, identity)
    {:ok, session} = ProviderSession.begin_operation(session, :run)
    assert :ok = ProviderSession.claim_operation(session, limits, identity)

    lifecycle_owner = spawn(fn -> receive do: (:stop -> :ok) end)
    run_state = spawn(fn -> receive do: (:stop -> :ok) end)

    assert :ok =
             ProviderSession.bind_lifecycle(
               session,
               lifecycle_owner,
               run_state,
               task_tracker(run_state)
             )

    assert {:error, :operation_claimed} =
             ProviderSession.claim_operation(session, limits, identity)

    assert :ok = ProviderSession.close(session)
    send(lifecycle_owner, :stop)
    send(run_state, :stop)
  end

  test "abnormal session death cannot be reported as successful cleanup" do
    parent = self()
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_owned_root(registrar, parent, :abnormal)
    root_monitor = Process.monitor(root)
    assert_receive {:root_ready, :abnormal, ^root}

    assert :ok =
             ResourceRegistrar.commit(registrar, fn ->
               send(parent, :unexpected_cleanup)
               :ok
             end)

    monitor = Process.monitor(session.pid)
    Process.exit(session.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    refute_receive :unexpected_cleanup
  end

  test "abnormal session death gives a stubborn root one bound before force-kill" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}

    Process.exit(session.pid, :kill)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}, 1_000
  end

  test "registrars enforce activation and terminal transitions" do
    {:ok, session} = ProviderSession.start(limits())
    {:ok, aborted} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.abort(aborted)

    assert {:error, :resource_registrar_unavailable} =
             ResourceRegistrar.activate(aborted)

    {:ok, committed} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(committed)
    assert :ok = ResourceRegistrar.commit(committed, nil)

    assert {:error, :resource_registrar_unavailable} =
             ResourceRegistrar.commit(committed, nil)

    assert :ok = ProviderSession.close(session)
  end

  test "registrar owners isolate provisional roots by acquisition scope" do
    parent = self()
    {:ok, session} = ProviderSession.start(limits())
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)

    first_owner = ResourceRegistrar.owner(first)
    second_owner = ResourceRegistrar.owner(second)

    assert is_pid(first_owner)
    assert is_pid(second_owner)
    refute first_owner == second_owner
    refute first_owner == session.pid
    refute second_owner == session.pid

    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)
    first_root = start_owned_root(first, parent, :first)
    second_root = start_owned_root(second, parent, :second)
    first_monitor = Process.monitor(first_root)
    second_monitor = Process.monitor(second_root)
    observer = start_owner_observer(first_owner, parent)
    observer_monitor = Process.monitor(observer)

    assert_receive {:root_ready, :first, ^first_root}
    assert_receive {:root_ready, :second, ^second_root}
    assert_receive {:observer_ready, ^observer}
    assert :ok = ResourceRegistrar.abort(first)

    assert_receive {:DOWN, ^first_monitor, :process, ^first_root, :normal}
    assert_receive {:owner_down_observed, ^observer}
    refute_receive {:DOWN, ^observer_monitor, :process, ^observer, _reason}
    assert Process.alive?(observer)
    refute_receive {:DOWN, ^second_monitor, :process, ^second_root, _reason}
    assert Process.alive?(second_root)

    Process.exit(observer, :kill)
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :killed}
    assert :ok = ProviderSession.close(session)
    assert_receive {:DOWN, ^second_monitor, :process, ^second_root, :normal}
  end

  test "aborting one scope does not consume a later scope's cleanup deadline" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)
    second_root = start_owned_root(second, parent, :later_scope)
    second_monitor = Process.monitor(second_root)
    assert_receive {:root_ready, :later_scope, ^second_root}

    assert :ok = ResourceRegistrar.abort(first)
    Process.send_after(self(), :first_deadline_elapsed, 150)
    assert_receive :first_deadline_elapsed, 1_000

    assert :ok = ResourceRegistrar.commit(second, nil)
    assert :ok = ProviderSession.close(session)
    assert_receive {:DOWN, ^second_monitor, :process, ^second_root, :normal}
  end

  test "committed closer runs before its scope owner is terminated" do
    parent = self()
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_owned_root(registrar, parent, :committed)
    root_monitor = Process.monitor(root)
    assert_receive {:root_ready, :committed, ^root}

    assert :ok =
             ResourceRegistrar.commit(registrar, fn ->
               send(parent, {:closer_saw_root, Process.alive?(root)})
               :ok
             end)

    assert :ok = ProviderSession.close(session)
    assert_receive {:closer_saw_root, true}
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}
  end

  test "a dormant scope owner does not consume the existing closer budget" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 400)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    assert :ok =
             ResourceRegistrar.commit(registrar, fn ->
               send(parent, {:budgeted_closer_started, self()})

               receive do
                 :finish_budgeted_close -> :ok
               end
             end)

    spawn(fn -> send(parent, {:budgeted_close_result, ProviderSession.close(session)}) end)
    assert_receive {:budgeted_closer_started, closer}
    Process.send_after(closer, :finish_budgeted_close, 250)
    assert_receive {:budgeted_close_result, :ok}, 1_000
  end

  test "two healthy committed scopes close within short cleanup slices" do
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)
    assert :ok = ResourceRegistrar.commit(first, fn -> :ok end)
    assert :ok = ResourceRegistrar.commit(second, fn -> :ok end)

    assert :ok = ProviderSession.close(session)
  end

  test "stubborn root cleanup reserves time for later provider closers" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 200)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, later} = ProviderSession.open_registrar(session)
    {:ok, stubborn} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(later)
    assert :ok = ResourceRegistrar.activate(stubborn)
    root = start_stubborn_root(stubborn, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}

    assert :ok =
             ResourceRegistrar.commit(later, fn ->
               send(parent, :later_provider_closed)
               :ok
             end)

    assert :ok = ResourceRegistrar.commit(stubborn, nil)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert_receive :later_provider_closed
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
  end

  test "registered roots retain an observed cleanup window after their closer" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 200)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}

    assert :ok =
             ResourceRegistrar.commit(registrar, fn ->
               receive do
                 :never_finish -> :ok
               end
             end)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    refute Process.alive?(root)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
  end

  test "cleanup force-kills a registered root that ignores owner death" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    refute Process.alive?(root)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
  end

  test "cleanup force-kills and observes a suspended signal owner without roots" do
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    owner = ResourceRegistrar.owner(registrar)
    owner_monitor = Process.monitor(owner)

    assert true = :erlang.suspend_process(owner)
    assert :ok = ResourceRegistrar.activate(registrar)
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    refute Process.alive?(owner)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
  end

  test "queued cleanup preserves the caller's absolute deadline" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 200)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    _suspender =
      spawn(fn ->
        true = :erlang.suspend_process(registrar.cleanup_owner)
        send(parent, :cleanup_owner_suspended)
        Process.send_after(self(), :resume, 175)

        receive do
          :resume -> :erlang.resume_process(registrar.cleanup_owner)
        end
      end)

    assert_receive :cleanup_owner_suspended

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    refute Process.alive?(root)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
  end

  test "cleanup does not depend on a responsive scope controller" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    controller_monitor = Process.monitor(registrar.scope_controller)
    assert_receive {:stubborn_root_ready, ^root}
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    assert true = :erlang.suspend_process(registrar.scope_controller)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)

    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
    assert_receive {:DOWN, ^controller_monitor, :process, _pid, :killed}
    refute Process.alive?(root)
    refute Process.alive?(registrar.scope_controller)
  end

  test "registration stalled at its gate cannot delay session cleanup" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    assert true = :erlang.suspend_process(registrar.scope_controller)

    root =
      spawn(fn ->
        send(parent, {:registration_result, ResourceRegistrar.register_root(registrar)})
      end)

    root_monitor = Process.monitor(root)
    assert_pending_registrations(session, 1)
    started_at = System.monotonic_time(:millisecond)

    assert :ok = ProviderSession.close(session)
    assert System.monotonic_time(:millisecond) - started_at < 1_000
    assert_receive {:registration_result, {:error, :resource_registrar_unavailable}}
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}
    refute Process.alive?(registrar.scope_controller)
  end

  @tag timeout: 7_000
  test "registration returns without mutation when the session is unresponsive" do
    parent = self()
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    assert true = :erlang.suspend_process(session.pid)

    root =
      spawn(fn ->
        send(parent, {:unresponsive_registration, ResourceRegistrar.register_root(registrar)})
      end)

    root_monitor = Process.monitor(root)
    assert_receive {:unresponsive_registration, {:error, :resource_registrar_unavailable}}, 6_000
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}
    assert true = :erlang.resume_process(session.pid)

    state = :sys.get_state(session.pid)
    refute state.scopes[registrar.scope].roots_registered?
    assert :ok = ResourceRegistrar.abort(registrar)
    assert :ok = ProviderSession.close(session)
  end

  test "accepted registration can reply after the mutation cutoff" do
    parent = self()
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    assert true = :erlang.suspend_process(registrar.scope_controller)

    root =
      spawn(fn ->
        result = ProviderSession.register_root(registrar, 500)
        send(parent, {:reserved_registration_response, result})
      end)

    root_monitor = Process.monitor(root)
    assert_pending_registrations(session, 1)

    [pending] = Map.values(:sys.get_state(session.pid).pending_registrations)
    assert pending.response_deadline_ms > pending.mutation_deadline_ms
    assert true = :erlang.suspend_process(session.pid)
    assert true = :erlang.resume_process(registrar.scope_controller)
    assert_message_queue_at_least(session.pid, 1)

    delay_ms = max(pending.mutation_deadline_ms + 1 - System.monotonic_time(:millisecond), 0)
    Process.send_after(self(), :resume_registration_session, delay_ms)
    assert_receive :resume_registration_session, 600
    assert true = :erlang.resume_process(session.pid)

    assert_receive {:reserved_registration_response, :ok}
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}
    assert :ok = ResourceRegistrar.abort(registrar)
    assert :ok = ProviderSession.close(session)
  end

  test "pending registration admission enforces the root cap per scope" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, stalled} = ProviderSession.open_registrar(session)
    {:ok, healthy} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(stalled)
    assert :ok = ResourceRegistrar.activate(healthy)
    assert true = :erlang.suspend_process(stalled.scope_controller)

    waiting =
      for _index <- 1..ProviderScopeOwner.max_roots() do
        spawn(fn ->
          send(parent, {:pending_registration_result, ResourceRegistrar.register_root(stalled)})
        end)
      end

    assert_pending_registrations(session, ProviderScopeOwner.max_roots())

    rejected =
      spawn(fn ->
        send(parent, {:capped_registration_result, ResourceRegistrar.register_root(stalled)})
      end)

    rejected_monitor = Process.monitor(rejected)
    healthy_root = start_owned_root(healthy, parent, :healthy_scope)
    healthy_monitor = Process.monitor(healthy_root)

    assert_receive {:capped_registration_result, {:error, :resource_registrar_unavailable}}
    assert_receive {:DOWN, ^rejected_monitor, :process, ^rejected, :normal}
    assert_receive {:root_ready, :healthy_scope, ^healthy_root}

    started_at = System.monotonic_time(:millisecond)
    assert :ok = ProviderSession.close(session)
    assert System.monotonic_time(:millisecond) - started_at < 1_000
    assert_receive {:DOWN, ^healthy_monitor, :process, ^healthy_root, :normal}

    for _root <- waiting do
      assert_receive {:pending_registration_result, {:error, :resource_registrar_unavailable}}
    end
  end

  test "an expired handoff cannot mutate ownership after reporting failure" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}
    assert true = :erlang.suspend_process(registrar.cleanup_owner)

    spawn(fn ->
      result = ProviderScopeOwner.handoff(registrar.cleanup_owner, session.pid, root, 100)
      send(parent, {:delayed_handoff_result, result})
    end)

    assert_receive {:delayed_handoff_result, {:error, :provider_scope_unavailable}}, 1_000
    assert true = :erlang.resume_process(registrar.cleanup_owner)

    assert {:error, :provider_cleanup_failed} = ResourceRegistrar.abort(registrar)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
    refute Process.alive?(root)
    assert :ok = ProviderSession.close(session)
  end

  test "scope controller survives session death during normal root drain" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_notifying_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    spawn(fn -> send(parent, {:close_result, ProviderSession.close(session)}) end)
    assert_receive {:stubborn_owner_down, ^root}
    Process.exit(session.pid, :kill)

    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}, 1_000
    assert_receive {:close_result, {:error, :provider_cleanup_failed}}
  end

  test "scope cleanup accepts a terminal handoff during cooperative drain" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_notifying_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    spawn(fn -> send(parent, {:close_result, ProviderSession.close(session)}) end)
    assert_receive {:stubborn_owner_down, ^root}

    assert :ok = ResourceRegistrar.handoff_root(registrar, root)
    assert_receive {:close_result, :ok}
    refute_receive {:DOWN, ^root_monitor, :process, ^root, _reason}
    assert Process.alive?(root)

    Process.exit(root, :kill)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
  end

  test "queued handoff traffic cannot extend the cooperative cleanup deadline" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_notifying_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    spawn(fn -> send(parent, {:close_result, ProviderSession.close(session)}) end)
    assert_receive {:stubborn_owner_down, ^root}

    noise = spawn(fn -> receive do: (:stop -> :ok) end)
    operation_deadline_ms = System.monotonic_time(:millisecond) + 5_000

    for _index <- 1..2_000 do
      send(
        registrar.cleanup_owner,
        {ProviderScopeOwner, {:handoff, session.pid, self(), operation_deadline_ms}, noise,
         make_ref()}
      )
    end

    assert_receive {:close_result, {:error, :provider_cleanup_failed}}, 1_000
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
    Process.exit(noise, :kill)
  end

  test "cleanup force-kills exact roots when the signal owner cannot stop" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}
    assert true = :erlang.suspend_process(ResourceRegistrar.owner(registrar))
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
    refute Process.alive?(ResourceRegistrar.owner(registrar))
    refute Process.alive?(root)
  end

  test "the signal owner cannot be handed off as though it were a root" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    signal_owner = ResourceRegistrar.owner(registrar)
    signal_monitor = Process.monitor(signal_owner)
    assert true = :erlang.suspend_process(signal_owner)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_stubborn_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:stubborn_root_ready, ^root}
    assert :ok = ResourceRegistrar.commit(registrar, nil)
    assert true = :erlang.suspend_process(registrar.cleanup_owner)

    spawn(fn -> send(parent, {:close_result, ProviderSession.close(session)}) end)

    spawn(fn ->
      send(
        parent,
        {:signal_handoff_result, ResourceRegistrar.handoff_root(registrar, signal_owner)}
      )
    end)

    assert_message_queue_at_least(registrar.cleanup_owner, 2)
    assert true = :erlang.resume_process(registrar.cleanup_owner)

    assert_receive {:signal_handoff_result, {:error, :resource_registrar_unavailable}}
    assert_receive {:close_result, {:error, :provider_cleanup_failed}}, 1_000
    assert_receive {:DOWN, ^signal_monitor, :process, ^signal_owner, :killed}
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
  end

  test "root admission is capped so forced cleanup remains structurally bounded" do
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    roots =
      for index <- 1..64 do
        root = start_owned_root(registrar, parent, index)
        assert_receive {:root_ready, ^index, ^root}
        root
      end

    rejected = start_owned_root(registrar, parent, :over_limit)
    rejected_monitor = Process.monitor(rejected)

    assert_receive {:root_registration_failed, :over_limit, :resource_registrar_unavailable}

    assert_receive {:DOWN, ^rejected_monitor, :process, ^rejected, :normal}

    monitors = Map.new(roots, &{Process.monitor(&1), &1})
    started_at = System.monotonic_time(:millisecond)
    assert :ok = ResourceRegistrar.abort(registrar)
    assert System.monotonic_time(:millisecond) - started_at < 1_000
    assert_roots_down(monitors)
    assert :ok = ProviderSession.close(session)
  end

  test "a handed-off terminalization root survives scope cleanup" do
    parent = self()
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_handoff_root(registrar, parent)
    root_monitor = Process.monitor(root)
    assert_receive {:handoff_root_ready, ^root}
    assert :ok = ResourceRegistrar.handoff_root(registrar, root)

    assert :ok = ResourceRegistrar.abort(registrar)
    assert_receive {:owner_down_observed, ^root}
    refute_receive {:DOWN, ^root_monitor, :process, ^root, _reason}
    assert Process.alive?(root)

    Process.exit(root, :kill)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
    assert :ok = ProviderSession.close(session)
  end

  test "a registered root can stop before its scope commits" do
    parent = self()
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    root =
      spawn(fn ->
        Process.monitor(ResourceRegistrar.owner(registrar))
        :ok = ResourceRegistrar.register_root(registrar)
        send(parent, {:short_root_ready, self()})
        receive do: (:stop -> :ok)
      end)

    root_monitor = Process.monitor(root)
    assert_receive {:short_root_ready, ^root}
    send(root, :stop)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal}

    assert :ok = ResourceRegistrar.commit(registrar, nil)
    assert :ok = ProviderSession.close(session)
  end

  test "lifecycle ownership transfers once before death cleanup" do
    parent = self()

    creator =
      spawn(fn ->
        {:ok, session} = ProviderSession.start(limits())
        {:ok, committed} = ProviderSession.open_registrar(session)
        :ok = ResourceRegistrar.activate(committed)

        :ok =
          ResourceRegistrar.commit(committed, fn ->
            send(parent, :committed_closed)
            :ok
          end)

        lifecycle_owner = spawn(fn -> receive do: (:stop -> :ok) end)
        run_state = spawn(fn -> receive do: (:stop -> :ok) end)
        {:ok, tracker} = ProviderTaskTracker.start(run_state)
        :ok = ProviderSession.bind_lifecycle(session, lifecycle_owner, run_state, tracker)
        send(parent, {:session_ready, session, lifecycle_owner, run_state, tracker})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:session_ready, session, lifecycle_owner, run_state, tracker}
    session_monitor = Process.monitor(session.pid)

    assert {:error, :provider_session_unavailable} =
             ProviderSession.bind_lifecycle(session, self(), run_state, tracker)

    provider = spawn(fn -> receive do: (:stop -> :ok) end)
    provider_monitor = Process.monitor(provider)
    assert :ok = ProviderTaskTracker.attach(tracker, provider)

    Process.exit(creator, :kill)
    refute_receive :committed_closed
    assert Process.alive?(session.pid)

    Process.exit(run_state, :kill)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :killed}
    refute_receive :committed_closed
    assert Process.alive?(session.pid)

    Process.exit(lifecycle_owner, :kill)

    assert_receive :committed_closed
    assert_receive {:DOWN, ^session_monitor, :process, _, :normal}
  end

  test "the cleanup deadline is anchored once for the whole terminal episode" do
    {:ok, session} = ProviderSession.start(limits())

    assert {:ok, anchored} = ProviderSession.anchor_cleanup_deadline(session)
    assert Deadline.valid?(anchored)

    # A later terminal stage consumes the same absolute deadline rather than
    # minting the installed cleanup duration again.
    assert {:ok, ^anchored} = ProviderSession.anchor_cleanup_deadline(session)

    assert :ok = ProviderSession.close(session)
    assert {:error, :provider_cleanup_failed} = ProviderSession.anchor_cleanup_deadline(session)
  end

  test "cleanup has one shared bound" do
    {:ok, order} = Agent.start_link(fn -> [] end)
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)

    assert :ok = ResourceRegistrar.commit(first, record_close(order, :first))

    assert :ok =
             ResourceRegistrar.commit(second, fn ->
               receive do
                 :never -> :ok
               end
             end)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert [:first] = Agent.get(order, &Enum.reverse/1)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
  end

  test "an unregistered close bounds the session's stack by the share it was given" do
    # The caller reserves part of the one budget for the closer that must
    # outlive a session which never answers. The session therefore bounds its
    # own stack by that same share; otherwise a stack it could have worked
    # through is killed at a bound only the caller knew about, and its oldest
    # closer is never invoked at all.
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 600)
    {:ok, session} = ProviderSession.start(limits)

    for label <- [:first, :second] do
      {:ok, registrar} = ProviderSession.open_registrar(session)
      assert :ok = ResourceRegistrar.activate(registrar)

      assert :ok =
               ResourceRegistrar.commit(registrar, fn ->
                 send(parent, {:closed, label})
                 receive do: (:never -> :ok)
               end)
    end

    assert {:error, :provider_cleanup_failed} =
             ProviderSession.close_with_unregistered(session, fn ->
               send(parent, {:closed, :unregistered})
               receive do: (:never -> :ok)
             end)

    # Every closer on the stack is attempted. A session spending the whole
    # anchored remainder instead of its share is killed part-way through and
    # strands the oldest one.
    assert_receive {:closed, :unregistered}
    assert_receive {:closed, :second}
    assert_receive {:closed, :first}
  end

  @tag timeout: 15_000
  test "the cleanup deadline starts where the terminal action began" do
    # Anchoring inside the session would measure from the instant it dequeued
    # the request, so time already spent waiting for a busy session would be
    # granted a second time.
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 1_000)
    {:ok, session} = ProviderSession.start(limits)
    parent = self()

    suspender =
      spawn(fn ->
        true = :erlang.suspend_process(session.pid)
        send(parent, :session_suspended)

        receive do
          :resume -> true = :erlang.resume_process(session.pid)
        end
      end)

    assert_receive :session_suspended
    Process.send_after(suspender, :resume, 300)

    assert {:ok, deadline} = ProviderSession.anchor_cleanup_deadline(session)
    assert Deadline.remaining(deadline) <= 700
    assert :ok = ProviderSession.close(session)
  end

  test "an unregistered closer still runs at the smallest supported cleanup limit" do
    # 100 ms is the smallest installable provider cleanup timeout, and it equals
    # the reply grace. A split that took the grace off the top before halving
    # would leave the session no budget at all and skip the closer it was just
    # handed, leaving that resource open on the acquisition-failure path.
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, session} = ProviderSession.start(limits)

    assert :ok =
             ProviderSession.close_with_unregistered(session, fn ->
               send(parent, :minimum_budget_closed)
               :ok
             end)

    assert_received :minimum_budget_closed
  end

  test "cleanup continues in reverse order after a close failure" do
    {:ok, order} = Agent.start_link(fn -> [] end)
    {:ok, session} = ProviderSession.start(limits())
    {:ok, first} = ProviderSession.open_registrar(session)
    {:ok, second} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(first)
    assert :ok = ResourceRegistrar.activate(second)
    assert :ok = ResourceRegistrar.commit(first, record_close(order, :first))
    assert :ok = ResourceRegistrar.commit(second, fn -> :failed end)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert [:first] = Agent.get(order, &Enum.reverse/1)
  end

  test "an unresponsive session is terminated at its installed cleanup budget" do
    # The lifecycle owner installs the whole terminal budget, so a session that
    # cannot answer within it is ended rather than waited on forever.
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 200)
    assert {:ok, session} = ProviderSession.start(limits)
    assert :ok = :sys.suspend(session.pid)
    monitor = Process.monitor(session.pid)

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received {:DOWN, ^monitor, :process, _pid, :killed}
    refute Process.alive?(session.pid)
    # Bounded by the installed budget, not by a fixed interval unrelated to it.
    assert elapsed < 1_000
  end

  test "an unresponsive session is terminated when closing an unregistered resource" do
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 200)
    assert {:ok, session} = ProviderSession.start(limits)
    parent = self()
    assert :ok = :sys.suspend(session.pid)
    monitor = Process.monitor(session.pid)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :provider_cleanup_failed} =
             ProviderSession.close_with_unregistered(session, fn ->
               send(parent, :unregistered_closed)
               :ok
             end)

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received {:DOWN, ^monitor, :process, _pid, :killed}
    # The unregistered closer keeps its share of the one terminal budget even
    # when the session itself never answers, and both shares together stay
    # inside that one budget rather than each taking a fresh one.
    assert_received :unregistered_closed
    refute Process.alive?(session.pid)
    assert elapsed < 1_000
  end

  test "tampered session and registrar handles are rejected" do
    {:ok, session} = ProviderSession.start(limits())
    {:ok, registrar} = ProviderSession.open_registrar(session)

    refute ProviderSession.valid?(%{session | token: make_ref()})
    refute ResourceRegistrar.valid?(%{registrar | scope: make_ref()})

    assert {:error, :provider_cleanup_failed} =
             ProviderSession.close(%{session | token: make_ref()})

    assert {:error, :resource_registrar_unavailable} =
             ResourceRegistrar.activate(%{registrar | scope: make_ref()})

    assert :ok = ProviderSession.close(session)
  end

  defp limits, do: Limits.defaults()

  # The subject here is a deadline, so the fixture consumes real time without a
  # timer the suite forbids.
  defp burn_until(target_ms) do
    if System.monotonic_time(:millisecond) < target_ms, do: burn_until(target_ms), else: :ok
  end

  defp task_tracker(run_state) do
    {:ok, tracker} = ProviderTaskTracker.start(run_state)
    tracker
  end

  defp record_close(agent, value) do
    fn ->
      Agent.update(agent, &[value | &1])
      :ok
    end
  end

  defp start_owned_root(registrar, parent, label) do
    spawn(fn ->
      owner = ResourceRegistrar.owner(registrar)
      owner_monitor = Process.monitor(owner)

      case ResourceRegistrar.register_root(registrar) do
        :ok ->
          send(parent, {:root_ready, label, self()})

          receive do
            {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
          end

        {:error, reason} ->
          send(parent, {:root_registration_failed, label, reason})
      end
    end)
  end

  defp start_owner_observer(owner, parent) do
    spawn(fn ->
      owner_monitor = Process.monitor(owner)
      send(parent, {:observer_ready, self()})

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          send(parent, {:owner_down_observed, self()})
          receive do: (:stop -> :ok)
      end
    end)
  end

  defp start_stubborn_root(registrar, parent) do
    spawn(fn ->
      owner = ResourceRegistrar.owner(registrar)
      owner_monitor = Process.monitor(owner)
      :ok = ResourceRegistrar.register_root(registrar)
      send(parent, {:stubborn_root_ready, self()})

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          receive do: (:stop -> :ok)
      end
    end)
  end

  defp start_handoff_root(registrar, parent) do
    spawn(fn ->
      owner = ResourceRegistrar.owner(registrar)
      owner_monitor = Process.monitor(owner)
      :ok = ResourceRegistrar.register_root(registrar)
      send(parent, {:handoff_root_ready, self()})

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          send(parent, {:owner_down_observed, self()})
          receive do: (:stop -> :ok)
      end
    end)
  end

  defp start_notifying_stubborn_root(registrar, parent) do
    spawn(fn ->
      owner = ResourceRegistrar.owner(registrar)
      owner_monitor = Process.monitor(owner)
      :ok = ResourceRegistrar.register_root(registrar)
      send(parent, {:stubborn_root_ready, self()})

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          send(parent, {:stubborn_owner_down, self()})
          receive do: (:stop -> :ok)
      end
    end)
  end

  defp assert_roots_down(monitors) when map_size(monitors) == 0, do: :ok

  defp assert_roots_down(monitors) do
    receive do
      {:DOWN, monitor, :process, root, _reason} when is_map_key(monitors, monitor) ->
        assert Map.fetch!(monitors, monitor) == root
        assert_roots_down(Map.delete(monitors, monitor))
    after
      1_000 -> flunk("registered roots did not all terminate")
    end
  end

  defp assert_pending_registrations(session, expected) do
    if map_size(:sys.get_state(session.pid).pending_registrations) == expected do
      :ok
    else
      :erlang.yield()
      assert_pending_registrations(session, expected)
    end
  end

  defp assert_message_queue_at_least(pid, expected) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} when count >= expected ->
        :ok

      _waiting ->
        :erlang.yield()
        assert_message_queue_at_least(pid, expected)
    end
  end
end
