defmodule PtcRunner.Kernel.HostConfigOAuthTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory

  test "decodes OAuth only when normalized static authentication is empty" do
    config = host_config()

    assert {:ok, decoded} = HostConfig.decode(config, "/tmp")
    transport = decoded.install["github"].transport

    assert transport.auth == []
    assert %Authority{} = transport.oauth
    assert transport.oauth.installation_id == "github-primary"

    assert {:ok, explicit_empty} =
             config
             |> put_in(["install", "github", "transport", "auth"], [])
             |> HostConfig.decode("/tmp")

    assert explicit_empty.install["github"].transport.oauth.fingerprint ==
             transport.oauth.fingerprint

    assert {:error, :invalid_host_config} =
             config
             |> put_in(
               ["install", "github", "transport", "auth"],
               [%{"scheme" => "bearer", "binding" => "token"}]
             )
             |> HostConfig.decode("/tmp")
  end

  test "client secret bindings are validated but not added to static auth" do
    config =
      host_config()
      |> put_in(["install", "github", "transport", "oauth", "client"], %{
        "registration" => "pre_registered",
        "client_id" => "confidential",
        "token_endpoint_auth_method" => "client_secret_basic",
        "client_secret_binding" => "oauth_secret",
        "grant_types" => ["authorization_code"],
        "redirect_uris" => ["https://app.example/callback"]
      })

    assert {:ok, decoded} = HostConfig.decode(config, "/tmp")
    transport = decoded.install["github"].transport
    assert transport.auth == []
    assert transport.oauth.client.client_secret_binding == "oauth_secret"

    assert {:error, :invalid_host_config} =
             config
             |> update_in(["credentials"], &Map.delete(&1, "oauth_secret"))
             |> HostConfig.decode("/tmp")
  end

  test "rejects tenant-local duplicate immutable installation IDs" do
    config = host_config()

    duplicate =
      config
      |> put_in(["install", "second"], config["install"]["github"])

    assert {:error, :invalid_host_config} = HostConfig.decode(duplicate, "/tmp")
  end

  test "generated schema exposes the closed OAuth registration profile" do
    encoded = Jason.encode!(HostConfig.schema())

    assert encoded =~ "client_id_metadata_document"
    assert encoded =~ "client_secret_basic"
    assert encoded =~ "scope_ceiling"
    refute encoded =~ "dynamic_client_registration"
  end

  test "generated schema rejects the same OAuth authentication and redirect conflicts as runtime" do
    root = JSV.build!(HostConfig.schema(), atoms: false, formats: false, warnings: :silent)

    invalid =
      [
        put_in(
          host_config(),
          ["install", "github", "transport", "auth"],
          [%{"scheme" => "bearer", "binding" => "token"}]
        ),
        update_in(
          host_config(),
          ["install", "github", "transport", "oauth", "client"],
          &Map.delete(&1, "loopback_redirect")
        ),
        put_in(
          host_config(),
          ["install", "github", "transport", "oauth", "client", "redirect_uris"],
          ["https://app.example/callback"]
        ),
        host_config()
        |> put_in(
          ["install", "github", "transport", "oauth", "client", "token_endpoint_auth_method"],
          "client_secret_basic"
        )
        |> put_in(
          ["install", "github", "transport", "oauth", "client", "redirect_uris"],
          ["https://app.example/callback"]
        )
        |> update_in(
          ["install", "github", "transport", "oauth", "client"],
          &Map.delete(&1, "loopback_redirect")
        )
      ]

    for config <- invalid do
      assert {:error, _errors} = JSV.validate(config, root, cast: false)
      assert {:error, :invalid_host_config} = HostConfig.decode(config, "/tmp")
    end

    assert {:ok, _validated} = JSV.validate(host_config(), root, cast: false)
  end

  test "registry/1 rejects OAuth while registry/2 claims explicit principal authority" do
    assert {:ok, decoded} = HostConfig.decode(host_config(), "/tmp")

    host =
      struct!(HostConfig,
        path: "/tmp/ptc-host.json",
        directory: "/tmp",
        runtime: decoded.runtime,
        limits: decoded.limits,
        credentials: decoded.credentials,
        install: decoded.install
      )

    assert {:error, :authorization_context_required} = HostInstallation.registry(host)

    {:ok, memory} = Memory.start_link(owner: self())
    {:ok, store} = Memory.store(memory)

    {:ok, context} =
      Context.new(tenant_id: "local", principal_id: "operator", store: store)

    assert {:ok, _registry} = HostInstallation.registry(host, context)
  end

  defp host_config do
    %{
      "credentials" => %{
        "token" => %{"literal" => "static-token"},
        "oauth_secret" => %{"literal" => "oauth-secret"}
      },
      "install" => %{
        "github" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://mcp.example/mcp",
            "oauth" => %{
              "installation_id" => "github-primary",
              "issuer" => "https://auth.example",
              "scope_ceiling" => ["repo:read"],
              "default_scopes" => ["repo:read"],
              "client" => %{
                "registration" => "pre_registered",
                "client_id" => "public-client",
                "token_endpoint_auth_method" => "none",
                "grant_types" => ["authorization_code"],
                "loopback_redirect" => %{
                  "host" => "127.0.0.1",
                  "path" => "/callback"
                }
              }
            }
          },
          "tools" => %{
            "get_file" => %{"as" => "github.get-file", "effect" => "read"}
          }
        }
      }
    }
  end
end
