defmodule PtcRunner.Kernel.EvaluationAdmissionTest do
  @moduledoc """
  Blocking admission behind the single evaluation lease.

  Every enqueued waiter must receive exactly one reply — admission, a typed
  error, or nothing only because its caller died. Grants additionally wait
  for provider reservations still tied to a dead evaluation's lease, so two
  evaluations' external effects can never overlap.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunState

  defp start_state(limit_overrides \\ []) do
    {:ok, limits} = Limits.new(limit_overrides)
    {:ok, state} = RunState.start(limits)
    state
  end

  # A worker process that performs RunState calls on command and reports
  # every result back, so the test controls sequencing without sleeping.
  defp start_worker(state) do
    parent = self()

    pid =
      spawn(fn ->
        worker_loop(state, parent)
      end)

    pid
  end

  defp worker_loop(state, parent) do
    receive do
      {:reserve, mode} ->
        send(parent, {:reserved, self(), RunState.reserve_evaluation(state, mode)})
        worker_loop(state, parent)

      {:release, lease} ->
        send(parent, {:released, self(), RunState.release_evaluation(state, lease)})
        worker_loop(state, parent)

      {:release_status, lease} ->
        send(parent, {:release_status, self(), RunState.release_evaluation_status(state, lease)})
        worker_loop(state, parent)

      {:reserve_capability, environment, name, lease} ->
        send(
          parent,
          {:capability_reserved, self(),
           RunState.reserve_capability(state, environment, name, lease)}
        )

        worker_loop(state, parent)

      {:attach_provider, provider} ->
        send(parent, {:provider_attached, self(), RunState.attach_provider(state, provider)})
        worker_loop(state, parent)

      :finish_provider ->
        send(parent, {:provider_finished, self(), RunState.finish_provider(state)})
        worker_loop(state, parent)

      :stop ->
        :ok
    end
  end

  defp reserve!(worker, mode \\ :fail_fast) do
    send(worker, {:reserve, mode})

    receive do
      {:reserved, ^worker, {:ok, _memory, _history, lease}} -> {:ok, lease}
      {:reserved, ^worker, error} -> error
    after
      1_000 -> flunk("worker did not complete reserve")
    end
  end

  defp reserve_async(worker, mode) do
    send(worker, {:reserve, mode})
    :ok
  end

  defp await_reserved(worker, timeout \\ 1_000) do
    receive do
      {:reserved, ^worker, result} -> result
    after
      timeout -> flunk("worker #{inspect(worker)} received no admission reply")
    end
  end

  defp release!(worker, lease) do
    send(worker, {:release, lease})
    assert_receive {:released, ^worker, :ok}, 1_000
  end

  # Blocking callers park inside GenServer.call, so parking is only
  # observable through the owner's queue. Bounded receive-based polling —
  # no fixed sleep.
  defp await_queued(state, expected_count, attempts \\ 200)

  defp await_queued(_state, _expected_count, 0), do: flunk("admission queue never reached size")

  defp await_queued(state, expected_count, attempts) do
    %{admission_queue: queue} = :sys.get_state(state.pid)

    if :queue.len(queue) == expected_count do
      :ok
    else
      receive do
      after
        5 -> :ok
      end

      await_queued(state, expected_count, attempts - 1)
    end
  end

  defp queued_monitor_refs(state) do
    %{admission_queue: queue} = :sys.get_state(state.pid)
    queue |> :queue.to_list() |> Enum.map(& &1.monitor_ref)
  end

  # Bounded receive-based poll until the owner's state satisfies `check` —
  # proves RunState has processed its own monitor messages, where a negative
  # assertion alone would race them.
  defp await_owner_state(state, check, attempts \\ 200)

  defp await_owner_state(_state, _check, 0), do: flunk("owner state never satisfied condition")

  defp await_owner_state(state, check, attempts) do
    if check.(:sys.get_state(state.pid)) do
      :ok
    else
      receive do
      after
        5 -> :ok
      end

      await_owner_state(state, check, attempts - 1)
    end
  end

  test "waiters are admitted in FIFO order as the lease frees" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    [w1, w2, w3] = workers = Enum.map(1..3, fn _n -> start_worker(state) end)

    reserve_async(w1, :block)
    await_queued(state, 1)
    reserve_async(w2, :block)
    await_queued(state, 2)
    reserve_async(w3, :block)
    await_queued(state, 3)

    release!(holder, lease)

    for worker <- workers do
      assert {:ok, _memory, _history, next_lease} = await_reserved(worker)
      release!(worker, next_lease)
    end
  end

  test "a timed-out head waiter frees the queue for the next waiter" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    w1 = start_worker(state)
    w2 = start_worker(state)
    reserve_async(w1, :block)
    await_queued(state, 1)
    reserve_async(w2, :block)
    await_queued(state, 2)

    # Deliver w1's admission deadline directly instead of racing wall-clock
    # timers: the owner handles the message identically either way.
    [w1_ref, _w2_ref] = queued_monitor_refs(state)
    send(state.pid, {:admission_deadline, w1_ref})

    assert {:error, :admission_timeout} = await_reserved(w1)

    release!(holder, lease)
    assert {:ok, _memory, _history, w2_lease} = await_reserved(w2)
    release!(w2, w2_lease)
  end

  test "an expired waiter is refused at grant even when the release beats its timer" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    w1 = start_worker(state)
    w2 = start_worker(state)
    reserve_async(w1, :block)
    await_queued(state, 1)
    reserve_async(w2, :block)
    await_queued(state, 2)

    # Backdate w1's absolute deadline: its timer has not fired, but the
    # release below reaches the owner first. The grant path must consult the
    # deadline — not the timer — and skip to w2.
    :sys.replace_state(state.pid, fn owner ->
      {{:value, head}, rest} = :queue.out(owner.admission_queue)
      expired = %{head | deadline_mono: System.monotonic_time(:millisecond) - 1}
      %{owner | admission_queue: :queue.in_r(expired, rest)}
    end)

    release!(holder, lease)

    assert {:error, :admission_timeout} = await_reserved(w1)
    assert {:ok, _memory, _history, w2_lease} = await_reserved(w2)
    release!(w2, w2_lease)
  end

  test "a stale admission-deadline message after admission is ignored" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    w1 = start_worker(state)
    reserve_async(w1, :block)
    await_queued(state, 1)
    [w1_ref] = queued_monitor_refs(state)

    release!(holder, lease)
    assert {:ok, _memory, _history, w1_lease} = await_reserved(w1)

    send(state.pid, {:admission_deadline, w1_ref})

    # The stale message must not disturb the granted lease.
    release!(w1, w1_lease)
  end

  test "a waiter that dies while queued is dropped without wedging the queue" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    w1 = start_worker(state)
    w2 = start_worker(state)
    reserve_async(w1, :block)
    await_queued(state, 1)
    reserve_async(w2, :block)
    await_queued(state, 2)

    monitor = Process.monitor(w1)
    Process.exit(w1, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^w1, :killed}, 1_000
    await_queued(state, 1)

    release!(holder, lease)
    assert {:ok, _memory, _history, w2_lease} = await_reserved(w2)
    release!(w2, w2_lease)
  end

  test "a spent evaluation budget drains the remaining queue with a typed error" do
    state = start_state(subordinate_evaluations: 2)
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    w1 = start_worker(state)
    w2 = start_worker(state)
    reserve_async(w1, :block)
    await_queued(state, 1)
    reserve_async(w2, :block)
    await_queued(state, 2)

    release!(holder, lease)
    assert {:ok, _memory, _history, w1_lease} = await_reserved(w1)

    # w1's admission spent the second and final evaluation; releasing must
    # drain w2 with the budget error rather than granting a stale lease.
    release!(w1, w1_lease)
    assert {:error, :limit_exceeded} = await_reserved(w2)
  end

  test "run closure drains every queued waiter" do
    state = start_state()
    holder = start_worker(state)
    {:ok, _lease} = reserve!(holder)

    w1 = start_worker(state)
    w2 = start_worker(state)
    reserve_async(w1, :block)
    await_queued(state, 1)
    reserve_async(w2, :block)
    await_queued(state, 2)

    :ok = RunState.fail(state, :workflow_failed, :test_closure)

    assert {:error, :run_closed} = await_reserved(w1)
    assert {:error, :run_closed} = await_reserved(w2)
  end

  test "no grant while a dead evaluation's provider reservation is still live" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    # A dispatcher holds a mission-capability reservation tied to the lease.
    dispatcher = start_worker(state)
    send(dispatcher, {:reserve_capability, :mission, "cap", lease})
    assert_receive {:capability_reserved, ^dispatcher, :ok}, 1_000

    # The evaluation owner dies: the lease clears, but the reservation
    # still references it, so nothing may be granted yet.
    holder_monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 1_000

    direct = start_worker(state)
    assert {:error, :busy} = reserve!(direct)

    blocked = start_worker(state)
    reserve_async(blocked, :block)
    await_queued(state, 1)

    # Draining the reservation is the admission trigger.
    send(dispatcher, :finish_provider)
    assert_receive {:provider_finished, ^dispatcher, :ok}, 1_000

    assert {:ok, _memory, _history, lease} = await_reserved(blocked)
    release!(blocked, lease)
  end

  test "a dead evaluation's late capability call cannot attach to the next lease" do
    state = start_state()
    holder = start_worker(state)
    {:ok, stale_lease} = reserve!(holder)

    # The dead evaluation's sandbox may outlive its owner briefly; its late
    # reserve arrives only after the next evaluation was already admitted.
    holder_monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 1_000

    next = start_worker(state)
    assert {:ok, next_lease} = reserve!(next, :block)

    lingering = start_worker(state)
    send(lingering, {:reserve_capability, :mission, "cap", stale_lease})
    assert_receive {:capability_reserved, ^lingering, {:error, :stale_evaluation}}, 1_000

    # A mission call presenting no lease at all is equally rejected.
    unleased = start_worker(state)
    send(unleased, {:reserve_capability, :mission, "cap", nil})
    assert_receive {:capability_reserved, ^unleased, {:error, :stale_evaluation}}, 1_000

    release!(next, next_lease)
  end

  test "fail-fast reserve and source checks stay :busy while the queue holds the lease" do
    state = start_state()
    holder = start_worker(state)
    {:ok, _lease} = reserve!(holder)

    waiter = start_worker(state)
    reserve_async(waiter, :block)
    await_queued(state, 1)

    direct = start_worker(state)
    assert {:error, :busy} = reserve!(direct)
    assert {:error, :busy} = RunState.reserve_source_check(state)
  end

  test "a parked release-status caller is replied to when its reservations drain" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    dispatcher = start_worker(state)
    send(dispatcher, {:reserve_capability, :mission, "cap", lease})
    assert_receive {:capability_reserved, ^dispatcher, :ok}, 1_000

    # The release parks: the lease still has a live reservation.
    send(holder, {:release_status, lease})
    refute_receive {:release_status, ^holder, _result}, 100

    send(dispatcher, :finish_provider)
    assert_receive {:provider_finished, ^dispatcher, :ok}, 1_000

    assert_receive {:release_status, ^holder, {:ok, %{terminal_provider_failure?: false}}}, 1_000
  end

  test "terminal provider provenance survives a parked release" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    dispatcher = start_worker(state)
    send(dispatcher, {:reserve_capability, :mission, "cap", lease})
    assert_receive {:capability_reserved, ^dispatcher, :ok}, 1_000

    parent = self()

    provider =
      spawn(fn ->
        receive do
          :mark ->
            :ok = RunState.mark_evaluation_terminal_provider_failure(state)
            send(parent, :marked)

            receive do
              :finish -> :ok
            end
        end
      end)

    send(dispatcher, {:attach_provider, provider})
    assert_receive {:provider_attached, ^dispatcher, :ok}, 1_000

    send(provider, :mark)
    assert_receive :marked, 1_000

    send(holder, {:release_status, lease})
    refute_receive {:release_status, ^holder, _result}, 100

    send(provider, :finish)
    send(dispatcher, :finish_provider)
    assert_receive {:provider_finished, ^dispatcher, :ok}, 1_000

    assert_receive {:release_status, ^holder, {:ok, %{terminal_provider_failure?: true}}}, 1_000
  end

  test "close_and_drain replies to a parked release-status caller instead of dropping it" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    dispatcher = start_worker(state)
    send(dispatcher, {:reserve_capability, :mission, "cap", lease})
    assert_receive {:capability_reserved, ^dispatcher, :ok}, 1_000

    send(holder, {:release_status, lease})
    refute_receive {:release_status, ^holder, _result}, 100

    :ok = RunState.close_and_drain(state)

    assert_receive {:release_status, ^holder, {:ok, %{terminal_provider_failure?: false}}}, 1_000
  end

  test "an async release-status followed by commit replies to both raw calls" do
    state = start_state()
    parent = self()

    dispatcher = start_worker(state)

    # The lease owner parks a release-status call and then commits without
    # waiting — raw sends model the async ordering. Both must be answered:
    # the commit's clear resolves the parked waiter instead of dropping it.
    holder =
      spawn(fn ->
        {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, :fail_fast)
        send(parent, {:leased, self(), lease})

        receive do
          :go ->
            status_ref = make_ref()
            commit_ref = make_ref()

            send(
              state.pid,
              {:"$gen_call", {self(), status_ref},
               {state.token, {:release_evaluation_status, lease}}}
            )

            send(
              state.pid,
              {:"$gen_call", {self(), commit_ref},
               {state.token, {:commit_evaluation, lease, %{}, []}}}
            )

            replies =
              for _n <- 1..2 do
                receive do
                  {^status_ref, reply} -> {:status, reply}
                  {^commit_ref, reply} -> {:commit, reply}
                after
                  2_000 -> :missing_reply
                end
              end

            send(parent, {:replies, Map.new(replies)})
        end
      end)

    assert_receive {:leased, ^holder, lease}, 1_000

    # A live reservation tied to the lease makes the release-status park.
    send(dispatcher, {:reserve_capability, :mission, "cap", lease})
    assert_receive {:capability_reserved, ^dispatcher, :ok}, 1_000

    send(holder, :go)

    assert_receive {:replies, replies}, 3_000
    assert %{status: {:ok, %{terminal_provider_failure?: false}}, commit: :ok} = replies
  end

  test "a duplicate release-status request is rejected instead of replacing the parked waiter" do
    state = start_state()
    parent = self()

    dispatcher = start_worker(state)

    holder =
      spawn(fn ->
        {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, :fail_fast)
        send(parent, {:leased, self(), lease})

        receive do
          :go ->
            first_ref = make_ref()
            second_ref = make_ref()

            send(
              state.pid,
              {:"$gen_call", {self(), first_ref},
               {state.token, {:release_evaluation_status, lease}}}
            )

            send(
              state.pid,
              {:"$gen_call", {self(), second_ref},
               {state.token, {:release_evaluation_status, lease}}}
            )

            receive do
              {^second_ref, reply} -> send(parent, {:second_reply, reply})
            after
              2_000 -> send(parent, {:second_reply, :missing})
            end

            receive do
              {^first_ref, reply} -> send(parent, {:first_reply, reply})
            after
              2_000 -> send(parent, {:first_reply, :missing})
            end
        end
      end)

    assert_receive {:leased, ^holder, lease}, 1_000

    send(dispatcher, {:reserve_capability, :mission, "cap", lease})
    assert_receive {:capability_reserved, ^dispatcher, :ok}, 1_000

    send(holder, :go)

    # The duplicate is rejected outright; the first waiter keeps its park and
    # completes when the reservation drains.
    assert_receive {:second_reply, {:error, :release_pending}}, 3_000

    send(dispatcher, :finish_provider)
    assert_receive {:provider_finished, ^dispatcher, :ok}, 1_000
    assert_receive {:first_reply, {:ok, %{terminal_provider_failure?: false}}}, 3_000
  end

  test "plain close drains every queued admission waiter" do
    state = start_state()
    holder = start_worker(state)
    {:ok, _lease} = reserve!(holder)

    w1 = start_worker(state)
    reserve_async(w1, :block)
    await_queued(state, 1)

    :ok = RunState.close(state)
    assert {:error, :run_closed} = await_reserved(w1)
  end

  test "provider death alone keeps the release parked until its dispatcher finishes" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    dispatcher = start_worker(state)
    send(dispatcher, {:reserve_capability, :mission, "cap", lease})
    assert_receive {:capability_reserved, ^dispatcher, :ok}, 1_000

    provider = spawn(fn -> receive do: (:never -> :ok) end)
    send(dispatcher, {:attach_provider, provider})
    assert_receive {:provider_attached, ^dispatcher, :ok}, 1_000

    send(holder, {:release_status, lease})
    refute_receive {:release_status, ^holder, _result}, 100

    # The reservation belongs to the live dispatcher, not the provider: the
    # waiter must stay parked through the provider's death. Wait until the
    # owner has processed the provider :DOWN (reservation retained with the
    # provider detached, waiter still parked) before asserting no reply.
    Process.exit(provider, :kill)

    await_owner_state(state, fn owner ->
      match?(
        %{
          evaluation_release_waiter: {_from, _lease},
          reservations: %{^dispatcher => %{provider: nil, provider_ref: nil}}
        },
        owner
      )
    end)

    refute_receive {:release_status, ^holder, _result}, 50

    send(dispatcher, :finish_provider)
    assert_receive {:provider_finished, ^dispatcher, :ok}, 1_000
    assert_receive {:release_status, ^holder, {:ok, %{terminal_provider_failure?: false}}}, 1_000
  end

  test "dispatcher death drains its reservation and completes a parked release" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    dispatcher = start_worker(state)
    send(dispatcher, {:reserve_capability, :mission, "cap", lease})
    assert_receive {:capability_reserved, ^dispatcher, :ok}, 1_000

    provider =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    send(dispatcher, {:attach_provider, provider})
    assert_receive {:provider_attached, ^dispatcher, :ok}, 1_000

    send(holder, {:release_status, lease})
    refute_receive {:release_status, ^holder, _result}, 100

    # Dispatcher death kills the attached provider; only the provider's
    # observed :DOWN releases the reservation and completes the waiter.
    monitor = Process.monitor(dispatcher)
    Process.exit(dispatcher, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^dispatcher, :killed}, 1_000

    assert_receive {:release_status, ^holder, {:ok, %{terminal_provider_failure?: false}}}, 1_000
  end

  test "simultaneous admission-deadline expirations resolve every waiter" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    w1 = start_worker(state)
    w2 = start_worker(state)
    reserve_async(w1, :block)
    await_queued(state, 1)
    reserve_async(w2, :block)
    await_queued(state, 2)

    [w1_ref, w2_ref] = queued_monitor_refs(state)
    send(state.pid, {:admission_deadline, w1_ref})
    send(state.pid, {:admission_deadline, w2_ref})

    assert {:error, :admission_timeout} = await_reserved(w1)
    assert {:error, :admission_timeout} = await_reserved(w2)

    # The drained queue must not wedge later admission.
    release!(holder, lease)
    late = start_worker(state)
    assert {:ok, late_lease} = reserve!(late, :block)
    release!(late, late_lease)
  end

  # A raw :"$gen_call" with a plain ref sees every reply the owner sends,
  # where GenServer.call aliases would silently absorb a duplicate. Both
  # orderings of the timer/admission race are pinned: admission first with a
  # stale timer behind it, and timer first with the release behind it.
  test "raw-call seam observes exactly one reply when admission beats the timer" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    reply_ref = make_ref()

    send(
      state.pid,
      {:"$gen_call", {self(), reply_ref}, {state.token, {:reserve_evaluation, :block}}}
    )

    await_queued(state, 1)
    [waiter_ref] = queued_monitor_refs(state)

    release!(holder, lease)
    send(state.pid, {:admission_deadline, waiter_ref})

    assert_receive {^reply_ref, {:ok, _memory, _history, _lease}}, 1_000
    refute_receive {^reply_ref, _duplicate}, 100
  end

  test "raw-call seam observes exactly one reply when the timer beats admission" do
    state = start_state()
    holder = start_worker(state)
    {:ok, lease} = reserve!(holder)

    reply_ref = make_ref()

    send(
      state.pid,
      {:"$gen_call", {self(), reply_ref}, {state.token, {:reserve_evaluation, :block}}}
    )

    await_queued(state, 1)
    [waiter_ref] = queued_monitor_refs(state)

    # Timer message first, then the release: the waiter must resolve as a
    # timeout exactly once, and the later lease clear must not re-reply.
    send(state.pid, {:admission_deadline, waiter_ref})
    assert_receive {^reply_ref, {:error, :admission_timeout}}, 1_000

    release!(holder, lease)
    refute_receive {^reply_ref, _duplicate}, 100

    await_owner_state(state, fn owner ->
      :queue.is_empty(owner.admission_queue) and owner.evaluation_release_waiter == nil and
        owner.evaluation_lease == nil
    end)
  end
end
