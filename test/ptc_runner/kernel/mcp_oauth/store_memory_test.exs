defmodule PtcRunner.Kernel.MCPOAuth.StoreMemoryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.Primitives
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory

  test "loads a valid external adapter before checking its callback" do
    module = PtcRunner.Test.MCPOAuthUnloadedStore
    :code.purge(module)
    :code.delete(module)
    refute Code.loaded?(module)

    assert {:ok, {^module, :adapter_state}} = Store.new(module, :adapter_state)
    assert Code.loaded?(module)
  end

  test "accepts an already anchored caller deadline", context do
    assert {:ok, _anchor} = Store.time_anchor(context.store, Deadline.new(1_000))
  end

  setup do
    {:ok, memory} = Memory.start_link(owner: self())
    {:ok, store} = Memory.store(memory)
    authority = authority()

    {:ok, epochs} =
      Store.claim_authorities(
        store,
        "tenant",
        [{authority.installation_id, authority.fingerprint}],
        1_000
      )

    {:ok, alice} =
      Context.new(
        tenant_id: "tenant",
        principal_id: "alice",
        store: store
      )

    {:ok, bob} =
      Context.new(
        tenant_id: "tenant",
        principal_id: "bob",
        store: store
      )

    {:ok,
     memory: memory,
     store: store,
     authority: authority,
     authority_epoch: epochs[authority.installation_id],
     alice: alice,
     bob: bob}
  end

  test "manager registration is idempotent and releases tracking after manager death", context do
    manager = spawn(fn -> receive do: (:stop -> :ok) end)

    assert :ok = Store.register_manager(context.store, manager)
    assert :ok = Store.register_manager(context.store, manager)
    assert manager_monitor_count(context.memory.pid, manager) == 1

    manager_ref = Process.monitor(manager)
    send(manager, :stop)
    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :normal}

    assert_eventually(fn ->
      context.memory.pid
      |> :sys.get_state()
      |> Map.fetch!(:managers)
      |> Map.has_key?(manager)
      |> Kernel.not()
    end)
  end

  test "closing the store terminates each live registered manager", context do
    manager = spawn(fn -> receive do: (:stop -> :ok) end)
    manager_ref = Process.monitor(manager)

    assert :ok = Store.register_manager(context.store, manager)
    assert :ok = Memory.close(context.memory)
    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}
  end

  test "isolates grants by principal and redacts opaque identities", context do
    alice_key =
      Context.grant_key(context.alice, context.authority, context.authority_epoch)

    bob_key =
      Context.grant_key(context.bob, context.authority, context.authority_epoch)

    assert {:ok, alice_grant} = seed_grant(context.store, alice_key, "alice-token")
    assert alice_grant.generation == 1
    assert {:ok, nil} = Store.load_grant(context.store, bob_key, 1_000)

    assert inspect(context.alice) == "#PtcRunner.MCPOAuth.Context<redacted>"
    assert inspect(alice_key) == "#PtcRunner.MCPOAuth.GrantKey<redacted>"
    refute inspect(:sys.get_status(context.memory.pid)) =~ "alice-token"
  end

  test "serializes mutation and never restores a possibly spent refresh token", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, grant} = seed_grant(context.store, key, "access-1")

    assert {:ok, lease} = Store.acquire_mutation(context.store, key, :refresh, 5_000, 1_000)
    assert lease.starting_generation == grant.generation

    assert {:error, :mutation_busy} =
             Store.acquire_mutation(context.store, key, :refresh, 5_000, 1_000)

    assert :ok =
             Store.begin_mutation_dispatch(
               context.store,
               key,
               lease.fence,
               dispatch_binding(context.store),
               1_000
             )

    assert :ok =
             Store.fail_mutation(
               context.store,
               key,
               lease.fence,
               :possibly_dispatched,
               1_000
             )

    assert {:ok, poisoned} = Store.load_grant(context.store, key, 1_000)
    assert poisoned.status == :refresh_indeterminate
    assert poisoned.generation == grant.generation + 1
    refute Map.has_key?(poisoned, :access_token)
    refute Map.has_key?(poisoned, :refresh_token)
  end

  test "worker death after dispatch fences and poisons the exact mutation", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, grant} = seed_grant(context.store, key, "access-1")
    parent = self()

    worker =
      Task.async(fn ->
        {:ok, lease} = Store.acquire_mutation(context.store, key, :refresh, 5_000, 1_000)

        :ok =
          Store.begin_mutation_dispatch(
            context.store,
            key,
            lease.fence,
            dispatch_binding(context.store),
            1_000
          )

        send(parent, {:mutation_dispatched, lease.fence})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:mutation_dispatched, fence}

    assert {:error, :stale_mutation} =
             Store.recover_mutation(context.store, key, {:wrong, fence}, :worker_fenced, 1_000)

    _ = Task.shutdown(worker, :brutal_kill)

    assert_eventually(fn ->
      case Store.load_grant(context.store, key, 1_000) do
        {:ok, %{status: :refresh_indeterminate} = poisoned} ->
          assert poisoned.generation == grant.generation + 1
          refute Map.has_key?(poisoned, :access_token)
          refute Map.has_key?(poisoned, :refresh_token)
          true

        _not_recovered_yet ->
          false
      end
    end)

    assert {:ok, _lease} =
             Store.acquire_mutation(context.store, key, :authorization, 1_000, 1_000)
  end

  test "dispatch admission catches stale and rejected generations before network", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, grant} = seed_grant(context.store, key, "access-1")

    assert {:error, :stale_before_dispatch} =
             Store.admit_mcp(context.store, key, grant.generation - 1, 1_000, 1_000)

    assert :ok =
             Store.mark_access_rejected(context.store, key, grant.generation, 1_000)

    assert {:error, :rejected_before_dispatch} =
             Store.admit_mcp(context.store, key, grant.generation, 1_000, 1_000)

    assert {:ok, refreshed} = replace_grant(context.store, key, "access-2")
    assert refreshed.generation == grant.generation + 1

    assert {:ok, admission} =
             Store.admit_mcp(context.store, key, refreshed.generation, 1_000, 1_000)

    assert :ok = Store.release_mcp(context.store, admission, 1_000)
  end

  test "dispatch admission atomically refuses a known-insufficient grant", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, grant} = seed_grant(context.store, key, "access-1")

    assert {:ok, _version} =
             Store.upsert_requirement(
               context.store,
               key,
               grant.generation,
               MapSet.new(["write"]),
               5_000,
               1_000
             )

    assert {:error, :authorization_required} =
             Store.admit_mcp(context.store, key, grant.generation, 1_000, 1_000)
  end

  test "an exact-generation challenge overrides nominal granted scopes", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, grant} = seed_grant(context.store, key, "access-1")

    assert {:ok, _version} =
             Store.upsert_requirement(
               context.store,
               key,
               grant.generation,
               MapSet.new(["read"]),
               5_000,
               1_000
             )

    assert {:error, :authorization_required} =
             Store.admit_mcp(context.store, key, grant.generation, 1_000, 1_000)
  end

  test "a delayed challenge blocks a newer grant that still lacks its scopes", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, old} = seed_grant(context.store, key, "access-1")
    {:ok, current} = replace_grant(context.store, key, "access-2")

    assert {:ok, _version} =
             Store.upsert_requirement(
               context.store,
               key,
               old.generation,
               MapSet.new(["write"]),
               5_000,
               1_000
             )

    assert {:error, :authorization_required} =
             Store.admit_mcp(context.store, key, current.generation, 1_000, 1_000)
  end

  test "a newer grant clears a delayed challenge only when it covers every scope", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, old} = seed_grant(context.store, key, "access-1")

    {:ok, current} =
      replace_grant(
        context.store,
        key,
        "access-2",
        MapSet.new(["read", "write"])
      )

    assert {:ok, _version} =
             Store.upsert_requirement(
               context.store,
               key,
               old.generation,
               MapSet.new(["write"]),
               5_000,
               1_000
             )

    assert {:ok, nil} = Store.load_requirement(context.store, key, 1_000)

    assert {:ok, admission} =
             Store.admit_mcp(context.store, key, current.generation, 1_000, 1_000)

    assert :ok = Store.release_mcp(context.store, admission, 1_000)
  end

  test "a delayed challenge survives concurrent poisoning of its grant", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, old} = seed_grant(context.store, key, "access-1")
    {:ok, lease} = Store.acquire_mutation(context.store, key, :refresh, 5_000, 1_000)

    assert :ok =
             Store.begin_mutation_dispatch(
               context.store,
               key,
               lease.fence,
               dispatch_binding(context.store),
               1_000
             )

    assert :ok =
             Store.fail_mutation(
               context.store,
               key,
               lease.fence,
               :possibly_dispatched,
               1_000
             )

    assert {:ok, %{status: :refresh_indeterminate, generation: poisoned_generation}} =
             Store.load_grant(context.store, key, 1_000)

    assert poisoned_generation > old.generation

    assert {:ok, _version} =
             Store.upsert_requirement(
               context.store,
               key,
               old.generation,
               MapSet.new(["write"]),
               5_000,
               1_000
             )

    assert {:ok, %{scopes: scopes, source_generation: source_generation}} =
             Store.load_requirement(context.store, key, 1_000)

    assert scopes == MapSet.new(["write"])
    assert source_generation == old.generation
  end

  test "an expired scope requirement is absent when a later requirement is stored", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, grant} = seed_grant(context.store, key, "access")

    assert {:ok, first_version} =
             Store.upsert_requirement(
               context.store,
               key,
               grant.generation,
               MapSet.new(["expired"]),
               1,
               1_000
             )

    wait_until_after(System.monotonic_time(:millisecond) + 2)

    assert {:ok, second_version} =
             Store.upsert_requirement(
               context.store,
               key,
               grant.generation,
               MapSet.new(["current"]),
               5_000,
               1_000
             )

    assert second_version > first_version
    assert {:ok, %{scopes: scopes}} = Store.load_requirement(context.store, key, 1_000)
    assert scopes == MapSet.new(["current"])
  end

  test "an ambiguous admission timeout queues exact cleanup", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, grant} = seed_grant(context.store, key, "access")

    :ok = :sys.suspend(context.memory.pid)

    assert {:error, :timeout} =
             Store.admit_mcp(context.store, key, grant.generation, 1_000, 10)

    :ok = :sys.resume(context.memory.pid)

    assert_eventually(fn ->
      {:ok, retirement} =
        Store.begin_authority_retirement(
          context.store,
          "tenant",
          context.authority.installation_id,
          context.authority.fingerprint,
          :release,
          "timeout-cleanup",
          1_000,
          1_000
        )

      match?(
        {:ok, _epoch},
        Store.complete_authority_retirement(
          context.store,
          retirement.intent_id,
          retirement.coordinator,
          1_000
        )
      )
    end)
  end

  test "a mutation that expires in the mailbox does not commit", context do
    :ok = :sys.suspend(context.memory.pid)

    assert {:error, :timeout} =
             Store.claim_authorities(
               context.store,
               "tenant",
               [{"queued-installation", "v1:queued"}],
               10
             )

    :ok = :sys.resume(context.memory.pid)

    # This call is sent by the same process, so its reply proves the expired
    # mutation ahead of it in the mailbox has been handled.
    assert {:ok, _anchor} = Store.time_anchor(context.store, 1_000)

    assert {:ok, claims} =
             Store.claim_authorities(
               context.store,
               "tenant",
               [{"queued-installation", "v1:replacement"}],
               1_000
             )

    assert Map.has_key?(claims, "queued-installation")
  end

  test "callback state is one-time and cancellation races atomically with code dispatch",
       context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    flow = flow(context.store)

    assert {:ok, pending} = Store.begin_flow(context.store, key, flow, 5_000, 1_000)

    assert {:ok, consumed} =
             Store.consume_callback(
               context.store,
               key,
               pending.id,
               flow.state,
               nil,
               1_000
             )

    assert consumed.verifier == flow.verifier

    assert {:error, :stale_flow} =
             Store.consume_callback(
               context.store,
               key,
               pending.id,
               flow.state,
               nil,
               1_000
             )

    assert {:ok, lease} =
             Store.acquire_mutation(context.store, key, :authorization, 5_000, 1_000)

    assert :ok = Store.cancel_flow(context.store, key, pending.id, 1_000)

    assert {:ok, _new_lease} =
             Store.acquire_mutation(context.store, key, :refresh, 5_000, 1_000)

    assert {:error, :stale_flow} =
             Store.begin_code_dispatch(context.store, key, pending.id, lease.fence, %{}, 1_000)
  end

  test "cached discovery freshness cannot restart after callback delay", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    binding = oauth_binding(context.store, 100)
    flow = put_in(flow(context.store), [:binding], binding)

    assert {:ok, pending} = Store.begin_flow(context.store, key, flow, 5_000, 1_000)

    assert {:ok, consumed} =
             Store.consume_callback(
               context.store,
               key,
               pending.id,
               flow.state,
               nil,
               1_000
             )

    assert {:memory_binding_freshness, freshness_deadline_ms} =
             consumed.binding_freshness_fence

    wait_until_after(freshness_deadline_ms)

    assert {:ok, lease} =
             Store.acquire_mutation(context.store, key, :authorization, 5_000, 1_000)

    cached_binding =
      consumed.binding
      |> Map.put(:freshness_fence, consumed.binding_freshness_fence)

    assert {:error, :stale_flow} =
             Store.begin_code_dispatch(
               context.store,
               key,
               pending.id,
               lease.fence,
               cached_binding,
               1_000
             )
  end

  test "a complete PR, server, and CIMD binding cannot outlive its store anchor", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, anchor} = Store.time_anchor(context.store, 1_000)
    wait_until_after(elem(anchor, 1) + 1)

    binding =
      context.store
      |> oauth_binding(1)
      |> Map.put(:freshness_anchor, anchor)
      |> Map.put(:freshness_anchor_ttl_ms, 1)

    flow = put_in(flow(context.store), [:binding], binding)

    assert {:error, :stale_flow} =
             Store.begin_flow(context.store, key, flow, 5_000, 1_000)
  end

  test "refresh dispatch atomically rejects an expired discovery anchor", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, anchor} = Store.time_anchor(context.store, 1_000)

    binding =
      context.store
      |> oauth_binding(1)
      |> Map.put(:freshness_anchor, anchor)
      |> Map.put(:freshness_anchor_ttl_ms, 1)

    assert {:ok, lease} =
             Store.acquire_mutation(context.store, key, :refresh, 5_000, 1_000)

    wait_until_after(elem(anchor, 1) + 1)

    assert {:error, :stale_mutation} =
             Store.begin_mutation_dispatch(
               context.store,
               key,
               lease.fence,
               binding,
               1_000
             )
  end

  test "retirement waits for admitted and dispatched work and fences old contexts", context do
    key = Context.grant_key(context.alice, context.authority, context.authority_epoch)
    {:ok, grant} = seed_grant(context.store, key, "access")

    {:ok, admission} =
      Store.admit_mcp(context.store, key, grant.generation, 5_000, 1_000)

    {:ok, retirement} =
      Store.begin_authority_retirement(
        context.store,
        "tenant",
        context.authority.installation_id,
        context.authority.fingerprint,
        :release,
        "release-1",
        5_000,
        1_000
      )

    assert {:error, :retirement_not_drained} =
             Store.complete_authority_retirement(
               context.store,
               retirement.intent_id,
               retirement.coordinator,
               1_000
             )

    assert {:error, :stale_authority} = Store.load_grant(context.store, key, 1_000)
    assert :ok = Store.release_mcp(context.store, admission, 1_000)

    assert {:ok, tombstone_epoch} =
             Store.complete_authority_retirement(
               context.store,
               retirement.intent_id,
               retirement.coordinator,
               1_000
             )

    refute tombstone_epoch == context.authority_epoch

    assert {:ok, reclaimed} =
             Store.claim_authorities(
               context.store,
               "tenant",
               [{context.authority.installation_id, context.authority.fingerprint}],
               1_000
             )

    refute reclaimed[context.authority.installation_id] == context.authority_epoch
    assert {:error, :stale_authority} = Store.load_grant(context.store, key, 1_000)
  end

  test "an expired retirement coordinator can be atomically taken over", context do
    assert {:ok, first} =
             Store.begin_authority_retirement(
               context.store,
               "tenant",
               context.authority.installation_id,
               context.authority.fingerprint,
               :release,
               "takeover",
               1,
               1_000
             )

    wait_until_after(System.monotonic_time(:millisecond) + 2)

    assert {:ok, replacement} =
             Store.begin_authority_retirement(
               context.store,
               "tenant",
               context.authority.installation_id,
               context.authority.fingerprint,
               :release,
               "takeover",
               5_000,
               1_000
             )

    assert replacement.intent_id == first.intent_id
    refute replacement.coordinator == first.coordinator

    assert {:error, :stale_retirement} =
             Store.complete_authority_retirement(
               context.store,
               first.intent_id,
               first.coordinator,
               1_000
             )

    assert {:ok, _epoch} =
             Store.complete_authority_retirement(
               context.store,
               replacement.intent_id,
               replacement.coordinator,
               1_000
             )
  end

  test "batch authority claim is all-or-nothing", context do
    assert {:error, :authority_collision} =
             Store.claim_authorities(
               context.store,
               "tenant",
               [
                 {"new-installation", "v1:new"},
                 {context.authority.installation_id, "v1:collision"}
               ],
               1_000
             )

    assert {:ok, claims} =
             Store.claim_authorities(
               context.store,
               "tenant",
               [{"new-installation", "v1:new"}],
               1_000
             )

    assert Map.has_key?(claims, "new-installation")
  end

  defp seed_grant(store, key, access_token, scopes \\ MapSet.new(["read"])) do
    {:ok, anchor} = Store.time_anchor(store, 1_000)
    {:ok, lease} = Store.acquire_mutation(store, key, :authorization, 5_000, 1_000)

    :ok =
      Store.begin_mutation_dispatch(
        store,
        key,
        lease.fence,
        dispatch_binding(store),
        1_000
      )

    Store.commit_grant(
      store,
      key,
      lease.fence,
      %{
        access_token: access_token,
        refresh_token: "refresh-" <> access_token,
        requested_scopes: scopes,
        granted_scopes: scopes,
        refresh_authorized: true,
        metadata_revision: 1
      },
      60_000,
      anchor,
      1_000
    )
  end

  defp replace_grant(store, key, access_token, scopes \\ MapSet.new(["read"])),
    do: seed_grant(store, key, access_token, scopes)

  defp assert_eventually(callback, attempts \\ 100)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.(), do: :ok, else: assert_eventually(callback, attempts - 1)
  end

  defp assert_eventually(_callback, 0), do: flunk("condition did not become true")

  defp manager_monitor_count(store_pid, manager) do
    {:monitors, monitors} = Process.info(store_pid, :monitors)
    Enum.count(monitors, &(&1 == {:process, manager}))
  end

  defp wait_until_after(target_ms) do
    if System.monotonic_time(:millisecond) > target_ms,
      do: :ok,
      else: wait_until_after(target_ms)
  end

  defp flow(store) do
    material = Primitives.new_flow()

    %{
      state: material.state,
      verifier: material.verifier,
      issuer: "https://auth.example",
      issuer_required?: false,
      requested_scopes: MapSet.new(["read"]),
      required_scopes: MapSet.new(["read"]),
      binding: Map.put(dispatch_binding(store), :revision, 1)
    }
  end

  defp oauth_binding(store, freshness_ttl_ms) do
    {:ok, anchor} = Store.time_anchor(store, 1_000)

    %{
      protected_resource: %{
        source: "https://mcp.example/.well-known/oauth-protected-resource",
        resource: "https://mcp.example/mcp",
        authorization_servers: ["https://auth.example"],
        scopes_supported: MapSet.new(["read"])
      },
      authorization_server: %{
        source: "https://auth.example/.well-known/oauth-authorization-server",
        issuer: "https://auth.example",
        authorization_endpoint: "https://auth.example/authorize",
        token_endpoint: "https://auth.example/token",
        grant_types_supported: MapSet.new(["authorization_code", "refresh_token"]),
        explicit_refresh_support: true,
        response_modes_supported: MapSet.new(["query"]),
        token_endpoint_auth_methods_supported: MapSet.new(["none"]),
        scopes_supported: MapSet.new(["read"]),
        authorization_response_iss_parameter_supported: false,
        client_id_metadata_document_supported: false
      },
      client: %{
        source: :pre_registered,
        client_id: "client",
        token_endpoint_auth_method: :none,
        grant_types: MapSet.new(["authorization_code", "refresh_token"]),
        explicit_refresh_support: true,
        redirect: %{host: "127.0.0.1", path: "/callback"}
      },
      requested_scopes: MapSet.new(["read"]),
      required_scopes: MapSet.new(["read"]),
      refresh_authorized: true,
      freshness_anchor: anchor,
      freshness_anchor_ttl_ms: freshness_ttl_ms
    }
  end

  defp dispatch_binding(store) do
    {:ok, anchor} = Store.time_anchor(store, 1_000)
    %{freshness_anchor: anchor, freshness_anchor_ttl_ms: 5_000}
  end

  defp authority do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "github",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
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
