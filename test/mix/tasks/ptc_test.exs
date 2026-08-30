defmodule Mix.Tasks.PtcTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.MixCommandAdapter
  alias PtcRunner.MixCommandRuntime
  alias PtcRunner.StandaloneCommandRuntime

  @root Path.expand("../../..", __DIR__)

  test "only the root project bootstrap skips dependency checks" do
    assert MixCommandRuntime.app_config_args(PtcRunner.MixProject) == ["--no-deps-check"]
    assert MixCommandRuntime.app_config_args(Downstream.MixProject) == []
    assert MixCommandRuntime.app_config_args(nil) == []
  end

  @tag :tmp_dir
  test "version reports the embedded source identity in human and machine forms", %{tmp_dir: dir} do
    identity = PtcRunner.BuildIdentity.current()
    %{version: version, source_revision: revision, source_dirty: dirty} = identity
    envelope_path = Path.join(dir, "version.json")

    assert run_output(["--version"]) ==
             "#{version} (#{String.slice(revision, 0, 8)}, " <>
               "#{if(dirty, do: "dirty", else: "clean")})\n"

    assert run_output(["version", "--envelope", envelope_path]) ==
             "#{version} (#{String.slice(revision, 0, 8)}, " <>
               "#{if(dirty, do: "dirty", else: "clean")})\n"

    assert %{
             "command" => "version",
             "result" => %{
               "version" => ^version,
               "source_revision" => ^revision,
               "source_dirty" => ^dirty
             }
           } = envelope_path |> File.read!() |> Jason.decode!()
  end

  test "version identity is not replaced by runtime application configuration" do
    identity = PtcRunner.BuildIdentity.current()
    previous = Application.get_env(:ptc_runner, :source_revision, :missing)

    on_exit(fn ->
      if previous == :missing,
        do: Application.delete_env(:ptc_runner, :source_revision),
        else: Application.put_env(:ptc_runner, :source_revision, previous)
    end)

    Application.put_env(:ptc_runner, :source_revision, String.duplicate("0", 40))

    assert PtcRunner.BuildIdentity.current() == identity
  end

  @tag :tmp_dir
  test "root command validates dependencies until the application has been built", %{
    tmp_dir: directory
  } do
    app_path = Path.join(directory, "ptc_runner")
    app_file = Path.join([app_path, "ebin", "ptc_runner.app"])

    assert PtcRunner.MixProject.ptc_prepare_args(app_path) == []

    File.mkdir_p!(Path.dirname(app_file))
    assert PtcRunner.MixProject.ptc_prepare_args(app_path) == []

    File.write!(app_file, "built")
    assert PtcRunner.MixProject.ptc_prepare_args(app_path) == ["--no-deps-check"]
  end

  # Seed everything except one dependency so this exercises the real alias
  # without rebuilding the entire dependency tree. The old unconditional
  # --no-deps-check path leaves the omitted dependency uncompiled. A warm
  # run is still a real Mix compile into a throwaway `_build` (~4.5 s), so
  # this lives on `mix nightly` with the other Mix-subprocess cases.
  @tag :nightly
  test "a cold root command compiles dependencies before running" do
    build_path =
      Path.join(@root, "_build/ptc-cold-start-#{System.unique_integer([:positive, :monotonic])}")

    on_exit(fn -> File.rm_rf!(build_path) end)
    seed_incomplete_build(build_path)

    {output, status} =
      System.cmd(System.find_executable("mix"), ["ptc", "--version"],
        cd: @root,
        env: [
          {"MIX_BUILD_PATH", build_path},
          {"MIX_ENV", "test"},
          {"MIX_QUIET", "1"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ Mix.Project.config()[:version]

    assert File.regular?(
             Path.join([build_path, "lib", "nimble_parsec", "ebin", "nimble_parsec.app"])
           )

    assert File.regular?(Path.join([build_path, "lib", "ptc_runner", "ebin", "ptc_runner.app"]))
  end

  @tag :tmp_dir
  test "renders a normal run value as deterministic compact JSON", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    input_path = Path.join(dir, "input.json")
    File.write!(input_path, Jason.encode!(%{"value" => 42}))

    assert run_output(["run", manifest_path, "--input", Path.basename(input_path)]) == "42\n"
  end

  @tag :tmp_dir
  test "publishes the closed envelope only when its destination is named", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    {rendering, envelope} = run_envelope(dir, ["run", manifest_path])

    assert rendering == "1\n"

    assert %{
             "schema_version" => 4,
             "command" => "run",
             "status" => "ok",
             "warnings" => [],
             "result" => %{"result_class" => "normal", "value" => 1},
             "execution" => %{"state" => "finished", "outcome" => "ok"}
           } = envelope
  end

  @tag :tmp_dir
  test "renders a shared command failure without exposing its path", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    missing_host = Path.join(dir, "missing-host.json")

    message = failed_message(["run", manifest_path, "--host-config", missing_host])

    assert message =~ "error: host/host_unavailable:"
    assert message =~ "(run_ref: cmd-"
    refute message =~ dir
    refute message =~ "schema_version"
  end

  @tag :tmp_dir
  test "root command names a missing manifest property", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})

    invalid_manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> update_in(["workflow"], &Map.delete(&1, "entry"))

    File.write!(manifest_path, Jason.encode!(invalid_manifest))

    message = failed_message(["validate", manifest_path])

    assert message =~
             "application/required_property_missing: " <>
               "the application manifest is missing a required property at /workflow/entry"
  end

  @tag :tmp_dir
  test "root validate renders optional-budget host and manifest remedies", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    host_path = Path.join(dir, "ptc-host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "limits" => %{"llm_cost_microusd" => 1_000},
        "credentials" => %{"key" => %{"env" => "PTC_TEST_ABSENT_KEY"}},
        "install" => %{
          "private-model-alias" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"},
            "installation_revision" => "model-v1",
            "model" => "provider:private-model",
            "credential" => "key"
          }
        }
      })
    )

    host_message = failed_message(["validate", manifest_path, "--host-config", host_path])

    assert host_message =~
             "host/installed_limit_invalid: llm_cost_microusd requires reservation_tariff on every live LLM installation"

    refute host_message =~ "private-model-alias"
    refute host_message =~ "provider:private-model"

    manifest = manifest_path |> File.read!() |> Jason.decode!()

    File.write!(
      manifest_path,
      Jason.encode!(Map.put(manifest, "limits", %{"llm_total_tokens" => 50}))
    )

    manifest_message = failed_message(["validate", manifest_path])

    assert manifest_message =~
             "application/limit_unavailable: llm_total_tokens 50 is unavailable because the host has not enabled it; enable llm_total_tokens in the host document before declaring it in the manifest"

    assert manifest_message =~ " at /limits/llm_total_tokens"
  end

  @tag :tmp_dir
  test "root command names input and result contract failure paths", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{})
    File.write!(Path.join(dir, "main.clj"), ~S|(ns main) (defn run [input] (return input))|)

    schema = %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "integer"}},
      "required" => ["answer"]
    }

    File.write!(Path.join(dir, "contract.schema.json"), Jason.encode!(schema))
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    for {role, value, command, code} <- [
          {"input_schema", %{"answer" => "wrong"}, "validate", "input_contract_failed"},
          {"result_schema", %{"answer" => "wrong", "extra" => 1}, "run",
           "result_contract_failed"},
          {"input_schema", %{}, "validate", "input_contract_failed"},
          {"result_schema", %{}, "run", "result_contract_failed"}
        ] do
      contract_manifest =
        manifest
        |> Map.put("contracts", %{role => %{"path" => "contract.schema.json"}})
        |> put_in(["input", "value"], value)

      File.write!(manifest_path, Jason.encode!(contract_manifest))

      message = failed_message([command, manifest_path])
      assert message =~ "#{code}:"
      assert message =~ " at /answer", "#{role} with #{inspect(value)} rendered: #{message}"
    end

    tagged_union = %{
      "oneOf" => [
        contract_branch("left", "left_value"),
        contract_branch("right", "right_value")
      ]
    }

    File.write!(Path.join(dir, "contract.schema.json"), Jason.encode!(tagged_union))

    for {role, command, code} <- [
          {"input_schema", "validate", "input_contract_failed"},
          {"result_schema", "run", "result_contract_failed"}
        ] do
      contract_manifest =
        manifest
        |> Map.put("contracts", %{role => %{"path" => "contract.schema.json"}})
        |> put_in(["input", "value"], %{})

      File.write!(manifest_path, Jason.encode!(contract_manifest))

      message = failed_message([command, manifest_path])
      assert message =~ "#{code}:"
      assert message =~ " at /kind"
    end
  end

  @tag :tmp_dir
  test "an invalid inspection destination states the required filename suffix", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    invalid_inspection = Path.join(dir, "run.jsonl")

    message = failed_message(["run", manifest_path, "--inspect", invalid_inspection])

    assert message =~ "destination/invalid_inspection_destination:"
    assert message =~ ".ptcins"
    refute message =~ invalid_inspection
  end

  @tag :tmp_dir
  test "keeps a private value out of rendering and the envelope", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    File.write!(Path.join(dir, "private.json"), Jason.encode!(%{"value" => "confidential"}))
    private_output = Path.join(dir, "answer.private.json")

    assert run_output([
             "run",
             manifest_path,
             "--private-input",
             "private.json",
             "--private-output",
             private_output
           ]) == "{\"artifact_class\":\"private\",\"status\":\"ok\"}\n"

    {rendering, envelope} =
      run_envelope(dir, [
        "run",
        manifest_path,
        "--private-input",
        "private.json",
        "--private-output",
        Path.join(dir, "second.private.json")
      ])

    assert rendering == "{\"artifact_class\":\"private\",\"status\":\"ok\"}\n"
    assert envelope["result"] == %{"result_class" => "private"}
    refute Jason.encode!(envelope) =~ "confidential"
    assert Jason.decode!(File.read!(private_output)) == "confidential"
  end

  @tag :tmp_dir
  test "uses the shared trace-directory publication contract", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})
    trace_dir = Path.join(dir, "traces")
    File.mkdir!(trace_dir)

    {rendering, envelope} =
      run_envelope(dir, ["run", manifest_path, "--trace-dir", trace_dir])

    assert rendering == "1\n"
    assert envelope["artifact_state"]["trace"] == "written"
    assert File.exists?(Path.join(trace_dir, envelope["run_ref"] <> ".jsonl"))
  end

  @tag :tmp_dir
  test "treats removed run switches as ordinary unknown input", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})

    for removed <- [
          ["--" <> "mission", "input.json"],
          ["--private-" <> "mission", "input.json"],
          ["--trace", "run.jsonl"],
          ["--check"]
        ] do
      message = failed_message(["run", manifest_path | removed])
      assert message =~ "arguments/invalid_arguments"
      assert message =~ "; unknown switch; accepted:"
      refute message =~ "retired switch"
    end
  end

  test "renders a closed accepted list without retaining an unknown switch" do
    message = failed_message(["run", "ptc.json", "--caller-secret", "value"])

    assert message =~ "; unknown switch; accepted: --host-config, --input"
    assert message =~ "--authorize-mcp"
    refute message =~ "caller-secret"
  end

  test "Mix-specific help seals and renders its frontend-only switch" do
    presentation = MixCommandAdapter.execute(["help", "run"])

    assert presentation.exit_status == 0
    assert presentation.stderr == ""
    assert presentation.stdout =~ "--authorize-mcp NAME"
    assert presentation.outcome.envelope["status"] == "ok"
  end

  # Two real `mix ptc doctor` OS processes (~3.2 s). In-process
  # MixCommandAdapter cases in this file cover the same rendering; this one
  # pins Mix.exit status mapping.
  @tag :nightly
  test "the Mix process preserves human rendering and normal-mode diagnostic status" do
    args = ["doctor", "--caller-secret", "value"]

    for {extra_env, expected_status} <- [
          {[{"MIX_DEBUG", nil}], 2},
          {[{"MIX_DEBUG", "1"}], 1}
        ] do
      {output, status} =
        System.cmd(System.find_executable("mix"), ["ptc" | args],
          cd: @root,
          env: [{"MIX_ENV", "test"}, {"MIX_QUIET", "1"} | extra_env],
          stderr_to_stdout: true
        )

      assert status == expected_status
      assert [_, run_ref] = Regex.run(~r/\(run_ref: (cmd-[^)]+)\)/, output)
      assert {:error, entry} = CommandEntry.open_with_ref(args, :mix, run_ref)
      assert output =~ String.trim_trailing(CommandRenderer.rejection(run_ref, entry.rejection))
    end
  end

  test "rejects malformed and duplicate Mix authorization extensions before bootstrap" do
    for args <- [
          ["run", "ptc.json", "--authorize-mcp"],
          ["run", "ptc.json", "--authorize-mcp", "workspace", "--authorize-mcp", "workspace"]
        ] do
      message = failed_message(args)
      assert message =~ "arguments/invalid_arguments"
    end
  end

  test "parses before bootstrap and projects startup failure from the parsed command" do
    parent = self()

    presentation =
      CommandFrontend.execute(["doctor"], :mix, fn _arguments ->
        send(parent, :bootstrapped)
        {:error, :command_bootstrap_failed}
      end)

    assert_received :bootstrapped
    assert presentation.outcome.command_mode == :doctor
    assert presentation.outcome.envelope["error"]["phase"] == "internal"

    rejected =
      CommandFrontend.execute(["doctor", "--unknown"], :mix, fn _arguments ->
        send(parent, :unexpected_bootstrap)
        {:error, :command_bootstrap_failed}
      end)

    refute_received :unexpected_bootstrap
    assert rejected.exit_status == 2
    assert rejected.stderr =~ "unknown switch"
  end

  test "routes the repl subcommand through the shared task and parser" do
    assert run_output(["repl", "-e", "(+ 20 22)"]) == "42\n"
  end

  @tag :tmp_dir
  test "provider-free runs do not read an ambient dotenv file", %{tmp_dir: dir} do
    variable = "PTC_RUN_UNUSED_DOTENV_CREDENTIAL"
    track_environment(variable)
    File.write!(Path.join(dir, ".env"), "#{variable}=must-not-load\n")
    manifest_path = write_manifest(dir, %{"value" => 1})

    File.cd!(dir, fn -> run_output(["run", manifest_path]) end)

    assert System.get_env(variable) == nil
  end

  @tag :tmp_dir
  test "the Mix runtime does not load an ambient dotenv file", %{tmp_dir: dir} do
    variable = "PTC_RUN_AMBIENT_DOTENV_CREDENTIAL"
    track_environment(variable)
    File.write!(Path.join(dir, ".env"), "#{variable}=must-not-load\n")
    assert {:ok, entry} = CommandEntry.open(["run", "ptc.json"], :mix)
    assert {:ok, runtime} = MixCommandRuntime.runtime(entry.arguments)

    assert File.cd!(dir, fn -> CommandRuntime.setup_environment(runtime) end) == :ok
    assert System.get_env(variable) == nil
  end

  @tag :tmp_dir
  test "command runtime bootstrappers leave explicit environment loading to command execution", %{
    tmp_dir: dir
  } do
    for {frontend, variable, bootstrap} <- [
          {:mix, "PTC_RUN_EXPLICIT_MIX_CREDENTIAL", &MixCommandRuntime.bootstrap/1},
          {:standalone, "PTC_RUN_EXPLICIT_STANDALONE_CREDENTIAL",
           &StandaloneCommandRuntime.bootstrap/1}
        ] do
      track_environment(variable)
      env_file = Path.join(dir, "#{frontend}.env")
      File.write!(env_file, "#{variable}=loaded\n")

      assert {:ok, entry} =
               CommandEntry.open(["run", "ptc.json", "--env-file", env_file], frontend)

      assert {:ok, runtime} = bootstrap.(entry.arguments)
      assert CommandRuntime.setup_environment(runtime) == :ok
      assert runtime.environment_setup == nil
      assert System.get_env(variable) == nil
    end
  end

  @tag :tmp_dir
  test "--authorize-mcp rejections name the argument rather than failing internally", %{
    tmp_dir: dir
  } do
    # Both are ordinary argument mistakes: a mistyped alias, and a real alias
    # that simply carries no OAuth policy. Neither may answer with the code
    # reserved for a broken runtime, and they must not answer alike.
    missing_env = "PTC_AUTHORIZE_MISSING_#{System.unique_integer([:positive])}"
    System.delete_env(missing_env)
    {manifest_path, host_path} = write_provider_application(dir, missing_env)

    for {target, code} <- [
          {"absent", "authorization_target_unknown"},
          {"workspace", "authorization_not_applicable"}
        ] do
      presentation =
        MixCommandAdapter.execute([
          "run",
          manifest_path,
          "--host-config",
          host_path,
          "--authorize-mcp",
          target
        ])

      assert presentation.stderr =~ "local_preflight/#{code}"
      assert presentation.stderr =~ "provider/#{target}/local"
      refute presentation.stderr =~ "internal_error"
    end
  end

  @tag :tmp_dir
  test "an active doctor finding remains a readiness report", %{tmp_dir: dir} do
    missing_env = "PTC_DOCTOR_MISSING_#{System.unique_integer([:positive])}"
    System.delete_env(missing_env)
    {manifest_path, host_path} = write_provider_application(dir, missing_env)
    args = ["doctor", manifest_path, "--host-config", host_path, "--connect"]

    presentation = MixCommandAdapter.execute(args)

    assert presentation.exit_status == 4
    assert presentation.stderr == ""

    assert %{
             "readiness" => "failed",
             "checks" => checks
           } = Jason.decode!(String.trim(presentation.stdout))

    assert %{
             "name" => "provider/workspace/credentials",
             "status" => "fail",
             "code" => "credential_unavailable"
           } in checks

    assert %{
             "name" => "provider/workspace/connectivity",
             "status" => "skipped",
             "code" => "not_verified_due_to_failure"
           } in checks
  end

  @tag :tmp_dir
  test "an invalid application remains a doctor readiness report", %{tmp_dir: dir} do
    manifest_path = write_manifest(dir, %{"value" => 1})

    invalid_manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["workflow", "components", Access.at(0), "path"], "../main.clj")

    File.write!(manifest_path, Jason.encode!(invalid_manifest))
    args = ["doctor", manifest_path]

    presentation = MixCommandAdapter.execute(args)

    assert presentation.exit_status == 3
    assert presentation.stderr == ""

    assert %{
             "readiness" => "failed",
             "provider_activity" => false,
             "checks" => checks
           } = Jason.decode!(String.trim(presentation.stdout))

    assert %{
             "name" => "application",
             "status" => "fail",
             "code" => "schema_violation"
           } in checks
  end

  @tag :nightly
  @tag :tmp_dir
  test "the Mix process writes complete failed doctor reports to stdout", %{tmp_dir: dir} do
    invalid_dir = Path.join(dir, "invalid-application")
    File.mkdir!(invalid_dir)
    invalid_manifest = write_manifest(invalid_dir, %{"value" => 1})

    invalid_application =
      invalid_manifest
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["workflow", "components", Access.at(0), "path"], "../main.clj")

    File.write!(invalid_manifest, Jason.encode!(invalid_application))

    local_dir = Path.join(dir, "local-preflight")
    File.mkdir!(local_dir)

    {local_manifest, local_host} =
      write_provider_application(
        local_dir,
        "PTC_DOCTOR_UNUSED_#{System.unique_integer([:positive])}"
      )

    unavailable_host =
      local_host
      |> File.read!()
      |> Jason.decode!()
      |> put_in(
        ["install", "workspace", "transport", "command"],
        "definitely-not-a-real-binary-xyz"
      )

    File.write!(local_host, Jason.encode!(unavailable_host))

    cases = [
      {3, ["doctor", invalid_manifest],
       %{
         "name" => "application",
         "status" => "fail",
         "code" => "schema_violation"
       }},
      {4, ["doctor", local_manifest, "--host-config", local_host],
       %{
         "name" => "provider/workspace/local",
         "status" => "fail",
         "code" => "command_not_found"
       }}
    ]

    for {status, args, expected_check} <- cases do
      presentation = MixCommandAdapter.execute(args)
      result = run_mix_process(args, dir)

      assert presentation.exit_status == status
      assert presentation.stderr == ""
      assert expected_check in Jason.decode!(presentation.stdout)["checks"]
      assert result.status == status
      assert result.stdout == presentation.stdout
      assert result.stderr == ""
    end
  end

  defp seed_incomplete_build(build_path) do
    source_lib_path = Path.join(Mix.Project.build_path(), "lib")
    build_lib_path = Path.join(build_path, "lib")
    File.mkdir_p!(build_lib_path)

    source_lib_path
    |> File.ls!()
    |> Enum.reject(&(&1 in ["nimble_parsec", "ptc_runner"]))
    |> Enum.each(fn dependency ->
      File.ln_s!(
        Path.join(source_lib_path, dependency),
        Path.join(build_lib_path, dependency)
      )
    end)

    runner_path = Path.join(build_lib_path, "ptc_runner")
    File.cp_r!(Path.join(source_lib_path, "ptc_runner"), runner_path)
    File.rm!(Path.join([runner_path, "ebin", "ptc_runner.app"]))
  end

  defp run_output(args) do
    capture_io(fn ->
      Mix.Task.reenable("ptc")
      Ptc.run(args)
    end)
  end

  defp run_envelope(dir, args) do
    path = Path.join(dir, "envelope-#{System.unique_integer([:positive])}.json")
    rendering = run_output(args ++ ["--envelope", path])
    {rendering, path |> File.read!() |> Jason.decode!()}
  end

  defp failed_message(args) do
    Mix.Task.reenable("ptc")

    error = assert_raise Mix.Error, fn -> Ptc.run(args) end
    assert error.mix > 0
    error.message
  end

  defp run_mix_process(args, directory) do
    stdout_path = Path.join(directory, "stdout-#{System.unique_integer([:positive])}")
    stderr_path = Path.join(directory, "stderr-#{System.unique_integer([:positive])}")

    {output, status} =
      System.cmd(
        System.find_executable("bash") || raise("bash is required for Mix process tests"),
        [
          "-c",
          ~S(exec "$@" >"$PTC_TEST_STDOUT" 2>"$PTC_TEST_STDERR"),
          "ptc-mix-process",
          System.find_executable("mix"),
          "ptc" | args
        ],
        cd: @root,
        env: [
          {"MIX_DEBUG", nil},
          {"MIX_ENV", "test"},
          {"MIX_QUIET", "1"},
          {"PTC_TEST_STDOUT", stdout_path},
          {"PTC_TEST_STDERR", stderr_path}
        ]
      )

    assert output == ""

    %{
      status: status,
      stdout: File.read!(stdout_path),
      stderr: File.read!(stderr_path)
    }
  end

  defp write_manifest(dir, input) do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    path = Path.join(dir, "ptc.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "main", "path" => "main.clj"}],
          "entry" => "main/run"
        },
        "input" => %{"value" => input}
      })
    )

    path
  end

  defp contract_branch(kind, value_name) do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{"type" => "string", "const" => kind},
        value_name => %{"type" => "integer"}
      },
      "required" => ["kind", value_name]
    }
  end

  defp write_provider_application(dir, missing_env) do
    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main) (defn run [input] (return (get input "value")))|
    )

    manifest_path = Path.join(dir, "ptc.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "main", "path" => "main.clj"}],
          "entry" => "main/run"
        },
        "input" => %{"value" => %{}},
        "providers" => %{"workflow" => [], "mission" => [%{"name" => "workspace"}]}
      })
    )

    host_path = Path.join(dir, "ptc-host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => missing_env}},
        "install" => %{
          "workspace" => %{
            "source" => "mcp",
            "installation_revision" => "mix-doctor-test-v1",
            "transport" => %{
              "type" => "stdio",
              "command" => System.find_executable("sh"),
              "env" => %{"TOKEN" => %{"binding" => "key"}}
            },
            "tools" => %{
              "read" => %{"as" => "workspace.read", "effect" => "read"}
            }
          }
        }
      })
    )

    {manifest_path, host_path}
  end

  defp track_environment(variable) do
    previous_value = System.get_env(variable)
    System.delete_env(variable)

    on_exit(fn ->
      if previous_value,
        do: System.put_env(variable, previous_value),
        else: System.delete_env(variable)
    end)
  end
end
