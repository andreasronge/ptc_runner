defmodule PtcRunner.Kernel.InstallationConfigDigestTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.CommandEngineFixtures

  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationConfigDigest
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @tag :tmp_dir
  test "widening an MCP root argument changes the installation digest and leaves application identity unchanged",
       %{tmp_dir: dir} do
    application =
      write_application(
        dir,
        "digest-root",
        valid_manifest(%{
          "providers" => %{
            "workflow" => [],
            "mission" => [%{"name" => "workspace", "config" => %{}}]
          }
        })
      )

    narrow = mcp_host(["--root", "apps/web"])
    wide = mcp_host(["--root", "apps"])

    narrow_digest = digest(narrow, "workspace")
    wide_digest = digest(wide, "workspace")

    assert InstallationConfigDigest.valid_digest?(narrow_digest)
    refute narrow_digest == wide_digest

    narrow_path = write_host_config(dir, "narrow", narrow)
    wide_path = write_host_config(dir, "wide", wide)

    assert {:ok, %CommandOutcome{} = narrow_outcome} =
             CommandEngine.prepare(["validate", application, "--host-config", narrow_path])

    assert {:ok, %CommandOutcome{} = wide_outcome} =
             CommandEngine.prepare(["validate", application, "--host-config", wide_path])

    assert narrow_outcome.envelope["result"]["provider_activity"] == false
    assert wide_outcome.envelope["result"]["provider_activity"] == false

    assert narrow_outcome.envelope["result"]["installation_config_digests"] == %{
             "workspace" => narrow_digest
           }

    assert wide_outcome.envelope["result"]["installation_config_digests"] == %{
             "workspace" => wide_digest
           }

    assert narrow_outcome.envelope["result"]["application_content_digest"] ==
             wide_outcome.envelope["result"]["application_content_digest"]

    assert narrow_outcome.envelope["result"]["effective_application_digest"] ==
             wide_outcome.envelope["result"]["effective_application_digest"]
  end

  test "authority-relevant declared fields change the digest and key order does not" do
    base = mcp_host(["server.js"])

    effect = put_in(base, ["install", "workspace", "tools", "read", "effect"], "write")
    ceiling = put_in(base, ["install", "workspace", "ceilings"], %{"timeout_ms" => 15_000})
    arg = put_in(base, ["install", "workspace", "transport", "args"], ["other.js"])

    assert digest(base, "workspace") != digest(effect, "workspace")
    assert digest(base, "workspace") != digest(ceiling, "workspace")
    assert digest(base, "workspace") != digest(arg, "workspace")

    refute digest(http_host("https://mcp.example.test/mcp"), "issues") ==
             digest(http_host("https://mcp.example.test/other"), "issues")

    refute digest(llm_host("openrouter:deepseek/deepseek-v4-flash-0731"), "deepseek") ==
             digest(llm_host("openrouter:deepseek/deepseek-v4-flash-other"), "deepseek")

    reordered = %{
      "install" => %{
        "workspace" => %{
          "tools" => %{"read" => %{"effect" => "read", "as" => "workspace.read"}},
          "transport" => %{"args" => ["server.js"], "command" => "node", "type" => "stdio"},
          "installation_revision" => "workspace-v1",
          "source" => "mcp"
        }
      }
    }

    assert digest(base, "workspace") == digest(reordered, "workspace")
  end

  test "set-valued declared fields hash independently of author order" do
    first =
      llm_host("openrouter:deepseek/deepseek-v4-flash-0731")
      |> put_in(["install", "deepseek", "accepts_data"], ["normal", "private_inspection"])

    reversed =
      put_in(first, ["install", "deepseek", "accepts_data"], ["private_inspection", "normal"])

    assert digest(first, "deepseek") == digest(reversed, "deepseek")

    left = oauth_host(["https://app.example/a", "https://app.example/b"])
    right = oauth_host(["https://app.example/b", "https://app.example/a"])
    assert digest(left, "github") == digest(right, "github")

    refute digest(mcp_host(["--root", "apps/web"]), "workspace") ==
             digest(mcp_host(["apps/web", "--root"]), "workspace")
  end

  test "omitted schema defaults match explicit defaults except for live LLM params" do
    omitted = mcp_host(["server.js"])

    explicit =
      omitted
      |> put_in(["install", "workspace", "transport", "cwd"], ".")
      |> put_in(["install", "workspace", "transport", "inherit_environment"], true)
      |> put_in(["install", "workspace", "transport", "grace_ms"], 250)
      |> put_in(["install", "workspace", "transport", "stderr_bytes"], 65_536)
      |> put_in(["install", "workspace", "transport", "start_timeout_ms"], 5_000)

    assert digest(omitted, "workspace") == digest(explicit, "workspace")

    llm = llm_host("openrouter:deepseek/deepseek-v4-flash-0731")
    with_zero = put_in(llm, ["install", "deepseek", "params"], %{"temperature" => 0.0})
    refute digest(llm, "deepseek") == digest(with_zero, "deepseek")
  end

  test "credential values are excluded while binding names and env keys remain" do
    binding = fn credential, env_key, env_name ->
      %{
        "credentials" => %{credential => %{"env" => env_name}},
        "install" => %{
          "workspace" => %{
            "source" => "mcp",
            "installation_revision" => "workspace-v1",
            "transport" => %{
              "type" => "stdio",
              "command" => "node",
              "env" => %{env_key => %{"binding" => credential}}
            },
            "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
          }
        }
      }
    end

    original = binding.("server_token", "SERVER_TOKEN", "SERVER_TOKEN")
    rotated = binding.("server_token", "SERVER_TOKEN", "SERVER_TOKEN_V2")
    renamed_binding = binding.("other_token", "SERVER_TOKEN", "SERVER_TOKEN")
    renamed_env = binding.("server_token", "OTHER_TOKEN", "SERVER_TOKEN")

    assert digest(original, "workspace") == digest(rotated, "workspace")
    refute digest(original, "workspace") == digest(renamed_binding, "workspace")
    refute digest(original, "workspace") == digest(renamed_env, "workspace")
  end

  @tag :tmp_dir
  test "declared paths stay as written across host directories and revision-only edits", %{
    tmp_dir: dir
  } do
    left = Path.join(dir, "left")
    right = Path.join(dir, "right")
    File.mkdir_p!(left)
    File.mkdir_p!(right)

    config = %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => "node",
            "cwd" => "servers",
            "args" => ["server.js"]
          },
          "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
        }
      }
    }

    {:ok, left_host} = left |> write_host_config("host", config) |> HostConfig.load()
    {:ok, right_host} = right |> write_host_config("host", config) |> HostConfig.load()

    assert left_host.install["workspace"].installation_config_digest ==
             right_host.install["workspace"].installation_config_digest

    refute left_host.install["workspace"].installation_config_digest =~ left
    refute left_host.install["workspace"].installation_config_digest =~ right

    revised = put_in(config, ["install", "workspace", "installation_revision"], "workspace-v2")
    assert digest(config, "workspace") == digest(revised, "workspace")
  end

  @tag :tmp_dir
  test "validate publishes only selected aliases and every host-backed source hashes", %{
    tmp_dir: dir
  } do
    application =
      write_application(
        dir,
        "digest-selected",
        valid_manifest(%{
          "providers" => %{
            "workflow" => [%{"name" => "deepseek", "config" => %{}}],
            "mission" => [%{"name" => "workspace", "config" => %{}}]
          }
        })
      )

    host = %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "workspace" => mcp_host(["server.js"])["install"]["workspace"],
        "extra" =>
          mcp_host(["other.js"])["install"]["workspace"]
          |> Map.put("installation_revision", "extra-v1"),
        "deepseek" =>
          llm_host("openrouter:deepseek/deepseek-v4-flash-0731")["install"]["deepseek"],
        "replay" => %{
          "source" => "llm_replay",
          "installation_revision" => "replay-v1",
          "fixtures" => "replay.jsonl"
        },
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "directory" => "traces",
          "installation_revision" => "history-v1"
        },
        "private-history" => %{
          "source" => "ptc_private_trace_snapshot",
          "directory" => "private-traces",
          "installation_revision" => "private-history-v1"
        },
        "inspection" => %{
          "source" => "ptc_inspection_snapshot",
          "directory" => "inspection",
          "installation_revision" => "inspection-v1"
        }
      }
    }

    {:ok, decoded} = HostConfig.decode(host, dir)

    for name <- [
          "workspace",
          "extra",
          "deepseek",
          "replay",
          "history",
          "private-history",
          "inspection"
        ] do
      assert InstallationConfigDigest.valid_digest?(
               decoded.install[name].installation_config_digest
             )
    end

    path = write_host_config(dir, "selected", host)

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["validate", application, "--host-config", path])

    assert outcome.envelope["result"]["provider_activity"] == false

    assert outcome.envelope["result"]["installation_config_digests"] |> Map.keys() |> Enum.sort() ==
             ["deepseek", "workspace"]

    assert outcome.envelope["result"]["installation_config_digests"]["workspace"] ==
             decoded.install["workspace"].installation_config_digest

    assert outcome.envelope["result"]["installation_config_digests"]["deepseek"] ==
             decoded.install["deepseek"].installation_config_digest

    {:ok, loaded} = HostConfig.load(path)
    assert {:ok, catalog} = HostInstallation.catalog(loaded)

    assert catalog.installation_config_digests["workspace"] ==
             loaded.install["workspace"].installation_config_digest
  end

  test "run-started metadata publishes selected host-backed installation digests from connector snapshots" do
    digest = "sha256:" <> String.duplicate("ab", 32)

    snapshots = [
      %{
        "provider" => "workspace",
        "snapshot_hash" => String.duplicate("1", 64),
        "installation_config_digest" => digest
      },
      %{
        "provider" => "custom",
        "snapshot_hash" => String.duplicate("2", 64)
      }
    ]

    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits)

    assert {:ok, config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: sink,
               connector_snapshots: snapshots
             )

    assert config.run_started_metadata.installation_config_digests == %{"workspace" => digest}

    EventSink.stop(sink)
  end

  defp digest(config, name) do
    assert {:ok, decoded} = HostConfig.decode(config, "/tmp")
    decoded.install[name].installation_config_digest
  end

  defp mcp_host(args) do
    %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => "node",
            "args" => args
          },
          "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
        }
      }
    }
  end

  defp http_host(endpoint) do
    %{
      "credentials" => %{"issues_token" => %{"env" => "ISSUES_TOKEN"}},
      "install" => %{
        "issues" => %{
          "source" => "mcp",
          "installation_revision" => "issues-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => endpoint,
            "auth" => [%{"scheme" => "bearer", "binding" => "issues_token"}]
          },
          "tools" => %{"search" => %{"as" => "issues.search", "effect" => "read"}}
        }
      }
    }
  end

  defp oauth_host(redirect_uris) do
    %{
      "credentials" => %{
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
              "client" => %{
                "registration" => "pre_registered",
                "client_id" => "public-client",
                "token_endpoint_auth_method" => "none",
                "grant_types" => ["authorization_code"],
                "redirect_uris" => redirect_uris
              }
            }
          },
          "tools" => %{"get_file" => %{"as" => "github.get-file", "effect" => "read"}}
        }
      }
    }
  end

  defp llm_host(model) do
    %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "installation_revision" => "model-policy-v2",
          "model" => model,
          "credential" => "openrouter_key"
        }
      }
    }
  end
end
