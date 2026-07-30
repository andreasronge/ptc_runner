defmodule PtcRunner.Kernel.MCPOAuth.AuthorityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.Authority

  test "validates a public pre-registered authority and canonicalizes only resource case" do
    assert {:ok, authority} =
             Authority.from_host(
               public_authority(),
               "HTTPS://MCP.EXAMPLE:443/a/?tenant=%2f",
               MapSet.new()
             )

    assert authority.resource == "https://mcp.example:443/a/?tenant=%2f"
    assert authority.issuer == "https://AUTH.EXAMPLE/tenant/"
    assert authority.scope_ceiling == MapSet.new(["offline_access", "repo:read"])
    assert authority.default_scopes == MapSet.new(["repo:read"])

    assert authority.client.grant_types ==
             MapSet.new(["authorization_code", "refresh_token"])

    assert Authority.cli_compatible?(authority)
    assert authority.fingerprint =~ ~r/\Av1:[0-9a-f]{64}\z/
  end

  test "fingerprint changes for every security-relevant edit" do
    base = public_authority()
    {:ok, original} = Authority.from_host(base, base["resource"], MapSet.new())

    edits = [
      put_in(base, ["default_scopes"], ["offline_access"]),
      put_in(base, ["refresh_access"], "none"),
      put_in(base, ["unknown_expiry_ttl_ms"], 301_000),
      put_in(base, ["network", "additional_origins"], ["https://extra.example"]),
      put_in(base, ["client", "grant_types"], ["authorization_code"]),
      put_in(base, ["client", "loopback_redirect", "path"], "/other")
    ]

    Enum.each(edits, fn edited ->
      assert {:ok, changed} = Authority.from_host(edited, edited["resource"], MapSet.new())
      refute changed.fingerprint == original.fingerprint
    end)
  end

  test "rejects resource near matches and scope widening" do
    base = public_authority()

    for endpoint <- [
          "https://mcp.example/a",
          "https://mcp.example:443/a/",
          "https://mcp.example:443/a/?tenant=%2F"
        ] do
      assert {:error, :invalid_oauth_authority} =
               Authority.from_host(base, endpoint, MapSet.new())
    end

    assert {:error, :invalid_oauth_authority} =
             base
             |> put_in(["default_scopes"], ["outside"])
             |> Authority.from_host(base["resource"], MapSet.new())
  end

  test "requires an exact existing secret binding for confidential clients" do
    confidential =
      public_authority()
      |> put_in(["client"], %{
        "registration" => "pre_registered",
        "client_id" => "client",
        "token_endpoint_auth_method" => "client_secret_basic",
        "client_secret_binding" => "oauth_secret",
        "grant_types" => ["authorization_code"],
        "redirect_uris" => ["https://APP.EXAMPLE/callback"]
      })

    assert {:error, :invalid_oauth_authority} =
             Authority.from_host(confidential, confidential["resource"], MapSet.new())

    assert {:ok, authority} =
             Authority.from_host(
               confidential,
               confidential["resource"],
               MapSet.new(["oauth_secret"])
             )

    refute Authority.cli_compatible?(authority)
    assert authority.client.client_secret_binding == "oauth_secret"
    assert authority.client.redirect == {:https, ["https://APP.EXAMPLE/callback"]}
  end

  test "validates CIMD URL and requires explicit public authentication" do
    cimd =
      public_authority()
      |> put_in(["client"], %{
        "registration" => "client_id_metadata_document",
        "client_id" => "https://client.example/metadata.json",
        "token_endpoint_auth_method" => "none",
        "loopback_redirect" => %{"host" => "::1", "path" => "/callback"}
      })

    assert {:ok, authority} =
             Authority.from_host(cimd, cimd["resource"], MapSet.new())

    assert authority.client.registration == :client_id_metadata_document

    assert {:error, :invalid_oauth_authority} =
             cimd
             |> update_in(["client"], &Map.delete(&1, "token_endpoint_auth_method"))
             |> Authority.from_host(cimd["resource"], MapSet.new())

    assert {:error, :invalid_oauth_authority} =
             cimd
             |> put_in(
               ["client", "client_id"],
               "https://client.example/" <> String.duplicate("a", 2_048)
             )
             |> Authority.from_host(cimd["resource"], MapSet.new())
  end

  test "rejects localhost and mixed redirect forms" do
    base = public_authority()

    assert {:error, :invalid_oauth_authority} =
             base
             |> put_in(["client", "loopback_redirect", "host"], "localhost")
             |> Authority.from_host(base["resource"], MapSet.new())

    assert {:error, :invalid_oauth_authority} =
             base
             |> put_in(["client", "redirect_uris"], ["https://app.example/callback"])
             |> Authority.from_host(base["resource"], MapSet.new())
  end

  defp public_authority do
    %{
      "installation_id" => "github-primary",
      "issuer" => "https://AUTH.EXAMPLE/tenant/",
      "resource" => "https://mcp.example:443/a/?tenant=%2f",
      "scope_ceiling" => ["repo:read", "offline_access"],
      "default_scopes" => ["repo:read"],
      "refresh_access" => "when_supported",
      "authorization_timeout_ms" => 300_000,
      "unknown_expiry_ttl_ms" => 300_000,
      "network" => %{
        "additional_origins" => [],
        "private_network_origins" => []
      },
      "client" => %{
        "registration" => "pre_registered",
        "client_id" => "public-client",
        "token_endpoint_auth_method" => "none",
        "grant_types" => ["authorization_code", "refresh_token"],
        "loopback_redirect" => %{
          "host" => "127.0.0.1",
          "path" => "/callback"
        }
      }
    }
  end
end
