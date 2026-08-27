defmodule PtcRunner.Kernel.ProviderExecutionOAuthTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.Discovery
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.MCPHTTPFixture

  test "OAuth setup and each requested target use their exact independent deadlines" do
    declarations = [
      %{name: "first", config: %{"timeout_ms" => 5_000}},
      %{name: "plain", config: %{"timeout_ms" => 1}},
      %{name: "first", config: %{"timeout_ms" => 2_000}},
      %{name: "second", config: %{"timeout_ms" => 3_000}}
    ]

    authorities = %{
      "first" => %{authorization_timeout_ms: 7_000},
      "plain" => nil,
      "second" => %{authorization_timeout_ms: 4_000}
    }

    setup =
      ProviderExecution.oauth_setup_deadline(
        declarations,
        authorities,
        ["second", "first"],
        1_000
      )

    first = ProviderExecution.oauth_target_deadline("first", declarations, authorities, 10_000)
    second = ProviderExecution.oauth_target_deadline("second", declarations, authorities, 20_000)

    assert Deadline.expires_at(setup) == 3_000
    assert Deadline.expires_at(first) == 12_000
    assert Deadline.expires_at(second) == 23_000
  end

  test "loopback discovery fixture satisfies the shipped discovery boundary" do
    server = start_server()
    authority = authority(server.base)

    assert {:ok, binding} = Discovery.discover(authority, deadline_ms: expires_in(5_000))
    assert binding.authorization_server.token_endpoint == server.base <> "/token"
    assert binding.client.client_id == "fixture-client"
  end

  test "loopback authorization fixture completes a real code exchange" do
    server = start_server()
    authority = authority(server.base)
    {:ok, memory} = Memory.start(owner: self())
    on_exit(fn -> Memory.close(memory) end)
    {:ok, store} = Memory.store(memory)
    deadline = Deadline.new(5_000)

    {:ok, context} =
      OAuthContext.new(
        tenant_id: "local-cli",
        principal_id: "local-user",
        store: store,
        deadline: deadline
      )

    {:ok, claims} =
      Store.claim_authorities(
        store,
        context.tenant_id,
        [{authority.installation_id, authority.fingerprint}],
        deadline
      )

    {:ok, listener} = LoopbackListener.start(authority)
    on_exit(fn -> LoopbackListener.close(listener) end)

    assert {:ok, pending} =
             Authorization.begin_authorization(context, authority,
               authority_epoch: claims[authority.installation_id],
               deadline_ms: Deadline.expires_at(deadline),
               redirect_uri: listener.redirect_uri
             )

    visit_authorization_url(self(), pending.url)

    assert {:ok, grant} =
             LoopbackListener.await(listener, context, pending,
               anchor_cleanup_deadline: fn -> {:ok, Deadline.new(5_000)} end
             )

    assert grant.status == :active
    assert grant.granted_scopes == MapSet.new(["read"])
    assert grant.access_token == "fixture-access-token"
    assert_receive {:oauth_request, "POST", "/token"}, 5_000
  end

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

    caller =
      spawn(fn ->
        {:ok, owner} =
          ExecutionSessionOwner.start(
            fixture.prepared,
            fixture.authority,
            self(),
            fixture.execution,
            fn url ->
              send(parent, {:blocked_in_notifier, url})
              receive do: (:never -> :never)
            end
          )

        send(parent, {:execution_owner, owner})
        send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
      end)

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

  @close_targets [
    {LoopbackListener, :close, 1},
    {ProviderRegistry, :close, 1},
    {Memory, :close, 1},
    {ProviderSession, :close, 1}
  ]

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

  test "a notifier that refuses names the provider in its authorization diagnostic" do
    server = start_server()
    fixture = provider_fixture(server)

    {:ok, owner} =
      ExecutionSessionOwner.start(
        fixture.prepared,
        fixture.authority,
        self(),
        fixture.execution,
        fn _url -> raise "the operator could not be reached" end
      )

    assert {:error, %CommandDiagnostic{} = diagnostic} = ExecutionSessionOwner.await(owner)
    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :authorization_unavailable
    assert diagnostic.subject.name == "fixture"
    assert diagnostic.subject.operation == :authorization
    refute_received {:oauth_request, "POST", "/token"}
  end

  test "a selected OAuth provider nobody authorized is refused before the interaction" do
    # Standalone V1 disables OAuth execution, so a selection nobody named with
    # `--authorize-mcp` has no grant and no store to find one in. Without the
    # up-front refusal this run reaches acquisition against an empty store and
    # stops at the HTTPS-only transport rule as `provider_acquisition` /
    # `provider_unavailable` — an accurate description of the wrong thing, since
    # the transport is not what is missing.
    server = start_server()
    fixture = provider_fixture(server, ["fixture"], authorize: [])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             RunCoordinator.execute(
               fixture.prepared,
               fixture.authority,
               fixture.execution,
               fn _url -> flunk("a refused selection must never open an interaction") end
             )

    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :authorization_required
    refute diagnostic.provider_activity
    assert diagnostic.subject.name == "fixture"
    assert diagnostic.subject.operation == :authorization
    assert diagnostic.subject.occurrence == nil

    # The refusal is past the lifecycle marker rather than one of the
    # pre-session ones, but the marker is not activity evidence. The preparation
    # was consumed and is no longer reusable while no OAuth endpoint — discovery,
    # authorization URL, or token exchange — was reached.
    refute PreparedRun.valid?(fixture.prepared)
    refute_received {:oauth_request, _method, _path}
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

  test "one unauthorized selection refuses before another one's interaction opens" do
    # Both are selected and OAuth-capable, and only "fixture" was named. The
    # refusal precedes the interactive branch entirely, so the operator is never
    # walked through a browser round trip for a command that cannot succeed.
    server = start_server()

    fixture =
      provider_fixture(server, ["fixture", "second"], authorize: ["fixture"])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             RunCoordinator.execute(
               fixture.prepared,
               fixture.authority,
               fixture.execution,
               fn _url -> flunk("a refused selection must never open an interaction") end
             )

    assert diagnostic.code == :authorization_required
    assert diagnostic.subject.name == "second"
    refute_received {:oauth_request, _method, _path}
  end

  test "authorizing a provider the run never selected leaves the prepared run reusable" do
    server = start_server()

    # Both are installed and OAuth-capable, but only "fixture" is selected.
    fixture =
      provider_fixture(server, ["fixture"],
        installed: ["fixture", "second"],
        authorize: ["second"]
      )

    assert {:error, :invalid_provider_execution} =
             RunCoordinator.execute(
               fixture.prepared,
               fixture.authority,
               fixture.execution,
               &visit_authorization_url(self(), &1)
             )

    assert PreparedRun.valid?(fixture.prepared)
    assert ProviderActivity.value(fixture.prepared.provider_activity) == false
    refute_received {:oauth_request, _method, _path}
    assert :ok = PreparedRun.close(fixture.prepared)
  end

  test "forced owner death strands no worker, session, store, or listener" do
    parent = self()
    server = start_server()
    fixture = provider_fixture(server)

    caller =
      spawn(fn ->
        {:ok, owner} =
          ExecutionSessionOwner.start(
            fixture.prepared,
            fixture.authority,
            self(),
            fixture.execution,
            fn url ->
              send(parent, {:blocked_in_notifier, url})
              receive do: (:never -> :never)
            end
          )

        send(parent, {:execution_owner, owner})
        send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
      end)

    assert_receive {:execution_owner, owner}, 5_000
    owner_pid = ExecutionSessionOwner.pid(owner)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:blocked_in_notifier, _url}, 5_000

    state = :sys.get_state(owner_pid)

    watched = [
      worker: state.worker_pid,
      session: state.provider_session.pid,
      oauth_store: state.oauth_memory.pid,
      registry_authority: state.registry.authority_owner.pid,
      event_sink: state.opened_sinks.event_sink.pid,
      run_activity: fixture.prepared.provider_activity.owner
    ]

    # Everything must still be running, so the assertions below cannot pass by
    # observing something that had already finished on its own.
    Enum.each(watched, fn {name, pid} ->
      assert Process.alive?(pid), "#{name} was already gone before the kill"
    end)

    assert match?({:ok, _address}, :inet.sockname(state.oauth_listener.socket))
    references = Enum.map(watched, fn {name, pid} -> {name, pid, Process.monitor(pid)} end)
    cleanup_timeout_ms = ProviderSession.cleanup_timeout(state.provider_session)

    # `:kill` is untrappable, so `terminate/2` never runs and nothing here may
    # depend on the owner's own cleanup path. The worker is monitored rather
    # than linked, so this is the case where it could have been left blocked in
    # the OAuth interaction; in practice it unblocks and exits normally.
    Process.exit(owner_pid, :kill)

    Enum.each(references, fn {name, pid, reference} ->
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason},
                     cleanup_timeout_ms + 1_000,
                     "#{name} outlived the killed owner"
    end)

    refute match?({:ok, _address}, :inet.sockname(state.oauth_listener.socket))
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

  defp expires_in(milliseconds), do: Deadline.expires_at(Deadline.new(milliseconds))

  defp provider_fixture(server, names \\ ["fixture"], opts \\ []) do
    installed = Keyword.get(opts, :installed, names)
    credential_alias = Keyword.get(opts, :credential_alias)
    host = host(server, installed, opts)
    {:ok, catalog} = HostInstallation.catalog(host)

    {:ok, services} =
      HostInstallation.runtime_services(host,
        provider_application_mode: Keyword.get(opts, :provider_application_mode, :host_owned)
      )

    services = maybe_delay_activation(services, opts)

    {:ok, execution} =
      ProviderExecution.new(catalog, services, Keyword.get(opts, :authorize, names))

    {:ok, authority} = PublicationAuthority.new([])

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" =>
          names
          |> Enum.filter(&(&1 == credential_alias))
          |> Enum.map(&%{"name" => &1, "config" => %{}}),
        "mission" =>
          names
          |> Enum.reject(&(&1 == credential_alias))
          |> Enum.map(&%{"name" => &1, "config" => %{}})
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    %{prepared: prepared, catalog: catalog, execution: execution, authority: authority}
  end

  # Host configuration deliberately refuses insecure loopback OAuth, so the
  # fixture decodes a normal HTTPS installation and then rebinds only the
  # transport endpoint and authority to the loopback server under test.
  defp host(server, names, opts) do
    {:ok, decoded} = HostConfig.decode(host_document(names, opts), "/tmp")

    install =
      Map.new(decoded.install, fn {name, installation} ->
        if installation.source == :mcp do
          transport = %{
            installation.transport
            | endpoint: server.endpoint,
              oauth: authority(server.base, name, opts)
          }

          {name, %{installation | transport: transport}}
        else
          {name, installation}
        end
      end)

    struct!(HostConfig,
      path: "/tmp/ptc-host.json",
      directory: "/tmp",
      runtime: decoded.runtime,
      limits: decoded.limits,
      credentials: decoded.credentials,
      install: install
    )
  end

  defp host_document(names, opts) do
    credential_alias = Keyword.get(opts, :credential_alias)
    credential_env = Keyword.get(opts, :credential_env)

    document = %{
      "install" =>
        Map.new(names, fn name ->
          installation =
            if name == credential_alias,
              do: credentialed_installation_document(),
              else: installation_document(name, opts)

          {name, installation}
        end)
    }

    if credential_alias,
      do: Map.put(document, "credentials", %{"missing" => %{"env" => credential_env}}),
      else: document
  end

  defp credentialed_installation_document do
    %{
      "source" => "llm",
      "structured_output_mode" => "unsupported",
      "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
      "installation_revision" => "credentialed-v1",
      "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
      "credential" => "missing"
    }
  end

  defp installation_document(name, opts) do
    %{
      "source" => "mcp",
      "installation_revision" => "fixture-v1",
      "transport" => %{
        "type" => "streamable_http",
        "endpoint" => "https://mcp.example/mcp",
        "oauth" => %{
          "installation_id" => name <> "-primary",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
          "authorization_timeout_ms" => Keyword.get(opts, :authorization_timeout_ms, 300_000),
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "fixture-client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        }
      },
      "tools" => %{"echo" => %{"as" => name <> ".echo", "effect" => "read"}}
    }
  end

  defp maybe_delay_activation(services, opts) do
    case Keyword.get(opts, :activation_delay_ms) do
      nil ->
        services

      delay_ms ->
        original = services.activation
        label = Keyword.fetch!(opts, :activation_label)
        parent = self()

        activation = fn ->
          result = original.()
          send(parent, {:registry_activation_started, label})
          yield_until(System.monotonic_time(:millisecond) + delay_ms)
          result
        end

        reseal_services(%{services | activation: activation})
    end
  end

  defp reseal_services(services) do
    payload =
      {services.activation, services.credential_resolver, services.provider_application_mode,
       services.oauth_mode, services.runtime_binding, services.host_payload}

    %{services | attestation: Attestation.attest(ProviderRuntimeServices, payload)}
  end

  defp yield_until(deadline_ms) do
    if System.monotonic_time(:millisecond) < deadline_ms do
      :erlang.yield()
      yield_until(deadline_ms)
    end
  end

  # Stands in for the operator opening the one-time authorization URL: the
  # authorization server would redirect the browser to the loopback listener.
  defp visit_authorization_url(parent, url) do
    query = URI.parse(url).query |> URI.decode_query()
    redirect = URI.parse(query["redirect_uri"])

    callback =
      URI.to_string(%{
        redirect
        | query:
            URI.encode_query(%{
              "code" => "fixture-code",
              "state" => query["state"],
              "iss" => query["resource"] |> issuer_of()
            })
      })

    send(parent, {:authorization_notice, url})
    spawn(fn -> get(callback) end)
    :ok
  end

  defp issuer_of(resource), do: resource

  defp get(url) do
    uri = URI.parse(url)
    path = uri.path <> "?" <> uri.query

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\nConnection: close\r\n\r\n"
      )

    _response = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
  end

  defp authority(base, name \\ "fixture", opts \\ []) do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => name <> "-primary",
          "issuer" => base <> "/mcp",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
          "authorization_timeout_ms" => Keyword.get(opts, :authorization_timeout_ms, 300_000),
          "network" => %{
            "additional_origins" => [],
            "private_network_origins" => [base]
          },
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "fixture-client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        },
        base <> "/mcp",
        MapSet.new(),
        allow_insecure_loopback: true
      )

    authority
  end

  defp start_server(opts \\ []) do
    parent = self()
    hold_token? = Keyword.get(opts, :hold_token?, false)

    fixture =
      MCPHTTPFixture.start(fn request ->
        send(parent, {:oauth_request, request.method, request.path})

        if hold_token? and request.path == "/token" do
          send(parent, {:token_pending, self()})
          receive do: (:release_token -> :ok)
        end

        respond(request)
      end)

    base = String.replace_suffix(fixture.endpoint, "/mcp", "")
    on_exit(fixture.close)
    %{base: base, endpoint: fixture.endpoint, close: fixture.close}
  end

  defp respond(%{method: "POST", path: "/mcp", headers: headers, body: body}) do
    if Map.has_key?(headers, "authorization") do
      mcp_response(body)
    else
      {401, [{"www-authenticate", ~s(Bearer scope="read")}], ""}
    end
  end

  defp respond(%{method: "GET", path: "/.well-known/oauth-protected-resource/mcp"} = request) do
    base = base_of(request)

    json(%{
      "resource" => base <> "/mcp",
      "authorization_servers" => [base <> "/mcp"],
      "scopes_supported" => ["read"]
    })
  end

  defp respond(%{method: "GET", path: "/.well-known/oauth-authorization-server/mcp"} = request) do
    base = base_of(request)

    json(%{
      "issuer" => base <> "/mcp",
      "authorization_endpoint" => base <> "/authorize",
      "token_endpoint" => base <> "/token",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code"],
      "response_modes_supported" => ["query"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "scopes_supported" => ["read"],
      "authorization_response_iss_parameter_supported" => true
    })
  end

  defp respond(%{method: "POST", path: "/token", body: body}) do
    form = URI.decode_query(body)

    if form["grant_type"] == "authorization_code" and form["code"] == "fixture-code" and
         is_binary(form["code_verifier"]) do
      json(%{
        "access_token" => "fixture-access-token",
        "token_type" => "Bearer",
        "expires_in" => 3_600,
        "scope" => "read"
      })
    else
      {400, [{"content-type", "application/json"}], ~s({"error":"invalid_grant"})}
    end
  end

  defp respond(_request), do: {404, [{"content-type", "application/json"}], "{}"}

  defp mcp_response(%{"method" => "server/discover", "id" => id}) do
    rpc(id, %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp mcp_response(%{"method" => "tools/list", "id" => id}) do
    rpc(id, %{
      "resultType" => "complete",
      "tools" => [
        %{
          "name" => "echo",
          "description" => "Fixture tool.",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"]
          }
        }
      ],
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp mcp_response(%{"id" => id}), do: rpc(id, %{"resultType" => "complete"})
  defp mcp_response(_body), do: {400, [{"content-type", "application/json"}], "{}"}

  defp rpc(id, result) do
    {200, [{"content-type", "application/json"}],
     Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
  end

  defp base_of(%{headers: %{"host" => host}}), do: "http://" <> host

  defp json(document) do
    {200, [{"content-type", "application/json"}, {"cache-control", "max-age=120"}],
     Jason.encode!(document)}
  end
end
