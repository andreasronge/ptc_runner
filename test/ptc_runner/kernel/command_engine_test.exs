defmodule PtcRunner.Kernel.CommandEngineTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandContractAuthority
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.ValueContractClassification

  @zero_entropy <<0::128>>
  @stdio_root Path.expand("../../..", __DIR__)
  @stdio_fixture Path.expand("../../support/mcp_stdio_source_fixture.sh", __DIR__)

  test "run references use the fixed Crockford encoding" do
    assert CommandRunRef.encode(@zero_entropy) == "cmd-" <> String.duplicate("0", 26)

    assert CommandRunRef.encode(:binary.copy(<<0xFF>>, 16)) ==
             "cmd-7" <> String.duplicate("z", 25)
  end

  test "provider activity is monotonic" do
    assert {:ok, activity} = ProviderActivity.start_link()
    assert ProviderActivity.value(activity) == false
    assert :ok = ProviderActivity.mark(activity)
    assert :ok = ProviderActivity.mark(activity)
    assert ProviderActivity.value(activity) == true
  end

  test "command runtimes pair authorization targets with their notifier" do
    runtime = CommandRuntime.standalone()
    assert runtime.authorization_targets == []
    assert runtime.authorization_notifier == nil

    assert {:error, :invalid_command_runtime} =
             CommandRuntime.new(authorization_notifier: fn _url -> :ok end)

    assert {:error, :invalid_command_runtime} =
             CommandRuntime.new(authorization_targets: ["workspace"])

    assert {:ok, runtime} =
             CommandRuntime.new(
               authorization_targets: ["workspace"],
               authorization_notifier: fn _url -> :ok end
             )

    assert runtime.authorization_targets == ["workspace"]
  end

  test "help and version are exact phase-1 successes" do
    assert {:ok, %CommandOutcome{} = help} =
             CommandEngine.prepare(["doctor", "--help"])

    assert help.exit_status == 0
    assert help.envelope["command"] == "help"
    assert help.envelope["result"]["topic"] == "doctor"

    assert help.envelope["result"]["notices"] == [
             "doctor --connect may perform one or more real provider requests and may incur provider cost"
           ]

    assert_schema_valid(help.envelope)

    assert {:ok, %CommandOutcome{} = version} =
             CommandEngine.prepare(["--version"])

    assert version.envelope["command"] == "version"
    assert version.envelope["result"]["version"] == "0.13.0"
    assert_schema_valid(version.envelope)
  end

  test "help schema topics have deterministic lexical order" do
    help_branch =
      Enum.find(CommandContract.schema()["oneOf"], fn branch ->
        get_in(branch, ["properties", "command", "enum"]) == ["help"] and
          get_in(branch, ["properties", "status", "const"]) == "ok"
      end)

    topics =
      Enum.map(get_in(help_branch, ["properties", "result", "oneOf"]), fn branch ->
        get_in(branch, ["properties", "topic", "const"])
      end)

    assert topics == ~w(doctor init models repl root run run validate)

    run_options =
      help_branch
      |> get_in(["properties", "result", "oneOf"])
      |> Enum.filter(&(get_in(&1, ["properties", "topic", "const"]) == "run"))
      |> Enum.map(&get_in(&1, ["properties", "options", "const"]))

    assert Enum.count(run_options, fn options ->
             Enum.any?(options, &(&1["switches"] == ["--authorize-mcp NAME"]))
           end) == 1
  end

  test "the production command engine owns run-reference entropy" do
    assert Code.ensure_loaded?(CommandEngine)
    assert function_exported?(CommandEngine, :prepare, 1)
    refute function_exported?(CommandEngine, :prepare, 2)
  end

  test "the direct engine APIs reject frontend-owned envelope publication" do
    for operation <- [&CommandEngine.prepare/1, &CommandEngine.dispatch/1] do
      path = Path.join(System.tmp_dir!(), "ptc-direct-envelope-#{System.unique_integer()}.json")

      assert {:error, %CommandOutcome{} = outcome} =
               operation.(["doctor", "--envelope", path])

      assert outcome.envelope["error"]["phase"] == "arguments"
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
      refute File.exists?(path)
    end
  end

  test "a switch after a missing string value remains an unknown switch" do
    for argv <- [
          ["repl", "--eval", "--no-help"],
          ["repl", "-e", "-hh"]
        ] do
      assert {:error, %CommandRejection{kind: :unknown_switch}} = CommandParser.parse(argv)
    end
  end

  @tag :tmp_dir
  test "shared dispatch completes a provider-free run through publication", %{tmp_dir: directory} do
    application = write_application(directory, "shared-dispatch", valid_manifest())
    output = Path.join(directory, "result.json")

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--output", output])

    assert outcome.envelope["status"] == "ok"
    assert outcome.envelope["artifact_class"] == "normal"
    assert outcome.envelope["artifact_state"]["result"] == "written"
    assert outcome.envelope["result"] == %{"result_class" => "normal", "value" => %{}}
    assert outcome.envelope["execution"]["state"] == "finished"
    assert outcome.envelope["execution"]["outcome"] == "ok"
    assert outcome.envelope["execution"]["diagnostic"] == nil
    assert_schema_valid(outcome.envelope)

    assert Jason.decode!(File.read!(output)) == %{}
  end

  @tag :tmp_dir
  test "provider-free dispatch rejects explicit authorization targets", %{tmp_dir: directory} do
    application = write_application(directory, "provider-free-authorization", valid_manifest())

    assert {:ok, runtime} =
             CommandRuntime.new(
               authorization_targets: ["workspace"],
               authorization_notifier: fn _url -> :ok end
             )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application], runtime)

    assert outcome.envelope["error"]["phase"] == "internal"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["execution"] == %{"state" => "not_started"}
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "shared dispatch withholds a private result after owner-backed publication", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "private-dispatch", valid_manifest())
    input = Path.join(Path.dirname(application), "private-input.json")
    output = Path.join(directory, "private-result.json")
    File.write!(input, ~s({"secret":"not-for-the-envelope"}))

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch([
               "run",
               application,
               "--private-input",
               "private-input.json",
               "--private-output",
               output
             ])

    assert outcome.envelope["artifact_class"] == "private"
    assert outcome.envelope["artifact_state"]["result"] == "written"
    assert outcome.envelope["result"] == %{"result_class" => "private"}
    refute Jason.encode!(outcome.envelope) =~ "not-for-the-envelope"
    assert Jason.decode!(File.read!(output)) == %{"secret" => "not-for-the-envelope"}
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "shared dispatch opens and closes one provider-backed run", %{tmp_dir: directory} do
    marker = Path.join(directory, "dispatch-methods")
    host_path = write_host_config(directory, "dispatch-stdio", connect_host_config(marker))

    application =
      doctor_application(directory, "dispatch-selects-stdio",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000}
      )

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert outcome.envelope["status"] == "ok"
    assert outcome.envelope["result"] == %{"result_class" => "normal", "value" => %{}}
    assert File.exists?(marker)
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "shared dispatch keeps audited-local rejection before execution and provider activity", %{
    tmp_dir: directory
  } do
    manifest =
      valid_manifest(%{
        "providers" => %{
          "workflow" => [],
          "mission" => [%{"name" => "workspace", "config" => %{}}]
        }
      })

    application = write_application(directory, "run-local-preflight", manifest)

    host_path =
      write_host_config(directory, "run-local-preflight", %{
        "install" => %{"workspace" => inert_stdio_installation("run-local-v1")}
      })

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["execution"] == %{"state" => "not_started"}
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "shared dispatch classifies a Kernel failure without exposing its value", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "failed-dispatch", valid_manifest())

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (fail {"secret" "must-not-escape"}))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.envelope["artifact_class"] == "normal"
    assert outcome.envelope["error"]["phase"] == "execution"
    assert outcome.envelope["error"]["code"] == "workflow_failed"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["execution"]["state"] == "incomplete"
    assert is_map(outcome.envelope["execution"]["usage"])
    refute Jason.encode!(outcome.envelope) =~ "must-not-escape"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "shared dispatch classifies an invalid terminal result as a result-guard failure", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "invalid-terminal-result", valid_manifest())

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (return #{1 2}))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.envelope["error"]["phase"] == "result_cleanup"
    assert outcome.envelope["error"]["code"] == "result_invalid"
    assert outcome.exit_status == 7
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "shared dispatch classifies Kernel-boundary projection failures as invalid results", %{
    tmp_dir: directory
  } do
    for {name, source} <- [
          {"java-terminal-result",
           ~S|(ns app) (defn run [_input] (return Boolean/parseBoolean))|},
          {"colliding-terminal-result",
           ~S|(ns app) (defn run [_input] (return {(fn [x] x) 1 "#fn[...]" 2}))|}
        ] do
      application = write_application(directory, name, valid_manifest())
      File.write!(Path.join(Path.dirname(application), "main.clj"), source)

      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.dispatch(["run", application])

      assert outcome.envelope["error"]["phase"] == "result_cleanup"
      assert outcome.envelope["error"]["code"] == "result_invalid"
      assert_schema_valid(outcome.envelope)
    end
  end

  test "post-execution settlement failures cannot report execution as not started" do
    artifact_state = %{
      "trace" => "not_requested",
      "inspection" => "not_requested",
      "result" => "not_requested"
    }

    run_ref = CommandRunRef.encode(@zero_entropy)
    assert {:ok, authority} = PublicationAuthority.authorize(run_ref, [], :normal, :normal)
    on_exit(fn -> PublicationAuthority.close(authority) end)

    assert {:error, %CommandOutcome{} = outcome} =
             CommandRunOutcome.settle(
               :invalid_execution_outcome,
               authority,
               run_ref,
               :normal,
               artifact_state,
               true
             )

    assert outcome.envelope["execution"] == %{
             "state" => "incomplete",
             "usage" => nil,
             "evaluation_memory" => nil
           }

    assert outcome.envelope["error"]["provider_activity"] == true
    assert_schema_valid(outcome.envelope)

    assert {:error, %CommandOutcome{} = fallback} =
             CommandRunOutcome.project(
               %{result_class: :normal},
               :invalid_settlement,
               run_ref,
               true
             )

    assert fallback.envelope["execution"] == %{
             "state" => "incomplete",
             "usage" => nil,
             "evaluation_memory" => nil
           }

    assert fallback.envelope["error"]["provider_activity"] == true
    assert_schema_valid(fallback.envelope)
  end

  @tag :tmp_dir
  test "frontend environment setup fails before the execution owner and activity marker", %{
    tmp_dir: directory
  } do
    host = %{
      "credentials" => %{"key" => %{"env" => "PTC_TEST_ABSENT_KEY"}},
      "install" => %{
        "model" => %{
          "source" => "llm",
          "installation_revision" => "model-v1",
          "model" => "openrouter:test/model",
          "credential" => "key"
        }
      }
    }

    host_path = write_host_config(directory, "environment-setup", host)
    trace_directory = Path.join(directory, "traces")
    File.mkdir!(trace_directory)

    application =
      doctor_application(directory, "environment-selected", workflow: ["model"])

    parent = self()

    assert {:ok, runtime} =
             CommandRuntime.new(
               provider_application_mode: :host_owned,
               environment_setup: fn ->
                 send(parent, :environment_setup)
                 {:error, :unavailable}
               end
             )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(
               [
                 "run",
                 application,
                 "--host-config",
                 host_path,
                 "--trace-dir",
                 trace_directory
               ],
               runtime
             )

    assert_received :environment_setup
    assert outcome.envelope["artifact_class"] == "normal"
    assert outcome.envelope["error"]["phase"] == "internal"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["execution"] == %{"state" => "not_started"}
    assert outcome.envelope["artifact_state"]["trace"] == "not_written"
    assert_schema_valid(outcome.envelope)
  end

  test "malformed phase-1 forms retain their recognized command" do
    cases = [
      {["version", "extra"], "version"},
      {["--version", "extra"], "version"},
      {["missing-command", "--version"], "version"},
      {["run", "ptc.json", "--version"], "version"},
      {["--help", "extra"], "help"},
      {["validate", "--help", "extra"], "help"},
      {["doctor", "--no-connect"], "doctor"}
    ]

    for {argv, command} <- cases do
      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.prepare(argv)

      assert outcome.envelope["command"] == command
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
      assert_schema_valid(outcome.envelope)
    end
  end

  test "parsed doctor connect commands retain their private outcome mode" do
    # The mode is private: it decides which diagnostics the envelope admits and
    # never appears in `command`. This case reaches the host document before any
    # provider work, so it also proves the mode survives an ordinary classified
    # failure rather than only the internal error the command answered with
    # while `--connect` was unreachable.
    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               "ptc.json",
               "--host-config",
               "host.json",
               "--connect"
             ])

    assert outcome.command_mode == {:doctor, :connect}
    assert outcome.envelope["command"] == "doctor"
    assert outcome.envelope["error"]["phase"] == "host"
    assert outcome.envelope["error"]["code"] == "host_unavailable"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "validate never invokes an audited-local check that doctor does", %{tmp_dir: directory} do
    # The alias names an executable that cannot exist, so its shipped
    # audited-local check must fail whenever it runs. Default doctor runs it and
    # reports the closed local code; `validate` sees the same host, the same
    # application, and the same selection, and succeeds — which it could only do
    # by never invoking the callback. Asserting `validate` merely succeeds would
    # prove nothing without doctor failing beside it on identical input.
    manifest =
      valid_manifest(%{
        "providers" => %{
          "workflow" => [],
          "mission" => [%{"name" => "workspace", "config" => %{}}]
        }
      })

    application = write_application(directory, "inert-validate", manifest)

    host_path =
      write_host_config(directory, "inert-validate", %{
        "install" => %{"workspace" => inert_stdio_installation("inert-v1")}
      })

    assert {:error, %CommandOutcome{} = doctored} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert doctored.envelope["error"]["phase"] == "local_preflight"
    assert doctored.envelope["error"]["provider_activity"] == false

    assert {:ok, %CommandOutcome{} = validated} =
             CommandEngine.prepare(["validate", application, "--host-config", host_path])

    assert validated.exit_status == 0
    assert validated.envelope["command"] == "validate"
    assert validated.envelope["result"]["provider_activity"] == false
    assert_schema_valid(validated.envelope)
  end

  @tag :tmp_dir
  test "models projects declarations without invoking a hostile local callback", %{
    tmp_dir: directory
  } do
    manifest =
      valid_manifest(%{
        "providers" => %{
          "workflow" => [],
          "mission" => [%{"name" => "zeta", "config" => %{}}]
        }
      })

    application = write_application(directory, "inert-models", manifest)

    host_path =
      write_host_config(directory, "inert-models", %{
        "install" => %{
          "zeta" => inert_stdio_installation("zeta-v1"),
          "alpha" => inert_stdio_installation("alpha-v1")
        }
      })

    assert {:error, %CommandOutcome{} = doctored} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert doctored.envelope["error"]["phase"] == "local_preflight"
    assert doctored.envelope["error"]["provider_activity"] == false

    assert {:ok, %CommandOutcome{} = modeled} =
             CommandEngine.prepare(["models", "--host-config", host_path])

    assert modeled.exit_status == 0
    assert modeled.envelope["command"] == "models"

    assert modeled.envelope["result"] == %{
             "installations" => [
               %{
                 "alias" => "alpha",
                 "source" => "mcp",
                 "installation_revision" => "alpha-v1",
                 "data_class" => "normal",
                 "accepts_data" => ["normal"],
                 "destinations" => ["mission"]
               },
               %{
                 "alias" => "zeta",
                 "source" => "mcp",
                 "installation_revision" => "zeta-v1",
                 "data_class" => "normal",
                 "accepts_data" => ["normal"],
                 "destinations" => ["mission"]
               }
             ]
           }

    assert_schema_valid(modeled.envelope)

    assert {:error, %CommandOutcome{} = missing_host} =
             CommandEngine.prepare([
               "models",
               "--host-config",
               Path.join(directory, "missing-host.json")
             ])

    assert missing_host.envelope["error"]["phase"] == "host"
    assert missing_host.envelope["error"]["code"] == "host_unavailable"
    assert missing_host.envelope["error"]["provider_activity"] == false
    assert_schema_valid(missing_host.envelope)
  end

  test "default doctor reports the environment without an application or host" do
    assert {:ok, %CommandOutcome{} = outcome} = CommandEngine.prepare(["doctor"])

    assert outcome.exit_status == 0
    assert outcome.envelope["command"] == "doctor"
    assert outcome.envelope["result"]["provider_activity"] == false

    checks = outcome.envelope["result"]["checks"]
    assert Enum.map(checks, & &1["name"]) == ["runtime", "application", "viewer"]

    assert %{"status" => "skipped", "code" => "not_requested"} =
             Enum.find(checks, &(&1["name"] == "application"))

    assert_schema_valid(outcome.envelope)
    assert CommandContract.valid_success_semantics?(:doctor, outcome.envelope["result"])
  end

  @tag :tmp_dir
  test "default doctor defers every installed alias until an application selects it", %{
    tmp_dir: directory
  } do
    host_path = write_host_config(directory, "doctor-surface", valid_host_config())

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", "--host-config", host_path])

    checks = outcome.envelope["result"]["checks"]

    assert %{"status" => "skipped", "code" => "application_required"} =
             Enum.find(checks, &(&1["name"] == "provider/workspace/local"))

    assert %{"status" => "skipped", "code" => "requires_connect"} =
             Enum.find(checks, &(&1["name"] == "provider/workspace/connectivity"))

    assert outcome.envelope["result"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a passing audited-local check settles its row without provider activity", %{
    tmp_dir: directory
  } do
    shell = System.find_executable("sh")

    host_path =
      write_host_config(
        directory,
        "doctor-local-pass",
        stdio_host_config(shell, shell, directory)
      )

    application = doctor_application(directory, "selects-stdio", mission: ["workspace"])

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    checks = outcome.envelope["result"]["checks"]

    assert %{"status" => "pass", "code" => "available"} =
             Enum.find(checks, &(&1["name"] == "provider/workspace/local"))

    # Phase 7 runs before the marker, so a settled local row still reports no
    # provider activity.
    assert outcome.envelope["result"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
    assert CommandContract.valid_success_semantics?(:doctor, outcome.envelope["result"])
  end

  @tag :tmp_dir
  test "a failing audited-local check fails the command instead of the row", %{
    tmp_dir: directory
  } do
    # The closed result contract has no failing provider row in any mode, so a
    # local check that fails must surface as the command's own diagnostic.
    host_path =
      write_host_config(directory, "doctor-local-fail", %{
        "credentials" => %{"key" => %{"literal" => "not-read"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "installation_revision" => "model-v1",
            "model" => "definitely-not-a-model",
            "credential" => "key"
          }
        }
      })

    application = doctor_application(directory, "selects-model", workflow: ["model"])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert outcome.envelope["command"] == "doctor"
    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "adapter_unavailable"
    assert outcome.envelope["error"]["subject"]["name"] == "model"
    assert outcome.envelope["error"]["subject"]["operation"] == "local"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
  end

  test "doctor --connect is refused without both an application and a host" do
    # The connect branch reads this as a guarantee rather than checking it
    # again: it derives a connect-mode plan, which requires a preparation, and
    # opens an operation, which requires installed providers. Relaxing the rule
    # would turn either omission into an internal error instead of the argument
    # error it is.
    for argv <- [
          ["doctor", "--connect"],
          ["doctor", "--connect", "--host-config", "host.json"],
          ["doctor", "ptc.json", "--connect"]
        ] do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.prepare(argv)

      # The mode is not yet known when the arguments are refused, so these
      # report as plain `doctor` rather than as the private connect mode.
      assert outcome.command_mode == :doctor
      assert outcome.envelope["error"]["phase"] == "arguments"
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
      assert_schema_valid(outcome.envelope)
    end
  end

  @tag :tmp_dir
  test "doctor --connect sets up selected environment credentials before active work", %{
    tmp_dir: directory
  } do
    environment_name = "PTC_TEST_DOCTOR_CONNECT_TOKEN"
    previous_environment = System.get_env(environment_name)
    System.delete_env(environment_name)

    initially_running =
      Application.started_applications()
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    previous =
      for key <- [
            :llm_adapter,
            :host_llm_test_owner,
            :host_llm_test_provider_application,
            :host_llm_test_result
          ],
          into: %{},
          do: {key, Application.fetch_env(:ptc_runner, key)}

    if MapSet.member?(initially_running, :req_llm), do: Application.stop(:req_llm)
    if MapSet.member?(initially_running, :llm_db), do: Application.stop(:llm_db)

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_provider_application, :req_llm)
    Application.put_env(:ptc_runner, :host_llm_test_result, {:ok, %{content: "ok", tokens: %{}}})
    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, false, persistent: true)

    on_exit(fn ->
      if previous_environment,
        do: System.put_env(environment_name, previous_environment),
        else: System.delete_env(environment_name)

      if :req_llm in Enum.map(Application.started_applications(), &elem(&1, 0)),
        do: Application.stop(:req_llm)

      if :llm_db in Enum.map(Application.started_applications(), &elem(&1, 0)),
        do: Application.stop(:llm_db)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_runner, key, value)
        {key, :error} -> Application.delete_env(:ptc_runner, key)
      end)

      if MapSet.member?(initially_running, :llm_db),
        do: Application.ensure_all_started(:llm_db)

      if MapSet.member?(initially_running, :req_llm),
        do: Application.ensure_all_started(:req_llm)
    end)

    host_path =
      write_host_config(directory, "command-owned-model", %{
        "credentials" => %{"key" => %{"env" => environment_name}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "installation_revision" => "model-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })

    application = doctor_application(directory, "command-owned-model", workflow: ["model"])
    caller = self()

    assert {:ok, runtime} =
             CommandRuntime.new(
               provider_application_mode: :command_vm,
               environment_setup: fn ->
                 System.put_env(environment_name, "test-secret")
                 send(caller, :doctor_environment_setup)
                 :ok
               end
             )

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(
               ["doctor", application, "--host-config", host_path, "--connect"],
               runtime
             )

    assert outcome.exit_status == 0
    assert outcome.envelope["result"]["provider_activity"] == true
    assert_received :doctor_environment_setup
    assert_received {:host_llm_ensure_ready, _pid}
    assert_received {:host_llm_request, "openrouter:test/model", _request}
  end

  @tag :tmp_dir
  test "doctor --connect settles the rows default doctor defers", %{tmp_dir: directory} do
    # The whole command end to end, over a real MCP stdio server. The same host
    # and application under default doctor leave the connectivity row deferred;
    # `--connect` reaches the server and settles it. `CommandContract` is the
    # judge rather than these assertions, because it admits a connect success
    # only when *every* provider row is `pass`.
    #
    # This is also what pins the plan mode. A `:default` plan carries
    # `skipped/requires_connect` on the connectivity row, and `settle_connect/4`
    # refuses a plan whose connectivity rows are not all pending, so deriving
    # the plan with the other mode fails the command rather than mislabelling a
    # row.
    marker = Path.join(directory, "connect-methods")
    host_path = write_host_config(directory, "connect-stdio", connect_host_config(marker))

    application =
      doctor_application(directory, "selects-stdio-connect",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000}
      )

    assert {:ok, %CommandOutcome{} = deferred} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert %{"status" => "skipped", "code" => "requires_connect"} =
             Enum.find(
               deferred.envelope["result"]["checks"],
               &(&1["name"] == "provider/workspace/connectivity")
             )

    assert deferred.envelope["result"]["provider_activity"] == false
    refute File.exists?(marker)

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.command_mode == {:doctor, :connect}
    assert outcome.exit_status == 0
    assert outcome.envelope["command"] == "doctor"

    checks = outcome.envelope["result"]["checks"]

    assert Enum.map(checks, & &1["name"]) == [
             "runtime",
             "application",
             "viewer",
             "provider/workspace/local",
             "provider/workspace/selection",
             "provider/workspace/connectivity"
           ]

    assert %{"status" => "pass", "code" => "valid"} =
             Enum.find(checks, &(&1["name"] == "application"))

    # Both rows default doctor could not settle. The local one is the shared
    # phase-7 audited-local step; the connectivity one comes from the
    # operation's own result.
    assert %{"status" => "pass", "code" => "available"} =
             Enum.find(checks, &(&1["name"] == "provider/workspace/local"))

    assert %{"status" => "pass", "code" => "available"} =
             Enum.find(checks, &(&1["name"] == "provider/workspace/connectivity"))

    assert outcome.envelope["result"]["provider_activity"] == true

    # Independent of the rows: the server was really contacted and really
    # served the acquisition handshake.
    assert File.read!(marker) =~ "server/discover"
    assert File.read!(marker) =~ "tools/list"

    assert_schema_valid(outcome.envelope)
    assert CommandContract.valid_success_result?(:doctor, outcome.envelope["result"])
  end

  @tag :tmp_dir
  test "doctor --connect answers for a selection naming no provider", %{tmp_dir: directory} do
    # Connectivity answers for selected occurrences, so a selection with none
    # has no operation to run and `RunCoordinator.connect/3` refuses one. The
    # command still has a complete answer: every row such a plan holds was
    # settled when it was derived, and no provider activity happened. The
    # installed alias is deliberately left unselected, so this also proves the
    # plan reports the selection rather than the installed surface.
    marker = Path.join(directory, "unselected-methods")
    host_path = write_host_config(directory, "connect-unselected", connect_host_config(marker))
    application = doctor_application(directory, "selects-nothing", [])

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.command_mode == {:doctor, :connect}
    assert outcome.exit_status == 0

    checks = outcome.envelope["result"]["checks"]
    assert Enum.map(checks, & &1["name"]) == ["runtime", "application", "viewer"]

    assert %{"status" => "pass", "code" => "valid"} =
             Enum.find(checks, &(&1["name"] == "application"))

    assert outcome.envelope["result"]["provider_activity"] == false
    refute File.exists?(marker)
    assert_schema_valid(outcome.envelope)
    assert CommandContract.valid_success_result?(:doctor, outcome.envelope["result"])
  end

  @tag :tmp_dir
  test "an internal failure before the marker reports no provider activity", %{
    tmp_dir: directory
  } do
    # The mirror of the case below, and the reason the answer is asked rather
    # than assumed. The execution owner opens its sinks before any provider
    # work, and a manifest may narrow `normal_event_bytes` below the reserve
    # that opening requires, so the operation can fail with a bare reason having
    # contacted nothing. Reporting `provider_activity: true` for it would claim
    # a cost the command never incurred.
    marker = Path.join(directory, "pre-marker-methods")
    host_path = write_host_config(directory, "connect-pre-marker", connect_host_config(marker))

    application =
      doctor_application(directory, "selects-pre-marker",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000, "normal_event_bytes" => 1}
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.command_mode == {:doctor, :connect}
    assert outcome.envelope["error"]["phase"] == "internal"
    assert outcome.envelope["error"]["code"] == "internal_error"
    assert outcome.envelope["error"]["provider_activity"] == false
    refute File.exists?(marker)
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "run sink-opening failures preserve not-started activity evidence", %{
    tmp_dir: directory
  } do
    limits = %{"evaluation_timeout_ms" => 5_000, "normal_event_bytes" => 1}

    provider_free =
      write_application(
        directory,
        "run-sink-provider-free",
        valid_manifest(%{"limits" => limits})
      )

    marker = Path.join(directory, "run-sink-provider-backed-methods")

    host_path =
      write_host_config(directory, "run-sink-provider-backed", connect_host_config(marker))

    provider_backed =
      doctor_application(directory, "run-sink-provider-backed",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: limits
      )

    for argv <- [
          ["run", provider_free],
          ["run", provider_backed, "--host-config", host_path]
        ] do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(argv)
      assert outcome.envelope["error"]["phase"] == "internal"
      assert outcome.envelope["error"]["code"] == "internal_error"
      assert outcome.envelope["error"]["provider_activity"] == false
      assert outcome.envelope["execution"] == %{"state" => "not_started"}
      assert_schema_valid(outcome.envelope)
    end

    refute File.exists?(marker)
  end

  @tag :tmp_dir
  test "an internal failure after the marker still reports provider activity", %{
    tmp_dir: directory
  } do
    # The counterpart to the audited-local case below, on the other side of the
    # marker. Sealing the operation's own result is made to raise, so the
    # command fails after it has already contacted the server. Reporting
    # `provider_activity: false` here would tell the caller nothing was spent
    # when something was.
    #
    # The diagnostic itself is minted by `ProviderExecution`'s own boundary, so
    # what this pins at the command boundary is narrower than it looks: that no
    # answer the engine gives from the operation onward loses the flag. It fails
    # if the engine mints its own activity-free internal error there, and it
    # does not discriminate between rendering the operation's diagnostic and
    # replacing it with an equivalent one — the case below does that.
    marker = Path.join(directory, "post-marker-methods")
    host_path = write_host_config(directory, "connect-post-marker", connect_host_config(marker))

    application =
      doctor_application(directory, "selects-post-marker",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000}
      )

    storage_key = {Attestation, PtcRunner.Kernel.ConnectivityResult}
    previous_key = :persistent_term.get(storage_key, :missing)

    on_exit(fn ->
      case previous_key do
        :missing -> :persistent_term.erase(storage_key)
        key -> :persistent_term.put(storage_key, key)
      end
    end)

    :persistent_term.put(storage_key, :invalid_hmac_key)

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.command_mode == {:doctor, :connect}
    assert outcome.envelope["error"]["phase"] == "internal"
    assert outcome.envelope["error"]["code"] == "internal_error"
    assert outcome.envelope["error"]["provider_activity"] == true

    # The failure is genuinely past the marker: the server was reached first.
    assert File.read!(marker) =~ "tools/list"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a failing check under --connect renders one diagnostic and no rows", %{
    tmp_dir: directory
  } do
    # The closed result contract has no failing provider row in either mode, so
    # a connect that cannot settle every row reports its catalogued diagnostic
    # and no `result` at all. This one fails in the shared phase-7 step, which
    # the connect operation crosses through `ProviderExecution` before the
    # activity marker — which is why it reports no provider activity even though
    # the command asked for connectivity.
    host_path =
      write_host_config(directory, "connect-local-fail", %{
        "credentials" => %{"key" => %{"literal" => "not-read"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "installation_revision" => "model-v1",
            "model" => "definitely-not-a-model",
            "credential" => "key"
          }
        }
      })

    application = doctor_application(directory, "connect-selects-model", workflow: ["model"])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.command_mode == {:doctor, :connect}
    assert outcome.envelope["command"] == "doctor"
    refute Map.has_key?(outcome.envelope, "result")
    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "adapter_unavailable"
    assert outcome.envelope["error"]["subject"]["name"] == "model"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["secondary_errors"] == []
    assert_schema_valid(outcome.envelope)
  end

  test "undeclared options are rejected before cross-command conflict rules" do
    cases = [
      {:init, ["init", "project", "--input", "a", "--private-input", "b"]},
      {:validate, ["validate", "ptc.json", "--input", "a", "--private-input", "b"]},
      {:doctor, ["doctor", "--output", "a", "--private-output", "b"]},
      {:models, ["models", "--input", "a", "--private-input", "b"]}
    ]

    for {command, argv} <- cases do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.prepare(argv)
      assert outcome.command_mode == command
      assert outcome.envelope["command"] == Atom.to_string(command)
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
      assert outcome.exit_status == 2
    end
  end

  test "every duplicate switch is rejected before path or provider work" do
    string_switches = [
      "--host-config",
      "--input",
      "--private-input",
      "--trace-dir",
      "--output",
      "--private-output",
      "--inspect",
      "--component-override-descriptor"
    ]

    for switch <- string_switches do
      argv = ["run", "ptc.json", switch, "first", switch, "second"]

      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.prepare(argv)

      assert outcome.envelope["command"] == "run"
      assert outcome.envelope["error"]["code"] == "invalid_arguments"
    end

    for argv <- [
          ["doctor", "ptc.json", "--host-config", "host.json", "--connect", "--connect"],
          [
            "run",
            "ptc.json",
            "--host-config",
            "first.json",
            "--host_config",
            "second.json"
          ],
          ["run", "ptc.json", "--help", "--help"],
          ["--version", "--version"]
        ] do
      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.prepare(argv)

      assert outcome.envelope["error"]["code"] == "invalid_arguments"
    end
  end

  test "the option terminator preserves underscore-bearing positional arguments" do
    assert {:ok, arguments} = CommandParser.parse(["init", "--", "--project_dir"])
    assert arguments.command == :init
    assert arguments.directory == "--project_dir"
    assert arguments.options == %{}
  end

  test "the option terminator excludes known switch names from duplicate detection" do
    assert {:ok, arguments} =
             CommandParser.parse([
               "validate",
               "--host-config",
               "host.json",
               "--",
               "--host-config"
             ])

    assert arguments.command == :validate
    assert arguments.application == "--host-config"
    assert arguments.options == %{host_config: "host.json"}
  end

  test "command declarations are the single source for accepted switches and help" do
    assert {:ok, validate_help} = CommandEngine.prepare(["help", "validate"])

    assert validate_help.envelope["result"] == %{
             "topic" => "validate",
             "usage" => ["ptc validate ptc.json [--host-config HOST.json]"],
             "options" => [
               %{
                 "switches" => ["--host-config HOST.json"],
                 "description" => "trusted provider installation document"
               },
               %{
                 "switches" => ["--envelope ENVELOPE.json"],
                 "description" => "atomically publish the V1 command envelope"
               }
             ],
             "notices" => []
           }

    assert {:error, rejection} =
             CommandParser.parse(["validate", "ptc.json", "--output", "result.json"])

    assert rejection.kind == :unknown_switch
    assert rejection.accepted == ["--host-config", "--envelope"]
  end

  test "the repl short help alias resolves to its generated help topic only by itself" do
    assert {:ok, arguments} = CommandParser.parse(["repl", "-h"])
    assert arguments.command == :help
    assert arguments.options.topic == :repl

    assert {:error, rejection} = CommandParser.parse(["repl", "-h", "-e", "42"])
    assert rejection.code == :invalid_arguments
  end

  test "unknown-switch rejections expose only the closed accepted list" do
    assert {:error, first} =
             CommandParser.parse(["run", "ptc.json", "--secret-first", "value"])

    assert {:error, second} =
             CommandParser.parse(["run", "ptc.json", "--secret-second", "value"])

    assert first == second
    assert first.command == :run
    assert first.code == :invalid_arguments
    assert first.kind == :unknown_switch

    assert first.accepted == [
             "--host-config",
             "--input",
             "--private-input",
             "--trace-dir",
             "--output",
             "--private-output",
             "--inspect",
             "--component-override-descriptor",
             "--envelope"
           ]

    refute inspect(first) =~ "secret-first"
    refute inspect(second) =~ "secret-second"
  end

  test "retired switches are command-specific and carry fixed replacements" do
    assert {:error, rejection} =
             CommandParser.parse(["run", "ptc.json", "--trace", "run.jsonl"])

    assert rejection.command == :run
    assert rejection.code == :invalid_arguments
    assert rejection.kind == :retired_switch
    assert rejection.retired == "--trace"
    assert rejection.replacement == "--trace-dir"
  end

  test "undeclared raw spellings are unknown rather than normalized by OptionParser" do
    for argv <- [
          ["run", "ptc.json", "--no-input"],
          ["run", "ptc.json", "--no-trace"],
          ["doctor", "--no-connect"],
          ["repl", "--no-private-terminal"],
          ["repl", "--no-continue-on-error"],
          ["repl", "--no-help"],
          ["repl", "-hh"]
        ] do
      assert {:error, rejection} = CommandParser.parse(argv)
      assert rejection.kind == :unknown_switch
      assert rejection.retired == nil
      assert rejection.replacement == nil
      assert rejection.accepted != []
    end
  end

  test "raw spelling checks do not reinterpret declared string option values" do
    assert {:ok, arguments} = CommandParser.parse(["repl", "-e", "-10"])
    assert arguments.ordered_options == [eval: "-10"]
  end

  test "repl structural combinations are rejected by the shared parser" do
    for argv <- [
          ["repl", "--format", "yaml"],
          ["repl", "--describe-profile", "log-analysis-v2", "--load", "caller-value"],
          ["repl", "--profile", "log-analysis-v2", "--manifest", "ptc.json"],
          ["repl", "--profile", "log-analysis-v2", "--host-config", "host.json"],
          ["repl", "--profile", "log-analysis-v2", "--trace", "trace.jsonl"],
          ["repl", "--profile", "log-analysis-v2"],
          [
            "repl",
            "--profile",
            "inspection-analysis-v2",
            "--resource",
            "traces=traces",
            "--private-unattended",
            "--format",
            "jsonl"
          ],
          [
            "repl",
            "--profile",
            "log-analysis-v2",
            "--resource",
            "traces=traces",
            "--continue-on-error",
            "-e",
            "1"
          ],
          ["repl", "--manifest", "ptc.json", "--resource", "traces=traces"],
          ["repl", "--manifest", "ptc.json", "--session-trace-dir", "traces"],
          ["repl", "--manifest", "ptc.json", "--continue-on-error"],
          ["repl", "--manifest", "ptc.json", "--private-unattended"],
          ["repl", "--manifest", "ptc.json", "--format", "jsonl"],
          ["repl", "--host-config", "host.json"],
          ["repl", "--resource", "traces=traces"],
          ["repl", "--session-trace-dir", "traces"],
          ["repl", "--continue-on-error"],
          ["repl", "--private-unattended"],
          ["repl", "--format", "jsonl"]
        ] do
      assert {:error, rejection} = CommandParser.parse(argv)
      assert rejection.command == :repl
      assert rejection.code == :invalid_arguments
    end
  end

  test "Mix help and rejections include the declared frontend-only authorization switch" do
    assert {:ok, arguments} = CommandParser.parse(["help", "run"], :mix)

    result = CommandContract.help_result(arguments.options.topic, arguments.frontend)

    assert Enum.any?(result["options"], fn option ->
             option["switches"] == ["--authorize-mcp NAME"]
           end)

    assert {:error, rejection} =
             CommandParser.parse(["run", "ptc.json", "--unknown"], :mix)

    assert "--authorize-mcp" in rejection.accepted

    assert {:error, standalone} =
             CommandParser.parse(["run", "ptc.json", "--authorize-mcp", "workspace"])

    assert standalone.kind == :unknown_switch
    refute "--authorize-mcp" in standalone.accepted
  end

  test "every catalog row renders with its generated schema constants" do
    assert {:ok, root} =
             JSV.build(
               CommandContract.catalog_diagnostic_schema(),
               atoms: false,
               warnings: :silent
             )

    for row <- DiagnosticCatalog.rows() do
      diagnostic = diagnostic_for_row(row)

      rendered = CommandDiagnostic.to_map(diagnostic)

      assert diagnostic.exit_status == row.exit_status
      assert rendered["retryable"] == row.retryable
      assert rendered["message"] == row.message
      assert {:ok, _validated} = JSV.validate(rendered, root, cast: false)
    end
  end

  test "run failures always carry their closed run-only fields" do
    diagnostic = CommandDiagnostic.new!(:arguments, :invalid_arguments)
    run_ref = CommandRunRef.encode(@zero_entropy)
    outcome = CommandOutcome.error(:run, run_ref, diagnostic)

    assert outcome.envelope["artifact_class"] == "unclassified"

    assert outcome.envelope["artifact_state"] == %{
             "trace" => "not_requested",
             "inspection" => "not_requested",
             "result" => "not_requested"
           }

    assert outcome.envelope["execution"] == %{"state" => "not_started"}
    assert_schema_valid(outcome.envelope)
  end

  test "unclassified run failures reject diagnostics from later phases" do
    run_ref = CommandRunRef.encode(@zero_entropy)
    early = CommandDiagnostic.new!(:arguments, :invalid_arguments)
    late = CommandDiagnostic.new!(:publication, :result_publication_failed)

    provider_active_internal =
      CommandDiagnostic.new!(:internal, :internal_error,
        source: CommandSource.fixed(:runtime),
        provider_activity: true
      )

    assert_raise ArgumentError, fn ->
      CommandOutcome.error(:run, run_ref, late)
    end

    assert_raise ArgumentError, fn ->
      CommandOutcome.error(:run, run_ref, provider_active_internal)
    end

    secondary =
      [provider_active_internal]
      |> :erlang.term_to_binary()
      |> :erlang.binary_to_term()

    assert_raise ArgumentError, fn ->
      CommandOutcome.error(:run, run_ref, early, secondary)
    end

    early_outcome = CommandOutcome.error(:run, run_ref, early)

    assert_schema_invalid(
      put_in(early_outcome.envelope, ["error"], CommandDiagnostic.to_map(late))
    )

    assert_schema_invalid(
      put_in(
        early_outcome.envelope,
        ["error"],
        CommandDiagnostic.to_map(provider_active_internal)
      )
    )

    assert_schema_invalid(
      put_in(
        early_outcome.envelope,
        ["secondary_errors"],
        [CommandDiagnostic.to_map(provider_active_internal)]
      )
    )

    assert_schema_invalid(
      put_in(
        early_outcome.envelope,
        ["secondary_errors"],
        [CommandDiagnostic.to_map(early)]
      )
    )
  end

  test "compound outcomes reject duplicate and out-of-precedence diagnostics" do
    cleanup =
      CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_timeout, provider_activity: true)

    internal =
      CommandDiagnostic.new!(:internal, :internal_error,
        source: CommandSource.fixed(:runtime),
        provider_activity: true
      )

    execution =
      CommandDiagnostic.new!(:execution, :workflow_failed,
        source: CommandSource.fixed(:runtime),
        provider_activity: true
      )

    assert CommandOutcome.valid_compound_diagnostics?(cleanup, [internal, execution])

    for secondary <- [
          [cleanup],
          [internal, internal],
          [execution, internal]
        ] do
      refute CommandOutcome.valid_compound_diagnostics?(cleanup, secondary)
    end
  end

  test "compound provider diagnostics use alias, destination, index, and operation order" do
    cleanup_timeout =
      CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_timeout, provider_activity: true)

    cleanup_failed =
      CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_failed, provider_activity: true)

    {:ok, alpha_mission_subject} =
      CommandSubject.provider("alpha", :local, %{destination: :mission, index: 9})

    {:ok, zeta_workflow_subject} =
      CommandSubject.provider("zeta", :local, %{destination: :workflow, index: 0})

    alpha =
      CommandDiagnostic.new!(:local_preflight, :adapter_unavailable,
        subject: alpha_mission_subject
      )

    zeta =
      CommandDiagnostic.new!(:local_preflight, :adapter_unavailable,
        subject: zeta_workflow_subject
      )

    refute CommandOutcome.valid_compound_diagnostics?(cleanup_timeout, [cleanup_failed])
    refute CommandOutcome.valid_compound_diagnostics?(cleanup_timeout, [alpha, zeta])
    refute CommandOutcome.valid_compound_diagnostics?(cleanup_timeout, [zeta, alpha])

    {:ok, workflow_subject} =
      CommandSubject.provider("same", :local, %{destination: :workflow, index: 8})

    {:ok, mission_subject} =
      CommandSubject.provider("same", :local, %{destination: :mission, index: 0})

    workflow =
      CommandDiagnostic.new!(:local_preflight, :adapter_unavailable, subject: workflow_subject)

    mission =
      CommandDiagnostic.new!(:local_preflight, :adapter_unavailable, subject: mission_subject)

    refute CommandOutcome.valid_compound_diagnostics?(cleanup_timeout, [workflow, mission])

    {:ok, authorization_subject} =
      CommandSubject.provider("same", :authorization)

    {:ok, acquisition_subject} =
      CommandSubject.provider("same", :acquisition, %{destination: :workflow, index: 0})

    authorization =
      CommandDiagnostic.new!(:active_preflight, :authentication_rejected,
        subject: authorization_subject,
        provider_activity: true
      )

    acquisition =
      CommandDiagnostic.new!(:active_preflight, :authentication_rejected,
        subject: acquisition_subject,
        provider_activity: true
      )

    refute CommandOutcome.valid_compound_diagnostics?(cleanup_timeout, [
             authorization,
             acquisition
           ])

    refute CommandOutcome.valid_compound_diagnostics?(cleanup_timeout, [
             acquisition,
             authorization
           ])

    execution =
      CommandDiagnostic.new!(:execution, :workflow_failed,
        source: CommandSource.fixed(:runtime),
        provider_activity: true
      )

    refute CommandOutcome.valid_compound_diagnostics?(cleanup_timeout, [execution, alpha])

    trace_publication =
      CommandDiagnostic.new!(:publication, :trace_publication_failed, provider_activity: true)

    inspection_publication =
      CommandDiagnostic.new!(:publication, :inspection_publication_failed,
        provider_activity: true
      )

    refute CommandOutcome.valid_compound_diagnostics?(cleanup_timeout, [
             trace_publication,
             inspection_publication
           ])
  end

  test "success construction rejects results outside the command schema" do
    run_ref = CommandRunRef.encode(@zero_entropy)

    host_revision = String.duplicate("r", 128)

    host_document = %{
      "credentials" => %{"key" => %{"env" => "KEY"}},
      "install" => %{
        "model" => %{
          "source" => "llm",
          "model" => "provider:model",
          "credential" => "key",
          "installation_revision" => host_revision
        }
      }
    }

    assert {:ok, %{install: %{"model" => %{installation_revision: ^host_revision}}}} =
             HostConfig.decode(host_document, "/tmp")

    model = put_in(model_result("model"), ["installation_revision"], host_revision)

    assert %CommandOutcome{} =
             CommandOutcome.success(:models, run_ref, %{"installations" => [model]})

    for invalid_revision <- [
          String.duplicate("a", 129),
          String.duplicate("😀", 65),
          "Upper",
          "revision/slash",
          "revision\0"
        ] do
      invalid_host =
        put_in(host_document, ["install", "model", "installation_revision"], invalid_revision)

      assert {:error, :invalid_host_config} = HostConfig.decode(invalid_host, "/tmp")

      invalid_model =
        put_in(model_result("model"), ["installation_revision"], invalid_revision)

      assert_raise ArgumentError, fn ->
        CommandOutcome.success(:models, run_ref, %{"installations" => [invalid_model]})
      end
    end

    for result <- [%{}, %{"version" => self()}, %{version: "0.13.0"}, %{"version" => "9.9.9"}] do
      assert_raise ArgumentError, fn ->
        CommandOutcome.success(:version, run_ref, result)
      end
    end

    assert_raise ArgumentError, fn ->
      CommandOutcome.success(:help, run_ref, %{
        "topic" => "root",
        "usage" => ["fabricated usage"],
        "notices" => []
      })
    end

    for result <- [
          %{
            "checks" => [%{"name" => "runtime", "status" => "pass", "code" => "available"}],
            "provider_activity" => false
          },
          %{
            "checks" => [
              %{"name" => "provider/not-safe!/local", "status" => "pass", "code" => "available"}
            ],
            "provider_activity" => false
          },
          %{
            "checks" => [
              %{"name" => "viewer", "status" => "pass", "code" => "available"},
              %{"name" => "runtime", "status" => "pass", "code" => "supported"},
              %{"name" => "application", "status" => "skipped", "code" => "not_requested"}
            ],
            "provider_activity" => false
          }
        ] do
      assert_raise ArgumentError, fn ->
        CommandOutcome.success(:doctor, run_ref, result)
      end
    end

    assert_raise ArgumentError, fn ->
      CommandOutcome.success(:models, run_ref, %{
        "installations" => [
          model_result("zeta"),
          model_result("alpha")
        ]
      })
    end

    fixed_doctor_checks = [
      %{"name" => "runtime", "status" => "pass", "code" => "supported"},
      %{"name" => "application", "status" => "skipped", "code" => "not_requested"},
      %{"name" => "viewer", "status" => "pass", "code" => "available"}
    ]

    application_doctor_checks =
      List.replace_at(
        fixed_doctor_checks,
        1,
        %{"name" => "application", "status" => "pass", "code" => "valid"}
      )

    refute CommandContract.valid_success_semantics?(:doctor, %{
             "checks" => fixed_doctor_checks,
             "provider_activity" => true
           })

    doctor_without_local = %{
      "checks" =>
        fixed_doctor_checks ++
          [
            %{
              "name" => "provider/alpha/connectivity",
              "status" => "pass",
              "code" => "available"
            }
          ],
      "provider_activity" => true
    }

    refute CommandContract.valid_success_semantics?(:doctor, doctor_without_local)

    local_only_application_doctor = %{
      "checks" =>
        application_doctor_checks ++
          [
            %{
              "name" => "provider/alpha/local",
              "status" => "pass",
              "code" => "available"
            }
          ],
      "provider_activity" => false
    }

    refute CommandContract.valid_success_semantics?(:doctor, local_only_application_doctor)

    valid_doctor =
      CommandOutcome.success(:doctor, run_ref, %{
        "checks" =>
          application_doctor_checks ++
            [
              %{
                "name" => "provider/alpha/local",
                "status" => "pass",
                "code" => "available"
              },
              %{
                "name" => "provider/alpha/selection",
                "status" => "pass",
                "code" => "declarative"
              }
            ],
        "provider_activity" => false
      })

    active_doctor_result = %{
      "checks" => [
        %{"name" => "runtime", "status" => "pass", "code" => "supported"},
        %{"name" => "application", "status" => "pass", "code" => "valid"},
        %{"name" => "viewer", "status" => "pass", "code" => "available"},
        %{"name" => "provider/alpha/local", "status" => "pass", "code" => "available"},
        %{
          "name" => "provider/alpha/selection",
          "status" => "pass",
          "code" => "available"
        },
        %{
          "name" => "provider/alpha/connectivity",
          "status" => "pass",
          "code" => "available"
        }
      ],
      "provider_activity" => true
    }

    assert_raise ArgumentError, fn ->
      CommandOutcome.success(:doctor, run_ref, active_doctor_result)
    end

    assert %CommandOutcome{command_mode: {:doctor, :connect}} =
             CommandOutcome.success({:doctor, :connect}, run_ref, active_doctor_result)

    provider_free_connect_result = %{
      "checks" => [
        %{"name" => "runtime", "status" => "pass", "code" => "supported"},
        %{"name" => "application", "status" => "pass", "code" => "valid"},
        %{"name" => "viewer", "status" => "pass", "code" => "available"}
      ],
      "provider_activity" => false
    }

    assert %CommandOutcome{command_mode: {:doctor, :connect}} =
             CommandOutcome.success(
               {:doctor, :connect},
               run_ref,
               provider_free_connect_result
             )

    impossible_default_results = [
      %{
        "checks" => [
          %{"name" => "runtime", "status" => "pass", "code" => "supported"},
          %{"name" => "application", "status" => "pass", "code" => "valid"},
          %{"name" => "viewer", "status" => "pass", "code" => "available"},
          %{
            "name" => "provider/alpha/local",
            "status" => "skipped",
            "code" => "application_required"
          }
        ],
        "provider_activity" => false
      },
      %{
        "checks" => [
          %{"name" => "runtime", "status" => "pass", "code" => "supported"},
          %{
            "name" => "application",
            "status" => "skipped",
            "code" => "not_requested"
          },
          %{"name" => "viewer", "status" => "pass", "code" => "available"},
          %{"name" => "provider/alpha/local", "status" => "pass", "code" => "available"}
        ],
        "provider_activity" => false
      },
      %{
        "checks" => [
          %{"name" => "runtime", "status" => "pass", "code" => "supported"},
          %{
            "name" => "application",
            "status" => "skipped",
            "code" => "not_requested"
          },
          %{"name" => "viewer", "status" => "pass", "code" => "available"},
          %{
            "name" => "provider/alpha/local",
            "status" => "skipped",
            "code" => "application_required"
          },
          %{
            "name" => "provider/alpha/selection",
            "status" => "pass",
            "code" => "declarative"
          }
        ],
        "provider_activity" => false
      }
    ]

    for result <- impossible_default_results do
      assert_raise ArgumentError, fn ->
        CommandOutcome.success(:doctor, run_ref, result)
      end
    end

    assert CommandContract.valid_success_semantics?(:doctor, %{
             "checks" => valid_doctor.envelope["result"]["checks"],
             "provider_activity" => true
           })

    refute CommandContract.valid_success_semantics?(:doctor, %{
             "checks" =>
               application_doctor_checks ++
                 [
                   %{
                     "name" => "provider/alpha/local",
                     "status" => "pass",
                     "code" => "available"
                   },
                   %{
                     "name" => "provider/alpha/connectivity",
                     "status" => "pass",
                     "code" => "available"
                   }
                 ],
             "provider_activity" => false
           })

    refute CommandContract.valid_success_semantics?(:doctor, %{
             "checks" =>
               application_doctor_checks ++
                 [
                   %{
                     "name" => "provider/alpha/local",
                     "status" => "pass",
                     "code" => "available"
                   },
                   %{
                     "name" => "provider/alpha/selection",
                     "status" => "skipped",
                     "code" => "active_check_required"
                   }
                 ],
             "provider_activity" => true
           })

    assert_schema_invalid(
      put_in(valid_doctor.envelope, ["result", "checks"], [
        %{"name" => "provider/alpha/local", "status" => "pass", "code" => "available"}
      ])
    )

    refute CommandContract.valid_success_semantics?(:models, %{
             "installations" => [model_result("zeta"), model_result("alpha")]
           })
  end

  test "diagnostics reject private sources and overlong rendered paths" do
    assert {:error, :invalid_command_source} =
             CommandSource.new(:host, "/private/ptc-host.json")

    forged_source = %CommandSource{kind: :host, name: "/private/ptc-host.json"}

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:host, :host_invalid, source: forged_source)

    forged_diagnostic = %{
      CommandDiagnostic.new!(:host, :host_invalid, source: CommandSource.fixed(:host))
      | source: forged_source
    }

    assert_raise ArgumentError, fn ->
      CommandOutcome.error(:validate, CommandRunRef.encode(@zero_entropy), forged_diagnostic)
    end

    valid =
      CommandOutcome.error(
        :validate,
        CommandRunRef.encode(@zero_entropy),
        CommandDiagnostic.new!(:host, :host_invalid, source: CommandSource.fixed(:host))
      )

    privacy_invalid =
      put_in(valid.envelope, ["error", "source"], %{
        "kind" => "host",
        "name" => "/private/ptc-host.json"
      })

    assert_schema_invalid(privacy_invalid)

    overlong_path =
      List.duplicate({:property, String.duplicate("a", 1_024)}, 9)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :schema_violation,
               source: CommandSource.fixed(:application),
               path_segments: overlong_path
             )

    for property <- ["", "caller-secret", String.duplicate("a", 1_500)] do
      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:application, :schema_violation,
                 source: CommandSource.fixed(:application),
                 path_segments: [{:property, property}]
               )
    end

    assert {:ok, safe_path} = CommandPath.manifest([{:property, "events"}])

    assert {:ok, safe_diagnostic} =
             CommandDiagnostic.new(:application, :schema_violation,
               source: CommandSource.fixed(:application),
               path: safe_path
             )

    assert CommandDiagnostic.to_map(safe_diagnostic)["path"] == "/events"

    forged_path = %{safe_path | segments: [{:property, "caller-secret"}]}

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :schema_violation,
               source: CommandSource.fixed(:application),
               path: forged_path
             )

    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => %{"caller-secret" => %{"type" => "string"}}
             })

    {_classification, wrong_evidence} =
      ValueContract.classify_with_evidence(contract, %{"caller-secret" => 42})

    assert {:ok, wrong_contract_authority} =
             CommandContractAuthority.new(wrong_evidence)

    assert {:ok, wrong_authority} =
             CommandPath.contract(wrong_contract_authority, [{:property, "caller-secret"}])

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :schema_violation,
               source: CommandSource.fixed(:application),
               path: wrong_authority
             )

    assert {:ok, expected_contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => %{"question" => %{"type" => "string"}}
             })

    {_classification, expected_evidence} =
      ValueContract.classify_with_evidence(expected_contract, %{"question" => 42})

    assert {:ok, authority} = CommandContractAuthority.new(expected_evidence)

    assert {:ok, expected_path} =
             CommandPath.contract(authority, [{:property, "question"}])

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :input_contract_failed,
               source: CommandSource.fixed(:external_input),
               path: expected_path
             )

    refute CommandContractAuthority.valid?(%{
             authority
             | behavior_hash: String.duplicate("0", 64)
           })

    assert {:ok, expected_source} =
             CommandSource.with_contract(CommandSource.fixed(:external_input), authority)

    assert {:ok, expected_diagnostic} =
             CommandDiagnostic.new(:application, :input_contract_failed,
               source: expected_source,
               path: expected_path
             )

    assert CommandDiagnostic.to_map(expected_diagnostic)["path"] == "/question"

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :input_contract_failed,
               source: expected_source,
               path: wrong_authority
             )

    assert {:ok, union_contract} =
             ValueContract.compile(%{
               "oneOf" => [
                 %{
                   "type" => "object",
                   "properties" => %{
                     "kind" => %{"type" => "string", "const" => "left"},
                     "left" => %{"type" => "integer"}
                   },
                   "required" => ["kind", "left"]
                 },
                 %{
                   "type" => "object",
                   "properties" => %{
                     "kind" => %{"type" => "string", "const" => "right"},
                     "right" => %{"type" => "integer"}
                   },
                   "required" => ["kind", "right"]
                 }
               ]
             })

    assert {:error, {:input_contract_failed, left_classification}} =
             ExecutionInput.new(%{"kind" => "left", "left" => "wrong"}, :normal, union_contract)

    assert {:error, {:input_contract_failed, right_classification}} =
             ExecutionInput.new(
               %{"kind" => "right", "right" => "wrong"},
               :normal,
               union_contract
             )

    assert {:ok, left_path} =
             CommandPath.contract(left_classification.contract_authority, [
               {:property, "left"}
             ])

    assert {:ok, right_source} =
             CommandSource.with_contract(
               CommandSource.fixed(:external_input),
               right_classification.contract_authority
             )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :input_contract_failed,
               source: right_source,
               path: left_path
             )

    combining = "a" <> String.duplicate("\u0301", 10_000)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :schema_violation,
               source: CommandSource.fixed(:application),
               path_segments: [{:property, combining}]
             )

    combining_pointer = put_in(valid.envelope, ["error", "path"], "/" <> combining)
    assert_schema_invalid(combining_pointer)

    invalid_pointer = put_in(valid.envelope, ["error", "path"], "not/a/pointer")
    assert_schema_invalid(invalid_pointer)

    impossible_span =
      valid.envelope
      |> put_in(["error", "source"], nil)
      |> put_in(["error", "span"], %{"start_byte" => 0, "end_byte" => 0})

    assert_schema_invalid(impossible_span)
  end

  test "host diagnostics admit only host-schema-authorized paths" do
    assert {:ok, host_path} =
             CommandPath.host([
               {:property, "limits"},
               {:property, "run_duration_ms"}
             ])

    assert {:ok, diagnostic} =
             CommandDiagnostic.new(:host, :installed_limit_invalid,
               source: CommandSource.fixed(:host),
               path: host_path
             )

    assert CommandDiagnostic.to_map(diagnostic)["path"] == "/limits/run_duration_ms"

    refute get_in(HostConfig.schema(), ["properties", "caller-secret"])

    assert {:error, :invalid_command_path} =
             CommandPath.host([{:property, "caller-secret"}])
  end

  test "diagnostics enforce source, subject, activity, and span relationships" do
    assert {:error, :invalid_command_subject} =
             CommandSubject.provider("safe", :local, %{
               destination: :workflow,
               index: 0,
               hidden: true
             })

    assert {:error, :invalid_command_subject} =
             CommandSubject.provider("safe", :local, %{
               destination: :workflow,
               index: 32
             })

    {:ok, provider} =
      CommandSubject.provider("safe", :declaration, %{destination: :workflow, index: 0})

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:provider_declaration, :provider_unknown)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :schema_violation, subject: provider)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:provider_declaration, :provider_unknown,
               source: CommandSource.fixed(:application),
               subject: provider
             )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :schema_violation, provider_activity: true)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :invalid_json,
               source: CommandSource.fixed(:application),
               span: %{start_byte: 0, end_byte: 1}
             )

    bounded_source = CommandSource.with_bytes(:application, "ptc.json", "{}")

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :invalid_json,
               source: bounded_source,
               span: %{start_byte: 0, end_byte: 2, hidden: true}
             )

    assert {:ok, _diagnostic} =
             CommandDiagnostic.new(:application, :invalid_json,
               source: bounded_source,
               span: %{start_byte: 0, end_byte: 2}
             )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :invalid_json,
               source: bounded_source,
               span: %{start_byte: 0, end_byte: 3}
             )

    mutated_source = %{bounded_source | byte_size: 3}
    refute CommandSource.valid?(mutated_source)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:application, :invalid_json,
               source: mutated_source,
               span: %{start_byte: 0, end_byte: 3}
             )

    forged_source = %CommandSource{
      kind: :application,
      name: "ptc.json",
      byte_size: 3
    }

    refute CommandSource.valid?(forged_source)
    assert_raise ArgumentError, fn -> CommandSource.to_map(forged_source) end

    provider_outcome =
      CommandOutcome.error(
        :validate,
        CommandRunRef.encode(@zero_entropy),
        CommandDiagnostic.new!(:provider_declaration, :provider_unknown, subject: provider)
      )

    assert_schema_invalid(put_in(provider_outcome.envelope, ["error", "subject"], nil))

    assert_schema_invalid(
      put_in(provider_outcome.envelope, ["error", "subject", "occurrence", "index"], 32)
    )

    assert_schema_invalid(
      put_in(provider_outcome.envelope, ["error", "source"], %{
        "kind" => "application",
        "name" => "ptc.json"
      })
    )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:provider_declaration, :provider_unknown,
               path_segments: [{:property, "caller-secret"}],
               subject: provider
             )

    assert_schema_invalid(put_in(provider_outcome.envelope, ["error", "path"], "/caller-secret"))

    application_outcome =
      CommandOutcome.error(
        :validate,
        CommandRunRef.encode(@zero_entropy),
        CommandDiagnostic.new!(:application, :schema_violation,
          source: CommandSource.fixed(:application)
        )
      )

    assert_schema_invalid(
      put_in(application_outcome.envelope, ["error", "provider_activity"], true)
    )

    {:ok, declaration_subject} =
      CommandSubject.provider("safe", :declaration, nil)

    assert {:ok, installation_revision_missing} =
             CommandDiagnostic.new(:host, :installation_revision_missing,
               subject: declaration_subject
             )

    assert installation_revision_missing.source == nil

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:host, :installation_revision_missing)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:host, :installation_revision_missing,
               source: CommandSource.fixed(:host),
               subject: declaration_subject
             )

    {:ok, local_subject} =
      CommandSubject.provider("safe", :local, %{destination: :workflow, index: 0})

    # `local_preflight` is the one phase that spans the marker: the audited-local
    # step reports before activity and the `:unverified` step reports after it,
    # through the same codes. The phase therefore pins neither value and the flag
    # carries which side ran, so both constructions are valid here.
    for activity <- [false, true] do
      assert {:ok, %CommandDiagnostic{provider_activity: ^activity}} =
               CommandDiagnostic.new(:local_preflight, :adapter_unavailable,
                 subject: local_subject,
                 provider_activity: activity
               )
    end

    {:ok, application_subject} =
      CommandSubject.provider("safe", :application, nil)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:active_preflight, :provider_application_unavailable,
               subject: application_subject,
               provider_activity: false
             )

    assert {:ok, active_diagnostic} =
             CommandDiagnostic.new(:active_preflight, :provider_application_unavailable,
               subject: application_subject,
               provider_activity: true
             )

    active_outcome =
      CommandOutcome.error(
        {:doctor, :connect},
        CommandRunRef.encode(@zero_entropy),
        active_diagnostic
      )

    assert_schema_invalid(put_in(active_outcome.envelope, ["error", "provider_activity"], false))

    {:ok, acquisition_subject} =
      CommandSubject.provider("safe", :acquisition, %{destination: :workflow, index: 0})

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:provider_acquisition, :provider_unavailable,
               subject: acquisition_subject,
               provider_activity: false
             )

    for operation <- [:connectivity, :acquisition] do
      {:ok, subject_without_occurrence} = CommandSubject.provider("safe", operation, nil)

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:active_preflight, :authentication_rejected,
                 subject: subject_without_occurrence,
                 provider_activity: true
               )
    end

    {:ok, authorization_subject} =
      CommandSubject.provider("safe", :authorization, nil)

    assert {:ok, _diagnostic} =
             CommandDiagnostic.new(:active_preflight, :authentication_rejected,
               subject: authorization_subject,
               provider_activity: true
             )

    {:ok, connectivity_subject} =
      CommandSubject.provider("safe", :connectivity, %{destination: :workflow, index: 0})

    connectivity_diagnostic =
      CommandDiagnostic.new!(:active_preflight, :authentication_rejected,
        subject: connectivity_subject,
        provider_activity: true
      )

    connectivity_outcome =
      CommandOutcome.error(
        {:doctor, :connect},
        CommandRunRef.encode(@zero_entropy),
        connectivity_diagnostic
      )

    assert_schema_invalid(
      put_in(connectivity_outcome.envelope, ["error", "subject", "occurrence"], nil)
    )

    {:ok, execution_subject} =
      CommandSubject.provider("safe", :execution, %{destination: :workflow, index: 0})

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:execution, :provider_failed,
               subject: execution_subject,
               provider_activity: false
             )

    execution_diagnostic =
      CommandDiagnostic.new!(:execution, :provider_failed,
        subject: execution_subject,
        provider_activity: true
      )

    assert_raise ArgumentError, fn ->
      CommandOutcome.error(
        :validate,
        CommandRunRef.encode(@zero_entropy),
        execution_diagnostic
      )
    end

    for code <- [:provider_cleanup_failed, :provider_cleanup_timeout] do
      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:result_cleanup, code, provider_activity: false)

      cleanup = CommandDiagnostic.new!(:result_cleanup, code, provider_activity: true)

      assert_raise ArgumentError, fn ->
        CommandOutcome.error(
          :validate,
          CommandRunRef.encode(@zero_entropy),
          cleanup
        )
      end
    end
  end

  test "non-run commands reject diagnostics outside their exact phase and activity modes" do
    run_ref = CommandRunRef.encode(@zero_entropy)

    {:ok, dependency_subject} =
      CommandSubject.provider("safe", :declaration, nil)

    dependency_invalid =
      CommandDiagnostic.new!(:provider_declaration, :dependency_invalid,
        subject: dependency_subject
      )

    assert %CommandOutcome{} =
             models_error = CommandOutcome.error(:models, run_ref, dependency_invalid)

    assert models_error.envelope["error"]["subject"]["occurrence"] == nil
    assert_schema_valid(models_error.envelope)

    {:ok, selected_dependency_subject} =
      CommandSubject.provider("safe", :declaration, %{destination: :workflow, index: 0})

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:provider_declaration, :dependency_invalid,
               subject: selected_dependency_subject
             )

    {:ok, subject} =
      CommandSubject.provider("safe", :connectivity, %{destination: :workflow, index: 0})

    active =
      CommandDiagnostic.new!(:active_preflight, :connectivity_unavailable,
        subject: subject,
        provider_activity: true
      )

    for command <- [:help, :version, :init, :validate, :models, :doctor] do
      assert_raise ArgumentError, fn -> CommandOutcome.error(command, run_ref, active) end
    end

    assert %CommandOutcome{} = CommandOutcome.error({:doctor, :connect}, run_ref, active)

    manual = %{
      "schema_version" => 1,
      "command" => "validate",
      "status" => "error",
      "run_ref" => run_ref,
      "error" => CommandDiagnostic.to_map(active),
      "secondary_errors" => []
    }

    assert_schema_invalid(manual)

    impossible_pairs = [
      {:models,
       diagnostic_for_row(DiagnosticCatalog.fetch!(:provider_declaration, :provider_unknown))},
      {:models,
       diagnostic_for_row(
         DiagnosticCatalog.fetch!(:provider_declaration, :selection_unverifiable)
       )},
      {{:doctor, :connect},
       diagnostic_for_row(DiagnosticCatalog.fetch!(:result_cleanup, :result_invalid))},
      {:validate, diagnostic_for_row(DiagnosticCatalog.fetch!(:application, :override_invalid))},
      {:validate,
       diagnostic_for_row(DiagnosticCatalog.fetch!(:application, :event_identity_conflict))},
      {:help, diagnostic_for_row(DiagnosticCatalog.fetch!(:arguments, :conflicting_arguments))}
    ]

    for {command_mode, diagnostic} <- impossible_pairs do
      assert_raise ArgumentError, fn ->
        CommandOutcome.error(command_mode, run_ref, diagnostic)
      end

      manual = %{
        "schema_version" => 1,
        "command" =>
          case command_mode do
            {:doctor, :connect} -> "doctor"
            command -> Atom.to_string(command)
          end,
        "status" => "error",
        "run_ref" => run_ref,
        "error" => CommandDiagnostic.to_map(diagnostic),
        "secondary_errors" => []
      }

      assert_schema_invalid(manual)
    end

    cleanup =
      diagnostic_for_row(DiagnosticCatalog.fetch!(:result_cleanup, :provider_cleanup_failed))

    assert %CommandOutcome{} =
             CommandOutcome.error({:doctor, :connect}, run_ref, cleanup)
  end

  test "commands that stop before compound work reject secondary diagnostics" do
    run_ref = CommandRunRef.encode(@zero_entropy)
    internal = diagnostic_for_row(DiagnosticCatalog.fetch!(:internal, :internal_error))

    publication =
      diagnostic_for_row(DiagnosticCatalog.fetch!(:publication, :initialization_failed))

    assert_raise ArgumentError, fn ->
      CommandOutcome.error(:init, run_ref, internal, [publication])
    end

    envelope =
      :init
      |> CommandOutcome.error(run_ref, internal)
      |> CommandOutcome.to_map()
      |> Map.put("secondary_errors", [CommandDiagnostic.to_map(publication)])

    assert_schema_invalid(envelope)
  end

  test "command outcomes reject forged envelopes, statuses, and undeclared fields" do
    outcome =
      CommandOutcome.error(
        :validate,
        CommandRunRef.encode(@zero_entropy),
        CommandDiagnostic.new!(:arguments, :invalid_arguments)
      )

    secret_envelope = Map.put(outcome.envelope, "secret", "must-not-render")

    for forged <- [
          %{outcome | envelope: secret_envelope},
          %{outcome | exit_status: 70},
          Map.put(outcome, :private_state, "must-not-render")
        ] do
      refute CommandOutcome.valid?(forged)

      assert_raise ArgumentError, fn ->
        CommandOutcome.to_map(forged)
      end
    end

    assert CommandOutcome.valid?(outcome)
    assert CommandOutcome.to_map(outcome) == outcome.envelope
  end

  test "finished execution schema binds outcomes to diagnostics" do
    run_ref = CommandRunRef.encode(@zero_entropy)
    top_level = CommandDiagnostic.new!(:publication, :result_publication_failed)
    execution = CommandDiagnostic.new!(:execution, :workflow_failed)

    finished_ok = %{
      "state" => "finished",
      "outcome" => "ok",
      "diagnostic" => nil,
      "usage" => usage_fixture(),
      "evaluation_memory" => evaluation_memory_fixture()
    }

    classified = %{
      "schema_version" => 1,
      "command" => "run",
      "status" => "error",
      "run_ref" => run_ref,
      "error" => CommandDiagnostic.to_map(top_level),
      "secondary_errors" => [],
      "artifact_state" => %{
        "trace" => "not_requested",
        "inspection" => "not_requested",
        "result" => "not_requested"
      },
      "artifact_class" => "normal",
      "execution" => finished_ok
    }

    assert_schema_valid(classified)

    preclassification = CommandDiagnostic.new!(:arguments, :invalid_arguments)

    assert_schema_invalid(
      put_in(classified, ["error"], CommandDiagnostic.to_map(preclassification))
    )

    assert_schema_invalid(
      put_in(
        classified,
        ["secondary_errors"],
        [CommandDiagnostic.to_map(preclassification)]
      )
    )

    assert_schema_invalid(
      put_in(classified, ["execution", "usage", "capability_calls"], %{"unsafe name" => 1})
    )

    assert_schema_invalid(
      put_in(classified, ["execution", "usage", "events_dropped"], %{"workflow/read" => 1})
    )

    assert_schema_valid(
      put_in(classified, ["execution", "usage", "events_dropped"], %{"$overflow" => 1})
    )

    assert_schema_invalid(
      put_in(classified, ["execution"], %{
        finished_ok
        | "diagnostic" => CommandDiagnostic.to_map(execution)
      })
    )

    finished_error = %{
      finished_ok
      | "outcome" => "error",
        "diagnostic" => CommandDiagnostic.to_map(execution)
    }

    assert_schema_valid(put_in(classified, ["execution"], finished_error))

    assert_schema_invalid(
      put_in(classified, ["execution"], %{
        finished_error
        | "diagnostic" => CommandDiagnostic.to_map(preclassification)
      })
    )

    assert_schema_invalid(
      put_in(classified, ["execution"], %{finished_error | "diagnostic" => nil})
    )
  end

  test "run schema binds result privacy and recovery states to their legal fields" do
    normal =
      run_success_fixture("normal", %{"result_class" => "normal", "value" => %{"ok" => true}})

    private =
      "private"
      |> run_success_fixture(%{"result_class" => "private"})
      |> put_in(["artifact_state", "result"], "written")

    assert_schema_valid(normal)
    assert_schema_valid(private)
    assert_schema_invalid(%{normal | "artifact_class" => "private"})
    assert_schema_invalid(%{private | "artifact_class" => "normal"})

    for artifact <- ["trace", "inspection", "result"],
        state <- ["not_written", "recovery_written", "finalization_uncertain", "failed"] do
      assert_schema_invalid(put_in(normal, ["artifact_state", artifact], state))
    end

    assert_schema_valid(put_in(normal, ["artifact_state", "result"], "written"))
    assert_schema_invalid(put_in(private, ["artifact_state", "result"], "not_requested"))
  end

  test "classified recovery states require a recovery-capable failure" do
    run_ref = CommandRunRef.encode(@zero_entropy)
    execution = CommandDiagnostic.new!(:execution, :workflow_failed)
    internal = CommandDiagnostic.new!(:internal, :internal_error)
    trace_publication = CommandDiagnostic.new!(:publication, :trace_publication_failed)
    result_publication = CommandDiagnostic.new!(:publication, :result_publication_failed)

    envelope = %{
      "schema_version" => 1,
      "command" => "run",
      "status" => "error",
      "run_ref" => run_ref,
      "error" => CommandDiagnostic.to_map(execution),
      "secondary_errors" => [],
      "artifact_state" => %{
        "trace" => "not_requested",
        "inspection" => "not_requested",
        "result" => "recovery_written"
      },
      "artifact_class" => "normal",
      "execution" => %{"state" => "not_started"}
    }

    assert_schema_invalid(envelope)
    assert_schema_invalid(%{envelope | "error" => CommandDiagnostic.to_map(internal)})

    assert_schema_valid(%{
      envelope
      | "error" => CommandDiagnostic.to_map(trace_publication)
    })

    assert_schema_valid(%{
      envelope
      | "secondary_errors" => [CommandDiagnostic.to_map(result_publication)]
    })

    uncertain = put_in(envelope, ["artifact_state", "result"], "finalization_uncertain")
    assert_schema_invalid(%{uncertain | "error" => CommandDiagnostic.to_map(internal)})
    assert_schema_invalid(%{uncertain | "error" => CommandDiagnostic.to_map(trace_publication)})
    assert_schema_valid(%{uncertain | "error" => CommandDiagnostic.to_map(result_publication)})

    assert_schema_invalid(put_in(envelope, ["artifact_state", "trace"], "finalization_uncertain"))
  end

  test "command schema identifier patterns reject trailing newlines" do
    run_ref = CommandRunRef.encode(@zero_entropy)
    diagnostic = CommandDiagnostic.new!(:arguments, :invalid_arguments)
    outcome = CommandOutcome.error(:validate, run_ref, diagnostic)
    assert_schema_invalid(%{outcome.envelope | "run_ref" => run_ref <> "\n"})

    {:ok, subject} =
      CommandSubject.provider("safe", :declaration, %{destination: :workflow, index: 0})

    provider =
      CommandOutcome.error(
        :validate,
        run_ref,
        CommandDiagnostic.new!(:provider_declaration, :provider_unknown, subject: subject)
      )

    assert_schema_invalid(put_in(provider.envelope, ["error", "subject", "name"], "safe\n"))

    result = %{
      "application_content_digest" => "sha256:" <> String.duplicate("0", 64),
      "effective_application_digest" => "sha256:" <> String.duplicate("1", 64),
      "workflow_bundle_hash" => String.duplicate("2", 64),
      "mission_bundle_hash" => nil,
      "provider_activity" => false
    }

    validate = CommandOutcome.success(:validate, run_ref, result)

    for field <- [
          "application_content_digest",
          "effective_application_digest",
          "workflow_bundle_hash"
        ] do
      assert_schema_invalid(put_in(validate.envelope, ["result", field], result[field] <> "\n"))
    end
  end

  test "an unknown command has one exact schema-valid phase-1 outcome" do
    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["explode"])

    assert outcome.exit_status == 2

    assert outcome.envelope == %{
             "schema_version" => 1,
             "command" => "unknown",
             "status" => "error",
             "run_ref" => outcome.envelope["run_ref"],
             "error" => %{
               "phase" => "arguments",
               "code" => "invalid_command",
               "message" => "use one of the supported commands",
               "source" => nil,
               "path" => nil,
               "span" => nil,
               "subject" => nil,
               "notes" => [],
               "retryable" => false,
               "provider_activity" => false
             },
             "secondary_errors" => []
           }

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "provider-free failures in phases 2 through 5 are closed and path-free", %{
    tmp_dir: directory
  } do
    missing_host = Path.join(directory, "missing-host.json")
    valid = write_application(directory, "valid", valid_manifest())

    assert_error(
      ["validate", valid, "--host-config", missing_host],
      "host",
      "host_unavailable"
    )

    invalid_json = write_application(directory, "invalid-json", "{")
    assert_error(["validate", invalid_json], "application", "invalid_json")

    missing_application = Path.join([directory, "missing-application", "ptc.json"])

    assert_error(
      ["validate", missing_application],
      "application",
      "application_unavailable"
    )

    missing_required =
      write_application(directory, "missing-required", Jason.encode!(%{"version" => 1}))

    required =
      assert_error(["validate", missing_required], "application", "required_property_missing")

    assert required.envelope["error"]["path"] == "/workflow"

    missing_workflow_entry =
      write_application(
        directory,
        "missing-workflow-entry",
        valid_manifest(%{"workflow" => %{"components" => []}})
      )

    missing_entry =
      assert_error(
        ["validate", missing_workflow_entry],
        "application",
        "required_property_missing"
      )

    assert missing_entry.envelope["error"]["path"] == "/workflow/entry"

    unknown_property =
      write_application(
        directory,
        "unknown-property",
        valid_manifest(%{"caller-secret" => "must-not-escape"})
      )

    unknown =
      assert_error(["validate", unknown_property], "application", "schema_violation")

    assert unknown.envelope["error"]["path"] == ""
    refute Jason.encode!(unknown.envelope) =~ "caller-secret"
    refute Jason.encode!(unknown.envelope) =~ "must-not-escape"

    for {name, input, expected_path} <- [
          {"invalid-input-value", %{"value" => []}, [{:property, "input"}, {:property, "value"}]},
          {"invalid-input-path", %{"path" => 42}, [{:property, "input"}, {:property, "path"}]},
          {"empty-input", %{}, [{:property, "input"}]}
        ] do
      manifest = valid_manifest(%{"input" => input})
      malformed_input = write_application(directory, name, manifest)

      outcome =
        assert_error(["validate", malformed_input], "application", "schema_violation")

      expected_pointer =
        Enum.map_join(expected_path, "", fn {:property, property} -> "/#{property}" end)

      assert outcome.envelope["error"]["path"] == expected_pointer

      documents = %{
        "ptc.json" => Jason.encode!(manifest),
        "main.clj" => "(ns app) (defn run [input] (return input))"
      }

      assert {:error, {:manifest_path, ^expected_path, :invalid_input_declaration}} =
               ApplicationPackage.request_memory(
                 "ptc.json",
                 documents,
                 result_projection: :json
               )
    end

    missing_component_path =
      write_application(
        directory,
        "missing-component-path",
        valid_manifest(%{
          "workflow" => %{
            "components" => [%{"id" => "app"}],
            "entry" => "app/run"
          }
        })
      )

    nested_required =
      assert_error(
        ["validate", missing_component_path],
        "application",
        "required_property_missing"
      )

    assert nested_required.envelope["error"]["path"] == "/workflow/components/0/path"

    missing_dependency =
      valid_manifest(%{
        "workflow" => %{
          "components" => [
            %{"id" => "app", "path" => "main.clj", "dependencies" => ["missing"]}
          ],
          "entry" => "app/run"
        }
      })

    invalid_bundle = write_application(directory, "invalid-bundle", missing_dependency)
    assert_error(["validate", invalid_bundle], "bundle", "bundle_invalid")

    assert {:ok, request} =
             ApplicationPackage.request_directory(invalid_bundle, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()

    assert {:error, %CommandDiagnostic{phase: :bundle, code: :bundle_invalid}} =
             RunBuilder.build(request, registry)

    for {name, source} <- [
          {"constant-entry", "(ns app) (def run 1)"},
          {"zero-arity-entry", "(ns app) (defn run [] (return 1))"},
          {"two-arity-entry", "(ns app) (defn run [first second] (return first))"}
        ] do
      application =
        write_application(directory, name, valid_manifest(), %{"main.clj" => source})

      assert_error(["validate", application], "bundle", "entry_invalid")

      assert {:ok, request} =
               ApplicationPackage.request_directory(application, result_projection: :json)

      assert {:error, %CommandDiagnostic{phase: :bundle, code: :entry_invalid}} =
               RunBuilder.build(request, registry)
    end

    parent = self()

    builder = fn _config, _context ->
      send(parent, :invalid_entry_provider_invoked)
      {:error, :should_not_run}
    end

    assert {:ok, provider_registry} = ProviderRegistry.new(%{"probe" => builder})

    provider_manifest =
      valid_manifest(%{
        "providers" => %{
          "workflow" => [%{"name" => "probe", "config" => %{}}],
          "mission" => []
        }
      })

    provider_application =
      write_application(directory, "provider-invalid-entry", provider_manifest, %{
        "main.clj" => "(ns app) (defn run [] (return 1))"
      })

    assert {:ok, provider_request} =
             ApplicationPackage.request_directory(provider_application,
               result_projection: :json
             )

    assert {:error, %CommandDiagnostic{phase: :bundle, code: :entry_invalid}} =
             RunBuilder.build(provider_request, provider_registry)

    refute_receive :invalid_entry_provider_invoked

    assert {:error, :invalid_execution_policy} =
             RunBuilder.build(request, registry,
               inspect: Path.join(directory, "unexpected-inspection.jsonl")
             )

    occupied = Path.join(directory, "occupied-inspection.jsonl")
    File.write!(occupied, "occupied")

    assert {:ok, inspection_request} =
             ApplicationPackage.request_directory(invalid_bundle,
               result_projection: :json,
               inspection_capture: true
             )

    assert {:error, %CommandDiagnostic{phase: :bundle, code: :bundle_invalid}} =
             RunBuilder.build(inspection_request, registry, inspect: occupied)

    unknown_provider =
      valid_manifest(%{
        "providers" => %{
          "workflow" => [%{"name" => "missing", "config" => %{}}],
          "mission" => []
        }
      })

    unknown = write_application(directory, "unknown-provider", unknown_provider)
    outcome = assert_error(["validate", unknown], "provider_declaration", "provider_unknown")

    assert outcome.envelope["error"]["subject"] == %{
             "kind" => "provider",
             "name" => "missing",
             "operation" => "declaration",
             "occurrence" => %{"destination" => "workflow", "index" => 0}
           }

    for outcome <- [required, outcome] do
      encoded = Jason.encode!(outcome.envelope)
      refute encoded =~ directory
      assert outcome.envelope["error"]["provider_activity"] == false
      assert_schema_valid(outcome.envelope)
    end
  end

  @tag :tmp_dir
  test "phase-2 host loading preserves every closed host diagnostic", %{tmp_dir: directory} do
    application = write_application(directory, "host-diagnostics", valid_manifest())
    base = valid_host_config()

    malformed_path = write_host_config(directory, "malformed", "{")

    malformed =
      assert_error(
        ["validate", application, "--host-config", malformed_path],
        "host",
        "host_invalid"
      )

    assert malformed.envelope["error"]["source"] == %{"kind" => "host", "name" => "ptc-host.json"}

    for {name, bytes} <- [
          {"too-deep", String.duplicate("[", 65) <> String.duplicate("]", 65)},
          {"too-many-nodes", "[" <> String.duplicate("0,", 100_000) <> "0]"}
        ] do
      host_path = write_host_config(directory, name, bytes)

      outcome =
        assert_error(
          ["validate", application, "--host-config", host_path],
          "host",
          "host_invalid"
        )

      assert outcome.envelope["error"]["source"] == %{"kind" => "host", "name" => "ptc-host.json"}
    end

    schema_path =
      write_host_config(
        directory,
        "schema",
        put_in(base, ["runtime"], %{"stdio_launcher" => "relative"})
      )

    schema =
      assert_error(
        ["validate", application, "--host-config", schema_path],
        "host",
        "host_schema_invalid"
      )

    assert schema.envelope["error"]["path"] == "/runtime/stdio_launcher"
    assert schema.envelope["error"]["source"] == %{"kind" => "host", "name" => "ptc-host.json"}

    missing_revision_path =
      write_host_config(
        directory,
        "missing-revision",
        update_in(base, ["install", "workspace"], &Map.delete(&1, "installation_revision"))
      )

    missing_revision =
      assert_error(
        ["validate", application, "--host-config", missing_revision_path],
        "host",
        "installation_revision_missing"
      )

    assert missing_revision.envelope["error"]["source"] == nil

    assert missing_revision.envelope["error"]["subject"] == %{
             "kind" => "provider",
             "name" => "workspace",
             "operation" => "declaration",
             "occurrence" => nil
           }

    invalid_alias_path =
      write_host_config(directory, "invalid-alias", %{
        "install" => %{"BAD" => %{"source" => "mcp"}}
      })

    invalid_alias =
      assert_error(
        ["validate", application, "--host-config", invalid_alias_path],
        "host",
        "host_schema_invalid"
      )

    refute invalid_alias.envelope["error"]["code"] == "internal_error"

    dangling_credential =
      write_host_config(directory, "dangling-credential", %{
        "install" => %{
          "model" => %{
            "source" => "llm",
            "installation_revision" => "model-v1",
            "model" => "provider:model",
            "credential" => "missing"
          }
        }
      })

    dangling =
      assert_error(
        ["validate", application, "--host-config", dangling_credential],
        "host",
        "host_invalid"
      )

    assert dangling.envelope["error"]["path"] == nil
    assert dangling.envelope["error"]["source"] == %{"kind" => "host", "name" => "ptc-host.json"}

    limit_path =
      write_host_config(
        directory,
        "limit",
        put_in(base, ["limits"], %{"run_duration_ms" => 0})
      )

    limit =
      assert_error(
        ["validate", application, "--host-config", limit_path],
        "host",
        "installed_limit_invalid"
      )

    assert limit.envelope["error"]["path"] == "/limits/run_duration_ms"
    assert limit.envelope["error"]["source"] == %{"kind" => "host", "name" => "ptc-host.json"}

    for {limit_name, invalid_value} <- [
          {"provider_cleanup_timeout_ms", 99},
          {"selection_validation_timeout_ms", 30_001},
          {"doctor_connectivity_timeout_ms", 99}
        ] do
      host_path =
        write_host_config(
          directory,
          "operational-limit-#{limit_name}",
          put_in(base, ["limits"], %{limit_name => invalid_value})
        )

      outcome =
        assert_error(
          ["validate", application, "--host-config", host_path],
          "host",
          "installed_limit_invalid"
        )

      assert outcome.envelope["error"]["path"] == "/limits/#{limit_name}"
      assert outcome.envelope["error"]["provider_activity"] == false

      assert outcome.envelope["error"]["source"] == %{
               "kind" => "host",
               "name" => "ptc-host.json"
             }
    end

    for {name, malformed_limits} <- [
          {"non-object", []},
          {"unknown-key", %{"caller-secret" => 1}}
        ] do
      host_path =
        write_host_config(
          directory,
          "structural-limits-#{name}",
          put_in(base, ["limits"], malformed_limits)
        )

      outcome =
        assert_error(
          ["validate", application, "--host-config", host_path],
          "host",
          "host_schema_invalid"
        )

      assert outcome.envelope["error"]["path"] == "/limits"
      refute Jason.encode!(outcome.envelope) =~ "caller-secret"
    end
  end

  @tag :tmp_dir
  test "host duplicate properties retain their schema-authorized parent", %{tmp_dir: directory} do
    application = write_application(directory, "host-duplicate-paths", valid_manifest())

    for {name, bytes, expected_path} <- [
          {"root", ~S|{"install":{},"install":{}}|, ""},
          {"runtime",
           ~S|{"install":{},"runtime":{"stdio_launcher":"/bin/true","stdio_launcher":"/bin/true"}}|,
           "/runtime"}
        ] do
      host_path = write_host_config(directory, "duplicate-#{name}", bytes)

      outcome =
        assert_error(
          ["validate", application, "--host-config", host_path],
          "host",
          "host_schema_invalid"
        )

      assert outcome.envelope["error"]["path"] == expected_path
      assert outcome.envelope["error"]["source"] == %{"kind" => "host", "name" => "ptc-host.json"}
    end
  end

  @tag :tmp_dir
  test "nested manifest structures retain safe section paths across adapters", %{
    tmp_dir: directory
  } do
    cases = [
      {["workflow"],
       %{"workflow" => %{"components" => [], "entry" => "app/run", "extra" => true}}},
      {["mission"], %{"mission" => %{"extra" => true}}},
      {["input"], %{"input" => %{"value" => %{}, "extra" => true}}},
      {["input"], %{"input" => %{"caller-secret" => 1}}},
      {["contracts"], %{"contracts" => %{"extra" => true}}},
      {["providers"], %{"providers" => %{"workflow" => [], "mission" => [], "extra" => true}}},
      {["providers", "workflow", 0],
       %{
         "providers" => %{
           "workflow" => [%{"name" => "missing", "config" => %{}, "extra" => true}],
           "mission" => []
         }
       }},
      {["limits"], %{"limits" => %{"caller-secret" => 1}}},
      {["events"], %{"events" => %{"extra" => true}}},
      {["labels"], %{"labels" => %{"caller-secret" => "must-not-escape"}}}
    ]

    for {path, override} <- cases do
      manifest = valid_manifest(override)

      directory_path =
        write_application(directory, "nested-#{length(path)}-#{hd(path)}", manifest)

      outcome = assert_error(["validate", directory_path], "application", "schema_violation")
      expected_pointer = Enum.map_join(path, "", &"/#{&1}")
      assert outcome.envelope["error"]["path"] == expected_pointer
      refute Jason.encode!(outcome.envelope) =~ "caller-secret"
      refute Jason.encode!(outcome.envelope) =~ "must-not-escape"

      documents = %{
        "ptc.json" => Jason.encode!(manifest),
        "main.clj" => "(ns app) (defn run [input] (return input))"
      }

      typed_path =
        Enum.map(path, fn
          segment when is_binary(segment) -> {:property, segment}
          segment when is_integer(segment) -> {:index, segment}
        end)

      assert {:error, {:manifest_path, ^typed_path, :unknown_properties}} =
               ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)
    end
  end

  @tag :tmp_dir
  test "invalid declared manifest values retain their exact safe paths across adapters", %{
    tmp_dir: directory
  } do
    cases = [
      {["workflow", "entry"], %{"workflow" => %{"components" => [], "entry" => 42}}},
      {["workflow", "components"], %{"workflow" => %{"components" => %{}, "entry" => "app/run"}}},
      {["workflow", "components", 0, "library"],
       %{
         "workflow" => %{
           "components" => [%{"library" => 42}],
           "entry" => "app/run"
         }
       }},
      {["workflow", "components", 0, "id"],
       %{
         "workflow" => %{
           "components" => [%{"id" => 42, "path" => "main.clj"}],
           "entry" => "app/run"
         }
       }},
      {["workflow", "components", 0, "path"],
       %{
         "workflow" => %{
           "components" => [%{"id" => "app", "path" => 42}],
           "entry" => "app/run"
         }
       }},
      {["workflow", "components", 0, "dependencies", 0],
       %{
         "workflow" => %{
           "components" => [
             %{"id" => "app", "path" => "main.clj", "dependencies" => [42]}
           ],
           "entry" => "app/run"
         }
       }},
      {["workflow", "components", 0, "dependencies"],
       %{
         "workflow" => %{
           "components" => [
             %{"id" => "app", "path" => "main.clj", "dependencies" => ["z", "a"]}
           ],
           "entry" => "app/run"
         }
       }},
      {["providers", "workflow"], %{"providers" => %{"workflow" => %{}, "mission" => []}}},
      {["providers", "workflow", 0, "name"],
       %{"providers" => %{"workflow" => [%{"name" => 42}], "mission" => []}}},
      {["providers", "workflow", 0, "config"],
       %{
         "providers" => %{
           "workflow" => [%{"name" => "safe", "config" => []}],
           "mission" => []
         }
       }},
      {["providers", "workflow"],
       %{
         "providers" => %{
           "workflow" => [%{"name" => "safe"}, %{"name" => "safe"}],
           "mission" => []
         }
       }},
      {["events", "policy"], %{"events" => %{"policy" => 42}}},
      {["events", "run_id"], %{"events" => %{"run_id" => 42}}},
      {["events", "run_id"], %{"events" => %{"run_id" => nil}}},
      {["events", "trace_id"], %{"events" => %{"trace_id" => nil}}},
      {["input", "value"], %{"input" => %{"value" => []}}},
      {["input", "path"], %{"input" => %{"path" => 42}}},
      {["limits", "run_duration_ms"], %{"limits" => %{"run_duration_ms" => 0}}},
      {["labels", "name"], %{"labels" => %{"name" => []}}},
      {["labels", "tags"], %{"labels" => %{"tags" => []}}},
      {["labels", "tags"], %{"labels" => %{"tags" => nil}}},
      {["labels", "tags", "stage"], %{"labels" => %{"tags" => %{"stage" => "secret"}}}},
      {["mission", "data"], %{"mission" => %{"data" => []}}},
      {["version"], %{"version" => 2}},
      {["$schema"], %{"$schema" => 42}},
      {["$schema"], %{"$schema" => nil}}
    ]

    for {{path, override}, index} <- Enum.with_index(cases) do
      manifest = valid_manifest(override)
      name = "invalid-value-#{index}-" <> Enum.map_join(path, "-", &to_string/1)
      directory_path = write_application(directory, name, manifest)
      outcome = assert_error(["validate", directory_path], "application", "schema_violation")
      expected_pointer = Enum.map_join(path, "", &"/#{&1}")
      assert outcome.envelope["error"]["path"] == expected_pointer

      documents = %{
        "ptc.json" => Jason.encode!(manifest),
        "main.clj" => "(ns app) (defn run [input] (return input))"
      }

      typed_path =
        Enum.map(path, fn
          segment when is_binary(segment) -> {:property, segment}
          segment when is_integer(segment) -> {:index, segment}
        end)

      assert {:error, {:manifest_path, ^typed_path, _reason}} =
               ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)
    end
  end

  @tag :tmp_dir
  test "duplicate manifest properties retain only their safe parent", %{tmp_dir: directory} do
    root_duplicate =
      ~S|{"version":1,"version":1,"workflow":{"components":[{"id":"app","path":"main.clj"}],"entry":"app/run"},"input":{"value":{}}}|

    workflow_duplicate =
      ~S|{"version":1,"workflow":{"components":[{"id":"app","path":"main.clj"}],"entry":"app/run","entry":"app/run"},"input":{"value":{}}}|

    for {name, manifest, expected_path, typed_path} <- [
          {"root-duplicate", root_duplicate, "", []},
          {"workflow-duplicate", workflow_duplicate, "/workflow", [{:property, "workflow"}]}
        ] do
      application = write_application(directory, name, manifest)
      outcome = assert_error(["validate", application], "application", "duplicate_property")
      assert outcome.envelope["error"]["path"] == expected_path

      assert {:error, {:manifest_path, ^typed_path, :duplicate_json_key}} =
               ApplicationPackage.request_memory(
                 "ptc.json",
                 %{
                   "ptc.json" => manifest,
                   "main.clj" => "(ns app) (defn run [input] (return input))"
                 },
                 result_projection: :json
               )
    end
  end

  @tag :tmp_dir
  test "requested run artifacts remain not written before classification", %{tmp_dir: directory} do
    application = write_application(directory, "valid-run", valid_manifest())
    missing_host = Path.join(directory, "missing-host.json")

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "run",
               application,
               "--host-config",
               missing_host,
               "--trace-dir",
               Path.join(directory, "trace"),
               "--inspect",
               Path.join(directory, "inspection.json"),
               "--private-output",
               Path.join(directory, "result.json")
             ])

    assert outcome.envelope["artifact_class"] == "unclassified"

    assert outcome.envelope["artifact_state"] == %{
             "trace" => "not_written",
             "inspection" => "not_written",
             "result" => "not_written"
           }

    assert outcome.envelope["execution"] == %{"state" => "not_started"}
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "trace preparation binds both event identities to the command run reference", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "traced-run", valid_manifest())
    trace_dir = Path.join(directory, "trace")

    assert {:ok, preparation} =
             CommandEngine.prepare(["run", application, "--trace-dir", trace_dir])

    assert preparation.command == :run
    assert preparation.artifact_destinations == %{trace_dir: trace_dir}
    assert preparation.artifact_destination_failures == []
    assert preparation.run_ref == preparation.prepared_run.request.policy.run_id

    prepared = preparation.prepared_run
    run_ref = prepared.request.policy.run_id
    assert CommandRunRef.valid?(run_ref)
    assert prepared.request.policy.run_id == run_ref
    assert prepared.request.policy.trace_id == run_ref
    assert :ok = PreparedRun.close(prepared)

    conflicting =
      write_application(
        directory,
        "conflicting-trace-run",
        valid_manifest(%{"events" => %{"run_id" => "manifest-owned"}})
      )

    conflict =
      assert_error(
        ["run", conflicting, "--trace-dir", trace_dir],
        "application",
        "event_identity_conflict"
      )

    assert conflict.envelope["error"]["path"] == "/events"
  end

  @tag :tmp_dir
  test "command preparation retains the run reference and phase-6 destinations", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "continuation-state", valid_manifest())
    output = Path.join(directory, "result.json")
    inspection = Path.join(directory, "inspection.jsonl")

    assert {:ok, preparation} =
             CommandEngine.prepare([
               "run",
               application,
               "--output",
               output,
               "--inspect",
               inspection
             ])

    assert preparation.command == :run
    assert CommandRunRef.valid?(preparation.run_ref)
    assert preparation.artifact_destinations == %{output: output, inspect: inspection}
    assert preparation.artifact_destination_failures == []
    assert %PreparedRun{} = preparation.prepared_run
    assert %InstallationCatalog{} = preparation.catalog
    assert CommandPreparation.valid?(preparation)
    refute CommandPreparation.valid?(%{preparation | run_ref: "cmd-invalid"})
    refute CommandPreparation.valid?(Map.put(preparation, :__struct__, PreparedRun))
    assert :ok = PreparedRun.close(preparation.prepared_run)
  end

  @tag :tmp_dir
  test "command preparation anchors artifact destinations at invocation", %{tmp_dir: directory} do
    invocation = Path.join(directory, "invocation")
    later = Path.join(directory, "later")
    File.mkdir!(invocation)
    File.mkdir!(later)
    application = write_application(directory, "anchored-destination", valid_manifest())

    preparation =
      File.cd!(invocation, fn ->
        assert {:ok, preparation} =
                 CommandEngine.prepare(["run", application, "--output", "result.json"])

        preparation
      end)

    File.cd!(later, fn ->
      assert preparation.artifact_destinations == %{
               output: Path.join(invocation, "result.json")
             }
    end)

    assert preparation.artifact_destination_failures == []
    assert :ok = CommandPreparation.close(preparation)
  end

  @tag :tmp_dir
  test "artifact anchoring captures cwd before application acquisition", %{tmp_dir: directory} do
    invocation = Path.join(directory, "invocation-before-acquisition")
    later = Path.join(directory, "cwd-during-acquisition")
    File.mkdir!(invocation)
    File.mkdir!(later)
    application = write_application(directory, "anchored-before-acquisition", valid_manifest())
    original = File.cwd!()

    on_exit(fn ->
      :erlang.trace_pattern({ApplicationPackage, :request_directory, 2}, false, [])
      File.cd!(original)
    end)

    File.cd!(invocation)
    assert {:module, ApplicationPackage} = Code.ensure_loaded(ApplicationPackage)
    assert 1 = :erlang.trace_pattern({ApplicationPackage, :request_directory, 2}, true, [])

    preparation =
      Task.async(fn ->
        receive do
          :prepare -> CommandEngine.prepare(["run", application, "--output", "result.json"])
        end
      end)

    assert 1 = :erlang.trace(preparation.pid, true, [:call])
    send(preparation.pid, :prepare)

    assert_receive {:trace, preparation_pid, :call,
                    {ApplicationPackage, :request_directory, _arguments}},
                   1_000

    assert preparation_pid == preparation.pid
    File.cd!(later)
    assert {:ok, preparation} = Task.await(preparation)

    assert preparation.artifact_destinations == %{
             output: Path.join(invocation, "result.json")
           }

    assert preparation.artifact_destination_failures == []
    assert :ok = CommandPreparation.close(preparation)
  end

  @tag :tmp_dir
  test "an unavailable cwd preserves failures for ordered destination preflight", %{
    tmp_dir: directory
  } do
    invocation = Path.join(directory, "removed-invocation-cwd")
    application = write_application(directory, "unavailable-invocation-cwd", valid_manifest())
    absolute_trace = Path.join(directory, "absolute-trace")
    original = File.cwd!()
    File.mkdir!(invocation)

    on_exit(fn -> File.cd!(original) end)

    File.cd!(invocation)
    File.rmdir!(invocation)
    assert {:error, :enoent} = File.cwd()

    assert {:ok, preparation} =
             CommandEngine.prepare([
               "run",
               application,
               "--trace-dir",
               absolute_trace,
               "--output",
               "result.json"
             ])

    assert preparation.artifact_destinations == %{trace_dir: absolute_trace}
    assert preparation.artifact_destination_failures == [:output]
    assert CommandPreparation.valid?(preparation)
    assert :ok = CommandPreparation.close(preparation)
  end

  @tag :tmp_dir
  test "command preparation releases its owner when continuation sealing raises", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "sealing-failure", valid_manifest())
    storage_key = {Attestation, CommandPreparation}
    previous_key = :persistent_term.get(storage_key, :missing)

    on_exit(fn ->
      case previous_key do
        :missing -> :persistent_term.erase(storage_key)
        key -> :persistent_term.put(storage_key, key)
      end
    end)

    :persistent_term.put(storage_key, :invalid_hmac_key)
    owners_before = host_installation_owners()

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["run", application])

    assert outcome.envelope["error"]["code"] == "internal_error"
    assert MapSet.difference(host_installation_owners(), owners_before) == MapSet.new()
  end

  @tag :tmp_dir
  test "host catalog construction rolls back its authority owner when sealing raises", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "catalog-sealing-failure", valid_manifest())
    host_path = write_host_config(directory, "catalog-sealing-failure", valid_host_config())
    storage_key = {Attestation, PtcRunner.Kernel.SelectionRules}
    previous_key = :persistent_term.get(storage_key, :missing)

    on_exit(fn ->
      case previous_key do
        :missing -> :persistent_term.erase(storage_key)
        key -> :persistent_term.put(storage_key, key)
      end
    end)

    :persistent_term.put(storage_key, :invalid_hmac_key)
    owners_before = host_installation_owners()

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["validate", application, "--host-config", host_path])

    assert outcome.envelope["error"]["code"] == "internal_error"
    assert MapSet.difference(host_installation_owners(), owners_before) == MapSet.new()
  end

  @tag :tmp_dir
  test "host authority rolls back when application request construction raises", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "request-sealing-failure", valid_manifest())
    host_path = write_host_config(directory, "request-sealing-failure", valid_host_config())
    storage_key = {Attestation, ApplicationPackage}
    previous_key = :persistent_term.get(storage_key, :missing)

    on_exit(fn ->
      case previous_key do
        :missing -> :persistent_term.erase(storage_key)
        key -> :persistent_term.put(storage_key, key)
      end
    end)

    :persistent_term.put(storage_key, :invalid_hmac_key)
    owners_before = host_installation_owners()

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["validate", application, "--host-config", host_path])

    assert outcome.envelope["error"]["code"] == "internal_error"
    assert MapSet.difference(host_installation_owners(), owners_before) == MapSet.new()
  end

  @tag :tmp_dir
  test "command preparation seals correlated policy, catalog, and destinations", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "correlated-preparation", valid_manifest())
    assert {:ok, preparation} = CommandEngine.prepare(["run", application])

    invalid_catalog = Map.put(preparation.catalog, :unexpected, :retained)

    refute InstallationCatalog.valid?(invalid_catalog)

    assert {:error, :invalid_command_preparation} =
             CommandPreparation.new(
               :run,
               preparation.run_ref,
               preparation.prepared_run,
               preparation.catalog,
               preparation.runtime_services,
               preparation.environment_setup_required,
               %{output: "relative-result.json"},
               []
             )

    refute CommandPreparation.valid?(Map.put(preparation, :unexpected, :retained))

    malformed =
      preparation
      |> Map.delete(:catalog)
      |> Map.put(:unexpected, :retained)

    refute CommandPreparation.valid?(malformed)

    mismatched_limits = %{
      preparation.catalog
      | installed_limits: %{preparation.catalog.installed_limits | run_duration_ms: 299_999}
    }

    for {catalog, destinations} <- [
          {preparation.catalog, %{inspect: "inspection.jsonl"}},
          {preparation.catalog, %{trace_dir: "trace"}},
          {preparation.catalog, %{output: "normal.json", private_output: "private.json"}},
          {invalid_catalog, %{}},
          {mismatched_limits, %{}}
        ] do
      assert {:error, :invalid_command_preparation} =
               CommandPreparation.new(
                 :run,
                 preparation.run_ref,
                 preparation.prepared_run,
                 catalog,
                 preparation.runtime_services,
                 preparation.environment_setup_required,
                 destinations,
                 []
               )
    end

    assert {:ok, native_request} = ApplicationPackage.request_directory(application)

    assert {:ok, native_prepared} =
             RunCoordinator.prepare(native_request, preparation.catalog)

    assert {:error, :invalid_command_preparation} =
             CommandPreparation.new(
               :run,
               preparation.run_ref,
               native_prepared,
               preparation.catalog,
               preparation.runtime_services,
               preparation.environment_setup_required,
               %{},
               []
             )

    assert :ok = PreparedRun.close(native_prepared)
    assert :ok = CommandPreparation.close(preparation)
  end

  @tag :tmp_dir
  test "sealed command values reject undeclared fields at every nested boundary", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "exact-sealed-values", valid_manifest())
    assert {:ok, preparation} = CommandEngine.prepare(["run", application])

    request = preparation.prepared_run.request
    package = request.package
    input = request.input
    policy = request.policy
    activity = preparation.prepared_run.provider_activity

    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => %{"count" => %{"type" => "integer"}},
               "required" => ["count"]
             })

    {_classification, evidence} =
      ValueContract.classify_with_evidence(contract, %{"count" => "wrong"})

    assert %ValueContractClassification{} = evidence
    assert {:ok, authority} = CommandContractAuthority.new(evidence)
    assert {:ok, path} = CommandPath.contract(authority, [{:property, "count"}])

    assert {:ok, source} =
             CommandSource.with_contract(CommandSource.fixed(:external_input), authority)

    refute ApplicationPackage.valid?(Map.put(package, :application_path, "private"))
    refute ExecutionInput.valid?(Map.put(input, :input_path, "private"))
    refute ExecutionPolicy.valid?(Map.put(policy, :output_path, "private"))
    refute RunRequest.valid?(Map.put(request, :application_path, "private"))
    refute PreparedRun.valid?(Map.put(preparation.prepared_run, :application_path, "private"))

    refute FrozenBundle.valid?(
             Map.put(preparation.prepared_run.workflow_bundle, :private_path, ".")
           )

    assert ProviderActivity.value(Map.put(activity, :provider_endpoint, "private")) == :unknown
    refute ValueContract.sealed?(Map.put(contract, :schema_path, "private"))
    refute ValueContractClassification.valid?(Map.put(evidence, :branch_secret, "private"))
    refute CommandContractAuthority.valid?(Map.put(authority, :branch_secret, "private"))
    refute CommandPath.valid?(Map.put(path, :source_path, "private"))
    refute CommandSource.valid?(Map.put(source, :source_path, "private"))

    assert {:error, :invalid_command_preparation} =
             CommandPreparation.new(
               :run,
               preparation.run_ref,
               Map.put(preparation.prepared_run, :application_path, "private"),
               preparation.catalog,
               preparation.runtime_services,
               preparation.environment_setup_required,
               %{},
               []
             )

    assert :ok = CommandPreparation.close(preparation)
  end

  test "provider registries reject struct builder collections" do
    assert {:ok, registry} = ProviderRegistry.new()

    for builders <- [MapSet.new(), %URI{}] do
      assert {:error, :invalid_provider_registry} = ProviderRegistry.new(builders)
      refute ProviderRegistry.valid?(%{registry | builders: builders})
    end

    refute ProviderRegistry.valid?(Map.put(registry, :unexpected, :retained))
  end

  test "provider registries reject a builder bound to a malformed declared policy" do
    prepare = fn _selection, _context ->
      {:ok, %{credential_names: [], preflight: fn -> :ok end}}
    end

    for policy <- [
          %{data_class: :normal, accepts_data: :normal},
          %{data_class: :normal, accepts_data: []},
          %{data_class: :unknown, accepts_data: [:normal]},
          %{data_class: :normal, accepts_data: [:normal, :unknown]}
        ] do
      assert {:error, :invalid_provider_registry} =
               ProviderRegistry.new(%{"bound" => ProviderRegistry.staged(prepare, policy)})
    end
  end

  @tag :tmp_dir
  test "preparation and assembly reject invalid registries before consuming work", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "invalid-registry", valid_manifest())
    assert {:ok, request} = ApplicationPackage.request_directory(application)
    assert {:ok, registry} = ProviderRegistry.new()
    invalid_registry = Map.put(registry, :unexpected, :retained)

    assert {:error, %CommandDiagnostic{phase: :internal, code: :internal_error}} =
             RunCoordinator.prepare(request, invalid_registry)

    assert {:error, :invalid_provider_registry} =
             RunBuilder.build(request, invalid_registry)

    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog_for(registry))

    assert {:error, :invalid_provider_registry} =
             RunBuilder.build_prepared(prepared, invalid_registry)

    assert {:ok, built} = RunBuilder.build_prepared(prepared, registry)
    assert :ok = RunBuilder.close(built)
    assert :ok = PreparedRun.close(prepared)
  end

  @tag :tmp_dir
  test "a prepared run exposes idempotent lifecycle cleanup", %{tmp_dir: directory} do
    application = write_application(directory, "prepared", valid_manifest())

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()

    assert {:ok, %PreparedRun{} = prepared} =
             RunCoordinator.prepare(request, catalog_for(registry))

    assert Process.alive?(prepared.provider_activity.owner)

    assert :ok = PreparedRun.close(prepared)
    refute Process.alive?(prepared.provider_activity.owner)
    assert :ok = PreparedRun.close(prepared)
  end

  @tag :tmp_dir
  test "a transferred prepared run reports cleanup by its former owner", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "prepared-transfer", valid_manifest())

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()

    assert {:ok, %PreparedRun{} = prepared} =
             RunCoordinator.prepare(request, catalog_for(registry))

    parent = self()
    owner_monitor = Process.monitor(prepared.provider_activity.owner)

    consumer =
      Task.async(fn ->
        assert :ok = PreparedRun.consume(prepared)
        send(parent, :prepared_consumed)

        receive do
          :close_prepared -> PreparedRun.close(prepared)
        end
      end)

    assert_receive :prepared_consumed
    assert {:error, :not_owner} = PreparedRun.close(prepared)
    assert Process.alive?(prepared.provider_activity.owner)

    send(consumer.pid, :close_prepared)
    assert :ok = Task.await(consumer)
    assert_receive {:DOWN, ^owner_monitor, :process, _, :normal}
  end

  @tag :tmp_dir
  test "direct embedding assembly consumes the sealed prepared run", %{tmp_dir: directory} do
    application = write_application(directory, "prepared-build", valid_manifest())

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()

    assert {:ok, %PreparedRun{} = prepared} =
             RunCoordinator.prepare(request, catalog_for(registry))

    assert {:ok, built} = RunBuilder.build_prepared(prepared, registry)
    assert built.entry_source == prepared.entry_source
    assert built.config.workflow_environment.bundle.hash == prepared.workflow_bundle.hash
    assert {:error, :invalid_prepared_run} = RunBuilder.build_prepared(prepared, registry)
    assert :ok = RunBuilder.close(built)
    assert :ok = PreparedRun.close(prepared)
  end

  @tag :tmp_dir
  test "pure option rejection does not consume a prepared run", %{tmp_dir: directory} do
    application = write_application(directory, "prepared-options", valid_manifest())

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog_for(registry))

    acquisition_options = [
      [mission: "input.json"],
      [private_mission: "private.json"],
      [component_override_descriptor: "override.json"],
      [result_projection: :native]
    ]

    for options <- acquisition_options do
      assert {:error, :invalid_build_options} = RunBuilder.build(request, registry, options)

      assert {:error, :invalid_build_options} =
               RunBuilder.build_prepared(prepared, registry, options)
    end

    assert {:error, :invalid_build_options} =
             RunBuilder.build_prepared(prepared, registry, [:not_keyword])

    assert {:error, :invalid_build_options} =
             RunBuilder.build_prepared(prepared, registry,
               trace_path: "first",
               trace_path: "second"
             )

    assert {:error, :invalid_build_options} =
             RunBuilder.build_prepared(prepared, registry, caller_secret: true)

    assert {:error, {:artifact_preflight_failed, :invalid_destination}} =
             RunBuilder.build_prepared(prepared, registry, inspect: 42)

    assert {:error, :invalid_build_options} =
             RunBuilder.build_prepared(prepared, registry,
               mission: "input.json",
               private_mission: "private.json"
             )

    assert {:error, {:result_preflight_failed, :conflicting_result_destinations}} =
             RunBuilder.build_prepared(prepared, registry,
               output: "result.json",
               private_output: "private.json"
             )

    assert {:ok, built} = RunBuilder.build_prepared(prepared, registry)
    assert :ok = RunBuilder.close(built)
    assert :ok = PreparedRun.close(prepared)
  end

  @tag :tmp_dir
  test "concurrent prepared-run consumers admit exactly one assembly", %{tmp_dir: directory} do
    application = write_application(directory, "prepared-concurrent", valid_manifest())

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog_for(registry))

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn -> RunBuilder.build_prepared(prepared, registry) end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, _built}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_prepared_run})) == 1

    Enum.each(results, fn
      {:ok, built} -> assert :ok = RunBuilder.close(built)
      {:error, :invalid_prepared_run} -> :ok
    end)

    assert :ok = PreparedRun.close(prepared)
  end

  @tag :tmp_dir
  test "a prepared run cannot seal bundles from another request", %{tmp_dir: directory} do
    first = write_application(directory, "prepared-first", valid_manifest())

    second =
      write_application(
        directory,
        "prepared-second",
        valid_manifest(),
        %{"main.clj" => "(ns app) (defn run [input] (return {\"other\" input}))"}
      )

    assert {:ok, first_request} =
             ApplicationPackage.request_directory(first, result_projection: :json)

    assert {:ok, second_request} =
             ApplicationPackage.request_directory(second, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()
    catalog = catalog_for(registry)
    assert {:ok, first_prepared} = RunCoordinator.prepare(first_request, catalog)
    assert {:ok, second_prepared} = RunCoordinator.prepare(second_request, catalog)

    assert {:error, :invalid_prepared_run} =
             ProviderActivity.start_owned(fn activity ->
               PreparedRun.new(
                 first_request,
                 second_prepared.workflow_bundle,
                 second_prepared.mission_bundle,
                 first_prepared.entry_source,
                 activity,
                 catalog,
                 prepared_metadata(first_prepared)
               )
             end)

    mission_application =
      write_application(
        directory,
        "prepared-mission",
        valid_manifest(%{
          "mission" => %{
            "components" => [%{"id" => "mission", "path" => "mission.clj"}],
            "data" => %{}
          }
        }),
        %{"mission.clj" => "(ns mission) (defn evaluate [input] input)"}
      )

    assert {:ok, mission_request} =
             ApplicationPackage.request_directory(mission_application, result_projection: :json)

    assert {:ok, mission_prepared} =
             RunCoordinator.prepare(mission_request, catalog)

    assert {:error, :invalid_prepared_run} =
             ProviderActivity.start_owned(fn activity ->
               PreparedRun.new(
                 first_request,
                 first_prepared.workflow_bundle,
                 mission_prepared.mission_bundle,
                 first_prepared.entry_source,
                 activity,
                 catalog,
                 prepared_metadata(first_prepared)
               )
             end)

    assert :ok = PreparedRun.close(first_prepared)
    assert :ok = PreparedRun.close(second_prepared)
    assert :ok = PreparedRun.close(mission_prepared)
  end

  @tag :tmp_dir
  test "a prepared run cannot bypass provider declaration preparation", %{tmp_dir: directory} do
    application =
      write_application(
        directory,
        "prepared-provider-bearing",
        valid_manifest(%{
          "providers" => %{
            "workflow" => [%{"name" => "installed", "config" => %{}}],
            "mission" => []
          }
        })
      )

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, workflow_bundle} =
             PtcRunner.Kernel.compile_bundle(request.package.workflow_components)

    assert {:ok, catalog} = InstallationCatalog.new()

    assert {:error, :invalid_prepared_run} =
             ProviderActivity.start_owned(fn activity ->
               PreparedRun.new(
                 request,
                 workflow_bundle,
                 nil,
                 "(#{request.package.entry} data/input)",
                 activity,
                 catalog,
                 %{}
               )
             end)
  end

  @tag :tmp_dir
  test "a prepared run exclusively claims an unused activity marker", %{tmp_dir: directory} do
    application = write_application(directory, "prepared-activity", valid_manifest())

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()
    catalog = catalog_for(registry)
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)

    assert {:error, :invalid_prepared_run} =
             PreparedRun.new(
               request,
               prepared.workflow_bundle,
               prepared.mission_bundle,
               prepared.entry_source,
               prepared.provider_activity,
               catalog,
               prepared_metadata(prepared)
             )

    assert {:ok, marked_activity} = ProviderActivity.start_link()
    assert :ok = ProviderActivity.mark(marked_activity)

    assert {:error, :invalid_prepared_run} =
             PreparedRun.new(
               request,
               prepared.workflow_bundle,
               prepared.mission_bundle,
               prepared.entry_source,
               marked_activity,
               catalog,
               prepared_metadata(prepared)
             )

    assert :ok = ProviderActivity.stop(marked_activity)
    assert :ok = PreparedRun.close(prepared)
  end

  @tag :tmp_dir
  test "prepared-run construction requires the linked marker creator", %{tmp_dir: directory} do
    application = write_application(directory, "prepared-owner", valid_manifest())

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, workflow_bundle} =
             PtcRunner.Kernel.compile_bundle(request.package.workflow_components)

    assert {:ok, registry} = ProviderRegistry.new()
    catalog = catalog_for(registry)
    assert {:ok, exemplar} = RunCoordinator.prepare(request, catalog)
    assert {:ok, activity} = ProviderActivity.start_link()

    construction =
      Task.async(fn ->
        PreparedRun.new(
          request,
          workflow_bundle,
          nil,
          "(#{request.package.entry} data/input)",
          activity,
          catalog,
          prepared_metadata(exemplar)
        )
      end)

    assert Task.await(construction) == {:error, :invalid_prepared_run}

    Process.unlink(activity.owner)

    assert {:error, :invalid_prepared_run} =
             PreparedRun.new(
               request,
               workflow_bundle,
               nil,
               "(#{request.package.entry} data/input)",
               activity,
               catalog,
               prepared_metadata(exemplar)
             )

    assert :ok = ProviderActivity.stop(activity)
    assert :ok = PreparedRun.close(exemplar)
  end

  test "the linked activity marker exits with its creating process" do
    parent = self()

    creator =
      spawn(fn ->
        {:ok, activity} = ProviderActivity.start_link()
        send(parent, {:activity_owner, activity.owner})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:activity_owner, owner}
    creator_monitor = Process.monitor(creator)
    owner_monitor = Process.monitor(owner)
    send(creator, :stop)
    assert_receive {:DOWN, ^creator_monitor, :process, ^creator, :normal}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}
  end

  test "activity consumption fails closed when the creator detaches during handoff" do
    assert {:ok, activity} = ProviderActivity.start_link()
    assert :ok = ProviderActivity.claim(activity)
    assert :ok = :sys.suspend(activity.owner)

    consumer =
      Task.async(fn ->
        receive do
          :consume -> ProviderActivity.consume(activity)
        end
      end)

    assert 1 = :erlang.trace(consumer.pid, true, [:send])
    send(consumer.pid, :consume)

    assert_receive {:trace, consumer_pid, :send,
                    {:"$gen_call", _from, {:deadline, :consume, _deadline}}, owner}

    assert consumer_pid == consumer.pid
    assert owner == activity.owner

    owner_monitor = Process.monitor(activity.owner)
    Process.unlink(activity.owner)
    assert :ok = :sys.resume(activity.owner)

    assert Task.await(consumer) == {:error, :provider_activity_unavailable}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
  end

  @tag timeout: 10_000
  test "timed-out activity consumption is bounded and cannot mutate later" do
    assert {:ok, activity} = ProviderActivity.start_link()
    assert :ok = ProviderActivity.claim(activity)
    assert :ok = :sys.suspend(activity.owner)

    consumer =
      Task.async(fn -> ProviderActivity.consume(activity, 200) end)

    assert Task.yield(consumer, 5_250) ==
             {:ok, {:error, :provider_activity_unavailable}}

    assert :ok = :sys.resume(activity.owner)
    assert ProviderActivity.value(activity) == false
  end

  test "activity marking fails closed when the current controller detaches" do
    assert {:ok, activity} = ProviderActivity.start_link()
    owner_monitor = Process.monitor(activity.owner)
    Process.unlink(activity.owner)

    assert ProviderActivity.mark(activity) == {:error, :provider_activity_unavailable}
    assert_receive {:DOWN, ^owner_monitor, :process, _owner, :normal}
  end

  test "a stale creator cannot stop activity after ownership transfers" do
    assert {:ok, activity} = ProviderActivity.start_link()
    assert :ok = ProviderActivity.claim(activity)
    parent = self()

    consumer =
      Task.async(fn ->
        assert :ok = ProviderActivity.consume(activity)
        send(parent, :activity_consumed)

        receive do
          :mark ->
            send(parent, {:activity_marked, ProviderActivity.mark(activity)})

            receive do
              :exit_normally -> :ok
            end
        end
      end)

    assert_receive :activity_consumed
    owner_monitor = Process.monitor(activity.owner)

    assert ProviderActivity.claim(activity) == {:error, :provider_activity_unavailable}
    assert Process.alive?(activity.owner)
    assert {:error, :not_owner} = ProviderActivity.stop(activity)
    assert Process.alive?(activity.owner)

    send(consumer.pid, :mark)
    assert_receive {:activity_marked, :ok}
    send(consumer.pid, :exit_normally)
    assert Task.await(consumer) == :ok
    assert_receive {:DOWN, ^owner_monitor, :process, _owner, :normal}
  end

  test "an expired stop from a stale creator cannot bypass transferred ownership" do
    assert {:ok, activity} = ProviderActivity.start_link()
    assert :ok = ProviderActivity.claim(activity)
    parent = self()

    consumer =
      Task.async(fn ->
        assert :ok = ProviderActivity.consume(activity)
        send(parent, :activity_consumed)

        receive do
          :mark -> ProviderActivity.mark(activity)
        end
      end)

    assert_receive :activity_consumed
    expired_deadline = Deadline.new(1, System.monotonic_time(:millisecond) - 2)

    assert {:error, :provider_activity_unavailable} =
             GenServer.call(
               activity.owner,
               {:deadline, :stop, expired_deadline},
               1_000
             )

    assert Process.alive?(activity.owner)
    send(consumer.pid, :mark)
    assert Task.await(consumer) == :ok
  end

  @tag timeout: 10_000
  test "a timed-out stop never reports successful cleanup" do
    assert {:ok, activity} = ProviderActivity.start_link()
    assert :ok = ProviderActivity.claim(activity)
    parent = self()

    consumer =
      Task.async(fn ->
        assert :ok = ProviderActivity.consume(activity)
        send(parent, :activity_consumed)

        receive do
          :mark -> ProviderActivity.mark(activity)
        end
      end)

    assert_receive :activity_consumed
    assert :ok = :sys.suspend(activity.owner)

    assert {:error, :provider_activity_unavailable} =
             ProviderActivity.stop(activity, 200)

    assert :ok = :sys.resume(activity.owner)
    assert Process.alive?(activity.owner)
    send(consumer.pid, :mark)
    assert Task.await(consumer) == :ok
  end

  test "activity ownership is rolled back when post-start construction fails" do
    assert {:error, :construction_failed} =
             ProviderActivity.start_owned(fn activity ->
               send(self(), {:failed_activity, activity})
               {:error, :construction_failed}
             end)

    assert_received {:failed_activity, failed_activity}
    refute Process.alive?(failed_activity.owner)

    assert_raise RuntimeError, "construction raised", fn ->
      ProviderActivity.start_owned(fn activity ->
        send(self(), {:raised_activity, activity})
        raise "construction raised"
      end)
    end

    assert_received {:raised_activity, raised_activity}
    refute Process.alive?(raised_activity.owner)
  end

  @tag :tmp_dir
  test "rejected input and arbitrary values never enter the envelope", %{tmp_dir: directory} do
    secret = "must-not-escape"

    schema = %{
      "type" => "object",
      "properties" => %{"safe" => %{"type" => "integer"}},
      "required" => ["safe"]
    }

    manifest =
      valid_manifest(%{
        "input" => %{"value" => %{"safe" => "wrong", secret => secret}},
        "contracts" => %{"input_schema" => %{"path" => "input.schema.json"}}
      })

    path =
      write_application(directory, "private-input", manifest, %{
        "input.schema.json" => Jason.encode!(schema)
      })

    outcome = assert_error(["validate", path], "application", "input_contract_failed")
    assert outcome.envelope["error"]["path"] == "/safe"
    refute Jason.encode!(outcome.envelope) =~ secret
  end

  @tag :tmp_dir
  test "contract and component failures retain portable logical provenance", %{
    tmp_dir: directory
  } do
    for {role, invalid_path} <- [
          {"input_schema", 42},
          {"input_schema", "../private-input.schema.json"},
          {"result_schema", 42},
          {"result_schema", "../private-result.schema.json"}
        ] do
      manifest =
        valid_manifest(%{
          "contracts" => %{role => %{"path" => invalid_path}}
        })

      invalid_reference =
        write_application(
          directory,
          "malformed-#{role}-#{:erlang.phash2(invalid_path)}",
          manifest
        )

      outcome =
        assert_error(["validate", invalid_reference], "application", "schema_violation")

      assert outcome.envelope["error"]["source"] == %{
               "kind" => "application",
               "name" => "ptc.json"
             }

      assert outcome.envelope["error"]["path"] == "/contracts/#{role}/path"

      typed_path = [
        {:property, "contracts"},
        {:property, role},
        {:property, "path"}
      ]

      assert {:error, {:manifest_path, ^typed_path, :invalid_contract_reference}} =
               ApplicationPackage.request_memory(
                 "ptc.json",
                 %{
                   "ptc.json" => Jason.encode!(manifest),
                   "main.clj" => "(ns app) (defn run [input] (return input))"
                 },
                 result_projection: :json
               )
    end

    for role <- ["input_schema", "result_schema"], invalid_reference <- [42, nil] do
      manifest = valid_manifest(%{"contracts" => %{role => invalid_reference}})

      invalid_reference_path =
        write_application(
          directory,
          "non-map-#{role}-#{inspect(invalid_reference)}",
          manifest
        )

      outcome =
        assert_error(
          ["validate", invalid_reference_path],
          "application",
          "schema_violation"
        )

      assert outcome.envelope["error"]["path"] == "/contracts/#{role}"

      typed_path = [{:property, "contracts"}, {:property, role}]

      assert {:error, {:manifest_path, ^typed_path, :invalid_contract_reference}} =
               ApplicationPackage.request_memory(
                 "ptc.json",
                 %{
                   "ptc.json" => Jason.encode!(manifest),
                   "main.clj" => "(ns app) (defn run [input] (return input))"
                 },
                 result_projection: :json
               )
    end

    invalid_contracts = valid_manifest(%{"contracts" => 42})
    invalid_contracts_path = write_application(directory, "non-map-contracts", invalid_contracts)

    invalid_contracts_outcome =
      assert_error(["validate", invalid_contracts_path], "application", "schema_violation")

    assert invalid_contracts_outcome.envelope["error"]["path"] == "/contracts"

    assert {:error, {:manifest_path, [{:property, "contracts"}], :invalid_contracts_section}} =
             ApplicationPackage.request_memory(
               "ptc.json",
               %{
                 "ptc.json" => Jason.encode!(invalid_contracts),
                 "main.clj" => "(ns app) (defn run [input] (return input))"
               },
               result_projection: :json
             )

    for {role, filename} <- [
          {"input_schema", "input.schema.json"},
          {"result_schema", "result.schema.json"}
        ] do
      invalid_reference =
        write_application(
          directory,
          "invalid-#{role}-reference",
          valid_manifest(%{
            "contracts" => %{
              role => %{"path" => filename, "extra" => "must-not-escape"}
            }
          }),
          %{filename => "{}"}
        )

      reference = assert_error(["validate", invalid_reference], "application", "schema_violation")

      assert reference.envelope["error"]["source"] == %{
               "kind" => "application",
               "name" => "ptc.json"
             }

      assert reference.envelope["error"]["path"] == "/contracts/#{role}"
      refute Jason.encode!(reference.envelope) =~ "must-not-escape"

      missing_path =
        write_application(
          directory,
          "missing-#{role}-path",
          valid_manifest(%{"contracts" => %{role => %{}}})
        )

      missing =
        assert_error(["validate", missing_path], "application", "required_property_missing")

      assert missing.envelope["error"]["source"] == %{
               "kind" => "application",
               "name" => "ptc.json"
             }

      assert missing.envelope["error"]["path"] == "/contracts/#{role}/path"
    end

    invalid_input_contract =
      write_application(
        directory,
        "invalid-input-contract",
        valid_manifest(%{
          "contracts" => %{"input_schema" => %{"path" => "input.schema.json"}}
        }),
        %{"input.schema.json" => "{"}
      )

    input_contract =
      assert_error(["validate", invalid_input_contract], "application", "invalid_json")

    assert input_contract.envelope["error"]["source"] == %{
             "kind" => "input_contract",
             "name" => "input.schema.json"
           }

    invalid_result_contract =
      write_application(
        directory,
        "invalid-result-contract",
        valid_manifest(%{
          "contracts" => %{"result_schema" => %{"path" => "result.schema.json"}}
        }),
        %{"result.schema.json" => "{"}
      )

    result_contract =
      assert_error(["validate", invalid_result_contract], "application", "invalid_json")

    assert result_contract.envelope["error"]["source"] == %{
             "kind" => "result_contract",
             "name" => "result.schema.json"
           }

    invalid_component =
      write_application(
        directory,
        "invalid-component",
        valid_manifest(),
        %{"main.clj" => "(ns app) ("}
      )

    component = assert_error(["validate", invalid_component], "bundle", "compile_failed")

    assert component.envelope["error"]["source"] == %{
             "kind" => "component",
             "name" => "main.clj"
           }

    documents = %{
      "ptc.json" => Jason.encode!(valid_manifest()),
      "main.clj" => "(ns app) ("
    }

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()

    assert {:error, %CommandDiagnostic{} = memory_component} =
             RunCoordinator.prepare(request, catalog_for(registry))

    assert CommandDiagnostic.to_map(memory_component)["source"] ==
             component.envelope["error"]["source"]

    for {name, bytes, code} <- [
          {"missing.clj", nil, "reference_missing"},
          {"oversized.clj", String.duplicate(" ", 2_000_001), "document_limit_exceeded"}
        ] do
      manifest =
        valid_manifest(%{
          "workflow" => %{
            "components" => [%{"id" => "app", "path" => name}],
            "entry" => "app/run"
          }
        })

      extras = if is_binary(bytes), do: %{name => bytes}, else: %{}
      directory_path = write_application(directory, "component-#{code}", manifest, extras)
      directory_failure = assert_error(["validate", directory_path], "application", code)

      assert directory_failure.envelope["error"]["source"] == %{
               "kind" => "component",
               "name" => name
             }

      memory_documents =
        %{"ptc.json" => Jason.encode!(manifest)}
        |> then(fn documents ->
          if is_binary(bytes), do: Map.put(documents, name, bytes), else: documents
        end)

      expected_reason = String.to_existing_atom(code)

      assert {:error, {:source_role, :component, ^name, ^expected_reason}} =
               ApplicationPackage.request_memory(
                 "ptc.json",
                 memory_documents,
                 result_projection: :json
               )
    end
  end

  @tag :tmp_dir
  test "application failures retain safe external-input and override provenance", %{
    tmp_dir: directory
  } do
    declared =
      write_application(
        directory,
        "declared-input",
        valid_manifest(%{"input" => %{"path" => "bad.json"}}),
        %{"bad.json" => "{"}
      )

    declared_outcome = assert_error(["validate", declared], "application", "invalid_json")

    assert declared_outcome.envelope["error"]["source"] == %{
             "kind" => "application",
             "name" => "ptc.json"
           }

    declared_shape_manifest = valid_manifest(%{"input" => %{"path" => "array.json"}})

    declared_shape =
      write_application(directory, "declared-shape-input", declared_shape_manifest, %{
        "array.json" => "[]"
      })

    declared_shape_outcome =
      assert_error(["validate", declared_shape], "application", "input_invalid")

    assert declared_shape_outcome.envelope["error"]["source"] == %{
             "kind" => "application",
             "name" => "ptc.json"
           }

    for acquire <- [
          fn ->
            ApplicationPackage.request_directory(declared_shape, result_projection: :json)
          end,
          fn ->
            ApplicationPackage.request_memory(
              "ptc.json",
              %{
                "ptc.json" => Jason.encode!(declared_shape_manifest),
                "main.clj" => "(ns app) (defn run [input] (return input))",
                "array.json" => "[]"
              },
              result_projection: :json
            )
          end
        ] do
      assert {:error, :invalid_input} = acquire.()
    end

    external =
      write_application(directory, "external-input", valid_manifest(), %{"bad.json" => "{"})

    external_outcome =
      assert_error(["run", external, "--input", "bad.json"], "application", "invalid_json")

    assert external_outcome.envelope["error"]["source"] == %{
             "kind" => "external_input",
             "name" => "input.json"
           }

    for flag <- ["--input", "--private-input"] do
      invalid_reference =
        assert_error(
          ["run", external, flag, "../caller-secret.json"],
          "application",
          "reference_missing"
        )

      assert invalid_reference.envelope["error"]["source"] == %{
               "kind" => "external_input",
               "name" => "input.json"
             }

      refute Jason.encode!(invalid_reference.envelope) =~ "caller-secret"
    end

    invalid_shape =
      write_application(directory, "invalid-shape-input", valid_manifest(), %{
        "array.json" => "[]"
      })

    invalid_shape_outcome =
      assert_error(
        ["run", invalid_shape, "--input", "array.json"],
        "application",
        "input_invalid"
      )

    assert invalid_shape_outcome.envelope["error"]["source"] == %{
             "kind" => "external_input",
             "name" => "input.json"
           }

    nested_json = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)

    excessive_depth =
      write_application(directory, "deep-input", valid_manifest(), %{"deep.json" => nested_json})

    excessive_depth_outcome =
      assert_error(
        ["run", excessive_depth, "--input", "deep.json"],
        "application",
        "document_limit_exceeded"
      )

    assert excessive_depth_outcome.envelope["error"]["source"] == %{
             "kind" => "external_input",
             "name" => "input.json"
           }

    captured_override =
      write_application(directory, "captured-override", valid_manifest(), %{
        "override.json" => "{"
      })

    captured_outcome =
      assert_error(
        ["run", captured_override, "--component-override-descriptor", "override.json"],
        "application",
        "override_invalid"
      )

    assert captured_outcome.envelope["error"]["source"] == %{
             "kind" => "component_override",
             "name" => "component-override.json"
           }

    external_override = Path.join(directory, "external-override.json")
    File.write!(external_override, "{")

    external_override_outcome =
      assert_error(
        ["run", external, "--component-override-descriptor", external_override],
        "application",
        "override_invalid"
      )

    assert external_override_outcome.envelope["error"]["source"] == %{
             "kind" => "component_override",
             "name" => "component-override.json"
           }
  end

  @tag :tmp_dir
  test "external override aggregate-limit failures retain override provenance", %{
    tmp_dir: directory
  } do
    component_bytes = String.duplicate(" ", 1_835_000)

    components =
      for index <- 0..3 do
        %{"id" => "component#{index}", "path" => "component#{index}.clj"}
      end

    documents =
      Map.new(0..3, fn index -> {"component#{index}.clj", component_bytes} end)

    manifest =
      valid_manifest(%{
        "workflow" => %{
          "components" => components,
          "entry" => "component0/run"
        }
      })

    application = write_application(directory, "override-accounting", manifest, documents)
    candidate = String.duplicate(" ", 1_048_576)
    candidate_path = Path.join(directory, "candidate.clj")
    descriptor_path = Path.join(directory, "external-override.json")
    File.write!(candidate_path, candidate)

    File.write!(
      descriptor_path,
      Jason.encode!(%{
        "component_id" => "component0",
        "base_source_hash" => ComponentOverride.hash(component_bytes),
        "source_hash" => ComponentOverride.hash(candidate),
        "path" => "candidate.clj"
      })
    )

    outcome =
      assert_error(
        ["run", application, "--component-override-descriptor", descriptor_path],
        "application",
        "document_limit_exceeded"
      )

    assert outcome.envelope["error"]["source"] == %{
             "kind" => "component_override",
             "name" => "component-override.json"
           }
  end

  @tag :tmp_dir
  test "override document limits retain override provenance", %{tmp_dir: directory} do
    application = write_application(directory, "override-document-limits", valid_manifest())
    oversized = String.duplicate(" ", 65_537)
    captured = Path.join(Path.dirname(application), "oversized-override.json")
    external = Path.join(directory, "oversized-external-override.json")
    File.write!(captured, oversized)
    File.write!(external, oversized)

    nested = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)
    digest = "sha256:" <> String.duplicate("0", 64)

    deep =
      ~s|{"component_id":"app","base_source_hash":"#{digest}","source_hash":"#{digest}","path":"candidate.clj","extra":| <>
        nested <> "}"

    deep_captured = Path.join(Path.dirname(application), "deep-override.json")
    deep_external = Path.join(directory, "deep-external-override.json")
    File.write!(deep_captured, deep)
    File.write!(deep_external, deep)

    oversized_source = String.duplicate(" ", 1_048_577)
    base_source = "(ns app) (defn run [input] (return input))"

    source_descriptor = fn candidate_name ->
      Jason.encode!(%{
        "component_id" => "app",
        "base_source_hash" => ComponentOverride.hash(base_source),
        "source_hash" => ComponentOverride.hash(oversized_source),
        "path" => candidate_name
      })
    end

    captured_candidate = Path.join(Path.dirname(application), "oversized-candidate.clj")
    captured_source_descriptor = Path.join(Path.dirname(application), "source-override.json")
    File.write!(captured_candidate, oversized_source)
    File.write!(captured_source_descriptor, source_descriptor.("oversized-candidate.clj"))

    external_candidate = Path.join(directory, "oversized-external-candidate.clj")
    external_source_descriptor = Path.join(directory, "source-external-override.json")
    File.write!(external_candidate, oversized_source)

    File.write!(
      external_source_descriptor,
      source_descriptor.("oversized-external-candidate.clj")
    )

    for descriptor <- [
          captured,
          external,
          deep_captured,
          deep_external,
          captured_source_descriptor,
          external_source_descriptor
        ] do
      outcome =
        assert_error(
          ["run", application, "--component-override-descriptor", descriptor],
          "application",
          "document_limit_exceeded"
        )

      assert outcome.envelope["error"]["source"] == %{
               "kind" => "component_override",
               "name" => "component-override.json"
             }
    end
  end

  @tag :tmp_dir
  test "override descriptor violations retain only schema-authorized paths", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "override-schema-paths", valid_manifest())
    digest = "sha256:" <> String.duplicate("0", 64)

    descriptors = [
      {"duplicate",
       ~s|{"component_id":"app","component_id":"app","base_source_hash":"#{digest}","source_hash":"#{digest}","path":"candidate.clj"}|,
       ""},
      {"unknown",
       Jason.encode!(%{
         "component_id" => "app",
         "base_source_hash" => digest,
         "source_hash" => digest,
         "path" => "candidate.clj",
         "caller-secret" => "must-not-escape"
       }), ""},
      {"invalid-declared",
       Jason.encode!(%{
         "component_id" => "INVALID",
         "base_source_hash" => digest,
         "source_hash" => digest,
         "path" => "candidate.clj"
       }), "/component_id"}
    ]

    for {name, bytes, expected_path} <- descriptors do
      descriptor = Path.join(directory, "#{name}-override.json")
      File.write!(descriptor, bytes)

      outcome =
        assert_error(
          ["run", application, "--component-override-descriptor", descriptor],
          "application",
          "override_invalid"
        )

      assert outcome.envelope["error"]["path"] == expected_path

      assert outcome.envelope["error"]["source"] == %{
               "kind" => "component_override",
               "name" => "component-override.json"
             }

      refute Jason.encode!(outcome.envelope) =~ "caller-secret"
    end
  end

  defp assert_error(argv, phase, code) do
    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(argv)

    assert outcome.envelope["error"]["phase"] == phase
    assert outcome.envelope["error"]["code"] == code
    assert outcome.envelope["error"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
    outcome
  end

  defp assert_schema_valid(envelope) do
    assert {:ok, root} =
             JSV.build(CommandContract.schema(), atoms: false, warnings: :silent)

    assert {:ok, _validated} = JSV.validate(envelope, root, cast: false)
  end

  defp assert_schema_invalid(envelope) do
    assert {:ok, root} =
             JSV.build(CommandContract.schema(), atoms: false, warnings: :silent)

    assert {:error, _reason} = JSV.validate(envelope, root, cast: false)
  end

  defp diagnostic_for_row(row) do
    case DiagnosticCatalog.subject_policy(row.phase, row.code) do
      :required ->
        [operation | _rest] = DiagnosticCatalog.subject_operations(row.phase, row.code)

        occurrence =
          case DiagnosticCatalog.subject_occurrence_policy(row.phase, row.code, operation) do
            :forbidden -> nil
            _allowed -> %{destination: :workflow, index: 0}
          end

        {:ok, subject} =
          CommandSubject.provider("safe", operation, occurrence)

        CommandDiagnostic.new!(row.phase, row.code,
          subject: subject,
          provider_activity: diagnostic_activity(row.phase, row.code)
        )

      _policy ->
        CommandDiagnostic.new!(row.phase, row.code,
          provider_activity: diagnostic_activity(row.phase, row.code)
        )
    end
  end

  defp diagnostic_activity(phase, code),
    do: DiagnosticCatalog.provider_activity_policy(phase, code) == true

  defp model_result(alias_name) do
    %{
      "alias" => alias_name,
      "source" => "llm",
      "installation_revision" => "revision",
      "data_class" => "normal",
      "accepts_data" => ["normal"],
      "destinations" => ["workflow"]
    }
  end

  defp usage_fixture do
    %{
      "remaining_ms" => 0,
      "capability_calls" => %{"workflow/read-file" => 1},
      "subordinate_evaluations" => 0,
      "protocol_errors" => 0,
      "evaluation_memory_bytes" => 0,
      "evaluation_history_bytes" => 0,
      "evaluation_continuation_bytes" => 0,
      "events_dropped" => %{"provider-call" => 2}
    }
  end

  defp run_success_fixture(artifact_class, result) do
    %{
      "schema_version" => 1,
      "command" => "run",
      "status" => "ok",
      "run_ref" => CommandRunRef.encode(@zero_entropy),
      "result" => result,
      "secondary_errors" => [],
      "artifact_state" => %{
        "trace" => "not_requested",
        "inspection" => "not_requested",
        "result" => "not_requested"
      },
      "artifact_class" => artifact_class,
      "execution" => %{
        "state" => "finished",
        "outcome" => "ok",
        "diagnostic" => nil,
        "usage" => usage_fixture(),
        "evaluation_memory" => evaluation_memory_fixture()
      }
    }
  end

  defp evaluation_memory_fixture do
    %{
      "defined_count" => 0,
      "history_count" => 0,
      "memory_bytes" => 0,
      "history_bytes" => 0,
      "bytes" => 0
    }
  end

  defp valid_manifest(overrides \\ %{}) do
    base = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    Map.merge(base, overrides)
  end

  defp valid_host_config do
    %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
          "transport" => %{"type" => "stdio", "command" => "node"},
          "tools" => %{
            "read" => %{"as" => "workspace.read", "effect" => "read"}
          }
        }
      }
    }
  end

  defp inert_stdio_installation(revision) do
    %{
      "source" => "mcp",
      "installation_revision" => revision,
      "transport" => %{
        "type" => "stdio",
        "command" => "ptc-nonexistent-executable-9f3a"
      },
      "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
    }
  end

  # A real MCP stdio server, offline and deterministic. It is the only shipped
  # recipe whose descriptor carries both an audited-local check and
  # `connectivity_mode: :acquisition`, which is what lets a connect at this
  # boundary settle two rows that default doctor cannot settle at all. `marker`
  # records the JSON-RPC methods the server actually served.
  defp connect_host_config(marker) do
    %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "connect-stdio-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => System.find_executable("sh"),
            "cwd" => @stdio_root,
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
  end

  defp stdio_host_config(command, launcher, cwd) do
    %{
      "runtime" => %{"stdio_launcher" => launcher},
      "credentials" => %{"token" => %{"literal" => "test-secret"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "stdio-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => command,
            "cwd" => cwd,
            "inherit_environment" => false,
            "env" => %{"TOKEN" => %{"binding" => "token"}}
          },
          "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
        }
      }
    }
  end

  defp doctor_application(directory, name, providers) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => provider_entries(Keyword.get(providers, :workflow, [])),
        "mission" => provider_entries(Keyword.get(providers, :mission, []))
      }
    }

    manifest =
      case Keyword.get(providers, :limits) do
        nil -> manifest
        limits -> Map.put(manifest, "limits", limits)
      end

    write_application(directory, name, manifest)
  end

  defp provider_entries(names) do
    Enum.map(names, fn
      {name, config} -> %{"name" => name, "config" => config}
      name -> %{"name" => name, "config" => %{}}
    end)
  end

  defp write_host_config(directory, name, bytes) when is_binary(bytes) do
    path = Path.join(directory, "#{name}.host.json")
    File.write!(path, bytes)
    path
  end

  defp write_host_config(directory, name, config),
    do: write_host_config(directory, name, Jason.encode!(config))

  defp catalog_for(registry) do
    {:ok, catalog} =
      InstallationCatalog.new(%{}, installed_limits: registry.installed_limits)

    catalog
  end

  defp prepared_metadata(prepared) do
    Map.take(prepared, [
      :provider_declarations,
      :effective_data_class,
      :effective_flow,
      :effective_event_policy,
      :effective_application_projection,
      :effective_application_digest,
      :post_selection_context
    ])
  end

  defp host_installation_owners do
    marker = {PtcRunner.Kernel.HostInstallationOwner, :authority}

    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> List.keymember?(dictionary, marker, 0)
        nil -> false
      end
    end)
    |> MapSet.new()
  end

  defp write_application(directory, name, manifest, extra_documents \\ []) do
    root = Path.join(directory, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "main.clj"), "(ns app) (defn run [input] (return input))")

    Enum.each(extra_documents, fn {logical_name, bytes} ->
      File.write!(Path.join(root, logical_name), bytes)
    end)

    bytes = if is_binary(manifest), do: manifest, else: Jason.encode!(manifest)
    path = Path.join(root, "ptc.json")
    File.write!(path, bytes)
    path
  end
end
