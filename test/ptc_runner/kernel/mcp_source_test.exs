defmodule PtcRunner.Kernel.MCPSourceTest do
  # This integration suite uses real TCP requests and intentionally exercises
  # short request deadlines. Running it beside unrelated async suites makes
  # scheduler and connection-pool contention part of those deadlines, causing
  # valid fixture responses to be reported intermittently as `:mcp_timeout`.
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.TestSupport.MCPHTTPFixture

  @owner_lifecycle_timeout_ms 30_000

  @input_schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string", "x-mcp-header" => "Query"}
    },
    "required" => ["query"]
  }
  @output_schema %{
    "type" => "object",
    "properties" => %{"value" => %{"type" => "integer"}},
    "required" => ["value"]
  }

  @tag :tmp_dir
  test "discovers a narrowed catalog and executes structured, text, and domain-error tools", %{
    tmp_dir: dir
  } do
    parent = self()
    fixture = fixture(parent)
    on_exit(fixture.close)

    registry = registry(fixture.endpoint)
    manifest = manifest(dir, ~w(remote.structured remote.text remote.fail))

    {:ok, built} = RunBuilder.load_and_build(manifest, registry)

    assert [snapshot] = built.config.connector_snapshots
    assert snapshot["provider"] == "fixture-mcp"
    assert snapshot["protocol"] == "mcp-2026-07-28"
    assert snapshot["transport"] == "streamable_http"
    assert snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert snapshot["server_info_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    refute Map.has_key?(snapshot, "server")

    assert Enum.map(snapshot["tools"], & &1["name"]) ==
             ~w(remote.fail remote.structured remote.text)

    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{
             status: :ok,
             value: %{
               outcome: :returned,
               value: %{
                 "failed" => %{
                   kind: :provider_error,
                   reason: :domain_error,
                   status: :error
                 },
                 "structured" => %{status: :ok, value: %{"value" => 42}},
                 "text" => %{status: :ok, value: %{"text" => ["hello"]}}
               }
             }
           } = result.value

    events = EventSink.events(built.config.event_sink)
    started = Enum.find(events, &(&1.type == "run-started"))
    assert started.data.connector_snapshots == [snapshot]

    assert_receive {:mcp_request, "server/discover", discover_headers}
    assert discover_headers["mcp-protocol-version"] == "2026-07-28"
    assert discover_headers["mcp-method"] == "server/discover"
    refute Map.has_key?(discover_headers, "mcp-name")

    assert_receive {:mcp_request, "tools/list", list_headers}
    assert list_headers["mcp-method"] == "tools/list"
    assert_receive {:mcp_request, "tools/list", _headers}
    assert_receive {:mcp_request, "tools/call", call_headers}
    assert call_headers["mcp-method"] == "tools/call"
    assert call_headers["mcp-name"] in ["structured", "text", "fail"]
    assert call_headers["mcp-param-query"] == "x"
    assert_receive {:mcp_request, "tools/call", _headers}
    assert_receive {:mcp_request, "tools/call", _headers}
    refute_receive :mcp_deleted

    EventSink.stop(built.config.event_sink)
  end

  @tag :tmp_dir
  test "tolerates spec-standard extra tool fields and SDK annotation keys", %{tmp_dir: dir} do
    parent = self()
    fixture = fixture(parent, spec_extras?: true)
    on_exit(fixture.close)

    registry = registry(fixture.endpoint)
    manifest = manifest(dir, ~w(remote.structured))

    assert {:ok, built} = RunBuilder.load_and_build(manifest, registry)

    assert [snapshot] = built.config.connector_snapshots
    assert Enum.map(snapshot["tools"], & &1["name"]) == ["remote.structured"]

    encoded = Jason.encode!(snapshot)
    refute encoded =~ "x-vendor-wrap"
    refute encoded =~ "$schema"
    refute encoded =~ "taskSupport"
  end

  @tag :tmp_dir
  test "excludes malformed x-mcp-header tools without poisoning unmapped tools", %{tmp_dir: dir} do
    parent = self()
    fixture = fixture(parent, invalid_header?: true)
    on_exit(fixture.close)
    registry = registry(fixture.endpoint)

    assert {:error, :mcp_mapped_tool_missing} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry)

    assert {:ok, built} =
             dir
             |> manifest(["remote.text"])
             |> RunBuilder.load_and_build(registry)

    assert [snapshot] = built.config.connector_snapshots
    assert Enum.map(snapshot["tools"], & &1["name"]) == ["remote.text"]
    assert :ok = RunBuilder.close(built)
  end

  @tag :tmp_dir
  test "snapshot identity changes with upstream names and effective descriptions", %{tmp_dir: dir} do
    first = fixture(self(), structured_description: "First description")
    on_exit(first.close)

    first_snapshot =
      build_snapshot(
        dir,
        first.endpoint,
        %{"structured" => %{as: "remote.structured", effect: :read}}
      )

    second =
      fixture(self(),
        structured_name: "structured-v2",
        structured_description: "Second description"
      )

    on_exit(second.close)

    second_snapshot =
      build_snapshot(
        dir,
        second.endpoint,
        %{"structured-v2" => %{as: "remote.structured", effect: :read}}
      )

    [first_tool] = first_snapshot["tools"]
    [second_tool] = second_snapshot["tools"]
    assert first_tool["upstream_name_hash"] != second_tool["upstream_name_hash"]
    assert first_tool["description_hash"] != second_tool["description_hash"]
    assert first_snapshot["snapshot_hash"] != second_snapshot["snapshot_hash"]
  end

  @tag :tmp_dir
  test "rejects unsupported modern result types", %{tmp_dir: dir} do
    parent = self()
    fixture = fixture(parent, result_type: "input_required")
    on_exit(fixture.close)

    registry = registry(fixture.endpoint)
    manifest = manifest(dir, Map.keys(public_mappings()))

    {:ok, built} = RunBuilder.load_and_build(manifest, registry)
    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{status: :error, kind: :provider_error, reason: :invalid_result} =
             get_in(result.value, [:value, :value, "structured"])

    EventSink.stop(built.config.event_sink)
  end

  @tag :tmp_dir
  test "ignores removed task-support declarations", %{tmp_dir: dir} do
    parent = self()

    for execution <- [
          %{"taskSupport" => "later"},
          %{"taskSupport" => 42},
          %{"taskSupport" => nil},
          "sync"
        ] do
      fixture = fixture(parent, execution: execution)
      registry = registry(fixture.endpoint)
      manifest = manifest(dir, ~w(remote.structured))

      assert {:ok, built} = RunBuilder.load_and_build(manifest, registry)
      assert :ok = RunBuilder.close(built)
      fixture.close.()
    end
  end

  @tag :tmp_dir
  test "rejects manifest expansion and invalid discovered schemas during assembly", %{
    tmp_dir: dir
  } do
    parent = self()
    fixture = fixture(parent, invalid_schema?: true)
    on_exit(fixture.close)
    registry = registry(fixture.endpoint)

    assert {:error, :invalid_mcp_selection} =
             dir
             |> manifest(["unmapped"])
             |> RunBuilder.load_and_build(registry)

    refute_receive {:mcp_request, _, _}

    assert {:error, :mcp_invalid_tool_schema} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry)

    assert_receive {:mcp_request, "server/discover", _headers}
    assert_receive {:mcp_request, "tools/list", _headers}
    assert_receive {:mcp_request, "tools/list", _headers}
  end

  test "installation rejects non-loopback HTTP endpoints and duplicate public mappings" do
    assert_raise ArgumentError, fn ->
      MCPSource.builder(endpoint: "http://example.com/mcp", tools: mappings())
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        endpoint: "https://example.com/mcp",
        tools: %{
          "one" => %{as: "same", effect: :read},
          "two" => %{as: "same", effect: :read}
        }
      )
    end
  end

  @tag :tmp_dir
  test "host headers cannot reintroduce protocol-owned MCP headers", %{tmp_dir: dir} do
    fixture = fixture(self())
    on_exit(fixture.close)

    registry =
      registry(fixture.endpoint,
        headers: fn -> [{"mcp-session-id", "legacy-session"}] end
      )

    assert {:error, :mcp_authentication_failed} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry)
  end

  @tag :tmp_dir
  test "resolves host headers once for discovery and every frozen capability call", %{
    tmp_dir: dir
  } do
    parent = self()
    fixture = fixture(parent)
    on_exit(fixture.close)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    headers = fn ->
      count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      [{"authorization", "Bearer token-#{count}"}]
    end

    registry = registry(fixture.endpoint, headers: headers)
    manifest = manifest(dir, ~w(remote.structured remote.text remote.fail))
    assert {:ok, built} = RunBuilder.load_and_build(manifest, registry)
    assert {:ok, _result} = Kernel.run(built.entry_source, built.config)
    assert Agent.get(counter, & &1) == 1

    for _request <- 1..6 do
      assert_receive {:mcp_request, _method, %{"authorization" => "Bearer token-1"}}
    end
  end

  @tag :tmp_dir
  test "rendered host credentials are absent from capability closures", %{tmp_dir: dir} do
    marker = "PRIVATE_MCP_CREDENTIAL_MARKER"
    fixture = fixture(self())
    on_exit(fixture.close)

    registry =
      registry(fixture.endpoint,
        headers: fn -> [{"authorization", "Bearer #{marker}"}] end
      )

    assert {:ok, built} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry)

    built.config.mission_environment.capabilities
    |> Map.values()
    |> Enum.each(fn capability ->
      {:env, environment} = :erlang.fun_info(capability.callback, :env)
      refute inspect(environment, limit: :infinity, printable_limit: :infinity) =~ marker
    end)

    assert :ok = RunBuilder.close(built)
  end

  @tag :tmp_dir
  test "rejects duplicate JSON response keys before protocol validation", %{tmp_dir: dir} do
    parent = self()
    duplicate = fixture(parent, duplicate_json?: true)
    on_exit(duplicate.close)

    assert {:error, :mcp_protocol_error} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(duplicate.endpoint))
  end

  @tag :tmp_dir
  test "rejects unsupported protocol errors without initialization fallback", %{tmp_dir: dir} do
    parent = self()
    legacy = fixture(parent, unsupported_protocol?: true)
    on_exit(legacy.close)

    assert {:error, :mcp_protocol_error} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(legacy.endpoint))

    assert_receive {:mcp_request, "server/discover", _headers}
    refute_receive {:mcp_request, "initialize", _headers}
  end

  @tag :tmp_dir
  test "JSON-RPC errors have closed discovery and non-retryable invocation outcomes", %{
    tmp_dir: dir
  } do
    parent = self()
    discovery_error = fixture(parent, discover_error?: true)
    on_exit(discovery_error.close)

    assert {:error, :mcp_remote_error} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(discovery_error.endpoint))

    invocation_error = fixture(parent, rpc_error_tool: "structured")
    on_exit(invocation_error.close)

    {:ok, built} =
      dir
      |> manifest(Map.keys(public_mappings()))
      |> RunBuilder.load_and_build(registry(invocation_error.endpoint))

    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{status: :error, kind: :provider_error, reason: :domain_error, retryable?: false} =
             get_in(result.value, [:value, :value, "structured"])

    EventSink.stop(built.config.event_sink)

    protocol_error =
      fixture(parent, rpc_error_tool: "structured", rpc_error_status: 400)

    on_exit(protocol_error.close)

    {:ok, built} =
      dir
      |> manifest(Map.keys(public_mappings()))
      |> RunBuilder.load_and_build(registry(protocol_error.endpoint))

    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{status: :error, kind: :provider_error, reason: :invalid_result, retryable?: false} =
             get_in(result.value, [:value, :value, "structured"])

    EventSink.stop(built.config.event_sink)
  end

  @tag :tmp_dir
  test "rejects JSON-RPC envelopes containing both result and error", %{tmp_dir: dir} do
    parent = self()
    invalid = fixture(parent, result_and_error?: true)
    on_exit(invalid.close)

    {:ok, built} =
      dir
      |> manifest(Map.keys(public_mappings()),
        timeout_ms: 5_000,
        evaluation_timeout_ms: 5_000
      )
      |> RunBuilder.load_and_build(registry(invalid.endpoint, timeout_ms: 5_000))

    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{status: :error, kind: :provider_error, reason: :invalid_result} =
             get_in(result.value, [:value, :value, "structured"])

    EventSink.stop(built.config.event_sink)
  end

  @tag :tmp_dir
  test "accepts bounded SSE responses and rejects malformed pagination and selection keys", %{
    tmp_dir: dir
  } do
    parent = self()
    sse = fixture(parent, sse?: true, sse_notification?: true, sse_comments?: true)
    on_exit(sse.close)

    {:ok, built} =
      dir
      |> manifest(["remote.structured"])
      |> RunBuilder.load_and_build(registry(sse.endpoint, timeout_ms: 5_000))

    assert [snapshot] = built.config.connector_snapshots
    assert Enum.map(snapshot["tools"], & &1["name"]) == ["remote.structured"]
    assert :ok = RunBuilder.close(built)
    assert :ok = RunBuilder.close(built)

    repeated = fixture(parent, sse?: true, sse_extra_response?: true)
    on_exit(repeated.close)

    assert {:ok, repeated_build} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(repeated.endpoint, timeout_ms: 5_000))

    assert :ok = RunBuilder.close(repeated_build)

    repeated_chunked =
      fixture(parent, sse?: true, sse_extra_response?: true, sse_chunked?: true)

    on_exit(repeated_chunked.close)

    assert {:ok, repeated_chunked_build} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(repeated_chunked.endpoint, timeout_ms: 5_000))

    assert_receive {:mcp_stream_holding, repeated_chunked_holder}
    send(repeated_chunked_holder, :release)
    assert :ok = RunBuilder.close(repeated_chunked_build)

    coalesced_tail = fixture(parent, sse?: true, sse_trailing_bytes: 1_100_000)
    on_exit(coalesced_tail.close)

    assert {:ok, coalesced_tail_build} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(coalesced_tail.endpoint, timeout_ms: 5_000))

    assert :ok = RunBuilder.close(coalesced_tail_build)

    split_tail =
      fixture(parent, sse?: true, sse_trailing_bytes: 1_100_000, sse_chunked?: true)

    on_exit(split_tail.close)

    assert {:ok, split_tail_build} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(split_tail.endpoint, timeout_ms: 5_000))

    assert_receive {:mcp_stream_holding, split_tail_holder}
    send(split_tail_holder, :release)
    assert :ok = RunBuilder.close(split_tail_build)

    oversized_prefix = fixture(parent, sse?: true, sse_oversized_prefix?: true)
    on_exit(oversized_prefix.close)

    assert {:error, :mcp_response_exceeded} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(oversized_prefix.endpoint, timeout_ms: 5_000))

    empty_data = fixture(parent, sse?: true, sse_empty_data?: true)
    on_exit(empty_data.close)

    assert {:error, :mcp_protocol_error} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(empty_data.endpoint, timeout_ms: 5_000))

    held_open = fixture(parent, sse?: true, sse_hold_open?: true)
    on_exit(held_open.close)

    build_task =
      Task.async(fn ->
        dir
        |> manifest(["remote.structured"])
        |> RunBuilder.load_and_build(registry(held_open.endpoint, timeout_ms: 5_000))
      end)

    assert_receive {:mcp_stream_holding, holder}
    assert {:ok, held_build} = Task.await(build_task, 2_000)
    send(holder, :release)
    assert :ok = RunBuilder.close(held_build)

    cr_only = fixture(parent, sse?: true, sse_line_ending: "\r")
    on_exit(cr_only.close)

    assert {:ok, cr_build} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(cr_only.endpoint, timeout_ms: 5_000))

    assert :ok = RunBuilder.close(cr_build)

    fragmented_bom =
      fixture(parent,
        sse?: true,
        sse_hold_open?: true,
        sse_fragmented_bom?: true
      )

    on_exit(fragmented_bom.close)

    bom_task =
      Task.async(fn ->
        dir
        |> manifest(["remote.structured"])
        |> RunBuilder.load_and_build(registry(fragmented_bom.endpoint, timeout_ms: 5_000))
      end)

    assert_receive {:mcp_stream_holding, bom_holder}
    assert {:ok, bom_build} = Task.await(bom_task, 2_000)
    send(bom_holder, :release)
    assert :ok = RunBuilder.close(bom_build)

    duplicate = fixture(parent, duplicate_catalog?: true)
    on_exit(duplicate.close)

    assert {:error, :mcp_invalid_catalog} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(duplicate.endpoint))

    excessive = fixture(parent)
    on_exit(excessive.close)

    assert {:error, :mcp_catalog_exceeded} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(excessive.endpoint, max_pages: 1))

    assert {:error, :invalid_mcp_selection} =
             dir
             |> manifest(["remote.structured"], config_extra: %{"endpoint" => "forbidden"})
             |> RunBuilder.load_and_build(registry(excessive.endpoint))
  end

  @tag :tmp_dir
  test "selection can hide an allowed MCP capability from model discovery", %{tmp_dir: dir} do
    parent = self()
    fixture = fixture(parent)
    on_exit(fixture.close)

    {:ok, built} =
      dir
      |> manifest(~w(remote.structured remote.text),
        timeout_ms: 5_000,
        evaluation_timeout_ms: 5_000,
        config_extra: %{"model_visible" => ["remote.structured"]}
      )
      |> RunBuilder.load_and_build(registry(fixture.endpoint, timeout_ms: 5_000))

    visibility =
      Map.new(built.config.mission_environment.capabilities, fn {_name, capability} ->
        {capability.name, capability.model_visible}
      end)

    assert visibility == %{"remote.structured" => true, "remote.text" => false}
    [restricted_snapshot] = built.config.connector_snapshots

    assert [
             %{"model_visible" => true, "description_hash" => visible_hash},
             %{"model_visible" => false, "description_hash" => nil}
           ] = restricted_snapshot["tools"]

    assert is_binary(visible_hash)
    assert :ok = RunBuilder.close(built)

    {:ok, fully_visible} =
      dir
      |> manifest(~w(remote.structured remote.text),
        timeout_ms: 5_000,
        evaluation_timeout_ms: 5_000
      )
      |> RunBuilder.load_and_build(registry(fixture.endpoint, timeout_ms: 5_000))

    [fully_visible_snapshot] = fully_visible.config.connector_snapshots
    assert fully_visible_snapshot["snapshot_hash"] != restricted_snapshot["snapshot_hash"]
    assert :ok = RunBuilder.close(fully_visible)

    assert {:error, :invalid_mcp_selection} =
             dir
             |> manifest(["remote.structured"],
               config_extra: %{"model_visible" => ["remote.text"]}
             )
             |> RunBuilder.load_and_build(registry(fixture.endpoint))
  end

  @tag :tmp_dir
  test "snapshot hashes are stable and owner cleanup remains resource-free", %{
    tmp_dir: dir
  } do
    parent = self()
    fixture = fixture(parent)
    on_exit(fixture.close)
    registry = registry(fixture.endpoint)
    manifest = manifest(dir, ~w(remote.structured remote.text remote.fail))

    {:ok, first} = RunBuilder.load_and_build(manifest, registry)
    first_snapshot = first.config.connector_snapshots
    assert :ok = RunBuilder.close(first)

    {:ok, second} = RunBuilder.load_and_build(manifest, registry)
    assert second.config.connector_snapshots == first_snapshot
    assert :ok = RunBuilder.close(second)

    {:ok, owner} =
      Task.start(fn ->
        result = RunBuilder.load_and_build(manifest, registry)
        send(parent, {:owner_build, result})
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:owner_build, {:ok, abandoned}}, @owner_lifecycle_timeout_ms
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, @owner_lifecycle_timeout_ms
    refute Process.alive?(abandoned.config.event_sink.pid)
  end

  @tag :tmp_dir
  test "bad output, oversized responses, disconnects, authentication failures, and timeouts are bounded",
       %{tmp_dir: dir} do
    parent = self()

    invalid_output = fixture(parent, structured_value: "wrong")
    on_exit(invalid_output.close)
    invalid_registry = registry(invalid_output.endpoint)

    {:ok, invalid} =
      RunBuilder.load_and_build(manifest(dir, Map.keys(public_mappings())), invalid_registry)

    assert {:ok, invalid_result} = Kernel.run(invalid.entry_source, invalid.config)

    assert %{kind: :provider_error, reason: :invalid_result, status: :error} =
             get_in(invalid_result.value, [:value, :value, "structured"])

    EventSink.stop(invalid.config.event_sink)

    oversized = fixture(parent, large_text?: true)
    on_exit(oversized.close)
    oversized_registry = registry(oversized.endpoint)

    {:ok, large} =
      RunBuilder.load_and_build(manifest(dir, Map.keys(public_mappings())), oversized_registry)

    assert {:ok, large_result} = Kernel.run(large.entry_source, large.config)

    assert %{kind: :provider_error, reason: :invalid_result, status: :error} =
             get_in(large_result.value, [:value, :value, "text"])

    EventSink.stop(large.config.event_sink)

    disconnected = fixture(parent, disconnect?: true)
    on_exit(disconnected.close)

    assert {:error, :mcp_transport_error} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(disconnected.endpoint))

    oversized_unauthorized = fixture(parent, http_error_status: 401)
    on_exit(oversized_unauthorized.close)

    assert {:error, :mcp_authentication_failed} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(oversized_unauthorized.endpoint))

    oversized_server_error = fixture(parent, http_error_status: 500)
    on_exit(oversized_server_error.close)

    assert {:error, :mcp_transport_error} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(oversized_server_error.endpoint))

    secret = "not-for-errors"

    auth_builder =
      MCPSource.builder(
        endpoint: invalid_output.endpoint,
        allow_insecure_loopback: true,
        headers: fn -> raise secret end,
        tools: mappings()
      )

    {:ok, auth_registry} = ProviderRegistry.new(%{"fixture-mcp" => auth_builder})

    assert {:error, :mcp_authentication_failed} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(auth_registry)

    refute inspect(:mcp_authentication_failed) =~ secret

    blocked = fixture(parent, block_discover?: true)
    on_exit(blocked.close)
    timeout_registry = registry(blocked.endpoint, timeout_ms: 500)

    task =
      Task.async(fn ->
        dir
        |> manifest(["remote.structured"], timeout_ms: 500)
        |> RunBuilder.load_and_build(timeout_registry)
      end)

    assert_receive {:mcp_blocked, worker}, 1_000
    assert {:error, :mcp_timeout} = Task.await(task, 2_000)
    send(worker, :release)

    header_builder =
      MCPSource.builder(
        endpoint: invalid_output.endpoint,
        allow_insecure_loopback: true,
        headers: fn ->
          send(parent, {:mcp_header_blocked, self()})

          receive do
            :never -> []
          end
        end,
        tools: mappings(),
        timeout_ms: 500
      )

    {:ok, header_registry} = ProviderRegistry.new(%{"fixture-mcp" => header_builder})

    header_task =
      Task.async(fn ->
        dir
        |> manifest(["remote.structured"], timeout_ms: 500)
        |> RunBuilder.load_and_build(header_registry)
      end)

    assert_receive {:mcp_header_blocked, header_worker}, 1_000
    header_ref = Process.monitor(header_worker)
    assert {:error, :mcp_timeout} = Task.await(header_task, 2_000)
    assert_receive {:DOWN, ^header_ref, :process, ^header_worker, :killed}
  end

  @tag :tmp_dir
  test "run timeout cancels an in-flight stateless MCP call", %{tmp_dir: dir} do
    parent = self()
    fixture = fixture(parent, block_tool: "structured")
    on_exit(fixture.close)
    registry = registry(fixture.endpoint, timeout_ms: 500)

    {:ok, built} =
      dir
      |> manifest(Map.keys(public_mappings()), timeout_ms: 500, evaluation_timeout_ms: 500)
      |> RunBuilder.load_and_build(registry)

    task = Task.async(fn -> Kernel.run(built.entry_source, built.config) end)
    assert_receive {:mcp_blocked, worker}
    assert {:ok, _result} = Task.await(task, 3_000)
    send(worker, :release)
    EventSink.stop(built.config.event_sink)
  end

  defp registry(endpoint, opts \\ []) do
    builder =
      MCPSource.builder(
        endpoint: endpoint,
        allow_insecure_loopback: true,
        headers:
          Keyword.get(
            opts,
            :headers,
            fn -> [{"authorization", "Bearer fixture-secret"}] end
          ),
        tools: Keyword.get(opts, :tools, mappings()),
        timeout_ms: Keyword.get(opts, :timeout_ms, 2_000),
        max_result_bytes: 64_000,
        max_pages: Keyword.get(opts, :max_pages, 16)
      )

    {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})
    registry
  end

  defp mappings do
    %{
      "structured" => %{as: "remote.structured", effect: :read},
      "text" => %{as: "remote.text", effect: :read},
      "fail" => %{as: "remote.fail", effect: :read}
    }
  end

  defp public_mappings, do: Map.new(mappings(), fn {_upstream, mapping} -> {mapping.as, true} end)

  defp build_snapshot(dir, endpoint, tools) do
    registry = registry(endpoint, tools: tools)
    {:ok, built} = RunBuilder.load_and_build(manifest(dir, ["remote.structured"]), registry)
    [snapshot] = built.config.connector_snapshots
    assert :ok = RunBuilder.close(built)
    snapshot
  end

  defp fixture(parent, opts \\ []) do
    MCPHTTPFixture.start(fn request ->
      method = request.body["method"]
      send(parent, {:mcp_request, method, request.headers})

      if opts[:block_discover?] && method == "server/discover" do
        send(parent, {:mcp_blocked, self()})

        receive do
          :release -> :ok
        end
      end

      blocked_tool = get_in(request.body, ["params", "name"])

      if is_binary(opts[:block_tool]) && opts[:block_tool] == blocked_tool do
        send(parent, {:mcp_blocked, self()})

        receive do
          :release -> :ok
        end
      end

      if opts[:disconnect?] && method == "server/discover" do
        :close
      else
        if valid_modern_request?(request) do
          request |> response(opts) |> maybe_sse(opts, method)
        else
          send(parent, {:mcp_invalid_request, method})
          {400, [{"content-type", "application/json"}], ""}
        end
      end
    end)
  end

  defp valid_modern_request?(request) do
    metadata = get_in(request.body, ["params", "_meta"])
    method = request.body["method"]
    name = get_in(request.body, ["params", "name"])
    arguments = get_in(request.body, ["params", "arguments"])

    request.method == "POST" and request.headers["mcp-protocol-version"] == "2026-07-28" and
      request.headers["mcp-method"] == method and
      metadata == %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientInfo" => %{"name" => "ptc_runner", "version" => "0.x"},
        "io.modelcontextprotocol/clientCapabilities" => %{}
      } and
      case method do
        "tools/call" ->
          request.headers["mcp-name"] == name and
            request.headers["mcp-param-query"] == arguments["query"]

        _method ->
          not Map.has_key?(request.headers, "mcp-name")
      end
  end

  defp response(%{body: %{"method" => "server/discover", "id" => id}}, opts) do
    cond do
      status = opts[:http_error_status] ->
        {status, [{"content-type", "text/plain"}], String.duplicate("x", 1_100_000)}

      opts[:unsupported_protocol?] ->
        rpc_error(id, -32_600, "UnsupportedProtocolVersion", status: 400)

      opts[:discover_error?] ->
        rpc_error(id, -32_603, "discovery rejected")

      opts[:duplicate_json?] ->
        body =
          ~s|{"jsonrpc":"2.0","id":#{id},"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|

        {200, [{"content-type", "application/json"}], body}

      true ->
        json(id, %{
          "resultType" => "complete",
          "supportedVersions" => Keyword.get(opts, :supported_versions, ["2026-07-28"]),
          "capabilities" => %{"tools" => %{}},
          "_meta" => %{
            "io.modelcontextprotocol/serverInfo" => %{
              "name" => "fixture",
              "version" => "1.0"
            }
          },
          "ttlMs" => 0,
          "cacheScope" => "private"
        })
    end
  end

  defp response(
         %{body: %{"method" => "tools/list", "id" => id, "params" => params}},
         opts
       ) do
    if is_nil(params["cursor"]) do
      structured_name = Keyword.get(opts, :structured_name, "structured")

      json(id, %{
        "resultType" => "complete",
        "tools" => [tool(structured_name, opts)],
        "nextCursor" => "page-2",
        "ttlMs" => 0,
        "cacheScope" => "private"
      })
    else
      tools =
        if opts[:duplicate_catalog?],
          do: [tool("structured", opts)],
          else: [tool("text", opts), tool("fail", opts)]

      json(id, %{
        "resultType" => "complete",
        "tools" => tools,
        "ttlMs" => 0,
        "cacheScope" => "private"
      })
    end
  end

  defp response(
         %{body: %{"method" => "tools/call", "id" => id, "params" => params}},
         opts
       ) do
    case params["name"] do
      "structured" ->
        if opts[:rpc_error_tool] == "structured" do
          rpc_error(
            id,
            -32_602,
            "invalid parameters",
            status: Keyword.get(opts, :rpc_error_status, 200)
          )
        else
          value = Keyword.get(opts, :structured_value, 42)

          if opts[:result_and_error?] do
            body = %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "resultType" => "complete",
                "structuredContent" => %{"value" => value},
                "content" => []
              },
              "error" => %{"code" => -32_000, "message" => "must not coexist"}
            }

            {200, [{"content-type", "application/json"}], Jason.encode!(body)}
          else
            json(id, %{
              "resultType" => Keyword.get(opts, :result_type, "complete"),
              "structuredContent" => %{"value" => value},
              "content" => []
            })
          end
        end

      "text" ->
        text = if opts[:large_text?], do: String.duplicate("x", 40_000), else: "hello"

        json(id, %{
          "resultType" => "complete",
          "content" => [%{"type" => "text", "text" => text}]
        })

      "fail" ->
        json(id, %{"resultType" => "complete", "isError" => true, "content" => []})
    end
  end

  defp tool(name, opts) when name in ["structured", "structured-v2"] do
    input =
      cond do
        opts[:invalid_schema?] ->
          Map.put(@input_schema, "$ref", "remote")

        opts[:invalid_header?] ->
          put_in(@input_schema, ["properties", "query", "x-mcp-header"], "bad header")

        true ->
          @input_schema
      end

    base = %{
      "name" => name,
      "description" => Keyword.get(opts, :structured_description, "Return one structured value."),
      "inputSchema" => input,
      "outputSchema" => @output_schema
    }

    base =
      if opts[:spec_extras?] do
        base
        |> Map.merge(%{
          "title" => "Structured",
          "execution" => %{"taskSupport" => "forbidden"},
          "_meta" => %{"vendor" => %{"tags" => []}}
        })
        |> Map.update!(
          "inputSchema",
          &Map.merge(&1, %{
            "$schema" => "http://json-schema.org/draft-07/schema#",
            "x-vendor-wrap" => true
          })
        )
      else
        base
      end

    case Keyword.fetch(opts, :execution) do
      {:ok, execution} -> Map.put(base, "execution", execution)
      :error -> base
    end
  end

  defp tool(name, _opts) do
    %{
      "name" => name,
      "description" => "Fixture tool.",
      "inputSchema" => @input_schema
    }
  end

  defp json(id, result, opts \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    headers = Keyword.get(opts, :headers, []) ++ [{"content-type", "application/json"}]
    {200, headers, body}
  end

  defp rpc_error(id, code, message, opts \\ []) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })

    {Keyword.get(opts, :status, 200), [{"content-type", "application/json"}], body}
  end

  defp maybe_sse({200, headers, body}, opts, method) do
    if opts[:sse?] do
      headers =
        headers
        |> Enum.reject(fn {name, _value} -> name == "content-type" end)
        |> Enum.concat([{"content-type", "text/event-stream"}])

      notification =
        if opts[:sse_notification?],
          do: ~s|data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\n|,
          else: ""

      before_comment = if opts[:sse_comments?], do: ": keep-alive\n\n", else: ""
      after_comment = if opts[:sse_comments?], do: ": complete\n\n", else: ""
      empty_data = if opts[:sse_empty_data?], do: "data\n\n", else: ""
      extra = if opts[:sse_extra_response?], do: "data: #{body}\n\n", else: ""
      trailing = String.duplicate("x", Keyword.get(opts, :sse_trailing_bytes, 0))

      leading =
        if opts[:sse_oversized_prefix?],
          do: ":" <> String.duplicate("x", 1_100_000) <> "\n\ndata: {\n\n",
          else: ""

      prefix = "#{before_comment}#{notification}#{empty_data}data: #{body}\n\n#{after_comment}"

      stream = leading <> prefix <> extra <> trailing

      stream = String.replace(stream, "\n", Keyword.get(opts, :sse_line_ending, "\n"))

      chunks =
        cond do
          opts[:sse_fragmented_bom?] ->
            [<<0xEF>>, <<0xBB>>, <<0xBF>> <> stream]

          opts[:sse_chunked?] ->
            line_ending = Keyword.get(opts, :sse_line_ending, "\n")
            encoded_prefix = String.replace(prefix, "\n", line_ending)
            [encoded_prefix, String.replace(extra <> trailing, "\n", line_ending)]

          true ->
            [stream]
        end

      if (opts[:sse_hold_open?] && method == "server/discover") || opts[:sse_chunked?],
        do: {:chunked, 200, headers, chunks},
        else: {200, headers, IO.iodata_to_binary(chunks)}
    else
      {200, headers, body}
    end
  end

  defp maybe_sse(response, _opts, _method), do: response

  defp manifest(dir, allow, opts \\ []) do
    File.write!(
      Path.join(dir, "workflow.clj"),
      ~S|(ns app) (defn run [input] (return (tool/kernel-eval {"kind" :source "source" (get input "program")})))|
    )

    program =
      ~S|(let [structured (tool/remote.structured {"query" "x"}) text (tool/remote.text {"query" "x"}) failed (tool/remote.fail {"query" "x"})] (return {"structured" structured "text" text "failed" failed}))|

    config =
      Map.merge(
        %{
          "allow" => allow,
          "timeout_ms" => Keyword.get(opts, :timeout_ms, 1_000),
          "max_result_bytes" => 32_000
        },
        Keyword.get(opts, :config_extra, %{})
      )

    body = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{"program" => program}},
      "providers" => %{
        "mission" => [
          %{
            "name" => "fixture-mcp",
            "config" => config
          }
        ]
      },
      "limits" =>
        if(opts[:evaluation_timeout_ms],
          do: %{"evaluation_timeout_ms" => opts[:evaluation_timeout_ms]},
          else: %{}
        )
    }

    path = Path.join(dir, "#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(body))
    path
  end
end
