defmodule PtcRunner.Kernel.MCPRemoteE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises the read-only MCP Streamable HTTP source against a real
  2026-07-28 server selected with `PTC_TEST_MCP_2026_ENDPOINT`.

  The interoperability baseline is the checked-in
  `test/support/mcp_go_stateless` harness. Its Go module pins the official SDK
  release `v1.7.0`, explicitly configures `StreamableHTTPOptions{Stateless:
  true}`, and exposes the `cityTime` tool.
  Unlike the loopback fixture, this covers an independently maintained
  protocol implementation and real SDK schemas. Public credential-free
  servers speaking a sessionful revision are intentionally not fallback
  targets.
  """

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "a live stateless MCP server crosses the bounded Kernel capability boundary" do
    endpoint = System.fetch_env!("PTC_TEST_MCP_2026_ENDPOINT")

    builder =
      MCPSource.builder(
        transport: {:streamable_http, endpoint: endpoint, allow_insecure_loopback: true},
        tools: %{"cityTime" => %{as: "time.city", effect: :read}},
        timeout_ms: 30_000,
        max_result_bytes: 500_000
      )

    {:ok, registry} = ProviderRegistry.new(%{"remote-docs" => builder})

    {:ok, limits} =
      Limits.new(
        run_duration_ms: 90_000,
        workflow_timeout_ms: 90_000,
        evaluation_timeout_ms: 30_000,
        live_provider_tasks: 1
      )

    {:ok, %{capabilities: [capability], snapshot: snapshot, close: close}} =
      ProviderRegistry.build(
        registry,
        "remote-docs",
        %{"allow" => ["time.city"]},
        %{
          application_content_digest: String.duplicate("0", 64),
          destination: :mission,
          limits: limits,
          installed_limits: limits,
          owner: self()
        }
      )

    if is_function(close, 0), do: on_exit(close)

    snapshot = snapshot |> Jason.encode!() |> Jason.decode!()
    assert snapshot["provider"] == "remote-docs"
    assert snapshot["protocol"] == "mcp-2026-07-28"
    assert snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert [%{"name" => "time.city", "effect" => "read"} = tool] = snapshot["tools"]
    assert tool["input_schema_hash"] =~ ~r/\A[0-9a-f]{64}\z/

    encoded_snapshot = Jason.encode!(snapshot)
    refute encoded_snapshot =~ URI.parse(endpoint).host
    refute encoded_snapshot =~ "cityTime"

    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new(capabilities: [capability])
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mcp-remote-e2e")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source =
      ~S|(return (tool/kernel-eval {"kind" :source "source" "(return (pmap (fn [city] (tool/time.city {\"city\" city \"delay_ms\" 100})) [\"nyc\" \"sf\" \"boston\" \"nyc\"]))"}))|

    assert {:ok,
            %{
              value: %{
                "status" => "ok",
                "value" => %{"outcome" => "returned", "value" => values}
              }
            }} =
             Kernel.run(source, config)

    assert 4 == length(values)

    assert Enum.all?(values, fn
             %{"status" => "ok", "value" => %{"text" => [entry | _]}} ->
               is_binary(entry) and entry != ""

             _other ->
               false
           end)
  end
end
