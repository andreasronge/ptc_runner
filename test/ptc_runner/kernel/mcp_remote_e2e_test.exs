defmodule PtcRunner.Kernel.MCPRemoteE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises the read-only MCP Streamable HTTP source against a real public
  server (default: the credential-free Context7 endpoint, which negotiates
  protocol 2025-11-25 over SSE and issues real session IDs). Override the
  target with `PTC_TEST_MCP_ENDPOINT`. Unlike the loopback fixture, this
  covers real session initialization and echo, discovery latency, SSE
  framing, dialect and vendor-annotation tolerance in real SDK schemas, and
  lease cleanup. Servers negotiating an older protocol version (for example
  Microsoft Learn, 2025-06-18) are correctly rejected by the pinned client.
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

  @default_endpoint "https://mcp.context7.com/mcp"

  test "a live remote MCP session crosses the bounded Kernel capability boundary" do
    endpoint = System.get_env("PTC_TEST_MCP_ENDPOINT", @default_endpoint)

    builder =
      MCPSource.builder(
        endpoint: endpoint,
        tools: %{"resolve-library-id" => %{as: "docs.resolve", effect: :read}},
        timeout_ms: 30_000,
        max_result_bytes: 500_000
      )

    {:ok, registry} = ProviderRegistry.new(%{"remote-docs" => builder})
    {:ok, limits} = Limits.new(run_duration_ms: 90_000, workflow_timeout_ms: 90_000)

    {:ok, %{capabilities: [capability], snapshot: snapshot, close: close}} =
      ProviderRegistry.build(
        registry,
        "remote-docs",
        %{"allow" => ["docs.resolve"]},
        %{directory: File.cwd!(), destination: :workflow, limits: limits, owner: self()}
      )

    if is_function(close, 0), do: on_exit(close)

    snapshot = snapshot |> Jason.encode!() |> Jason.decode!()
    assert snapshot["provider"] == "remote-docs"
    assert snapshot["protocol"] == "mcp-2025-11-25"
    assert snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert [%{"name" => "docs.resolve", "effect" => "read"} = tool] = snapshot["tools"]
    assert tool["input_schema_hash"] =~ ~r/\A[0-9a-f]{64}\z/

    encoded_snapshot = Jason.encode!(snapshot)
    refute encoded_snapshot =~ URI.parse(endpoint).host
    refute encoded_snapshot =~ "resolve-library-id"

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mcp-remote-e2e")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = """
    (return (tool/docs.resolve {"libraryName" "phoenix framework" "query" "channels"}))
    """

    assert {:ok, %{value: value}} = Kernel.run(source, config)
    assert %{status: :ok, value: %{"text" => [entry | _]}} = value
    assert is_binary(entry) and entry != ""
  end
end
