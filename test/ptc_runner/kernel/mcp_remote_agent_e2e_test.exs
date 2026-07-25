defmodule PtcRunner.Kernel.MCPRemoteAgentE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Full agent flow against real providers: a live model (default `deepseek`)
  plans a PTC-Lisp program that calls the configured modern MCP endpoint from
  the mission environment through a manifest run. CI uses the same pinned
  official Go SDK-backed stateless `cityTime` harness as
  `MCPRemoteE2ETest`. The written `--trace`/`--inspect` artifacts are audited
  for endpoint-host and transport field-name absence; exact credential
  exclusion from retained capability closures is proven by the deterministic
  loopback fixture in `mcp_source_test.exs`.
  """

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  setup_all do
    :ok = PtcRunner.Dotenv.load()
    :ok
  end

  @tag :tmp_dir
  test "a live model drives a remote MCP tool through a manifest run", %{tmp_dir: dir} do
    endpoint = System.fetch_env!("PTC_TEST_MCP_2026_ENDPOINT")
    model = System.get_env("PTC_TEST_MODEL", "deepseek")

    builder =
      MCPSource.builder(
        endpoint: endpoint,
        allow_insecure_loopback: true,
        tools: %{"cityTime" => %{as: "time.city", effect: :read}},
        timeout_ms: 8_000,
        max_result_bytes: 500_000
      )

    {:ok, registry} = ProviderRegistry.new(%{"remote-time" => builder})

    File.write!(Path.join(dir, "agent.clj"), ~S"""
    (ns e2e.agent "Remote MCP e2e entry." {:visibility :prompt})

    (defn run [input]
      (agent.core/run (get input "task") {"max_turns" 3}))
    """)

    # Bare capabilities carry no invocation syntax in the frozen inventory,
    # and live models reliably invent wrong call forms for `tool/NAME`. The
    # supported agent pattern is a prompt-visible mission wrapper whose
    # export advertises its exact call shape, mirroring the kernel tutorial
    # and inspection-lab wrapper journeys.
    File.write!(Path.join(dir, "mission.clj"), ~S"""
    (ns e2e.tools "Remote time lookups." {:visibility :prompt})

    (defn city-time [city]
      (tool/time.city {"city" city}))
    """)

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [
          %{"id" => "e2e.agent", "path" => "agent.clj", "dependencies" => ["agent.core"]},
          %{"library" => "agent.core"}
        ],
        "entry" => "e2e.agent/run"
      },
      "mission" => %{
        "components" => [%{"id" => "e2e.tools", "path" => "mission.clj"}],
        "data" => %{}
      },
      "input" => %{
        "value" => %{
          "task" =>
            ~S[Call (e2e.tools/city-time "nyc") exactly once and return its unchanged result.]
        }
      },
      "providers" => %{
        "workflow" => [%{"name" => "llm", "config" => %{"model" => model}}],
        "mission" => [
          %{
            "name" => "remote-time",
            "config" => %{"allow" => ["time.city"], "timeout_ms" => 8_000}
          }
        ]
      },
      "limits" => %{"evaluation_timeout_ms" => 10_000, "run_duration_ms" => 60_000},
      "labels" => %{"name" => "mcp-agent-e2e", "tags" => %{"mode" => "agent"}}
    }

    manifest_path = Path.join(dir, "ptc.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    trace_path = Path.join(dir, "run.jsonl")
    inspection_path = Path.join(dir, "run.inspection.jsonl")

    assert {:ok, result} =
             RunBuilder.run(manifest_path, registry,
               trace: trace_path,
               inspect: inspection_path
             )

    encoded_value = Jason.encode!(result.value)
    assert encoded_value =~ "current time in New York City"

    # The canonical success path must be present, and the run must be clean:
    # no protocol errors and no failed instrumentation calls — the shipped
    # agent-action annotation is accepted vocabulary.
    assert result.usage.protocol_errors == 0

    events = trace_path |> File.stream!() |> Enum.map(&Jason.decode!/1)

    refute Enum.any?(events, fn event ->
             event["type"] == "capability-stopped" and
               event["data"]["name"] == "workflow-annotate" and
               event["data"]["status"] != "ok"
           end)

    assert Enum.any?(events, fn event ->
             event["type"] == "workflow-annotation" and
               event["data"]["annotation_type"] == "agent-action"
           end)

    assert Enum.any?(events, fn event ->
             event["type"] == "capability-stopped" and
               event["data"]["name"] == "time.city" and
               event["data"]["environment"] == "mission" and
               event["data"]["status"] == "ok"
           end)

    assert Enum.any?(events, fn event ->
             event["type"] == "evaluation-stopped" and
               event["data"]["environment"] == "mission" and
               event["data"]["status"] == "returned"
           end)

    assert Enum.any?(events, fn event ->
             event["type"] == "run-stopped" and event["data"]["outcome"] == "ok"
           end)

    # Scrub audit: endpoint host and transport field names never enter the
    # artifacts. Upstream tool names stay behind the public mapping.
    endpoint_host = URI.parse(endpoint).host
    trace = File.read!(trace_path)
    assert trace =~ "snapshot_hash"
    refute trace =~ endpoint_host
    refute trace =~ "cityTime"
    refute trace =~ ~r/authorization/i
    refute trace =~ "mcp-session"

    inspection = File.read!(inspection_path)
    assert inspection =~ "time.city"
    refute inspection =~ endpoint_host
    refute inspection =~ "mcp-session"

    {:ok, records} = InspectionArtifact.load(inspection_path)

    assert Enum.any?(records, fn record ->
             record["record_type"] == "capability-input" and
               record["payload"]["name"] == "time.city" and
               get_in(record, ["payload", "arguments", "city"]) == "nyc"
           end)

    assert Enum.any?(records, fn record ->
             record["record_type"] == "evaluation-source" and
               record["payload"]["source"] =~ "city-time"
           end)
  end
end
