defmodule PtcRunner.Kernel.MCPOAuth.TokenManagerGlobalStateTest do
  # async: false — kills the application's named ManagerCleanup, which would terminate managers
  # that concurrently running modules have adopted into it (class D). The rest of TokenManager
  # coverage is `async: true`.
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanup
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.MCPOAuth.TokenManager
  alias PtcRunner.Test.MCPOAuthRecordingStore

  @settle_timeout_ms 10_000

  test "cleanup supervisor restart terminates an adopted manager instead of orphaning it" do
    parent = self()

    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "cleanup-restart",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
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

    {:ok, memory} = Memory.start(owner: self())
    {:ok, store} = Memory.store(memory)

    {:ok, claims} =
      Store.claim_authorities(
        store,
        "tenant",
        [{authority.installation_id, authority.fingerprint}],
        Deadline.new(@settle_timeout_ms)
      )

    # Every rejection write fails, so the adopted cleanup worker keeps the
    # manager alive and retrying when its supervisor is killed.
    {:ok, failing_store} =
      MCPOAuthRecordingStore.wrap(store, parent,
        interceptor: fn
          {:mark_access_rejected, _key, _generation}, _timeout ->
            send(parent, :restart_cleanup_persistence_attempted)
            {:return, {:error, :store_error}}

          _operation, _timeout ->
            :delegate
        end
      )

    {:ok, context} =
      Context.new(
        tenant_id: "tenant",
        principal_id: "alice",
        store: failing_store,
        deadline: Deadline.new(@settle_timeout_ms)
      )

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context,
        authority: authority,
        authority_epoch: claims[authority.installation_id]
      )

    manager_ref = Process.monitor(manager.pid)
    deadline = System.monotonic_time(:millisecond) + @settle_timeout_ms

    assert {:error, :store_error} = TokenManager.reject(manager, 1, deadline)
    assert_receive :restart_cleanup_persistence_attempted
    assert :ok = ManagerCleanup.adopt(manager)
    assert_receive :restart_cleanup_persistence_attempted

    cleanup = Process.whereis(ManagerCleanup)
    cleanup_ref = Process.monitor(cleanup)
    Process.exit(cleanup, :kill)

    assert_receive {:DOWN, ^cleanup_ref, :process, ^cleanup, :killed}
    assert_receive {:DOWN, ^manager_ref, :process, _pid, :killed}

    assert_eventually(fn ->
      restarted = Process.whereis(ManagerCleanup)
      is_pid(restarted) and restarted != cleanup
    end)
  end
end
