defmodule Mix.Tasks.PtcTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc
  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.MixCommandAdapter
  alias PtcRunner.MixCommandRuntime

  @root Path.expand("../../..", __DIR__)

  test "only the root project bootstrap skips dependency checks" do
    assert MixCommandRuntime.app_config_args(PtcRunner.MixProject) == ["--no-deps-check"]
    assert MixCommandRuntime.app_config_args(Downstream.MixProject) == []
    assert MixCommandRuntime.app_config_args(nil) == []
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
  # --no-deps-check path leaves the omitted dependency uncompiled.
  @tag :slow
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
             "schema_version" => 2,
             "command" => "run",
             "status" => "ok",
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

  @tag :slow
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
    reset_dotenv(variable)
    File.write!(Path.join(dir, ".env"), "#{variable}=must-not-load\n")
    manifest_path = write_manifest(dir, %{"value" => 1})

    File.cd!(dir, fn -> run_output(["run", manifest_path]) end)

    assert System.get_env(variable) == nil
  end

  @tag :tmp_dir
  test "an active doctor finding remains the Mix failure message", %{tmp_dir: dir} do
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

    message = failed_message(args)
    assert %{"readiness" => "failed", "checks" => ^checks} = Jason.decode!(message)
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

  defp reset_dotenv(variable) do
    previous_value = System.get_env(variable)
    key = {Dotenv, :dotenv_loaded}
    previous_state = :persistent_term.get(key, :missing)

    System.delete_env(variable)
    :persistent_term.erase(key)

    on_exit(fn ->
      if previous_value,
        do: System.put_env(variable, previous_value),
        else: System.delete_env(variable)

      case previous_state do
        :missing -> :persistent_term.erase(key)
        state -> :persistent_term.put(key, state)
      end
    end)
  end
end
