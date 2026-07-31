defmodule Mix.Tasks.Ptc.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Run
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.TraceLog

  @root Path.expand("../../..", __DIR__)
  @stdio_fixture Path.expand("../../support/mcp_stdio_source_fixture.sh", __DIR__)

  @tag :tmp_dir
  test "runs the shared manifest path and accepts a confined mission override", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    File.write!(Path.join(dir, "override.json"), Jason.encode!(%{"value" => 42}))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"value" => 1}}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([path, "--mission", "override.json"])
      end)

    assert %{"value" => 42} = Jason.decode!(output)
  end

  @tag :tmp_dir
  test "rejects quoted-symbol results at the JSON command boundary", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [_] (return {"ref" 'foo "nested" ['bar] 'key "quoted-key"}))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))

    Mix.Task.reenable("ptc.run")

    assert_raise Mix.Error, ~r/invalid_result_projection/, fn ->
      capture_io(fn -> Run.run([path]) end)
    end
  end

  @tag :tmp_dir
  test "rejects native-only results before CLI JSON serialization", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [_] (return #{1 2}))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    Mix.Task.reenable("ptc.run")

    assert_raise Mix.Error, ~r/invalid_result_projection/, fn ->
      Run.run([path])
    end
  end

  @tag :tmp_dir
  test "--private-mission classifies the value before assembly and requires a private sink", %{
    tmp_dir: dir
  } do
    manifest_path = write_manifest(dir, %{"value" => 1})
    File.write!(Path.join(dir, "private.json"), Jason.encode!(%{"value" => "confidential"}))
    private_output = Path.join(dir, "answer.private.json")

    terminal =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")

        Run.run([
          manifest_path,
          "--private-mission",
          "private.json",
          "--private-output",
          private_output
        ])
      end)

    refute terminal =~ "confidential"
    assert %{"class" => "private"} = Jason.decode!(terminal)
    assert "confidential" == private_output |> File.read!() |> Jason.decode!()
  end

  @tag :tmp_dir
  test "rejects selecting ordinary and private mission inputs together", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    File.write!(Path.join(dir, "input.json"), "{}")

    Mix.Task.reenable("ptc.run")

    assert_raise Mix.Error, ~r/conflicting_mission_inputs/, fn ->
      Run.run([
        manifest_path,
        "--mission",
        "input.json",
        "--private-mission",
        "input.json"
      ])
    end
  end

  @tag :tmp_dir
  test "--check reports a host-installed workflow LLM without invoking it", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return input))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => [%{"name" => "deepseek"}]}
    }

    host = %{
      "credentials" => %{"openrouter_key" => %{"literal" => "test-only-secret"}},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "openrouter_key"
        },
        "unused-oauth" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://mcp.example/mcp",
            "oauth" => %{
              "installation_id" => "unused-oauth",
              "issuer" => "https://auth.example",
              "scope_ceiling" => ["read"],
              "default_scopes" => ["read"],
              "client" => %{
                "registration" => "pre_registered",
                "client_id" => "unused-client",
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
            "read" => %{"as" => "unused.read", "effect" => "read"}
          }
        }
      }
    }

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "host.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--host-config", host_path, "--check"])
      end)

    assert output =~
             "workflow  deepseek  llm  model openrouter:deepseek/deepseek-v4-flash"

    assert output =~ "snapshot "
    refute output =~ "test-only-secret"
  end

  @tag :tmp_dir
  test "--check assembles and closes without invoking the workflow", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (/ 1 0))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([path, "--check"])
      end)

    assert output == "check ok: no providers\n"
  end

  @tag :tmp_dir
  test "a provider-bearing manifest has no implicit registry fallback", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return input))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "llm", "config" => %{"model" => "deepseek"}}]
      }
    }

    host = %{
      "install" => %{
        "remote" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://example.test/mcp"
          },
          "tools" => %{"read" => %{"as" => "remote.read", "effect" => "read"}}
        }
      }
    }

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "host.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))

    Mix.Task.reenable("ptc.run")

    assert_raise Mix.Error, ~r/unknown_provider/, fn ->
      Run.run([manifest_path, "--host-config", host_path, "--check"])
    end
  end

  @tag :tmp_dir
  test "--check discovers and closes a host-installed stdio MCP server", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return input))|
    )

    marker = Path.join(dir, "methods")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "mission" => [
          %{
            "name" => "workspace",
            "config" => %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}
          }
        ]
      },
      "limits" => %{"evaluation_timeout_ms" => 5_000}
    }

    host = %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "transport" => %{
            "type" => "stdio",
            "command" => System.find_executable("sh"),
            "cwd" => @root,
            "args" => [@stdio_fixture, marker],
            "start_timeout_ms" => 5_000
          },
          "tools" => %{
            "structured" => %{
              "as" => "workspace.structured",
              "effect" => "write",
              "model_visible" => true
            }
          },
          "ceilings" => %{"timeout_ms" => 5_000}
        }
      }
    }

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "host.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--host-config", host_path, "--check"])
      end)

    assert output =~ "mission  workspace  mcp/stdio  1 tools"
    assert output =~ "1 tools  0 read  1 write"
    assert output =~ "snapshot "
    assert File.read!(marker) =~ "server/discover"
    assert File.read!(marker) =~ "tools/list"
  end

  @tag :tmp_dir
  test "--check captures a host-installed canonical trace snapshot", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    trace_directory = Path.join(dir, "traces")
    File.mkdir_p!(trace_directory)

    capture_io(fn ->
      Mix.Task.reenable("ptc.run")
      Run.run([manifest_path, "--trace", Path.join(trace_directory, "seed.jsonl")])
    end)

    manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("providers", %{"mission" => [%{"name" => "history"}]})

    File.write!(manifest_path, Jason.encode!(manifest))

    host = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "directory" => "traces",
          "ceilings" => %{"max_result_bytes" => 250_000}
        }
      }
    }

    host_path = Path.join(dir, "host.json")
    File.write!(host_path, Jason.encode!(host))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--host-config", host_path, "--check"])
      end)

    assert output =~ "mission  history  ptc_trace_snapshot  4 operations"
    assert output =~ "accepts: normal, private_inspection"
    assert output =~ "snapshot "
  end

  @tag :tmp_dir
  test "--check correlates a host-installed private inspection snapshot", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    trace_directory = Path.join(dir, "traces")
    inspection_directory = Path.join(dir, "inspection")
    File.mkdir_p!(trace_directory)
    File.mkdir_p!(inspection_directory)

    capture_io(fn ->
      Mix.Task.reenable("ptc.run")

      Run.run([
        manifest_path,
        "--trace",
        Path.join(trace_directory, "seed.jsonl"),
        "--inspect",
        Path.join(inspection_directory, "seed.inspection.jsonl")
      ])
    end)

    manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("providers", %{
        "mission" => [%{"name" => "private-history"}, %{"name" => "history"}]
      })

    File.write!(manifest_path, Jason.encode!(manifest))

    host = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "directory" => "traces"
        },
        "private-history" => %{
          "source" => "ptc_inspection_snapshot",
          "directory" => "inspection",
          "ceilings" => %{
            "max_files" => 100,
            "max_source_bytes" => 64_000_000,
            "max_result_bytes" => 500_000
          }
        }
      }
    }

    host_path = Path.join(dir, "host.json")
    File.write!(host_path, Jason.encode!(host))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--host-config", host_path, "--check"])
      end)

    assert output =~ "mission  history  ptc_trace_snapshot  4 operations"

    assert output =~
             "mission  private-history  ptc_inspection_snapshot  6 operations  " <>
               "data private_inspection"

    assert output =~ "accepts: normal, private_inspection"
    refute output =~ inspection_directory
  end

  @tag :tmp_dir
  test "rejects an occupied inspection destination before execution", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return 1))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))

    occupied = Path.join(dir, "run.inspection.jsonl")
    File.write!(occupied, "occupied")

    Mix.Task.reenable("ptc.run")

    assert_raise Mix.Error, ~r/inspection_preflight_failed/, fn ->
      Run.run([path, "--inspect", occupied])
    end

    assert File.read!(occupied) == "occupied"
  end

  @tag :tmp_dir
  test "persists canonical run events when --trace is selected", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"value" => 42}},
      "labels" => %{"name" => "traceable-run"}
    }

    manifest_path = Path.join(dir, "ptc.json")
    trace_path = Path.join(dir, "run.jsonl")
    File.write!(manifest_path, Jason.encode!(manifest))

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--trace", trace_path])
      end)

    assert %{"value" => 42} = Jason.decode!(output)
    assert {:ok, trace_log} = TraceLog.new(source: {:file, trace_path})

    assert {:ok, %{"items" => [%{"complete" => true, "name" => name}]}} =
             TraceLog.query(trace_log, :list_runs, %{})

    assert name == SafeMetadata.fingerprint("traceable-run")
  end

  @tag :tmp_dir
  test "rejects a private trace path before executing the run", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"secret" => "confidential"}, private?: true)
    trace_path = Path.join(dir, "wrong.jsonl")
    output_path = Path.join(dir, "result.private.json")

    Mix.Task.reenable("ptc.run")

    assert_raise Mix.Error, ~r/private_trace_requires_private_suffix/, fn ->
      Run.run([
        manifest_path,
        "--trace",
        trace_path,
        "--private-output",
        output_path
      ])
    end

    refute File.exists?(trace_path)
    refute File.exists?(output_path)
  end

  @tag :tmp_dir
  test "traces from separate runs remain a valid shared directory source", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{"value" => 7}}
    }

    manifest_path = Path.join(dir, "ptc.json")
    File.write!(manifest_path, Jason.encode!(manifest))

    for name <- ["first", "second"] do
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--trace", Path.join(dir, "#{name}.jsonl")])
      end)
    end

    assert {:ok, trace_log} = TraceLog.new(source: {:directory, dir})
    assert {:ok, %{"items" => items}} = TraceLog.query(trace_log, :list_runs, %{})

    run_ids = Enum.map(items, & &1["run_id"])
    assert length(items) == 2
    assert Enum.uniq(run_ids) == run_ids
  end

  describe "result artifacts" do
    # The point of the artifact is that a later run consumes it directly, so
    # assert the round trip rather than only the bytes on disk.
    @tag :tmp_dir
    test "writes a value a later run consumes without scraping stdout", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => 42})
      output = Path.join(dir, "candidate.json")
      schema_path = Path.join(dir, "candidate.schema.json")

      File.write!(
        Path.join(dir, "main.clj"),
        ~S|(ns main) (defn run [input] (return input))|
      )

      schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["value"],
        "properties" => %{"value" => %{"type" => "integer"}}
      }

      File.write!(schema_path, Jason.encode!(schema))

      manifest =
        manifest_path
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("contracts", %{
          "input_schema" => %{"path" => Path.basename(schema_path)},
          "result_schema" => %{"path" => Path.basename(schema_path)}
        })

      File.write!(manifest_path, Jason.encode!(manifest))

      terminal =
        capture_io(fn ->
          Mix.Task.reenable("ptc.run")
          Run.run([manifest_path, "--output", output])
        end)

      assert %{"value" => %{"value" => 42}} = Jason.decode!(terminal)
      assert %{"value" => 42} = output |> File.read!() |> Jason.decode!()

      # Feed the artifact straight back in as the next run's input.
      second =
        capture_io(fn ->
          Mix.Task.reenable("ptc.run")
          Run.run([manifest_path, "--mission", Path.basename(output)])
        end)

      assert %{"value" => %{"value" => 42}} = Jason.decode!(second)
    end

    @tag :tmp_dir
    test "refuses to clobber an occupied destination", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => 1})
      output = Path.join(dir, "answer.json")
      File.write!(output, "occupied")

      Mix.Task.reenable("ptc.run")

      assert_raise Mix.Error, ~r/result_destination_exists/, fn ->
        Run.run([manifest_path, "--output", output])
      end

      assert File.read!(output) == "occupied"
    end

    @tag :tmp_dir
    test "rejects selecting both destinations", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => 1})

      Mix.Task.reenable("ptc.run")

      assert_raise Mix.Error, ~r/conflicting_result_destinations/, fn ->
        Run.run([
          manifest_path,
          "--output",
          Path.join(dir, "a.json"),
          "--private-output",
          Path.join(dir, "b.json")
        ])
      end

      refute File.exists?(Path.join(dir, "a.json"))
      refute File.exists?(Path.join(dir, "b.json"))
    end

    @tag :tmp_dir
    test "restricts a private artifact to 0600 and keeps the value off stdout",
         %{tmp_dir: dir} do
      manifest_path =
        write_manifest(dir, %{"value" => %{"secret" => "confidential"}}, private?: true)

      output = Path.join(dir, "answer.private.json")

      terminal =
        capture_io(fn ->
          Mix.Task.reenable("ptc.run")
          Run.run([manifest_path, "--private-output", output])
        end)

      refute terminal =~ "confidential"
      assert %{"class" => "private"} = Jason.decode!(terminal)
      assert %{"secret" => "confidential"} = output |> File.read!() |> Jason.decode!()

      assert {:ok, %File.Stat{mode: mode}} = File.stat(output)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    @tag :tmp_dir
    test "refuses to publish a private value through --output", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => "confidential"}, private?: true)
      output = Path.join(dir, "answer.json")

      Mix.Task.reenable("ptc.run")

      error =
        assert_raise Mix.Error, ~r/private_result_requires_private_destination/, fn ->
          capture_io(fn -> Run.run([manifest_path, "--output", output]) end)
        end

      # The refusal must not itself publish what it refused to write.
      refute error.message =~ "confidential"
      refute File.exists?(output)
    end

    @tag :tmp_dir
    test "an occupied private destination does not disclose the value", %{tmp_dir: dir} do
      manifest_path =
        write_manifest(dir, %{"value" => %{"secret" => "confidential"}}, private?: true)

      output = Path.join(dir, "answer.private.json")
      File.write!(output, "occupied")

      Mix.Task.reenable("ptc.run")

      error =
        assert_raise Mix.Error, ~r/result_destination_exists/, fn ->
          capture_io(fn -> Run.run([manifest_path, "--private-output", output]) end)
        end

      refute error.message =~ "confidential"
    end

    @tag :tmp_dir
    test "a private run without a private destination keeps nothing", %{tmp_dir: dir} do
      manifest_path = write_manifest(dir, %{"value" => "confidential"}, private?: true)

      Mix.Task.reenable("ptc.run")

      assert_raise Mix.Error, ~r/requires --private-output/, fn ->
        capture_io(fn -> Run.run([manifest_path]) end)
      end
    end
  end

  defp write_manifest(dir, input, opts \\ []) do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => input}
    }

    manifest =
      if Keyword.get(opts, :private?, false),
        do: Map.put(manifest, "events", %{"policy" => "private"}),
        else: manifest

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end
end
