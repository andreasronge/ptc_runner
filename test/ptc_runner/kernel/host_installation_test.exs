defmodule PtcRunner.Kernel.HostInstallationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderRegistry

  @tag :tmp_dir
  test "installs only declared aliases and enforces MCP mission placement", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    assert {:ok, registry} = HostInstallation.registry(host)

    context = context(dir, :mission)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "remote", %{}, context)

    assert prepared.credential_names == ["token"]

    assert {:error, :provider_destination_denied} =
             ProviderRegistry.prepare(registry, "remote", %{}, %{context | destination: :workflow})

    assert {:error, :unknown_provider} =
             ProviderRegistry.prepare(registry, "llm", %{}, %{
               context
               | destination: :workflow
             })
  end

  @tag :tmp_dir
  test "preflight freezes local stdio paths before resolving credentials", %{tmp_dir: dir} do
    config =
      stdio_config(System.find_executable("sh"))
      |> put_in(["runtime", "stdio_launcher"], System.find_executable("sh"))

    host = load_host(dir, config)
    assert {:ok, registry} = HostInstallation.registry(host)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(registry, "workspace", %{}, context(dir, :mission))

    assert prepared.credential_names == ["token"]
    assert {:ok, %{acquire: acquire}} = ProviderRegistry.preflight(prepared)
    assert is_function(acquire, 1)

    assert {:ok, %{"token" => "test-secret"}} =
             ProviderRegistry.resolve_credentials(registry, ["token"])
  end

  @tag :tmp_dir
  test "selection can only narrow installed visibility and ceilings", %{tmp_dir: dir} do
    host = load_host(dir, http_config())
    assert {:ok, registry} = HostInstallation.registry(host)
    context = context(dir, :mission)

    assert {:ok, _prepared} =
             ProviderRegistry.prepare(
               registry,
               "remote",
               %{"allow" => ["remote.read"], "model_visible" => []},
               context
             )

    assert {:error, :invalid_mcp_selection} =
             ProviderRegistry.prepare(
               registry,
               "remote",
               %{"model_visible" => ["remote.hidden"]},
               context
             )

    assert {:error, :invalid_mcp_selection} =
             ProviderRegistry.prepare(
               registry,
               "remote",
               %{"timeout_ms" => 5_001},
               context
             )
  end

  @tag :tmp_dir
  test "normal mission data is rejected by an installation that only accepts private data", %{
    tmp_dir: dir
  } do
    config =
      http_config()
      |> put_in(["install", "remote", "accepts_data"], ["private_inspection"])

    host = load_host(dir, config)
    assert {:ok, registry} = HostInstallation.registry(host)

    assert {:error, :provider_data_class_denied} =
             ProviderRegistry.prepare(registry, "remote", %{}, context(dir, :mission))
  end

  defp context(directory, destination) do
    {:ok, limits} = Limits.new()

    %{
      directory: directory,
      destination: destination,
      owner: self(),
      limits: limits,
      installed_limits: limits
    }
  end

  defp http_config do
    %{
      "credentials" => %{"token" => %{"literal" => "test-secret"}},
      "install" => %{
        "remote" => %{
          "source" => "mcp",
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

  defp stdio_config(command) do
    %{
      "runtime" => %{},
      "credentials" => %{"token" => %{"literal" => "test-secret"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
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

  defp load_host(dir, body) do
    path = Path.join(dir, "host.json")
    File.write!(path, Jason.encode!(body))
    {:ok, host} = HostConfig.load(path)
    host
  end
end
