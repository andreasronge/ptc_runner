defmodule PtcRunner.Kernel.MCPOAuth.DiscoveryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Discovery
  alias PtcRunner.Kernel.MCPOAuth.Metadata

  test "collapses endpoint connection causes at the OAuth boundary" do
    for reason <- [:connection_refused, :name_not_resolved, :tls_handshake_failed] do
      assert {:error, :transport_error} =
               Discovery.discover(authority(),
                 request: fn _method, _url, _headers, _body, _timeout -> {:error, reason} end
               )
    end

    assert {:error, :transport_error} =
             Discovery.discover(authority(),
               resolver: fn _hostname -> {:error, :nxdomain} end
             )
  end

  test "runs challenge, resource, and authorization-server fallbacks in order" do
    authority = authority()
    parent = self()
    [resource_path, resource_root] = Metadata.protected_resource_candidates(authority.resource)
    [oauth, openid | _rest] = Metadata.authorization_server_candidates(authority.issuer)

    responses = %{
      {:post, authority.resource} =>
        response(
          401,
          "",
          [{"www-authenticate", ~s(Basic realm="x", Bearer scope="read")}]
        ),
      {:get, resource_path} => response(404, "not found"),
      {:get, resource_root} =>
        json_response(%{
          "resource" => authority.resource,
          "authorization_servers" => [authority.issuer],
          "scopes_supported" => ["read"]
        }),
      {:get, oauth} => response(404, "not found"),
      {:get, openid} => json_response(server_document(authority))
    }

    request = fn method, url, _headers, _body, timeout ->
      send(parent, {:request, method, url})
      assert timeout > 0
      {:ok, Map.fetch!(responses, {method, url})}
    end

    assert {:ok, binding} = Discovery.discover(authority, request: request)
    assert binding.requested_scopes == MapSet.new(["read", "offline_access"])
    assert binding.required_scopes == MapSet.new(["read"])
    assert binding.refresh_authorized
    assert binding.freshness_ttl_ms in 1..120_000

    resource_url = authority.resource
    assert_receive {:request, :post, ^resource_url}
    assert_receive {:request, :get, ^resource_path}
    assert_receive {:request, :get, ^resource_root}
    assert_receive {:request, :get, ^oauth}
    assert_receive {:request, :get, ^openid}
  end

  test "keeps automatically requested offline_access optional" do
    authority = authority()
    [resource_path | _rest] = Metadata.protected_resource_candidates(authority.resource)
    [oauth | _rest] = Metadata.authorization_server_candidates(authority.issuer)

    responses = %{
      {:post, authority.resource} => response(401, "", [{"www-authenticate", "Bearer"}]),
      {:get, resource_path} =>
        json_response(%{
          "resource" => authority.resource,
          "authorization_servers" => [authority.issuer],
          "scopes_supported" => ["read"]
        }),
      {:get, oauth} => json_response(server_document(authority))
    }

    request = fn method, url, _headers, _body, _timeout ->
      case Map.fetch(responses, {method, url}) do
        {:ok, response} -> {:ok, response}
        :error -> {:ok, response(404, "not found")}
      end
    end

    assert {:ok, binding} = Discovery.discover(authority, request: request)
    assert binding.requested_scopes == MapSet.new(["read", "offline_access"])
    assert binding.required_scopes == MapSet.new(["read"])
  end

  test "a challenge-directed resource metadata URL fails closed without fallback" do
    authority = authority()
    directed = "https://mcp.example/directed-metadata"
    parent = self()

    request = fn
      :post, _url, _headers, _body, _timeout ->
        {:ok,
         response(
           401,
           "",
           [{"www-authenticate", ~s(Bearer resource_metadata="#{directed}")}]
         )}

      :get, ^directed, _headers, _body, _timeout ->
        send(parent, :directed)
        {:ok, response(500, "failure")}

      :get, other, _headers, _body, _timeout ->
        send(parent, {:unexpected_fallback, other})
        {:ok, response(500, "failure")}
    end

    assert {:error, :mcp_authorization_discovery_failed} =
             Discovery.discover(authority, request: request)

    assert_receive :directed
    refute_receive {:unexpected_fallback, _url}
  end

  test "validates a CIMD public client with structured JSON media type" do
    authority = cimd_authority()
    [resource | _] = Metadata.protected_resource_candidates(authority.resource)
    [server | _] = Metadata.authorization_server_candidates(authority.issuer)
    redirect = "http://127.0.0.1:49152/callback"

    responses = %{
      {:post, authority.resource} => response(401, ""),
      {:get, resource} =>
        json_response(%{
          "resource" => authority.resource,
          "authorization_servers" => [authority.issuer],
          "scopes_supported" => ["read"]
        }),
      {:get, server} =>
        json_response(
          Map.put(server_document(authority), "client_id_metadata_document_supported", true)
        ),
      {:get, authority.client.client_id} =>
        response(
          200,
          Jason.encode!(%{
            "client_id" => authority.client.client_id,
            "client_name" => "PtcRunner",
            "redirect_uris" => ["http://127.0.0.1:12345/callback"],
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code", "refresh_token"],
            "response_types" => ["code"]
          }),
          [{"content-type", "application/oauth-client-metadata+json"}]
        )
    }

    request = fn method, url, _headers, _body, _timeout ->
      case Map.fetch(responses, {method, url}) do
        {:ok, response} -> {:ok, response}
        :error -> {:ok, response(404, "")}
      end
    end

    assert {:ok, binding} =
             Discovery.discover(authority, request: request, redirect_uri: redirect)

    assert binding.client.explicit_refresh_support
    assert binding.refresh_authorized
  end

  test "debits response latency from Protected Resource, server, and CIMD freshness" do
    authority = cimd_authority()
    [resource | _] = Metadata.protected_resource_candidates(authority.resource)
    [server | _] = Metadata.authorization_server_candidates(authority.issuer)
    client = authority.client.client_id
    redirect = "http://127.0.0.1:49152/callback"

    responses = %{
      {:post, authority.resource} => response(401, ""),
      {:get, resource} =>
        json_response(
          %{
            "resource" => authority.resource,
            "authorization_servers" => [authority.issuer],
            "scopes_supported" => ["read"]
          },
          1
        ),
      {:get, server} =>
        json_response(
          Map.put(server_document(authority), "client_id_metadata_document_supported", true),
          1
        ),
      {:get, client} =>
        response(
          200,
          Jason.encode!(%{
            "client_id" => client,
            "client_name" => "PtcRunner",
            "redirect_uris" => ["http://127.0.0.1:12345/callback"],
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code", "refresh_token"],
            "response_types" => ["code"]
          }),
          [
            {"content-type", "application/oauth-client-metadata+json"},
            {"cache-control", "max-age=1"}
          ]
        )
    }

    Enum.each([resource, server, client], fn delayed_url ->
      request = fn method, url, _headers, _body, _timeout ->
        if url == delayed_url, do: wait_ms(5)

        case Map.fetch(responses, {method, url}) do
          {:ok, response} -> {:ok, response}
          :error -> {:ok, response(404, "")}
        end
      end

      assert {:ok, binding} =
               Discovery.discover(authority, request: request, redirect_uri: redirect)

      assert binding.freshness_anchor_ttl_ms == 1_000
      assert binding.freshness_ttl_ms <= 995
    end)
  end

  test "requires immediate revalidation for no-cache metadata" do
    assert {:ok, binding} =
             discover_with_resource_cache_headers([
               {"cache-control", "no-cache, max-age=3600"}
             ])

    assert binding.freshness_anchor_ttl_ms == 0
    assert binding.freshness_ttl_ms == 0
    assert binding.revalidation_required
  end

  test "requires immediate revalidation for malformed or duplicate max-age" do
    for headers <- [
          [{"cache-control", "max-age=invalid"}],
          [{"cache-control", "max-age=3600, max-age=0"}],
          [{"cache-control", "max-age=3600"}, {"cache-control", "max-age=3600"}]
        ] do
      assert {:ok, binding} = discover_with_resource_cache_headers(headers)
      assert binding.freshness_anchor_ttl_ms == 0
      assert binding.freshness_ttl_ms == 0
      assert binding.revalidation_required
    end
  end

  test "debits a cached metadata response's Age from max-age" do
    assert {:ok, binding} =
             discover_with_resource_cache_headers([
               {"cache-control", "max-age=3600"},
               {"age", "3599"}
             ])

    assert binding.freshness_anchor_ttl_ms == 1_000
    assert binding.freshness_ttl_ms in 1..1_000
    refute binding.revalidation_required
  end

  test "rejects duplicate metadata members before projection" do
    authority = authority()
    [resource | _] = Metadata.protected_resource_candidates(authority.resource)

    request = fn
      :post, _url, _headers, _body, _timeout ->
        {:ok, response(401, "")}

      :get, ^resource, _headers, _body, _timeout ->
        {:ok,
         response(
           200,
           ~s({"resource":"#{authority.resource}","resource":"#{authority.resource}","authorization_servers":["#{authority.issuer}"]}),
           [{"content-type", "application/json"}]
         )}

      :get, _other, _headers, _body, _timeout ->
        {:ok, response(404, "")}
    end

    assert {:error, :mcp_authorization_discovery_failed} =
             Discovery.discover(authority, request: request)
  end

  defp response(status, body, extra_headers \\ []) do
    %{
      status: status,
      headers: extra_headers,
      body: body
    }
  end

  defp json_response(document, max_age \\ 120) do
    response(
      200,
      Jason.encode!(document),
      [
        {"content-type", "application/json; charset=UTF-8"},
        {"cache-control", "max-age=#{max_age}"}
      ]
    )
  end

  defp discover_with_resource_cache_headers(cache_headers) do
    authority = authority()
    [resource | _] = Metadata.protected_resource_candidates(authority.resource)
    [server | _] = Metadata.authorization_server_candidates(authority.issuer)

    request = fn
      :post, url, _headers, _body, _timeout when url == authority.resource ->
        {:ok, response(401, "")}

      :get, ^resource, _headers, _body, _timeout ->
        {:ok,
         response(
           200,
           Jason.encode!(%{
             "resource" => authority.resource,
             "authorization_servers" => [authority.issuer],
             "scopes_supported" => ["read"]
           }),
           [{"content-type", "application/json"} | cache_headers]
         )}

      :get, ^server, _headers, _body, _timeout ->
        {:ok, json_response(server_document(authority), 3_600)}

      :get, _other, _headers, _body, _timeout ->
        {:ok, response(404, "")}
    end

    Discovery.discover(authority, request: request)
  end

  defp wait_ms(duration_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + duration_ms
    wait_until(deadline_ms)
  end

  defp wait_until(deadline_ms) do
    if System.monotonic_time(:millisecond) >= deadline_ms,
      do: :ok,
      else: wait_until(deadline_ms)
  end

  defp server_document(authority) do
    %{
      "issuer" => authority.issuer,
      "authorization_endpoint" => "https://auth.example/authorize",
      "token_endpoint" => "https://auth.example/token",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "response_modes_supported" => ["query"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "scopes_supported" => ["read", "offline_access"],
      "authorization_response_iss_parameter_supported" => true
    }
  end

  defp authority do
    oauth = %{
      "installation_id" => "test",
      "issuer" => "https://auth.example",
      "scope_ceiling" => ["read", "offline_access"],
      "default_scopes" => ["read"],
      "refresh_access" => "when_supported",
      "client" => %{
        "registration" => "pre_registered",
        "client_id" => "client",
        "token_endpoint_auth_method" => "none",
        "grant_types" => ["authorization_code", "refresh_token"],
        "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
      }
    }

    {:ok, authority} =
      Authority.from_host(oauth, "https://mcp.example/a/b?tenant=one", MapSet.new())

    authority
  end

  defp cimd_authority do
    oauth = %{
      "installation_id" => "cimd",
      "issuer" => "https://auth.example",
      "scope_ceiling" => ["read", "offline_access"],
      "default_scopes" => ["read"],
      "refresh_access" => "when_supported",
      "network" => %{"additional_origins" => ["https://client.example"]},
      "client" => %{
        "registration" => "client_id_metadata_document",
        "client_id" => "https://client.example/client.json",
        "token_endpoint_auth_method" => "none",
        "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
      }
    }

    {:ok, authority} =
      Authority.from_host(oauth, "https://mcp.example/mcp", MapSet.new())

    authority
  end
end
