defmodule PtcRunner.Kernel.LLMReplayTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers the `llm_replay` host source: fixture decoding, bounds, identity, and
  owner lifecycle.

  These fixtures prove the runtime. The application fixture set that an
  evaluation recipe actually replays is `repo-analyst/evaluation/replay.jsonl`
  and belongs to the evaluator issue.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator

  @request %{"system" => "bounded", "messages" => [%{"role" => "user", "content" => "hi"}]}

  describe "fixture decoding" do
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

      assert {:error, %ProviderError{kind: :not_found, retryable?: false} = error} =
               LLMReplay.requester(replay).(%{"system" => "different", "messages" => []})

      assert error.details =~ "no replay fixture"
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

      assert {:ok, result} = RunBuilder.run(paths.manifest, registry)
      assert result.value == %{"first" => %{"content" => "a"}, "second" => %{"content" => "b"}}
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
    test "a run selecting both a live and a replay LLM fails before provider activity", %{
      tmp_dir: dir
    } do
      {:ok, key} = LLMReplay.request_hash(@request)
      write(dir, [%{"request_hash" => key, "response" => %{"content" => "a"}}])

      # A fixture path that does not exist and a credential that is never set:
      # if either provider were activated, the failure would name one of those
      # instead of the ambiguity.
      paths = write_application(dir, both_llms: true, fixtures: "missing.jsonl")
      {:ok, host} = HostConfig.load(paths.host)

      {:ok, registry} =
        HostInstallation.catalog(host)
        |> then(fn {:ok, catalog} ->
          HostInstallation.runtime_registry(host, catalog)
        end)

      assert {:error, :ambiguous_workflow_llm} = RunBuilder.run(paths.manifest, registry)
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

      assert {:error, :provider_destination_denied} = RunBuilder.run(paths.manifest, registry)
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

      assert {:error, :invalid_llm_replay_selection} = RunBuilder.run(paths.manifest, registry)
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
      Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n"
    )
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
            "model" => "openrouter:deepseek/deepseek-v4-flash",
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
      if Keyword.get(opts, :both_llms, false),
        do: %{"workflow" => [spec, %{"name" => "live-llm"}]},
        else: %{destination => [spec]}

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
end
