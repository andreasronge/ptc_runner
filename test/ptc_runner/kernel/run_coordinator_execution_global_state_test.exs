defmodule PtcRunner.Kernel.RunCoordinatorExecutionGlobalStateTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.RunCoordinatorExecutionFixture
  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]
  import PtcRunner.TestSupport.TestHelpers, only: [long_running_body: 0]

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LLMBudget
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.PublicationAuthority

  test "successful handoff performs no owner-driven sink release or authority abort" do
    {prepared, catalog} = prepared_run("(return 42)")
    assert {:ok, authority} = PublicationAuthority.new([])

    release_patterns = [
      {EventSink, :finalize_and_events, 2},
      {EventSink, :stop, 1},
      {PublicationAuthority, :abort, 1}
    ]

    Enum.each([EventSink, PublicationAuthority], &Code.ensure_loaded!/1)
    Enum.each(release_patterns, &assert(:erlang.trace_pattern(&1, true, [:local]) == 1))
    on_exit(fn -> Enum.each(release_patterns, &:erlang.trace_pattern(&1, false, [:local])) end)

    assert {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
    owner_pid = ExecutionSessionOwner.pid(owner)
    owner_ref = Process.monitor(owner_pid)
    assert :erlang.trace(owner_pid, true, [:call]) == 1

    try do
      assert {:ok, %ExecutionOutcome{}} = ExecutionSessionOwner.await(owner)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}, 5_000

      delivered = :erlang.trace_delivered(owner_pid)
      assert_receive {:trace_delivered, ^owner_pid, ^delivered}

      refute_received {:trace, ^owner_pid, :call, {EventSink, :finalize_and_events, _arguments}}
      refute_received {:trace, ^owner_pid, :call, {EventSink, :stop, _arguments}}
      refute_received {:trace, ^owner_pid, :call, {PublicationAuthority, :abort, _arguments}}
    after
      stop_trace(owner_pid)
    end

    assert PublicationAuthority.authorized?(authority)
    assert :ok = PublicationAuthority.abort(authority)
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "failed opening finalizes and stops both sinks from the execution owner", %{
    tmp_dir: directory
  } do
    {prepared, catalog} = oversized_metadata_prepared_run()
    inspection_path = Path.join(directory, "failed.ptcins")

    assert {:ok, authority} =
             PublicationAuthority.authorize(
               "failed-opening",
               [inspect: inspection_path],
               :normal,
               :normal
             )

    trace_calls([
      {EventSink, :start, 3},
      {EventSink, :finalize_and_events, 2},
      {EventSink, :stop, 1},
      {InspectionSink, :start, 1},
      {InspectionSink, :stop, 1}
    ])

    try do
      assert {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
      owner_pid = ExecutionSessionOwner.pid(owner)

      assert {:error, %OwnerFailure{} = failure} = ExecutionSessionOwner.await(owner)

      assert {:ok, :run_started_metadata_exceeded, false, :not_started} =
               OwnerFailure.evidence(failure)

      assert_receive {:trace, ^owner_pid, :call, {EventSink, :start, _arguments}}, 5_000

      assert_receive {:trace, ^owner_pid, :call, {InspectionSink, :start, _arguments}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call,
                      {EventSink, :finalize_and_events,
                       [event_sink, %{outcome: :error, reason: :session_owner_failed}]}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call, {InspectionSink, :stop, [inspection_sink]}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call, {EventSink, :stop, [^event_sink]}}, 5_000

      refute Process.alive?(event_sink.pid)
      refute Process.alive?(inspection_sink.pid)
    after
      stop_trace_calls([
        {EventSink, :start, 3},
        {EventSink, :finalize_and_events, 2},
        {EventSink, :stop, 1},
        {InspectionSink, :start, 1},
        {InspectionSink, :stop, 1}
      ])
    end

    assert :ok = PublicationAuthority.abort(authority)
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "caller death aborts the worker and stops both owner-backed sinks", %{
    tmp_dir: directory
  } do
    # This test's premise -- that the run is still in flight when
    # `Process.exit(caller, :kill)` fires below -- used to rest on
    # `(loop [] (recur))`, which is not the infinite loop it looks like (see
    # `long_running_body/1`). It was really racing that loop's natural
    # completion, and could lose even outside full-suite load (reproduced
    # failing >50% of runs combined with just 3 other test files).
    #
    # The workflow sandbox watchdog-monitors its execution worker. Caller death
    # aborts that worker and asynchronously kills the sandbox. The short body
    # still bounds this fixture if an earlier assertion fails.
    #
    # `evaluation_timeout_ms` does not apply here: that governs subordinate
    # mission evaluations, not this top-level workflow call, which uses
    # `workflow_timeout_ms` (a 30s default, unrelated to this loop's budget).
    {prepared, catalog} = prepared_run(long_running_body(), inspection_capture: true)

    inspection_path = Path.join(directory, "run.ptcins")

    assert {:ok, authority} =
             PublicationAuthority.authorize(
               "caller-death",
               [inspect: inspection_path],
               :normal,
               :normal
             )

    parent = self()

    telemetry_handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_handler,
        [:ptc_runner, :sandbox, :armed],
        fn _, _, %{live_run: live_run, pid: sandbox}, destination ->
          send(destination, {:sandbox_armed, live_run, sandbox})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    caller =
      spawn(fn ->
        assert {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
        send(parent, {:execution_owner, owner})
        send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
      end)

    # Registered immediately, before any assertion below can fail: caller
    # death is exactly this test's own mechanism for aborting the run, so
    # this is a safe no-op on the pass path (caller is already dead by
    # then) and, on any earlier failure, stops the ~6s CPU-heavy loop
    # instead of leaving it running unlinked until its own deadline.
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    caller_ref = Process.monitor(caller)
    assert_receive {:execution_owner, owner}, 5_000
    owner_pid = ExecutionSessionOwner.pid(owner)
    assert_receive {:sandbox_armed, _live_run, sandbox}, 5_000
    sandbox_ref = Process.monitor(sandbox)
    state = :sys.get_state(owner_pid)
    event_sink = state.built.config.event_sink
    inspection_sink = state.built.config.inspection_sink

    assert {:ok, ^owner_pid} = EventSink.owner(event_sink)
    assert {:ok, ^owner_pid} = InspectionSink.owner(inspection_sink)
    assert_eventually(fn -> run_started?(event_sink) end)

    release_patterns = [
      {EventSink, :finalize_and_events, 2},
      {EventSink, :stop, 1},
      {PublicationAuthority, :abort, 1}
    ]

    Enum.each([EventSink, PublicationAuthority], &Code.ensure_loaded!/1)
    Enum.each(release_patterns, &assert(:erlang.trace_pattern(&1, true, [:local]) == 1))

    # Registered immediately: this is a VM-global trace pattern, so ANY
    # later failure in this test -- including the five `Process.monitor/1`
    # calls right below, before the `try` -- must not leave it enabled and
    # contaminating every later test in the suite. `on_exit` always runs,
    # unlike the `try/after` below which only protects its own block.
    on_exit(fn ->
      Enum.each(release_patterns, &:erlang.trace_pattern(&1, false, [:local]))
    end)

    owner_ref = Process.monitor(owner_pid)
    worker_ref = Process.monitor(state.worker_pid)
    event_sink_ref = Process.monitor(event_sink.pid)
    inspection_sink_ref = Process.monitor(inspection_sink.pid)
    activity_ref = Process.monitor(prepared.provider_activity.owner)

    try do
      # `owner_pid` is running a loop built to take ~6s across 1_000 heavy
      # iterations (see the comment above this test's
      # `prepared_run/2` call), so it must still be alive here. If it is
      # not, something ended the run far earlier than that -- fail with
      # that distinction instead of the opaque ArgumentError
      # `:erlang.trace/3` raises on a dead pid. Both checks stay inside this
      # `try` so a failure here still runs the `after` cleanup below --
      # otherwise the global `:erlang.trace_pattern/3` enabled above would
      # leak into every later test in the suite.
      assert Process.alive?(owner_pid),
             "owner #{inspect(owner_pid)} exited before tracing could start; " <>
               "the run ended far earlier than its ~6s natural completion"

      assert :erlang.trace(owner_pid, true, [:call]) == 1

      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

      assert_receive {:trace, ^owner_pid, :call,
                      {EventSink, :finalize_and_events,
                       [^event_sink, %{outcome: :error, reason: :session_owner_failed} = stopped]}}

      assert is_map(stopped.usage)

      assert {:ok, _projection} =
               LLMBudget.validate_terminal_projection(stopped.usage.llm_budget)

      assert_receive {:DOWN, ^worker_ref, :process, _worker, :killed}, 5_000
      assert_receive {:DOWN, ^sandbox_ref, :process, ^sandbox, :killed}, 1_000
      assert_receive {:DOWN, ^inspection_sink_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^event_sink_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^activity_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}, 5_000

      delivered = :erlang.trace_delivered(owner_pid)
      assert_receive {:trace_delivered, ^owner_pid, ^delivered}

      assert_receive {:trace, ^owner_pid, :call, {EventSink, :stop, [^event_sink]}}
      refute_received {:trace, ^owner_pid, :call, {EventSink, :stop, [^event_sink]}}

      assert_receive {:trace, ^owner_pid, :call, {PublicationAuthority, :abort, [^authority]}}

      refute_received {:trace, ^owner_pid, :call, {PublicationAuthority, :abort, [^authority]}}

      refute_received {:execution_result, _result}
    rescue
      e in ArgumentError ->
        flunk(
          "owner #{inspect(owner_pid)} exited between the liveness check and " <>
            ":erlang.trace/3 (#{Exception.message(e)}); treat as a real early-abort " <>
            "signal, not scheduler delay"
        )
    after
      # The global trace_pattern's disable is handled by the `on_exit`
      # above, unconditionally -- no need to duplicate it here.
      stop_trace(owner_pid)
    end

    assert :ok = PublicationAuthority.abort(authority)
    assert :ok = InstallationCatalog.close(catalog)
  end

  defp run_started?(sink), do: Enum.any?(EventSink.events(sink), &(&1.type == "run-started"))

  defp stop_trace(pid) do
    :erlang.trace(pid, false, [:call])
  catch
    :error, :badarg -> false
  end

  defp trace_calls(patterns) do
    patterns
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.each(&Code.ensure_loaded!/1)

    assert :erlang.trace(:new_processes, true, [:call]) >= 0
    Enum.each(patterns, &assert(:erlang.trace_pattern(&1, true, [:local]) == 1))
  end

  defp stop_trace_calls(patterns) do
    :erlang.trace(:new_processes, false, [:call])
    Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
  end
end
