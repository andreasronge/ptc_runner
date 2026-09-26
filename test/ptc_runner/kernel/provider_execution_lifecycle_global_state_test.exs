defmodule PtcRunner.Kernel.ProviderExecutionLifecycleGlobalStateTest do
  use ExUnit.Case, async: false
  import PtcRunner.TestSupport.ProviderExecutionLifecycleFixture
  import PtcRunner.TestSupport.ProviderExecutionFixture

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]
  import PtcRunner.TestSupport.TestHelpers, only: [long_running_body: 0]

  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession

  test "caller death runs a committed closer before the runtime that produced it closes" do
    # A committed provider closer belongs to the runtime that acquired it: it
    # may still release an admission, persist a token response, or reach the
    # authority the registry holds. Aborting must therefore close the session
    # first and leave that runtime standing until the closer has settled.
    parent = self()

    fixture =
      provider_fixture(
        body: long_running_body(),
        acquire: fn context ->
          scoped_root(parent, context)
          {:ok, capability} = fixture_capability()

          {:ok,
           %{
             capabilities: [capability],
             close: fn ->
               send(parent, {:provider_closing, self()})
               receive do: (:release -> :ok)
             end
           }}
        end
      )

    started = start_owned_execution(fixture)
    state = await_state(started.owner_pid, & &1.registry)

    # Killing on the acquire callback would race `ResourceRegistrar.commit/2`,
    # so wait until the session actually holds the committed closer.
    assert_eventually(fn -> :sys.get_state(state.provider_session.pid).committed != [] end)

    trace_closes(started.owner_pid)

    try do
      Process.exit(started.caller, :kill)

      # The session is the first thing the abort closes...
      assert ProviderSession == next_close()
      assert_receive {:provider_closing, closer}, 5_000

      # ...and the owner is blocked inside that close while the committed closer
      # runs, so nothing can have unwound the registry underneath it yet.
      refute_received {:trace, _owner, :call, {ProviderRegistry, :close, _arguments}}

      send(closer, :release)
      assert ProviderRegistry == next_close()
    after
      stop_trace_closes(started.owner_pid)
    end

    refute_received {:execution_result, _result}
  end

  test "caller death while acquisition blocks closes the session before the registry" do
    parent = self()

    fixture =
      provider_fixture(
        acquire: fn context ->
          scoped_root(parent, context)
          send(parent, {:blocked_in, :provider_acquire, self()})
          block_forever()
        end
      )

    started = start_owned_execution(fixture)
    assert_receive {:provider_root, root, :ok}, 5_000
    assert_receive {:blocked_in, :provider_acquire, acquirer}, 5_000
    state = :sys.get_state(started.owner_pid)
    assert ProviderSession.valid?(state.provider_session)
    assert ProviderRegistry.valid?(state.registry)

    watched =
      watch(%{
        owner: started.owner_pid,
        worker: state.worker_pid,
        session: state.provider_session.pid,
        provider_root: root,
        acquirer: acquirer,
        event_sink: state.opened_sinks.event_sink.pid,
        activity: fixture.prepared.provider_activity.owner
      })

    trace_closes(started.owner_pid)

    try do
      Process.exit(started.caller, :kill)

      assert [ProviderSession, ProviderRegistry] == [next_close(), next_close()]
      assert_all_down(watched)
    after
      stop_trace_closes(started.owner_pid)
    end

    refute_received {:execution_result, _result}
  end

  test "connectivity closes its provider session inside the runtime that acquired it" do
    # A connectivity acquisition commits real closers to the session, so
    # unwinding the registry first would run them against a runtime that is
    # already gone. An independent review found the inversion; this is what
    # would have caught it.
    fixture = provider_fixture([connectivity_mode: :acquisition] ++ closing_acquire())
    assert_session_closes_before_registry(fixture, :connect)
  end
end
