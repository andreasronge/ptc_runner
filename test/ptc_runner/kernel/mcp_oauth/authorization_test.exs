defmodule PtcRunner.Kernel.MCPOAuth.AuthorizationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Metadata
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
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

    {:ok,
     authority: authority,
     context: context,
     store: store,
     epoch: claims[authority.installation_id]}
  end

  test "begins and completes a one-time S256 authorization", context do
    {:ok, recording_store} =
      MCPOAuthRecordingStore.wrap(context.store, self(), expire_callback?: true)

    {:ok, authorization_context} =
      Context.new(
        tenant_id: "tenant",
        principal_id: "alice",
        store: recording_store
      )

    request =
      context.authority
      |> request_fixture(self())
      |> record_requests(self())

    redirect_uri = "http://127.0.0.1:49152/callback"

    assert {:ok, pending} =
             Authorization.begin_authorization(authorization_context, context.authority,
               authority_epoch: context.epoch,
               redirect_uri: redirect_uri,
               request: request
             )

    assert {:time_anchor, initial_anchor} = next_sequence()
    assert next_sequence() == {:request, :post, context.authority.resource}
    assert {:request, :get, _protected_resource} = next_sequence()
    assert {:request, :get, _authorization_server} = next_sequence()
    assert next_sequence() == {:begin_flow, initial_anchor}

    query = pending.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["response_type"] == "code"
    assert query["code_challenge_method"] == "S256"
    assert query["resource"] == context.authority.resource
    refute Map.has_key?(query, "code_verifier")

    assert {:error, :invalid_callback} =
             Authorization.complete_authorization(
               authorization_context,
               pending,
               [{"code", "code-1"}, {"state", "wrong"}, {"iss", context.authority.issuer}],
               request: request
             )

    assert {:ok, grant} =
             Authorization.complete_authorization(
               authorization_context,
               pending,
               [
                 {"code", "code-1"},
                 {"state", query["state"]},
                 {"iss", context.authority.issuer}
               ],
               request: request
             )

    assert {:time_anchor, callback_anchor} = next_sequence()
    assert next_sequence() == {:request, :post, context.authority.resource}
    assert {:request, :get, _protected_resource} = next_sequence()
    assert {:request, :get, _authorization_server} = next_sequence()
    assert {:time_anchor, _token_anchor} = next_sequence()
    assert next_sequence() == {:begin_code_dispatch, callback_anchor}
    assert next_sequence() == {:request, :post, "https://auth.example/token"}

    assert grant.access_token == "access-token"
    assert grant.generation == 1

    assert {:error, :stale_flow} =
             Authorization.complete_authorization(
               authorization_context,
               pending,
               [
                 {"code", "code-1"},
                 {"state", query["state"]},
                 {"iss", context.authority.issuer}
               ],
               request: request
             )

    assert_receive {:token_exchange, form}
    assert form["code"] == "code-1"
    assert form["redirect_uri"] == redirect_uri
    assert form["resource"] == context.authority.resource
  end

  test "revalidates no-cache metadata before code dispatch", context do
    request = request_fixture(context.authority, self(), "no-cache, max-age=3600")
    redirect_uri = "http://127.0.0.1:49152/callback"

    assert {:ok, pending} =
             Authorization.begin_authorization(context.context, context.authority,
               authority_epoch: context.epoch,
               redirect_uri: redirect_uri,
               request: request
             )

    query = pending.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:ok, grant} =
             Authorization.complete_authorization(
               context.context,
               pending,
               [
                 {"code", "code-1"},
                 {"state", query["state"]},
                 {"iss", context.authority.issuer}
               ],
               request: request
             )

    assert grant.access_token == "access-token"
    assert_receive {:token_exchange, _form}
  end

  test "carries a persisted step-up scope through code exchange and validation", context do
    {:ok, grant} =
      seed_grant(
        context.store,
        Context.grant_key(context.context, context.authority, context.epoch)
      )

    key = Context.grant_key(context.context, context.authority, context.epoch)

    assert {:ok, _version} =
             Store.upsert_requirement(
               context.store,
               key,
               grant.generation,
               MapSet.new(["write"]),
               5_000,
               1_000
             )

    request = request_fixture(context.authority, self(), "max-age=120", "read write")
    redirect_uri = "http://127.0.0.1:49152/callback"

    assert {:ok, pending} =
             Authorization.begin_authorization(context.context, context.authority,
               authority_epoch: context.epoch,
               redirect_uri: redirect_uri,
               request: request
             )

    query = pending.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert MapSet.new(String.split(query["scope"])) == MapSet.new(["read", "write"])

    assert {:ok, completed} =
             Authorization.complete_authorization(
               context.context,
               pending,
               [
                 {"code", "step-up-code"},
                 {"state", query["state"]},
                 {"iss", context.authority.issuer}
               ],
               request: request
             )

    assert completed.granted_scopes == MapSet.new(["read", "write"])
    assert_receive {:token_exchange, form}
    assert MapSet.new(String.split(form["scope"])) == MapSet.new(["read", "write"])
  end

  test "validates the issuer on denial callbacks without consuming a mismatch", context do
    request = request_fixture(context.authority, self())

    assert {:ok, pending} =
             Authorization.begin_authorization(context.context, context.authority,
               authority_epoch: context.epoch,
               redirect_uri: "http://127.0.0.1:49152/callback",
               request: request
             )

    state =
      pending.url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    assert {:error, :invalid_callback} =
             Authorization.complete_authorization(
               context.context,
               pending,
               [{"error", "access_denied"}, {"state", state}, {"iss", "https://wrong.example"}],
               request: request
             )

    assert {:error, :authorization_denied} =
             Authorization.complete_authorization(
               context.context,
               pending,
               [
                 {"error", "access_denied"},
                 {"state", state},
                 {"iss", context.authority.issuer}
               ],
               request: request
             )
  end

  test "a pending flow cannot be completed or cancelled by another principal", context do
    request = request_fixture(context.authority, self())

    {:ok, bob} =
      Context.new(
        tenant_id: "tenant",
        principal_id: "bob",
        store: context.store
      )

    assert {:ok, pending} =
             Authorization.begin_authorization(context.context, context.authority,
               authority_epoch: context.epoch,
               redirect_uri: "http://127.0.0.1:49152/callback",
               request: request
             )

    state =
      pending.url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    callback = [
      {"code", "code-1"},
      {"state", state},
      {"iss", context.authority.issuer}
    ]

    assert {:error, :invalid_authorization_context} =
             Authorization.complete_authorization(bob, pending, callback, request: request)

    assert {:error, :invalid_authorization_context} =
             Authorization.cancel_authorization(bob, pending, [])

    assert {:ok, _grant} =
             Authorization.complete_authorization(
               context.context,
               pending,
               callback,
               request: request
             )
  end

  test "loopback callback binds an ephemeral literal-IP port and closes after one request",
       context do
    request = request_fixture(context.authority, self())
    assert {:ok, listener} = LoopbackListener.start(context.authority)
    assert listener.port > 0
    assert listener.redirect_uri =~ "http://127.0.0.1:#{listener.port}/callback"
    assert inspect(listener) == "#PtcRunner.MCPOAuth.LoopbackListener<redacted>"

    assert {:ok, pending} =
             Authorization.begin_authorization(context.context, context.authority,
               authority_epoch: context.epoch,
               redirect_uri: listener.redirect_uri,
               request: request
             )

    state =
      pending.url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    parent = self()

    task =
      Task.async(fn ->
        receive do
          :go -> :ok
        end

        result =
          LoopbackListener.await(listener, context.context, pending, request: request)

        send(parent, {:awaited, result})
      end)

    assert :ok = :gen_tcp.controlling_process(listener.socket, task.pid)
    send(task.pid, :go)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, listener.port, [:binary, active: false], 1_000)

    target =
      "/callback?" <>
        URI.encode_query(%{
          "code" => "loopback-code",
          "state" => state,
          "iss" => context.authority.issuer
        })

    request_head =
      "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{listener.port}\r\nConnection: close\r\n\r\n"

    assert :ok = :gen_tcp.send(socket, request_head)
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    assert response =~ "200 OK"
    assert_receive {:awaited, {:ok, %{access_token: "access-token"}}}
    assert {:ok, _result} = Task.yield(task, 1_000)
  end

  test "loopback callback rejects a non-UTF-8 header without crashing", context do
    request = request_fixture(context.authority, self())
    assert {:ok, listener} = LoopbackListener.start(context.authority)

    assert {:ok, pending} =
             Authorization.begin_authorization(context.context, context.authority,
               authority_epoch: context.epoch,
               redirect_uri: listener.redirect_uri,
               request: request
             )

    task =
      Task.async(fn ->
        receive do
          :go -> :ok
        end

        LoopbackListener.await(listener, context.context, pending, request: request)
      end)

    assert :ok = :gen_tcp.controlling_process(listener.socket, task.pid)
    send(task.pid, :go)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, listener.port, [:binary, active: false], 1_000)

    request_head =
      "GET /callback HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{listener.port}\r\n" <>
        "X-Invalid: " <> <<0xFF>> <> "\r\n\r\n"

    assert :ok = :gen_tcp.send(socket, request_head)
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    assert response =~ "400 Bad Request"

    assert {:error, :invalid_callback_request} = Task.await(task, 1_000)
  end

  defp request_fixture(
         authority,
         parent,
         cache_control \\ "max-age=120",
         token_scope \\ "read"
       ) do
    [resource | _] = Metadata.protected_resource_candidates(authority.resource)
    [server | _] = Metadata.authorization_server_candidates(authority.issuer)

    fn
      :post, url, _headers, body, _timeout when url == authority.resource ->
        assert Jason.decode!(body)["method"] == "server/discover"

        {:ok,
         %{
           status: 401,
           headers: [{"www-authenticate", ~s(Bearer scope="read")}],
           body: ""
         }}

      :get, ^resource, _headers, _body, _timeout ->
        json(
          %{
            "resource" => authority.resource,
            "authorization_servers" => [authority.issuer],
            "scopes_supported" => ["read"]
          },
          cache_control
        )

      :get, ^server, _headers, _body, _timeout ->
        json(
          %{
            "issuer" => authority.issuer,
            "authorization_endpoint" => "https://auth.example/authorize",
            "token_endpoint" => "https://auth.example/token",
            "response_types_supported" => ["code"],
            "grant_types_supported" => ["authorization_code", "refresh_token"],
            "response_modes_supported" => ["query"],
            "code_challenge_methods_supported" => ["S256"],
            "token_endpoint_auth_methods_supported" => ["none"],
            "scopes_supported" => ["read"],
            "authorization_response_iss_parameter_supported" => true
          },
          cache_control
        )

      :post, "https://auth.example/token", _headers, body, _timeout ->
        send(parent, {:token_exchange, URI.decode_query(body)})

        json(%{
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "token_type" => "Bearer",
          "expires_in" => 3_600,
          "scope" => token_scope
        })

      _method, _url, _headers, _body, _timeout ->
        {:ok, %{status: 404, headers: [], body: ""}}
    end
  end

  defp record_requests(request, observer) do
    fn method, url, headers, body, timeout ->
      send(observer, {:oauth_sequence, {:request, method, url}})
      request.(method, url, headers, body, timeout)
    end
  end

  defp next_sequence do
    assert_receive {:oauth_sequence, event}
    event
  end

  defp json(document, cache_control \\ "max-age=120") do
    {:ok,
     %{
       status: 200,
       headers: [
         {"content-type", "application/json"},
         {"cache-control", cache_control}
       ],
       body: Jason.encode!(document)
     }}
  end

  defp authority do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "oauth-test",
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

  defp seed_grant(store, key) do
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
        access_token: "old-access",
        refresh_token: "old-refresh",
        requested_scopes: MapSet.new(["read"]),
        granted_scopes: MapSet.new(["read"]),
        refresh_authorized: true,
        redirect_uri: "http://127.0.0.1:49152/callback",
        metadata_revision: 1,
        metadata_binding: nil
      },
      60_000,
      anchor,
      1_000
    )
  end
end
