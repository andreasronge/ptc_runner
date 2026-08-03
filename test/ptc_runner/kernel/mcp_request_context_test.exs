defmodule PtcRunner.Kernel.MCPRequestContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.MCPOAuth.TokenManager
  alias PtcRunner.Kernel.MCPRequestContext
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Test.MCPOAuthRecordingStore

  test "owner death closes the credential context" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, context} = context(owner)
    context_ref = Process.monitor(context.pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^context_ref, :process, _pid, reason}
    assert reason in [:normal, :noproc]
  end

  test "close kills and drains an in-flight request caller" do
    {:ok, context} = context(self())
    parent = self()

    caller =
      spawn(fn ->
        assert {:ok, _request} = MCPRequestContext.begin_request(context)
        send(parent, :request_started)
        receive do: (:never -> :ok)
      end)

    caller_ref = Process.monitor(caller)
    context_ref = Process.monitor(context.pid)
    assert_receive :request_started

    assert :ok = MCPRequestContext.close(context)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^context_ref, :process, _pid, :normal}
  end

  test "every concurrent close waits for the same completed shutdown" do
    {:ok, context} = context(self())
    parent = self()

    for index <- 1..64 do
      spawn(fn ->
        assert {:ok, _request} = MCPRequestContext.begin_request(context)
        send(parent, {:request_started, index})
        receive do: (:never -> :ok)
      end)
    end

    for index <- 1..64, do: assert_receive({:request_started, ^index})

    context_ref = Process.monitor(context.pid)

    closers =
      for index <- 1..8 do
        Task.async(fn ->
          result = MCPRequestContext.close(context)
          {index, result, Process.alive?(context.pid)}
        end)
      end

    assert_receive {:DOWN, ^context_ref, :process, _pid, :normal}

    assert Enum.map(closers, &Task.await/1)
           |> Enum.all?(fn {_index, result, alive?} -> result == :ok and not alive? end)
  end

  test "an expired request deadline gets a fresh bounded admission-release budget" do
    parent = self()

    interceptor = fn
      {:release_mcp, _admission}, timeout ->
        send(parent, {:release_timeout, timeout})
        :delegate

      _operation, _timeout ->
        :delegate
    end

    manager = oauth_manager(interceptor)

    {:ok, context} =
      MCPRequestContext.start(
        owner: self(),
        endpoint: manager.resource,
        headers: [],
        timeout_ms: 20,
        authorization: manager
      )

    assert {:ok, _request} = MCPRequestContext.begin_request(context)

    receive do
      _message -> flunk("unexpected message")
    after
      25 -> :ok
    end

    assert :ok = MCPRequestContext.finish_request(context)
    assert_receive {:release_timeout, timeout}
    assert timeout > 4_000
    assert :ok = MCPRequestContext.close(context)
  end

  test "a failed release kills the admitted worker through provider acquisition" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    interceptor = fn
      {:release_mcp, _admission}, _timeout ->
        attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
        if attempt == 0, do: {:return, {:error, :store_error}}, else: :delegate

      _operation, _timeout ->
        :delegate
    end

    manager = oauth_manager(interceptor)

    {:ok, context} =
      MCPRequestContext.start(
        owner: self(),
        endpoint: manager.resource,
        headers: [],
        timeout_ms: 1_000,
        authorization: manager
      )

    parent = self()

    preflighted = %{
      acquire: fn %{} ->
        assert {:ok, _request} = MCPRequestContext.begin_request(context)
        send(parent, :admitted)
        MCPRequestContext.finish_request(context)
        send(parent, :worker_survived)
        %{capabilities: []}
      end,
      provides: [],
      requires: []
    }

    caller =
      spawn(fn ->
        result = ProviderRegistry.acquire(preflighted, %{})
        send(parent, {:acquire_result, result})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive :admitted, 1_000

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    refute_receive :worker_survived
    refute_receive {:acquire_result, _result}
    assert :ok = MCPRequestContext.close(context)
  end

  test "worker death asynchronously retries an admission release the store cannot monitor" do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    interceptor = fn
      {:admit_mcp, _admission, _key, _generation, _worker_pid, _ttl_ms}, _timeout ->
        {:return, {:ok, :durable_admission}}

      {:release_mcp, :durable_admission}, _timeout ->
        attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
        send(parent, {:detached_release, self(), attempt})
        if attempt == 0, do: {:return, {:error, :store_error}}, else: {:return, :ok}

      _operation, _timeout ->
        :delegate
    end

    manager = oauth_manager(interceptor)

    {:ok, context} =
      MCPRequestContext.start(
        owner: self(),
        endpoint: manager.resource,
        headers: [],
        timeout_ms: 1_000,
        authorization: manager
      )

    caller =
      spawn(fn ->
        assert {:ok, _request} = MCPRequestContext.begin_request(context)
        send(parent, {:durable_admission_taken, self()})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:durable_admission_taken, ^caller}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_receive {:detached_release, first_worker, 0}
    refute first_worker == caller
    assert_receive {:detached_release, second_worker, 1}, 1_000
    refute second_worker == caller
    assert :ok = MCPRequestContext.close(context)
  end

  test "a closed request context kills a worker whose admission cannot be acknowledged" do
    {:ok, context} = context(self())
    parent = self()

    caller =
      spawn(fn ->
        assert {:ok, _request} = MCPRequestContext.begin_request(context)
        send(parent, :admitted)

        receive do
          :finish -> MCPRequestContext.finish_request(context)
        end

        send(parent, :worker_survived)
      end)

    caller_ref = Process.monitor(caller)
    assert_receive :admitted
    Process.exit(context.pid, :kill)
    send(caller, :finish)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    refute_receive :worker_survived
  end

  test "caller death while admission returns transfers cleanup to the context" do
    parent = self()

    interceptor = fn
      {:admit_mcp, _admission, _key, _generation, _worker_pid, _ttl_ms}, _timeout ->
        send(parent, {:admission_taken, self()})

        receive do
          :continue -> {:return, {:ok, :durable_admission}}
        end

      {:release_mcp, :durable_admission}, _timeout ->
        send(parent, :admission_released)
        {:return, :ok}

      _operation, _timeout ->
        :delegate
    end

    manager = oauth_manager(interceptor)

    {:ok, context} =
      MCPRequestContext.start(
        owner: self(),
        endpoint: manager.resource,
        headers: [],
        timeout_ms: 10_000,
        authorization: manager
      )

    caller =
      spawn(fn ->
        send(parent, {:begin_result, MCPRequestContext.begin_request(context)})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:admission_taken, admission_worker}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    send(admission_worker, :continue)
    assert_receive :admission_released
    refute_receive {:begin_result, _result}
    assert :ok = MCPRequestContext.close(context)
  end

  test "cleanup retains simultaneous admission release and token persistence" do
    parent = self()
    {:ok, available} = Agent.start_link(fn -> false end)
    {:ok, session} = ProviderSession.start(Limits.defaults())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        if Agent.get(available, & &1), do: :delegate, else: {:return, {:error, :store_error}}

      {:admit_mcp, _admission, _key, _generation, _worker_pid, _ttl_ms}, _timeout ->
        if Agent.get(available, & &1),
          do: :delegate,
          else: {:return, {:ok, :durable_admission}}

      {:release_mcp, :durable_admission}, _timeout ->
        send(parent, :detached_release_attempt)

        if Agent.get(available, & &1),
          do: {:return, :ok},
          else: {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    fixture =
      oauth_manager_fixture(interceptor,
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar
      )

    manager = fixture.manager

    {:ok, context} =
      MCPRequestContext.start(
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar,
        endpoint: manager.resource,
        headers: [],
        timeout_ms: 1_000,
        authorization: manager
      )

    caller =
      spawn(fn ->
        assert {:ok, _request} = MCPRequestContext.begin_request(context)
        send(parent, :combined_request_started)
        receive do: (:finish -> :ok)
      end)

    caller_ref = Process.monitor(caller)
    assert_receive :combined_request_started
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert {:error, :store_error} = TokenManager.reject(manager, 1, deadline)
    send(caller, :finish)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_receive :detached_release_attempt
    assert :ok = ResourceRegistrar.commit(registrar, fn -> MCPRequestContext.close(context) end)

    context_ref = Process.monitor(context.pid)
    manager_ref = Process.monitor(manager.pid)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert Process.alive?(context.pid)
    assert Process.alive?(manager.pid)

    Agent.update(available, fn _available -> true end)
    assert_receive {:DOWN, ^manager_ref, :process, _pid, :normal}, 2_000
    assert_receive {:DOWN, ^context_ref, :process, _pid, :normal}, 31_000
    assert :ok = MCPRequestContext.close(context)

    {:ok, replacement_manager} =
      TokenManager.start(
        owner: self(),
        context: fixture.context,
        authority: fixture.authority,
        authority_epoch: fixture.epoch
      )

    replacement_deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(replacement_manager, replacement_deadline)

    assert :ok = TokenManager.close(replacement_manager)
  end

  test "abnormal session death hands off simultaneous release and persistence" do
    parent = self()
    {:ok, available} = Agent.start_link(fn -> false end)
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 500)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        if Agent.get(available, & &1), do: :delegate, else: {:return, {:error, :store_error}}

      {:admit_mcp, _admission, _key, _generation, _worker_pid, _ttl_ms}, _timeout ->
        {:return, {:ok, :abnormal_admission}}

      {:release_mcp, :abnormal_admission}, _timeout ->
        send(parent, :abnormal_release_attempt)

        if Agent.get(available, & &1),
          do: {:return, :ok},
          else: {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    fixture =
      oauth_manager_fixture(interceptor,
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar
      )

    manager = fixture.manager

    {:ok, context} =
      MCPRequestContext.start(
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar,
        endpoint: manager.resource,
        headers: [],
        timeout_ms: 1_000,
        authorization: manager
      )

    caller = spawn(fn -> assert {:ok, _request} = MCPRequestContext.begin_request(context) end)
    caller_ref = Process.monitor(caller)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_receive :abnormal_release_attempt

    deadline = System.monotonic_time(:millisecond) + 1_000
    assert {:error, :store_error} = TokenManager.reject(manager, 1, deadline)
    assert :ok = ResourceRegistrar.commit(registrar, nil)

    session_ref = Process.monitor(session.pid)
    controller_ref = Process.monitor(registrar.scope_controller)
    context_ref = Process.monitor(context.pid)
    manager_ref = Process.monitor(manager.pid)
    Process.exit(session.pid, :kill)

    assert_receive {:DOWN, ^session_ref, :process, _pid, :killed}
    assert_receive {:DOWN, ^controller_ref, :process, _pid, :killed}, 2_000
    assert Process.alive?(context.pid)
    assert Process.alive?(manager.pid)

    Agent.update(available, fn _available -> true end)
    assert_receive {:DOWN, ^manager_ref, :process, _pid, :normal}, 2_000
    assert_receive {:DOWN, ^context_ref, :process, _pid, :normal}, 2_000
    assert :ok = MCPRequestContext.close(context)
  end

  test "session death during registration returns a transport error" do
    {:ok, session} = ProviderSession.start(Limits.defaults())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    assert true = :erlang.suspend_process(session.pid)

    start =
      Task.async(fn ->
        MCPRequestContext.start(
          owner: ResourceRegistrar.owner(registrar),
          resource_registrar: registrar,
          endpoint: "https://mcp.example/mcp",
          headers: [],
          timeout_ms: 1_000
        )
      end)

    assert nil == Task.yield(start, 50)
    session_ref = Process.monitor(session.pid)
    Process.exit(session.pid, :kill)
    assert_receive {:DOWN, ^session_ref, :process, _pid, :killed}
    assert {:error, :mcp_transport_error} = Task.await(start, 1_000)
  end

  test "retained release survives an unavailable signal owner" do
    parent = self()
    {:ok, available} = Agent.start_link(fn -> false end)
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 200)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    interceptor = fn
      {:admit_mcp, _admission, _key, _generation, _worker_pid, _ttl_ms}, _timeout ->
        {:return, {:ok, :durable_admission}}

      {:release_mcp, :durable_admission}, _timeout ->
        send(parent, :unavailable_owner_release_attempt)

        if Agent.get(available, & &1),
          do: {:return, :ok},
          else: {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    manager = oauth_manager(interceptor)

    {:ok, context} =
      MCPRequestContext.start(
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar,
        endpoint: manager.resource,
        headers: [],
        timeout_ms: 1_000,
        authorization: manager
      )

    caller = spawn(fn -> assert {:ok, _request} = MCPRequestContext.begin_request(context) end)
    caller_ref = Process.monitor(caller)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_receive :unavailable_owner_release_attempt

    assert true = :erlang.suspend_process(ResourceRegistrar.owner(registrar))
    assert :ok = ResourceRegistrar.commit(registrar, fn -> MCPRequestContext.close(context) end)
    context_ref = Process.monitor(context.pid)

    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    assert Process.alive?(context.pid)

    Agent.update(available, fn _available -> true end)
    assert_receive {:DOWN, ^context_ref, :process, _pid, :normal}, 10_000
    assert :ok = TokenManager.close(manager)
  end

  test "a stopped token manager closes request admission without leaking its internal error" do
    manager = oauth_manager(fn _operation, _timeout -> :delegate end)

    {:ok, context} =
      MCPRequestContext.start(
        owner: self(),
        endpoint: manager.resource,
        headers: [],
        timeout_ms: 1_000,
        authorization: manager
      )

    assert :ok = TokenManager.close(manager)
    assert {:error, :closed} = MCPRequestContext.begin_request(context)
    assert :ok = MCPRequestContext.close(context)
  end

  defp context(owner) do
    MCPRequestContext.start(
      owner: owner,
      endpoint: "https://example.com/mcp",
      headers: [{"authorization", "Bearer PRIVATE"}],
      timeout_ms: 1_000
    )
  end

  defp oauth_manager(interceptor) do
    oauth_manager_fixture(interceptor).manager
  end

  defp oauth_manager_fixture(interceptor, opts \\ []) do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "request-context-test",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        },
        "https://mcp.example/mcp",
        MapSet.new()
      )

    {:ok, memory} = Memory.start_link(owner: self())
    {:ok, store} = Memory.store(memory)
    {:ok, context} = Context.new(tenant_id: "tenant", principal_id: "alice", store: store)

    {:ok, claims} =
      Store.claim_authorities(
        store,
        context.tenant_id,
        [{authority.installation_id, authority.fingerprint}],
        1_000
      )

    epoch = claims[authority.installation_id]
    key = Context.grant_key(context, authority, epoch)
    {:ok, anchor} = Store.time_anchor(store, 1_000)
    {:ok, lease} = Store.acquire_mutation(store, key, :authorization, 5_000, 1_000)

    :ok =
      Store.begin_mutation_dispatch(
        store,
        key,
        lease.fence,
        %{freshness_anchor: anchor, freshness_anchor_ttl_ms: 5_000},
        1_000
      )

    {:ok, _grant} =
      Store.commit_grant(
        store,
        key,
        lease.fence,
        %{
          access_token: "access",
          requested_scopes: MapSet.new(["read"]),
          granted_scopes: MapSet.new(["read"]),
          refresh_authorized: false,
          redirect_uri: "http://127.0.0.1:49152/callback",
          metadata_revision: 1,
          metadata_binding: nil
        },
        60_000,
        anchor,
        1_000
      )

    {:ok, recording_store} =
      MCPOAuthRecordingStore.wrap(store, self(), interceptor: interceptor)

    {:ok, wrapped_context} =
      Context.new(
        tenant_id: context.tenant_id,
        principal_id: context.principal_id,
        store: recording_store
      )

    {:ok, manager} =
      TokenManager.start(
        owner: Keyword.get(opts, :owner, self()),
        resource_registrar: Keyword.get(opts, :resource_registrar),
        context: wrapped_context,
        authority: authority,
        authority_epoch: epoch
      )

    %{manager: manager, context: wrapped_context, authority: authority, epoch: epoch}
  end
end
