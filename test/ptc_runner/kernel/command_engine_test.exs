defmodule PtcRunner.Kernel.CommandEngineTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.CommandEngineFixtures

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandApplicationDiagnostic
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandContractAuthority
  alias PtcRunner.Kernel.CommandDeclaration
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandParser
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRejection
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CommandSubject
  alias PtcRunner.Kernel.CommandWarning
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.ExecutionInput
  alias PtcRunner.Kernel.ExecutionPolicy
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LimitCapacityDiagnostic
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.LimitConfiguration
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ModelContractDiagnostic
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunRequest
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.ValueContractClassification
  alias PtcRunner.Lisp.TrustedError
  alias PtcRunner.StandaloneCLI
  alias PtcRunner.TestSupport.MCPHTTPFixture
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TestSupport.TestHelpers

  @zero_entropy <<0::128>>

  test "contract projection overflow has a stable source-free application diagnostic" do
    diagnostic =
      CommandApplicationDiagnostic.project(:validate, :contract_projection_limit_exceeded)

    assert diagnostic.phase == :application
    assert diagnostic.code == :contract_projection_limit_exceeded
    assert diagnostic.exit_status == 3
    assert diagnostic.source == nil
    assert diagnostic.path == nil
  end

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

  test "the envelope schema compiles once per VM" do
    assert {:ok, root} = CommandContract.envelope_schema_root()
    assert {:ok, ^root} = CommandContract.envelope_schema_root()
  end

  test "help and version are exact phase-1 successes" do
    assert {:ok, %CommandOutcome{} = init_help} =
             CommandEngine.prepare(["help", "init"])

    assert init_help.envelope["result"]["notices"] == [
             "DIRECTORY must not already exist",
             "init assembles the complete scaffold or selected example tree and publishes it atomically without replacing anything",
             "to add PtcRunner to an existing repository, initialize a new sibling or subdirectory and deliberately copy or move the generated files the repository wants"
           ]

    assert_schema_valid(init_help.envelope)

    assert {:ok, %CommandOutcome{} = help} =
             CommandEngine.prepare(["doctor", "--help"])

    assert help.exit_status == 0
    assert help.envelope["command"] == "help"
    assert help.envelope["result"]["topic"] == "doctor"

    assert help.envelope["result"]["notices"] == [
             "doctor --connect may perform one or more real provider requests and may incur provider cost"
           ]

    assert_schema_valid(help.envelope)

    assert {:ok, %CommandOutcome{} = transcript_help} =
             CommandEngine.prepare(["help", "transcript"])

    private_output =
      Enum.find(transcript_help.envelope["result"]["options"], fn option ->
        "--private-output TRANSCRIPT.json" in option["switches"]
      end)

    assert private_output["description"] =~ "symlink"
    assert private_output["description"] =~ "physically separate"
    assert private_output["description"] =~ "/tmp"

    assert {:stdout, text} = CommandRenderer.render(transcript_help)
    assert text =~ "--private-output TRANSCRIPT.json"
    assert text =~ "symlink"
    assert text =~ "physically separate"
    assert_schema_valid(transcript_help.envelope)

    assert {:ok, %CommandOutcome{} = version} =
             CommandEngine.prepare(["--version"])

    assert version.envelope["command"] == "version"
    assert version.envelope["result"]["version"] == "0.14.0"
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

    assert topics ==
             ~w(docs doctor init materialize models repl root run run transcript validate version viewer)

    run_options =
      help_branch
      |> get_in(["properties", "result", "oneOf"])
      |> Enum.filter(&(get_in(&1, ["properties", "topic", "const"]) == "run"))
      |> Enum.map(&get_in(&1, ["properties", "options", "const"]))

    assert Enum.count(run_options, fn options ->
             Enum.any?(options, &(&1["switches"] == ["--authorize-mcp NAME"]))
           end) == 1
  end

  test "run and viewer help expose externally attached live runs" do
    for {topic, expected_guidance} <- [
          {:run, "reports an externally started run to a Viewer Live tab"},
          {:viewer, "use the Viewer URL printed at startup"}
        ] do
      assert {:ok, %CommandOutcome{} = help} =
               CommandEngine.prepare(["help", Atom.to_string(topic)])

      assert [notice] = help.envelope["result"]["notices"]
      assert notice =~ "PTC_VIEWER_URL"
      assert notice =~ expected_guidance

      assert {:stdout, rendered} = CommandRenderer.render(help)
      assert rendered =~ "PTC_VIEWER_URL"
      assert rendered =~ expected_guidance
    end

    viewer_notice = CommandContract.help_result(:viewer)["notices"] |> List.first()
    assert viewer_notice =~ "when it is loopback"
    assert viewer_notice =~ "otherwise use an address that reaches the Viewer"
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

  test "the one-shot engine APIs reject accepted and malformed requests as sealed outcomes" do
    for {argv, code} <- [
          {["repl"], "invalid_command"},
          {["repl", "--caller-secret", "value"], "invalid_arguments"},
          {["repl", "-e", "expr", "script.clj"], "invalid_arguments"},
          {[
             "transcript",
             "run-1",
             "--traces",
             "traces",
             "--inspection",
             "inspection",
             "--private-unattended",
             "--private-output",
             "transcript.json"
           ], "invalid_command"},
          {["transcript", "run-1"], "invalid_arguments"}
        ],
        operation <- [&CommandEngine.prepare/1, &CommandEngine.dispatch/1] do
      assert {:error, %CommandOutcome{} = outcome} = operation.(argv)
      assert outcome.command_mode == :unknown
      assert outcome.envelope["command"] == "unknown"
      assert outcome.envelope["error"]["phase"] == "arguments"
      assert outcome.envelope["error"]["code"] == code
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

    # An application selecting no provider selects no authorization target
    # either, so this is the unknown-target case and names the alias asked for.
    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "authorization_target_unknown"
    assert outcome.envelope["error"]["subject"]["name"] == "workspace"
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
  test "run publishes an unsupported MCP profile without remote details and closes stdio", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "unsupported-run-methods")

    host_path =
      write_host_config(
        directory,
        "unsupported-run",
        connect_host_config(marker, "unsupported-protocol")
      )

    application =
      doctor_application(directory, "run-unsupported-profile",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000}
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    encoded = Jason.encode!(outcome.envelope)
    assert outcome.exit_status == 4
    assert outcome.envelope["error"]["code"] == "provider_protocol_version_unsupported"

    assert outcome.envelope["error"]["message"] ==
             "the endpoint rejected the required server/discover method and does not support MCP protocol 2026-07-28"

    assert outcome.envelope["error"]["retryable"] == false
    refute encoded =~ "PRIVATE_REMOTE_MESSAGE"
    refute encoded =~ "PRIVATE_REMOTE_DATA"
    refute encoded =~ "PRIVATE_STDERR_DETAIL"
    refute encoded =~ "PRIVATE_LAUNCH_ARGUMENT"

    assert {:stderr, rendered} = CommandRenderer.render(outcome)
    assert rendered =~ "provider_protocol_version_unsupported"
    refute rendered =~ "PRIVATE_REMOTE_MESSAGE"
    refute rendered =~ "PRIVATE_REMOTE_DATA"
    refute rendered =~ "PRIVATE_STDERR_DETAIL"
    refute rendered =~ "PRIVATE_LAUNCH_ARGUMENT"

    assert File.read!(marker) =~ "server/discover"
    refute File.read!(marker) =~ "tools/list"
    assert File.read!(marker) =~ "session-closed"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "run distinguishes a valid discovery result missing the required revision", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "unsupported-version-methods")

    host_path =
      write_host_config(
        directory,
        "unsupported-version-run",
        connect_host_config(marker, "unsupported-version")
      )

    application =
      doctor_application(directory, "run-unsupported-version",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000}
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert outcome.envelope["error"]["code"] == "provider_protocol_version_unsupported"

    assert outcome.envelope["error"]["message"] ==
             "the endpoint did not advertise support for MCP protocol 2026-07-28"

    encoded = Jason.encode!(outcome.envelope)
    refute encoded =~ "PRIVATE_ADVERTISED_VERSION"

    assert {:stderr, rendered} = CommandRenderer.render(outcome)
    refute rendered =~ "PRIVATE_ADVERTISED_VERSION"
    refute File.read!(marker) =~ "tools/list"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "HTTP method rejection withholds the endpoint URL and remote error payload", %{
    tmp_dir: directory
  } do
    parent = self()

    fixture =
      MCPHTTPFixture.start(fn request ->
        send(parent, {:mcp_request, request.body["method"]})

        response = %{
          "jsonrpc" => "2.0",
          "id" => request.body["id"],
          "error" => %{
            "code" => -32_601,
            "message" => "PRIVATE_REMOTE_MESSAGE",
            "data" => %{"secret" => "PRIVATE_REMOTE_DATA"}
          }
        }

        {404, [{"content-type", "application/json"}], Jason.encode!(response)}
      end)

    on_exit(fixture.close)
    endpoint = fixture.endpoint <> "/PRIVATE_ENDPOINT_URL"
    host_path = write_host_config(directory, "private-http-endpoint", http_mcp_host(endpoint))

    application =
      doctor_application(directory, "http-unsupported-profile",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000}
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert outcome.envelope["error"]["message"] ==
             "the endpoint rejected the required server/discover method and does not support MCP protocol 2026-07-28"

    for secret <- ["PRIVATE_ENDPOINT_URL", "PRIVATE_REMOTE_MESSAGE", "PRIVATE_REMOTE_DATA"] do
      refute Jason.encode!(outcome.envelope) =~ secret
      assert {:stderr, rendered} = CommandRenderer.render(outcome)
      refute rendered =~ secret
    end

    assert_receive {:mcp_request, "server/discover"}
    refute_receive {:mcp_request, "initialize"}
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
    assert outcome.envelope["error"]["code"] == "explicit_failure"

    # No inspection artifact was requested, so the diagnostic says the value
    # was dropped and names the switch that would have retained it.
    assert outcome.envelope["error"]["message"] =~ "published no inspection artifact"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["execution"]["state"] == "incomplete"
    assert is_map(outcome.envelope["execution"]["usage"])
    refute Jason.encode!(outcome.envelope) =~ "must-not-escape"
    assert outcome.envelope["execution"]["last_evaluation_error"] == nil
    assert_schema_valid(outcome.envelope)

    assert {:stderr, rendered} = CommandRenderer.render(outcome)
    assert rendered =~ "error: execution/explicit_failure:"
    refute rendered =~ "evaluation:"
  end

  @tag :tmp_dir
  test "an arithmetic evaluator failure publishes evaluation_failed with typed evidence", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "arithmetic-dispatch", valid_manifest())

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (return (/ 1 0)))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.envelope["error"]["phase"] == "execution"
    assert outcome.envelope["error"]["code"] == "evaluation_failed"
    assert outcome.envelope["error"]["retryable"] == false
    assert outcome.exit_status == 5

    assert outcome.envelope["execution"]["last_evaluation_error"] == %{
             "kind" => "arithmetic_error",
             "message" => "division by zero"
           }

    assert_schema_valid(outcome.envelope)

    assert {:stderr, rendered} = CommandRenderer.render(outcome)
    assert rendered =~ "error: execution/evaluation_failed: the evaluation failed"
    assert rendered =~ "evaluation: arithmetic_error: division by zero"
    refute rendered =~ "PtcRunner.Lisp"
  end

  @tag :tmp_dir
  test "a type evaluator failure publishes only fixed V4 evidence", %{tmp_dir: directory} do
    application = write_application(directory, "type-error-dispatch", valid_manifest())

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (return (count 5)))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.exit_status == 5
    assert outcome.envelope["error"]["phase"] == "execution"
    assert outcome.envelope["error"]["code"] == "evaluation_failed"

    assert outcome.envelope["execution"]["last_evaluation_error"] == %{
             "kind" => "type_error",
             "message" => "a PTC-Lisp operation received a value of the wrong type"
           }

    encoded = Jason.encode!(outcome.envelope)
    refute encoded =~ "main/run"
    refute encoded =~ "count"
    refute encoded =~ "invalid argument types"
    assert_schema_valid(outcome.envelope)

    assert {:stderr, rendered} = CommandRenderer.render(outcome)
    assert rendered =~ "error: execution/evaluation_failed: the evaluation failed"

    assert rendered =~
             "evaluation: type_error: a PTC-Lisp operation received a value of the wrong type"
  end

  @tag :tmp_dir
  test "arity, not_callable, and loop evaluator failures publish exact public kinds", %{
    tmp_dir: directory
  } do
    cases = [
      {~S|(ns app) (defn run [_input] (return (count)))|, "arity_error", []},
      {~S|(ns app) (defn run [_input] (return (1 2 3)))|, "not_callable", []},
      {~S|(ns app) (defn run [_input] (return (Math/round 1)))|, "java_type_error", []}
    ]

    Enum.with_index(cases, fn {source, kind, extra}, index ->
      application = write_application(directory, "evaluator-kind-#{index}", valid_manifest())
      File.write!(Path.join(Path.dirname(application), "main.clj"), source)

      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.dispatch(["run", application] ++ extra)

      assert outcome.envelope["error"]["code"] == "evaluation_failed"
      assert outcome.envelope["execution"]["last_evaluation_error"]["kind"] == kind
      refute Jason.encode!(outcome.envelope) =~ "PtcRunner.Lisp"
      assert_schema_valid(outcome.envelope)
    end)

    host_path =
      write_host_config(directory, "evaluator-loop-limit", %{
        "install" => %{},
        "limits" => %{"workflow_loop_iterations" => 50}
      })

    application = write_application(directory, "evaluator-kind-loop", valid_manifest())

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (loop [i 0] (if (< i 999999) (recur (inc i)) i)))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert outcome.envelope["error"]["code"] == "evaluation_failed"
    assert outcome.envelope["execution"]["last_evaluation_error"]["kind"] == "loop_limit_exceeded"
    refute Jason.encode!(outcome.envelope) =~ "PtcRunner.Lisp"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a private type evaluator failure keeps last_evaluation_error null", %{tmp_dir: directory} do
    application = write_application(directory, "private-type-error", valid_manifest())
    input = Path.join(Path.dirname(application), "private-input.json")
    output = Path.join(directory, "private-result.json")
    File.write!(input, ~s({}))

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (return (count 5)))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch([
               "run",
               application,
               "--private-input",
               "private-input.json",
               "--private-output",
               output
             ])

    assert outcome.envelope["artifact_class"] == "private"
    assert outcome.envelope["error"]["code"] == "workflow_failed"
    assert outcome.envelope["execution"]["last_evaluation_error"] == nil
    refute Jason.encode!(outcome.envelope) =~ "type_error"
    refute Jason.encode!(outcome.envelope) =~ "wrong type"
    refute Jason.encode!(outcome.envelope) =~ "count"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "an explicit fail value the boundary cannot project is not reported as oversized", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "explicit-fail-unprojectable", valid_manifest())
    inspection = Path.join(directory, "run.ptcins")

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (fail (fn [x] x)))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--inspect", inspection])

    assert outcome.envelope["error"]["code"] == "explicit_failure"
    assert outcome.envelope["error"]["message"] =~ "cannot be represented as JSON"
    refute outcome.envelope["error"]["message"] =~ "terminal result ceiling"
    assert_schema_valid(outcome.envelope)

    assert {:ok, records} = StreamingInspection.read_path(inspection)
    assert Enum.find(records, &(&1["record_type"] == "explicit-failure-value")) == nil
  end

  @tag :tmp_dir
  test "an explicit fail value over terminal_result_bytes reports that it was not retained", %{
    tmp_dir: directory
  } do
    manifest = narrow_terminal_result_manifest(100)

    inspection = Path.join(directory, "run.ptcins")

    application =
      write_application(directory, "explicit-fail-oversized", manifest, [
        {"wide.clj", ~s|(ns wide) (defn run [input] (fail "#{String.duplicate("x", 200)}"))|}
      ])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--inspect", inspection])

    assert outcome.envelope["error"]["code"] == "explicit_failure"
    assert outcome.envelope["error"]["message"] =~ "exceeded the terminal result ceiling"
    assert_schema_valid(outcome.envelope)

    # The artifact was published, so "not retained" has to mean the value
    # itself is absent rather than the artifact being missing.
    assert {:ok, records} = StreamingInspection.read_path(inspection)
    assert Enum.find(records, &(&1["record_type"] == "explicit-failure-value")) == nil
    assert Enum.find(records, &(&1["record_type"] == "execution-error"))
  end

  @tag :tmp_dir
  test "an explicit fail value is retained only as a dedicated inspection record", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "explicit-fail-inspect", valid_manifest())
    inspection = Path.join(directory, "run.ptcins")

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (fail {"secret" "must-not-escape"}))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--inspect", inspection])

    assert outcome.envelope["error"]["code"] == "explicit_failure"
    assert outcome.envelope["error"]["message"] =~ "private inspection record"
    assert outcome.envelope["execution"]["last_evaluation_error"] == nil
    refute Jason.encode!(outcome.envelope) =~ "must-not-escape"
    assert_schema_valid(outcome.envelope)

    assert {:ok, records} = StreamingInspection.read_path(inspection)
    error_record = Enum.find(records, &(&1["record_type"] == "execution-error"))
    fail_record = Enum.find(records, &(&1["record_type"] == "explicit-failure-value"))

    refute Jason.encode!(error_record) =~ "must-not-escape"
    assert fail_record["payload"]["environment"] == "workflow"
    assert fail_record["payload"]["value"] == %{"secret" => "must-not-escape"}

    assert fail_record["correlation"]["evaluation_id"] ==
             error_record["correlation"]["evaluation_id"]
  end

  @tag :tmp_dir
  test "a higher-order callback arithmetic failure publishes evaluation_failed", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "hof-arithmetic", valid_manifest())

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (return (map (fn [x] (/ 1 x)) [1 0])))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.envelope["error"]["code"] == "evaluation_failed"

    assert outcome.envelope["execution"]["last_evaluation_error"] == %{
             "kind" => "arithmetic_error",
             "message" => "division by zero"
           }

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a higher-order callback type failure publishes fixed evidence", %{tmp_dir: directory} do
    application = write_application(directory, "hof-type-error", valid_manifest())

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (return (map count [5])))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.envelope["error"]["code"] == "evaluation_failed"

    assert outcome.envelope["execution"]["last_evaluation_error"] == %{
             "kind" => "type_error",
             "message" => "a PTC-Lisp operation received a value of the wrong type"
           }

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a private not-callable failure still writes an execution-error record", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "private-not-callable", valid_manifest())
    input = Path.join(Path.dirname(application), "private-input.json")
    output = Path.join(directory, "private-result.json")
    inspection = Path.join(directory, "run.ptcins")
    File.write!(input, ~s({}))

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (return (1 2 3)))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch([
               "run",
               application,
               "--private-input",
               "private-input.json",
               "--private-output",
               output,
               "--inspect",
               inspection
             ])

    assert outcome.envelope["error"]["code"] == "workflow_failed"
    assert outcome.envelope["execution"]["last_evaluation_error"] == nil
    assert_schema_valid(outcome.envelope)

    assert {:ok, records} = StreamingInspection.read_path(inspection)
    error_record = Enum.find(records, &(&1["record_type"] == "execution-error"))
    assert error_record["payload"]["kind"] == "workflow_failed"
    assert error_record["payload"]["reason"] == "not_callable"
    assert is_map(error_record["payload"]["details"])
  end

  @tag :tmp_dir
  test "fail nil retains a dedicated inspection record", %{tmp_dir: directory} do
    application = write_application(directory, "explicit-fail-nil", valid_manifest())
    inspection = Path.join(directory, "run.ptcins")

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (fail nil))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--inspect", inspection])

    assert outcome.envelope["error"]["code"] == "explicit_failure"
    assert outcome.envelope["error"]["message"] =~ "private inspection record"
    assert outcome.envelope["execution"]["last_evaluation_error"] == nil
    assert_schema_valid(outcome.envelope)

    assert {:ok, records} = StreamingInspection.read_path(inspection)
    fail_record = Enum.find(records, &(&1["record_type"] == "explicit-failure-value"))
    assert fail_record["payload"]["environment"] == "workflow"
    assert fail_record["payload"]["value"] == nil
  end

  @tag :tmp_dir
  test "fail of the former presence sentinel still writes a dedicated inspection record", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "explicit-fail-sentinel", valid_manifest())
    inspection = Path.join(directory, "run.ptcins")

    File.write!(
      Path.join(Path.dirname(application), "main.clj"),
      ~S|(ns app) (defn run [_input] (fail :__ptc_no_explicit_failure__))|
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--inspect", inspection])

    assert outcome.envelope["error"]["code"] == "explicit_failure"
    assert outcome.envelope["error"]["message"] =~ "private inspection record"
    assert outcome.envelope["execution"]["last_evaluation_error"] == nil
    refute Jason.encode!(outcome.envelope) =~ "__ptc_no_explicit_failure__"
    assert_schema_valid(outcome.envelope)

    assert {:ok, records} = StreamingInspection.read_path(inspection)
    fail_record = Enum.find(records, &(&1["record_type"] == "explicit-failure-value"))
    assert fail_record["payload"]["environment"] == "workflow"
    assert fail_record["payload"]["value"] == "__ptc_no_explicit_failure__"
  end

  @tag :tmp_dir
  test "V4 success and error envelopes retain evaluations by mission", %{tmp_dir: directory} do
    manifest =
      valid_manifest(%{
        "workflow" => %{
          "components" => [
            %{"id" => "app", "path" => "main.clj", "dependencies" => ["kernel"]},
            %{"library" => "kernel"}
          ],
          "entry" => "app/run"
        },
        "missions" => %{"reader" => %{}}
      })

    success = write_application(directory, "mission-usage-success", manifest)

    File.write!(
      Path.join(Path.dirname(success), "main.clj"),
      ~S|(ns app) (defn run [_input] (return (get (kernel/eval-source "reader" "(return 1)") :value)))|
    )

    assert {:ok, %CommandOutcome{} = success_outcome} = CommandEngine.dispatch(["run", success])

    assert get_in(success_outcome.envelope, ["execution", "usage", "evaluations_by_mission"]) ==
             %{"reader" => 1}

    assert get_in(success_outcome.envelope, ["execution", "usage", "capability_refusals"]) == %{}

    failed = write_application(directory, "mission-usage-error", manifest)

    File.write!(
      Path.join(Path.dirname(failed), "main.clj"),
      ~S|(ns app) (defn run [_input] (do (kernel/eval-source "reader" "(return 1)") (fail :nope)))|
    )

    assert {:error, %CommandOutcome{} = failed_outcome} = CommandEngine.dispatch(["run", failed])

    assert get_in(failed_outcome.envelope, ["execution", "usage", "evaluations_by_mission"]) ==
             %{"reader" => 1}

    assert_schema_valid(success_outcome.envelope)
    assert_schema_valid(failed_outcome.envelope)
  end

  @tag :tmp_dir
  test "usage counts quota refusals and replay misses without failing the run", %{
    tmp_dir: directory
  } do
    File.write!(
      Path.join(directory, "replay.jsonl"),
      Jason.encode!(%{
        "schema_version" => 1,
        "request_hash" => "sha256:" <> String.duplicate("0", 64),
        "response" => %{"content" => "frozen"}
      }) <> "\n"
    )

    host_path =
      write_host_config(directory, "quota-replay", %{
        "install" => %{
          "frozen-model" => %{
            "source" => "llm_replay",
            "installation_revision" => "quota-replay-v1",
            "fixtures" => "replay.jsonl"
          }
        }
      })

    application =
      write_application(
        directory,
        "quota-replay",
        valid_manifest(%{
          "providers" => %{"workflow" => [%{"name" => "frozen-model"}]},
          "limits" => %{"workflow_capability_calls_per_name" => 2}
        }),
        %{
          "main.clj" => """
          (ns app)
          (defn ask [i]
            (tool/llm-request {"messages" [{"role" "user" "content" (str "n" i)}]}))
          (defn run [_input]
            (return {"answers" (mapv ask (range 1 6))}))
          """
        }
      )

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert outcome.envelope["status"] == "ok"
    assert outcome.envelope["execution"]["diagnostic"] == nil

    assert get_in(outcome.envelope, ["execution", "usage", "capability_refusals"]) == %{
             "workflow/provider_error/not_found" => 2,
             "workflow/limit_exceeded/capability_quota" => 3
           }

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "usage counts a refused workflow annotation without failing the run", %{
    tmp_dir: directory
  } do
    application =
      write_application(
        directory,
        "refused-annotation",
        valid_manifest(%{
          "workflow" => %{
            "components" => [
              %{"library" => "workflow.event"},
              %{"id" => "app", "path" => "main.clj", "dependencies" => ["workflow.event"]}
            ],
            "entry" => "app/run"
          }
        }),
        %{
          "main.clj" => """
          (ns app)
          (defn run [_input]
            (do
              (workflow.event/annotate "my_custom_type" {"n" 1})
              (return {"ok" true})))
          """
        }
      )

    assert {:ok, %CommandOutcome{} = outcome} = CommandEngine.dispatch(["run", application])
    assert outcome.envelope["status"] == "ok"

    assert get_in(outcome.envelope, ["execution", "usage", "capability_refusals"]) == %{
             "workflow/invalid_annotation/invalid_workflow_annotation" => 1
           }

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
             "evaluation_memory" => nil,
             "last_evaluation_error" => nil
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
             "evaluation_memory" => nil,
             "last_evaluation_error" => nil
           }

    assert fallback.envelope["error"]["provider_activity"] == true
    assert_schema_valid(fallback.envelope)
  end

  test "subordinate evaluation exhaustion names the limit and configured ceiling" do
    usage = %{
      remaining_ms: 0,
      capability_calls: %{workflow: %{}, mission: %{}},
      subordinate_evaluations: 4,
      evaluations_by_mission: %{"default" => 4},
      protocol_errors: 0,
      agent_protocol_errors: 0,
      evaluation_memory_bytes: 0,
      evaluation_history_bytes: 0,
      evaluation_continuation_bytes: 0,
      events_dropped: %{},
      llm_budget: %{"total_tokens" => nil, "cost" => nil},
      llm_spend: %{"state" => "empty"}
    }

    evidence = %{
      result:
        {:error,
         %Error{
           kind: :workflow_failed,
           reason: :runtime_limit_exceeded,
           details: %{
             limit: :subordinate_evaluations,
             limit_value: 4
           },
           usage: usage
         }}
    }

    artifact_state = %{
      "trace" => "not_requested",
      "inspection" => "not_requested",
      "result" => "not_requested"
    }

    settlement =
      {:error,
       %{
         result_class: :normal,
         artifact_state: artifact_state,
         error: nil,
         secondary_errors: []
       }}

    run_ref = CommandRunRef.encode(@zero_entropy)

    assert {:error, %CommandOutcome{} = outcome} =
             CommandRunOutcome.project(evidence, settlement, run_ref, true)

    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert outcome.envelope["execution"]["usage"]["llm_usage_state"] == "unavailable"
    assert outcome.envelope["execution"]["usage"]["llm_usage"] == nil

    assert outcome.envelope["error"]["message"] ==
             "subordinate_evaluations limit 4 was exceeded; raise limits.subordinate_evaluations in the manifest, and the installed host ceiling if it is lower, or reduce total subordinate evaluations or agent turns"

    assert {:stderr, rendered} = CommandRenderer.render(outcome)

    assert rendered ==
             "error: execution/runtime_limit_exceeded: subordinate_evaluations limit 4 was exceeded; raise limits.subordinate_evaluations in the manifest, and the installed host ceiling if it is lower, or reduce total subordinate evaluations or agent turns (run_ref: #{run_ref})\n"

    assert_schema_valid(outcome.envelope)

    runtime_source = CommandSource.fixed(:runtime)

    for invalid_message <- [
          "subordinate_evaluations limit 0 was exceeded; raise limits.subordinate_evaluations in the manifest, and the installed host ceiling if it is lower, or reduce total subordinate evaluations or agent turns",
          "subordinate_evaluations limit 04 was exceeded; raise limits.subordinate_evaluations in the manifest, and the installed host ceiling if it is lower, or reduce total subordinate evaluations or agent turns",
          "subordinate_evaluations limit 2592000001 was exceeded; raise limits.subordinate_evaluations in the manifest, and the installed host ceiling if it is lower, or reduce total subordinate evaluations or agent turns",
          "subordinate_evaluations limit 4 was exceeded; expose private details"
        ] do
      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
                 message: invalid_message,
                 source: runtime_source,
                 provider_activity: true
               )

      assert_schema_invalid(put_in(outcome.envelope, ["error", "message"], invalid_message))
    end
  end

  test "missing or malformed sealed LLM spend invalidates the command outcome" do
    base_usage = %{
      remaining_ms: 0,
      capability_calls: %{workflow: %{}, mission: %{}},
      subordinate_evaluations: 0,
      evaluations_by_mission: %{},
      protocol_errors: 0,
      agent_protocol_errors: 0,
      evaluation_memory_bytes: 0,
      evaluation_history_bytes: 0,
      evaluation_continuation_bytes: 0,
      events_dropped: %{},
      llm_budget: %{"total_tokens" => nil, "cost" => nil}
    }

    settlement =
      {:error,
       %{
         result_class: :normal,
         artifact_state: %{
           "trace" => "not_requested",
           "inspection" => "not_requested",
           "result" => "not_requested"
         },
         error: nil,
         secondary_errors: []
       }}

    for usage <- [base_usage, Map.put(base_usage, :llm_spend, %{"state" => "available"})] do
      evidence = %{
        result:
          {:error,
           %Error{
             kind: :workflow_failed,
             reason: :explicit_failure,
             details: %{},
             usage: usage
           }}
      }

      assert {:error, %CommandOutcome{} = outcome} =
               CommandRunOutcome.project(
                 evidence,
                 settlement,
                 CommandRunRef.encode(@zero_entropy),
                 true
               )

      assert outcome.envelope["error"]["code"] == "internal_error"
      assert outcome.envelope["execution"]["state"] == "incomplete"
      assert outcome.envelope["execution"]["usage"] == nil
      assert_schema_valid(outcome.envelope)
    end
  end

  test "missing or malformed sealed LLM budget invalidates the command outcome" do
    base_usage = %{
      remaining_ms: 0,
      capability_calls: %{workflow: %{}, mission: %{}},
      subordinate_evaluations: 0,
      evaluations_by_mission: %{},
      protocol_errors: 0,
      agent_protocol_errors: 0,
      evaluation_memory_bytes: 0,
      evaluation_history_bytes: 0,
      evaluation_continuation_bytes: 0,
      events_dropped: %{},
      llm_spend: %{"state" => "empty"}
    }

    settlement =
      {:error,
       %{
         result_class: :normal,
         artifact_state: %{
           "trace" => "not_requested",
           "inspection" => "not_requested",
           "result" => "not_requested"
         },
         error: nil,
         secondary_errors: []
       }}

    malformed = %{
      "total_tokens" => %{
        "state" => "available",
        "limit" => 100,
        "reserved" => 1,
        "charged" => 0,
        "remaining" => 99,
        "refused" => 0
      },
      "cost" => nil
    }

    for usage <- [base_usage, Map.put(base_usage, :llm_budget, malformed)] do
      evidence = %{
        result:
          {:error,
           %Error{
             kind: :workflow_failed,
             reason: :explicit_failure,
             details: %{},
             usage: usage
           }}
      }

      assert {:error, %CommandOutcome{} = outcome} =
               CommandRunOutcome.project(
                 evidence,
                 settlement,
                 CommandRunRef.encode(@zero_entropy),
                 true
               )

      assert outcome.envelope["error"]["code"] == "internal_error"
      assert outcome.envelope["execution"]["state"] == "incomplete"
      assert outcome.envelope["execution"]["usage"] == nil
      assert_schema_valid(outcome.envelope)
    end
  end

  test "workflow timeout diagnostics name the binding limit and duration" do
    assert {:error, %CommandOutcome{} = outcome} =
             project_limit_exceeded(:timeout, %{
               limit: :parallel_timeout_ms,
               limit_ms: 60_000,
               phase: :execution
             })

    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"

    assert outcome.envelope["error"]["message"] ==
             "parallel_timeout_ms limit 60000 ms was exceeded during execution; raise limits.parallel_timeout_ms in the manifest, and the installed host ceiling if it is lower"

    assert_schema_valid(outcome.envelope)

    runtime_source = CommandSource.fixed(:runtime)

    for invalid_message <- [
          "parallel_timeout_ms limit 0 ms was exceeded during execution; raise limits.parallel_timeout_ms in the manifest, and the installed host ceiling if it is lower",
          "parallel_timeout_ms limit 060000 ms was exceeded during execution; raise limits.parallel_timeout_ms in the manifest, and the installed host ceiling if it is lower",
          "run_duration_ms limit 60000 ms was exceeded during execution; raise limits.run_duration_ms in the manifest, and the installed host ceiling if it is lower",
          "parallel_timeout_ms limit 60000 ms was exceeded during execution; raise limits.parallel_timeout_ms in the manifest, and the installed host ceiling if it is lower; private"
        ] do
      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
                 message: invalid_message,
                 source: runtime_source,
                 provider_activity: true
               )

      assert_schema_invalid(put_in(outcome.envelope, ["error", "message"], invalid_message))
    end
  end

  test "workflow heap diagnostics name the limit and bind the runtime source" do
    assert {:error, %CommandOutcome{} = outcome} =
             project_limit_exceeded(:memory_exceeded, %{
               limit: :workflow_heap_words,
               limit_value: 8_000_000
             })

    assert {:ok, expected} = RuntimeLimitDiagnostic.heap_words_message(8_000_000)
    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert outcome.envelope["error"]["message"] == expected
    assert outcome.envelope["error"]["source"] == %{"kind" => "runtime", "name" => "ptc-runtime"}
    assert outcome.envelope["error"]["subject"] == nil
    assert outcome.envelope["error"]["provider_activity"] == true
    assert_schema_valid(outcome.envelope)

    runtime_source = CommandSource.fixed(:runtime)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
               message: expected,
               provider_activity: true
             )

    assert {:ok, %CommandDiagnostic{source: ^runtime_source}} =
             CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
               message: expected,
               source: runtime_source,
               provider_activity: true
             )
  end

  test "max_calls diagnostics name the alias and bind the runtime source" do
    assert {:error, %CommandOutcome{} = outcome} =
             project_limit_exceeded(:capability_quota, %{
               limit: :max_calls,
               alias: "deepseek",
               limit_value: 4
             })

    assert {:ok, expected} = RuntimeLimitDiagnostic.max_calls_message("deepseek", 4)
    assert outcome.envelope["error"]["code"] == "capability_quota_exceeded"
    assert outcome.envelope["error"]["message"] == expected
    assert outcome.envelope["error"]["source"] == %{"kind" => "runtime", "name" => "ptc-runtime"}
    assert outcome.envelope["error"]["subject"] == nil
    assert outcome.envelope["error"]["provider_activity"] == true
    assert_schema_valid(outcome.envelope)

    runtime_source = CommandSource.fixed(:runtime)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:execution, :capability_quota_exceeded,
               message: expected,
               provider_activity: true
             )

    assert {:ok, %CommandDiagnostic{source: ^runtime_source}} =
             CommandDiagnostic.new(:execution, :capability_quota_exceeded,
               message: expected,
               source: runtime_source,
               provider_activity: true
             )
  end

  test "public quota diagnostics name the capability and bind the runtime source" do
    assert {:error, %CommandOutcome{} = outcome} =
             project_limit_exceeded(:capability_quota, %{
               limit: :workflow_capability_calls_per_name,
               name: "llm-request",
               limit_value: 2
             })

    assert {:ok, expected} =
             RuntimeLimitDiagnostic.capability_quota_message(
               :workflow_capability_calls_per_name,
               "llm-request",
               2
             )

    assert outcome.envelope["error"]["code"] == "capability_quota_exceeded"
    assert outcome.envelope["error"]["message"] == expected
    assert outcome.envelope["error"]["source"] == %{"kind" => "runtime", "name" => "ptc-runtime"}
    assert outcome.envelope["error"]["subject"] == nil
    assert outcome.envelope["error"]["provider_activity"] == true
    assert_schema_valid(outcome.envelope)
  end

  test "protocol_errors diagnostics name the limit and bind the runtime source" do
    assert {:error, %CommandOutcome{} = outcome} =
             project_limit_exceeded(:protocol_errors, %{
               limit: :protocol_errors,
               limit_value: 3
             })

    assert {:ok, expected} = RuntimeLimitDiagnostic.protocol_errors_message(3)
    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert outcome.envelope["error"]["message"] == expected
    assert outcome.envelope["error"]["source"] == %{"kind" => "runtime", "name" => "ptc-runtime"}
    assert_schema_valid(outcome.envelope)
  end

  test "aggregate budget diagnostics name the reservation and bind the runtime source" do
    assert {:error, %CommandOutcome{} = token_outcome} =
             project_limit_exceeded(:llm_total_tokens, %{
               limit: :llm_total_tokens,
               limit_value: 1,
               requested: 4_096,
               remaining: 1
             })

    assert {:ok, token_expected} =
             RuntimeLimitDiagnostic.budget_message(:llm_total_tokens, 1, 4_096, 1)

    assert token_outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert token_outcome.envelope["error"]["message"] == token_expected

    assert token_outcome.envelope["error"]["source"] == %{
             "kind" => "runtime",
             "name" => "ptc-runtime"
           }

    assert token_outcome.exit_status == 6
    assert_schema_valid(token_outcome.envelope)

    assert {:error, %CommandOutcome{} = cost_outcome} =
             project_limit_exceeded(:llm_cost_microusd, %{
               limit: :llm_cost_microusd,
               limit_value: 2_400,
               requested: 2_419,
               remaining: 2_338
             })

    assert {:ok, cost_expected} =
             RuntimeLimitDiagnostic.budget_message(:llm_cost_microusd, 2_400, 2_419, 2_338)

    assert cost_outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert cost_outcome.envelope["error"]["message"] == cost_expected
    assert cost_outcome.exit_status == 6
    assert_schema_valid(cost_outcome.envelope)

    runtime_source = CommandSource.fixed(:runtime)

    assert {:ok, token_expected} =
             RuntimeLimitDiagnostic.budget_message(:llm_total_tokens, 1, 4_096, 1)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
               message: token_expected,
               provider_activity: true
             )

    assert {:ok, %CommandDiagnostic{source: ^runtime_source, exit_status: 6}} =
             CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
               message: token_expected,
               source: runtime_source,
               provider_activity: true
             )

    maximum = 9_007_199_254_740_991

    assert {:ok, max_message} =
             RuntimeLimitDiagnostic.budget_message(:llm_total_tokens, maximum, maximum, 0)

    assert RuntimeLimitDiagnostic.budget_message?(max_message)

    assert {:ok, %CommandDiagnostic{}} =
             CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
               message: max_message,
               source: runtime_source,
               provider_activity: true
             )

    inconsistent = [
      "llm_total_tokens limit 1 tokens would be exceeded: the next call requires a 1 tokens reservation with 1 remaining; raise limits.llm_total_tokens in the manifest, and the installed host ceiling if it is lower",
      "llm_cost_microusd limit 2400 microUSD would be exceeded: the next call requires a 2338 microUSD reservation with 2419 remaining; raise limits.llm_cost_microusd in the manifest, and the installed host ceiling if it is lower",
      "llm_total_tokens limit 1 tokens would be exceeded: the next call requires a 0 tokens reservation with 0 remaining; raise limits.llm_total_tokens in the manifest, and the installed host ceiling if it is lower"
    ]

    for message <- inconsistent do
      refute RuntimeLimitDiagnostic.budget_message?(message)

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
                 message: message,
                 source: runtime_source,
                 provider_activity: true
               )
    end

    malformed = [
      "llm_total_tokens limit 01 tokens would be exceeded: the next call requires a 4096 tokens reservation with 1 remaining; raise limits.llm_total_tokens in the manifest, and the installed host ceiling if it is lower",
      token_expected <> "; private"
    ]

    for message <- malformed do
      refute RuntimeLimitDiagnostic.budget_message?(message)

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
                 message: message,
                 source: runtime_source,
                 provider_activity: true
               )

      assert_schema_invalid(put_in(token_outcome.envelope, ["error", "message"], message))
    end
  end

  test "application-authored turn-limit fields cannot claim an agent runtime limit" do
    usage = %{
      remaining_ms: 0,
      capability_calls: %{workflow: %{}, mission: %{}},
      subordinate_evaluations: 2,
      evaluations_by_mission: %{},
      protocol_errors: 2,
      agent_protocol_errors: 0,
      evaluation_memory_bytes: 0,
      evaluation_history_bytes: 0,
      evaluation_continuation_bytes: 0,
      events_dropped: %{},
      llm_budget: %{"total_tokens" => nil, "cost" => nil},
      llm_spend: %{"state" => "empty"}
    }

    evidence = %{
      result:
        {:error,
         %Error{
           kind: :workflow_failed,
           reason: :explicit_failure,
           details: %{
             failure_kind: "turn-limit",
             limit: :agent_turns,
             limit_value: 2
           },
           usage: usage
         }}
    }

    settlement =
      {:error,
       %{
         result_class: :normal,
         artifact_state: %{
           "trace" => "not_requested",
           "inspection" => "not_requested",
           "result" => "not_requested"
         },
         error: nil,
         secondary_errors: []
       }}

    assert {:error, %CommandOutcome{} = outcome} =
             CommandRunOutcome.project(
               evidence,
               settlement,
               CommandRunRef.encode(@zero_entropy),
               true
             )

    assert outcome.envelope["error"]["code"] == "workflow_failed"
    assert outcome.envelope["error"]["message"] == "the workflow failed"
    assert_schema_valid(outcome.envelope)
  end

  test "agent turn-limit diagnostics bind their bounded message to a null source" do
    runtime_source = CommandSource.fixed(:runtime)

    for limit <- [1, 128],
        reason <- RuntimeLimitDiagnostic.agent_turns_reasons() do
      assert {:ok, message} = RuntimeLimitDiagnostic.agent_turns_message(limit, reason)

      assert {:ok, %CommandDiagnostic{source: nil}} =
               CommandDiagnostic.new(:execution, :turn_limit_exceeded,
                 message: message,
                 provider_activity: true
               )

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:execution, :turn_limit_exceeded,
                 message: message,
                 source: runtime_source,
                 provider_activity: true
               )
    end

    for invalid_message <- [
          "agent turn limit 0 was exceeded; raise max_turns in the agent configuration, or reduce the work per turn",
          "agent turn limit 02 was exceeded; raise max_turns in the agent configuration, or reduce the work per turn",
          "agent turn limit 129 was exceeded; raise max_turns in the agent configuration, or reduce the work per turn",
          "agent turn limit 2 was exceeded; expose private details",
          "the model produced no valid tool call in 0 turns; raising max_turns repeats it. Check that the model supports tool calling and that any configured max_tokens leaves room for a complete call",
          "the model produced no valid tool call in 2 turns; raise max_turns"
        ] do
      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:execution, :turn_limit_exceeded,
                 message: invalid_message,
                 provider_activity: true
               )
    end

    assert {:ok, subordinate_message} =
             RuntimeLimitDiagnostic.subordinate_evaluations_message(4)

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
               message: subordinate_message,
               provider_activity: true
             )
  end

  @tag :tmp_dir
  test "a compilation heap kill names the workflow heap limit", %{tmp_dir: directory} do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "tiny", "path" => "tiny.clj"}],
        "entry" => "tiny/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"workflow_heap_words" => 1_000},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    application =
      write_application(directory, "compile-heap-exhausted", manifest, [
        {"tiny.clj", "(ns tiny) (defn run [input] (return input))"}
      ])

    trace_dir = Path.join(directory, "compile-heap-traces")
    File.mkdir_p!(trace_dir)

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--trace-dir", trace_dir])

    assert {:ok, expected} = RuntimeLimitDiagnostic.heap_words_message(1_000)
    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert outcome.exit_status == 6
    assert outcome.envelope["error"]["message"] == expected
    assert outcome.envelope["error"]["source"] == %{"kind" => "runtime", "name" => "ptc-runtime"}
    assert_schema_valid(outcome.envelope)

    assert [trace_path] = Path.wildcard(Path.join(trace_dir, "*.jsonl"))

    limit_event =
      trace_path
      |> File.stream!()
      |> Stream.map(&Jason.decode!/1)
      |> Enum.find(&(&1["type"] == "limit-exceeded"))

    assert limit_event["data"]["reason"] == "compile_memory_exceeded"
    assert limit_event["data"]["limit"] == "workflow_heap_words"
    assert limit_event["data"]["limit_value"] == 1_000
    assert limit_event["data"]["phase"] == "compilation"
  end

  @tag :tmp_dir
  test "a run that exhausts run_duration_ms reports the limit and its value", %{
    tmp_dir: directory
  } do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "slow", "path" => "slow.clj"}],
        "entry" => "slow/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"run_duration_ms" => 1},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    application =
      write_application(directory, "run-duration-exhausted", manifest, [
        {"slow.clj", "(ns slow) (defn run [input] (return (count (vec (range 2000000)))))"}
      ])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.envelope["error"]["code"] == "run_timeout"
    assert outcome.exit_status == 6

    assert outcome.envelope["error"]["message"] =~
             ~r/^run_duration_ms limit 1 ms was exceeded during (compilation|execution); raise limits\.run_duration_ms in the manifest, and the installed host ceiling if it is lower$/

    assert outcome.envelope["error"]["source"] == %{"kind" => "runtime", "name" => "ptc-runtime"}
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a workflow heap kill names the limit, its value, and the runtime source", %{
    tmp_dir: directory
  } do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "hungry", "path" => "hungry.clj"}],
        "entry" => "hungry/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"workflow_heap_words" => 400_000},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    application =
      write_application(directory, "heap-exhausted", manifest, [
        {"hungry.clj", "(ns hungry) (defn run [input] (return (count (vec (range 2000000)))))"}
      ])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert {:ok, expected} = RuntimeLimitDiagnostic.heap_words_message(400_000)
    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert outcome.exit_status == 6
    assert outcome.envelope["error"]["message"] == expected
    assert outcome.envelope["error"]["source"] == %{"kind" => "runtime", "name" => "ptc-runtime"}
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a limits-only host document raises a protected heap ceiling", %{tmp_dir: directory} do
    application =
      write_application(
        directory,
        "heap-raised",
        valid_manifest(%{"limits" => %{"workflow_heap_words" => 16_000_000}})
      )

    host_path =
      write_host_config(directory, "limits-only", %{
        "install" => %{},
        "limits" => %{"workflow_heap_words" => 16_000_000}
      })

    assert {:ok, %CommandOutcome{} = validated} =
             CommandEngine.prepare(["validate", application, "--host-config", host_path])

    assert validated.exit_status == 0
    assert_schema_valid(validated.envelope)

    limit =
      assert_error(["validate", application], "application", "installed_limit_exceeded")

    assert {:ok, expected} =
             RuntimeLimitDiagnostic.installed_ceiling_message(
               "workflow_heap_words",
               16_000_000,
               8_000_000
             )

    assert limit.envelope["error"]["message"] == expected
  end

  @tag :tmp_dir
  test "a result over terminal_result_bytes names the limit, its value, and the manifest key", %{
    tmp_dir: directory
  } do
    manifest = narrow_terminal_result_manifest(100)

    application =
      write_application(directory, "result-limit-exceeded", manifest, [
        {"wide.clj", ~s|(ns wide) (defn run [input] (return "#{String.duplicate("x", 200)}"))|}
      ])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.envelope["error"]["code"] == "result_limit_exceeded"
    assert outcome.exit_status == 7

    assert {:ok, expected} = RuntimeLimitDiagnostic.result_limit_message(100)
    assert outcome.envelope["error"]["message"] == expected
    assert outcome.envelope["error"]["message"] =~ "raise limits.terminal_result_bytes"
    assert_schema_valid(outcome.envelope)
  end

  test "an out-of-range agent option names the option, range, and rejected integer" do
    usage = %{
      remaining_ms: 0,
      capability_calls: %{workflow: %{}, mission: %{}},
      subordinate_evaluations: 0,
      evaluations_by_mission: %{"default" => 0},
      protocol_errors: 0,
      agent_protocol_errors: 0,
      evaluation_memory_bytes: 0,
      evaluation_history_bytes: 0,
      evaluation_continuation_bytes: 0,
      events_dropped: %{},
      llm_budget: %{"total_tokens" => nil, "cost" => nil},
      llm_spend: %{"state" => "empty"}
    }

    evidence = %{
      result:
        {:error,
         %Error{
           kind: :workflow_failed,
           reason: :invalid_agent_config,
           details: %{option: "max_turns", min: 1, max: 128, value: 129},
           usage: usage
         }}
    }

    settlement =
      {:error,
       %{
         result_class: :normal,
         artifact_state: %{
           "trace" => "not_requested",
           "inspection" => "not_requested",
           "result" => "not_requested"
         },
         error: nil,
         secondary_errors: []
       }}

    run_ref = CommandRunRef.encode(@zero_entropy)

    assert {:error, %CommandOutcome{} = outcome} =
             CommandRunOutcome.project(evidence, settlement, run_ref, true)

    assert outcome.envelope["error"]["code"] == "invalid_agent_config"
    assert outcome.envelope["error"]["source"] == nil

    assert outcome.envelope["error"]["message"] ==
             "max_turns 129 is outside the supported range 1–128 for agent.core/run; lower it"

    assert_schema_valid(outcome.envelope)

    string_evidence = %{
      evidence
      | result:
          {:error,
           %Error{
             kind: :workflow_failed,
             reason: :invalid_agent_config,
             details: %{option: "max_turns", min: 1, max: 128, type: :string},
             usage: usage
           }}
    }

    assert {:error, %CommandOutcome{} = typed} =
             CommandRunOutcome.project(string_evidence, settlement, run_ref, true)

    assert typed.envelope["error"]["message"] ==
             "max_turns must be an integer in 1–128 for agent.core/run; received a string"

    assert_schema_valid(typed.envelope)

    int64_min = -9_223_372_036_854_775_808

    min_evidence = %{
      evidence
      | result:
          {:error,
           %Error{
             kind: :workflow_failed,
             reason: :invalid_agent_config,
             details: %{option: "max_turns", min: 1, max: 128, value: int64_min},
             usage: usage
           }}
    }

    assert {:error, %CommandOutcome{} = minimum} =
             CommandRunOutcome.project(min_evidence, settlement, run_ref, true)

    assert minimum.envelope["error"]["code"] == "invalid_agent_config"

    assert minimum.envelope["error"]["message"] ==
             "max_turns #{int64_min} is outside the supported range 1–128 for agent.core/run; lower it"

    assert_schema_valid(minimum.envelope)

    drifted = %{
      evidence
      | result:
          {:error,
           %Error{
             kind: :workflow_failed,
             reason: :invalid_agent_config,
             details: %{option: "max_turns", min: 1, max: 4096, value: 129},
             usage: usage
           }}
    }

    assert {:error, %CommandOutcome{} = fallback} =
             CommandRunOutcome.project(drifted, settlement, run_ref, true)

    assert fallback.envelope["error"]["message"] ==
             "an agent configuration option is outside its supported range"
  end

  test "standalone return-contract failures retain their authenticated source and path" do
    {:ok, contract} =
      ValueContract.compile(%{
        "type" => "object",
        "required" => ["sum"],
        "properties" => %{"sum" => %{"type" => "integer", "minimum" => 100}}
      })

    failure =
      RuntimeTools.phase_return_contract_failure(%{
        "evidence" => %{contract: contract, source: "work.schema.json"}
      })

    assert %TrustedError{details: details} =
             failure.(%{
               "value" => %{"sum" => 3},
               "completion" => "invalid_return",
               "phase_index" => 1,
               "mission" => "default",
               "contract" => "evidence",
               "max_turns" => 1,
               "mode" => "fail"
             })

    usage = %{
      remaining_ms: 0,
      capability_calls: %{workflow: %{}, mission: %{}},
      subordinate_evaluations: 1,
      evaluations_by_mission: %{"default" => 1},
      protocol_errors: 0,
      agent_protocol_errors: 0,
      evaluation_memory_bytes: 0,
      evaluation_history_bytes: 0,
      evaluation_continuation_bytes: 0,
      events_dropped: %{},
      llm_budget: %{"total_tokens" => nil, "cost" => nil},
      llm_spend: %{"state" => "empty"}
    }

    evidence = %{
      result:
        {:error,
         %Error{
           kind: :workflow_failed,
           reason: :phase_return_contract_failed,
           details: details,
           usage: usage
         }}
    }

    settlement =
      {:error,
       %{
         result_class: :normal,
         artifact_state: %{
           "trace" => "not_requested",
           "inspection" => "not_requested",
           "result" => "not_requested"
         },
         error: nil,
         secondary_errors: []
       }}

    assert {:error, %CommandOutcome{} = outcome} =
             CommandRunOutcome.project(
               evidence,
               settlement,
               CommandRunRef.encode(@zero_entropy),
               true
             )

    assert outcome.envelope["error"]
           |> Map.take(~w(phase code source path)) == %{
             "phase" => "execution",
             "code" => "phase_return_contract_failed",
             "source" => %{
               "kind" => "phase_return_contract",
               "name" => "work.schema.json"
             },
             "path" => "/sum"
           }

    assert_schema_valid(outcome.envelope)
  end

  test "transcript-ceiling diagnostics bind their bounded message to a null source" do
    runtime_source = CommandSource.fixed(:runtime)

    for limit <- [1, 262_144, 1_000_000] do
      assert {:ok, message} = RuntimeLimitDiagnostic.transcript_chars_message(limit)

      assert {:ok, %CommandDiagnostic{source: nil, exit_status: 6}} =
               CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
                 message: message,
                 provider_activity: true
               )

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
                 message: message,
                 source: runtime_source,
                 provider_activity: true
               )
    end

    for invalid_limit <- [0, 1_000_001, "6000"] do
      assert :error = RuntimeLimitDiagnostic.transcript_chars_message(invalid_limit)
    end

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:execution, :runtime_limit_exceeded,
               message: "transcript limit 0 characters was exceeded",
               provider_activity: true
             )
  end

  test "a run timeout names the configured run_duration_ms rather than only timing out" do
    assert {:ok, message} =
             RuntimeLimitDiagnostic.live_timeout_message(:run_duration_ms, 3_000, :execution)

    assert message ==
             "run_duration_ms limit 3000 ms was exceeded during execution; raise limits.run_duration_ms in the manifest, and the installed host ceiling if it is lower"

    # The wall-clock stop keeps its own code and status, so a script can still
    # separate it from a turn limit on more than the exit code.
    assert {:ok, %CommandDiagnostic{code: :run_timeout, exit_status: 6}} =
             CommandDiagnostic.new(:execution, :run_timeout,
               message: message,
               source: CommandSource.fixed(:runtime),
               provider_activity: true
             )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:execution, :run_timeout,
               message: message,
               provider_activity: true
             )

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:execution, :run_timeout,
               message:
                 "run_duration_ms limit 0 ms was exceeded during execution; raise limits.run_duration_ms in the manifest, and the installed host ceiling if it is lower",
               source: CommandSource.fixed(:runtime),
               provider_activity: true
             )
  end

  @tag :tmp_dir
  test "frontend environment setup fails before the execution owner and activity marker", %{
    tmp_dir: directory
  } do
    host_path = write_host_config(directory, "environment-setup", env_credential_host())
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

  @tag :tmp_dir
  test "a missing named environment file reports the concrete cause", %{
    tmp_dir: directory
  } do
    # The file the operator names by hand is the likeliest first-run mistake, so
    # it must not answer with the code reserved for a broken runtime. An
    # embedding host's own failing setup callback stays internal; only the named
    # dotenv file is user input this layer can classify.
    host_path = write_host_config(directory, "env-file-missing", env_credential_host())
    application = doctor_application(directory, "env-file-missing", workflow: ["model"])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch([
               "run",
               application,
               "--host-config",
               host_path,
               "--env-file",
               Path.join(directory, "absent.env")
             ])

    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "environment_file_not_found"
    assert outcome.envelope["error"]["message"] == "the named environment file does not exist"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["execution"] == %{"state" => "not_started"}
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "an artifact destination under a missing directory names that cause", %{
    tmp_dir: directory
  } do
    # `--trace-dir` already names this exact condition. The result and inspection
    # destinations computed the same cause and discarded it, so a missing parent
    # directory was indistinguishable from every other unavailable destination.
    application = write_application(directory, "destination-parent", valid_manifest())
    absent = Path.join(directory, "absent")

    for {switch, destination, code} <- [
          {"--output", Path.join(absent, "result.json"), "result_directory_missing"},
          {"--private-output", Path.join(absent, "result.json"), "result_directory_missing"},
          {"--inspect", Path.join(absent, "run.ptcins"), "inspection_directory_missing"}
        ] do
      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.dispatch(["run", application, switch, destination])

      assert outcome.envelope["error"]["code"] == code
      assert outcome.envelope["error"]["message"] =~ "existing"
      assert_schema_valid(outcome.envelope)
    end
  end

  @tag :tmp_dir
  test "doctor answers an unreadable environment file the same way run does", %{
    tmp_dir: directory
  } do
    host_path = write_host_config(directory, "doctor-env-file", env_credential_host())
    application = doctor_application(directory, "doctor-env-file", workflow: ["model"])
    absent = Path.join(directory, "absent.env")

    for argv <- [
          ["doctor", application, "--host-config", host_path, "--env-file", absent, "--connect"],
          ["run", application, "--host-config", host_path, "--env-file", absent]
        ] do
      assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(argv)

      assert outcome.envelope["error"]["phase"] == "local_preflight"
      assert outcome.envelope["error"]["code"] == "environment_file_not_found"
      assert_schema_valid(outcome.envelope)
    end
  end

  test "an embedding host's own setup failure stays undifferentiated" do
    # Only the dotenv attachment knows the operator named a file. A caller
    # supplying its own callback must not have an arbitrary failure relabelled
    # as a bad --env-file.
    assert {:ok, runtime} =
             CommandRuntime.new(environment_setup: fn -> {:error, :environment_file_invalid} end)

    assert CommandRuntime.setup_environment(runtime) == {:error, :environment_setup_failed}

    assert CommandRuntime.setup_environment_diagnostic(runtime) ==
             {:error, :environment_setup_failed}
  end

  test "invocation-scoped local-preflight codes assert no provider activity" do
    # Every other local-preflight row spans the activity marker and admits either
    # value. These three are decided before any provider runs, so a `true` must
    # be unconstructible rather than merely unused by their producers.
    for code <- [
          :environment_file_not_found,
          :authorization_target_unknown,
          :authorization_not_applicable
        ] do
      assert DiagnosticCatalog.provider_activity_policy(:local_preflight, code) == false

      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(:local_preflight, code,
                 subject: authorization_subject(code),
                 provider_activity: true
               )
    end
  end

  test "run-only authorization codes are not doctor findings" do
    # `doctor` accepts no --authorize-mcp, so it can never produce these. They
    # are subject-bearing local-preflight rows and would otherwise be attributed
    # to a doctor check that cannot report them.
    doctor_codes = Enum.map(DiagnosticCatalog.doctor_attributable_rows(), & &1.code)
    local_codes = Map.get(DiagnosticCatalog.doctor_failure_codes_by_operation(), :local, [])

    for code <- [:authorization_target_unknown, :authorization_not_applicable] do
      refute code in doctor_codes
      refute code in local_codes
    end

    assert :environment_unavailable in local_codes
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
  test "plain doctor locally refuses uncataloged cost reservation pricing", %{
    tmp_dir: directory
  } do
    application =
      doctor_application(directory, "uncataloged-pricing", workflow: ["model"], mission: [])

    installation = %{
      "source" => "llm",
      "structured_output_mode" => "unsupported",
      "usage_guarantees" => %{"tokens" => true, "cost_currency" => "USD"},
      "reservation_tariff" => %{"currency" => "USD", "id" => "test-tariff-v1"},
      "installation_revision" => "model-v1",
      "model" => "openrouter:future-vendor/future-priced-model-1781",
      "credential" => "key"
    }

    host = %{
      "limits" => %{"llm_cost_microusd" => 100_000},
      "credentials" => %{"key" => %{"literal" => "unused-test-secret"}},
      "install" => %{"model" => installation}
    }

    host_path = write_host_config(directory, "uncataloged-pricing", host)
    argv = [application, "--host-config", host_path]

    assert {:ok, %CommandOutcome{} = validated} = CommandEngine.dispatch(["validate" | argv])
    assert validated.exit_status == 0

    assert {:error, %CommandOutcome{} = doctored} = CommandEngine.dispatch(["doctor" | argv])
    assert doctored.exit_status == 4
    assert doctored.envelope["error"]["phase"] == "local_preflight"
    assert doctored.envelope["error"]["code"] == "model_contract_unsupported"
    assert doctored.envelope["error"]["provider_activity"] == false

    result = doctored.envelope["result"]

    assert %{"status" => "fail", "code" => "model_contract_unsupported"} =
             Enum.find(result["checks"], &(&1["name"] == "provider/model/local"))

    assert result["provider_activity"] == false
    assert result["usage"] == %{"llm_usage_state" => "available", "llm_usage" => []}
    assert [warning] = doctored.envelope["warnings"]
    assert warning["code"] == "model_uncataloged"
    assert warning["provider"] == "model"
    assert warning["model"] == installation["model"]
    assert_schema_valid(doctored.envelope)

    assert {:stdio, rendered_result, rendered_warnings} = CommandRenderer.render(doctored)
    assert Jason.decode!(rendered_result) == result
    assert rendered_warnings =~ "warning: model_uncataloged:"
    assert rendered_warnings =~ installation["model"]

    refute CommandContract.valid_envelope?(
             put_in(doctored.envelope, ["warnings", Access.at(0), "provider"], "other")
           )

    {:ok, primary_subject} =
      CommandSubject.provider("model", :local, %{destination: :workflow, index: 0})

    {:ok, primary_warning} = CommandWarning.model_uncataloged("model", installation["model"])

    primary =
      CommandDiagnostic.new!(:local_preflight, :model_contract_unsupported,
        subject: primary_subject,
        provider_activity: false,
        message: ModelContractDiagnostic.cost_reservation_pricing_message(installation["model"]),
        warnings: [primary_warning]
      )

    {:ok, unrelated_subject} =
      CommandSubject.provider("other", :local, %{destination: :workflow, index: 0})

    {:ok, unrelated_warning} = CommandWarning.model_uncataloged("other", installation["model"])

    unrelated =
      CommandDiagnostic.new!(:local_preflight, :model_contract_unsupported,
        subject: unrelated_subject,
        provider_activity: false,
        message: ModelContractDiagnostic.cost_reservation_pricing_message(installation["model"]),
        warnings: [unrelated_warning]
      )

    assert_raise ArgumentError, fn ->
      CommandOutcome.doctor_failure(
        :doctor,
        doctored.envelope["run_ref"],
        result,
        primary,
        [],
        [unrelated]
      )
    end

    replay_result = put_in(result, ["model_aliases", Access.at(0), "source"], "llm_replay")

    refute CommandContract.valid_envelope?(%{
             doctored.envelope
             | "result" => replay_result
           })

    assert_raise ArgumentError, fn ->
      CommandOutcome.doctor_failure(
        :doctor,
        doctored.envelope["run_ref"],
        replay_result,
        primary,
        [],
        [primary]
      )
    end

    mixed_result =
      update_in(result["checks"], fn checks ->
        Enum.map(checks, fn
          %{"name" => "provider/model/local"} = check ->
            %{check | "code" => "adapter_unavailable"}

          check ->
            check
        end)
      end)

    mixed_primary =
      CommandDiagnostic.new!(:local_preflight, :adapter_unavailable,
        subject: primary_subject,
        provider_activity: false
      )

    mixed =
      CommandOutcome.doctor_failure(
        :doctor,
        doctored.envelope["run_ref"],
        mixed_result,
        mixed_primary,
        [],
        [primary]
      )

    assert mixed.envelope["warnings"] == [warning]
    assert CommandContract.valid_envelope?(mixed.envelope)

    assert {:error, %CommandOutcome{} = run} = CommandEngine.dispatch(["run" | argv])
    assert run.exit_status == 4
    assert run.envelope["error"]["phase"] == "local_preflight"
    assert run.envelope["error"]["code"] == "model_contract_unsupported"
    assert run.envelope["error"]["message"] == doctored.envelope["error"]["message"]

    control_path =
      write_host_config(directory, "uncataloged-pricing-control", Map.delete(host, "limits"))

    control_argv = [application, "--host-config", control_path]

    assert {:ok, %CommandOutcome{} = control_doctor} =
             CommandEngine.dispatch(["doctor" | control_argv])

    assert control_doctor.exit_status == 0

    assert %{"status" => "pass", "code" => "available"} =
             Enum.find(
               control_doctor.envelope["result"]["checks"],
               &(&1["name"] == "provider/model/local")
             )

    assert {:ok, %CommandOutcome{} = control_run} = CommandEngine.dispatch(["run" | control_argv])
    assert control_run.exit_status == 0
    assert_schema_valid(control_run.envelope)
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

  @tag :tmp_dir
  test "models names the configured selector and withholds an endpoint-bearing one", %{
    tmp_dir: directory
  } do
    host_path =
      write_host_config(directory, "selector-models", %{
        "credentials" => %{"key" => %{"env" => "PTC_TEST_ABSENT_KEY"}},
        "install" => %{
          "cataloged" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "cataloged-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          },
          "endpoint" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "endpoint-v1",
            "model" => "openai-compat:https://private.example/v1|deployment",
            "credential" => "key"
          },
          "tooling" => inert_stdio_installation("tooling-v1")
        }
      })

    assert {:ok, %CommandOutcome{} = modeled} =
             CommandEngine.prepare(["models", "--host-config", host_path])

    assert [cataloged, endpoint, tooling] = modeled.envelope["result"]["installations"]
    assert cataloged["alias"] == "cataloged"
    assert cataloged["model_selector"] == "openrouter:test/model"
    assert endpoint["alias"] == "endpoint"
    refute Map.has_key?(endpoint, "model_selector")
    assert tooling["alias"] == "tooling"
    refute Map.has_key?(tooling, "model_selector")
    assert_schema_valid(modeled.envelope)
  end

  @tag :tmp_dir
  test "doctor --show-model-selectors applies the same disclosure rule as models", %{
    tmp_dir: directory
  } do
    application =
      write_application(
        directory,
        "selector-doctor",
        valid_manifest(%{
          "providers" => %{
            "workflow" => [
              %{"name" => "cataloged", "config" => %{}},
              %{"name" => "endpoint", "config" => %{}}
            ],
            "mission" => []
          }
        })
      )

    host_path =
      write_host_config(directory, "selector-doctor", %{
        "credentials" => %{"key" => %{"env" => "PTC_TEST_ABSENT_KEY"}},
        "install" => %{
          "cataloged" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "cataloged-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          },
          "endpoint" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "endpoint-v1",
            "model" => "openai-compat:https://private.example/v1|deployment",
            "credential" => "key"
          }
        }
      })

    argv = ["doctor", application, "--host-config", host_path]

    assert {:ok, %CommandOutcome{} = plain} = CommandEngine.prepare(argv)

    assert Enum.all?(
             plain.envelope["result"]["model_aliases"],
             &(not Map.has_key?(&1, "model_selector"))
           )

    assert {:ok, %CommandOutcome{} = shown} =
             CommandEngine.prepare(argv ++ ["--show-model-selectors"])

    assert [cataloged, endpoint] = shown.envelope["result"]["model_aliases"]
    assert cataloged["alias"] == "cataloged"
    assert cataloged["model_selector"] == "openrouter:test/model"
    assert endpoint["alias"] == "endpoint"
    refute Map.has_key?(endpoint, "model_selector")
    assert_schema_valid(shown.envelope)
  end

  test "default doctor reports the environment without an application or host" do
    assert {:ok, %CommandOutcome{} = outcome} = CommandEngine.prepare(["doctor"])

    assert outcome.exit_status == 0
    assert outcome.envelope["command"] == "doctor"
    assert outcome.envelope["result"]["provider_activity"] == false
    assert outcome.envelope["result"]["readiness"] == "not_applicable"

    checks = outcome.envelope["result"]["checks"]
    assert Enum.map(checks, & &1["name"]) == ["runtime", "application", "viewer"]

    assert %{"status" => "skipped", "code" => "not_requested"} =
             Enum.find(checks, &(&1["name"] == "application"))

    assert_schema_valid(outcome.envelope)
    assert CommandContract.valid_success_semantics?(:doctor, outcome.envelope["result"])
  end

  @tag :tmp_dir
  test "doctor reports an invalid application as a failed readiness check", %{
    tmp_dir: directory
  } do
    manifest =
      valid_manifest()
      |> put_in(["workflow", "components", Access.at(0), "path"], "../main.clj")

    application = write_application(directory, "invalid-doctor-application", manifest)
    host_path = write_host_config(directory, "invalid-doctor-application", valid_host_config())

    for {mode, suffix} <- [{:doctor, []}, {{:doctor, :connect}, ["--connect"]}] do
      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.prepare(
                 ["doctor", application, "--host-config", host_path] ++ suffix
               )

      assert outcome.command_mode == mode
      assert outcome.exit_status == 3

      assert outcome.envelope["error"] == %{
               "phase" => "application",
               "code" => "schema_violation",
               "message" => "the application manifest violates the pattern schema rule",
               "source" => %{"kind" => "application", "name" => "ptc.json"},
               "path" => "/workflow/components/0/path",
               "span" => nil,
               "subject" => nil,
               "notes" => [],
               "retryable" => false,
               "provider_activity" => false
             }

      assert outcome.envelope["secondary_errors"] == []

      assert outcome.envelope["result"] == %{
               "checks" => [
                 %{"name" => "runtime", "status" => "pass", "code" => "supported"},
                 %{
                   "name" => "application",
                   "status" => "fail",
                   "code" => "schema_violation"
                 },
                 %{"name" => "viewer", "status" => "pass", "code" => "available"},
                 %{
                   "name" => "provider/workspace/local",
                   "status" => "skipped",
                   "code" => "not_verified_due_to_failure"
                 },
                 %{
                   "name" => "provider/workspace/connectivity",
                   "status" => "skipped",
                   "code" => "not_verified_due_to_failure"
                 }
               ],
               "model_aliases" => [],
               "provider_activity" => false,
               "readiness" => "failed",
               "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
             }

      assert_schema_valid(outcome.envelope)
    end
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
    assert outcome.envelope["result"]["readiness"] == "unverified"
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
  test "default doctor reports a missing stdio command as a failed local check", %{
    tmp_dir: directory
  } do
    host_path =
      write_host_config(directory, "doctor-missing-command", %{
        "install" => %{
          "workspace" => inert_stdio_installation("missing-command-v1")
        }
      })

    application = doctor_application(directory, "selects-missing-command", mission: ["workspace"])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert outcome.command_mode == :doctor
    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "command_not_found"
    assert outcome.envelope["result"]["readiness"] == "failed"
    assert outcome.envelope["result"]["provider_activity"] == false

    assert %{"status" => "fail", "code" => "command_not_found"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/workspace/local")
             )

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "default doctor distinguishes an unusable stdio executable from a missing command", %{
    tmp_dir: directory
  } do
    executable = Path.join(directory, "not-executable")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o644)

    host_path =
      write_host_config(
        directory,
        "doctor-unusable-command",
        stdio_host_config(executable, System.find_executable("sh"), directory)
      )

    application =
      doctor_application(directory, "selects-unusable-command", mission: ["workspace"])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "executable_unavailable"

    assert %{"status" => "fail", "code" => "executable_unavailable"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/workspace/local")
             )

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "default doctor reports unreadable replay fixtures as a failed local check", %{
    tmp_dir: directory
  } do
    host_path =
      write_host_config(directory, "doctor-missing-replay", %{
        "install" => %{
          "frozen-model" => %{
            "source" => "llm_replay",
            "installation_revision" => "missing-replay-v1",
            "fixtures" => "missing-replay.jsonl"
          }
        }
      })

    application =
      doctor_application(directory, "selects-missing-replay", workflow: ["frozen-model"])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert outcome.command_mode == :doctor
    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "fixtures_unreadable"
    assert outcome.envelope["result"]["readiness"] == "failed"
    assert outcome.envelope["result"]["provider_activity"] == false

    assert %{"status" => "fail", "code" => "fixtures_unreadable"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/frozen-model/local")
             )

    assert_schema_valid(outcome.envelope)

    assert {:error, %CommandOutcome{} = run_outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert run_outcome.envelope["error"]["phase"] == "local_preflight"
    assert run_outcome.envelope["error"]["code"] == "environment_unavailable"
    assert run_outcome.envelope["error"]["subject"]["name"] == "frozen-model"
    assert run_outcome.envelope["error"]["subject"]["operation"] == "local"
    assert_schema_valid(run_outcome.envelope)
  end

  @tag :tmp_dir
  test "default doctor parses a valid replay fixture as an available local check", %{
    tmp_dir: directory
  } do
    File.write!(
      Path.join(directory, "replay.jsonl"),
      Jason.encode!(%{
        "schema_version" => 1,
        "request_hash" => "sha256:" <> String.duplicate("0", 64),
        "response" => %{"content" => "frozen"}
      }) <> "\n"
    )

    host_path =
      write_host_config(directory, "doctor-valid-replay", %{
        "install" => %{
          "frozen-model" => %{
            "source" => "llm_replay",
            "installation_revision" => "valid-replay-v1",
            "fixtures" => "replay.jsonl"
          }
        }
      })

    application =
      doctor_application(directory, "selects-valid-replay", workflow: ["frozen-model"])

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert %{"status" => "pass", "code" => "available"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/frozen-model/local")
             )

    assert outcome.envelope["result"]["readiness"] == "ready"
    assert outcome.envelope["result"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "default doctor admits a valid replay response near its configured ceiling", %{
    tmp_dir: directory
  } do
    File.write!(
      Path.join(directory, "large-replay.jsonl"),
      Jason.encode!(%{
        "schema_version" => 1,
        "request_hash" => "sha256:" <> String.duplicate("1", 64),
        "response" => %{"content" => String.duplicate("x", 900_000)}
      }) <> "\n"
    )

    host_path =
      write_host_config(directory, "doctor-large-replay", %{
        "install" => %{
          "frozen-model" => %{
            "source" => "llm_replay",
            "installation_revision" => "large-replay-v1",
            "fixtures" => "large-replay.jsonl"
          }
        }
      })

    application =
      doctor_application(directory, "selects-large-replay", workflow: ["frozen-model"])

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert %{"status" => "pass", "code" => "available"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/frozen-model/local")
             )

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "default doctor completes every local check after an ordinary failure", %{
    tmp_dir: directory
  } do
    host_path =
      write_host_config(directory, "doctor-multiple-local-failures", %{
        "install" => %{
          "frozen-model" => %{
            "source" => "llm_replay",
            "installation_revision" => "missing-replay-v1",
            "fixtures" => "missing-replay.jsonl"
          },
          "workspace" => inert_stdio_installation("missing-command-v1")
        }
      })

    application =
      doctor_application(directory, "selects-two-broken-providers",
        workflow: ["frozen-model"],
        mission: ["workspace"]
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    checks = outcome.envelope["result"]["checks"]

    assert %{"status" => "fail", "code" => "fixtures_unreadable"} =
             Enum.find(checks, &(&1["name"] == "provider/frozen-model/local"))

    assert %{"status" => "fail", "code" => "command_not_found"} =
             Enum.find(checks, &(&1["name"] == "provider/workspace/local"))

    assert outcome.envelope["result"]["readiness"] == "failed"
    assert outcome.envelope["result"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a failing audited-local check fails its row without provider activity", %{
    tmp_dir: directory
  } do
    host_path =
      write_host_config(
        directory,
        "doctor-local-fail",
        literal_credential_host("not-read", "definitely-not-a-model")
      )

    application = doctor_application(directory, "selects-model", workflow: ["model"])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["doctor", application, "--host-config", host_path])

    assert outcome.envelope["command"] == "doctor"
    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "adapter_unavailable"
    assert outcome.envelope["error"]["subject"]["name"] == "model"
    assert outcome.envelope["error"]["subject"]["operation"] == "local"
    assert outcome.envelope["error"]["provider_activity"] == false

    assert %{
             "readiness" => "failed",
             "provider_activity" => false,
             "checks" => checks
           } = outcome.envelope["result"]

    assert %{"status" => "fail", "code" => "adapter_unavailable"} =
             Enum.find(checks, &(&1["name"] == "provider/model/local"))

    assert %{"status" => "skipped", "code" => "requires_connect"} =
             Enum.find(checks, &(&1["name"] == "provider/model/credentials"))

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
    assert outcome.envelope["result"]["readiness"] == "ready"

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
    assert outcome.envelope["result"]["readiness"] == "not_applicable"
    refute File.exists?(marker)
    assert_schema_valid(outcome.envelope)
    assert CommandContract.valid_success_result?(:doctor, outcome.envelope["result"])
  end

  @tag :tmp_dir
  test "doctor --connect distinguishes a declared MCP tool missing from the server", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "missing-tool-methods")

    missing_tool_host =
      marker
      |> connect_host_config()
      |> put_in(
        ["install", "workspace", "tools"],
        %{
          "structuredMissing" => %{
            "as" => "workspace.structured",
            "effect" => "write",
            "model_visible" => true
          }
        }
      )

    host_path = write_host_config(directory, "missing-tool", missing_tool_host)

    application =
      doctor_application(directory, "selects-missing-tool",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000}
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.envelope["error"]["phase"] == "provider_acquisition"
    assert outcome.envelope["error"]["code"] == "provider_tool_missing"

    assert outcome.envelope["error"]["message"] ==
             ~s(the installed endpoint does not expose declared tool "structuredMissing")

    assert %{"status" => "fail", "code" => "provider_tool_missing"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/workspace/connectivity")
             )

    assert File.read!(marker) =~ "tools/list"
    refute outcome.envelope["error"]["message"] =~ "it exposes"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "doctor --connect reports an unsupported MCP profile and closes stdio", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "unsupported-doctor-methods")

    host_path =
      write_host_config(
        directory,
        "unsupported-doctor",
        connect_host_config(marker, "unsupported-protocol")
      )

    application =
      doctor_application(directory, "doctor-unsupported-profile",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 5_000}}],
        limits: %{"evaluation_timeout_ms" => 5_000}
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.envelope["error"]["code"] == "provider_protocol_version_unsupported"
    assert outcome.exit_status == 4
    assert outcome.envelope["error"]["retryable"] == false

    assert outcome.envelope["error"]["message"] ==
             "the endpoint rejected the required server/discover method and does not support MCP protocol 2026-07-28"

    assert %{"status" => "fail", "code" => "provider_protocol_version_unsupported"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/workspace/connectivity")
             )

    encoded = Jason.encode!(outcome.envelope)
    refute encoded =~ "PRIVATE_REMOTE_MESSAGE"
    refute encoded =~ "PRIVATE_REMOTE_DATA"
    refute encoded =~ "PRIVATE_STDERR_DETAIL"
    refute encoded =~ "PRIVATE_LAUNCH_ARGUMENT"

    assert {:stdout, rendered} = CommandRenderer.render(outcome)
    assert rendered =~ "provider_protocol_version_unsupported"
    refute rendered =~ "PRIVATE_REMOTE_MESSAGE"
    refute rendered =~ "PRIVATE_REMOTE_DATA"
    refute rendered =~ "PRIVATE_STDERR_DETAIL"
    refute rendered =~ "PRIVATE_LAUNCH_ARGUMENT"

    assert File.read!(marker) =~ "server/discover"
    refute File.read!(marker) =~ "tools/list"
    assert File.read!(marker) =~ "session-closed"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "doctor --connect separates an acquisition timeout from an unreachable provider", %{
    tmp_dir: directory
  } do
    # Issue #1453. The server here is healthy and would answer `server/discover`
    # with the same `-32601` the test above classifies; it is only slower than
    # the budget. Reporting that as `provider_unavailable` sent three separate
    # investigations after the transport, because the one fact that ends it —
    # nothing was wrong except the clock — was the fact being withheld. A cold
    # `npx` launch and a loaded machine both land here.
    marker = Path.join(directory, "slow-doctor-methods")

    host_config =
      update_in(
        connect_host_config(marker, "slow-unsupported-protocol"),
        ["install", "workspace", "ceilings", "timeout_ms"],
        fn _default -> 1_000 end
      )

    host_path = write_host_config(directory, "slow-doctor", host_config)

    application =
      doctor_application(directory, "doctor-slow-profile",
        mission: [{"workspace", %{"allow" => ["workspace.structured"], "timeout_ms" => 1_000}}],
        limits: %{"evaluation_timeout_ms" => 1_000}
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.envelope["error"]["code"] == "provider_acquisition_timeout"
    assert outcome.exit_status == 4
    # Retryable, because the same launch usually answers once the cache is warm.
    assert outcome.envelope["error"]["retryable"] == true

    assert %{"status" => "fail", "code" => "provider_acquisition_timeout"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/workspace/connectivity")
             )

    # The marker proves which step ran out of clock. `:mcp_timeout` also carries
    # launcher staging and spawn expiry, so without this the test would pass on a
    # slow spawn and stop covering the case it is named for: discovery was
    # reached, and the answer was merely late.
    assert File.read!(marker) =~ "server/discover"
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "doctor --connect preserves a provider-bearing no-op result", %{tmp_dir: directory} do
    trace_directory = Path.join(directory, "traces")
    File.mkdir_p!(trace_directory)

    host_path =
      write_host_config(directory, "connect-no-op", %{
        "install" => %{
          "history" => %{
            "source" => "ptc_trace_snapshot",
            "installation_revision" => "history-v1",
            "directory" => trace_directory,
            "ceilings" => %{
              "max_source_bytes" => 2_000_000,
              "max_result_bytes" => 250_000
            }
          }
        }
      })

    application = doctor_application(directory, "selects-no-op", mission: ["history"])

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    checks = outcome.envelope["result"]["checks"]
    assert Enum.any?(checks, &(&1["name"] == "provider/history/local"))
    assert outcome.envelope["result"]["provider_activity"] == false
    assert_schema_valid(outcome.envelope)
    assert CommandContract.valid_success_result?(:doctor, outcome.envelope["result"])
  end

  @tag :tmp_dir
  test "an impossible trace budget fails doctor admission before the activity marker", %{
    tmp_dir: directory
  } do
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
    assert outcome.envelope["error"]["phase"] == "application"
    assert outcome.envelope["error"]["code"] == "limit_configuration_invalid"
    assert outcome.envelope["error"]["provider_activity"] == false
    refute File.exists?(marker)
    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "run rejects impossible trace budgets with not-started activity evidence", %{
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
      assert outcome.envelope["error"]["phase"] == "application"
      assert outcome.envelope["error"]["code"] == "limit_configuration_invalid"
      assert outcome.envelope["error"]["provider_activity"] == false
      assert outcome.envelope["execution"] == %{"state" => "not_started"}
      assert_schema_valid(outcome.envelope)
    end

    refute File.exists?(marker)
  end

  @tag :tmp_dir
  test "a stale mission capability requirement remains actionable after acquisition", %{
    tmp_dir: directory
  } do
    trace_directory = Path.join(directory, "legacy-capability-traces")
    File.mkdir_p!(trace_directory)

    host_path =
      write_host_config(directory, "legacy-capability", %{
        "install" => %{
          "history" => %{
            "source" => "ptc_trace_snapshot",
            "installation_revision" => "history-v1",
            "directory" => trace_directory,
            "ceilings" => %{
              "max_source_bytes" => 2_000_000,
              "max_result_bytes" => 250_000
            }
          }
        }
      })

    application =
      write_application(
        directory,
        "legacy-capability",
        valid_manifest(%{
          "missions" => %{
            "default" => %{
              "components" => [%{"id" => "legacy", "path" => "legacy.clj"}],
              "data" => %{},
              "providers" => ["history"]
            }
          },
          "providers" => %{
            "workflow" => [],
            "mission" => [%{"name" => "history", "config" => %{}}]
          }
        }),
        %{
          "legacy.clj" =>
            "(ns legacy) (defn inspect [input] (tool/history.list-runs {\"limit\" 1}))"
        }
      )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert outcome.envelope["error"]["phase"] == "provider_acquisition"
    assert outcome.envelope["error"]["code"] == "capability_requirement_missing"

    assert outcome.envelope["error"]["message"] ==
             "Missing capability requirement: history.list-runs"

    assert outcome.envelope["error"]["provider_activity"] == true

    assert outcome.envelope["execution"] == %{
             "state" => "incomplete",
             "usage" => nil,
             "evaluation_memory" => nil,
             "last_evaluation_error" => nil
           }

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a provider-free capability requirement remains actionable without activity", %{
    tmp_dir: directory
  } do
    application =
      write_application(directory, "provider-free-capability", valid_manifest(), %{
        "main.clj" => "(ns app) (defn run [input] (tool/history.list-runs {\"limit\" 1}))"
      })

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch(["run", application])

    assert outcome.envelope["error"] == %{
             "phase" => "provider_acquisition",
             "code" => "capability_requirement_missing",
             "message" => "Missing capability requirement: history.list-runs",
             "provider_activity" => false,
             "retryable" => false,
             "source" => nil,
             "span" => nil,
             "subject" => nil,
             "path" => nil,
             "notes" => []
           }

    assert outcome.envelope["execution"] == %{"state" => "not_started"}

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a failing check under --connect reports the attributed row", %{
    tmp_dir: directory
  } do
    # This one fails in the shared phase-7 step, which the connect operation
    # crosses through `ProviderExecution` before the activity marker. Doctor
    # retains the diagnostic as the error authority while projecting its
    # attributable local check as a finding.
    host_path =
      write_host_config(
        directory,
        "connect-local-fail",
        literal_credential_host("not-read", "definitely-not-a-model")
      )

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
    assert outcome.exit_status == 4
    assert outcome.envelope["error"]["phase"] == "local_preflight"
    assert outcome.envelope["error"]["code"] == "adapter_unavailable"
    assert outcome.envelope["error"]["subject"]["name"] == "model"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.envelope["secondary_errors"] == []

    assert %{
             "readiness" => "failed",
             "provider_activity" => false,
             "checks" => checks
           } = outcome.envelope["result"]

    assert %{"status" => "fail", "code" => "adapter_unavailable"} =
             Enum.find(checks, &(&1["name"] == "provider/model/local"))

    assert %{"status" => "skipped", "code" => "not_verified_due_to_failure"} =
             Enum.find(checks, &(&1["name"] == "provider/model/credentials"))

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a credential written by an ordinary shell redirect is usable, not internal", %{
    tmp_dir: directory
  } do
    # `printf '%s\\n' "$TOKEN" > tok.txt`, `echo`, an editor save, and
    # `gh auth token > file` all produce the trailing newline, and the host
    # reference recommends `file:` for secrets. It reached the one phase that
    # tells the reader the fault is not theirs.
    File.write!(Path.join(directory, "tok.txt"), "ptc-not-a-real-token\n")

    host_path =
      write_host_config(directory, "credential-newline", bearer_credential_host("tok.txt"))

    application = doctor_application(directory, "credential-newline", mission: ["remote"])

    presentation =
      StandaloneCLI.execute([
        "doctor",
        application,
        "--host-config",
        host_path,
        "--connect"
      ])

    error = presentation.outcome.envelope["error"]
    refute error["phase"] == "internal"
    refute error["code"] == "internal_error"
    refute presentation.exit_status == 70

    # Surrounding whitespace is not part of a secret, so the credential is the
    # same one the clean file would have supplied and the run reaches the
    # endpoint it was configured for.
    assert error["phase"] == "active_preflight"
  end

  @tag :tmp_dir
  test "a credential that cannot be carried reports authentication, not an internal fault", %{
    tmp_dir: directory
  } do
    # An interior newline survives trimming and cannot go into a header, so this
    # credential cannot authenticate the request. It reports the class the
    # endpoint's own refusal reports, rather than escaping unclassified and
    # falling closed as an internal error.
    File.write!(Path.join(directory, "tok.txt"), "ptc-not\na-real-token")

    host_path =
      write_host_config(
        directory,
        "credential-interior-newline",
        bearer_credential_host("tok.txt")
      )

    application =
      doctor_application(directory, "credential-interior-newline", mission: ["remote"])

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.exit_status == 4
    assert outcome.envelope["error"]["phase"] == "active_preflight"
    assert outcome.envelope["error"]["code"] == "authentication_rejected"
    refute outcome.envelope["error"]["phase"] == "internal"

    assert %{"status" => "fail", "code" => "authentication_rejected"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/remote/connectivity")
             )

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a whole multi-line credential still reaches a child process environment", %{
    tmp_dir: directory
  } do
    # A PEM block or a JSON service-account key is one credential with interior
    # newlines, and `transport.env` exists to hand exactly that to the child.
    # Only the header sink cannot carry them.
    pem = "-----BEGIN PRIVATE KEY-----\nMIIBVgIBADAN\n-----END PRIVATE KEY-----\n"
    File.write!(Path.join(directory, "key.pem"), pem)

    host_path =
      write_host_config(directory, "multiline-credential", %{
        "credentials" => %{"key" => %{"file" => "key.pem"}},
        "install" => %{
          "workspace" => %{
            "source" => "mcp",
            "installation_revision" => "workspace-v1",
            "transport" => %{
              "type" => "stdio",
              "command" => System.find_executable("sh"),
              "env" => %{"SERVICE_KEY" => %{"binding" => "key"}}
            },
            "tools" => %{"read" => %{"as" => "workspace.read", "effect" => "read"}}
          }
        }
      })

    {:ok, host} = HostConfig.load(host_path)

    # Trailing whitespace is not part of the secret; the interior structure is.
    assert {:ok, %{"key" => resolved}} =
             HostInstallation.resolve_runtime_credentials(host, ["key"])

    assert resolved == String.trim(pem)
    assert String.contains?(resolved, "\n")
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
             "usage" => [
               "ptc validate MANIFEST.json|PROJECT.json [--host-config HOST.json] [--component-override-descriptor DESCRIPTOR.json]"
             ],
             "options" => [
               %{
                 "switches" => ["--host-config HOST.json"],
                 "description" => "trusted provider installation document"
               },
               %{
                 "switches" => ["--component-override-descriptor DESCRIPTOR.json"],
                 "description" => "verified replacement component descriptor"
               },
               %{
                 "switches" => ["--envelope ENVELOPE.json"],
                 "description" => "atomically publish the V4 command envelope"
               },
               %{
                 "switches" => ["--help"],
                 "description" => "show help for this command"
               }
             ],
             "notices" => []
           }

    assert {:error, rejection} =
             CommandParser.parse(["validate", "ptc.json", "--output", "result.json"])

    assert rejection.kind == :unknown_switch

    assert rejection.accepted == [
             "--host-config",
             "--component-override-descriptor",
             "--envelope",
             "--help"
           ]
  end

  test "declared command help aliases resolve to generated topics only by themselves" do
    for {command, alias_name} <- [{"run", "--help"}, {"repl", "-h"}] do
      assert {:ok, arguments} = CommandParser.parse([command, alias_name])
      assert arguments.command == :help
      assert arguments.options.topic == String.to_existing_atom(command)
    end

    assert {:error, rejection} = CommandParser.parse(["repl", "-h", "-e", "42"])
    assert rejection.code == :invalid_arguments

    assert {:error, rejection} =
             CommandParser.parse(["run", "--help", "--envelope", "out.json"])

    assert rejection.command == :help
    assert rejection.kind == :unknown_switch
    assert rejection.accepted == []
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
             "--env-file",
             "--envelope",
             "--progress",
             "--help"
           ]

    refute inspect(first) =~ "secret-first"
    refute inspect(second) =~ "secret-second"
  end

  @tag :tmp_dir
  test "environment files are explicit frontend-owned inputs", %{tmp_dir: dir} do
    env_file = Path.join(dir, "local.env")

    for frontend <- [:standalone, :mix],
        argv <- [
          ["run", "ptc.json", "--env-file", env_file],
          [
            "doctor",
            "ptc.json",
            "--host-config",
            "host.json",
            "--connect",
            "--env-file",
            env_file
          ],
          [
            "repl",
            "--manifest",
            "ptc.json",
            "--host-config",
            "host.json",
            "--env-file",
            env_file
          ],
          ["viewer", "ptc-project.json", "--env-file", env_file]
        ] do
      assert {:ok, entry} = CommandEntry.open(argv, frontend)
      assert entry.arguments.frontend_options == [env_file: env_file]
      refute Map.has_key?(entry.arguments.options, :env_file)
    end

    assert {:error, rejection} =
             CommandParser.parse(["validate", "ptc.json", "--env-file", env_file])

    assert rejection.kind == :unknown_switch

    for argv <- [
          ["doctor", "--env-file", env_file],
          ["repl", "--env-file", env_file],
          ["repl", "--profile", "run-analysis-v1", "--env-file", env_file]
        ] do
      assert {:error, rejection} = CommandParser.parse(argv)
      assert rejection.code == :invalid_arguments
    end
  end

  test "removed switches are ordinary unknown input" do
    assert {:error, rejection} =
             CommandParser.parse(["run", "ptc.json", "--trace", "run.jsonl"])

    assert rejection.command == :run
    assert rejection.code == :invalid_arguments
    assert rejection.kind == :unknown_switch

    assert rejection.accepted ==
             CommandDeclaration.accepted_switches(:run, :standalone)
  end

  test "progress is a shared frontend-owned run switch" do
    for frontend <- [:standalone, :mix] do
      assert {:ok, arguments} = CommandParser.parse(["run", "ptc.json", "--progress"], frontend)
      assert arguments.frontend_options == [progress: true]
      refute Map.has_key?(arguments.options, :progress)
      assert "--progress" in CommandDeclaration.accepted_switches(:run, frontend)
    end
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
      assert rejection.accepted != []
    end
  end

  test "raw spelling checks do not reinterpret declared string option values" do
    assert {:ok, arguments} = CommandParser.parse(["repl", "-e", "-10"])
    assert arguments.ordered_options == [eval: "-10"]
  end

  test "repl preserves repeated selected-run flags in argument order" do
    first = CommandRunRef.encode(<<1::128>>)
    second = CommandRunRef.encode(<<2::128>>)

    assert {:ok, arguments} =
             CommandParser.parse([
               "repl",
               "--profile",
               "private-run-analysis-v2",
               "--run",
               second,
               "--run",
               first,
               "--resource",
               "traces=traces",
               "--resource",
               "inspection=inspection"
             ])

    assert Keyword.get_values(arguments.ordered_options, :run) == [second, first]
  end

  test "repl structural combinations are rejected by the shared parser" do
    for argv <- [
          ["repl", "--format", "yaml"],
          ["repl", "--describe-profile", "run-analysis-v1", "--load", "caller-value"],
          ["repl", "--profile", "run-analysis-v1", "--manifest", "ptc.json"],
          ["repl", "--profile", "run-analysis-v1", "--host-config", "host.json"],
          ["repl", "--profile", "run-analysis-v1", "--trace", "trace.jsonl"],
          ["repl", "--profile", "run-analysis-v1"],
          [
            "repl",
            "--profile",
            "private-run-analysis-v2",
            "--resource",
            "traces=traces",
            "--private-unattended",
            "--format",
            "jsonl"
          ],
          [
            "repl",
            "--profile",
            "run-analysis-v1",
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
          ["repl", "--format", "jsonl"],
          ["repl", "--inspect-only"]
        ] do
      assert {:error, rejection} = CommandParser.parse(argv)
      assert rejection.command == :repl
      assert rejection.code == :invalid_arguments
    end
  end

  test "repl inspect-only conflicts are rejected by the shared parser" do
    for argv <- [
          ["repl", "--inspect-only", "--host-config", "host.json"],
          ["repl", "--inspect-only", "--manifest", "ptc.json", "--host-config", "host.json"],
          ["repl", "--inspect-only", "--manifest", "ptc.json", "--trace", "trace.jsonl"],
          ["repl", "--inspect-only", "--manifest", "ptc.json", "--private-terminal"],
          ["repl", "--inspect-only", "--profile", "run-analysis-v1"],
          ["repl", "--inspect-only", "--manifest", "ptc.json", "--env-file", "missing.env"]
        ] do
      assert {:error, rejection} = CommandParser.parse(argv)
      assert rejection.command == :repl
      assert rejection.code == :conflicting_arguments
    end
  end

  test "viewer accepts one project and the closed listener vocabulary" do
    assert {:ok, arguments} = CommandParser.parse(["viewer", "ptc-project.json"])
    assert arguments.command == :viewer
    assert arguments.application == "ptc-project.json"
    assert arguments.options == %{}

    for {argv, options} <- [
          {["viewer", "p.json", "--listen", "127.0.0.1"], %{listen: "127.0.0.1"}},
          {["viewer", "p.json", "--listen", "0.0.0.0"], %{listen: "0.0.0.0"}},
          {["viewer", "p.json", "--port", "0"], %{port: "0"}},
          {["viewer", "p.json", "--port", "65535"], %{port: "65535"}},
          {["viewer", "p.json", "--port", "4123", "--listen", "0.0.0.0"],
           %{port: "4123", listen: "0.0.0.0"}}
        ] do
      assert {:ok, arguments} = CommandParser.parse(argv)
      assert arguments.options == options
    end
  end

  test "viewer rejects every listener value outside its closed vocabulary" do
    for value <- ["", "::", "::1", "localhost", "10.0.0.1", "0.0.0.1", "127.0.0.2", "0"] do
      assert {:error, rejection} = CommandParser.parse(["viewer", "p.json", "--listen", value])
      assert rejection.command == :viewer
      assert rejection.code == :invalid_arguments
    end
  end

  test "viewer rejects a port outside the representable range" do
    for value <- ["", "-1", "65536", "abc", "1.5", "4123 ", " 4123", "0x10"] do
      assert {:error, rejection} = CommandParser.parse(["viewer", "p.json", "--port", value])
      assert rejection.command == :viewer
      assert rejection.code == :invalid_arguments
    end
  end

  test "viewer takes exactly one project and publishes nothing" do
    for argv <- [
          ["viewer"],
          ["viewer", "a.json", "b.json"],
          ["viewer", "p.json", "--envelope", "envelope.json"],
          ["viewer", "p.json", "--host-config", "host.json"],
          ["viewer", "p.json", "--output", "value.json"],
          ["viewer", "p.json", "--trace-dir", "traces"]
        ] do
      assert {:error, rejection} = CommandParser.parse(argv)
      assert rejection.command == :viewer
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
          "structured_output_mode" => "unsupported",
          "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
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

    # `ModelSelectorDisclosure` withholds endpoint-bearing selectors. The closed
    # envelope refuses one outright, so a future producer that read the host
    # installation directly could not publish what these commands refuse.
    assert %CommandOutcome{} =
             CommandOutcome.success(:models, run_ref, %{
               "installations" => [Map.put(model, "model_selector", "openrouter:test/model")]
             })

    assert_raise ArgumentError, fn ->
      CommandOutcome.success(:models, run_ref, %{
        "installations" => [
          Map.put(model, "model_selector", "openai-compat:https://private.example/v1|deployment")
        ]
      })
    end

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

    for result <- [%{}, %{"version" => self()}, %{version: "0.14.0"}, %{"version" => "9.9.9"}] do
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
             "model_aliases" => [],
             "provider_activity" => true,
             "readiness" => "not_applicable",
             "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
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
      "model_aliases" => [],
      "provider_activity" => true,
      "readiness" => "not_applicable",
      "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
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
      "model_aliases" => [],
      "provider_activity" => false,
      "readiness" => "ready",
      "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
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
        "model_aliases" => [],
        "provider_activity" => false,
        "readiness" => "ready",
        "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
      })

    refute CommandContract.valid_success_semantics?(
             :doctor,
             put_in(valid_doctor.envelope, ["result", "readiness"], "unverified")["result"]
           )

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
      "model_aliases" => [],
      "provider_activity" => true,
      "readiness" => "ready",
      "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
    }

    assert_raise ArgumentError, fn ->
      CommandOutcome.success(:doctor, run_ref, active_doctor_result)
    end

    assert %CommandOutcome{command_mode: {:doctor, :connect}} =
             CommandOutcome.success({:doctor, :connect}, run_ref, active_doctor_result)

    assert_schema_invalid(
      valid_doctor.envelope
      |> Map.put("warnings", [
        %{
          "code" => "model_uncataloged",
          "message" =>
            "the configured model is not an exact catalog entry; pricing, limits, token estimation, and capability detection may be incomplete",
          "provider" => "alpha",
          "model" => "openrouter:future/model"
        }
      ])
    )

    provider_free_connect_result = %{
      "checks" => [
        %{"name" => "runtime", "status" => "pass", "code" => "supported"},
        %{"name" => "application", "status" => "pass", "code" => "valid"},
        %{"name" => "viewer", "status" => "pass", "code" => "available"}
      ],
      "model_aliases" => [],
      "provider_activity" => false,
      "readiness" => "not_applicable",
      "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
    }

    assert %CommandOutcome{command_mode: {:doctor, :connect}} =
             CommandOutcome.success(
               {:doctor, :connect},
               run_ref,
               provider_free_connect_result
             )

    refute CommandContract.valid_success_semantics?(
             :doctor,
             %{provider_free_connect_result | "readiness" => "ready"}
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
             "model_aliases" => [],
             "provider_activity" => true,
             "readiness" => "ready",
             "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
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
             "model_aliases" => [],
             "provider_activity" => false,
             "readiness" => "ready",
             "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
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
             "model_aliases" => [],
             "provider_activity" => true,
             "readiness" => "unverified",
             "usage" => %{"llm_usage_state" => "available", "llm_usage" => []}
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

  test "rebuilt compile messages require component-source provenance" do
    message = "Undefined variable: missing-value"

    assert {:error, :invalid_command_diagnostic} =
             CommandDiagnostic.new(:bundle, :undefined_variable, message: message)

    source = CommandSource.with_bytes(:component, "main.clj", "missing-value")

    assert {:ok, %CommandDiagnostic{message: ^message}} =
             CommandDiagnostic.new(:bundle, :undefined_variable,
               message: message,
               source: source
             )
  end

  test "compile message schema enforces producer name and count bounds" do
    source = CommandSource.with_bytes(:component, "main.clj", "(ns app)")
    run_ref = CommandRunRef.encode(@zero_entropy)

    for {code, message} <- [
          {:undefined_variable, "Undefined variable: #{String.duplicate("x", 128)}"},
          {:undefined_variable,
           "Undefined variables: " <> Enum.map_join(1..8, ", ", &"name#{&1}")},
          {:duplicate_definition, "Duplicate definition: app/#{String.duplicate("x", 128)}"}
        ] do
      {:ok, diagnostic} =
        CommandDiagnostic.new(:bundle, code, message: message, source: source)

      assert_schema_valid(CommandOutcome.error(:validate, run_ref, diagnostic).envelope)
    end

    for {code, message} <- [
          {:undefined_variable,
           "Undefined variables: " <> Enum.map_join(1..9, ", ", &"name#{&1}")},
          {:undefined_variable, "Undefined variable: #{String.duplicate("x", 129)}"},
          {:duplicate_definition, "Duplicate definition: app/#{String.duplicate("x", 129)}"}
        ] do
      {:ok, diagnostic} = CommandDiagnostic.new(:bundle, code, source: source)
      envelope = CommandOutcome.error(:validate, run_ref, diagnostic).envelope

      assert_schema_invalid(put_in(envelope, ["error", "message"], message))
    end
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

    for activity <- [false, true] do
      assert {:ok, %CommandDiagnostic{provider_activity: ^activity}} =
               CommandDiagnostic.new(:active_preflight, :provider_application_unavailable,
                 subject: application_subject,
                 provider_activity: activity
               )
    end

    {:ok, active_diagnostic} =
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

    assert_schema_valid(put_in(active_outcome.envelope, ["error", "provider_activity"], false))

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

  test "pricing diagnostics bind their warning to the subject and message" do
    {:ok, subject} =
      CommandSubject.provider("model", :local, %{destination: :workflow, index: 0})

    {:ok, warning} = CommandWarning.model_uncataloged("model", "provider:model")

    message =
      ModelContractDiagnostic.cost_reservation_pricing_message("provider:model")

    for provider_activity <- [false, true] do
      assert {:ok, _diagnostic} =
               CommandDiagnostic.new(:local_preflight, :model_contract_unsupported,
                 subject: subject,
                 provider_activity: provider_activity,
                 message: message,
                 warnings: [warning]
               )
    end

    {:ok, other_provider} = CommandWarning.model_uncataloged("other", "provider:model")
    {:ok, other_model} = CommandWarning.model_uncataloged("model", "provider:other")
    malformed_model = %{warning | model: :invalid}

    for provider_activity <- [false, true],
        opts <- [
          [subject: subject, message: message],
          [subject: subject, message: message, warnings: [other_provider]],
          [subject: subject, message: message, warnings: [other_model]],
          [subject: subject, message: message, warnings: [malformed_model]]
        ] do
      assert {:error, :invalid_command_diagnostic} =
               CommandDiagnostic.new(
                 :local_preflight,
                 :model_contract_unsupported,
                 Keyword.put(opts, :provider_activity, provider_activity)
               )
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

    for command <- [:help, :version, :init, :validate, :models, :doctor, :materialize] do
      assert_raise ArgumentError, fn -> CommandOutcome.error(command, run_ref, active) end
    end

    assert %CommandOutcome{} = CommandOutcome.error({:doctor, :connect}, run_ref, active)

    manual = %{
      "schema_version" => 2,
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
        "schema_version" => 2,
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
      "evaluation_memory" => evaluation_memory_fixture(),
      "last_evaluation_error" => nil
    }

    classified = %{
      "schema_version" => 4,
      "command" => "run",
      "status" => "error",
      "run_ref" => run_ref,
      "error" => CommandDiagnostic.to_map(top_level),
      "secondary_errors" => [],
      "warnings" => [],
      "artifact_state" => %{
        "trace" => "not_requested",
        "inspection" => "not_requested",
        "result" => "not_requested"
      },
      "artifact_class" => "normal",
      "execution" => finished_ok
    }

    assert_schema_valid(classified)

    for spend <- [
          %{"state" => "empty"},
          %{"state" => "incomplete"},
          %{"state" => "overflow"},
          %{"state" => "unpriced", "input" => 1, "output" => 2},
          %{
            "state" => "available",
            "input" => 1,
            "output" => 2,
            "total_cost" => %{"currency" => "USD", "microunits" => 0}
          }
        ] do
      assert_schema_valid(put_in(classified, ["execution", "usage", "llm_spend"], spend))
    end

    for invalid_spend <- [
          nil,
          %{"state" => "empty", "total_cost" => 0},
          %{"state" => "unpriced", "input" => 1},
          %{"state" => "unpriced", "input" => 1, "output" => 2, "total_cost" => 0},
          %{"state" => "available", "input" => 1, "output" => 2}
        ] do
      assert_schema_invalid(
        put_in(classified, ["execution", "usage", "llm_spend"], invalid_spend)
      )
    end

    assert_schema_invalid(
      update_in(classified, ["execution", "usage"], &Map.delete(&1, "llm_spend"))
    )

    enabled_budget = %{
      "total_tokens" => %{
        "state" => "available",
        "limit" => 100,
        "reserved" => 0,
        "charged" => 18,
        "remaining" => 82,
        "refused" => 0
      },
      "cost" => %{
        "state" => "incomplete",
        "currency" => "USD",
        "limit_microusd" => 500,
        "reserved_microusd" => 0,
        "charged_microusd" => 200,
        "remaining_microusd" => 300,
        "refused" => 1
      }
    }

    assert_schema_valid(put_in(classified, ["execution", "usage", "llm_budget"], enabled_budget))

    for invalid_budget <- [
          nil,
          %{"total_tokens" => nil},
          put_in(enabled_budget, ["total_tokens", "state"], "unknown"),
          put_in(enabled_budget, ["total_tokens", "reserved"], 1),
          put_in(enabled_budget, ["cost", "currency"], "EUR"),
          put_in(enabled_budget, ["cost", "charged_microusd"], -1)
        ] do
      assert_schema_invalid(
        put_in(classified, ["execution", "usage", "llm_budget"], invalid_budget)
      )
    end

    assert_schema_invalid(
      update_in(classified, ["execution", "usage"], &Map.delete(&1, "llm_budget"))
    )

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

    llm_row = %{
      "alias" => "writer",
      "installation_revision" => "stable-v1",
      "calls" => 1,
      "successful_calls" => 1,
      "usage_calls" => 1,
      "missing_usage_calls" => 0,
      "usage_overflow" => false,
      "usage" => %{"input" => 4}
    }

    unmatched_row = %{
      "alias" => "writer",
      "installation_revision" => "stable-v1",
      "calls" => 1,
      "successful_calls" => 0,
      "usage_calls" => 0,
      "missing_usage_calls" => 1,
      "usage_overflow" => false,
      "usage" => %{}
    }

    with_llm =
      classified
      |> put_in(["execution", "usage", "llm_usage"], [llm_row])
      |> put_in(["execution", "usage", "unattributed_model_calls"], 1)

    assert_schema_valid(with_llm)
    assert_schema_valid(put_in(with_llm, ["execution", "usage", "llm_usage"], [unmatched_row]))

    for invalid <- [
          put_in(with_llm, ["execution", "usage", "llm_usage", Access.at(0), "extra"], true),
          put_in(
            with_llm,
            ["execution", "usage", "llm_usage", Access.at(0), "alias"],
            "Bad Alias"
          ),
          put_in(
            with_llm,
            ["execution", "usage", "llm_usage", Access.at(0), "usage", "total_cost"],
            "unknown"
          ),
          put_in(
            with_llm,
            ["execution", "usage", "llm_usage"],
            List.duplicate(llm_row, 129)
          ),
          put_in(with_llm, ["execution", "usage", "llm_usage_state"], "unavailable")
        ] do
      assert_schema_invalid(invalid)
    end

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
      "schema_version" => 4,
      "command" => "run",
      "status" => "error",
      "run_ref" => run_ref,
      "error" => CommandDiagnostic.to_map(execution),
      "secondary_errors" => [],
      "warnings" => [],
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

    result = validate_success_result()

    validate = CommandOutcome.success(:validate, run_ref, result)

    for field <- [
          "application_content_digest",
          "effective_application_digest",
          "workflow_bundle_hash"
        ] do
      assert_schema_invalid(put_in(validate.envelope, ["result", field], result[field] <> "\n"))
    end

    assert CommandContract.valid_success_result?(:validate, result)

    newline_alias =
      validate_success_result(%{
        "installation_config_digests" => %{
          "safe\n" => "sha256:" <> String.duplicate("3", 64)
        }
      })

    refute CommandContract.valid_success_result?(:validate, newline_alias)
    assert_schema_invalid(%{validate.envelope | "result" => newline_alias})
  end

  test "validate mission_grants schema admits producer-scale data and export refs" do
    run_ref = CommandRunRef.encode(@zero_entropy)

    data = Enum.map(1..257, fn index -> "data/k#{index}" end)
    long_export = String.duplicate("n", 200) <> "/" <> String.duplicate("s", 200)
    long_data_form = "data/" <> String.duplicate("k", 70_000)

    result =
      validate_success_result(%{
        "mission_bundle_hashes" => %{"intake" => String.duplicate("3", 64)},
        "mission_grants" => %{
          "intake" => %{
            "data" => [long_data_form | data],
            "exports" => [long_export],
            "providers" => ["workspace.read"]
          }
        }
      })

    outcome = CommandOutcome.success(:validate, run_ref, result)
    assert_schema_valid(outcome.envelope)

    assert length(outcome.envelope["result"]["mission_grants"]["intake"]["data"]) == 258

    assert hd(outcome.envelope["result"]["mission_grants"]["intake"]["data"]) ==
             long_data_form

    assert outcome.envelope["result"]["mission_grants"]["intake"]["exports"] == [
             long_export
           ]
  end

  test "an unknown command has one exact schema-valid phase-1 outcome" do
    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["explode"])

    assert outcome.exit_status == 2

    assert outcome.envelope == %{
             "schema_version" => 4,
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
             "secondary_errors" => [],
             "warnings" => []
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
      "application_not_found"
    )

    over_ceiling =
      write_application(
        directory,
        "over-installed-limit",
        valid_manifest(%{"limits" => %{"mission_capability_calls" => 8_192}})
      )

    limit =
      assert_error(
        ["validate", over_ceiling],
        "application",
        "installed_limit_exceeded"
      )

    # The refusal is the one message that says how to raise a limit, so it names
    # the limit, what the manifest asked for, and the ceiling that refused it.
    assert {:ok, expected} =
             RuntimeLimitDiagnostic.installed_ceiling_message(
               "mission_capability_calls",
               8_192,
               4_096
             )

    assert limit.envelope["error"]["message"] == expected
    assert limit.envelope["error"]["path"] == "/limits/mission_capability_calls"

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

    for {name, input, code, expected_path} <- [
          {"invalid-input-value", %{"value" => []}, "schema_violation",
           [{:property, "input"}, {:property, "value"}]},
          {"invalid-input-path", %{"path" => 42}, "schema_violation",
           [{:property, "input"}, {:property, "path"}]},
          {"empty-input", %{}, "required_property_missing",
           [{:property, "input"}, {:property, "value"}]}
        ] do
      manifest = valid_manifest(%{"input" => input})
      malformed_input = write_application(directory, name, manifest)

      outcome = assert_error(["validate", malformed_input], "application", code)

      expected_pointer =
        Enum.map_join(expected_path, "", fn {:property, property} -> "/#{property}" end)

      assert outcome.envelope["error"]["path"] == expected_pointer

      documents = %{
        "ptc.json" => Jason.encode!(manifest),
        "main.clj" => "(ns app) (defn run [input] (return input))"
      }

      assert {:error, reason} =
               ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

      assert manifest_error_path(reason) == expected_path
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

    assert {:ok, provider_registry} =
             ProviderRegistry.new(%{"probe" => TestHelpers.staged_provider(builder)})

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
               inspect: Path.join(directory, "unexpected.ptcins")
             )

    occupied = Path.join(directory, "occupied.ptcins")
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
  test "impossible normal trace budgets are rejected identically before execution", %{
    tmp_dir: directory
  } do
    payload_bytes = EventBudget.minimum_normal_payload_bytes()
    {:ok, base_limits} = Limits.new(event_payload_bytes: payload_bytes)
    required_bytes = LimitConfiguration.required_normal_event_bytes(base_limits)
    configured_bytes = required_bytes - 1

    application =
      write_application(
        directory,
        "invalid-normal-trace-budget",
        valid_manifest(%{
          "limits" => %{
            "event_payload_bytes" => payload_bytes,
            "normal_event_bytes" => configured_bytes,
            "normal_event_count" => 3
          }
        })
      )

    expected_message =
      "normal_event_bytes effective limit #{configured_bytes} is below the required " <>
        "#{required_bytes} bytes for event_payload_bytes #{payload_bytes}; raise " <>
        "limits.normal_event_bytes, and its installed host ceiling if it is lower, or " <>
        "lower limits.event_payload_bytes"

    errors =
      for argv <- [
            ["validate", application],
            ["run", application],
            ["doctor", application]
          ] do
        outcome = assert_error(argv, "application", "limit_configuration_invalid")

        if hd(argv) == "run",
          do: assert(outcome.envelope["execution"] == %{"state" => "not_started"})

        assert outcome.envelope["error"]["message"] == expected_message
        assert outcome.envelope["error"]["path"] == nil
        outcome.envelope["error"]
      end

    assert Enum.uniq(errors) |> length() == 1

    admitted =
      write_application(
        directory,
        "valid-minimum-normal-trace-budget",
        valid_manifest(%{
          "limits" => %{
            "event_payload_bytes" => payload_bytes,
            "normal_event_bytes" => required_bytes,
            "normal_event_count" => 3
          }
        })
      )

    assert {:ok, %CommandOutcome{}} = CommandEngine.prepare(["validate", admitted])
  end

  # The fixed part of the terminal projection is a catalog minimum; the part
  # keyed by declared capability and mission names cannot be, because it is only
  # resolved when the run assembles. That refusal is still a limits decision, so
  # it must arrive as a configuration diagnostic and not as an internal error.
  @tag :tmp_dir
  test "a resolved terminal usage above the payload ceiling is refused as a limits diagnostic",
       %{tmp_dir: directory} do
    payload_bytes = EventBudget.minimum_normal_payload_bytes()
    padding = String.duplicate("x", 120)

    missions =
      Map.new(1..3, fn index ->
        {"m#{padding}#{String.pad_leading(Integer.to_string(index), 3, "0")}",
         %{"components" => [], "data" => %{}, "providers" => []}}
      end)

    application =
      write_application(
        directory,
        "resolved-terminal-usage-too-large",
        valid_manifest(%{
          "limits" => %{"event_payload_bytes" => payload_bytes},
          "missions" => missions
        })
      )

    assert {:ok, %CommandOutcome{}} = CommandEngine.prepare(["validate", application])

    assert {:error, %CommandOutcome{} = outcome} = CommandEngine.dispatch(["run", application])
    assert_schema_valid(outcome.envelope)
    assert outcome.envelope["error"]["phase"] == "application"
    assert outcome.envelope["error"]["code"] == "limit_capacity_invalid"
    assert outcome.envelope["error"]["provider_activity"] == false
    assert outcome.exit_status == 3
    assert outcome.envelope["execution"] == %{"state" => "not_started"}
    assert outcome.envelope["artifact_state"]["trace"] == "not_requested"
    assert outcome.envelope["error"]["path"] == nil

    assert [_matched, reported, required] =
             Regex.run(
               ~r/\Aevent_payload_bytes effective limit (\d+) is below the required (\d+) bytes/,
               outcome.envelope["error"]["message"]
             )

    assert String.to_integer(reported) == payload_bytes
    assert String.to_integer(required) > payload_bytes
  end

  @tag :tmp_dir
  test "normal trace count values below three use schema diagnostics", %{tmp_dir: directory} do
    for count <- [1, 2] do
      application =
        write_application(
          directory,
          "invalid-normal-event-count-#{count}",
          valid_manifest(%{"limits" => %{"normal_event_count" => count}})
        )

      for command <- ["validate", "run", "doctor"] do
        outcome = assert_error([command, application], "application", "schema_violation")
        assert outcome.envelope["error"]["path"] == "/limits/normal_event_count"
        assert outcome.envelope["error"]["message"] =~ "minimum"
      end

      host =
        write_host_config(directory, "invalid-normal-event-count-#{count}", %{
          "install" => %{},
          "limits" => %{"normal_event_count" => count}
        })

      outcome =
        assert_error(
          ["validate", application, "--host-config", host],
          "host",
          "host_schema_invalid"
        )

      assert outcome.envelope["error"]["path"] == "/limits/normal_event_count"
      assert outcome.envelope["error"]["message"] =~ "minimum"
    end
  end

  # Only a run that already assembled providers can reach this code, so the
  # commands that stop before assembly must not admit it at all.
  test "the capacity refusal is admitted only by a run" do
    for mode <- [:validate, :doctor, {:doctor, :connect}, :run_unclassified] do
      refute CommandContract.diagnostic_allowed?(mode, :application, :limit_capacity_invalid),
             "#{inspect(mode)} admits limit_capacity_invalid"

      assert CommandContract.diagnostic_allowed?(
               mode,
               :application,
               :limit_configuration_invalid
             ),
             "#{inspect(mode)} lost limit_configuration_invalid"
    end

    assert CommandContract.diagnostic_allowed?(:run, :application, :limit_capacity_invalid)
  end

  # The refusal is computed after provider assembly, so it can be reported with
  # or without provider activity, and the dispatcher calls an active failure
  # incomplete. Every one of those outcomes has to seal, or the run that raised
  # this reason exits 70 through the very path the diagnostic exists to replace.
  test "every reachable capacity refusal outcome seals as a V4 envelope" do
    payload_bytes = EventBudget.minimum_normal_payload_bytes()
    {:ok, message} = LimitCapacityDiagnostic.message(payload_bytes, payload_bytes * 2)
    {:ok, run_ref} = CommandRunRef.generate()

    artifact_state = %{
      "trace" => "not_written",
      "inspection" => "not_requested",
      "result" => "not_requested"
    }

    for provider_activity <- [false, true],
        execution_state <- [:not_started, :incomplete],
        result_class <- [:normal, :private] do
      assert {:ok, diagnostic} =
               CommandDiagnostic.new(:application, :limit_capacity_invalid,
                 source: CommandSource.fixed(:application),
                 message: message,
                 provider_activity: provider_activity
               )

      assert {:error, outcome} =
               CommandRunOutcome.operation_failure(
                 run_ref,
                 diagnostic,
                 result_class,
                 artifact_state,
                 provider_activity,
                 execution_state
               )

      assert outcome.exit_status == 3
      assert outcome.envelope["error"]["code"] == "limit_capacity_invalid"
      assert outcome.envelope["error"]["provider_activity"] == provider_activity
      assert CommandContract.valid_envelope?(outcome.envelope)
    end
  end

  @tag :tmp_dir
  test "event payload values below the catalog minimum use schema diagnostics", %{
    tmp_dir: directory
  } do
    minimum = EventBudget.minimum_normal_payload_bytes()

    for payload_bytes <- [1, minimum - 1] do
      application =
        write_application(
          directory,
          "invalid-event-payload-#{payload_bytes}",
          valid_manifest(%{"limits" => %{"event_payload_bytes" => payload_bytes}})
        )

      for command <- ["validate", "run", "doctor"] do
        outcome = assert_error([command, application], "application", "schema_violation")
        assert outcome.envelope["error"]["path"] == "/limits/event_payload_bytes"
        assert outcome.envelope["error"]["message"] =~ "minimum"
      end

      host =
        write_host_config(directory, "invalid-event-payload-#{payload_bytes}", %{
          "install" => %{},
          "limits" => %{"event_payload_bytes" => payload_bytes}
        })

      admitted =
        write_application(
          directory,
          "admitted-event-payload-#{payload_bytes}",
          valid_manifest()
        )

      outcome =
        assert_error(
          ["validate", admitted, "--host-config", host],
          "host",
          "host_schema_invalid"
        )

      assert outcome.envelope["error"]["path"] == "/limits/event_payload_bytes"
      assert outcome.envelope["error"]["message"] =~ "minimum"
    end
  end

  @tag :tmp_dir
  test "host-schema failures inside an installation are told apart by their pointer", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "host-schema-depth", valid_manifest())
    base = valid_host_config()

    # Six structurally different mistakes reported one identical pointer,
    # `/install`, because an installation is a tagged union and the member that
    # broke is named only inside the rejected branches.
    cases = [
      {"wrong-parent",
       put_in(base, ["install", "workspace", "ceilings"], %{"run_timeout_ms" => 1}),
       "/install/*/ceilings"},
      {"ceiling-range",
       put_in(base, ["install", "workspace", "ceilings"], %{"timeout_ms" => 999_999}),
       "/install/*/ceilings/timeout_ms"},
      {"transport-range",
       put_in(base, ["install", "workspace", "transport", "start_timeout_ms"], 99_999),
       "/install/*/transport/start_timeout_ms"},
      {"revision-pattern",
       put_in(base, ["install", "workspace", "installation_revision"], "WORKSPACE-V1"),
       "/install/*/installation_revision"},
      {"tool-effect", put_in(base, ["install", "workspace", "tools", "read", "effect"], "delete"),
       "/install/*/tools"}
    ]

    pointers =
      for {name, host, expected} <- cases do
        host_path = write_host_config(directory, "depth-#{name}", host)

        outcome =
          assert_error(
            ["validate", application, "--host-config", host_path],
            "host",
            "host_schema_invalid"
          )

        assert outcome.envelope["error"]["path"] == expected

        # The installation alias and the upstream tool name are the author's
        # own words. Neither reaches the pointer.
        refute outcome.envelope["error"]["path"] =~ "workspace"
        refute outcome.envelope["error"]["path"] =~ "read"
        assert_schema_valid(outcome.envelope)
        outcome.envelope["error"]["path"]
      end

    assert length(Enum.uniq(pointers)) == 5
  end

  @tag :tmp_dir
  test "host and manifest schema failures name the bounded rule that was violated", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "schema-rules", valid_manifest())
    host = valid_host_config()

    host_cases = [
      {"unknown-root", Map.put(host, "limitss", %{}), "", "contains an unknown property"},
      {"unknown-nested",
       put_in(host, ["install", "workspace", "ceilings"], %{
         "evaluation_timeout_ms" => 60_000
       }), "/install/*/ceilings", "contains an unknown property"},
      {"maximum", put_in(host, ["install", "workspace", "ceilings"], %{"timeout_ms" => 999_999}),
       "/install/*/ceilings/timeout_ms", "violates the maximum schema rule"},
      {"pattern", put_in(host, ["install", "workspace", "installation_revision"], "WORKSPACE-V1"),
       "/install/*/installation_revision", "violates the pattern schema rule"},
      {"required", update_in(host, ["install", "workspace"], &Map.delete(&1, "tools")),
       "/install/*/tools", "is missing a required property"}
    ]

    for {name, document, expected_path, expected_message} <- host_cases do
      host_path = write_host_config(directory, "rule-#{name}", document)

      outcome =
        assert_error(
          ["validate", application, "--host-config", host_path],
          "host",
          "host_schema_invalid"
        )

      assert outcome.envelope["error"]["path"] == expected_path
      assert outcome.envelope["error"]["message"] =~ expected_message
      refute Jason.encode!(outcome.envelope) =~ "workspace"
      refute Jason.encode!(outcome.envelope) =~ "limitss"
      assert_schema_valid(outcome.envelope)
    end

    manifest = valid_manifest()

    manifest_cases = [
      {"unknown-root", Map.put(manifest, "artifactz", %{}), "schema_violation", "",
       "contains an unknown property"},
      {"unknown-nested", put_in(manifest, ["workflow", "libraries"], []), "schema_violation",
       "/workflow", "contains an unknown property"},
      {"type", put_in(manifest, ["workflow", "entry"], 123), "schema_violation",
       "/workflow/entry", "violates the type schema rule"},
      {"pattern", put_in(manifest, ["workflow", "entry"], "Main/Run"), "schema_violation",
       "/workflow/entry", "violates the pattern schema rule"},
      {"required", update_in(manifest, ["workflow"], &Map.delete(&1, "entry")),
       "required_property_missing", "/workflow/entry", "is missing a required property"}
    ]

    for {name, document, code, expected_path, expected_message} <- manifest_cases do
      path = write_application(directory, "manifest-rule-#{name}", document)
      outcome = assert_error(["validate", path], "application", code)

      assert outcome.envelope["error"]["path"] == expected_path
      assert outcome.envelope["error"]["message"] =~ expected_message
      refute Jason.encode!(outcome.envelope) =~ "artifactz"
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
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
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
  test "optional LLM budget prerequisites produce closed host diagnostics", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "budget-prerequisites", valid_manifest())

    cases = [
      {"tokens", "llm_total_tokens", %{"tokens" => false, "cost_currency" => nil}, nil,
       "/install/*/usage_guarantees/tokens",
       "llm_total_tokens requires usage_guarantees.tokens: true on every live LLM installation; set it in the host document"},
      {"currency", "llm_cost_microusd", %{"tokens" => true, "cost_currency" => nil},
       %{"currency" => "USD", "id" => "private-tariff-id"},
       "/install/*/usage_guarantees/cost_currency",
       "llm_cost_microusd requires usage_guarantees.cost_currency: \"USD\" on every live LLM installation; set it in the host document"},
      {"tariff", "llm_cost_microusd", %{"tokens" => true, "cost_currency" => "USD"}, nil,
       "/install/*/reservation_tariff",
       "llm_cost_microusd requires reservation_tariff on every live LLM installation; add it under each live LLM installation (see ptc docs host)"}
    ]

    for {name, limit, guarantees, tariff, expected_path, expected_message} <- cases do
      host =
        env_credential_host()
        |> Map.put("limits", %{limit => 1_000})
        |> put_in(["install", "model", "usage_guarantees"], guarantees)
        |> then(fn host ->
          if tariff,
            do: put_in(host, ["install", "model", "reservation_tariff"], tariff),
            else: host
        end)

      host_path = write_host_config(directory, "budget-prerequisite-#{name}", host)

      outcome =
        assert_error(
          ["validate", application, "--host-config", host_path],
          "host",
          "installed_limit_invalid"
        )

      error = outcome.envelope["error"]
      assert outcome.exit_status == 3
      assert error["message"] == expected_message
      assert error["path"] == expected_path
      assert error["notes"] == []
      assert error["source"] == %{"kind" => "host", "name" => "ptc-host.json"}
      assert error["provider_activity"] == false

      encoded = Jason.encode!(outcome.envelope)
      refute encoded =~ "model"
      refute encoded =~ "private-tariff-id"
    end
  end

  @tag :tmp_dir
  test "optional LLM budget prerequisite selection is deterministic and private", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "budget-alias-order", valid_manifest())

    invalid_installation =
      env_credential_host()
      |> get_in(["install", "model"])
      |> put_in(["usage_guarantees"], %{"tokens" => false, "cost_currency" => nil})

    host = %{
      "limits" => %{"llm_total_tokens" => 1_000},
      "credentials" => %{"key" => %{"env" => "PTC_TEST_ABSENT_KEY"}},
      "install" => %{
        "zeta-private" => invalid_installation,
        "alpha-private" => invalid_installation
      }
    }

    host_path = write_host_config(directory, "budget-alias-order", host)

    for _iteration <- 1..5 do
      outcome =
        assert_error(
          ["validate", application, "--host-config", host_path],
          "host",
          "installed_limit_invalid"
        )

      error = outcome.envelope["error"]
      assert error["path"] == "/install/*/usage_guarantees/tokens"

      assert error["message"] ==
               "llm_total_tokens requires usage_guarantees.tokens: true on every live LLM installation; set it in the host document"

      encoded = Jason.encode!(outcome.envelope)
      refute encoded =~ "alpha-private"
      refute encoded =~ "zeta-private"
    end
  end

  @tag :tmp_dir
  test "host budget diagnostics preserve structural and unrelated semantic precedence", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "budget-precedence", valid_manifest())

    malformed_tariff =
      env_credential_host()
      |> Map.put("limits", %{"llm_cost_microusd" => 1_000})
      |> put_in(
        ["install", "model", "usage_guarantees"],
        %{"tokens" => true, "cost_currency" => "USD"}
      )
      |> put_in(["install", "model", "reservation_tariff"], %{"currency" => "USD"})

    malformed_path = write_host_config(directory, "malformed-tariff", malformed_tariff)

    malformed =
      assert_error(
        ["validate", application, "--host-config", malformed_path],
        "host",
        "host_schema_invalid"
      )

    assert malformed.envelope["error"]["path"] == "/install/*/reservation_tariff/id"

    dangling_credential =
      env_credential_host()
      |> put_in(["install", "model", "credential"], "private-missing-credential")

    dangling_path = write_host_config(directory, "budget-unrelated-semantic", dangling_credential)

    dangling =
      assert_error(
        ["validate", application, "--host-config", dangling_path],
        "host",
        "host_invalid"
      )

    assert dangling.envelope["error"]["path"] == nil
    refute Jason.encode!(dangling.envelope) =~ "private-missing-credential"
  end

  @tag :tmp_dir
  test "host-disabled optional budgets name the unavailable limit and remedy", %{
    tmp_dir: directory
  } do
    for row <- LimitCatalog.rows(:optional_manifest_narrowable),
        requested <- [row.minimum, row.maximum] do
      name = row.name

      application =
        write_application(
          directory,
          "disabled-#{name}-#{requested}",
          valid_manifest(%{"limits" => %{name => requested}})
        )

      outcome = assert_error(["validate", application], "application", "limit_unavailable")
      error = outcome.envelope["error"]

      assert outcome.exit_status == 3
      assert error["path"] == "/limits/#{name}"

      assert error["message"] ==
               "#{name} #{requested} is unavailable because the host has not enabled it; enable #{name} in the host document before declaring it in the manifest"

      assert error["notes"] == []
      assert error["source"] == %{"kind" => "application", "name" => "ptc.json"}
      assert error["provider_activity"] == false
    end
  end

  @tag :tmp_dir
  test "enabled optional budgets inherit, narrow, and distinguish an exceeded ceiling", %{
    tmp_dir: directory
  } do
    host =
      env_credential_host()
      |> Map.put("limits", %{"llm_total_tokens" => 1_000})
      |> put_in(
        ["install", "model", "usage_guarantees"],
        %{"tokens" => true, "cost_currency" => nil}
      )

    host_path = write_host_config(directory, "enabled-token-budget", host)

    inherited = write_application(directory, "inherited-token-budget", valid_manifest())

    assert {:ok, %CommandOutcome{} = inherited_outcome} =
             CommandEngine.prepare(["validate", inherited, "--host-config", host_path])

    assert inherited_outcome.exit_status == 0

    narrowed =
      write_application(
        directory,
        "narrowed-token-budget",
        valid_manifest(%{"limits" => %{"llm_total_tokens" => 500}})
      )

    assert {:ok, %CommandOutcome{} = narrowed_outcome} =
             CommandEngine.prepare(["validate", narrowed, "--host-config", host_path])

    assert narrowed_outcome.exit_status == 0

    exceeded =
      write_application(
        directory,
        "exceeded-token-budget",
        valid_manifest(%{"limits" => %{"llm_total_tokens" => 1_001}})
      )

    outcome =
      assert_error(
        ["validate", exceeded, "--host-config", host_path],
        "application",
        "installed_limit_exceeded"
      )

    assert outcome.envelope["error"]["path"] == "/limits/llm_total_tokens"
  end

  @tag :tmp_dir
  test "enabled optional non-LLM limits inherit, narrow, and distinguish an exceeded ceiling", %{
    tmp_dir: directory
  } do
    for row <- LimitCatalog.rows(:optional_manifest_narrowable),
        row.prerequisites == [] do
      host_path =
        write_host_config(directory, "enabled-#{row.name}", %{
          "install" => %{},
          "limits" => %{row.name => 1_000}
        })

      inherited = write_application(directory, "inherited-#{row.name}", valid_manifest())

      assert {:ok, %CommandOutcome{} = inherited_outcome} =
               CommandEngine.prepare(["validate", inherited, "--host-config", host_path])

      assert inherited_outcome.exit_status == 0

      narrowed =
        write_application(
          directory,
          "narrowed-#{row.name}",
          valid_manifest(%{"limits" => %{row.name => 500}})
        )

      assert {:ok, %CommandOutcome{} = narrowed_outcome} =
               CommandEngine.prepare(["validate", narrowed, "--host-config", host_path])

      assert narrowed_outcome.exit_status == 0

      exceeded =
        write_application(
          directory,
          "exceeded-#{row.name}",
          valid_manifest(%{"limits" => %{row.name => 1_001}})
        )

      outcome =
        assert_error(
          ["validate", exceeded, "--host-config", host_path],
          "application",
          "installed_limit_exceeded"
        )

      assert outcome.envelope["error"]["path"] == "/limits/#{row.name}"
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
      {["missions", "default"], %{"missions" => %{"default" => %{"extra" => true}}}},
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

      input_without_variant? =
        path == ["input"] and Map.has_key?(override["input"], "caller-secret")

      code = if input_without_variant?, do: "required_property_missing", else: "schema_violation"
      outcome = assert_error(["validate", directory_path], "application", code)

      # A mission name is the author's own, so it is elided rather than named;
      # the closed schema beneath it stays addressable.
      expected_pointer =
        cond do
          input_without_variant? -> "/input/value"
          hd(path) == "missions" -> "/missions/*"
          true -> Enum.map_join(path, "", &"/#{&1}")
        end

      assert outcome.envelope["error"]["path"] == expected_pointer
      refute Jason.encode!(outcome.envelope) =~ "caller-secret"
      refute Jason.encode!(outcome.envelope) =~ "must-not-escape"

      documents = %{
        "ptc.json" => Jason.encode!(manifest),
        "main.clj" => "(ns app) (defn run [input] (return input))"
      }

      typed_path =
        if input_without_variant? do
          [{:property, "input"}, {:property, "value"}]
        else
          Enum.map(path, fn
            "default" -> {:property, "*"}
            segment when is_binary(segment) -> {:property, segment}
            segment when is_integer(segment) -> {:index, segment}
          end)
        end

      expected_rule = if input_without_variant?, do: :required, else: :unknown_property

      assert {:error,
              {:manifest_schema_invalid,
               %PtcRunner.Kernel.SchemaViolation{
                 rule: ^expected_rule,
                 path: ^typed_path
               }}} =
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
      {["missions", "default", "data"], %{"missions" => %{"default" => %{"data" => []}}}},
      {["version"], %{"version" => 2}},
      {["$schema"], %{"$schema" => 42}},
      {["$schema"], %{"$schema" => nil}}
    ]

    for {{path, override}, index} <- Enum.with_index(cases) do
      manifest = valid_manifest(override)
      name = "invalid-value-#{index}-" <> Enum.map_join(path, "-", &to_string/1)
      directory_path = write_application(directory, name, manifest)
      outcome = assert_error(["validate", directory_path], "application", "schema_violation")

      expected_pointer =
        Enum.map_join(path, "", fn
          "default" -> "/*"
          segment -> "/#{segment}"
        end)

      assert outcome.envelope["error"]["path"] == expected_pointer

      documents = %{
        "ptc.json" => Jason.encode!(manifest),
        "main.clj" => "(ns app) (defn run [input] (return input))"
      }

      typed_path =
        Enum.map(path, fn
          "default" -> {:property, "*"}
          segment when is_binary(segment) -> {:property, segment}
          segment when is_integer(segment) -> {:index, segment}
        end)

      assert {:error, reason} =
               ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

      assert manifest_error_path(reason) == typed_path
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
    inspection = Path.join(directory, "inspection.ptcins")

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
               nil,
               {%{output: "relative-result.json"}, []}
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
          {preparation.catalog, %{inspect: "inspection.ptcins"}},
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
                 nil,
                 {destinations, []}
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
               nil,
               {%{}, []}
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
    refute ExecutionInput.valid?(Map.delete(input, :value))
    refute ExecutionPolicy.valid?(Map.put(policy, :output_path, "private"))
    refute RunRequest.valid?(Map.put(request, :application_path, "private"))
    refute PreparedRun.valid?(Map.put(preparation.prepared_run, :application_path, "private"))

    refute FrozenBundle.valid?(
             Map.put(preparation.prepared_run.workflow_bundle, :private_path, ".")
           )

    refute FrozenBundle.valid?(Map.delete(preparation.prepared_run.workflow_bundle, :components))

    assert ProviderActivity.value(Map.put(activity, :provider_endpoint, "private")) == :unknown
    refute ValueContract.sealed?(Map.put(contract, :schema_path, "private"))
    refute ValueContract.sealed?(Map.delete(contract, :schema))
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
               nil,
               {%{}, []}
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

    tasks =
      Enum.map(1..2, fn _index ->
        Task.async(fn -> RunBuilder.build_prepared(prepared, registry) end)
      end)

    results = Task.await_many(tasks)
    Enum.each(tasks, &await_exit/1)

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
                 second_prepared.mission_bundles,
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
          "missions" => %{
            "default" => %{
              "components" => [%{"id" => "mission", "path" => "mission.clj"}],
              "data" => %{}
            }
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
                 mission_prepared.mission_bundles,
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
  test "preparation reuses a byte-identical workflow bundle for missions", %{tmp_dir: directory} do
    source = """
    (ns app)
    (defn run [input]
      (return (case (:mode input) :first 1 0)))
    """

    application =
      write_application(
        directory,
        "prepared-bundle-reuse",
        valid_manifest(%{
          "missions" => %{
            "first" => %{
              "components" => [%{"id" => "app", "path" => "main.clj"}],
              "data" => %{}
            },
            "second" => %{
              "components" => [%{"id" => "app", "path" => "main.clj"}],
              "data" => %{}
            }
          }
        }),
        %{"main.clj" => source}
      )

    assert {:ok, request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, registry} = ProviderRegistry.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog_for(registry))

    assert prepared.mission_bundles == %{
             "first" => prepared.workflow_bundle,
             "second" => prepared.workflow_bundle
           }

    assert :ok = PreparedRun.close(prepared)
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
               prepared.mission_bundles,
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
               prepared.mission_bundles,
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

      assert {:error,
              {:manifest_schema_invalid, %PtcRunner.Kernel.SchemaViolation{path: ^typed_path}}} =
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

      assert {:error,
              {:manifest_schema_invalid,
               %PtcRunner.Kernel.SchemaViolation{rule: :type, path: ^typed_path}}} =
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

    assert {:error,
            {:manifest_schema_invalid,
             %PtcRunner.Kernel.SchemaViolation{
               rule: :type,
               path: [{:property, "contracts"}]
             }}} =
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

    component = assert_error(["validate", invalid_component], "bundle", "syntax_invalid")

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

  # Six structurally different authoring mistakes used to report the same six
  # words with a null path, so "I misspelled something" and "this feature does
  # not exist" were indistinguishable and the profile's edges could only be
  # found by bisecting the schema one keyword at a time.
  @tag :tmp_dir
  test "validate accepts a nullable result-contract type array", %{tmp_dir: directory} do
    schema = %{
      "type" => "object",
      "properties" => %{"analysis" => %{"type" => ["string", "null"]}},
      "required" => ["analysis"]
    }

    path =
      write_application(
        directory,
        "nullable-result-contract",
        valid_manifest(%{
          "contracts" => %{"result_schema" => %{"path" => "result.schema.json"}}
        }),
        %{"result.schema.json" => Jason.encode!(schema)}
      )

    assert {:ok, %CommandOutcome{exit_status: 0} = outcome} =
             CommandEngine.prepare(["validate", path])

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "a rejected contract schema names its rule and its location", %{tmp_dir: directory} do
    cases = [
      {"bare-enum", %{"type" => "object", "properties" => %{"sum" => %{"enum" => [1, 2]}}},
       ~s(contract schema node declares no "type"), "/properties/sum"},
      {"bare-const", %{"type" => "object", "properties" => %{"sum" => %{"const" => 5}}},
       ~s(contract schema node declares no "type"), "/properties/sum"},
      {"misspelled-type",
       %{"type" => "object", "properties" => %{"sum" => %{"type" => "intger"}}},
       ~s(contract schema "type" must be "null", "boolean", "object", "array", "number", "integer", or "string", or a two-member array pairing "null" with one non-null type),
       "/properties/sum/type"},
      {"unsupported-keyword",
       %{
         "type" => "object",
         "properties" => %{"sum" => %{"type" => "integer", "multipleOf" => 7}}
       }, "contract schema uses a keyword outside the supported profile",
       "/properties/sum/multipleOf"},
      {"excluded-bound",
       %{
         "type" => "object",
         "properties" => %{"n" => %{"type" => "integer", "exclusiveMinimum" => 0}}
       }, "contract schema uses a keyword outside the supported profile",
       "/properties/n/exclusiveMinimum"},
      {"unsatisfiable-bound",
       %{
         "type" => "object",
         "properties" => %{
           "sum" => %{"type" => "integer", "minimum" => 100, "maximum" => 99}
         }
       }, "contract schema declares a minimum above its maximum", "/properties/sum/minimum"},
      {"unsupported-format",
       %{
         "type" => "object",
         "properties" => %{"s" => %{"type" => "string", "format" => "date-time"}}
       }, ~s(contract schema declares an unsupported "format"), "/properties/s/format"},
      {"undeclared-required",
       %{
         "type" => "object",
         "properties" => %{"a" => %{"type" => "string"}},
         "required" => ["b"]
       }, "contract schema requires a property it does not declare", "/required"}
    ]

    messages =
      for {name, schema, message, pointer} <- cases do
        path =
          write_application(
            directory,
            "contract-#{name}",
            valid_manifest(%{
              "contracts" => %{"result_schema" => %{"path" => "result.schema.json"}}
            }),
            %{"result.schema.json" => Jason.encode!(schema)}
          )

        outcome = assert_error(["validate", path], "application", "contract_invalid")

        assert outcome.envelope["error"]["message"] == message
        assert outcome.envelope["error"]["path"] == pointer

        assert outcome.envelope["error"]["source"] == %{
                 "kind" => "result_contract",
                 "name" => "result.schema.json"
               }

        {:stderr, rendered} = CommandRenderer.render(outcome)
        assert rendered =~ "#{message} at #{pointer} in result.schema.json "

        {message, pointer}
      end

    # A distinct cause must produce a distinct diagnostic; the bare-enum and
    # bare-const rows deliberately share one rule at two locations.
    assert length(Enum.uniq(messages)) == length(cases) - 1

    phase_path =
      write_application(
        directory,
        "invalid-phase-contract",
        valid_manifest(%{
          "contracts" => %{
            "phase_return_schemas" => %{
              "gathered" => %{"path" => "gather.schema.json"}
            }
          }
        }),
        %{
          "gather.schema.json" =>
            Jason.encode!(%{
              "type" => "object",
              "properties" => %{
                "sum" => %{"type" => "integer", "minimum" => 2, "maximum" => 1}
              }
            })
        }
      )

    phase_outcome = assert_error(["validate", phase_path], "application", "contract_invalid")
    assert phase_outcome.envelope["error"]["path"] == "/properties/sum/minimum"

    assert phase_outcome.envelope["error"]["source"] == %{
             "kind" => "phase_return_contract",
             "name" => "gather.schema.json"
           }

    # A contract document that is not an object at all reaches the compiler and
    # is named as such. Refusing it before compilation would leave the
    # commonest "wrong thing entirely" mistake on the blind message.
    for document <- ["[]", "\"result\"", "42", "null"] do
      path =
        write_application(
          directory,
          "contract-non-object-#{byte_size(document)}",
          valid_manifest(%{
            "contracts" => %{"result_schema" => %{"path" => "result.schema.json"}}
          }),
          %{"result.schema.json" => document}
        )

      outcome = assert_error(["validate", path], "application", "contract_invalid")

      assert outcome.envelope["error"]["message"] == "contract schema node is not a JSON object"
      assert outcome.envelope["error"]["path"] == nil
    end
  end

  @tag :tmp_dir
  test "compile diagnostics classify safe reasons without exposing compiler details", %{
    tmp_dir: directory
  } do
    cases = [
      {"syntax", "(ns app) (", "syntax_invalid", "the component source is not valid PTC-Lisp",
       nil, :eof},
      {"syntax-unicode-comment", "; λ 🚀\n(ns app) (", "syntax_invalid",
       "the component source is not valid PTC-Lisp", nil, :eof},
      {"undefined", "(ns app) (defn run [input] (return missing-value))", "undefined_variable",
       "Undefined variable: missing-value", nil, nil},
      {"undefined-many", "(ns app) (defn run [input] (+ missing-left missing-right))",
       "undefined_variable", "Undefined variables: missing-left, missing-right", nil, nil},
      {"duplicate", "(ns app) (defn run [input] input) (defn run [input] input)",
       "duplicate_definition", "Duplicate definition: app/run", nil, "(defn run [input] input)"}
    ]

    for {name, source, code, message, private_detail, spanned_form} <- cases do
      path =
        write_application(directory, "compile-#{name}", valid_manifest(), %{
          "main.clj" => source
        })

      diagnostic = assert_error(["validate", path], "bundle", code).envelope["error"]

      assert diagnostic["message"] == message
      assert diagnostic["source"] == %{"kind" => "component", "name" => "main.clj"}

      if private_detail do
        refute diagnostic["message"] =~ private_detail
      end

      case {spanned_form, diagnostic["span"]} do
        {nil, nil} ->
          :ok

        {:eof, %{"start_byte" => start_byte, "end_byte" => end_byte}} ->
          assert start_byte == byte_size(source)
          assert end_byte == byte_size(source)

        {form, %{"start_byte" => start_byte, "end_byte" => end_byte}} ->
          assert binary_part(source, start_byte, end_byte - start_byte) == form
      end
    end
  end

  @tag :tmp_dir
  test "compile diagnostics retain fixed fallbacks when structured position is unavailable", %{
    tmp_dir: directory
  } do
    source = "(ns app) #_ (defn run [input] input)"

    path =
      write_application(directory, "unlocated-syntax", valid_manifest(), %{
        "main.clj" => source
      })

    diagnostic = assert_error(["validate", path], "bundle", "syntax_invalid").envelope["error"]

    assert diagnostic["message"] == "the component source is not valid PTC-Lisp"
    assert diagnostic["span"] == nil
  end

  @tag :tmp_dir
  test "a locatable compile failure carries the offending form's byte span", %{
    tmp_dir: directory
  } do
    source = """
    (ns app)

    (defn run [input] (return input))

    (defn broken)
    """

    path =
      write_application(directory, "located-compile-failure", valid_manifest(), %{
        "main.clj" => source
      })

    outcome = assert_error(["validate", path], "bundle", "compile_failed")

    assert %{"start_byte" => start_byte, "end_byte" => end_byte} =
             outcome.envelope["error"]["span"]

    # The offsets are only worth emitting if they cut the source at the form a
    # reader has to fix, so slice rather than assert the numbers.
    assert binary_part(source, start_byte, end_byte - start_byte) == "(defn broken)"
  end

  @tag :tmp_dir
  test "unknown component namespaces retain safe structured analyzer guidance", %{
    tmp_dir: directory
  } do
    source = """
    (ns app)

    (defn run [input]
      (return (kernel/mission-model-context \"reader\")))
    """

    path =
      write_application(directory, "unknown-component-namespace", valid_manifest(), %{
        "main.clj" => source
      })

    outcome = assert_error(["validate", path], "bundle", "unknown_namespace")
    diagnostic = outcome.envelope["error"]

    assert diagnostic["message"] =~ "unknown namespace kernel/"
    assert diagnostic["message"] =~ "Available namespaces:"
    assert diagnostic["message"] =~ "json/"
    assert diagnostic["message"] =~ "For JSON parsing use json/parse-string"

    assert %{"start_byte" => start_byte, "end_byte" => end_byte} = diagnostic["span"]

    assert binary_part(source, start_byte, end_byte - start_byte) ==
             "(defn run [input]\n  (return (kernel/mission-model-context \"reader\")))"

    assert {:stderr, rendered} = CommandRenderer.render(outcome)

    assert rendered =~ "bundle/unknown_namespace: #{diagnostic["message"]} "
    assert rendered =~ "at main.clj bytes [#{start_byte},#{end_byte})"
  end

  @tag :tmp_dir
  test "human compile failures render their component byte spans", %{tmp_dir: directory} do
    source = """
    (ns app)

    (defn run [input] (return input))

    (defn broken)
    """

    path =
      write_application(directory, "human-compile-span", valid_manifest(), %{
        "main.clj" => source
      })

    outcome = assert_error(["validate", path], "bundle", "compile_failed")
    diagnostic = outcome.envelope["error"]
    %{"start_byte" => start_byte, "end_byte" => end_byte} = diagnostic["span"]

    assert {:stderr, rendered} = CommandRenderer.render(outcome)

    assert rendered =~
             "the component bundle could not be compiled " <>
               "at main.clj bytes [#{start_byte},#{end_byte}) "
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
  test "CLI --input accepts application-relative and absolute paths and documents resolution", %{
    tmp_dir: directory
  } do
    application =
      write_application(directory, "orders", valid_manifest(), %{
        "orders.json" => ~S({"answer":1})
      })

    alternate = Path.join(directory, "cwd-orders.json")
    File.write!(alternate, ~S({"answer":2}))

    assert {:ok, %CommandOutcome{} = application_relative} =
             CommandEngine.dispatch(["run", application, "--input", "orders.json"])

    assert application_relative.envelope["result"]["value"] == %{"answer" => 1}

    assert {:ok, %CommandOutcome{} = absolute} =
             CommandEngine.dispatch(["run", application, "--input", alternate])

    assert absolute.envelope["result"]["value"] == %{"answer" => 2}

    assert {:ok, %CommandOutcome{} = private_absolute} =
             CommandEngine.dispatch([
               "run",
               application,
               "--private-input",
               alternate,
               "--private-output",
               Path.join(directory, "private-result.json")
             ])

    assert private_absolute.envelope["artifact_class"] == "private"
    assert private_absolute.envelope["result"] == %{"result_class" => "private"}

    assert Jason.decode!(File.read!(Path.join(directory, "private-result.json"))) == %{
             "answer" => 2
           }

    missing =
      assert_error(
        ["run", application, "--input", "missing-orders.json"],
        "application",
        "reference_missing"
      )

    assert missing.envelope["error"]["source"] == %{
             "kind" => "external_input",
             "name" => "input.json"
           }

    assert missing.envelope["error"]["message"] =~ "working-directory"
    refute Jason.encode!(missing.envelope) =~ "missing-orders"

    assert {:ok, %CommandOutcome{} = help} = CommandEngine.prepare(["help", "run"])

    assert Enum.any?(help.envelope["result"]["options"], fn option ->
             "--input INPUT.json" in option["switches"] and
               option["description"] =~ "absolute/cwd path"
           end)

    assert {:error, {:source_role, :external_input, :reference_missing}} =
             ApplicationPackage.request_memory(
               "ptc.json",
               %{
                 "ptc.json" => Jason.encode!(valid_manifest()),
                 "main.clj" => "(ns app) (defn run [input] (return input))",
                 "orders.json" => ~S({"answer":1})
               },
               input: alternate,
               result_projection: :json
             )
  end

  @tag :tmp_dir
  test "manifest source aggregate failures precede external override acquisition", %{
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
        "target" => %{"environment" => "workflow"},
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
        "schema_violation"
      )

    assert outcome.envelope["error"]["source"] == %{
             "kind" => "application",
             "name" => "ptc.json"
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
      ~s|{"target":{"environment":"workflow"},"component_id":"app","base_source_hash":"#{digest}","source_hash":"#{digest}","path":"candidate.clj","extra":| <>
        nested <> "}"

    deep_captured = Path.join(Path.dirname(application), "deep-override.json")
    deep_external = Path.join(directory, "deep-external-override.json")
    File.write!(deep_captured, deep)
    File.write!(deep_external, deep)

    oversized_source = String.duplicate(" ", 1_048_577)
    base_source = "(ns app) (defn run [input] (return input))"

    source_descriptor = fn candidate_name ->
      Jason.encode!(%{
        "target" => %{"environment" => "workflow"},
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
       ~s|{"target":{"environment":"workflow"},"component_id":"app","component_id":"app","base_source_hash":"#{digest}","source_hash":"#{digest}","path":"candidate.clj"}|,
       ""},
      {"unknown",
       Jason.encode!(%{
         "target" => %{"environment" => "workflow"},
         "component_id" => "app",
         "base_source_hash" => digest,
         "source_hash" => digest,
         "path" => "candidate.clj",
         "caller-secret" => "must-not-escape"
       }), ""},
      {"invalid-declared",
       Jason.encode!(%{
         "target" => %{"environment" => "workflow"},
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

  @tag :tmp_dir
  test "override verification failures name the field they broke", %{tmp_dir: directory} do
    base_source = "(ns app) (defn run [input] (return input))"
    candidate = "(ns app) (defn run [input] (return \"candidate\"))"
    application = write_application(directory, "override-verification", valid_manifest())
    File.write!(Path.join(directory, "candidate.clj"), candidate)

    digest = fn bytes -> ComponentOverride.hash(bytes) end
    wrong = "sha256:" <> String.duplicate("0", 64)

    cases = [
      {"ov-stale-base.json", digest.(candidate), wrong, "app",
       "base_source_hash does not match the installed source", "/base_source_hash"},
      {"ov-source-mismatch.json", wrong, digest.(base_source), "app",
       "source_hash does not match the candidate bytes", "/source_hash"},
      {"ov-unknown-component.json", digest.(candidate), digest.(base_source), "nosuchcomponent",
       "component_id is not a selected component", "/component_id"}
    ]

    for {name, source_hash, base_hash, component_id, message, pointer} <- cases do
      descriptor = Path.join(directory, name)

      File.write!(
        descriptor,
        Jason.encode!(%{
          "target" => %{"environment" => "workflow"},
          "component_id" => component_id,
          "base_source_hash" => base_hash,
          "source_hash" => source_hash,
          "path" => "candidate.clj"
        })
      )

      outcome =
        assert_error(
          ["run", application, "--component-override-descriptor", descriptor],
          "application",
          "override_invalid"
        )

      error = outcome.envelope["error"]
      assert error["message"] == message
      assert error["path"] == pointer
      assert error["subject"] == nil

      assert error["source"] == %{
               "kind" => "component_override",
               "name" => "component-override.json"
             }

      encoded = Jason.encode!(outcome.envelope)
      refute encoded =~ name
      refute encoded =~ directory

      {:stderr, rendered} = CommandRenderer.render(outcome)
      assert rendered =~ "#{message} at #{pointer} "
    end
  end

  @tag :tmp_dir
  test "override source confinement names the path field", %{tmp_dir: directory} do
    application = write_application(directory, "override-source-path", valid_manifest())
    digest = "sha256:" <> String.duplicate("0", 64)
    descriptor = Path.join(directory, "ov-escape.json")

    File.write!(
      descriptor,
      Jason.encode!(%{
        "target" => %{"environment" => "workflow"},
        "component_id" => "app",
        "base_source_hash" => digest,
        "source_hash" => digest,
        "path" => "../escape.clj"
      })
    )

    outcome =
      assert_error(
        ["run", application, "--component-override-descriptor", descriptor],
        "application",
        "override_invalid"
      )

    error = outcome.envelope["error"]
    assert error["message"] == "path is not a usable candidate source"
    assert error["path"] == "/path"

    assert error["source"] == %{
             "kind" => "component_override",
             "name" => "component-override.json"
           }

    refute Jason.encode!(outcome.envelope) =~ "ov-escape"
    refute Jason.encode!(outcome.envelope) =~ "escape.clj"
  end

  defp http_mcp_host(endpoint) do
    %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "private-http-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => endpoint,
            "allow_insecure_loopback" => true
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

  defp await_exit(%Task{pid: pid}) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> flunk("prepared-run consumer task did not exit")
    end
  end

  defp manifest_error_path({:manifest_path, path, _reason}), do: path

  defp manifest_error_path(
         {:manifest_schema_invalid, %PtcRunner.Kernel.SchemaViolation{path: path}}
       ),
       do: path
end
