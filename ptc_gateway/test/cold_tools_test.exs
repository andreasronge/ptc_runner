defmodule PtcGateway.ColdToolsTest do
  use ExUnit.Case, async: false
  import PtcGateway.TestSupport.GatewayFixture
  alias PtcGateway.PinDiscovery

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  @tag :tmp_dir
  test "cold analysis eval captures later traces independently", %{tmp_dir: dir} do
    {path, config} = deployment(dir)
    {:ok, host} = PtcRunner.Kernel.HostConfig.load(Path.join(dir, "host.json"))
    {:ok, catalog} = PtcRunner.Kernel.HostInstallation.catalog(host)
    on_exit(fn -> PtcRunner.Kernel.InstallationCatalog.close(catalog) end)

    assert {:ok, _} =
             PtcRunner.Kernel.ServingTemplate.from_directory(
               Path.join(dir, "app.json"),
               host.limits,
               providers: catalog
             )

    assert {:ok, pins} = PinDiscovery.discover(path)
    assert pins["a"]["provider_snapshot_pins"] == %{}
    assert Map.keys(pins["a"]["installation_config_pins"]) == ["history"]
    config = pin(path, config, pins)
    assert {:ok, gateway} = PtcGateway.start_link(path)
    on_exit(fn -> stop(gateway) end)
    assert :sys.get_state(:sys.get_state(gateway).warm).runtimes == %{}
    assert call(config, ~S|(return (count (get (history/runs {}) "items")))|) == "0"
    write_trace(dir, "later")
    assert call(config, ~S|(return (count (get (history/runs {}) "items")))|) == "1"

    assert call(
             config,
             ~S|(return (str (history/read {"run_id" "later" "collection" "activity"})))|
           ) =~ "snapshot_hash"

    assert call(config, ~S|(return (str (history/counters {"run_id" "later"})))|) =~
             "snapshot_hash"

    assert call(config, "", "z") =~ "history/runs"
    File.rm!(Path.join([dir, "traces", "later.jsonl"]))
    write_trace(dir, "changed")
    assert call(config, ~S|(return (count (get (history/runs {}) "items")))|) == "1"

    assert Path.wildcard(Path.join([dir, "debug-artifacts", "traces", "*.jsonl"])) != []

    :erlang.trace_pattern(
      {PtcRunner.Kernel.TraceSnapshot, :start, 2},
      [{:_, [], [{:return_trace}]}],
      []
    )

    :erlang.trace(:new, true, [:call])

    try do
      tasks =
        for _ <- 1..4,
            do:
              Task.async(fn ->
                call(
                  config,
                  ~S|(return (get-in (history/open {"run_id" "changed"}) ["run" "snapshot_hash"]))|
                )
              end)

      for task <- tasks, do: assert("sha256:" <> _ = Task.await(task))

      captures =
        for _ <- tasks do
          assert_receive {:trace, _, :return_from, {PtcRunner.Kernel.TraceSnapshot, :start, 2},
                          {:ok, snapshot}},
                         5000

          snapshot.pid
        end

      assert length(Enum.uniq(captures)) == 4
      assert Enum.all?(captures, &(not Process.alive?(&1)))
    after
      :erlang.trace(:new, false, [:call])
      :erlang.trace_pattern({PtcRunner.Kernel.TraceSnapshot, :start, 2}, false, [])
    end
  end

  @tag :tmp_dir
  test "startup checks installation pins and the directory before binding", %{tmp_dir: dir} do
    {path, config} = deployment(dir)
    assert {:ok, pins} = PinDiscovery.discover(path)
    config = pin(path, config, pins)

    for invalid <- [%{}, %{"history" => "sha256:" <> String.duplicate("0", 64)}] do
      broken =
        update_in(
          config["tools"],
          &Enum.map(&1, fn tool -> Map.put(tool, "installation_config_pins", invalid) end)
        )

      File.write!(path, Jason.encode!(broken))
      assert {:error, :installation_pin_mismatch} = PtcGateway.start_link(path)
      assert_unbound(config)
    end

    broken =
      update_in(
        config["tools"],
        &Enum.map(&1, fn tool ->
          Map.put(tool, "provider_snapshot_pins", %{
            "mission/history" => "sha256:" <> String.duplicate("0", 64)
          })
        end)
      )

    File.write!(path, Jason.encode!(broken))
    assert {:error, :provider_pin_mismatch} = PtcGateway.start_link(path)
    assert_unbound(config)
    File.write!(path, Jason.encode!(config))
    File.rmdir!(Path.join(dir, "traces"))
    assert {:error, _} = PtcGateway.start_link(path)
    assert_unbound(config)
  end

  @tag :tmp_dir
  test "private and mixed snapshot selections are refused without acquisition", %{tmp_dir: dir} do
    {path, config} = deployment(dir)
    host_path = Path.join(dir, "host.json")
    host = Jason.decode!(File.read!(host_path))

    for source <- ["ptc_private_trace_snapshot", "ptc_inspection_snapshot"] do
      private = put_in(host, ["install", "history", "source"], source)
      private = put_in(private, ["install", "history", "directory"], "missing")
      File.write!(host_path, Jason.encode!(private))
      assert {:error, :provider_source_unsupported} = PinDiscovery.discover(path)
      assert {:error, :provider_source_unsupported} = PtcGateway.start_link(path)
    end

    manifest_path = Path.join(dir, "app.json")
    manifest = Jason.decode!(File.read!(manifest_path))

    mixed =
      put_in(manifest, ["providers", "mission"], [%{"name" => "history"}, %{"name" => "remote"}])

    mixed = put_in(mixed, ["missions", "default", "providers"], ["history", "remote"])
    File.write!(manifest_path, Jason.encode!(mixed))
    File.write!(path, Jason.encode!(content_pins(dir, config)))

    remote = %{
      "source" => "mcp",
      "installation_revision" => "v1",
      "transport" => %{"type" => "streamable_http", "endpoint" => "https://127.0.0.1:1/mcp"},
      "tools" => %{"echo" => %{"as" => "remote.echo", "effect" => "read"}}
    }

    File.write!(host_path, Jason.encode!(put_in(host, ["install", "remote"], remote)))
    assert {:error, :provider_source_unsupported} = PinDiscovery.discover(path)
    assert {:error, :provider_source_unsupported} = PtcGateway.start_link(path)
  end

  defp assert_unbound(config) do
    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, config["listen"]["port"], [], 1000)
  end

  defp deployment(dir) do
    {path, config} = fixture(dir)
    File.mkdir!(Path.join(dir, "traces"))
    File.write!(Path.join(dir, "gateway.key"), token())

    File.write!(
      Path.join(dir, "host.json"),
      Jason.encode!(%{
        "credentials" => %{"gateway" => %{"file" => "gateway.key"}},
        "install" => %{
          "history" => %{
            "source" => "ptc_trace_snapshot",
            "installation_revision" => "v1",
            "directory" => "traces"
          }
        }
      })
    )

    File.write!(
      Path.join(dir, "input.json"),
      Jason.encode!(%{
        "type" => "object",
        "properties" => %{"source" => %{"type" => "string"}},
        "required" => ["source"]
      })
    )

    File.write!(
      Path.join(dir, "result.json"),
      Jason.encode!(%{"type" => "object", "properties" => %{"value" => %{"type" => "string"}}})
    )

    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run {:effect :read} [input] (return {"value" (str (get (kernel/eval-source "default" (get input "source")) :value))}))|
    )

    File.write!(Path.join(dir, "history.clj"), ~S|(ns history {:visibility :prompt})
(defn- unwrap {:effect :read} [response]
  (if (= :ok (get response :status)) (get response :value) (fail response)))
(defn runs {:effect :read} [args] (unwrap (tool/history.runs args)))
(defn open {:effect :read} [args] (unwrap (tool/history.open args)))
(defn read {:effect :read} [args] (unwrap (tool/history.read args)))
(defn counters {:effect :read} [args] (unwrap (tool/history.counters args)))|)

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "entry" => "app/run",
        "components" => [
          %{"id" => "app", "path" => "workflow.clj", "dependencies" => ["kernel"]},
          %{"library" => "kernel"}
        ]
      },
      "input" => %{"value" => %{}},
      "missions" => %{
        "default" => %{
          "components" => [%{"id" => "history", "path" => "history.clj"}],
          "providers" => ["history"]
        }
      },
      "providers" => %{"mission" => [%{"name" => "history"}]},
      "contracts" => %{
        "input_schema" => %{"path" => "input.json"},
        "result_schema" => %{"path" => "result.json"}
      }
    }

    File.write!(Path.join(dir, "app.json"), Jason.encode!(manifest))
    api = put_in(manifest, ["workflow", "components", Access.at(0), "path"], "api.clj")
    File.write!(Path.join(dir, "api.json"), Jason.encode!(api))

    File.write!(
      Path.join(dir, "api.clj"),
      ~S|(ns app) (defn run {:effect :read} [input] (return {"value" (str (kernel/mission-inventory "default"))}))|
    )

    config =
      update_in(
        config["tools"],
        &Enum.map(&1, fn tool ->
          if tool["name"] == "z",
            do: put_in(tool, ["application", "manifest"], "api.json"),
            else: tool
        end)
      )

    config = content_pins(dir, config)
    config = Map.put(config, "artifacts", %{"root" => "debug-artifacts", "trace" => true})
    File.write!(path, Jason.encode!(config))
    {path, config}
  end

  defp content_pins(dir, config) do
    update_in(
      config["tools"],
      &Enum.map(&1, fn tool ->
        {:ok, package, _} =
          PtcRunner.Kernel.ApplicationPackage.acquire_directory(
            Path.join(dir, tool["application"]["manifest"]),
            omit_input: true
          )

        Map.put(
          tool,
          "expected_application_content_digest",
          "sha256:" <> package.application_content_digest
        )
      end)
    )
  end

  defp pin(path, config, pins) do
    config =
      update_in(
        config["tools"],
        &Enum.map(&1, fn tool -> Map.merge(tool, pins[tool["name"]]) end)
      )

    File.write!(path, Jason.encode!(config))
    config
  end

  defp call(config, source, name \\ "a") do
    response =
      mcp(config, "tools/call", 1,
        params: %{"name" => name, "arguments" => %{"source" => source}},
        headers: [{"mcp-name", name}]
      )

    body =
      if is_binary(response.body) do
        [_, event, ""] = String.split(response.body, "\n\n")
        ["event: message", "data: " <> payload] = String.split(event, "\n")
        Jason.decode!(payload)
      else
        response.body
      end

    assert body["result"]["isError"] != true, inspect(body)
    body["result"]["structuredContent"]["value"]
  end

  defp write_trace(dir, id) do
    events =
      for {type, seq} <- [{"run-started", 1}, {"run-stopped", 2}] do
        %{
          "schema_version" => 2,
          "run_id" => id,
          "trace_id" => "trace-#{id}",
          "sequence" => seq,
          "timestamp" => "2026-07-19T12:00:00Z",
          "type" => type,
          "data" =>
            if(seq == 1,
              do: %{"missions" => %{}},
              else: %{
                "outcome" => "ok",
                "usage" => %{"llm_budget" => %{"total_tokens" => nil, "cost" => nil}}
              }
            )
        }
      end

    File.write!(
      Path.join([dir, "traces", id <> ".jsonl"]),
      Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    )
  end
end
