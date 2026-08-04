defmodule PtcRunner.Kernel.MCPOAuth.TokenManagerTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Binding
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.Discovery
  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanup
  alias PtcRunner.Kernel.MCPOAuth.Metadata
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.MCPOAuth.TokenManager
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Test.MCPOAuthRecordingStore

  setup do
    authority = authority()
    {:ok, memory} = Memory.start_link(owner: self())
    {:ok, store} = Memory.store(memory)
    {:ok, context} = Context.new(tenant_id: "tenant", principal_id: "alice", store: store)

    {:ok, claims} =
      Store.claim_authorities(
        store,
        "tenant",
        [{authority.installation_id, authority.fingerprint}],
        1_000
      )

    key = Context.grant_key(context, authority, claims[authority.installation_id])

    {:ok,
     authority: authority,
     context: context,
     memory: memory,
     store: store,
     epoch: claims[authority.installation_id],
     key: key}
  end

  test "admits exactly the loaded generation and rejects it after a 401", context do
    {:ok, _grant} = seed_grant(context.store, context.key, 60_000)

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    deadline = System.monotonic_time(:millisecond) + 2_000
    assert {:ok, issued} = TokenManager.authorization_header(manager, deadline)
    assert issued.header == {"authorization", "Bearer access-1"}
    assert :ok = TokenManager.release(manager, issued.admission, deadline)
    assert :ok = TokenManager.reject(manager, issued.generation, deadline)

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(manager, deadline)

    {:ok, replacement} =
      replace_grant(context.store, context.key, MapSet.new(["read", "write"]))

    assert {:ok, issued} = TokenManager.authorization_header(manager, deadline)
    assert issued.generation == replacement.generation
    assert :ok = TokenManager.release(manager, issued.admission, deadline)
  end

  test "refreshes proactively and commits only a rotated public refresh token", context do
    fixture = refresh_fixture(context.authority, self())
    {:ok, binding} = Discovery.discover(context.authority, request: fixture)

    {:ok, original} =
      seed_grant(
        context.store,
        context.key,
        500,
        Binding.identity(binding),
        MapSet.new(["read", "write"])
      )

    {:ok, recording_store} = MCPOAuthRecordingStore.wrap(context.store, self())

    {:ok, refresh_context} =
      Context.new(
        tenant_id: "tenant",
        principal_id: "alice",
        store: recording_store
      )

    request = record_requests(fixture, self())

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: refresh_context,
        authority: context.authority,
        authority_epoch: context.epoch,
        request: request
      )

    deadline = System.monotonic_time(:millisecond) + 2_000
    assert {:ok, issued} = TokenManager.authorization_header(manager, deadline)
    assert issued.header == {"authorization", "Bearer access-2"}
    assert issued.generation == original.generation + 1
    assert {:time_anchor, refresh_anchor} = next_sequence()
    assert next_sequence() == {:request, :post, context.authority.resource}
    assert {:request, :get, _protected_resource} = next_sequence()
    assert {:request, :get, _authorization_server} = next_sequence()
    assert {:time_anchor, _token_anchor} = next_sequence()
    assert next_sequence() == {:begin_mutation_dispatch, refresh_anchor}
    assert next_sequence() == {:request, :post, "https://auth.example/token"}
    assert_receive {:refresh, "refresh-access-1"}
    assert :ok = TokenManager.release(manager, issued.admission, deadline)

    assert {:ok, stored} = Store.load_grant(context.store, context.key, 1_000)
    assert stored.refresh_token == "refresh-2"
    assert stored.requested_scopes == MapSet.new(["read", "write"])
    assert stored.granted_scopes == MapSet.new(["read"])
  end

  test "uses an unrefreshable access token through its remaining lifetime", context do
    {:ok, anchor} = Store.time_anchor(context.store, 1_000)

    {:ok, lease} =
      Store.acquire_mutation(context.store, context.key, :authorization, 5_000, 1_000)

    :ok =
      Store.begin_mutation_dispatch(
        context.store,
        context.key,
        lease.fence,
        %{freshness_anchor: anchor, freshness_anchor_ttl_ms: 5_000},
        1_000
      )

    {:ok, _grant} =
      Store.commit_grant(
        context.store,
        context.key,
        lease.fence,
        %{
          access_token: "short-lived",
          refresh_token: nil,
          requested_scopes: MapSet.new(["read"]),
          granted_scopes: MapSet.new(["read"]),
          refresh_authorized: false,
          redirect_uri: "http://127.0.0.1:49152/callback",
          metadata_revision: 1,
          metadata_binding: nil
        },
        500,
        anchor,
        1_000
      )

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    deadline = System.monotonic_time(:millisecond) + 1_000
    assert {:ok, issued} = TokenManager.authorization_header(manager, deadline)
    assert issued.header == {"authorization", "Bearer short-lived"}
    assert :ok = TokenManager.release(manager, issued.admission, deadline)
  end

  test "releases the mutation lease after a proven pre-dispatch discovery failure", context do
    request = refresh_fixture(context.authority, self())
    {:ok, binding} = Discovery.discover(context.authority, request: request)
    {:ok, _grant} = seed_grant(context.store, context.key, 500, Binding.identity(binding))

    failing_request = fn _method, _url, _headers, _body, _timeout ->
      {:error, :unreachable}
    end

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch,
        request: failing_request
      )

    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(manager, deadline)

    assert {:ok, _lease} =
             Store.acquire_mutation(context.store, context.key, :authorization, 1_000, 1_000)
  end

  test "terminalizes a dispatched refresh failure after the request deadline", context do
    fixture = refresh_fixture(context.authority, self())
    {:ok, binding} = Discovery.discover(context.authority, request: fixture)
    {:ok, _grant} = seed_grant(context.store, context.key, 500, Binding.identity(binding))
    parent = self()

    blocking_request = fn method, url, headers, body, timeout ->
      if method == :post and url == "https://auth.example/token" do
        send(parent, {:refresh_dispatched, self()})

        receive do
          :return_failure -> {:error, :unreachable}
        end
      else
        fixture.(method, url, headers, body, timeout)
      end
    end

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch,
        request: blocking_request
      )

    deadline = System.monotonic_time(:millisecond) + 1_000

    refresh =
      Task.async(fn ->
        result = TokenManager.authorization_header(manager, deadline)
        send(parent, {:refresh_result, result})

        receive do
          :finish -> result
        end
      end)

    assert_receive {:refresh_dispatched, refresh_worker}

    wait_ms = max(deadline - System.monotonic_time(:millisecond) + 10, 10)
    Process.send_after(self(), :deadline_passed, wait_ms)
    assert_receive :deadline_passed, wait_ms + 100
    send(refresh_worker, :return_failure)

    assert_receive {:refresh_result, {:error, :mcp_authorization_required}}

    assert {:ok, _lease} =
             Store.acquire_mutation(context.store, context.key, :authorization, 1_000, 1_000)

    send(refresh.pid, :finish)
    assert {:error, :mcp_authorization_required} = Task.await(refresh)
  end

  test "metadata binding drift releases the refresh lease and requires authorization", context do
    request = refresh_fixture(context.authority, self())
    {:ok, binding} = Discovery.discover(context.authority, request: request)
    {:ok, _grant} = seed_grant(context.store, context.key, 500, Binding.identity(binding))

    changed_request =
      refresh_request_with_server_metadata(context.authority, self(), fn metadata ->
        Map.put(metadata, "token_endpoint", "https://auth.example/token-v2")
      end)

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch,
        request: changed_request
      )

    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(manager, deadline)

    assert {:ok, _lease} =
             Store.acquire_mutation(context.store, context.key, :authorization, 1_000, 1_000)

    refute_receive {:refresh, _token}
  end

  test "removed refresh support releases the refresh lease and requires authorization", context do
    request = refresh_fixture(context.authority, self())
    {:ok, binding} = Discovery.discover(context.authority, request: request)
    {:ok, _grant} = seed_grant(context.store, context.key, 500, Binding.identity(binding))

    changed_request =
      refresh_request_with_server_metadata(context.authority, self(), fn metadata ->
        Map.put(metadata, "grant_types_supported", ["authorization_code"])
      end)

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch,
        request: changed_request
      )

    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(manager, deadline)

    assert {:ok, _lease} =
             Store.acquire_mutation(context.store, context.key, :authorization, 1_000, 1_000)

    refute_receive {:refresh, _token}
  end

  test "rejects a step-up requirement outside the installed scope ceiling", context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :mcp_authorization_required} =
             TokenManager.require_scopes(
               manager,
               grant.generation,
               [~s(Bearer error="insufficient_scope", scope="admin")],
               deadline
             )

    assert {:ok, nil} = Store.load_requirement(context.store, context.key, 1_000)
  end

  test "locally fences a rejected generation when durable rejection fails", context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    manager = manager_with_interceptor(context, interceptor)
    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :store_error} = TokenManager.reject(manager, grant.generation, deadline)

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(manager, deadline)
  end

  test "locally fences a valid scope requirement when durable persistence fails", context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)

    interceptor = fn
      {:upsert_requirement, _key, _generation, _scopes, _ttl_ms}, _timeout ->
        {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    manager = manager_with_interceptor(context, interceptor)
    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :store_error} =
             TokenManager.require_scopes(
               manager,
               grant.generation,
               [~s(Bearer error="insufficient_scope", scope="write")],
               deadline
             )

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(manager, deadline)

    {:ok, replacement} =
      replace_grant(context.store, context.key, MapSet.new(["read", "write"]))

    assert {:ok, issued} = TokenManager.authorization_header(manager, deadline)
    assert issued.generation == replacement.generation
    assert :ok = TokenManager.release(manager, issued.admission, deadline)
  end

  test "a late 403 gets a fresh bounded scope-transition budget", context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    :ok = :sys.suspend(manager.pid)

    spawn(fn ->
      receive do
      after
        25 -> :sys.resume(manager.pid)
      end
    end)

    expired_request_deadline = System.monotonic_time(:millisecond) - 1

    assert :ok =
             TokenManager.require_scopes(
               manager,
               grant.generation,
               [~s(Bearer error="insufficient_scope", scope="write")],
               expired_request_deadline
             )

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(
               manager,
               System.monotonic_time(:millisecond) + 1_000
             )
  end

  test "close drains an in-flight response persistence before replacement", context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)
    parent = self()

    interceptor = fn
      {:upsert_requirement, _key, _generation, _scopes, _ttl_ms}, _timeout ->
        send(parent, {:persistence_started, self()})

        receive do
          :continue -> :delegate
        end

      _operation, _timeout ->
        :delegate
    end

    manager = manager_with_interceptor(context, interceptor)

    transition =
      Task.async(fn ->
        TokenManager.require_scopes(
          manager,
          grant.generation,
          [~s(Bearer error="insufficient_scope", scope="write")],
          System.monotonic_time(:millisecond) - 1
        )
      end)

    assert_receive {:persistence_started, worker}
    closing = Task.async(fn -> TokenManager.close(manager) end)
    assert Task.yield(closing, 100) == nil

    send(worker, :continue)
    assert :ok = Task.await(transition, 1_000)
    assert :ok = Task.await(closing, 1_000)

    {:ok, replacement_manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(
               replacement_manager,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :ok = TokenManager.close(replacement_manager)
  end

  test "close retries a failed persistence before allowing replacement", context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
        if attempt == 0, do: {:return, {:error, :store_error}}, else: :delegate

      _operation, _timeout ->
        :delegate
    end

    manager = manager_with_interceptor(context, interceptor)
    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :store_error} = TokenManager.reject(manager, grant.generation, deadline)
    assert :ok = TokenManager.close(manager)

    {:ok, replacement_manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(replacement_manager, deadline)

    assert :ok = TokenManager.close(replacement_manager)
  end

  test "a replacement manager cannot bypass another manager's failed local fence", context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    failed_manager = manager_with_interceptor(context, interceptor)
    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :store_error} =
             TokenManager.reject(failed_manager, grant.generation, deadline)

    {:ok, replacement_manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(replacement_manager, deadline)

    Process.exit(failed_manager.pid, :kill)

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(replacement_manager, deadline)

    {:ok, replacement} =
      replace_grant(context.store, context.key, MapSet.new(["read", "write"]))

    assert {:ok, issued} = TokenManager.authorization_header(replacement_manager, deadline)
    assert issued.generation == replacement.generation
    assert :ok = TokenManager.release(replacement_manager, issued.admission, deadline)
    assert :ok = TokenManager.close(replacement_manager)
  end

  test "a manager crash during rejection persistence cannot revive its bearer generation",
       context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)
    parent = self()

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        send(parent, {:rejection_persistence_started, self()})

        receive do
          :continue -> :ok
        end

        {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    failed_manager = manager_with_interceptor(context, interceptor)
    deadline = System.monotonic_time(:millisecond) + 2_000

    reject_task =
      Task.async(fn -> TokenManager.reject(failed_manager, grant.generation, deadline) end)

    assert_receive {:rejection_persistence_started, persistence_worker}
    Process.exit(failed_manager.pid, :kill)

    {:ok, replacement_manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(replacement_manager, deadline)

    send(persistence_worker, :continue)
    assert {:ok, {:error, :closed}} = Task.yield(reject_task, 1_000)

    {:ok, replacement} =
      replace_grant(context.store, context.key, MapSet.new(["read", "write"]))

    assert {:ok, issued} = TokenManager.authorization_header(replacement_manager, deadline)
    assert issued.generation == replacement.generation
    assert :ok = TokenManager.release(replacement_manager, issued.admission, deadline)
    assert :ok = TokenManager.close(replacement_manager)
  end

  test "a second manager waits for an in-flight refresh commit", context do
    fixture = refresh_fixture(context.authority, self())
    {:ok, binding} = Discovery.discover(context.authority, request: fixture)

    {:ok, _grant} =
      seed_grant(
        context.store,
        context.key,
        500,
        Binding.identity(binding),
        MapSet.new(["read", "write"])
      )

    parent = self()

    blocking_request = fn method, url, headers, body, timeout ->
      if method == :post and url == "https://auth.example/token" do
        send(parent, {:refresh_blocked, self()})

        receive do
          :continue -> :ok
        end
      end

      fixture.(method, url, headers, body, timeout)
    end

    managers =
      for _index <- 1..2 do
        {:ok, manager} =
          TokenManager.start(
            owner: self(),
            context: context.context,
            authority: context.authority,
            authority_epoch: context.epoch,
            request: blocking_request
          )

        manager
      end

    deadline = System.monotonic_time(:millisecond) + 5_000
    [leader_manager, follower_manager] = managers
    leader = Task.async(fn -> TokenManager.authorization_header(leader_manager, deadline) end)
    assert_receive {:refresh_blocked, refresh_worker}

    follower =
      Task.async(fn -> TokenManager.authorization_header(follower_manager, deadline) end)

    assert Task.yield(follower, 100) == nil
    send(refresh_worker, :continue)

    for {task, manager} <- [{leader, leader_manager}, {follower, follower_manager}] do
      assert {:ok, issued} = Task.await(task, 2_000)
      assert issued.header == {"authorization", "Bearer access-2"}
      assert :ok = TokenManager.release(manager, issued.admission, deadline)
      assert :ok = TokenManager.close(manager)
    end
  end

  test "a refresh follower takes over after the leader aborts before dispatch", context do
    fixture = refresh_fixture(context.authority, self())
    {:ok, binding} = Discovery.discover(context.authority, request: fixture)

    {:ok, _grant} =
      seed_grant(
        context.store,
        context.key,
        500,
        Binding.identity(binding),
        MapSet.new(["read", "write"])
      )

    parent = self()

    leader_request = fn method, url, headers, body, timeout ->
      if method == :post and url == context.authority.resource do
        send(parent, {:refresh_discovery_blocked, self()})

        receive do
          :fail_before_dispatch -> {:error, :transport_error, :not_dispatched}
        end
      else
        fixture.(method, url, headers, body, timeout)
      end
    end

    {:ok, leader_manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch,
        request: leader_request
      )

    {:ok, follower_manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch,
        request: fixture
      )

    deadline = System.monotonic_time(:millisecond) + 5_000
    leader = Task.async(fn -> TokenManager.authorization_header(leader_manager, deadline) end)
    assert_receive {:refresh_discovery_blocked, refresh_worker}

    follower =
      Task.async(fn -> TokenManager.authorization_header(follower_manager, deadline) end)

    assert Task.yield(follower, 100) == nil
    send(refresh_worker, :fail_before_dispatch)

    assert {:error, :mcp_authorization_required} = Task.await(leader, 2_000)
    assert {:ok, issued} = Task.await(follower, 2_000)
    assert issued.header == {"authorization", "Bearer access-2"}
    assert :ok = TokenManager.release(follower_manager, issued.admission, deadline)
    assert :ok = TokenManager.close(leader_manager)
    assert :ok = TokenManager.close(follower_manager)
  end

  test "owner death keeps a failed persistence manager closed until cleanup recovers",
       context do
    {:ok, grant} = seed_grant(context.store, context.key, 60_000)
    {:ok, store_available?} = Agent.start_link(fn -> false end)
    parent = self()

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        send(parent, :rejection_persist_attempt)

        if Agent.get(store_available?, & &1),
          do: :delegate,
          else: {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    manager = manager_with_interceptor(context, interceptor, owner: owner)
    deadline = System.monotonic_time(:millisecond) + 2_000

    assert {:error, :store_error} = TokenManager.reject(manager, grant.generation, deadline)
    assert_receive :rejection_persist_attempt

    Process.exit(owner, :kill)
    assert_receive :rejection_persist_attempt
    assert Process.alive?(manager.pid)
    assert {:error, :persistence_failed} = TokenManager.close(manager)
    assert {:error, :closed} = TokenManager.release(manager, :unused, deadline)

    Agent.update(store_available?, fn _available? -> true end)
    assert :ok = TokenManager.close(manager)

    {:ok, replacement_manager} =
      TokenManager.start(
        owner: self(),
        context: context.context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(replacement_manager, deadline)

    assert :ok = TokenManager.close(replacement_manager)
  end

  test "supervised cleanup retains and retries a fenced manager after acquisition loss",
       context do
    {:ok, _grant} = seed_grant(context.store, context.key, 60_000)
    {:ok, persist?} = Agent.start_link(fn -> false end)
    parent = self()

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        send(parent, {:cleanup_persistence_attempted, System.monotonic_time(:millisecond)})

        if Agent.get(persist?, & &1),
          do: :delegate,
          else: {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    manager = manager_with_interceptor(context, interceptor)
    manager_ref = Process.monitor(manager.pid)
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:error, :store_error} = TokenManager.reject(manager, 1, deadline)
    assert_receive {:cleanup_persistence_attempted, _initial}
    assert :ok = ManagerCleanup.adopt(manager)
    assert_receive {:cleanup_persistence_attempted, first}
    assert_receive {:cleanup_persistence_attempted, second}, 1_000
    assert_receive {:cleanup_persistence_attempted, third}, 1_000
    assert second - first >= 200
    assert third - second >= 400
    assert Process.alive?(manager.pid)

    Agent.update(persist?, fn _failed -> true end)

    assert_receive {:DOWN, ^manager_ref, :process, _pid, :normal}, 2_000
  end

  test "closing an ephemeral store terminates its adopted retry managers", context do
    {:ok, _grant} = seed_grant(context.store, context.key, 60_000)
    parent = self()

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        send(parent, :terminal_persistence_attempt)
        {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    manager = manager_with_interceptor(context, interceptor)
    manager_ref = Process.monitor(manager.pid)
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:error, :store_error} = TokenManager.reject(manager, 1, deadline)
    assert_receive :terminal_persistence_attempt
    assert :ok = ManagerCleanup.adopt(manager)
    assert_receive :terminal_persistence_attempt
    assert Process.alive?(manager.pid)

    assert :ok = Memory.close(context.memory)
    assert_receive {:DOWN, ^manager_ref, :process, _pid, :killed}, 1_000
  end

  test "registration-controller loss does not block persistence handoff", context do
    {:ok, _grant} = seed_grant(context.store, context.key, 60_000)
    {:ok, persist?} = Agent.start_link(fn -> false end)

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        if Agent.get(persist?, & &1),
          do: :delegate,
          else: {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    {:ok, session} = ProviderSession.start(Limits.defaults())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    manager =
      manager_with_interceptor(context, interceptor,
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar
      )

    manager_ref = Process.monitor(manager.pid)
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert {:error, :store_error} = TokenManager.reject(manager, 1, deadline)

    Process.exit(registrar.scope_controller, :kill)
    assert :ok = ManagerCleanup.adopt(manager, registrar)
    assert Process.alive?(manager.pid)

    Agent.update(persist?, fn _failed -> true end)
    assert_receive {:DOWN, ^manager_ref, :process, _pid, :normal}, 2_000
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
  end

  test "an unavailable registrar is not reported as an invalid token manager", context do
    {:ok, session} = ProviderSession.start(Limits.defaults())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    owner = ResourceRegistrar.owner(registrar)
    assert :ok = ResourceRegistrar.abort(registrar)

    assert {:error, :resource_registrar_unavailable} =
             TokenManager.start(
               owner: owner,
               resource_registrar: registrar,
               context: context.context,
               authority: context.authority,
               authority_epoch: context.epoch
             )

    assert :ok = ProviderSession.close(session)
  end

  test "concurrent repeated adoption creates one cleanup worker", context do
    {:ok, _grant} = seed_grant(context.store, context.key, 60_000)
    {:ok, persist?} = Agent.start_link(fn -> false end)
    {:ok, session} = ProviderSession.start(Limits.defaults())
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        if Agent.get(persist?, & &1),
          do: :delegate,
          else: {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    manager =
      manager_with_interceptor(context, interceptor,
        owner: ResourceRegistrar.owner(registrar),
        resource_registrar: registrar
      )

    manager_ref = Process.monitor(manager.pid)
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert {:error, :store_error} = TokenManager.reject(manager, 1, deadline)

    results =
      1..32
      |> Task.async_stream(fn _attempt -> ManagerCleanup.adopt(manager, registrar) end,
        max_concurrency: 32,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, worker} = ManagerCleanup.adopted_worker(manager.pid)
    assert Process.alive?(worker)
    assert {:links, [^worker]} = Process.info(manager.pid, :links)

    Agent.update(persist?, fn _failed -> true end)
    assert_receive {:DOWN, ^manager_ref, :process, _pid, :normal}, 2_000
    assert :ok = ResourceRegistrar.commit(registrar, nil)
    assert :ok = ProviderSession.close(session)
  end

  test "a stalled scope handoff does not block adoption from another scope", context do
    {:ok, _grant} = seed_grant(context.store, context.key, 60_000)
    {:ok, persist?} = Agent.start_link(fn -> false end)
    {:ok, first_session} = ProviderSession.start(Limits.defaults())
    {:ok, first_registrar} = ProviderSession.open_registrar(first_session)
    assert :ok = ResourceRegistrar.activate(first_registrar)
    {:ok, second_session} = ProviderSession.start(Limits.defaults())
    {:ok, second_registrar} = ProviderSession.open_registrar(second_session)
    assert :ok = ResourceRegistrar.activate(second_registrar)

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        if Agent.get(persist?, & &1),
          do: :delegate,
          else: {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    first_manager =
      manager_with_interceptor(context, interceptor,
        owner: ResourceRegistrar.owner(first_registrar),
        resource_registrar: first_registrar
      )

    second_manager =
      manager_with_interceptor(context, interceptor,
        owner: ResourceRegistrar.owner(second_registrar),
        resource_registrar: second_registrar
      )

    first_ref = Process.monitor(first_manager.pid)
    second_ref = Process.monitor(second_manager.pid)
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert {:error, :store_error} = TokenManager.reject(first_manager, 1, deadline)
    assert {:error, :store_error} = TokenManager.reject(second_manager, 1, deadline)

    assert true = :erlang.suspend_process(first_registrar.cleanup_owner)
    stalled = Task.async(fn -> ManagerCleanup.adopt(first_manager, first_registrar) end)
    assert nil == Task.yield(stalled, 50)

    healthy = Task.async(fn -> ManagerCleanup.adopt(second_manager, second_registrar) end)
    assert {:ok, :ok} = Task.yield(healthy, 500)
    assert nil == Task.yield(stalled, 0)

    assert true = :erlang.resume_process(first_registrar.cleanup_owner)
    assert :ok = Task.await(stalled, 1_000)

    Agent.update(persist?, fn _failed -> true end)
    assert_receive {:DOWN, ^first_ref, :process, _pid, :normal}, 2_000
    assert_receive {:DOWN, ^second_ref, :process, _pid, :normal}, 2_000
    assert :ok = ResourceRegistrar.commit(first_registrar, nil)
    assert :ok = ResourceRegistrar.commit(second_registrar, nil)
    assert :ok = ProviderSession.close(first_session)
    assert :ok = ProviderSession.close(second_session)
  end

  test "cleanup supervisor restart terminates an adopted manager instead of orphaning it",
       context do
    {:ok, _grant} = seed_grant(context.store, context.key, 60_000)
    parent = self()

    interceptor = fn
      {:mark_access_rejected, _key, _generation}, _timeout ->
        send(parent, :restart_cleanup_persistence_attempted)
        {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    manager = manager_with_interceptor(context, interceptor)
    manager_ref = Process.monitor(manager.pid)
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:error, :store_error} = TokenManager.reject(manager, 1, deadline)
    assert_receive :restart_cleanup_persistence_attempted
    assert :ok = ManagerCleanup.adopt(manager)
    assert_receive :restart_cleanup_persistence_attempted

    cleanup = Process.whereis(ManagerCleanup)
    cleanup_ref = Process.monitor(cleanup)
    Process.exit(cleanup, :kill)

    assert_receive {:DOWN, ^cleanup_ref, :process, ^cleanup, :killed}
    assert_receive {:DOWN, ^manager_ref, :process, _pid, :killed}
    assert is_pid(await_cleanup_restart(cleanup))
  end

  test "cleanup adoption treats a manager that already exited as complete" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
    assert reason in [:normal, :noproc]

    manager = %TokenManager{pid: pid, resource: "https://mcp.example/mcp"}
    assert :ok = ManagerCleanup.adopt(manager)
    assert :ok = ManagerCleanup.adopt(manager, nil)
    refute Map.has_key?(:sys.get_state(ManagerCleanup).handoffs, pid)
  end

  test "concurrent successful cleanups do not restart the cleanup supervisor", context do
    cleanup = Process.whereis(ManagerCleanup)

    managers =
      for _index <- 1..8 do
        {:ok, manager} =
          TokenManager.start(
            owner: self(),
            context: context.context,
            authority: context.authority,
            authority_epoch: context.epoch
          )

        {manager, Process.monitor(manager.pid)}
      end

    Enum.each(managers, fn {manager, _ref} ->
      assert :ok = ManagerCleanup.adopt(manager)
    end)

    Enum.each(managers, fn {manager, ref} ->
      assert_receive {:DOWN, ^ref, :process, pid, :normal}
      assert pid == manager.pid
    end)

    assert Process.whereis(ManagerCleanup) == cleanup
    assert Process.alive?(cleanup)
  end

  test "release reports store failure instead of silently acknowledging it", context do
    {:ok, _grant} = seed_grant(context.store, context.key, 60_000)

    interceptor = fn
      {:release_mcp, _admission}, _timeout ->
        {:return, {:error, :store_error}}

      _operation, _timeout ->
        :delegate
    end

    manager = manager_with_interceptor(context, interceptor)
    deadline = System.monotonic_time(:millisecond) + 2_000
    assert {:ok, issued} = TokenManager.authorization_header(manager, deadline)
    assert {:error, :store_error} = TokenManager.release(manager, issued.admission, deadline)
  end

  defp seed_grant(
         store,
         key,
         ttl_ms,
         metadata_binding \\ nil,
         requested_scopes \\ MapSet.new(["read"])
       ) do
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

    Store.commit_grant(
      store,
      key,
      lease.fence,
      %{
        access_token: "access-1",
        refresh_token: "refresh-access-1",
        requested_scopes: requested_scopes,
        granted_scopes: MapSet.new(["read"]),
        refresh_authorized: true,
        redirect_uri: "http://127.0.0.1:49152/callback",
        metadata_revision: 1,
        metadata_binding: metadata_binding
      },
      ttl_ms,
      anchor,
      1_000
    )
  end

  defp replace_grant(store, key, granted_scopes) do
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

    Store.commit_grant(
      store,
      key,
      lease.fence,
      %{
        access_token: "replacement-access",
        requested_scopes: granted_scopes,
        granted_scopes: granted_scopes,
        refresh_authorized: false,
        redirect_uri: "http://127.0.0.1:49152/callback",
        metadata_revision: 2,
        metadata_binding: nil
      },
      60_000,
      anchor,
      1_000
    )
  end

  defp refresh_fixture(authority, parent) do
    [resource | _] = Metadata.protected_resource_candidates(authority.resource)
    [server | _] = Metadata.authorization_server_candidates(authority.issuer)

    fn
      :post, url, _headers, _body, _timeout when url == authority.resource ->
        {:ok,
         %{
           status: 401,
           headers: [{"www-authenticate", ~s(Bearer scope="read")}],
           body: ""
         }}

      :get, ^resource, _headers, _body, _timeout ->
        json(%{
          "resource" => authority.resource,
          "authorization_servers" => [authority.issuer],
          "scopes_supported" => ["read"]
        })

      :get, ^server, _headers, _body, _timeout ->
        json(%{
          "issuer" => authority.issuer,
          "authorization_endpoint" => "https://auth.example/authorize",
          "token_endpoint" => "https://auth.example/token",
          "response_types_supported" => ["code"],
          "grant_types_supported" => ["authorization_code", "refresh_token"],
          "response_modes_supported" => ["query"],
          "code_challenge_methods_supported" => ["S256"],
          "token_endpoint_auth_methods_supported" => ["none"],
          "scopes_supported" => ["read"]
        })

      :post, "https://auth.example/token", _headers, body, _timeout ->
        form = URI.decode_query(body)
        send(parent, {:refresh, form["refresh_token"]})

        json(%{
          "access_token" => "access-2",
          "refresh_token" => "refresh-2",
          "token_type" => "Bearer",
          "expires_in" => 3_600,
          "scope" => "read"
        })

      _method, _url, _headers, _body, _timeout ->
        {:ok, %{status: 404, headers: [], body: ""}}
    end
  end

  defp refresh_request_with_server_metadata(authority, parent, transform) do
    request = refresh_fixture(authority, parent)
    [server | _] = Metadata.authorization_server_candidates(authority.issuer)

    fn
      :get, ^server, _headers, _body, _timeout ->
        json(
          transform.(%{
            "issuer" => authority.issuer,
            "authorization_endpoint" => "https://auth.example/authorize",
            "token_endpoint" => "https://auth.example/token",
            "response_types_supported" => ["code"],
            "grant_types_supported" => ["authorization_code", "refresh_token"],
            "response_modes_supported" => ["query"],
            "code_challenge_methods_supported" => ["S256"],
            "token_endpoint_auth_methods_supported" => ["none"],
            "scopes_supported" => ["read"]
          })
        )

      method, url, headers, body, timeout ->
        request.(method, url, headers, body, timeout)
    end
  end

  defp record_requests(request, observer) do
    fn method, url, headers, body, timeout ->
      send(observer, {:oauth_sequence, {:request, method, url}})
      request.(method, url, headers, body, timeout)
    end
  end

  defp manager_with_interceptor(context, interceptor, opts \\ []) do
    {:ok, recording_store} =
      MCPOAuthRecordingStore.wrap(context.store, self(), interceptor: interceptor)

    {:ok, wrapped_context} =
      Context.new(
        tenant_id: context.context.tenant_id,
        principal_id: context.context.principal_id,
        store: recording_store
      )

    {:ok, manager} =
      TokenManager.start(
        owner: Keyword.get(opts, :owner, self()),
        resource_registrar: Keyword.get(opts, :resource_registrar),
        context: wrapped_context,
        authority: context.authority,
        authority_epoch: context.epoch
      )

    manager
  end

  defp next_sequence do
    assert_receive {:oauth_sequence, event}
    event
  end

  defp await_cleanup_restart(previous, attempts \\ 100)

  defp await_cleanup_restart(_previous, 0), do: nil

  defp await_cleanup_restart(previous, attempts) do
    case Process.whereis(ManagerCleanup) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _not_restarted ->
        receive do
        after
          10 -> await_cleanup_restart(previous, attempts - 1)
        end
    end
  end

  defp json(document) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"content-type", "application/json"},
         {"cache-control", "max-age=120"}
       ],
       body: Jason.encode!(document)
     }}
  end

  defp authority do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "manager-test",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read", "write"],
          "default_scopes" => ["read"],
          "refresh_access" => "when_supported",
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code", "refresh_token"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        },
        "https://mcp.example/mcp",
        MapSet.new()
      )

    authority
  end
end
