defmodule PtcRunner.Kernel.HostConfigTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.InstallationConfigDigest
  alias PtcRunner.Lisp.RetainedSize

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

    assert without_digest(host.install["workspace"]) == %{
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
                 inspection_capture: :full,
                 model_visible: false
               }
             },
             snapshot_identity: nil,
             installation_revision: "workspace-v1",
             ceilings: %{
               timeout_ms: 5_000,
               max_catalog_tools: 128,
               max_result_bytes: 1_000_000
             },
             data_class: :normal,
             accepts_data: [:normal]
           }

    assert InstallationConfigDigest.valid_digest?(
             host.install["workspace"].installation_config_digest
           )
  end

  @tag :tmp_dir
  test "loads one closed live LLM installation with an explicit credential", %{tmp_dir: dir} do
    config = %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"},
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "openrouter_key",
          "cache" => false,
          "params" => %{
            "temperature" => 0.2,
            "seed" => 42,
            "max_tokens" => 4_096,
            "top_p" => 0.85,
            "presence_penalty" => -0.25,
            "frequency_penalty" => 1.5,
            "reasoning_effort" => "medium"
          },
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

    assert without_digest(host.install["deepseek"]) == %{
             source: :llm,
             model: "openrouter:deepseek/deepseek-v4-flash-0731",
             credential: "openrouter_key",
             cache: false,
             params: %{
               temperature: 0.2,
               seed: 42,
               max_tokens: 4_096,
               top_p: 0.85,
               presence_penalty: -0.25,
               frequency_penalty: 1.5,
               reasoning_effort: :medium
             },
             structured_output_mode: :unsupported,
             usage_guarantees: %{tokens: true, cost_currency: "USD"},
             reservation_tariff: nil,
             installation_revision: "model-policy-v2",
             ceilings: %{
               max_request_bytes: 200_000,
               max_response_bytes: 300_000,
               max_calls: 2_048,
               request_timeout_ms: 120_000
             },
             data_class: :normal,
             accepts_data: [:normal, :private_inspection]
           }

    assert InstallationConfigDigest.valid_digest?(
             host.install["deepseek"].installation_config_digest
           )
  end

  @tag :tmp_dir
  test "loads an explicit live LLM max_calls ceiling", %{tmp_dir: dir} do
    config = %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "openrouter_key",
          "installation_revision" => "model-policy-v2",
          "ceilings" => %{"max_calls" => 4}
        }
      }
    }

    assert {:ok, host} = dir |> write_config(config) |> HostConfig.load()
    assert host.install["deepseek"].ceilings.max_calls == 4
  end

  @tag :tmp_dir
  test "refuses a max_calls ceiling that could never bind", %{tmp_dir: dir} do
    config = %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "openrouter_key",
          "installation_revision" => "model-policy-v2",
          "ceilings" => %{"max_calls" => 2_049}
        }
      }
    }

    assert {:error, :invalid_host_config} = dir |> write_config(config) |> HostConfig.load()
  end

  @tag :tmp_dir
  test "loads an explicit live LLM request_timeout_ms ceiling", %{tmp_dir: dir} do
    config = %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "openrouter_key",
          "installation_revision" => "model-policy-v2",
          "ceilings" => %{"request_timeout_ms" => 5_000}
        }
      }
    }

    assert {:ok, host} = dir |> write_config(config) |> HostConfig.load()
    assert host.install["deepseek"].ceilings.request_timeout_ms == 5_000
  end

  @tag :tmp_dir
  test "refuses a request_timeout_ms ceiling above the host LLM deadline", %{tmp_dir: dir} do
    config = %{
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "openrouter_key",
          "installation_revision" => "model-policy-v2",
          "ceilings" => %{"request_timeout_ms" => 120_001}
        }
      }
    }

    assert {:error, :invalid_host_config} = dir |> write_config(config) |> HostConfig.load()
  end

  @tag :tmp_dir
  test "omitted live LLM request_timeout_ms follows a narrowed host deadline", %{tmp_dir: dir} do
    config = %{
      "limits" => %{"llm_request_timeout_ms" => 5_000},
      "credentials" => %{"openrouter_key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "openrouter_key",
          "installation_revision" => "model-policy-v2"
        }
      }
    }

    assert {:ok, host} = dir |> write_config(config) |> HostConfig.load()
    assert host.limits.llm_request_timeout_ms == 5_000
    assert host.install["deepseek"].ceilings.request_timeout_ms == 5_000
  end

  test "command decoding rejects explicit nulls that semantic defaults would otherwise accept" do
    cases = [
      {
        put_in(valid_config(), ["$schema"], nil),
        [{:property, "$schema"}]
      },
      {
        put_in(valid_config(), ["runtime"], %{"stdio_launcher" => nil}),
        [{:property, "runtime"}, {:property, "stdio_launcher"}]
      },
      {
        put_in(valid_config(), ["install", "workspace", "installation_revision"], nil),
        [{:property, "install"}, {:property, "*"}, {:property, "installation_revision"}]
      },
      {
        # The installation alias is elided; the upstream tool name is not,
        # because `tools` admits a member that would render as the placeholder.
        put_in(
          valid_config(),
          ["install", "workspace", "tools", "read_text", "description"],
          nil
        ),
        [{:property, "install"}, {:property, "*"}, {:property, "tools"}]
      }
    ]

    for {config, expected_path} <- cases do
      assert {:error, :invalid_host_config} = HostConfig.decode(config, "/tmp")

      assert {:error,
              {:host_schema_invalid,
               %PtcRunner.Kernel.SchemaViolation{rule: :type, path: ^expected_path}}} =
               HostConfig.decode_command(config, "/tmp")
    end
  end

  test "command decoding reports a missing revision before generic schema failure for every source" do
    for {name, source} <- [
          {"mcp", "mcp"},
          {"llm", "llm"},
          {"replay", "llm_replay"},
          {"trace", "ptc_trace_snapshot"},
          {"private-trace", "ptc_private_trace_snapshot"},
          {"inspection", "ptc_inspection_snapshot"}
        ] do
      document = %{"install" => %{name => %{"source" => source}}}

      assert {:error, {:installation_revision_missing, ^name}} =
               HostConfig.decode_command(document, "/tmp")
    end
  end

  test "oneOf branch selection does not mistake nested enum failures for discriminators" do
    invalid =
      put_in(valid_config(), ["install", "workspace", "tools"], %{
        "first" => %{"as" => "workspace.first", "effect" => "execute"},
        "second" => %{"as" => "workspace.second", "effect" => "execute"}
      })

    assert {:error,
            {:host_schema_invalid,
             %PtcRunner.Kernel.SchemaViolation{
               rule: :enum,
               path: [
                 {:property, "install"},
                 {:property, "*"},
                 {:property, "tools"}
               ]
             }}} = HostConfig.decode_command(invalid, "/tmp")
  end

  test "oneOf branch selection does not mistake an immediate shared enum for a discriminator" do
    invalid = %{
      "install" => %{
        "replay" => %{
          "source" => "llm_replay",
          "installation_revision" => "replay-v1",
          "data_class" => "secret"
        }
      }
    }

    assert {:error,
            {:host_schema_invalid,
             %PtcRunner.Kernel.SchemaViolation{
               rule: :enum,
               path: [
                 {:property, "install"},
                 {:property, "*"},
                 {:property, "data_class"}
               ]
             }}} = HostConfig.decode_command(invalid, "/tmp")
  end

  @tag :tmp_dir
  test "loads the fixed private-authorized trace snapshot installation", %{tmp_dir: dir} do
    config = %{
      "install" => %{
        "private-history" => %{
          "source" => "ptc_private_trace_snapshot",
          "directory" => "traces",
          "installation_revision" => "private-history-v1"
        }
      }
    }

    assert {:ok, host} = dir |> write_config(config) |> HostConfig.load()
    installation = host.install["private-history"]
    assert installation.source == :ptc_private_trace_snapshot
    assert installation.directory == "traces"

    for forbidden <- ["data_class", "accepts_data", "private"] do
      invalid = put_in(config, ["install", "private-history", forbidden], true)
      assert {:error, :invalid_host_config} = HostConfig.decode(invalid, dir)
    end
  end

  test "an invalid installation alias is a schema error even when its revision is absent" do
    document = %{"install" => %{"BAD" => %{"source" => "mcp"}}}

    assert {:error, {:host_schema_invalid, _path}} =
             HostConfig.decode_command(document, "/tmp")
  end

  @tag :tmp_dir
  test "a limits-only host document admits an empty install map", %{tmp_dir: dir} do
    document = %{
      "install" => %{},
      "limits" => %{"workflow_heap_words" => 16_000_000}
    }

    assert {:ok, decoded} = HostConfig.decode(document, dir)
    assert decoded.install == %{}
    assert decoded.limits.workflow_heap_words == 16_000_000

    assert {:ok, command} = HostConfig.decode_command(document, dir)
    assert command.install == %{}
    assert command.limits.workflow_heap_words == 16_000_000

    assert {:ok, loaded} = dir |> write_config(document) |> HostConfig.load()
    assert loaded.install == %{}
    assert loaded.limits.workflow_heap_words == 16_000_000
  end

  test "installation revisions use the exact portable lowercase identifier grammar" do
    for invalid <- ["Upper", "1leading", "contains/slash", "", String.duplicate("a", 129)] do
      document =
        put_in(
          valid_config(),
          ["install", "workspace", "installation_revision"],
          invalid
        )

      assert {:error, :invalid_host_config} = HostConfig.decode(document, "/tmp")
      assert {:error, {:host_schema_invalid, _path}} = HostConfig.decode_command(document, "/tmp")
    end
  end

  @tag :tmp_dir
  test "loads one native canonical trace snapshot installation", %{tmp_dir: dir} do
    config = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "directory" => "traces",
          "installation_revision" => "history-v1",
          "ceilings" => %{
            "max_source_bytes" => 2_000_000,
            "max_result_bytes" => 250_000
          }
        }
      }
    }

    assert {:ok, host} = dir |> write_config(config) |> HostConfig.load()

    assert without_digest(host.install["history"]) == %{
             source: :ptc_trace_snapshot,
             directory: "traces",
             installation_revision: "history-v1",
             ceilings: %{
               max_source_bytes: 2_000_000,
               max_result_bytes: 250_000
             }
           }

    assert InstallationConfigDigest.valid_digest?(
             host.install["history"].installation_config_digest
           )
  end

  @tag :tmp_dir
  test "loads one private inspection snapshot installation", %{tmp_dir: dir} do
    config = %{
      "install" => %{
        "private-history" => %{
          "source" => "ptc_inspection_snapshot",
          "directory" => "inspection",
          "installation_revision" => "private-history-v1",
          "ceilings" => %{
            "max_files" => 100,
            "max_source_bytes" => 536_871_120,
            "max_result_bytes" => 500_000
          }
        }
      }
    }

    assert {:ok, host} = dir |> write_config(config) |> HostConfig.load()

    assert without_digest(host.install["private-history"]) == %{
             source: :ptc_inspection_snapshot,
             directory: "inspection",
             installation_revision: "private-history-v1",
             ceilings: %{
               max_files: 100,
               max_source_bytes: 536_871_120,
               max_result_bytes: 500_000
             }
           }

    assert InstallationConfigDigest.valid_digest?(
             host.install["private-history"].installation_config_digest
           )
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
  test "loads operator-declared write tools and rejects write snapshot identities", %{
    tmp_dir: dir
  } do
    write_config =
      valid_config()
      |> put_in(
        ["install", "workspace", "tools", "write_text"],
        %{"as" => "workspace.write", "effect" => "write", "model_visible" => true}
      )

    assert {:ok, host} = dir |> write_config(write_config) |> HostConfig.load()
    assert host.install["workspace"].tools["write_text"].effect == :write
    assert host.install["workspace"].tools["write_text"].model_visible

    invalid_identity =
      put_in(
        write_config,
        ["install", "workspace", "snapshot_identity"],
        %{"tool" => "write_text", "field" => "digest"}
      )

    assert {:error, :invalid_host_config} =
             dir |> write_config(invalid_identity, unique_name()) |> HostConfig.load()

    valid_identity =
      put_in(
        write_config,
        ["install", "workspace", "snapshot_identity"],
        %{"tool" => "read_text", "field" => "digest"}
      )

    assert {:ok, host} =
             dir |> write_config(valid_identity, unique_name()) |> HostConfig.load()

    assert host.install["workspace"].snapshot_identity == %{tool: "read_text", field: "digest"}
  end

  test "every enumerated value decodes to an atom this module owns" do
    # The assertions above check the decoded values but not where the atoms came
    # from. They previously came from `String.to_existing_atom/1`, which only
    # succeeds once some other module has interned the atom: `:bounded` and
    # `:closed` appear in MCPProtocol and MCPSource guards, `:bearer` and
    # `:basic` nowhere else at all. Decoding a valid host document therefore
    # raised ArgumentError rather than returning a result whenever HostConfig
    # ran first, and the tests above passed only because the surrounding suite
    # happened to load MCP first.
    #
    # Reading the compiled atom chunk is the one check that does not depend on
    # what else the VM has loaded: an atom in this list is a literal of this
    # module and exists as soon as the module does.
    {:ok, {_module, [atoms: atoms]}} =
      PtcRunner.Kernel.HostConfig |> :code.which() |> :beam_lib.chunks([:atoms])

    owned = MapSet.new(atoms, fn {_index, atom} -> atom end)

    for atom <- [:bearer, :basic, :closed, :bounded, :write, :normal, :private_inspection] do
      assert MapSet.member?(owned, atom),
             "#{inspect(atom)} must be a literal in HostConfig, not borrowed from another module"
    end
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
        ["install", "workspace", "transport", "env"],
        %{"LC_ALL" => %{"binding" => "server_token"}}
      ),
      put_in(
        valid_config(),
        ["install", "workspace", "transport", "shell"],
        true
      ),
      put_in(
        valid_config(),
        ["install", "workspace", "tools", "read_text", "effect"],
        "unknown"
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
          "installation_revision" => "remote-v1",
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

    write =
      put_in(
        http,
        ["install", "remote", "tools", "write"],
        %{"as" => "remote.write", "effect" => "write"}
      )

    assert {:ok, _validated} = JSV.validate(write, root, cast: false)
    assert {:ok, host} = HostConfig.decode(write, "/tmp")
    assert host.install["remote"].tools["write"].effect == :write

    llm = %{
      "credentials" => %{"key" => %{"env" => "OPENROUTER_API_KEY"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"},
          "installation_revision" => "deepseek-v1",
          "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
          "credential" => "key"
        }
      }
    }

    assert {:ok, _validated} = JSV.validate(llm, root, cast: false)
    assert {:ok, host} = HostConfig.decode(llm, "/tmp")
    assert host.install["deepseek"].source == :llm
    assert host.install["deepseek"].params == %{}
    assert host.install["deepseek"].structured_output_mode == :unsupported
    assert host.install["deepseek"].usage_guarantees == %{tokens: true, cost_currency: "USD"}

    missing_guarantees =
      update_in(llm, ["install", "deepseek"], &Map.delete(&1, "usage_guarantees"))

    assert {:error, :invalid_host_config} = HostConfig.decode(missing_guarantees, "/tmp")
    assert {:error, _details} = JSV.validate(missing_guarantees, root, cast: false)

    for invalid_guarantees <- [
          %{"tokens" => true},
          %{"cost_currency" => "USD"},
          %{"tokens" => 1, "cost_currency" => "USD"},
          %{"tokens" => true, "cost_currency" => "EUR"},
          %{"tokens" => true, "cost_currency" => nil, "extra" => true}
        ] do
      invalid = put_in(llm, ["install", "deepseek", "usage_guarantees"], invalid_guarantees)
      assert {:error, :invalid_host_config} = HostConfig.decode(invalid, "/tmp")
      assert {:error, _details} = JSV.validate(invalid, root, cast: false)
    end

    for invalid_params <- [
          %{"temperature" => 2.1},
          %{"seed" => -1},
          %{"max_tokens" => 0},
          %{"top_p" => 0},
          %{"top_p" => 1.1},
          %{"presence_penalty" => -2.1},
          %{"frequency_penalty" => 2.1},
          %{"reasoning_effort" => "xhigh"},
          %{"reasoning_effort" => nil}
        ] do
      invalid = put_in(llm, ["install", "deepseek", "params"], invalid_params)
      assert {:error, :invalid_host_config} = HostConfig.decode(invalid, "/tmp")
      assert {:error, _details} = JSV.validate(invalid, root, cast: false)
    end

    missing_mode =
      update_in(llm, ["install", "deepseek"], &Map.delete(&1, "structured_output_mode"))

    assert {:error, :invalid_host_config} = HostConfig.decode(missing_mode, "/tmp")
    assert {:error, _details} = JSV.validate(missing_mode, root, cast: false)

    for invalid_mode <- ["prompt_and_parse", "json", nil, true] do
      invalid = put_in(llm, ["install", "deepseek", "structured_output_mode"], invalid_mode)
      assert {:error, :invalid_host_config} = HostConfig.decode(invalid, "/tmp")
      assert {:error, _details} = JSV.validate(invalid, root, cast: false)
    end

    json_schema = put_in(llm, ["install", "deepseek", "structured_output_mode"], "json_schema")
    assert {:ok, schema_host} = HostConfig.decode(json_schema, "/tmp")
    assert schema_host.install["deepseek"].structured_output_mode == :json_schema

    trace = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "directory" => "traces",
          "installation_revision" => "history-v1"
        }
      }
    }

    assert {:ok, _validated} = JSV.validate(trace, root, cast: false)
    assert {:ok, host} = HostConfig.decode(trace, "/tmp")
    assert host.install["history"].source == :ptc_trace_snapshot

    too_small_trace =
      put_in(
        trace,
        ["install", "history", "ceilings"],
        %{"max_result_bytes" => HostConfig.minimum_snapshot_result_bytes() - 1}
      )

    assert {:error, :invalid_host_config} = HostConfig.decode(too_small_trace, "/tmp")
    assert {:error, _details} = JSV.validate(too_small_trace, root, cast: false)

    empty_page = %{
      "items" => [],
      "next_cursor" => nil,
      "omitted_count" => 0,
      "snapshot_hash" => "sha256:" <> String.duplicate("0", 64),
      "truncated" => false
    }

    expected_minimum = max(byte_size(Jason.encode!(empty_page)), RetainedSize.bytes(empty_page))

    assert HostConfig.minimum_snapshot_result_bytes() == expected_minimum

    inspection = %{
      "install" => %{
        "private-history" => %{
          "source" => "ptc_inspection_snapshot",
          "directory" => "inspection",
          "installation_revision" => "private-history-v1"
        }
      }
    }

    assert {:ok, _validated} = JSV.validate(inspection, root, cast: false)
    assert {:ok, host} = HostConfig.decode(inspection, "/tmp")
    assert host.install["private-history"].source == :ptc_inspection_snapshot

    too_small_inspection =
      put_in(
        inspection,
        ["install", "private-history", "ceilings"],
        %{"max_result_bytes" => HostConfig.minimum_snapshot_result_bytes() - 1}
      )

    assert {:error, :invalid_host_config} = HostConfig.decode(too_small_inspection, "/tmp")
    assert {:error, _details} = JSV.validate(too_small_inspection, root, cast: false)

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
    assert {:error, :host_invalid} = HostConfig.decode_command(dangling_llm, "/tmp")
  end

  test "stdio credential environment reserves the complete compatibility budget" do
    root = JSV.build!(HostConfig.schema(), atoms: false, formats: false, warnings: :silent)

    environment =
      Map.new(1..249, fn index ->
        {"PTC_VALUE_#{index}", %{"binding" => "server_token"}}
      end)

    at_limit = put_in(valid_config(), ["install", "workspace", "transport", "env"], environment)

    assert {:ok, _host} = HostConfig.decode(at_limit, "/tmp")
    assert {:ok, _validated} = JSV.validate(at_limit, root, cast: false)

    over_limit =
      put_in(
        at_limit,
        ["install", "workspace", "transport", "env", "PTC_VALUE_250"],
        %{"binding" => "server_token"}
      )

    assert {:error, :invalid_host_config} = HostConfig.decode(over_limit, "/tmp")
    assert {:error, _details} = JSV.validate(over_limit, root, cast: false)
  end

  test "an upstream tool name is the server's, so it is held to the MCP protocol rule" do
    # #1422: the host layer used to force upstream names to PtcRunner's
    # lowercase-dotted rule, which no operator controls. The shipped Go harness
    # advertises `cityTime`, so no host document could install it.
    {:ok, root} = JSV.build(HostConfig.schema(), atoms: false, warnings: :silent)

    camel =
      put_in(valid_config(), ["install", "workspace", "tools"], %{
        "cityTime" => %{"as" => "workspace.city_time", "effect" => "read"}
      })

    assert {:ok, decoded} = HostConfig.decode(camel, "/tmp")
    assert Map.has_key?(decoded.install["workspace"].tools, "cityTime")
    assert {:ok, _validated} = JSV.validate(camel, root, cast: false)

    # Only the public name crosses the capability boundary, so that one keeps
    # PtcRunner's naming rule.
    public =
      put_in(valid_config(), ["install", "workspace", "tools"], %{
        "cityTime" => %{"as" => "workspace.cityTime", "effect" => "read"}
      })

    assert {:error, :invalid_host_config} = HostConfig.decode(public, "/tmp")
    assert {:error, _details} = JSV.validate(public, root, cast: false)

    # An upstream name the protocol itself rejects is still refused.
    whitespace =
      put_in(valid_config(), ["install", "workspace", "tools"], %{
        "city Time" => %{"as" => "workspace.city_time", "effect" => "read"}
      })

    assert {:error, :invalid_host_config} = HostConfig.decode(whitespace, "/tmp")
    assert {:error, _details} = JSV.validate(whitespace, root, cast: false)
  end

  defp valid_config do
    %{
      "credentials" => %{"server_token" => %{"env" => "SERVER_TOKEN"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
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

  defp without_digest(installation), do: Map.delete(installation, :installation_config_digest)
end
