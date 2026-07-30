defmodule PtcRunner.Kernel.MCPOAuth.TokenResponseTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.TokenResponse

  @headers [{"content-type", "application/json; charset=UTF-8"}]

  test "projects only supported success fields" do
    requested = MapSet.new(["read", "write"])

    body =
      Jason.encode!(%{
        "access_token" => "opaque.token==",
        "refresh_token" => "rotate-me",
        "token_type" => "bEaReR",
        "expires_in" => 60,
        "scope" => "read",
        "id_token" => "discard",
        "unknown" => %{"secret" => "discard"}
      })

    assert {:ok,
            %{
              access_token: "opaque.token==",
              refresh_token: "rotate-me",
              token_type: :bearer,
              expires_in_ms: 60_000,
              granted_scopes: scopes
            }} =
             TokenResponse.success(200, @headers, body,
               requested_scopes: requested,
               refresh_authorized: true
             )

    assert scopes == MapSet.new(["read"])
  end

  test "discards unsolicited refresh tokens" do
    body =
      Jason.encode!(%{
        "access_token" => "access",
        "refresh_token" => "unsolicited",
        "token_type" => "Bearer"
      })

    assert {:ok, grant} =
             TokenResponse.success(200, @headers, body,
               requested_scopes: MapSet.new(["read"]),
               refresh_authorized: false
             )

    refute Map.has_key?(grant, :refresh_token)
    assert grant.granted_scopes == MapSet.new(["read"])
  end

  test "accepts the complete RFC 6749 VSCHAR range for refresh tokens" do
    body =
      Jason.encode!(%{
        "access_token" => "access",
        "refresh_token" => "opaque refresh token",
        "token_type" => "Bearer"
      })

    assert {:ok, %{refresh_token: "opaque refresh token"}} =
             TokenResponse.success(200, @headers, body,
               requested_scopes: MapSet.new(["read"]),
               refresh_authorized: true
             )
  end

  test "rejects malformed tokens, duplicate keys, scope expansion, and expiry shapes" do
    base = %{"access_token" => "access", "token_type" => "Bearer"}
    requested = MapSet.new(["read"])

    invalid_bodies = [
      Jason.encode!(%{base | "access_token" => ""}),
      Jason.encode!(%{base | "access_token" => "with space"}),
      Jason.encode!(%{base | "access_token" => "bad=padding=x"}),
      Jason.encode!(Map.put(base, "expires_in", 0)),
      Jason.encode!(Map.put(base, "expires_in", 1.5)),
      Jason.encode!(Map.put(base, "expires_in", "60")),
      Jason.encode!(Map.put(base, "scope", "write")),
      ~s({"access_token":"one","access_token":"two","token_type":"Bearer"})
    ]

    Enum.each(invalid_bodies, fn body ->
      assert {:error, :invalid_token_response} =
               TokenResponse.success(200, @headers, body,
                 requested_scopes: requested,
                 refresh_authorized: true
               )
    end)
  end

  test "accepts only bounded 400 or 401 OAuth error projections" do
    assert {:ok, "invalid_grant"} =
             TokenResponse.error(
               400,
               @headers,
               Jason.encode!(%{
                 "error" => "invalid_grant",
                 "error_description" => "discard",
                 "error_uri" => "https://attacker.invalid"
               })
             )

    assert {:error, :invalid_token_response} =
             TokenResponse.error(500, @headers, ~s({"error":"invalid_grant"}))

    assert {:error, :invalid_token_response} =
             TokenResponse.error(400, @headers, ~s({"error":"bad\nerror"}))
  end
end
