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
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.StandaloneCLI
  alias PtcRunner.TestSupport.LLMSupport

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
      write_host_config(directory, "billing-failure", %{
        "credentials" => %{"key" => %{"literal" => "test-key"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "installation_revision" => "model-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })

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
  test "doctor --connect sets up selected environment credentials before active work", %{
    tmp_dir: directory
  } do
    environment_name = "PTC_TEST_DOCTOR_CONNECT_TOKEN"
    previous_environment = System.get_env(environment_name)
    System.delete_env(environment_name)

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
            "installation_revision" => "model-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })

    application = doctor_application(directory, "command-owned-model", workflow: ["model"])
    env_file = Path.join(directory, "model.env")
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

    outcome = presentation.outcome
    assert presentation.exit_status == 0
    assert outcome.exit_status == 0
    assert outcome.envelope["result"]["provider_activity"] == true
    assert System.get_env(environment_name) == "test-secret"
    assert_received {:host_llm_ensure_ready, _pid}
    assert_received {:host_llm_request, "openrouter:test/model", _request}

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
                 "usage" => %{"input" => 8, "output" => 1, "total_cost" => 3.0e-6}
               }
             ]
           }
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
    assert System.get_env(environment_name) == "test-secret"

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
               "run.inspection.jsonl"
             ])

    assert preparation.artifact_destinations == %{}
    assert preparation.artifact_destination_failures == [:inspect]
    assert CommandPreparation.valid?(preparation)

    assert {:error, outcome} = CommandEngine.preflight(preparation)
    assert outcome.exit_status == 7

    assert %{
             "phase" => "destination",
             "code" => "invalid_inspection_destination",
             "message" => "--inspect must name a valid destination ending in .inspection.jsonl",
             "retryable" => false,
             "source" => nil,
             "subject" => nil
           } = outcome.envelope["error"]

    refute Jason.encode!(outcome.envelope) =~ directory
  end

  @tag :tmp_dir
  test "entry still rejects captured envelope collisions when another destination cannot anchor",
       %{
         tmp_dir: directory
       } do
    invocation = Path.join(directory, "removed-entry-cwd")
    collision = Path.join(directory, "shared.inspection.jsonl")
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
end
