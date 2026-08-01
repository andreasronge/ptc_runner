defmodule PtcRunner.Kernel.HostConfigOAuthTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority

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

  test "catalog construction retains private authority without requiring a principal or store" do
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

    assert {:ok, catalog} = HostInstallation.catalog(host)
    descriptor = catalog.descriptors["github"]

    assert descriptor.authorization_mode == :oauth
    assert descriptor.credential_names == []
    assert %Authority{} = catalog.authorities["github"]
    assert descriptor.authority_fingerprint == catalog.authorities["github"].fingerprint

    public =
      catalog |> InstallationCatalog.public_installations() |> List.first()

    assert public["installation_revision"] == "github-v1"
    refute Map.has_key?(public, "authority")
    refute inspect(public) =~ descriptor.authority_fingerprint
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
          "installation_revision" => "github-v1",
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
