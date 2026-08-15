defmodule PtcRunner.Kernel.LLMReplayTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers the `llm_replay` host source: fixture decoding, bounds, identity, and
  owner lifecycle. Each test builds the minimal fixture set needed to prove the
  runtime contract.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.TestSupport.RunLifecycle

  @request %{"system" => "bounded", "messages" => [%{"role" => "user", "content" => "hi"}]}

  describe "fixture decoding" do
    @tag :tmp_dir
    test "the local probe parses fixtures without starting a replay owner", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "responses" => [%{"n" => 1}, %{"n" => 2}]}])

      assert {:ok,
              %{
                entry_count: 1,
                response_count: 2,
                fixture_hash: "sha256:" <> _digest,
                max_result_bytes: 250_000
              }} = LLMReplay.probe(dir, "replay.jsonl", opts([]))

      File.write!(Path.join(dir, "replay.jsonl"), "not-json\n")

      assert {:error, :invalid_replay_fixtures} =
               LLMReplay.probe(dir, "replay.jsonl", opts([]))
    end

    @tag :tmp_dir
    test "a single response answers every call with the same value", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"content" => "only"}}])

      {:ok, replay} = start(dir)
      requester = LLMReplay.requester(replay)

      assert {:ok, %{"content" => "only"}} = requester.(@request)
      assert {:error, %ProviderError{kind: :not_found}} = requester.(@request)
    end

    @tag :tmp_dir
    test "an ordered sequence is consumed once per call and then closes", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)

      write(dir, [
        %{"request_hash" => key, "responses" => [%{"turn" => 1}, %{"turn" => 2}]}
      ])

      {:ok, replay} = start(dir)
      requester = LLMReplay.requester(replay)

      assert {:ok, %{"turn" => 1}} = requester.(@request)
      assert {:ok, %{"turn" => 2}} = requester.(@request)

      assert {:error, %ProviderError{kind: :not_found, retryable?: false} = error} =
               requester.(@request)

      assert error.details =~ "exhausted"
    end

    @tag :tmp_dir
    test "an unmatched request fails closed rather than reusing another response", %{
      tmp_dir: dir
    } do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"content" => "only"}}])

      {:ok, replay} = start(dir)

      unmatched = %{"system" => "different", "messages" => []}
      {:ok, unmatched_hash} = LLMReplay.request_hash(unmatched)

      assert {:error, %ProviderError{kind: :not_found, retryable?: false} = error} =
               LLMReplay.requester(replay).(unmatched)

      assert error.details ==
               "no replay fixture matches this request (request_hash: #{unmatched_hash})"

      assert error.replay_request_hash == unmatched_hash

      assert_raise ArgumentError, fn ->
        ProviderError.new(:not_found, error.details,
          replay_request_hash: "sha256:" <> String.duplicate("0", 64)
        )
      end
    end

    @tag :tmp_dir
    test "a replay miss is never retryable", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"content" => "only"}}])
      {:ok, replay} = start(dir)

      # A frozen answer set cannot become available on a second attempt, so a
      # retryable classification would only spend the agent's turn budget.
      assert {:error, %ProviderError{retryable?: false}} =
               LLMReplay.requester(replay).(%{"messages" => []})
    end

    @tag :tmp_dir
    test "rejects duplicate entries, both keys and request hashes", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)

      write(dir, [
        %{"request_hash" => key, "response" => %{"n" => 1}},
        %{"request_hash" => key, "response" => %{"n" => 2}}
      ])

      assert {:error, :duplicate_replay_entry} = start(dir)

      File.write!(
        Path.join(dir, "replay.jsonl"),
        ~s({"request_hash": "#{key}", "response": {"n": 1}, "response": {"n": 2}}\n)
      )

      assert {:error, :invalid_replay_fixtures} = start(dir)
    end

    @tag :tmp_dir
    test "rejects malformed entries", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)

      File.write!(
        Path.join(dir, "replay.jsonl"),
        Jason.encode!(%{"request_hash" => key, "response" => %{}}) <> "\n"
      )

      assert {:error, :invalid_replay_fixtures} = start(dir)

      for entry <- [
            %{"request_hash" => "not-a-hash", "response" => %{}},
            %{"request_hash" => key, "response" => "not an object"},
            %{"request_hash" => key},
            %{"request_hash" => key, "responses" => []},
            %{"request_hash" => key, "response" => %{}, "responses" => [%{}]},
            %{"request_hash" => key, "response" => %{}, "unexpected" => true},
            %{"schema_version" => 2, "request_hash" => key, "response" => %{}}
          ] do
        write(dir, [entry])
        assert {:error, :invalid_replay_fixtures} = start(dir), "accepted #{inspect(entry)}"
      end
    end

    @tag :tmp_dir
    test "rejects an empty fixture file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "replay.jsonl"), "\n\n")
      assert {:error, :invalid_replay_fixtures} = start(dir)
    end

    @tag :tmp_dir
    test "enforces the entry ceiling and the response ceiling", %{tmp_dir: dir} do
      entries =
        for index <- 1..4 do
          {:ok, key} = LLMReplay.request_hash(%{"n" => index})
          %{"request_hash" => key, "response" => %{"n" => index}}
        end

      write(dir, entries)
      assert {:error, :replay_entry_limit_exceeded} = start(dir, max_entries: 3)

      {:ok, key} = LLMReplay.request_hash(@request)

      write(dir, [
        %{"request_hash" => key, "response" => %{"blob" => String.duplicate("x", 4_096)}}
      ])

      assert {:error, :invalid_replay_fixtures} = start(dir, max_result_bytes: 512)
    end
  end

  describe "identity and lifecycle" do
    @tag :tmp_dir
    test "the safe snapshot carries counts and ceilings but no payload or path", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "responses" => [%{"secret" => "shh"}, %{"n" => 2}]}])

      {:ok, replay} = start(dir)
      snapshot = LLMReplay.snapshot(replay)

      assert snapshot["source"] == "llm_replay"
      assert snapshot["entry_count"] == 1
      assert snapshot["response_count"] == 2
      assert snapshot["fixture_set_hash"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
      assert snapshot["max_result_bytes"] == 250_000

      encoded = inspect(snapshot)
      refute encoded =~ "shh"
      refute encoded =~ dir
      refute encoded =~ "replay.jsonl"
    end

    @tag :tmp_dir
    test "a changed fixture set changes the identity", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"n" => 1}}])
      {:ok, first} = start(dir)

      write(dir, [%{"request_hash" => key, "response" => %{"n" => 2}}])
      {:ok, second} = start(dir)

      refute LLMReplay.snapshot(first)["fixture_set_hash"] ==
               LLMReplay.snapshot(second)["fixture_set_hash"]
    end

    @tag :tmp_dir
    test "the required installation revision changes provider identity", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"n" => 1}}])

      snapshot = fn revision ->
        paths = write_application(dir, installation_revision: revision)
        {:ok, host} = HostConfig.load(paths.host)

        {:ok, registry} =
          HostInstallation.catalog(host)
          |> then(fn {:ok, catalog} ->
            HostInstallation.runtime_registry(host, catalog)
          end)

        {:ok, limits} = Limits.new()

        context = %{
          application_content_digest: String.duplicate("0", 64),
          destination: :workflow,
          owner: self(),
          limits: limits,
          installed_limits: limits
        }

        {:ok, built} = ProviderRegistry.build(registry, "replay-llm", %{}, context)
        if built.close, do: built.close.()
        built.snapshot
      end

      third = snapshot.("deployment-3")
      fourth = snapshot.("deployment-4")

      assert third["declaration"]["installation_revision"] == "deployment-3"

      # The revision has to enter the identity before it is hashed, or a
      # revision change would leave trial attribution unchanged.
      refute third["snapshot_hash"] == fourth["snapshot_hash"]
    end

    @tag :tmp_dir
    test "the owner dies with the process that acquired it", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"n" => 1}}])

      owner = spawn(fn -> receive do: (:release -> :ok) end)
      {:ok, replay} = LLMReplay.start(dir, "replay.jsonl", opts(owner: owner))

      assert Process.alive?(replay.pid)
      reference = Process.monitor(replay.pid)

      # A run that fails between acquisition and cleanup must not leave a
      # replay owner behind holding its fixture set.
      send(owner, :release)
      assert_receive {:DOWN, ^reference, :process, _pid, _reason}, 2_000
    end

    @tag :tmp_dir
    test "stopping the owner is idempotent and releases the process", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"n" => 1}}])
      {:ok, replay} = start(dir)

      assert Process.alive?(replay.pid)
      assert :ok = LLMReplay.stop(replay)
      refute Process.alive?(replay.pid)
      assert :ok = LLMReplay.stop(replay)

      assert {:error, %ProviderError{kind: :unavailable}} =
               LLMReplay.requester(replay).(@request)
    end

    @tag :tmp_dir
    test "an unavailable registrar is not reported as invalid fixtures", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"n" => 1}}])

      {:ok, session} = ProviderSession.start(Limits.defaults())
      {:ok, registrar} = ProviderSession.open_registrar(session)
      assert :ok = ResourceRegistrar.activate(registrar)
      owner = ResourceRegistrar.owner(registrar)
      assert :ok = ResourceRegistrar.abort(registrar)

      assert {:error, :resource_registrar_unavailable} =
               LLMReplay.start(dir, "replay.jsonl",
                 max_entries: 100,
                 max_result_bytes: 250_000,
                 owner: owner,
                 resource_registrar: registrar
               )

      assert :ok = ProviderSession.close(session)
    end

    @tag :tmp_dir
    test "fixtures are confined to the host-config directory", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "host"))
      File.write!(Path.join(dir, "outside.jsonl"), "{}\n")

      assert {:error, :invalid_replay_fixtures} =
               LLMReplay.start(Path.join(dir, "host"), "../outside.jsonl",
                 max_entries: 10,
                 max_result_bytes: 1_000
               )
    end
  end

  describe "installed provider" do
    @tag :tmp_dir
    test "a command replay miss prints the hash needed to author a working fixture", %{
      tmp_dir: dir
    } do
      {:ok, unrelated_hash} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => unrelated_hash, "response" => %{"content" => "unused"}}])

      paths = write_application(dir)
      write_agent_application(paths, ~S|(agent.core/run-value "Return 42" {"max_turns" 1})|)

      assert {:error, %CommandOutcome{} = miss} =
               CommandEngine.dispatch(["run", paths.manifest, "--host-config", paths.host])

      assert miss.envelope["error"]["code"] == "replay_fixture_missing"
      assert CommandContract.valid_envelope?(miss.envelope)
      message = miss.envelope["error"]["message"]

      assert [request_hash] =
               Regex.run(~r/sha256:[0-9a-f]{64}/, message, capture: :first)

      assert message ==
               "no replay fixture matches this request (request_hash: #{request_hash})"

      assert {:stderr, stderr} = CommandRenderer.render(miss)
      assert stderr =~ message

      for invalid_message <- [
            message <> "\nprivate detail",
            String.replace(message, request_hash, String.upcase(request_hash)),
            String.replace(message, "no replay fixture", "provider says")
          ] do
        assert {:error, :invalid_command_diagnostic} =
                 CommandDiagnostic.new(:execution, :replay_fixture_missing,
                   message: invalid_message,
                   source: CommandSource.fixed(:runtime),
                   provider_activity: true
                 )
      end

      write(dir, [
        %{
          "request_hash" => request_hash,
          "response" => %{
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "done",
                "name" => "run_ptc_lisp",
                "args" => %{"program" => "(return 42)"}
              }
            ]
          }
        }
      ])

      assert {:ok, %CommandOutcome{} = replayed} =
               CommandEngine.dispatch(["run", paths.manifest, "--host-config", paths.host])

      assert replayed.envelope["result"]["value"] == 42
    end

    @tag :tmp_dir
    test "agent turn exhaustion names max_turns and its effective value", %{tmp_dir: dir} do
      {:ok, unrelated_hash} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => unrelated_hash, "response" => %{"content" => "unused"}}])

      paths = write_application(dir)
      write_agent_application(paths, ~S|(agent.core/run-value "Return 42" {"max_turns" 2})|)

      assert {:error, %CommandOutcome{} = first_miss} =
               CommandEngine.dispatch(["run", paths.manifest, "--host-config", paths.host])

      first_hash = replay_request_hash(first_miss)

      write(dir, [
        %{"request_hash" => first_hash, "response" => %{"content" => "first prose reply"}}
      ])

      assert {:error, %CommandOutcome{} = second_miss} =
               CommandEngine.dispatch(["run", paths.manifest, "--host-config", paths.host])

      second_hash = replay_request_hash(second_miss)

      write(dir, [
        %{"request_hash" => first_hash, "response" => %{"content" => "first prose reply"}},
        %{"request_hash" => second_hash, "response" => %{"content" => "second prose reply"}}
      ])

      trace_dir = Path.join(dir, "turn-limit-traces")
      File.mkdir_p!(trace_dir)

      assert {:error, %CommandOutcome{} = exhausted} =
               CommandEngine.dispatch([
                 "run",
                 paths.manifest,
                 "--host-config",
                 paths.host,
                 "--trace-dir",
                 trace_dir
               ])

      assert exhausted.envelope["error"]["code"] == "runtime_limit_exceeded",
             inspect(exhausted.envelope)

      assert exhausted.envelope["error"]["message"] ==
               "agent turn limit 2 was exceeded; raise max_turns for this agent.core/run call, or reduce the work per turn"

      assert exhausted.envelope["error"]["source"] == nil
      assert CommandContract.valid_envelope?(exhausted.envelope)

      assert [trace_path] = Path.wildcard(Path.join(trace_dir, "*.jsonl"))

      stopped =
        trace_path
        |> File.stream!()
        |> Stream.map(&Jason.decode!/1)
        |> Enum.find(&(&1["type"] == "run-stopped"))

      assert stopped["data"]["failure_kind"] == "turn-limit"
      assert stopped["data"]["limit"] == "agent_turns"
      assert stopped["data"]["limit_value"] == 2
    end

    @tag :tmp_dir
    test "agent result-contract exhaustion publishes its bounded final diagnosis", %{tmp_dir: dir} do
      {:ok, unrelated_hash} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => unrelated_hash, "response" => %{"content" => "unused"}}])

      paths = write_application(dir)

      write_agent_application(
        paths,
        ~S|(agent.core/run-result-value "Return a sum of at least 100" {"max_turns" 2})|
      )

      result_schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["sum"],
        "properties" => %{"sum" => %{"type" => "integer", "minimum" => 100}}
      }

      schema_path = Path.join(dir, "result.schema.json")
      File.write!(schema_path, Jason.encode!(result_schema))

      manifest = paths.manifest |> File.read!() |> Jason.decode!()

      File.write!(
        paths.manifest,
        manifest
        |> Map.put("contracts", %{"result_schema" => %{"path" => "result.schema.json"}})
        |> Jason.encode!()
      )

      assert {:error, %CommandOutcome{} = first_miss} =
               CommandEngine.dispatch(["run", paths.manifest, "--host-config", paths.host])

      first_hash = replay_request_hash(first_miss)
      first_response = invalid_result_response("first-invalid", 42)
      write(dir, [%{"request_hash" => first_hash, "response" => first_response}])

      assert {:error, %CommandOutcome{} = second_miss} =
               CommandEngine.dispatch(["run", paths.manifest, "--host-config", paths.host])

      second_hash = replay_request_hash(second_miss)

      write(dir, [
        %{"request_hash" => first_hash, "response" => first_response},
        %{
          "request_hash" => second_hash,
          "response" => invalid_result_response("final-invalid", 99)
        }
      ])

      trace_dir = Path.join(dir, "result-contract-traces")
      File.mkdir_p!(trace_dir)

      assert {:error, %CommandOutcome{} = exhausted} =
               CommandEngine.dispatch([
                 "run",
                 paths.manifest,
                 "--host-config",
                 paths.host,
                 "--trace-dir",
                 trace_dir
               ])

      assert exhausted.envelope["error"] == %{
               "code" => "result_contract_failed",
               "message" =>
                 "agent could not satisfy the result contract within 2 turns; last candidate violated minimum",
               "notes" => [],
               "path" => "/sum",
               "phase" => "result_cleanup",
               "provider_activity" => true,
               "retryable" => false,
               "source" => %{"kind" => "result_contract", "name" => "result.schema.json"},
               "span" => nil,
               "subject" => nil
             }

      assert exhausted.envelope["result"] == nil
      assert CommandContract.valid_envelope?(exhausted.envelope)

      {:ok, result_source} = CommandSource.new(:result_contract, "result.schema.json")

      for invalid_message <- [
            "agent could not satisfy the result contract within 0 turns; last candidate violated minimum",
            "agent could not satisfy the result contract within 02 turns; last candidate violated minimum",
            "agent could not satisfy the result contract within 129 turns; last candidate violated minimum",
            "agent could not satisfy the result contract within 2 turns; last candidate violated private-value"
          ] do
        assert {:error, :invalid_command_diagnostic} =
                 CommandDiagnostic.new(:result_cleanup, :result_contract_failed,
                   message: invalid_message,
                   source: result_source,
                   provider_activity: true
                 )

        refute CommandContract.valid_envelope?(
                 put_in(exhausted.envelope, ["error", "message"], invalid_message)
               )
      end

      assert [trace_path] = Path.wildcard(Path.join(trace_dir, "*.jsonl"))
      trace = File.read!(trace_path)
      refute trace =~ "candidate-secret"

      stopped =
        trace
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["type"] == "run-stopped"))

      assert stopped["data"]["failure_kind"] == "result-contract"
      assert stopped["data"]["agent_turns"] == 2
      assert stopped["data"]["constraint"] == "minimum"
    end

    @tag :tmp_dir
    test "parallel replay misses retain the authoring hash", %{tmp_dir: dir} do
      {:ok, unrelated_hash} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => unrelated_hash, "response" => %{"content" => "unused"}}])
      paths = write_application(dir)

      for {parallel, expression} <- [
            {:pmap, ~S|(pmap (fn [_] (agent.core/run-value "Return 42" {"max_turns" 1})) [1])|},
            {:pcalls, ~S|(pcalls #(agent.core/run-value "Return 42" {"max_turns" 1}))|}
          ] do
        write_agent_application(paths, expression)

        assert {:error, %CommandOutcome{} = miss} =
                 CommandEngine.dispatch(["run", paths.manifest, "--host-config", paths.host])

        assert miss.envelope["error"]["code"] == "replay_fixture_missing",
               "#{parallel} discarded the replay-miss hash"

        assert miss.envelope["error"]["message"] =~ ~r/request_hash: sha256:[0-9a-f]{64}/

        trace_path = Path.join(dir, "#{parallel}.trace.jsonl")
        {:ok, registry} = replay_registry(paths.host)

        assert {:error, %{reason: reason}} =
                 paths.manifest
                 |> ApplicationPackage.request_directory(
                   installed_limits: registry.installed_limits
                 )
                 |> RunLifecycle.build(registry, trace_path: trace_path)
                 |> RunLifecycle.execute()

        assert reason == if(parallel == :pmap, do: :pmap_error, else: :pcalls_error)

        stopped =
          trace_path
          |> File.stream!()
          |> Stream.map(&Jason.decode!/1)
          |> Enum.find(&(&1["type"] == "run-stopped"))

        assert stopped["data"]["failure_kind"] == "llm-provider-error"
      end
    end

    @tag :tmp_dir
    test "direct replay misses retain the authoring hash", %{tmp_dir: dir} do
      {:ok, unrelated_hash} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => unrelated_hash, "response" => %{"content" => "unused"}}])
      paths = write_application(dir)

      request =
        ~S|{"system" "different" "messages" [{"role" "user" "content" "missing"}]}|

      for {style, expression} <- [
            {:raw, ~s|(let [response (llm/request #{request})]
                  (if (= :error (get response :status))
                    (fail response)
                    (return response)))|},
            {:documented_wrapper, ~s|(let [response (tool/llm-request #{request})]
                  (if (= :error (get response :status))
                    (fail {"kind" "llm-provider-error" "provider_response" response})
                    (return (get response :value))))|},
            {:parallel_raw, ~s|(pmap
                  (fn [_]
                    (let [response (llm/request #{request})]
                      (if (= :error (get response :status))
                        (fail response)
                        response)))
                  [1])|}
          ] do
        File.write!(
          Path.join(dir, "w.clj"),
          "(ns app)\n(defn run [_input]\n  #{expression})\n"
        )

        assert {:error, %CommandOutcome{} = miss} =
                 CommandEngine.dispatch(["run", paths.manifest, "--host-config", paths.host])

        assert miss.envelope["error"]["code"] == "replay_fixture_missing",
               "#{style} discarded the replay-miss hash"

        assert miss.envelope["error"]["message"] =~ ~r/request_hash: sha256:[0-9a-f]{64}/
      end
    end

    @tag :tmp_dir
    test "a private replay miss keeps its request hash out of public diagnostics", %{tmp_dir: dir} do
      {:ok, unrelated_hash} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => unrelated_hash, "response" => %{"content" => "unused"}}])
      paths = write_application(dir)
      private_input = Path.join(dir, "private-input.json")
      inspection = Path.join(dir, "private-run.inspection.jsonl")
      secret = "PRIVATE_REPLAY_PROMPT"

      File.write!(private_input, Jason.encode!(%{"secret" => secret}))

      write_agent_application(
        paths,
        ~S|(agent.core/run-value (get input "secret") {"max_turns" 1})|
      )

      host = paths.host |> File.read!() |> Jason.decode!()

      host =
        put_in(host, ["install", "replay-llm", "accepts_data"], ["normal", "private_inspection"])

      File.write!(paths.host, Jason.encode!(host))

      assert {:error, %CommandOutcome{} = miss} =
               CommandEngine.dispatch([
                 "run",
                 paths.manifest,
                 "--host-config",
                 paths.host,
                 "--private-input",
                 Path.basename(private_input),
                 "--inspect",
                 inspection
               ])

      assert miss.envelope["artifact_class"] == "private", inspect(miss.envelope)
      assert miss.envelope["error"]["code"] == "workflow_failed"
      refute Jason.encode!(miss.envelope) =~ ~r/sha256:[0-9a-f]{64}/
      refute Jason.encode!(miss.envelope) =~ secret

      assert {:stderr, stderr} = CommandRenderer.render(miss)
      refute stderr =~ ~r/sha256:[0-9a-f]{64}/
      refute stderr =~ secret

      private_records = File.read!(inspection)
      assert private_records =~ ~r/request_hash: sha256:[0-9a-f]{64}/
      assert private_records =~ secret
    end

    @tag :tmp_dir
    test "a replay-backed run reaches the same llm-request capability as a live one", %{
      tmp_dir: dir
    } do
      {:ok, key} = LLMReplay.request_hash(@request)

      write(dir, [
        %{"request_hash" => key, "responses" => [%{"content" => "a"}, %{"content" => "b"}]}
      ])

      paths = write_application(dir)
      {:ok, host} = HostConfig.load(paths.host)

      {:ok, registry} =
        HostInstallation.catalog(host)
        |> then(fn {:ok, catalog} ->
          HostInstallation.runtime_registry(host, catalog)
        end)

      assert {:ok, result} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: registry.installed_limits
               )
               |> RunLifecycle.build(registry)
               |> RunLifecycle.execute()

      assert result.value == %{"first" => %{"content" => "a"}, "second" => %{"content" => "b"}}
    end

    @tag :tmp_dir
    test "a run explicitly routes between two installed replay aliases", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)

      File.write!(
        Path.join(dir, "replay.jsonl"),
        Jason.encode!(%{
          "schema_version" => 1,
          "request_hash" => key,
          "response" => %{"content" => "first"}
        }) <>
          "\n"
      )

      File.write!(
        Path.join(dir, "second.jsonl"),
        Jason.encode!(%{
          "schema_version" => 1,
          "request_hash" => key,
          "response" => %{"content" => "second"}
        }) <>
          "\n"
      )

      paths = write_application(dir)
      host = paths.host |> File.read!() |> Jason.decode!()
      second = host["install"]["replay-llm"] |> Map.put("fixtures", "second.jsonl")
      host = put_in(host, ["install", "second-replay"], second)
      File.write!(paths.host, Jason.encode!(host))

      manifest = paths.manifest |> File.read!() |> Jason.decode!()

      manifest =
        put_in(manifest, ["providers", "workflow"], [
          %{"name" => "replay-llm"},
          %{"name" => "second-replay"}
        ])

      File.write!(paths.manifest, Jason.encode!(manifest))

      File.write!(
        Path.join(dir, "w.clj"),
        ~S|(ns app)
        (defn run [_i]
          (return
            (llm/request
              {"model" "second-replay"
               "system" "bounded"
               "messages" [{"role" "user" "content" "hi"}]})))|
      )

      assert {:ok, host} = HostConfig.load(paths.host)
      assert {:ok, catalog} = HostInstallation.catalog(host)
      assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

      assert {:ok, result} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: registry.installed_limits
               )
               |> RunLifecycle.build(registry)
               |> RunLifecycle.execute()

      assert result.value == %{"content" => "second"}
    end

    @tag :tmp_dir
    test "a sealed replay declaration is accepted by the runtime provider path", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"content" => "a"}}])

      paths = write_application(dir)
      assert {:ok, host} = HostConfig.load(paths.host)
      assert {:ok, catalog} = HostInstallation.catalog(host)

      assert {:ok, request} =
               ApplicationPackage.request_directory(paths.manifest,
                 installed_limits: catalog.installed_limits
               )

      assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)

      assert get_in(prepared.provider_declarations, [Access.at(0), :config, "max_entries"]) == 100

      assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

      [declaration] = prepared.provider_declarations

      context = %{
        application_content_digest: prepared.request.package.application_content_digest,
        destination: declaration.destination,
        owner: self(),
        limits: prepared.request.package.limits,
        installed_limits: prepared.request.package.installed_limits
      }

      assert {:ok, provider_preparation} =
               ProviderRegistry.prepare(
                 registry,
                 declaration.name,
                 declaration.config,
                 context
               )

      assert provider_preparation.credential_names == []
      assert :ok = PreparedRun.close(prepared)
      assert :ok = ProviderRegistry.close(registry)
    end

    @tag :tmp_dir
    test "a run may select both a live and a replay LLM while providers are inert", %{
      tmp_dir: dir
    } do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"content" => "a"}}])

      # A fixture path that does not exist and a credential that is never set
      # prove that preparation is entirely inert.
      paths = write_application(dir, both_llms: true, fixtures: "missing.jsonl")
      {:ok, host} = HostConfig.load(paths.host)

      assert {:ok, catalog} = HostInstallation.catalog(host)

      assert {:ok, request} =
               ApplicationPackage.request_directory(paths.manifest,
                 installed_limits: catalog.installed_limits
               )

      assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
      assert Enum.map(prepared.provider_declarations, & &1.name) == ["replay-llm", "live-llm"]
      assert :ok = PreparedRun.close(prepared)
    end

    @tag :tmp_dir
    test "two declared workflow LLM defaults fail while providers are inert", %{tmp_dir: dir} do
      paths =
        write_application(dir,
          both_llms: true,
          fixtures: "missing.jsonl",
          selection: %{"default" => true},
          live_selection: %{"default" => true}
        )

      assert {:ok, host} = HostConfig.load(paths.host)
      assert {:ok, catalog} = HostInstallation.catalog(host)

      assert {:ok, request} =
               ApplicationPackage.request_directory(paths.manifest,
                 installed_limits: catalog.installed_limits
               )

      assert {:error, diagnostic} = RunCoordinator.prepare(request, catalog)
      assert diagnostic.phase == :provider_declaration
      assert diagnostic.code == :dependency_invalid
    end

    @tag :tmp_dir
    test "a replay alias cannot be selected into mission", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"content" => "a"}}])

      paths = write_application(dir, destination: "mission")
      {:ok, host} = HostConfig.load(paths.host)

      {:ok, registry} =
        HostInstallation.catalog(host)
        |> then(fn {:ok, catalog} ->
          HostInstallation.runtime_registry(host, catalog)
        end)

      assert {:error, :provider_destination_denied} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: registry.installed_limits
               )
               |> RunLifecycle.build(registry)
               |> RunLifecycle.execute()
    end

    @tag :tmp_dir
    test "a manifest may lower the result ceiling but not raise it", %{tmp_dir: dir} do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"content" => "a"}}])

      paths = write_application(dir, selection: %{"max_result_bytes" => 500_000})
      {:ok, host} = HostConfig.load(paths.host)

      {:ok, registry} =
        HostInstallation.catalog(host)
        |> then(fn {:ok, catalog} ->
          HostInstallation.runtime_registry(host, catalog)
        end)

      assert {:error, :invalid_llm_replay_selection} =
               paths.manifest
               |> ApplicationPackage.request_directory(
                 installed_limits: registry.installed_limits
               )
               |> RunLifecycle.build(registry)
               |> RunLifecycle.execute()
    end
  end

  defp start(dir, opts \\ []), do: LLMReplay.start(dir, "replay.jsonl", opts(opts))

  defp opts(opts) do
    [
      max_entries: Keyword.get(opts, :max_entries, 100),
      max_result_bytes: Keyword.get(opts, :max_result_bytes, 250_000)
    ]
    |> then(fn base ->
      case Keyword.get(opts, :owner) do
        nil -> base
        owner -> Keyword.put(base, :owner, owner)
      end
    end)
  end

  defp write(dir, entries) do
    File.write!(
      Path.join(dir, "replay.jsonl"),
      Enum.map_join(entries, "\n", &Jason.encode!(Map.put_new(&1, "schema_version", 1))) <>
        "\n"
    )
  end

  defp replay_request_hash(%CommandOutcome{} = outcome) do
    assert outcome.envelope["error"]["code"] == "replay_fixture_missing"

    assert [request_hash] =
             Regex.run(~r/sha256:[0-9a-f]{64}/, outcome.envelope["error"]["message"],
               capture: :first
             )

    request_hash
  end

  defp invalid_result_response(id, sum) do
    %{
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => id,
          "name" => "run_ptc_lisp",
          "args" => %{
            "program" => ~s|(return {"sum" #{sum} "secret" "candidate-secret"})|
          }
        }
      ]
    }
  end

  defp write_application(dir, opts \\ []) do
    destination = Keyword.get(opts, :destination, "workflow")
    fixtures = Keyword.get(opts, :fixtures, "replay.jsonl")

    File.write!(
      Path.join(dir, "w.clj"),
      ~S|(ns app)
      (defn run [_i]
        (let [req {"system" "bounded" "messages" [{"role" "user" "content" "hi"}]}]
          (return {"first" (llm/request req) "second" (llm/request req)})))|
    )

    replay =
      %{
        "source" => "llm_replay",
        "installation_revision" => Keyword.get(opts, :installation_revision, "replay-v1"),
        "fixtures" => fixtures,
        "ceilings" => %{"max_entries" => 100, "max_result_bytes" => 250_000}
      }

    install =
      if Keyword.get(opts, :both_llms, false) do
        %{
          "replay-llm" => replay,
          "live-llm" => %{
            "source" => "llm",
            "installation_revision" => "live-v1",
            "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
            "credential" => "key"
          }
        }
      else
        %{"replay-llm" => replay}
      end

    host =
      %{"install" => install}
      |> then(fn document ->
        if Keyword.get(opts, :both_llms, false),
          do: Map.put(document, "credentials", %{"key" => %{"env" => "PTC_TEST_ABSENT_KEY"}}),
          else: document
      end)

    selection = Keyword.get(opts, :selection)

    spec =
      if selection,
        do: %{"name" => "replay-llm", "config" => selection},
        else: %{"name" => "replay-llm"}

    providers =
      if Keyword.get(opts, :both_llms, false) do
        live_spec =
          case Keyword.get(opts, :live_selection) do
            nil -> %{"name" => "live-llm"}
            config -> %{"name" => "live-llm", "config" => config}
          end

        %{"workflow" => [spec, live_spec]}
      else
        %{destination => [spec]}
      end

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [
          %{"library" => "llm"},
          %{"id" => "app", "path" => "w.clj", "dependencies" => ["llm"]}
        ],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => providers,
      "limits" => %{"run_duration_ms" => 30_000}
    }

    manifest_path = Path.join(dir, "ptc.json")
    host_path = Path.join(dir, "ptc-host.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    File.write!(host_path, Jason.encode!(host))
    %{manifest: manifest_path, host: host_path}
  end

  defp write_agent_application(paths, expression) do
    File.write!(
      Path.join(Path.dirname(paths.manifest), "w.clj"),
      """
      (ns app)
      (defn run [input]
        (return #{expression}))
      """
    )

    manifest = paths.manifest |> File.read!() |> Jason.decode!()

    manifest =
      put_in(manifest, ["workflow", "components"], [
        %{"library" => "agent.core"},
        %{"id" => "app", "path" => "w.clj", "dependencies" => ["agent.core"]}
      ])
      |> Map.put("missions", %{"default" => %{"components" => []}})

    File.write!(paths.manifest, Jason.encode!(manifest))
  end

  defp replay_registry(host_path) do
    with {:ok, host} <- HostConfig.load(host_path),
         {:ok, catalog} <- HostInstallation.catalog(host) do
      HostInstallation.runtime_registry(host, catalog)
    end
  end
end
