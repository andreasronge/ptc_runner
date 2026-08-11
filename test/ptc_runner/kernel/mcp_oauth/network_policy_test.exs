defmodule PtcRunner.Kernel.MCPOAuth.NetworkPolicyTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.NetworkPolicy

  setup do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "test",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
          "network" => %{
            "additional_origins" => ["https://client.example"],
            "private_network_origins" => []
          },
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

    %{authority: authority}
  end

  test "allows installed public origins and pins every approved answer", %{
    authority: authority
  } do
    resolver = fn "auth.example" -> {:ok, [{93, 184, 216, 34}]} end

    assert {:ok, target} =
             NetworkPolicy.resolve("https://auth.example/token", authority, resolver: resolver)

    assert target.addresses == [{93, 184, 216, 34}]
    verifier = NetworkPolicy.peer_verifier(target.addresses)
    assert :ok = verifier.({93, 184, 216, 34})
    assert {:error, :peer_rejected} = verifier.({8, 8, 8, 8})
  end

  test "rejects endpoint substitution and one mixed private DNS answer", %{
    authority: authority
  } do
    assert {:error, :egress_denied} =
             NetworkPolicy.resolve("https://attacker.example/token", authority,
               resolver: fn _ -> {:ok, [{8, 8, 8, 8}]} end
             )

    assert {:error, :egress_denied} =
             NetworkPolicy.resolve("https://auth.example/token", authority,
               resolver: fn _ -> {:ok, [{8, 8, 8, 8}, {127, 0, 0, 1}]} end
             )
  end

  test "an exact private-origin exception permits private answers only there", %{
    authority: authority
  } do
    oauth =
      %{
        "installation_id" => authority.installation_id,
        "issuer" => authority.issuer,
        "scope_ceiling" => ["read"],
        "network" => %{
          "additional_origins" => [],
          "private_network_origins" => ["https://auth.example"]
        },
        "client" => %{
          "registration" => "pre_registered",
          "client_id" => "client",
          "token_endpoint_auth_method" => "none",
          "grant_types" => ["authorization_code"],
          "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
        }
      }

    {:ok, private_authority} =
      Authority.from_host(oauth, authority.resource, MapSet.new())

    assert {:ok, _target} =
             NetworkPolicy.resolve("https://auth.example/token", private_authority,
               resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
             )

    assert {:error, :egress_denied} =
             NetworkPolicy.resolve(authority.resource, private_authority,
               resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
             )
  end

  test "a separately installed private origin is both allowlisted and private-enabled", %{
    authority: authority
  } do
    private_origin = "http://127.0.0.1:8765"

    oauth =
      %{
        "installation_id" => authority.installation_id,
        "issuer" => authority.issuer,
        "scope_ceiling" => ["read"],
        "network" => %{
          "additional_origins" => [],
          "private_network_origins" => [private_origin]
        },
        "client" => %{
          "registration" => "pre_registered",
          "client_id" => "client",
          "token_endpoint_auth_method" => "none",
          "grant_types" => ["authorization_code"],
          "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
        }
      }

    {:ok, private_authority} =
      Authority.from_host(oauth, authority.resource, MapSet.new())

    assert {:ok, target} =
             NetworkPolicy.resolve(private_origin <> "/token", private_authority,
               resolver: fn "127.0.0.1" -> {:ok, [{127, 0, 0, 1}]} end
             )

    assert target.origin == private_origin
  end

  test "bounds a resolver that never returns by the supplied absolute deadline", %{
    authority: authority
  } do
    resolver = fn _hostname ->
      receive do
        :never -> {:ok, [{8, 8, 8, 8}]}
      end
    end

    deadline_ms = System.monotonic_time(:millisecond) + 20

    # Under scheduler load the 20ms may already be spent before resolve/3
    # checks the clock; the expired-deadline path now also classifies as
    # :resolution_failed, so either interleaving yields the same error.
    assert {:error, :resolution_failed} =
             NetworkPolicy.resolve("https://auth.example/token", authority,
               resolver: resolver,
               deadline_ms: deadline_ms
             )

    # Proves the never-returning resolver did not block us indefinitely.
    # Generous: this measures wall time across scheduling, not promptness.
    assert System.monotonic_time(:millisecond) - deadline_ms < 5_000
  end

  test "classifies representative reserved IPv4 and IPv6 ranges" do
    for address <- [
          {10, 0, 0, 1},
          {100, 64, 0, 1},
          {169, 254, 1, 1},
          {192, 0, 2, 1},
          {198, 51, 100, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
          {0x2002, 0, 0, 0, 0, 0, 0, 1},
          {0x3FFF, 0, 0, 0, 0, 0, 0, 1}
        ] do
      refute NetworkPolicy.public_address?(address)
    end

    assert NetworkPolicy.public_address?({8, 8, 8, 8})
    assert NetworkPolicy.public_address?({0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111})
  end
end
