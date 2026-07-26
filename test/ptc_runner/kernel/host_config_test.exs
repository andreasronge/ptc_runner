defmodule PtcRunner.Kernel.HostConfigTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig

  @tag :tmp_dir
  test "loads one closed stdio MCP installation without resolving credentials", %{tmp_dir: dir} do
    config =
      valid_config()
      |> put_in(["credentials", "server_token"], %{"env" => "DEFINITELY_MISSING_PTC_TOKEN"})
      |> put_in(
        ["install", "workspace", "transport", "env"],
        %{"SERVER_TOKEN" => %{"binding" => "server_token"}}
      )

    path = write_config(dir, config)

    assert {:ok, host} = HostConfig.load(path)
    assert host.path == Path.join(dir, "host.json")
    assert host.directory == dir
    assert host.runtime == %{stdio_launcher: nil}

    assert host.credentials["server_token"] == %{
             source: :env,
             name: "DEFINITELY_MISSING_PTC_TOKEN"
           }

    assert host.install["workspace"] == %{
             source: :mcp,
             transport: %{
               type: :stdio,
               command: "node",
               cwd: ".",
               args: ["server.js"],
               env: %{"SERVER_TOKEN" => "server_token"},
               inherit_environment: true,
               grace_ms: 250,
               stderr_bytes: 65_536,
               start_timeout_ms: 5_000
             },
             tools: %{
               "read_text" => %{
                 as: "workspace.read",
                 effect: :read,
                 description: nil,
                 error_feedback: :closed,
                 model_visible: false
               }
             },
             snapshot_identity: nil,
             installation_revision: nil,
             ceilings: %{
               timeout_ms: 5_000,
               max_catalog_tools: 128,
               max_result_bytes: 1_000_000
             },
             data_class: :normal,
             accepts_data: [:normal]
           }
  end

  @tag :tmp_dir
  test "loads one closed live LLM installation with an explicit credential", %{tmp_dir: dir} do
    config = %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "openrouter_key",
          "cache" => false,
          "installation_revision" => "model-policy-v2",
          "accepts_data" => ["normal", "private_inspection"],
          "ceilings" => %{
            "max_request_bytes" => 200_000,
            "max_response_bytes" => 300_000
          }
        }
      }
    }

    assert {:ok, host} = dir |> write_config(config) |> HostConfig.load()

    assert host.install["deepseek"] == %{
             source: :llm,
             model: "openrouter:deepseek/deepseek-v4-flash",
             credential: "openrouter_key",
             cache: false,
             installation_revision: "model-policy-v2",
             ceilings: %{max_request_bytes: 200_000, max_response_bytes: 300_000},
             data_class: :normal,
             accepts_data: [:normal, :private_inspection]
           }
  end

  @tag :tmp_dir
  test "loads closed HTTP authentication and safe installation metadata", %{tmp_dir: dir} do
    config = %{
      "$schema" => "./ptc-host-config.schema.json",
      "runtime" => %{"stdio_launcher" => "/opt/ptc/launcher"},
      "credentials" => %{"issues_token" => %{"file" => "secrets/issues-token"}},
      "install" => %{
        "issues" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://mcp.example.test/mcp",
            "auth" => [%{"scheme" => "bearer", "binding" => "issues_token"}]
          },
          "tools" => %{
            "search_issues" => %{
              "as" => "issues.search",
              "effect" => "read",
              "description" => "Search approved issue metadata.",
              "error_feedback" => "bounded",
              "model_visible" => true
            }
          },
          "installation_revision" => "deployment-3",
          "data_class" => "private_inspection",
          "accepts_data" => ["normal", "private_inspection"],
          "ceilings" => %{
            "timeout_ms" => 12_000,
            "max_catalog_tools" => 16,
            "max_result_bytes" => 250_000
          }
        }
      }
    }

    assert {:ok, host} = dir |> write_config(config) |> HostConfig.load()
    assert host.runtime.stdio_launcher == "/opt/ptc/launcher"
    assert host.credentials["issues_token"] == %{source: :file, path: "secrets/issues-token"}

    installation = host.install["issues"]
    assert installation.transport.type == :streamable_http
    assert installation.transport.auth == [%{scheme: :bearer, binding: "issues_token"}]
    assert installation.installation_revision == "deployment-3"
    assert installation.data_class == :private_inspection
    assert installation.accepts_data == [:normal, :private_inspection]
    assert installation.tools["search_issues"].model_visible
    assert installation.tools["search_issues"].error_feedback == :bounded
  end

  @tag :tmp_dir
  test "rejects duplicate keys, unknown sources, dangling bindings, and authority-bearing extras",
       %{
         tmp_dir: dir
       } do
    duplicate =
      ~s|{"install":{"workspace":{"source":"mcp","source":"mcp","transport":{"type":"stdio","command":"node"},"tools":{"read":{"as":"workspace.read","effect":"read"}}}}}|

    File.write!(Path.join(dir, "duplicate.json"), duplicate)

    assert {:error, :duplicate_host_config_key} =
             HostConfig.load(Path.join(dir, "duplicate.json"))

    invalid = [
      put_in(valid_config(), ["install", "workspace", "source"], "file-read"),
      put_in(
        valid_config(),
        ["install", "workspace", "transport", "env"],
        %{"TOKEN" => %{"binding" => "missing"}}
      ),
      put_in(
        valid_config(),
        ["install", "workspace", "transport", "env"],
        %{"PATH" => %{"binding" => "server_token"}}
      ),
      put_in(
        valid_config(),
        ["install", "workspace", "transport", "shell"],
        true
      ),
      put_in(
        valid_config(),
        ["install", "workspace", "tools", "read_text", "effect"],
        "write"
      )
    ]

    for config <- invalid do
      assert {:error, :invalid_host_config} =
               dir |> write_config(config, unique_name()) |> HostConfig.load()
    end
  end

  test "generated schema accepts the same structural examples and rejects closed-shape errors" do
    root = JSV.build!(HostConfig.schema(), atoms: false, formats: false, warnings: :silent)

    assert {:ok, _validated} = JSV.validate(valid_config(), root, cast: false)

    http = %{
      "credentials" => %{"token" => %{"literal" => "test-only"}},
      "install" => %{
        "remote" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://example.test/mcp",
            "auth" => [%{"scheme" => "api_key", "binding" => "token", "header" => "X-Key"}]
          },
          "tools" => %{
            "read" => %{"as" => "remote.read", "effect" => "read"}
          }
        }
      }
    }

    assert {:ok, _validated} = JSV.validate(http, root, cast: false)

    llm = %{
      "credentials" => %{"key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "key"
        }
      }
    }

    assert {:ok, _validated} = JSV.validate(llm, root, cast: false)
    assert {:ok, host} = HostConfig.decode(llm, "/tmp")
    assert host.install["deepseek"].source == :llm

    refute match?(
             {:ok, _validated},
             valid_config()
             |> put_in(["install", "workspace", "transport", "shell"], true)
             |> JSV.validate(root, cast: false)
           )

    refute match?(
             {:ok, _validated},
             valid_config()
             |> put_in(["install", "workspace", "source"], "file-read")
             |> JSV.validate(root, cast: false)
           )

    dangling_llm = put_in(llm, ["install", "deepseek", "credential"], "missing")

    assert {:ok, _validated} = JSV.validate(dangling_llm, root, cast: false)
    assert {:error, :invalid_host_config} = HostConfig.decode(dangling_llm, "/tmp")
  end

  defp valid_config do
    %{
      "credentials" => %{"server_token" => %{"env" => "SERVER_TOKEN"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "stdio",
            "command" => "node",
            "args" => ["server.js"]
          },
          "tools" => %{
            "read_text" => %{"as" => "workspace.read", "effect" => "read"}
          }
        }
      }
    }
  end

  defp write_config(dir, config, name \\ "host.json") do
    path = Path.join(dir, name)
    File.write!(path, Jason.encode!(config))
    path
  end

  defp unique_name,
    do: "host-#{System.unique_integer([:positive, :monotonic])}.json"
end
