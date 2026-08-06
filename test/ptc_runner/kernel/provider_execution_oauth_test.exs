defmodule PtcRunner.Kernel.ProviderExecutionOAuthTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
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
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator
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
    assert {:error, :invalid_mcp_transport} = ExecutionSessionOwner.await(owner)
    assert [:token_exchange, :run_started] == [next_event(), next_event()]

    # The run reuses that grant instead of authorizing a second time.
    refute_received {:oauth_request, "POST", "/token"}
    assert_received {:authorization_notice, _url}
    refute_received {:authorization_notice, _other}
  end

  test "a check authorizes exactly as the run it shares its session with" do
    # `--check --authorize-mcp` was deferred to the execution-owner cutover.
    # A check runs the same marker, session, registry, credentials, OAuth, and
    # acquisition prefix, so it stops at the same transport rule as the run
    # above and never reaches a second authorization.
    parent = self()
    server = start_server()
    fixture = provider_fixture(server)
    trace_run_start()

    {:ok, owner} =
      ExecutionSessionOwner.start(
        fixture.prepared,
        fixture.authority,
        self(),
        fixture.execution,
        &visit_authorization_url(parent, &1),
        :check
      )

    assert {:error, :invalid_mcp_transport} = ExecutionSessionOwner.await(owner)
    assert [:token_exchange, :run_started] == [next_event(), next_event()]
    assert_received {:authorization_notice, _url}
    refute_received {:authorization_notice, _other}
    refute_received {:oauth_request, "POST", "/token"}
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

    assert {:error, :invalid_mcp_transport} = ExecutionSessionOwner.await(owner)

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

    # `:kill` is untrappable, so `terminate/2` never runs and nothing here may
    # depend on the owner's own cleanup path. The worker is monitored rather
    # than linked, so this is the case where it could have been left blocked in
    # the OAuth interaction; in practice it unblocks and exits normally.
    Process.exit(owner_pid, :kill)

    Enum.each(references, fn {name, pid, reference} ->
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason},
                     5_000,
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

    assert :erlang.trace_pattern({ProviderActiveSession, :begin_owned_operation, 4}, true, [
             :local
           ]) ==
             1

    assert :erlang.trace(:new_processes, true, [:call]) >= 0

    on_exit(fn ->
      :erlang.trace(:new_processes, false, [:call])
      :erlang.trace_pattern({ProviderActiveSession, :begin_owned_operation, 4}, false, [:local])
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
    host = host(server, installed)
    {:ok, catalog} = HostInstallation.catalog(host)
    {:ok, services} = HostInstallation.runtime_services(host)

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
        "workflow" => [],
        "mission" => Enum.map(names, &%{"name" => &1, "config" => %{}})
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
  defp host(server, names) do
    {:ok, decoded} = HostConfig.decode(host_document(names), "/tmp")

    install =
      Map.new(decoded.install, fn {name, installation} ->
        transport = %{
          installation.transport
          | endpoint: server.endpoint,
            oauth: authority(server.base, name)
        }

        {name, %{installation | transport: transport}}
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

  defp host_document(names) do
    %{"install" => Map.new(names, &{&1, installation_document(&1)})}
  end

  defp installation_document(name) do
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

  defp authority(base, name \\ "fixture") do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => name <> "-primary",
          "issuer" => base <> "/mcp",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
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
