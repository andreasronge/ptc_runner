defmodule PtcRunner.Kernel.ProviderExecutionOAuthGlobalStateTest do
  # async: false — these cases trace :new_processes or set call trace patterns VM-wide, stop and
  # restart :req_llm, or mutate the OS environment (class D). The rest of OAuth provider
  # execution coverage is async in ProviderExecutionOAuthTest.
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.ProviderExecutionOAuthFixtures

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.TestSupport.LLMSupport

  @close_targets [
    {LoopbackListener, :close, 1},
    {ProviderRegistry, :close, 1},
    {Memory, :close, 1},
    {ProviderSession, :close, 1}
  ]

  # Acquisition itself cannot run here: `HostInstallation` never passes
  # `allow_insecure_loopback` to `MCPSource.builder/1`, so a host-installed
  # streamable-HTTP transport always requires HTTPS. The run therefore stops at
  # that rule, which is exactly what makes this a clean probe of everything
  # before it — the authorization interaction and the run clock that follows it.
  # Carrying the resulting bearer across the real MCP protocol boundary is
  # covered separately by the credential-free Go OAuth end-to-end test; no
  # single test spans both halves.
  test "one explicit authorization precedes the run it hands its context to" do
    parent = self()
    server = start_server(hold_token?: true)
    fixture = provider_fixture(server)
    trace_run_start()

    {:ok, owner} =
      ExecutionSessionOwner.start(
        fixture.prepared,
        fixture.authority,
        self(),
        fixture.execution,
        &visit_authorization_url(parent, &1)
      )

    # While the token exchange is still in flight the ordinary run clock must
    # not have started, so authorization never spends the run budget.
    assert_receive {:token_pending, exchange}, 5_000

    refute_received {:trace, _pid, :call,
                     {ProviderActiveSession, :begin_owned_operation, _arguments}}

    send(exchange, :release_token)

    assert {:error, %CommandDiagnostic{} = transport_stop} =
             ExecutionSessionOwner.await(owner)

    # The HTTPS-only transport rule is where an in-process OAuth run stops, and
    # that stop is now classified: the provider could not be acquired, named by
    # occurrence. Reaching it is still the evidence that authorization settled
    # and the run got as far as acquisition.
    assert transport_stop.phase == :provider_acquisition
    assert transport_stop.code == :provider_unavailable

    # `provider_unavailable` also covers a plain connection failure, so naming
    # the occurrence is what keeps this pinned to the builder-validation stop
    # rather than to any transport fault that happened to occur.
    assert transport_stop.subject.name == "fixture"
    assert transport_stop.subject.operation == :acquisition
    assert transport_stop.subject.occurrence == %{destination: :mission, index: 0}
    assert [:token_exchange, :run_started] == [next_event(), next_event()]

    # The run reuses that grant instead of authorizing a second time.
    refute_received {:oauth_request, "POST", "/token"}
    assert_received {:authorization_notice, _url}
    refute_received {:authorization_notice, _other}
  end

  test "a credential failure after authorization preserves provider activity" do
    initially_started =
      Application.started_applications()
      |> MapSet.new(&elem(&1, 0))

    {:ok, started} = Application.ensure_all_started(:req_llm)

    on_exit(fn ->
      started
      |> Enum.reverse()
      |> Enum.reject(&MapSet.member?(initially_started, &1))
      |> Enum.each(&Application.stop/1)
    end)

    missing_env = "PTC_OAUTH_POST_AUTH_MISSING_CREDENTIAL"
    previous_env = System.get_env(missing_env)
    System.delete_env(missing_env)

    on_exit(fn ->
      if previous_env,
        do: System.put_env(missing_env, previous_env),
        else: System.delete_env(missing_env)
    end)

    parent = self()
    server = start_server()

    fixture =
      provider_fixture(server, ["fixture", "credentialed"],
        authorize: ["fixture"],
        credential_alias: "credentialed",
        credential_env: missing_env
      )

    {:ok, owner} =
      ExecutionSessionOwner.start(
        fixture.prepared,
        fixture.authority,
        self(),
        fixture.execution,
        &visit_authorization_url(parent, &1)
      )

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             ExecutionSessionOwner.await(owner)

    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :credential_unavailable
    assert diagnostic.provider_activity
    assert diagnostic.subject.name == "credentialed"
    assert_receive {:oauth_request, "POST", "/token"}, 5_000
  end

  test "authorization registry timeout preserves the attempted prefix" do
    isolate_provider_applications()

    server = start_server()

    for {label, fixture_options, expected_activity} <- [
          {:inactive, [], false},
          {:application_started,
           [
             names: ["fixture", "model"],
             credential_alias: "model",
             credential_env: "PTC_OAUTH_UNUSED_CREDENTIAL",
             provider_application_mode: :command_vm
           ], true}
        ] do
      names = Keyword.get(fixture_options, :names, ["fixture"])

      fixture =
        provider_fixture(
          server,
          names,
          fixture_options
          |> Keyword.delete(:names)
          |> Keyword.merge(
            authorize: ["fixture"],
            authorization_timeout_ms: 100,
            activation_delay_ms: 150,
            activation_label: label
          )
        )

      assert {:error, %CommandDiagnostic{} = diagnostic} =
               RunCoordinator.execute(
                 fixture.prepared,
                 fixture.authority,
                 fixture.execution,
                 fn _url -> flunk("registry timeout must precede operator interaction") end
               )

      assert_received {:registry_activation_started, ^label}
      assert diagnostic.phase == :active_preflight
      assert diagnostic.code == :authorization_unavailable

      assert diagnostic.provider_activity == expected_activity,
             "#{label} registry timeout reported unexpected provider activity"

      refute_received {:oauth_request, _method, _path}
    end
  end

  test "selected authorities share one execution-scoped OAuth context" do
    parent = self()
    server = start_server()
    fixture = provider_fixture(server, ["fixture", "second"])
    trace_oauth_stores()

    {:ok, owner} =
      ExecutionSessionOwner.start(
        fixture.prepared,
        fixture.authority,
        self(),
        fixture.execution,
        &visit_authorization_url(parent, &1)
      )

    assert {:error, %CommandDiagnostic{} = transport_stop} =
             ExecutionSessionOwner.await(owner)

    # The HTTPS-only transport rule is where an in-process OAuth run stops, and
    # that stop is now classified: the provider could not be acquired, named by
    # occurrence. Reaching it is still the evidence that authorization settled
    # and the run got as far as acquisition.
    assert transport_stop.phase == :provider_acquisition
    assert transport_stop.code == :provider_unavailable

    # `provider_unavailable` also covers a plain connection failure, so naming
    # the occurrence is what keeps this pinned to the builder-validation stop
    # rather than to any transport fault that happened to occur.
    assert transport_stop.subject.name == "fixture"
    assert transport_stop.subject.operation == :acquisition
    assert transport_stop.subject.occurrence == %{destination: :mission, index: 0}

    # Each selected authority interacts on its own anchor...
    assert_receive {:authorization_notice, _first}, 5_000
    assert_receive {:authorization_notice, _second}, 5_000

    # ...but the execution opens exactly one store to back their shared context.
    assert_receive {:trace, _pid, :call, {Memory, :start, _arguments}}, 5_000
    refute_received {:trace, _pid, :call, {Memory, :start, _other}}
  end

  test "caller death during the OAuth interaction unwinds every tracked resource in order" do
    parent = self()
    server = start_server()
    fixture = provider_fixture(server)

    caller = spawn_blocked_caller(parent, fixture)

    assert_receive {:execution_owner, owner}, 5_000
    owner_pid = ExecutionSessionOwner.pid(owner)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:blocked_in_notifier, _url}, 5_000

    state = :sys.get_state(owner_pid)
    assert %LoopbackListener{} = state.oauth_listener
    assert %Memory{} = state.oauth_memory
    assert ProviderRegistry.valid?(state.registry)
    assert ProviderSession.valid?(state.provider_session)

    # All four are live while the interaction blocks, so the unwind below is
    # ordering real resources rather than four no-ops.
    assert match?({:ok, _address}, :inet.sockname(state.oauth_listener.socket))
    assert Process.alive?(state.oauth_memory.pid)
    assert Process.alive?(state.registry.authority_owner.pid)
    assert Process.alive?(state.provider_session.pid)

    watched = [
      owner_pid,
      state.worker_pid,
      state.provider_session.pid,
      state.registry.authority_owner.pid,
      state.opened_sinks.event_sink.pid,
      fixture.prepared.provider_activity.owner
    ]

    references = Enum.map(watched, &{&1, Process.monitor(&1)})
    store_reference = Process.monitor(state.oauth_memory.pid)
    trace_resource_closes(owner_pid)

    try do
      # The session closes first because its committed closers still belong to
      # this runtime; the listener, registry, and store it depended on unwind
      # only once that cleanup has settled.
      Process.exit(caller, :kill)

      assert [ProviderSession, LoopbackListener, ProviderRegistry, Memory] ==
               [next_close(), next_close(), next_close(), next_close()]

      # `:normal` rather than `:killed` is the point: the store is owned by the
      # lifecycle owner, so killing the blocked worker no longer destroys the
      # store a session closer would still need.
      store_pid = state.oauth_memory.pid
      assert_receive {:DOWN, ^store_reference, :process, ^store_pid, :normal}, 5_000

      Enum.each(references, fn {pid, reference} ->
        assert_receive {:DOWN, ^reference, :process, ^pid, _reason}, 5_000
      end)
    after
      stop_resource_closes(owner_pid)
    end

    # The loopback port is gone with its listener, not merely unreferenced.
    refute match?({:ok, _address}, :inet.sockname(state.oauth_listener.socket))
    refute_received {:execution_result, _result}
  end

  defp trace_resource_closes(owner_pid) do
    Enum.each(@close_targets, fn {module, _function, _arity} -> Code.ensure_loaded!(module) end)
    Enum.each(@close_targets, &assert(:erlang.trace_pattern(&1, true, [:local]) == 1))
    assert :erlang.trace(owner_pid, true, [:call]) == 1
  end

  defp stop_resource_closes(owner_pid) do
    Enum.each(@close_targets, &:erlang.trace_pattern(&1, false, [:local]))
    :erlang.trace(owner_pid, false, [:call])
  catch
    :error, :badarg -> false
  end

  defp next_close do
    assert_receive {:trace, _owner, :call, {module, :close, _arguments}}, 5_000
    module
  end

  test "command-owned application startup is retained by an OAuth pre-refusal" do
    isolate_provider_applications()

    server = start_server()

    fixture =
      provider_fixture(server, ["fixture", "model"],
        authorize: [],
        credential_alias: "model",
        credential_env: "PTC_OAUTH_UNUSED_CREDENTIAL",
        provider_application_mode: :command_vm
      )

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             RunCoordinator.execute(
               fixture.prepared,
               fixture.authority,
               fixture.execution,
               fn _url -> flunk("a refused selection must never open an interaction") end
             )

    assert diagnostic.code == :authorization_required
    assert diagnostic.provider_activity
    assert :req_llm in Enum.map(Application.started_applications(), &elem(&1, 0))
    refute_received {:oauth_request, _method, _path}
  end

  defp isolate_provider_applications do
    snapshot = LLMSupport.snapshot_provider_applications()
    :ok = LLMSupport.stop_provider_applications()
    on_exit(fn -> LLMSupport.restore_provider_applications(snapshot) end)
  end

  defp trace_oauth_stores do
    Code.ensure_loaded!(Memory)
    assert :erlang.trace_pattern({Memory, :start, 1}, true, [:local]) == 1
    assert :erlang.trace(:new_processes, true, [:call]) >= 0

    on_exit(fn ->
      :erlang.trace(:new_processes, false, [:call])
      :erlang.trace_pattern({Memory, :start, 1}, false, [:local])
    end)
  end

  defp trace_run_start do
    Code.ensure_loaded!(ProviderActiveSession)

    assert :erlang.trace_pattern({ProviderActiveSession, :begin_owned_operation, 5}, true, [
             :local
           ]) ==
             1

    assert :erlang.trace(:new_processes, true, [:call]) >= 0

    on_exit(fn ->
      :erlang.trace(:new_processes, false, [:call])
      :erlang.trace_pattern({ProviderActiveSession, :begin_owned_operation, 5}, false, [:local])
    end)
  end

  # `assert_receive` scans the whole mailbox, so ordering has to be read from
  # the next event of interest rather than from two independent matches.
  defp next_event do
    receive do
      {:oauth_request, "POST", "/token"} ->
        :token_exchange

      {:trace, _pid, :call, {ProviderActiveSession, :begin_owned_operation, _arguments}} ->
        :run_started

      {:oauth_request, _method, _path} ->
        next_event()

      {:trace, _pid, :call, _mfa} ->
        next_event()
    after
      5_000 -> flunk("no authorization or run event arrived")
    end
  end
end
