defmodule PtcRunner.Kernel.HostInstallationTest do
  use ExUnit.Case, async: false

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
  test "rejects an invalid LLM model during preflight before reading its credential", %{
    tmp_dir: dir
  } do
    config = %{
      "credentials" => %{
        "missing_key" => %{"env" => "DEFINITELY_MISSING_PTC_LLM_KEY"}
      },
      "install" => %{
        "invalid-model" => %{
          "source" => "llm",
          "model" => "definitely-not-a-model",
          "credential" => "missing_key"
        }
      }
    }

    host = load_host(dir, config)
    assert {:ok, registry} = HostInstallation.registry(host)

    assert {:error, :invalid_llm_model} =
             ProviderRegistry.build(
               registry,
               "invalid-model",
               %{},
               context(dir, :workflow)
             )
  end

  @tag :tmp_dir
  test "installs live LLM aliases only in workflow with explicit credential and safe identity", %{
    tmp_dir: dir
  } do
    previous_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    previous_owner = Application.get_env(:ptc_runner, :host_llm_test_owner)
    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
      restore_env(:host_llm_test_owner, previous_owner)
    end)

    config = %{
      "credentials" => %{"openrouter_key" => %{"literal" => "test-llm-secret"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "openrouter_key",
          "installation_revision" => "model-policy-v2",
          "accepts_data" => ["normal", "private_inspection"],
          "ceilings" => %{
            "max_request_bytes" => 200_000,
            "max_response_bytes" => 300_000
          }
        }
      }
    }

    host = load_host(dir, config)
    assert {:ok, registry} = HostInstallation.registry(host)
    workflow = context(dir, :workflow)

    assert {:ok, prepared} =
             ProviderRegistry.prepare(
               registry,
               "deepseek",
               %{"max_request_bytes" => 100_000},
               workflow
             )

    assert prepared.credential_names == ["openrouter_key"]

    assert {:error, :provider_destination_denied} =
             ProviderRegistry.prepare(registry, "deepseek", %{}, %{
               workflow
               | destination: :mission
             })

    assert {:error, :invalid_llm_selection} =
             ProviderRegistry.prepare(
               registry,
               "deepseek",
               %{"max_response_bytes" => 300_001},
               workflow
             )

    assert {:ok, preflighted} = ProviderRegistry.preflight(prepared)

    assert {:ok, credentials} =
             ProviderRegistry.resolve_credentials(registry, prepared.credential_names)

    assert credentials == %{"openrouter_key" => "test-llm-secret"}
    assert {:ok, built} = ProviderRegistry.acquire(preflighted, credentials)

    assert [%{name: "llm-request"} = capability] = built.capabilities
    assert built.accepts_data == [:normal, :private_inspection]
    assert built.data_class == :normal
    assert built.snapshot["provider"] == "deepseek"
    assert built.snapshot["source"] == "llm"
    assert built.snapshot["model"] == "openrouter:deepseek/deepseek-v4-flash"
    assert built.snapshot["cache"] == false
    assert built.snapshot["installation_revision"] == "model-policy-v2"
    assert built.snapshot["max_request_bytes"] == 100_000
    assert built.snapshot["max_response_bytes"] == 300_000
    assert built.snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(built.snapshot) =~ "test-llm-secret"

    assert {:ok, response} =
             capability.callback.(%{
               "messages" => [%{"role" => "user", "content" => "hello"}],
               "cache" => true
             })

    assert response["content"] == "ok"

    assert_receive {:host_llm_request, "openrouter:deepseek/deepseek-v4-flash", request}
    assert request.api_key == "test-llm-secret"
    assert request.cache == false
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

  defp restore_env(key, nil), do: Application.delete_env(:ptc_runner, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_runner, key, value)
end
