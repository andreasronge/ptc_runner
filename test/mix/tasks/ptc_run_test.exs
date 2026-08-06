defmodule Mix.Tasks.Ptc.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Run
  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.ProviderSession
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
  test "renders shared closed diagnostics for host acquisition failures", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    missing_host = Path.join(dir, "missing-host.json")
    Mix.Task.reenable("ptc.run")

    error =
      assert_raise Mix.Error, fn ->
        Run.run([manifest_path, "--host-config", missing_host])
      end

    assert error.message ==
             "ptc.run failed: host/host_unavailable: " <>
               "the host configuration is unavailable"
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

  test "failure rendering ignores persistence result payloads and structural tags" do
    success =
      Run.failure_message(
        {:trace_persistence_failed, :write_failed, {:ok, %{value: "private-success-value"}}}
      )

    failure =
      Run.failure_message(
        {:result_persistence_failed, :write_failed,
         {:error, %{reason: :"private-failure-reason", value: "private-failure-value"}}}
      )

    assert success == "trace_persistence_failed/write_failed"
    assert failure == "result_persistence_failed/write_failed"
    refute success =~ "ok"
    refute success =~ "private-success-value"
    refute failure =~ "error"
    refute failure =~ "private-failure"
    assert Run.failure_message(%{private: "arbitrary-term"}) == "internal_error"
  end

  test "failure rendering retains established source classifications" do
    assert Run.failure_message({:source_role, :component_override, :invalid_override_descriptor}) ==
             "source_role/component_override/invalid_override_descriptor"

    assert Run.failure_message(
             {:source_role, :input_contract, "private-contract-path.json", :duplicate_json_key}
           ) == "source_role/input_contract/duplicate_json_key"
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
  test "--check reports a host-installed workflow LLM across repeated Mix invocations", %{
    tmp_dir: dir
  } do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    Application.put_env(:req_llm, :load_dotenv, true, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, true, persistent: true)
    {manifest_path, host_path} = write_llm_check_fixture(dir)

    output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--host-config", host_path, "--check"])
      end)

    assert output =~ "workflow  deepseek  llm  revision check-llm-v1"

    assert output =~ "snapshot "
    refute output =~ "openrouter:"
    refute output =~ "test-only-secret"
    assert Application.get_env(:req_llm, :load_dotenv) == false
    assert Application.get_env(:llm_db, :load_dotenv) == false
    assert :req_llm in started_applications()
    assert :llm_db in started_applications()

    repeated_output =
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run([manifest_path, "--host-config", host_path, "--check"])
      end)

    assert repeated_output =~ "workflow  deepseek  llm  revision check-llm-v1"
  end

  @tag :tmp_dir
  test "--check resolves a declared LLM credential from the nearest .env", %{tmp_dir: dir} do
    restore_provider_applications_on_exit()
    stop_provider_applications()

    credential_env = "PTC_RUN_DOTENV_CREDENTIAL"
    reset_dotenv_state(credential_env)
    File.write!(Path.join(dir, ".env"), "#{credential_env}=dotenv-secret\n")

    {manifest_path, host_path} =
      write_llm_check_fixture(dir, %{"env" => credential_env})

    output =
      File.cd!(dir, fn ->
        capture_io(fn ->
          Mix.Task.reenable("ptc.run")
          Run.run([manifest_path, "--host-config", host_path, "--check"])
        end)
      end)

    assert output =~ "workflow  deepseek  llm  revision check-llm-v1"
    refute output =~ "dotenv-secret"
  end

  @tag :tmp_dir
  test "one-shot and --check apply the same env-credential rule", %{tmp_dir: dir} do
    restore_provider_applications_on_exit()
    stop_provider_applications()

    credential_env = "PTC_RUN_DOTENV_SHARED_CREDENTIAL"
    reset_dotenv_state(credential_env)
    File.write!(Path.join(dir, ".env"), "#{credential_env}=dotenv-secret\n")
    {manifest_path, host_path} = write_llm_check_fixture(dir, %{"env" => credential_env})

    one_shot = run_in(dir, [manifest_path, "--host-config", host_path])

    assert System.get_env(credential_env) == "dotenv-secret"
    refute one_shot =~ "dotenv-secret"

    # Loading is latched per VM, so the check invocation must reload it rather
    # than inherit the one-shot's environment.
    clear_dotenv_state(credential_env)

    check = run_in(dir, [manifest_path, "--host-config", host_path, "--check"])

    assert System.get_env(credential_env) == "dotenv-secret"
    refute check =~ "dotenv-secret"
  end

  @tag :tmp_dir
  test "provider-free and literal-credential runs never read the nearest .env", %{tmp_dir: dir} do
    restore_provider_applications_on_exit()
    stop_provider_applications()

    credential_env = "PTC_RUN_DOTENV_UNUSED_CREDENTIAL"
    reset_dotenv_state(credential_env)
    File.write!(Path.join(dir, ".env"), "#{credential_env}=dotenv-secret\n")

    {literal_manifest, literal_host} = write_llm_check_fixture(dir)
    _literal = run_in(dir, [literal_manifest, "--host-config", literal_host])
    assert System.get_env(credential_env) == nil

    free_dir = Path.join(dir, "provider-free")
    File.mkdir_p!(free_dir)
    File.write!(Path.join(free_dir, "main.clj"), ~S|(ns main) (defn run [input] (return input))|)

    free_manifest = Path.join(free_dir, "ptc.json")

    File.write!(
      free_manifest,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "main", "path" => "main.clj"}],
          "entry" => "main/run"
        },
        "input" => %{"value" => %{}}
      })
    )

    _free = run_in(dir, [free_manifest])
    assert System.get_env(credential_env) == nil
  end

  @tag :tmp_dir
  test "a one-shot loads .env before the run clock starts", %{tmp_dir: dir} do
    restore_provider_applications_on_exit()
    stop_provider_applications()

    credential_env = "PTC_RUN_DOTENV_ORDER_CREDENTIAL"
    reset_dotenv_state(credential_env)
    File.write!(Path.join(dir, ".env"), "#{credential_env}=dotenv-secret\n")
    {manifest_path, host_path} = write_llm_check_fixture(dir, %{"env" => credential_env})

    trace_calls(
      [
        {{Dotenv, :load, 0}, [{:_, [], [{:return_trace}]}]},
        {{ProviderSession, :begin_run, 1}, true}
      ],
      fn -> run_in(dir, [manifest_path, "--host-config", host_path]) end
    )

    # Mailbox order across processes is not a happens-before proof, so the
    # assertion compares the VM's own monotonic trace timestamps, and it uses
    # the load's return rather than its call so a blocked loader cannot pass.
    assert_receive {:trace_ts, loader, :return_from, {Dotenv, :load, 0}, :ok, loaded_at}, 5_000

    assert_receive {:trace_ts, _worker, :call, {ProviderSession, :begin_run, [_session]},
                    run_clock_started_at},
                   5_000

    assert loader == self()
    assert loaded_at < run_clock_started_at
  end

  @tag :tmp_dir
  test "an unreadable .env fails the command without exposing its path", %{tmp_dir: dir} do
    restore_provider_applications_on_exit()
    stop_provider_applications()

    credential_env = "PTC_RUN_DOTENV_UNREADABLE_CREDENTIAL"
    reset_dotenv_state(credential_env)
    env_path = Path.join(dir, ".env")
    File.write!(env_path, "#{credential_env}=dotenv-secret\n")
    File.chmod!(env_path, 0o000)
    on_exit(fn -> File.chmod(env_path, 0o600) end)

    {manifest_path, host_path} = write_llm_check_fixture(dir, %{"env" => credential_env})

    # A privileged user can read the file anyway, which would make the failure
    # unreachable rather than the assertion wrong.
    if match?({:error, _reason}, File.read(env_path)) do
      for argv <- [
            [manifest_path, "--host-config", host_path],
            [manifest_path, "--host-config", host_path, "--check"]
          ] do
        error =
          assert_raise Mix.Error, fn ->
            run_in(dir, argv)
          end

        assert error.message == "ptc.run failed: dotenv_unavailable"
        refute error.message =~ dir
      end
    end
  end

  @tag :tmp_dir
  test "provider destination preflight completes before application admission", %{tmp_dir: dir} do
    restore_provider_applications_on_exit()
    stop_provider_applications()
    {manifest_path, host_path} = write_llm_check_fixture(dir)
    occupied = Path.join(dir, "occupied.json")
    File.write!(occupied, "occupied")

    Mix.Task.reenable("ptc.run")

    assert_raise Mix.Error, ~r/result_destination_exists/, fn ->
      Run.run([manifest_path, "--host-config", host_path, "--output", occupied])
    end

    refute :req_llm in started_applications()
    refute :llm_db in started_applications()
  end

  test "the core application does not infer optional provider applications" do
    applications = Application.spec(:ptc_runner, :applications)

    refute :req_llm in applications
    refute :llm_db in applications
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
          "installation_revision" => "unknown-provider-v1",
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

    error =
      assert_raise Mix.Error, fn ->
        Run.run([manifest_path, "--host-config", host_path, "--check"])
      end

    assert error.message ==
             "ptc.run failed: provider_declaration/provider_unknown: " <>
               "the selected provider is not installed"

    refute error.message =~ "CommandDiagnostic"
    refute error.message =~ "attestation"
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
          "installation_revision" => "stdio-check-v1",
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
          "installation_revision" => "trace-check-v1",
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
  test "provider-backed one-shot runs through the execution owner", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 42})
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
          "installation_revision" => "trace-run-v1",
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
        Run.run([manifest_path, "--host-config", host_path])
      end)

    assert %{"value" => 42} = Jason.decode!(output)
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
          "installation_revision" => "trace-check-v1",
          "directory" => "traces"
        },
        "private-history" => %{
          "source" => "ptc_inspection_snapshot",
          "installation_revision" => "inspection-check-v1",
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

  defp write_llm_check_fixture(
         dir,
         credential_declaration \\ %{"literal" => "test-only-secret"}
       ) do
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
      "credentials" => %{"openrouter_key" => credential_declaration},
      "install" => %{
        "deepseek" => %{
          "source" => "llm",
          "installation_revision" => "check-llm-v1",
          "model" => "openrouter:deepseek/deepseek-v4-flash",
          "credential" => "openrouter_key"
        },
        "unused-oauth" => %{
          "source" => "mcp",
          "installation_revision" => "check-workspace-v1",
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
          "tools" => %{"read" => %{"as" => "unused.read", "effect" => "read"}}
        }
      }
    }

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "host.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))
    {manifest_path, host_path}
  end

  defp started_applications,
    do: Application.started_applications() |> Enum.map(&elem(&1, 0))

  defp run_in(dir, argv) do
    File.cd!(dir, fn ->
      capture_io(fn ->
        Mix.Task.reenable("ptc.run")
        Run.run(argv)
      end)
    end)
  end

  defp reset_dotenv_state(credential_env) do
    previous_credential = System.get_env(credential_env)
    previous_state = :persistent_term.get(dotenv_key(), :missing)
    clear_dotenv_state(credential_env)

    on_exit(fn ->
      if previous_credential,
        do: System.put_env(credential_env, previous_credential),
        else: System.delete_env(credential_env)

      case previous_state do
        :missing -> :persistent_term.erase(dotenv_key())
        state -> :persistent_term.put(dotenv_key(), state)
      end
    end)
  end

  defp clear_dotenv_state(credential_env) do
    System.delete_env(credential_env)
    :persistent_term.erase(dotenv_key())
  end

  defp dotenv_key, do: {Dotenv, :dotenv_loaded}

  # Traces the named calls in this process and in every process the run spawns,
  # so an ordering assertion can span the frontend and the execution owner
  # without tracing unrelated work. A process receives no trace messages for
  # its own calls while it is its own tracer, so a forwarding tracer collects
  # them on the test process's behalf.
  defp trace_calls(functions, operation) do
    test = self()
    tracer = spawn_link(fn -> forward_traces(test) end)
    tracer_down = Process.monitor(tracer)

    # `:set_on_spawn` keeps the trace inside this invocation's process tree, so
    # an unrelated process cannot satisfy an ordering assertion.
    flags = [:call, :monotonic_timestamp, :set_on_spawn, {:tracer, tracer}]

    Enum.each(functions, fn {{module, function, arity}, match_spec} ->
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern({module, function, arity}, match_spec, [:local]) == 1
    end)

    :erlang.trace(self(), true, flags)

    try do
      operation.()
    after
      :erlang.trace(self(), false, [:call, :set_on_spawn])

      Enum.each(functions, fn {{module, function, arity}, _match_spec} ->
        :erlang.trace_pattern({module, function, arity}, false, [:local])
      end)

      # Trace signals from the spawned execution owner can still be in flight
      # when `operation.()` returns, so delivery is settled before the
      # forwarder is stopped. A test process exits normally, which a linked
      # process ignores, so it is stopped explicitly rather than left for the
      # suite to accumulate.
      delivered = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^delivered} -> :ok
      after
        5_000 -> flunk("trace delivery did not settle")
      end

      send(tracer, :stop)
      assert_receive {:DOWN, ^tracer_down, :process, ^tracer, :normal}, 5_000
    end
  end

  defp forward_traces(test) do
    receive do
      :stop ->
        :ok

      message ->
        send(test, message)
        forward_traces(test)
    end
  end

  defp stop_provider_applications do
    running = started_applications()

    if :req_llm in running, do: Application.stop(:req_llm)
    if :llm_db in running, do: Application.stop(:llm_db)
  end

  defp restore_provider_applications_on_exit do
    initially_running = MapSet.new(started_applications())

    on_exit(fn ->
      stop_provider_applications()
      Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
      Application.put_env(:llm_db, :load_dotenv, false, persistent: true)

      if MapSet.member?(initially_running, :llm_db),
        do: Application.ensure_all_started(:llm_db)

      if MapSet.member?(initially_running, :req_llm),
        do: Application.ensure_all_started(:req_llm)
    end)
  end
end
