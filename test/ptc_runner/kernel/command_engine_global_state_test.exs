defmodule PtcRunner.Kernel.CommandEngineGlobalStateTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.CommandEngineFixtures

  # These cases mutate VM-global state (`Application.put_env`,
  # `System.put_env`, `File.cd`, or `:persistent_term`). They stay serial;
  # the rest of CommandEngine coverage is `async: true`.

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.StandaloneCLI
  alias PtcRunner.TestSupport.HTTPRequest
  alias PtcRunner.TestSupport.LLMSupport

  @tag :tmp_dir
  test "doctor attributes a reached LLM authentication refusal to credentials", %{
    tmp_dir: directory
  } do
    keys = [:llm_adapter, :host_llm_test_owner, :host_llm_test_result]
    previous = Map.new(keys, &{&1, Application.fetch_env(:ptc_runner, &1)})

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    on_exit(fn -> restore_application_env(previous) end)

    host_path =
      write_host_config(directory, "doctor-llm-auth", literal_credential_host("rejected-key"))

    application = doctor_application(directory, "doctor-llm-auth", workflow: ["model"])

    for kind <- [:authentication_failed, :denied] do
      Application.put_env(
        :ptc_runner,
        :host_llm_test_result,
        {:error,
         ProviderError.new(kind, "PRIVATE PROVIDER MESSAGE", dispatch_provenance: :dispatched)}
      )

      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.prepare([
                 "doctor",
                 application,
                 "--host-config",
                 host_path,
                 "--connect"
               ])

      assert outcome.envelope["error"]["phase"] == "active_preflight"
      assert outcome.envelope["error"]["code"] == "authentication_rejected"
      assert outcome.envelope["error"]["subject"]["operation"] == "credentials"
      refute Jason.encode!(outcome.envelope) =~ "PRIVATE PROVIDER MESSAGE"

      checks = outcome.envelope["result"]["checks"]

      assert %{"status" => "fail", "code" => "authentication_rejected"} =
               Enum.find(checks, &(&1["name"] == "provider/model/credentials"))

      assert %{"status" => "pass", "code" => "available"} =
               Enum.find(checks, &(&1["name"] == "provider/model/connectivity"))

      assert_schema_valid(outcome.envelope)
      assert_receive {:host_llm_request, "openrouter:test/model", _request}
    end

    for provenance <- [nil, :not_dispatched] do
      Application.put_env(
        :ptc_runner,
        :host_llm_test_result,
        {:error,
         ProviderError.new(:authentication_failed, "PRIVATE PROVIDER MESSAGE",
           dispatch_provenance: provenance
         )}
      )

      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.prepare([
                 "doctor",
                 application,
                 "--host-config",
                 host_path,
                 "--connect"
               ])

      assert outcome.envelope["error"]["code"] == "connectivity_unavailable"
      assert outcome.envelope["error"]["subject"]["operation"] == "connectivity"
      refute Jason.encode!(outcome.envelope) =~ "PRIVATE PROVIDER MESSAGE"
      assert_schema_valid(outcome.envelope)
      assert_receive {:host_llm_request, "openrouter:test/model", _request}
    end

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:error, ProviderError.new(:transport_error, "PRIVATE TRANSPORT MESSAGE")}
    )

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert outcome.envelope["error"]["code"] == "connectivity_unavailable"
    assert outcome.envelope["error"]["subject"]["operation"] == "connectivity"

    assert %{"status" => "fail", "code" => "connectivity_unavailable"} =
             Enum.find(
               outcome.envelope["result"]["checks"],
               &(&1["name"] == "provider/model/connectivity")
             )

    refute Jason.encode!(outcome.envelope) =~ "PRIVATE TRANSPORT MESSAGE"
    assert_schema_valid(outcome.envelope)
    assert_receive {:host_llm_request, "openrouter:test/model", _request}
  end

  @tag :tmp_dir
  test "agent LLM failures publish a bounded provider class", %{tmp_dir: directory} do
    keys = [:llm_adapter, :host_llm_test_owner, :host_llm_test_result]
    previous = Map.new(keys, &{&1, Application.fetch_env(:ptc_runner, &1)})

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:error, ProviderError.new(:payment_required, "PRIVATE PROVIDER MESSAGE")}
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_runner, key, value)
        {key, :error} -> Application.delete_env(:ptc_runner, key)
      end)
    end)

    host_path =
      write_host_config(directory, "billing-failure", literal_credential_host("test-key"))

    manifest =
      valid_manifest(%{
        "workflow" => %{
          "components" => [
            %{"id" => "app", "path" => "main.clj", "dependencies" => ["agent.core"]},
            %{"library" => "agent.core"}
          ],
          "entry" => "app/run"
        },
        "missions" => %{"default" => %{}},
        "providers" => %{
          "workflow" => [%{"name" => "model", "config" => %{}}],
          "mission" => []
        }
      })

    for {name, expression} <- [
          {"direct", ~S|(agent.core/run "answer" {"max_turns" 1})|},
          {"pmap", ~S|(pmap (fn [_] (agent.core/run "answer" {"max_turns" 1})) [1])|},
          {"pcalls", ~S|(pcalls #(agent.core/run "answer" {"max_turns" 1}))|}
        ] do
      application =
        write_application(directory, "billing-failure-#{name}", manifest, %{
          "main.clj" => "(ns app) (defn run [_input] #{expression})"
        })

      assert {:error, %CommandOutcome{} = outcome} =
               CommandEngine.dispatch(["run", application, "--host-config", host_path])

      assert outcome.envelope["error"]["code"] == "llm_payment_required"
      assert outcome.envelope["error"]["message"] =~ "billing or credit"
      refute Jason.encode!(outcome.envelope) =~ "PRIVATE PROVIDER MESSAGE"
      assert_schema_valid(outcome.envelope)
    end

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:error, ProviderError.new(:invalid_result, "PRIVATE INVALID RESPONSE")}
    )

    invalid_response =
      write_application(directory, "invalid-provider-response", manifest, %{
        "main.clj" => ~S|(ns app) (defn run [_input] (agent.core/run "answer" {"max_turns" 1}))|
      })

    assert {:error, %CommandOutcome{} = invalid_outcome} =
             CommandEngine.dispatch(["run", invalid_response, "--host-config", host_path])

    assert invalid_outcome.envelope["error"]["code"] == "llm_provider_failed"
    assert invalid_outcome.envelope["error"]["retryable"] == false
    refute Jason.encode!(invalid_outcome.envelope) =~ "PRIVATE INVALID RESPONSE"
    assert_schema_valid(invalid_outcome.envelope)

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:error,
       ProviderError.new(:usage_unavailable, "PRIVATE USAGE RESPONSE",
         dispatch_provenance: :dispatched
       )}
    )

    usage_unavailable =
      write_application(directory, "usage-unavailable", manifest, %{
        "main.clj" => ~S|(ns app) (defn run [_input] (agent.core/run "answer" {"max_turns" 1}))|
      })

    assert {:error, %CommandOutcome{} = usage_outcome} =
             CommandEngine.dispatch(["run", usage_unavailable, "--host-config", host_path])

    assert usage_outcome.envelope["error"]["code"] == "llm_usage_unavailable"

    assert usage_outcome.envelope["execution"]["usage"]["llm_spend"] == %{
             "state" => "incomplete"
           }

    assert [usage_row] = usage_outcome.envelope["execution"]["usage"]["llm_usage"]
    assert usage_row["missing_usage_calls"] == 1
    refute Jason.encode!(usage_outcome.envelope) =~ "PRIVATE USAGE RESPONSE"
    assert_schema_valid(usage_outcome.envelope)

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:error,
       ProviderError.new(:invalid_request, "PRIVATE LOCAL VALIDATION",
         dispatch_provenance: :not_dispatched
       )}
    )

    not_dispatched =
      write_application(directory, "not-dispatched", manifest, %{
        "main.clj" => ~S|(ns app) (defn run [_input] (agent.core/run "answer" {"max_turns" 1}))|
      })

    assert {:error, %CommandOutcome{} = not_dispatched_outcome} =
             CommandEngine.dispatch(["run", not_dispatched, "--host-config", host_path])

    not_dispatched_usage = not_dispatched_outcome.envelope["execution"]["usage"]
    assert not_dispatched_outcome.envelope["error"]["code"] == "llm_request_invalid"
    assert not_dispatched_usage["llm_spend"] == %{"state" => "empty"}
    assert [not_dispatched_row] = not_dispatched_usage["llm_usage"]
    assert not_dispatched_row["missing_usage_calls"] == 0
    refute Jason.encode!(not_dispatched_outcome.envelope) =~ "PRIVATE LOCAL VALIDATION"
    assert_schema_valid(not_dispatched_outcome.envelope)

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:error, ProviderError.new(:tool_calling_unsupported, "PRIVATE TOOL CAPABILITY RESPONSE")}
    )

    tool_unsupported =
      write_application(directory, "tool-calling-unsupported", manifest, %{
        "main.clj" => ~S|(ns app) (defn run [_input] (agent.core/run "answer" {"max_turns" 1}))|
      })

    assert {:error, %CommandOutcome{} = unsupported_outcome} =
             CommandEngine.dispatch(["run", tool_unsupported, "--host-config", host_path])

    assert unsupported_outcome.envelope["error"]["code"] == "llm_tool_calling_unsupported"
    assert unsupported_outcome.envelope["error"]["message"] =~ "does not support tool calling"
    refute Jason.encode!(unsupported_outcome.envelope) =~ "PRIVATE TOOL CAPABILITY RESPONSE"
    assert_schema_valid(unsupported_outcome.envelope)
  end

  @tag :tmp_dir
  test "commands resolve deferred environment before active work and live reporting", %{
    tmp_dir: directory
  } do
    environment_name = "PTC_TEST_DOCTOR_CONNECT_TOKEN"
    previous_environment = System.get_env(environment_name)
    previous_viewer_url = System.get_env("PTC_VIEWER_URL")
    System.put_env(environment_name, "ambient-secret")
    System.put_env("PTC_VIEWER_URL", "http://127.0.0.1:1")

    provider_applications = LLMSupport.snapshot_provider_applications()

    previous =
      for key <- [
            :llm_adapter,
            :host_llm_test_owner,
            :host_llm_test_provider_application,
            :host_llm_test_result
          ],
          into: %{},
          do: {key, Application.fetch_env(:ptc_runner, key)}

    :ok = LLMSupport.stop_provider_applications()

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_provider_application, :req_llm)

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:ok, %{content: "ok", tokens: %{input: 8, output: 1, total_cost: 3.0e-6}}}
    )

    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    Application.put_env(:llm_db, :load_dotenv, false, persistent: true)

    on_exit(fn ->
      if previous_environment,
        do: System.put_env(environment_name, previous_environment),
        else: System.delete_env(environment_name)

      if previous_viewer_url,
        do: System.put_env("PTC_VIEWER_URL", previous_viewer_url),
        else: System.delete_env("PTC_VIEWER_URL")

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_runner, key, value)
        {key, :error} -> Application.delete_env(:ptc_runner, key)
      end)

      LLMSupport.restore_provider_applications(provider_applications)
    end)

    host_path =
      write_host_config(directory, "command-owned-model", %{
        "credentials" => %{"key" => %{"env" => environment_name}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "model-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })

    application = doctor_application(directory, "command-owned-model", workflow: ["model"])
    env_file = Path.join(directory, "model.env")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    _server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = HTTPRequest.receive_complete(socket)
        send(parent, {:deferred_viewer_request, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        :ok = :gen_tcp.close(socket)
      end)

    File.write!(
      env_file,
      "#{environment_name}=test-secret\nPTC_VIEWER_URL=http://127.0.0.1:#{port}\n"
    )

    presentation =
      StandaloneCLI.execute([
        "doctor",
        application,
        "--host-config",
        host_path,
        "--connect",
        "--env-file",
        env_file
      ])

    outcome = presentation.outcome
    assert presentation.exit_status == 0
    assert outcome.exit_status == 0
    assert outcome.envelope["result"]["provider_activity"] == true
    assert System.get_env(environment_name) == "ambient-secret"
    assert_received {:host_llm_ensure_ready, _pid}

    assert_received {:host_llm_request, "openrouter:test/model", %{credential: "test-secret"}}

    # The readiness check bills a real request, so it accounts for one, on the
    # rows a run reports. `max_tokens: 1` bounds the magnitude, not the
    # attribution.
    assert outcome.envelope["result"]["usage"] == %{
             "llm_usage_state" => "available",
             "llm_usage" => [
               %{
                 "alias" => "model",
                 "installation_revision" => "model-v1",
                 "calls" => 1,
                 "successful_calls" => 1,
                 "usage_calls" => 1,
                 "missing_usage_calls" => 0,
                 "usage_overflow" => false,
                 "usage" => %{
                   "input" => 8,
                   "output" => 1,
                   "total_cost" => %{"currency" => "USD", "microunits" => 3}
                 }
               }
             ]
           }

    assert %{exit_status: 0} =
             StandaloneCLI.execute([
               "run",
               application,
               "--host-config",
               host_path,
               "--env-file",
               env_file
             ])

    assert_receive {:deferred_viewer_request, request}, 2_000
    assert request =~ ~s|"label":"ptc.json · app/run"|
    :ok = :gen_tcp.close(listener)
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
  test "doctor --connect turns a missing credential into a failed check", %{
    tmp_dir: directory
  } do
    environment_name = "PTC_TEST_DOCTOR_MISSING_CREDENTIAL"
    previous_environment = System.get_env(environment_name)
    System.delete_env(environment_name)

    on_exit(fn ->
      if previous_environment,
        do: System.put_env(environment_name, previous_environment),
        else: System.delete_env(environment_name)
    end)

    host_path =
      write_host_config(
        directory,
        "connect-missing-credential",
        stdio_credential_host(environment_name)
      )

    application =
      doctor_application(directory, "connect-missing-credential", mission: ["workspace"])

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
    assert outcome.envelope["error"]["code"] == "credential_unavailable"
    assert outcome.envelope["error"]["subject"]["operation"] == "credentials"

    result = outcome.envelope["result"]
    assert result["readiness"] == "failed"

    assert result["provider_activity"] ==
             outcome.envelope["error"]["provider_activity"]

    assert %{"status" => "fail", "code" => "credential_unavailable"} =
             Enum.find(result["checks"], &(&1["name"] == "provider/workspace/credentials"))

    assert %{"status" => "skipped", "code" => "not_verified_due_to_failure"} =
             Enum.find(result["checks"], &(&1["name"] == "provider/workspace/connectivity"))

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "run stderr explains named env-file precedence only when a file is selected", %{
    tmp_dir: directory
  } do
    environment_name = "PTC_TEST_RUN_MISSING_NAMED_ENV_CREDENTIAL"
    previous_environment = System.get_env(environment_name)
    System.delete_env(environment_name)

    on_exit(fn ->
      if previous_environment,
        do: System.put_env(environment_name, previous_environment),
        else: System.delete_env(environment_name)
    end)

    host_path =
      write_host_config(
        directory,
        "run-missing-named-env",
        stdio_credential_host(environment_name)
      )

    application = doctor_application(directory, "run-missing-named-env", mission: ["workspace"])

    env_file = Path.join(directory, "model.env")
    File.write!(env_file, "# #{environment_name}\n")

    with_file =
      StandaloneCLI.execute([
        "run",
        application,
        "--host-config",
        host_path,
        "--env-file",
        env_file
      ])

    without_file = StandaloneCLI.execute(["run", application, "--host-config", host_path])

    file_credential_host =
      stdio_credential_host(environment_name)
      |> put_in(["credentials", "key"], %{"file" => "missing-token"})

    file_credential_host_path =
      write_host_config(directory, "run-missing-file-credential", file_credential_host)

    unrelated_file =
      StandaloneCLI.execute([
        "run",
        application,
        "--host-config",
        file_credential_host_path,
        "--env-file",
        env_file
      ])

    mixed_credential_host =
      stdio_credential_host(environment_name)
      |> put_in(["credentials", "file_key"], %{"file" => "missing-token"})
      |> put_in(["install", "workspace", "transport", "env", "FILE_TOKEN"], %{
        "binding" => "file_key"
      })

    mixed_credential_host_path =
      write_host_config(directory, "run-mixed-credentials", mixed_credential_host)

    mixed_sources =
      StandaloneCLI.execute([
        "run",
        application,
        "--host-config",
        mixed_credential_host_path,
        "--env-file",
        env_file
      ])

    assert with_file.outcome.envelope["error"] == without_file.outcome.envelope["error"]
    assert with_file.stderr =~ "assignments in a named environment file override process values"
    assert with_file.stderr =~ "including empty assignments"
    refute with_file.stderr =~ env_file
    refute without_file.stderr =~ "assignments in a named environment file"
    assert unrelated_file.outcome.envelope["error"]["code"] == "credential_unavailable"
    refute unrelated_file.stderr =~ "assignments in a named environment file"
    assert mixed_sources.outcome.envelope["error"]["code"] == "credential_unavailable"
    assert mixed_sources.stderr =~ "assignments in a named environment file"
  end

  @tag :tmp_dir
  test "--env-file supplies an MCP transport credential, not only an LLM one", %{
    tmp_dir: directory
  } do
    environment_name = "PTC_TEST_MCP_ENV_FILE_CREDENTIAL"
    previous_environment = System.get_env(environment_name)
    System.delete_env(environment_name)

    on_exit(fn ->
      if previous_environment,
        do: System.put_env(environment_name, previous_environment),
        else: System.delete_env(environment_name)
    end)

    host_path =
      write_host_config(directory, "mcp-env-file", stdio_credential_host(environment_name))

    application = doctor_application(directory, "mcp-env-file", mission: ["workspace"])
    env_file = Path.join(directory, "mcp.env")
    File.write!(env_file, "#{environment_name}=test-secret\n")

    presentation =
      StandaloneCLI.execute([
        "doctor",
        application,
        "--host-config",
        host_path,
        "--connect",
        "--env-file",
        env_file
      ])

    # An MCP-only project reached `credential_unavailable` with the named file
    # never read: environment setup was gated on the selected provider being an
    # LLM, while an MCP transport binds environment credentials the same way.
    assert System.get_env(environment_name) == nil

    refute presentation.outcome.envelope["error"]["code"] == "credential_unavailable"
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

    assert {:error, outcome} = CommandEngine.preflight(preparation)
    assert outcome.exit_status == 7
    assert outcome.envelope["error"]["phase"] == "destination"
    assert outcome.envelope["error"]["code"] == "invalid_result_destination"
    assert outcome.envelope["artifact_state"]["trace"] == "not_written"
    assert outcome.envelope["artifact_state"]["result"] == "not_written"
    refute Jason.encode!(outcome.envelope) =~ directory
  end

  @tag :tmp_dir
  test "an unavailable cwd keeps the inspection destination diagnostic accurate", %{
    tmp_dir: directory
  } do
    invocation = Path.join(directory, "removed-inspection-cwd")
    application = write_application(directory, "unavailable-inspection-cwd", valid_manifest())
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
               "--inspect",
               "run.ptcins"
             ])

    assert preparation.artifact_destinations == %{}
    assert preparation.artifact_destination_failures == [:inspect]
    assert CommandPreparation.valid?(preparation)

    assert {:error, outcome} = CommandEngine.preflight(preparation)
    assert outcome.exit_status == 7

    assert %{
             "phase" => "destination",
             "code" => "invalid_inspection_destination",
             "message" => "--inspect must name a valid destination ending in .ptcins",
             "retryable" => false,
             "source" => nil,
             "subject" => nil
           } = outcome.envelope["error"]

    refute Jason.encode!(outcome.envelope) =~ directory
  end

  @tag :tmp_dir
  test "CLI --input prefers application-relative names over cwd files and accepts cwd paths",
       %{
         tmp_dir: directory
       } do
    application =
      write_application(directory, "orders", valid_manifest(), %{
        "choice.json" => ~S({"answer":"application"})
      })

    File.write!(Path.join(directory, "choice.json"), ~S({"answer":"cwd"}))
    File.write!(Path.join(directory, "cwd-only.json"), ~S({"answer":"cwd-only"}))

    original = File.cwd!()
    on_exit(fn -> File.cd!(original) end)
    File.cd!(directory)

    assert {:ok, %CommandOutcome{} = preferred} =
             CommandEngine.dispatch(["run", application, "--input", "choice.json"])

    assert preferred.envelope["result"]["value"] == %{"answer" => "application"}

    assert {:ok, %CommandOutcome{} = cwd_only} =
             CommandEngine.dispatch(["run", application, "--input", "cwd-only.json"])

    assert cwd_only.envelope["result"]["value"] == %{"answer" => "cwd-only"}
  end

  @tag :tmp_dir
  test "entry still rejects captured envelope collisions when another destination cannot anchor",
       %{
         tmp_dir: directory
       } do
    invocation = Path.join(directory, "removed-entry-cwd")
    collision = Path.join(directory, "shared.ptcins")
    original = File.cwd!()
    File.mkdir!(invocation)

    on_exit(fn -> File.cd!(original) end)

    File.cd!(invocation)
    File.rmdir!(invocation)
    assert {:error, :enoent} = File.cwd()

    assert {:error, entry} =
             CommandEntry.open_with_ref(
               [
                 "run",
                 "ptc.json",
                 "--output",
                 "relative-result.json",
                 "--inspect",
                 collision,
                 "--envelope",
                 collision
               ],
               :standalone,
               "cmd-00000000000000000000000001"
             )

    assert entry.rejection.kind == :destination_collision
    assert entry.rejection.conflicts == ["--inspect", "--envelope"]
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
  @tag timeout: 30_000
  test "an in-flight LLM call cancelled by a timeout reports missing usage", %{tmp_dir: directory} do
    keys = [:llm_adapter, :host_llm_test_owner, :host_llm_test_block, :host_llm_test_result]

    previous = Map.new(keys, &{&1, Application.fetch_env(:ptc_runner, &1)})

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_block, true)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_runner, key, value)
        {key, :error} -> Application.delete_env(:ptc_runner, key)
      end)
    end)

    host_path =
      write_host_config(directory, "timeout-inflight", literal_credential_host("test-key"))

    manifest =
      valid_manifest(%{
        "workflow" => %{
          "components" => [
            %{"id" => "app", "path" => "main.clj", "dependencies" => ["llm"]},
            %{"library" => "llm"}
          ],
          "entry" => "app/run"
        },
        "providers" => %{
          "workflow" => [%{"name" => "model", "config" => %{}}],
          "mission" => []
        },
        "limits" => %{
          "evaluation_timeout_ms" => 15_000,
          "workflow_timeout_ms" => 1_000,
          "run_duration_ms" => 30_000
        }
      })

    application =
      write_application(directory, "timeout-inflight", manifest, %{
        "main.clj" => ~S|(ns app) (defn run [_input] (llm/request {"messages" []}))|
      })

    # Dispatcher emits `capability-started` before invoking the adapter, so
    # receiving the blocked request is the synchronization that the start is
    # already in the terminal batch. The evaluation is then killed while the
    # provider worker is still blocked, leaving no matching stop. The workflow
    # clock is the binding limit so that kill wins against the dispatcher's
    # provider-await timer: when `run_duration_ms` is the tighter bound, that
    # timer can emit a matched failed stop (`missing_usage_calls` stays 0).
    # No sleep.
    task =
      Task.async(fn ->
        CommandEngine.dispatch(["run", application, "--host-config", host_path])
      end)

    receive do
      {:host_llm_ensure_ready, _pid} ->
        assert_receive {:host_llm_request, _model, _request}, 10_000

      {:host_llm_request, _model, _request} ->
        :ok
    after
      10_000 ->
        flunk("did not observe the in-flight LLM request after capability-started")
    end

    assert {:error, %CommandOutcome{} = outcome} = Task.await(task, 15_000)
    assert outcome.envelope["error"]["code"] in ["run_timeout", "runtime_limit_exceeded"]

    usage = outcome.envelope["execution"]["usage"]
    assert usage["llm_usage_state"] == "available"

    expected_counters = %{
      "calls" => 1,
      "successful_calls" => 0,
      "usage_calls" => 0,
      "missing_usage_calls" => 1,
      "usage" => %{}
    }

    assert [row] = usage["llm_usage"]
    assert Map.take(row, Map.keys(expected_counters)) == expected_counters
    assert row["alias"] == "model"
    assert row["installation_revision"] == "model-v1"
    refute Map.has_key?(row["usage"], "total_cost")

    alias_calls = Enum.reduce(usage["llm_usage"], 0, &(&2 + &1["calls"]))
    model_calls = Enum.reduce(usage["llm_usage_by_model"], 0, &(&2 + &1["calls"]))
    assert model_calls + usage["unattributed_model_calls"] == alias_calls

    assert_schema_valid(outcome.envelope)
  end

  @tag :tmp_dir
  test "an uncataloged model warning reaches the V4 envelope and trace", %{tmp_dir: directory} do
    keys = [
      :llm_adapter,
      :host_llm_test_owner,
      :host_llm_test_result,
      :host_llm_test_catalog_status,
      :host_llm_test_public_model
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:ptc_runner, &1)})

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())
    Application.put_env(:ptc_runner, :host_llm_test_catalog_status, :uncataloged)
    Application.put_env(:ptc_runner, :host_llm_test_public_model, true)

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:ok, %{content: "ok", tokens: %{input: 1, output: 1}}}
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_runner, key, value)
        {key, :error} -> Application.delete_env(:ptc_runner, key)
      end)
    end)

    host_path =
      write_host_config(directory, "uncataloged-warning", literal_credential_host("test-key"))

    manifest =
      valid_manifest(%{
        "workflow" => %{
          "components" => [
            %{"id" => "app", "path" => "main.clj", "dependencies" => ["llm"]},
            %{"library" => "llm"}
          ],
          "entry" => "app/run"
        },
        "providers" => %{
          "workflow" => [%{"name" => "model", "config" => %{}}],
          "mission" => []
        }
      })

    application =
      write_application(directory, "uncataloged-warning", manifest, %{
        "main.clj" => ~S|(ns app) (defn run [_input] (llm/request {"messages" []}))|
      })

    trace_dir = Path.join(directory, "traces")
    File.mkdir!(trace_dir)

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.dispatch([
               "run",
               application,
               "--host-config",
               host_path,
               "--trace-dir",
               trace_dir
             ])

    warning = %{
      "code" => "model_uncataloged",
      "message" =>
        "the configured model is not an exact catalog entry; pricing, limits, token estimation, and capability detection may be incomplete",
      "provider" => "model",
      "model" => "openrouter:test/model"
    }

    assert outcome.envelope["schema_version"] == 4
    assert outcome.envelope["warnings"] == [warning]
    assert_schema_valid(outcome.envelope)

    assert [trace_path] = Path.wildcard(Path.join(trace_dir, "*.jsonl"))

    started =
      trace_path
      |> File.stream!()
      |> Stream.map(&Jason.decode!/1)
      |> Enum.find(&(&1["type"] == "run-started"))

    assert started["data"]["warnings"] == [warning]
  end

  @tag :tmp_dir
  test "an uncataloged cost-budget refusal explains pricing in run and doctor", %{
    tmp_dir: directory
  } do
    keys = [
      :llm_adapter,
      :host_llm_test_owner,
      :host_llm_test_prepare_error,
      :host_llm_test_public_model
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:ptc_runner, &1)})

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    Application.put_env(
      :ptc_runner,
      :host_llm_test_prepare_error,
      :uncataloged_cost_reservation_pricing_unavailable
    )

    Application.put_env(:ptc_runner, :host_llm_test_public_model, true)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_runner, key, value)
        {key, :error} -> Application.delete_env(:ptc_runner, key)
      end)
    end)

    model = "openrouter:future-vendor/future-priced-model-1724"

    host = uncataloged_cost_host(model)

    host_path = write_host_config(directory, "uncataloged-cost", host)

    manifest =
      valid_manifest(%{
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "providers" => %{
          "workflow" => [%{"name" => "model", "config" => %{}}],
          "mission" => []
        }
      })

    application =
      write_application(directory, "uncataloged-cost", manifest, %{
        "main.clj" => ~S|(ns app) (defn run [_input] true)|
      })

    assert {:error, %CommandOutcome{} = run} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    assert run.exit_status == 4, inspect(run.envelope)
    assert run.envelope["error"]["phase"] == "local_preflight", inspect(run.envelope)
    assert run.envelope["error"]["code"] == "model_contract_unsupported"
    assert run.envelope["error"]["provider_activity"] == true
    assert run.envelope["error"]["notes"] == []
    assert run.envelope["error"]["subject"]["name"] == "model"
    assert run.envelope["error"]["message"] =~ "llm_cost_microusd"
    assert run.envelope["error"]["message"] =~ model
    assert run.envelope["error"]["message"] =~ "supported USD reservation pricing"

    assert run.envelope["warnings"] == [
             %{
               "code" => "model_uncataloged",
               "message" =>
                 "the configured model is not an exact catalog entry; pricing, limits, token estimation, and capability detection may be incomplete",
               "provider" => "model",
               "model" => model
             }
           ]

    assert {:stderr, run_stderr} = CommandRenderer.render(run)
    assert run_stderr =~ "warning: model_uncataloged"
    assert run_stderr =~ model

    assert_schema_valid(run.envelope)

    message_prefix = "llm_cost_microusd requires supported USD reservation pricing for "

    message_suffix =
      "; remove limits.llm_cost_microusd, or select a model with supported USD reservation pricing"

    for invalid_message <- [
          message_prefix <> ~S("invalid\qescape") <> message_suffix,
          message_prefix <> ~S("\u0061") <> message_suffix,
          message_prefix <> ~S("\/") <> message_suffix,
          message_prefix <> Jason.encode!(String.duplicate("a", 257)) <> message_suffix,
          message_prefix <> Jason.encode!(String.duplicate("é", 129)) <> message_suffix,
          run.envelope["error"]["message"] <> "\n"
        ] do
      assert_schema_invalid(put_in(run.envelope, ["error", "message"], invalid_message))
    end

    Application.put_env(:ptc_runner, :host_llm_test_public_model, false)

    assert {:error, %CommandOutcome{} = private_run} =
             CommandEngine.dispatch(["run", application, "--host-config", host_path])

    refute private_run.envelope["error"]["message"] =~ model
    assert private_run.envelope["error"]["message"] =~ "the selected model"
    assert [%{"code" => "model_uncataloged", "model" => nil}] = private_run.envelope["warnings"]
    assert_schema_valid(private_run.envelope)

    Application.put_env(:ptc_runner, :host_llm_test_public_model, true)

    assert {:error, %CommandOutcome{} = doctor} =
             CommandEngine.dispatch([
               "doctor",
               application,
               "--host-config",
               host_path,
               "--connect"
             ])

    assert {:stdio, _doctor_stdout, doctor_stderr} = CommandRenderer.render(doctor)

    assert doctor_stderr =~ "warning: model_uncataloged"
    assert doctor_stderr =~ model
    assert doctor_stderr =~ "pricing"

    assert doctor.exit_status == 4
    assert doctor.envelope["result"]["readiness"] == "failed", inspect(doctor.envelope)
    assert doctor.envelope["result"]["provider_activity"] == true
    assert doctor.envelope["warnings"] == []
    assert doctor.envelope["error"]["code"] == "model_contract_unsupported"

    assert Enum.any?(doctor.envelope["result"]["checks"], fn check ->
             check == %{
               "name" => "provider/model/local",
               "status" => "fail",
               "code" => "model_contract_unsupported"
             }
           end)

    refute_received {:host_llm_request, _, _}
    assert_schema_valid(doctor.envelope)
  end

  defp restore_application_env(previous) do
    Enum.each(previous, fn
      {key, {:ok, value}} -> Application.put_env(:ptc_runner, key, value)
      {key, :error} -> Application.delete_env(:ptc_runner, key)
    end)
  end
end
