defmodule PtcRunner.Kernel.HostConfigOAuthTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRegistry

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

  test "catalog construction retains only an OAuth runtime marker" do
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
    assert catalog.authorities["github"] == :host_runtime
    assert is_binary(descriptor.authority_fingerprint)

    encoded_catalog = :erlang.term_to_binary(catalog)
    refute encoded_catalog =~ "https://auth.example"
    refute encoded_catalog =~ "https://mcp.example/mcp"
    refute encoded_catalog =~ "public-client"
    refute encoded_catalog =~ "/callback"
    refute encoded_catalog =~ "oauth_secret"

    public =
      catalog |> InstallationCatalog.public_installations() |> List.first()

    assert public["installation_revision"] == "github-v1"
    refute Map.has_key?(public, "authority")
    refute inspect(public) =~ descriptor.authority_fingerprint
  end

  test "selected host registry exposes its already-claimed OAuth epoch" do
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
    assert {:ok, memory} = Memory.start(owner: self())
    assert {:ok, store} = Memory.store(memory)
    deadline = Deadline.new(1_000)

    assert {:ok, services} =
             HostInstallation.runtime_services(host,
               oauth_mode:
                 {:context_factory,
                  fn ^deadline ->
                    Context.new(
                      tenant_id: "tenant",
                      principal_id: "principal",
                      store: store,
                      deadline: deadline
                    )
                  end}
             )

    assert {:ok, registry} =
             InstallationCatalog.runtime_registry(catalog, services, ["github"], deadline, self())

    assert {:ok, authority_epoch} =
             ProviderRegistry.oauth_authority_epoch(registry, "github", deadline)

    authority = host.install["github"].transport.oauth
    installation_id = authority.installation_id

    assert {:ok, %{^installation_id => ^authority_epoch}} =
             Store.claim_authorities(
               store,
               "tenant",
               [{authority.installation_id, authority.fingerprint}],
               deadline
             )

    assert {:error, :authorization_context_required} =
             ProviderRegistry.oauth_authority_epoch(registry, "unselected", deadline)

    owner = registry.authority_owner.pid
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

    assert {:error, :authorization_context_required} =
             ProviderRegistry.oauth_authority_epoch(registry, "github", deadline)

    assert :ok = ProviderRegistry.close(registry)
    assert :ok = Memory.close(memory)
  end

  test "Mix OAuth deadlines resolve private authorities from the host, not catalog markers" do
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
    assert catalog.authorities["github"] == :host_runtime

    authority = host.install["github"].transport.oauth
    assert Authority.valid?(authority)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             ProviderExecution.authorization_result(
               {:error, {:authorization_timeout, "github"}},
               ["github"],
               catalog
             )

    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :authorization_unavailable
    assert diagnostic.subject.name == "github"
    assert diagnostic.subject.operation == :authorization
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
