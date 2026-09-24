defmodule PtcRunner.Kernel.ProviderExecutionOAuthTest do
  # The cases that trace VM-wide, stop and restart :req_llm, or mutate the OS environment live in
  # ProviderExecutionOAuthGlobalStateTest.
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.ProviderExecutionOAuthFixtures

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.Discovery
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.RunCoordinator

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

    assert diagnostic.message ==
             "provider authorization is required; runtime-included ptc cannot initiate " <>
               "authorization; source-checkout mix ptc run ... --authorize-mcp NAME can " <>
               "initiate it, and embedding hosts may provide authorization"

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
    # The worker is released when its authorization deadline expires, which
    # the occurrence timeout caps; the 5 s default would be spent waiting here.
    fixture = provider_fixture(server, ["fixture"], provider_config: %{"timeout_ms" => 2_000})

    caller = spawn_blocked_caller(parent, fixture)

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

  defp expires_in(milliseconds), do: Deadline.expires_at(Deadline.new(milliseconds))
end
