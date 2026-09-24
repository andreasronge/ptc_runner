defmodule PtcRunner.TestSupport.HostInstallationFixtures do
  @moduledoc false

  # Shared by HostInstallationTest (async) and HostInstallationGlobalStateTest.

  import ExUnit.Assertions

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.SelectionRules

  def context(_directory, destination) do
    {:ok, limits} = Limits.new()

    %{
      application_content_digest: String.duplicate("0", 64),
      destination: destination,
      owner: self(),
      limits: limits,
      installed_limits: limits
    }
  end

  def http_config do
    %{
      "credentials" => %{"token" => %{"literal" => "test-secret"}},
      "install" => %{
        "remote" => %{
          "source" => "mcp",
          "installation_revision" => "remote-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://example.test/mcp",
            "auth" => [%{"scheme" => "bearer", "binding" => "token"}]
          },
          "tools" => %{
            "read" => %{
              "as" => "remote.read",
              "effect" => "read",
              "model_visible" => true
            },
            "hidden" => %{
              "as" => "remote.hidden",
              "effect" => "read"
            }
          },
          "ceilings" => %{"timeout_ms" => 5_000}
        }
      }
    }
  end

  def stdio_config(command) do
    %{
      "runtime" => %{},
      "credentials" => %{"token" => %{"literal" => "test-secret"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "stdio-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => command,
            "cwd" => ".",
            "inherit_environment" => false,
            "env" => %{"TOKEN" => %{"binding" => "token"}}
          },
          "tools" => %{
            "read" => %{"as" => "workspace.read", "effect" => "read"}
          }
        }
      }
    }
  end

  def load_host(dir, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "host.json")
    File.write!(path, Jason.encode!(body))
    {:ok, host} = HostConfig.load(path)
    host
  end

  def replace_credential_resolver(services, resolver),
    do: reseal_services(%{services | credential_resolver: resolver})

  def replace_activation(services, activation),
    do: reseal_services(%{services | activation: activation})

  defp reseal_services(services) do
    payload =
      {services.activation, services.credential_resolver, services.provider_application_mode,
       services.oauth_mode, services.provider_call_admission, services.runtime_binding,
       services.host_payload}

    %{services | attestation: Attestation.attest(ProviderRuntimeServices, payload)}
  end

  def assert_local_preflight_parity(host, name, destination, expected) do
    assert {:ok, catalog} = HostInstallation.catalog(host)
    descriptor = Map.fetch!(catalog.descriptors, name)
    implementation = Map.fetch!(catalog.implementations, name)
    provider_context = context(host.directory, destination)
    assert {:ok, runtime_services} = HostInstallation.runtime_services(host)

    # An audited-local declaration cannot be sealed into an unbound catalog, so
    # a host recipe that stopped binding its catalog would fail construction
    # rather than quietly install a check phase 7 refuses to run.
    assert is_binary(catalog.runtime_binding)
    assert descriptor.local_preflight == :audited_local
    assert is_function(implementation.local_preflight, 3)

    assert {:ok, selection} =
             SelectionRules.normalize(descriptor.selection_rules, %{}, provider_context.limits)

    assert ^expected =
             implementation.local_preflight.(selection, provider_context, runtime_services)

    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
    assert {:ok, prepared} = ProviderRegistry.prepare(registry, name, selection, provider_context)
    assert ^expected = ProviderRegistry.preflight(prepared)
    assert :ok = ProviderRegistry.close(registry)
  end
end
