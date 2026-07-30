defmodule PtcRunner.Kernel.MCPOAuth.MetadataTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Metadata

  setup do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "test",
          "issuer" => "https://auth.example/tenant",
          "scope_ceiling" => ["read", "write", "offline_access"],
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
        "https://mcp.example/a/b?tenant=%2f",
        MapSet.new()
      )

    %{authority: authority}
  end

  test "constructs protected-resource candidates in required order", %{authority: authority} do
    assert Metadata.protected_resource_candidates(authority.resource) == [
             "https://mcp.example/.well-known/oauth-protected-resource/a/b?tenant=%2f",
             "https://mcp.example/.well-known/oauth-protected-resource"
           ]

    assert Metadata.protected_resource_candidates("https://mcp.example/") == [
             "https://mcp.example/.well-known/oauth-protected-resource"
           ]
  end

  test "constructs all path-issuer authorization-server candidates in priority order", %{
    authority: authority
  } do
    assert Metadata.authorization_server_candidates(authority.issuer) == [
             "https://auth.example/.well-known/oauth-authorization-server/tenant",
             "https://auth.example/.well-known/openid-configuration/tenant",
             "https://auth.example/tenant/.well-known/openid-configuration"
           ]
  end

  test "validates resource identity, issuer membership, scopes, and fail-closed fields", %{
    authority: authority
  } do
    document = %{
      "resource" => authority.resource,
      "authorization_servers" => [authority.issuer],
      "scopes_supported" => ["read", "write"]
    }

    assert {:ok, metadata} =
             Metadata.validate_protected_resource(document, authority, "https://source")

    assert metadata.scopes_supported == MapSet.new(["read", "write"])

    for invalid <- [
          Map.put(document, "resource", authority.resource <> "/"),
          Map.put(document, "authorization_servers", ["https://other.example"]),
          Map.put(document, "scopes_supported", []),
          Map.put(document, "dpop_bound_access_tokens_required", true),
          Map.put(document, "signed_metadata", "unverified")
        ] do
      assert {:error, :invalid_protected_resource_metadata} =
               Metadata.validate_protected_resource(invalid, authority, "https://source")
    end
  end

  test "validates OAuth-only and OpenID-shaped authorization metadata", %{
    authority: authority
  } do
    base = %{
      "issuer" => authority.issuer,
      "authorization_endpoint" => "https://auth.example/authorize?route=one",
      "token_endpoint" => "https://auth.example/token",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "response_modes_supported" => ["query"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none", "client_secret_basic"],
      "scopes_supported" => ["read", "offline_access"],
      "authorization_response_iss_parameter_supported" => true
    }

    assert {:ok, metadata} =
             Metadata.validate_authorization_server(base, authority, "https://oauth")

    assert metadata.explicit_refresh_support
    assert metadata.authorization_response_iss_parameter_supported

    openid =
      Map.merge(base, %{
        "jwks_uri" => "https://auth.example/jwks",
        "subject_types_supported" => ["public"],
        "id_token_signing_alg_values_supported" => ["RS256"]
      })

    assert {:ok, _metadata} =
             Metadata.validate_authorization_server(openid, authority, "https://openid")

    for invalid <- [
          Map.delete(base, "code_challenge_methods_supported"),
          Map.put(base, "code_challenge_methods_supported", ["plain"]),
          Map.put(base, "response_types_supported", ["token"]),
          Map.put(base, "response_modes_supported", ["fragment"]),
          Map.put(base, "require_pushed_authorization_requests", true),
          Map.put(base, "authorization_endpoint", "https://auth.example/authorize?state=x")
        ] do
      assert {:error, :invalid_authorization_server_metadata} =
               Metadata.validate_authorization_server(invalid, authority, "https://source")
    end
  end

  test "requires discovered authorization and token endpoint origins to be installed", %{
    authority: authority
  } do
    base = %{
      "issuer" => authority.issuer,
      "authorization_endpoint" => "https://login.example/authorize",
      "token_endpoint" => "https://tokens.example/token",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code"],
      "response_modes_supported" => ["query"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"]
    }

    assert {:error, :invalid_authorization_server_metadata} =
             Metadata.validate_authorization_server(base, authority, "https://source")

    allowed = %{
      authority
      | additional_origins: ["https://login.example", "https://tokens.example"]
    }

    assert {:ok, metadata} =
             Metadata.validate_authorization_server(base, allowed, "https://source")

    assert metadata.authorization_endpoint == "https://login.example/authorize"
    assert metadata.token_endpoint == "https://tokens.example/token"
  end

  test "selects challenge then resource then installed scopes within the ceiling", %{
    authority: authority
  } do
    resource = %{scopes_supported: MapSet.new(["write"])}
    assert {:ok, scopes} = Metadata.select_scopes(%{}, resource, authority)
    assert scopes == MapSet.new(["write"])

    assert {:ok, scopes} =
             Metadata.select_scopes(
               %{scopes: MapSet.new(["read"])},
               resource,
               authority
             )

    assert scopes == MapSet.new(["read"])

    assert {:error, :authorization_required} =
             Metadata.select_scopes(
               %{scopes: MapSet.new(["outside"])},
               resource,
               authority
             )
  end
end
