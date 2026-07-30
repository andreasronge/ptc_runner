defmodule PtcRunner.Kernel.MCPSourceTest do
  # This integration suite uses real TCP requests and intentionally exercises
  # short request deadlines. Running it beside unrelated async suites makes
  # scheduler and connection-pool contention part of those deadlines, causing
  # valid fixture responses to be reported intermittently as `:mcp_timeout`.
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.MCPOAuth.TokenManager
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Test.MCPOAuthRecordingStore
  alias PtcRunner.TestSupport.MCPHTTPFixture

  @owner_lifecycle_timeout_ms 30_000
  @max_logical_result_bytes 1_048_576
  @stdio_fixture Path.expand("../../support/mcp_stdio_source_fixture.sh", __DIR__)
  @root Path.expand("../../..", __DIR__)
  @inherited_environment ~w(HOME LOGNAME PATH SHELL TERM USER)

  test "rejects a dynamic OAuth manager bound to another exact resource" do
    manager = %TokenManager{pid: self(), resource: "https://mcp.example/a"}

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport: {:streamable_http, endpoint: "https://mcp.example/b", authorization: manager},
        tools: %{"read" => %{as: "read", effect: :read}}
      )
    end
  end

  test "fences dynamic OAuth after rejected-response state persistence fails" do
    cases = [
      {{401, [{"www-authenticate", ~s(Bearer error="invalid_token")}]}, 401,
       [{"www-authenticate", ~s(Bearer error="invalid_token")}],
       fn
         {:mark_access_rejected, _key, _generation}, _timeout ->
           {:return, {:error, :store_error}}

         _operation, _timeout ->
           :delegate
       end},
      {{403,
        [
          {"www-authenticate", ~s(Bearer error="insufficient_scope", scope="write")}
        ]}, 403,
       [
         {"www-authenticate", ~s(Bearer error="insufficient_scope", scope="write")}
       ],
       fn
         {:upsert_requirement, _key, _generation, _scopes, _ttl_ms}, _timeout ->
           {:return, {:error, :store_error}}

         _operation, _timeout ->
           :delegate
       end},
      {{401, [{"www-authenticate", ~s(Bearer error="invalid_token")}],
        String.duplicate("x", 2_100_000)}, 401,
       [{"www-authenticate", ~s(Bearer error="invalid_token")}],
       fn
         {:mark_access_rejected, _key, _generation}, _timeout ->
           {:return, {:error, :store_error}}

         _operation, _timeout ->
           :delegate
       end},
      {{:headers_only, 403,
        [
          {"www-authenticate", ~s(Bearer error="insufficient_scope", scope="write")}
        ]}, 403,
       [
         {"www-authenticate", ~s(Bearer error="insufficient_scope", scope="write")}
       ],
       fn
         {:upsert_requirement, _key, _generation, _scopes, _ttl_ms}, _timeout ->
           {:return, {:error, :store_error}}

         _operation, _timeout ->
           :delegate
       end},
      {{:status_only, 401}, 401, [],
       fn
         {:mark_access_rejected, _key, _generation}, _timeout ->
           {:return, {:error, :store_error}}

         _operation, _timeout ->
           :delegate
       end},
      {{401, [{"x-oversized", String.duplicate("x", 40_000)}], ""}, 401, [],
       fn
         {:mark_access_rejected, _key, _generation}, _timeout ->
           {:return, {:error, :store_error}}

         _operation, _timeout ->
           :delegate
       end}
    ]

    for {tool_http_error, status, _headers, interceptor} <- cases do
      fixture = fixture(self(), tool_http_error: tool_http_error)
      manager = oauth_manager(fixture.endpoint, interceptor)

      builder =
        MCPSource.builder(
          transport:
            {:streamable_http,
             endpoint: fixture.endpoint, authorization: manager, allow_insecure_loopback: true},
          tools: %{"structured" => %{as: "remote.structured", effect: :read}},
          timeout_ms: 2_000
        )

      {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})
      {:ok, limits} = Limits.new()

      assert {:ok, %{capabilities: [capability], close: close}} =
               ProviderRegistry.build(
                 registry,
                 "fixture-mcp",
                 %{"allow" => ["remote.structured"]},
                 %{
                   directory: File.cwd!(),
                   destination: :mission,
                   limits: limits,
                   installed_limits: limits,
                   owner: self()
                 }
               )

      result =
        capability.callback.(%{"query" => "x"}, %{
          capability_id: capability.name,
          inspection_sink: nil,
          traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
        })

      assert_receive {:fixture_tool_http_error, ^status}

      assert {:error, :mcp_authorization_required} =
               TokenManager.authorization_header(
                 manager,
                 System.monotonic_time(:millisecond) + 1_000
               )

      assert match?({:error, %ProviderError{kind: :transport_error}}, result),
             "unexpected OAuth #{status} result: #{inspect(result)}"

      assert {:error, :mcp_transport_error} = close.()
      Process.exit(manager.pid, :kill)
      fixture.close.()
    end
  end

  test "ordinary and malformed dynamic 403 responses are non-retryable authentication failures" do
    challenges = [
      [],
      [{"www-authenticate", "Bearer ???"}],
      [{"www-authenticate", ~s(Bearer error="access_denied")}]
    ]

    for headers <- challenges do
      fixture = fixture(self(), tool_http_error: {403, headers})
      manager = oauth_manager(fixture.endpoint, fn _operation, _timeout -> :delegate end)

      builder =
        MCPSource.builder(
          transport:
            {:streamable_http,
             endpoint: fixture.endpoint, authorization: manager, allow_insecure_loopback: true},
          tools: %{"structured" => %{as: "remote.structured", effect: :read}},
          timeout_ms: 2_000
        )

      {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})
      {:ok, limits} = Limits.new()

      assert {:ok, %{capabilities: [capability], close: close}} =
               ProviderRegistry.build(
                 registry,
                 "fixture-mcp",
                 %{"allow" => ["remote.structured"]},
                 %{
                   directory: File.cwd!(),
                   destination: :mission,
                   limits: limits,
                   installed_limits: limits,
                   owner: self()
                 }
               )

      assert {:error,
              %ProviderError{
                kind: :authentication_failed,
                retryable?: false,
                details: "mcp_authentication_failed"
              }} =
               capability.callback.(%{"query" => "x"}, %{
                 capability_id: capability.name,
                 inspection_sink: nil,
                 traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
               })

      deadline = System.monotonic_time(:millisecond) + 1_000
      assert {:ok, issued} = TokenManager.authorization_header(manager, deadline)
      assert :ok = TokenManager.release(manager, issued.admission, deadline)
      assert :ok = close.()
      fixture.close.()
    end
  end

  test "a Dispatcher timeout cannot skip late OAuth response persistence" do
    assert_dispatcher_timeout_persists_oauth_failure(
      401,
      [{"www-authenticate", ~s(Bearer error="invalid_token")}]
    )

    assert_dispatcher_timeout_persists_oauth_failure(
      403,
      [
        {"www-authenticate", ~s(Bearer error="insufficient_scope", scope="write")}
      ]
    )
  end

  defp assert_dispatcher_timeout_persists_oauth_failure(status, headers) do
    parent = self()

    fixture =
      fixture(
        parent,
        tool_http_error: {status, headers}
      )

    manager =
      oauth_manager(fixture.endpoint, fn operation, _timeout ->
        transition? =
          case {status, operation} do
            {401, {:mark_access_rejected, _key, _generation}} -> true
            {403, {:upsert_requirement, _key, _generation, _scopes, _ttl_ms}} -> true
            _other -> false
          end

        if transition? do
          send(parent, {:oauth_transition_persistence_blocked, status, self()})

          receive do
            :continue_oauth_transition -> :delegate
          end
        else
          :delegate
        end
      end)

    builder =
      MCPSource.builder(
        transport:
          {:streamable_http,
           endpoint: fixture.endpoint, authorization: manager, allow_insecure_loopback: true},
        tools: %{"structured" => %{as: "remote.structured", effect: :read}},
        timeout_ms: 1_000
      )

    {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})
    {:ok, limits} = Limits.new()

    assert {:ok, %{capabilities: [capability], close: close}} =
             ProviderRegistry.build(
               registry,
               "fixture-mcp",
               %{"allow" => ["remote.structured"]},
               %{
                 directory: File.cwd!(),
                 destination: :mission,
                 limits: limits,
                 installed_limits: limits,
                 owner: self()
               }
             )

    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
    authorization_config = :sys.get_state(manager.pid).config

    {:ok, grant} =
      Store.load_grant(authorization_config.context.store, authorization_config.key, 1_000)

    limits = Limits.defaults()

    {:ok, state, event_sink} =
      RunState.start_with_event_sink(
        limits,
        run_id: "late-oauth-transition-#{status}",
        trace_id: "late-oauth-transition-#{status}",
        terminal_reserve: EventSink.terminal_reserve(:normal, limits)
      )

    task =
      Task.async(fn ->
        Dispatcher.dispatch(
          state,
          :mission,
          environment,
          capability.name,
          %{"query" => "x"},
          500,
          event_sink
        )
      end)

    assert_receive {:oauth_transition_persistence_blocked, ^status, persistence_worker}, 1_000
    persistence_ref = Process.monitor(persistence_worker)

    assert %{status: :error, kind: :timeout, reason: :provider_timeout} =
             Task.await(task, 2_000)

    send(persistence_worker, :continue_oauth_transition)
    assert_receive {:DOWN, ^persistence_ref, :process, ^persistence_worker, :normal}, 1_000

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(
               manager,
               System.monotonic_time(:millisecond) + 1_000
             )

    case status do
      401 ->
        assert {:error, :rejected_before_dispatch} =
                 Store.admit_mcp(
                   authorization_config.context.store,
                   authorization_config.key,
                   grant.generation,
                   1_000,
                   1_000
                 )

      403 ->
        assert {:ok, %{scopes: scopes}} =
                 Store.load_requirement(
                   authorization_config.context.store,
                   authorization_config.key,
                   1_000
                 )

        assert scopes == MapSet.new(["write"])
    end

    assert :ok = close.()

    assert {:ok, replacement_manager} =
             TokenManager.start(
               owner: self(),
               context: authorization_config.context,
               authority: authorization_config.authority,
               authority_epoch: authorization_config.key.authority_epoch
             )

    assert {:error, :mcp_authorization_required} =
             TokenManager.authorization_header(
               replacement_manager,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :ok = TokenManager.close(replacement_manager)
    assert :ok = RunState.close(state)
    fixture.close.()
  end

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
    refute Map.has_key?(snapshot, "launcher_protocol_version")
    refute Map.has_key?(snapshot, "launcher_sha256")
    refute Map.has_key?(snapshot, "server_executable_sha256")

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
  test "rejects a cache-scope change across catalog pages", %{tmp_dir: dir} do
    fixture = fixture(self(), second_page_cache_scope: "public")
    on_exit(fixture.close)

    assert {:error, :mcp_invalid_catalog} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(fixture.endpoint))
  end

  @tag :tmp_dir
  test "bounded tool-error feedback is recoverable while canonical events stay closed", %{
    tmp_dir: dir
  } do
    feedback = "unknown path; retry with x"
    fixture = fixture(self(), error_text: feedback, recoverable_error?: true)
    on_exit(fixture.close)

    tools =
      Map.update!(mappings(), "fail", fn mapping ->
        Map.put(mapping, :error_feedback, :bounded)
      end)

    program =
      ~S|(let [first (tool/remote.fail {"query" "bad"}) second (if (= "unknown path; retry with x" (get first :details)) (tool/remote.fail {"query" "x"}) first)] (return {"first" first "second" second}))|

    {:ok, built} =
      dir
      |> manifest(["remote.fail"], program: program)
      |> RunBuilder.load_and_build(registry(fixture.endpoint, tools: tools))

    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :domain_error,
             details: ^feedback,
             retryable?: false
           } = get_in(result.value, [:value, :value, "first"])

    assert %{status: :ok, value: %{"text" => ["recovered"]}} =
             get_in(result.value, [:value, :value, "second"])

    events = EventSink.events(built.config.event_sink)
    refute inspect(events) =~ feedback

    EventSink.stop(built.config.event_sink)
  end

  @tag :tmp_dir
  test "private inspection captures correlated MCP bodies and safe trace context", %{
    tmp_dir: dir
  } do
    fixture = fixture(self(), capture_body?: true)
    on_exit(fixture.close)

    inspection_path = Path.join(dir, "mcp.inspection.jsonl")
    trace_path = Path.join(dir, "mcp.trace.jsonl")
    manifest_path = manifest(dir, Map.keys(public_mappings()))

    assert {:ok, _result} =
             RunBuilder.run(manifest_path, registry(fixture.endpoint),
               inspect: inspection_path,
               trace: trace_path
             )

    assert_receive {:mcp_body, "tools/call", request_body}

    assert get_in(request_body, ["params", "_meta", "traceparent"]) =~
             ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-01\z/

    assert {:ok, records} = InspectionArtifact.load(inspection_path)

    requests = Enum.filter(records, &(&1["record_type"] == "mcp-request"))
    responses = Enum.filter(records, &(&1["record_type"] == "mcp-response"))
    assert length(requests) == 3
    assert length(responses) == 3

    assert Enum.map(requests, & &1["correlation"]) |> MapSet.new() ==
             Enum.map(responses, & &1["correlation"]) |> MapSet.new()

    assert Enum.all?(requests ++ responses, &(&1["schema_version"] == 2))

    encoded_inspection = File.read!(inspection_path)
    refute encoded_inspection =~ "Bearer fixture-secret"

    encoded_trace = File.read!(trace_path)
    refute encoded_trace =~ ~s("arguments")
    refute encoded_trace =~ ~s("structuredContent")
    refute encoded_trace =~ "Bearer fixture-secret"
  end

  @tag :tmp_dir
  test "the common MCP source discovers and calls the same tools over stdio", %{tmp_dir: dir} do
    marker = Path.join(dir, "stdio-methods")
    fixture = fixture(self())
    on_exit(fixture.close)

    http_registry = registry(fixture.endpoint, timeout_ms: 5_000)
    stdio_registry = stdio_registry(dir, marker)

    manifest =
      manifest(dir, ~w(remote.structured remote.text remote.fail),
        timeout_ms: 5_000,
        evaluation_timeout_ms: 5_000
      )

    assert {:ok, http_built} = RunBuilder.load_and_build(manifest, http_registry)
    assert {:ok, built} = RunBuilder.load_and_build(manifest, stdio_registry)

    assert capability_contracts(http_built) == capability_contracts(built)

    assert [http_snapshot] = http_built.config.connector_snapshots
    assert [snapshot] = built.config.connector_snapshots
    assert common_snapshot(http_snapshot) == common_snapshot(snapshot)
    assert snapshot["provider"] == "fixture-mcp"
    assert snapshot["protocol"] == "mcp-2026-07-28"
    assert snapshot["transport"] == "stdio"
    assert snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert snapshot["server_info_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert snapshot["launcher_protocol_version"] == 1
    {:ok, launcher} = PtcRunnerLauncher.executable_path()
    assert snapshot["launcher_sha256"] == file_sha256(launcher)
    assert snapshot["server_executable_sha256"] == file_sha256(System.find_executable("sh"))

    assert Enum.map(snapshot["tools"], & &1["name"]) ==
             ~w(remote.fail remote.structured remote.text)

    assert Enum.all?(snapshot["tools"], &is_nil(&1["http_headers_hash"]))

    assert :ok = RunBuilder.close(http_built)
    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{
             status: :ok,
             value: %{
               outcome: :returned,
               value: %{
                 "failed" => %{kind: :provider_error, reason: :domain_error, status: :error},
                 "structured" => %{status: :ok, value: %{"value" => 42}},
                 "text" => %{status: :ok, value: %{"text" => ["hello"]}}
               }
             }
           } = result.value

    assert :ok = RunBuilder.close(built)

    assert marker
           |> File.read!()
           |> String.split("\n", trim: true)
           |> Enum.map(fn line ->
             [id, method] = String.split(line, ":", parts: 2)
             {String.to_integer(id), method}
           end)
           |> Enum.sort() ==
             [
               {1, "server/discover"},
               {2, "tools/list"},
               {3, "tools/list"},
               {4, "tools/call"},
               {5, "tools/call"},
               {6, "tools/call"}
             ]
  end

  @tag :tmp_dir
  test "the local stdio fixture executes an explicitly selected write mapping", %{tmp_dir: dir} do
    marker = Path.join(dir, "stdio-write-methods")
    tools = mappings_with_effect("structured", :write)
    registry = stdio_registry(dir, marker, nil, tools: tools)

    assert {:ok, built} =
             dir
             |> manifest(["remote.structured"],
               program: single_call_program("remote.structured", "x"),
               timeout_ms: 5_000,
               evaluation_timeout_ms: 5_000
             )
             |> RunBuilder.load_and_build(registry)

    assert %Capability{effect: :write} =
             built.config.mission_environment.capabilities["remote.structured"]

    assert [%{"name" => "remote.structured", "effect" => "write"}] =
             built.config.connector_snapshots |> hd() |> Map.fetch!("tools")

    assert {:ok, result} = Kernel.run(built.entry_source, built.config)
    assert %{status: :ok, value: %{"value" => 42}} = get_in(result.value, [:value, :value])
    assert :ok = RunBuilder.close(built)
    assert File.read!(marker) =~ "tools/call"
  end

  @tag :tmp_dir
  test "both transports measure the selected ceiling on the decoded MCP result", %{tmp_dir: dir} do
    empty_result = %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => ""}]
    }

    assert {:ok, encoded_empty_result} = DeterministicJSON.encode(empty_result)
    text_bytes = @max_logical_result_bytes - byte_size(encoded_empty_result)
    text = String.duplicate("x", text_bytes)

    mcp_result = %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => text}]
    }

    assert {:ok, encoded_result} = DeterministicJSON.encode(mcp_result)
    assert byte_size(encoded_result) == @max_logical_result_bytes

    wire_response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => mcp_result})

    assert byte_size(wire_response) > @max_logical_result_bytes

    fixture = fixture(self(), text_bytes: text_bytes)
    on_exit(fixture.close)

    marker = Path.join(dir, "stdio-logical-result-ceiling")

    registries = [
      registry(fixture.endpoint,
        timeout_ms: 5_000,
        max_result_bytes: @max_logical_result_bytes
      ),
      stdio_registry(dir, marker, "text-logical-max", max_result_bytes: @max_logical_result_bytes)
    ]

    {:ok, installed_limits} =
      Limits.installed_defaults()
      |> Map.from_struct()
      |> Map.merge(%{
        capability_result_bytes: 1_200_000,
        event_payload_bytes: 1_200_000,
        terminal_result_bytes: 1_200_000
      })
      |> Limits.new()

    run_limits = %{
      "capability_result_bytes" => 1_200_000,
      "event_payload_bytes" => 1_200_000,
      "terminal_result_bytes" => 1_200_000
    }

    for {max_result_bytes, expected_status} <- [
          {@max_logical_result_bytes, :ok},
          {@max_logical_result_bytes - 1, :error}
        ],
        registry <- registries do
      manifest =
        manifest(dir, ~w(remote.structured remote.text remote.fail),
          timeout_ms: 5_000,
          evaluation_timeout_ms: 5_000,
          max_result_bytes: max_result_bytes,
          limits: run_limits
        )

      assert {:ok, built} =
               RunBuilder.load_and_build(manifest, registry, installed_limits: installed_limits)

      assert {:ok, result} = Kernel.run(built.entry_source, built.config)

      case expected_status do
        :ok ->
          assert %{status: :ok, value: %{"text" => [returned_text]}} =
                   get_in(result.value, [:value, :value, "text"])

          assert returned_text == text

        :error ->
          assert %{status: :error, reason: :invalid_result} =
                   get_in(result.value, [:value, :value, "text"])
      end

      assert :ok = RunBuilder.close(built)
    end
  end

  @tag :tmp_dir
  test "a launcher symlink is frozen before its digest and process identity", %{tmp_dir: dir} do
    marker = Path.join(dir, "stdio-symlink-methods")
    trusted_tree = Path.join(dir, "trusted")
    replacement_tree = Path.join(dir, "replacement")
    launcher_parent = Path.join(dir, "launcher-parent")
    configured_launcher = Path.join([launcher_parent, "..", "launcher"])
    {:ok, launcher} = PtcRunnerLauncher.executable_path()

    for tree <- [trusted_tree, replacement_tree] do
      File.mkdir_p!(Path.join(tree, "nested"))
    end

    File.ln_s!(launcher, Path.join(trusted_tree, "launcher"))
    File.ln_s!(@stdio_fixture, Path.join(replacement_tree, "launcher"))
    File.ln_s!(Path.join(trusted_tree, "nested"), launcher_parent)

    builder =
      MCPSource.builder(
        transport:
          {:stdio,
           marker
           |> stdio_transport_options()
           |> Keyword.put(:launcher, configured_launcher)},
        tools: mappings(),
        timeout_ms: 5_000,
        max_result_bytes: 64_000
      )

    File.rm!(launcher_parent)
    File.ln_s!(Path.join(replacement_tree, "nested"), launcher_parent)

    {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})

    assert {:ok, built} =
             dir
             |> manifest(~w(remote.structured), timeout_ms: 5_000, evaluation_timeout_ms: 5_000)
             |> RunBuilder.load_and_build(registry)

    assert [snapshot] = built.config.connector_snapshots
    assert snapshot["launcher_sha256"] == file_sha256(launcher)
    assert {:ok, _result} = Kernel.run(built.entry_source, built.config)
    assert :ok = RunBuilder.close(built)
  end

  @tag :tmp_dir
  test "a verified server exit remains an operational result rather than a cleanup failure", %{
    tmp_dir: dir
  } do
    for mode <- ["exit-before-response", "exit-after-response"] do
      marker = Path.join(dir, mode)
      registry = stdio_registry(dir, marker, mode)

      manifest =
        manifest(dir, ~w(remote.structured remote.text remote.fail),
          timeout_ms: 5_000,
          evaluation_timeout_ms: 5_000
        )

      assert {:ok, built} = RunBuilder.load_and_build(manifest, registry)
      assert {:ok, result} = Kernel.run(built.entry_source, built.config)

      assert %{
               status: :ok,
               value: %{
                 outcome: :returned,
                 value: %{
                   "structured" => structured,
                   "text" => %{
                     status: :error,
                     reason: :transport_error,
                     retryable?: false
                   },
                   "failed" => %{
                     status: :error,
                     reason: :transport_error,
                     retryable?: false
                   }
                 }
               }
             } = result.value

      case mode do
        "exit-before-response" ->
          assert %{status: :error, reason: :transport_error, retryable?: false} = structured

        "exit-after-response" ->
          assert %{status: :ok, value: %{"value" => 42}} = structured
      end

      assert :ok = RunBuilder.close(built)
    end
  end

  @tag :tmp_dir
  test "normalizes a stdio server exit between discovery requests", %{tmp_dir: dir} do
    marker = Path.join(dir, "exit-after-discover")
    registry = stdio_registry(dir, marker, "exit-after-discover")

    assert {:error, :mcp_transport_error} =
             dir
             |> manifest(~w(remote.structured),
               timeout_ms: 5_000,
               evaluation_timeout_ms: 5_000
             )
             |> RunBuilder.load_and_build(registry)

    assert marker
           |> File.read!()
           |> String.split("\n", trim: true)
           |> Enum.map(&String.split(&1, ":", parts: 2))
           |> Enum.map(&List.last/1) == ["server/discover"]
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
  test "operator write effects reach capabilities, snapshots, and wrapper inventory unchanged", %{
    tmp_dir: dir
  } do
    fixture = fixture(self(), spec_extras?: true)
    on_exit(fixture.close)

    tools =
      Map.put(
        mappings(),
        "structured",
        %{as: "remote.structured", effect: :write}
      )

    mission_source = """
    (ns actions "Write facade" {:visibility :prompt})
    (defn save {:signature "(query :string) -> :any" :effect :read}
      [query]
      (tool/remote.structured {"query" query}))
    """

    assert {:ok, built} =
             dir
             |> manifest(["remote.structured"],
               mission_source: mission_source,
               program: single_call_program("remote.structured", "x")
             )
             |> RunBuilder.load_and_build(registry(fixture.endpoint, tools: tools))

    assert %Capability{effect: :write} =
             built.config.mission_environment.capabilities["remote.structured"]

    assert [%{"name" => "remote.structured", "effect" => "write"} = snapshot_tool] =
             built.config.connector_snapshots |> hd() |> Map.fetch!("tools")

    refute Map.has_key?(snapshot_tool, "annotations")

    inventory = Jason.decode!(built.config.mission_inventory.rendered)
    assert [%{"ref" => "actions/save", "effect" => "write"}] = inventory["exports"]

    model_inventory = Jason.decode!(built.config.mission_inventory.model_rendered)

    assert %{"effect" => "write"} =
             Enum.find(model_inventory["entries"], &(&1["form"] == "(actions/save query)"))

    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{status: :ok, value: %{"value" => 42}} = get_in(result.value, [:value, :value])

    assert :ok = RunBuilder.close(built)
  end

  @tag :tmp_dir
  test "write-bearing direct sources require explicit allow while read-only omission stays convenient",
       %{tmp_dir: dir} do
    fixture = fixture(self())
    on_exit(fixture.close)

    write_tools =
      Map.put(
        mappings(),
        "structured",
        %{as: "remote.structured", effect: :write}
      )

    assert {:error, :invalid_mcp_selection} =
             dir
             |> manifest(["remote.structured"], omit_allow?: true)
             |> RunBuilder.load_and_build(registry(fixture.endpoint, tools: write_tools))

    refute_receive {:mcp_request, _method, _headers}

    assert {:ok, built} =
             dir
             |> manifest(["remote.structured"], omit_allow?: true)
             |> RunBuilder.load_and_build(registry(fixture.endpoint))

    assert :ok = RunBuilder.close(built)
  end

  test "direct sources reject write snapshot identities before any authority-bearing activity" do
    parent = self()

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport:
          {:streamable_http,
           endpoint: "https://example.test/mcp",
           headers: fn ->
             send(parent, :unexpected_credential_resolution)
             []
           end},
        tools: %{"write" => %{as: "remote.write", effect: :write}},
        snapshot_identity: %{tool: "write", field: "digest"}
      )
    end

    refute_receive :unexpected_credential_resolution
  end

  test "direct sources reject workflow placement before authority-bearing activity" do
    parent = self()

    builder =
      MCPSource.builder(
        transport:
          {:streamable_http,
           endpoint: "https://example.test/mcp",
           headers: fn ->
             send(parent, :unexpected_credential_resolution)
             []
           end},
        tools: %{"write" => %{as: "remote.write", effect: :write}}
      )

    {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})
    {:ok, limits} = Limits.new()

    assert {:error, :invalid_mcp_selection} =
             ProviderRegistry.build(
               registry,
               "fixture-mcp",
               %{"allow" => ["remote.write"]},
               %{
                 directory: File.cwd!(),
                 destination: :workflow,
                 limits: limits,
                 owner: self()
               }
             )

    refute_receive :unexpected_credential_resolution
  end

  @tag :tmp_dir
  test "post-dispatch MCP failures preserve their cause and make writes indeterminate", %{
    tmp_dir: dir
  } do
    cases = [
      {"structured", [rpc_error_tool: "structured"], :domain_error, "mcp_remote_error", []},
      {"structured", [structured_value: "wrong"], :invalid_result, "mcp_invalid_result", []},
      {"structured", [result_and_error?: true], :invalid_result, "mcp_protocol_error", []},
      {"structured", [structured_result: input_required_state_only()], :denied,
       "mcp_input_required_refused", []},
      {"structured",
       [
         structured_result: %{
           "resultType" => "input_required",
           "inputRequests" => %{},
           "requestState" => "load-shed"
         }
       ], :denied, "mcp_input_required_refused", []},
      {"structured",
       [structured_result: %{"resultType" => "input_required", "inputRequests" => %{}}],
       :invalid_result, "mcp_protocol_error", []},
      {"structured", [structured_result: input_required_with_requests()], :invalid_result,
       "mcp_capability_negotiation_error", []},
      {"structured", [structured_result: %{"resultType" => "input_required"}], :invalid_result,
       "mcp_protocol_error", []},
      {"fail", [], :domain_error, "mcp_domain_error", []},
      {"text", [large_text?: true], :invalid_result, "mcp_response_exceeded",
       [max_result_bytes: 1_000]}
    ]

    for effect <- [:read, :write],
        {upstream, fixture_opts, reason, details, manifest_opts} <- cases do
      fixture = fixture(self(), fixture_opts)
      on_exit(fixture.close)
      tools = mappings_with_effect(upstream, effect)
      public_name = tools[upstream].as

      assert {:ok, built} =
               dir
               |> manifest(
                 [public_name],
                 [
                   program: single_call_program(public_name, "x"),
                   evaluation_timeout_ms: 5_000
                 ] ++ manifest_opts
               )
               |> RunBuilder.load_and_build(
                 registry(fixture.endpoint,
                   tools: tools,
                   timeout_ms: 5_000
                 )
               )

      assert {:ok, result} = Kernel.run(built.entry_source, built.config)
      failure = get_in(result.value, [:value, :value])

      assert %{
               status: :error,
               kind: :provider_error,
               reason: ^reason,
               details: ^details,
               retryable?: false
             } = failure

      assert_effect_state(failure, effect)
      assert :ok = RunBuilder.close(built)
    end
  end

  test "agent correction does not repeat any MCP input-required classification" do
    programs = [
      {~S|(fail (tool/remote.structured {"query" "x"}))|, [evaluation_timeout_ms: 5_000]},
      {~S|(do (tool/remote.structured {"query" "x"}) (+ {} 1))|, [evaluation_timeout_ms: 5_000]},
      {~S|(do (tool/remote.structured {"query" "x"}) (reduce + (range 0 100000000)))|,
       [evaluation_timeout_ms: 500, evaluation_heap_words: 100_000_000]}
    ]

    for structured_result <- [
          input_required_state_only(),
          input_required_with_requests(),
          %{"resultType" => "input_required"}
        ],
        {program, limit_overrides} <- programs do
      parent = self()
      fixture = fixture(parent, structured_result: structured_result)
      on_exit(fixture.close)

      {:ok, limits} = Limits.new(limit_overrides)
      evaluation_timeout_ms = limits.evaluation_timeout_ms

      assert {:ok, mcp} =
               ProviderRegistry.build(
                 registry(fixture.endpoint),
                 "fixture-mcp",
                 %{
                   "allow" => ["remote.structured"],
                   "timeout_ms" => min(evaluation_timeout_ms, 2_000),
                   "max_result_bytes" => 32_000
                 },
                 %{
                   directory: File.cwd!(),
                   destination: :mission,
                   limits: limits,
                   installed_limits: limits,
                   owner: self()
                 }
               )

      assert_receive {:mcp_request, "server/discover", _headers}
      assert_receive {:mcp_request, "tools/list", _headers}
      assert_receive {:mcp_request, "tools/list", _headers}

      first = %{
        content: nil,
        tool_calls: [
          %{
            id: "mcp-refusal",
            name: "run_ptc_lisp",
            args: %{"program" => program}
          }
        ]
      }

      recovered = %{
        content: nil,
        tool_calls: [
          %{id: "unexpected-retry", name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}
        ]
      }

      {:ok, responses} = Agent.start_link(fn -> [first, recovered] end)

      {:ok, llm} =
        LLMCapability.new(
          requester: fn request ->
            send(parent, {:agent_request, request})

            Agent.get_and_update(responses, fn
              [response | rest] -> {{:ok, response}, rest}
              [] -> {{:error, :script_exhausted}, []}
            end)
          end
        )

      {:ok, components} =
        Library.components(~w(agent.core agent.feedback agent.native agent.prompt agent.retry
             kernel llm result workflow.event))

      {:ok, bundle} = Kernel.compile_bundle(components)
      {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm])
      {:ok, mission} = MissionEnvironment.new(capabilities: mcp.capabilities)
      {:ok, sink} = EventSink.start(:normal, limits, run_id: "mcp-mrtr-agent-refusal")

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
          input: %{},
          limits: limits,
          event_sink: sink,
          provider_resources: [mcp.close]
        )

      assert {:error, %{kind: :workflow_failed, reason: :explicit_failure}} =
               Kernel.run(~S|(agent.core/run "Read once" {"max_turns" 3})|, config)

      assert_receive {:agent_request, _first}
      refute_receive {:agent_request, _second}
      assert_receive {:mcp_request, "tools/call", _headers}
      refute_receive {:mcp_request, "tools/call", _headers}
    end
  end

  @tag :tmp_dir
  test "MCP timeout and transport loss remain retryable reads but indeterminate writes", %{
    tmp_dir: dir
  } do
    for effect <- [:read, :write],
        {fixture_opts, reason} <- [
          {[block_tool: "structured"], :timeout},
          {[disconnect_tool: "structured"], :transport_error}
        ] do
      fixture = fixture(self(), fixture_opts)
      on_exit(fixture.close)
      tools = mappings_with_effect("structured", effect)

      assert {:ok, built} =
               dir
               |> manifest(["remote.structured"],
                 program: single_call_program("remote.structured", "x"),
                 timeout_ms: 100,
                 evaluation_timeout_ms: 2_000
               )
               |> RunBuilder.load_and_build(
                 registry(fixture.endpoint, tools: tools, timeout_ms: 100)
               )

      assert {:ok, result} = Kernel.run(built.entry_source, built.config)
      failure = get_in(result.value, [:value, :value])

      assert %{status: :error, kind: :provider_error, reason: ^reason} = failure

      if reason == :timeout do
        assert_receive {:mcp_blocked, worker}
        send(worker, :release)
      end

      if effect == :read do
        assert failure.retryable?
        refute Map.has_key?(failure, :mutation_state)
      else
        refute failure.retryable?
        assert failure.mutation_state == :indeterminate
      end

      assert :ok = RunBuilder.close(built)
    end
  end

  @tag :tmp_dir
  test "write parameter, outbound-header, and closed-context failures prove no dispatch", %{
    tmp_dir: dir
  } do
    tools = mappings_with_effect("structured", :write)

    for {query, registry_opts} <- [
          {String.duplicate("x", 20_000), []},
          {
            String.duplicate("x", 16_365),
            [headers: fn -> [{"authorization", String.duplicate("a", 16_367)}] end]
          }
        ] do
      fixture = fixture(self())
      on_exit(fixture.close)

      assert {:ok, built} =
               dir
               |> manifest(["remote.structured"],
                 program: single_call_program("remote.structured", query),
                 evaluation_timeout_ms: 5_000
               )
               |> RunBuilder.load_and_build(
                 registry(fixture.endpoint, [tools: tools] ++ registry_opts)
               )

      assert_receive {:mcp_request, "server/discover", _headers}
      assert_receive {:mcp_request, "tools/list", _headers}
      assert_receive {:mcp_request, "tools/list", _headers}

      assert {:ok, result} = Kernel.run(built.entry_source, built.config)
      failure = get_in(result.value, [:value, :value])

      assert %{
               status: :error,
               kind: :provider_error,
               reason: :invalid_result,
               retryable?: false
             } = failure

      refute Map.has_key?(failure, :mutation_state)
      refute_receive {:mcp_request, "tools/call", _headers}
      assert :ok = RunBuilder.close(built)
    end

    fixture = fixture(self())
    on_exit(fixture.close)

    assert {:ok, built} =
             dir
             |> manifest(["remote.structured"],
               program: single_call_program("remote.structured", "x")
             )
             |> RunBuilder.load_and_build(registry(fixture.endpoint, tools: tools))

    capability = built.config.mission_environment.capabilities["remote.structured"]
    assert :ok = RunBuilder.close(built)
    {:ok, state} = RunState.start(Limits.defaults())

    failure =
      Dispatcher.dispatch(
        state,
        :mission,
        %{capabilities: %{capability.name => capability}},
        capability.name,
        %{"query" => "x"},
        1_000
      )

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :transport_error,
             details: "mcp_transport_closed",
             retryable?: false
           } = failure

    refute Map.has_key?(failure, :mutation_state)
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
  test "snapshot identity attests selected timeout and result ceilings", %{tmp_dir: dir} do
    fixture = fixture(self())
    on_exit(fixture.close)
    registry = registry(fixture.endpoint)

    {:ok, first} =
      dir
      |> manifest(["remote.structured"], timeout_ms: 900, max_result_bytes: 31_000)
      |> RunBuilder.load_and_build(registry)

    [first_snapshot] = first.config.connector_snapshots
    assert first_snapshot["timeout_ms"] == 900
    assert first_snapshot["max_result_bytes"] == 31_000
    assert :ok = RunBuilder.close(first)

    {:ok, second} =
      dir
      |> manifest(["remote.structured"], timeout_ms: 800, max_result_bytes: 30_000)
      |> RunBuilder.load_and_build(registry)

    [second_snapshot] = second.config.connector_snapshots
    assert second_snapshot["timeout_ms"] == 800
    assert second_snapshot["max_result_bytes"] == 30_000
    assert second_snapshot["snapshot_hash"] != first_snapshot["snapshot_hash"]
    assert :ok = RunBuilder.close(second)
  end

  @tag :tmp_dir
  test "a closed request context produces a terminal provider error", %{tmp_dir: dir} do
    fixture = fixture(self())
    on_exit(fixture.close)

    {:ok, built} =
      dir
      |> manifest(["remote.structured"])
      |> RunBuilder.load_and_build(registry(fixture.endpoint))

    capability = built.config.mission_environment.capabilities["remote.structured"]
    assert :ok = RunBuilder.close(built)

    assert {:error,
            %{
              kind: :transport_error,
              details: "mcp_transport_closed",
              retryable?: false
            }} = capability.callback.(%{"query" => "x"}, nil)
  end

  @tag :tmp_dir
  test "rejects unknown modern result types", %{tmp_dir: dir} do
    parent = self()
    fixture = fixture(parent, result_type: "future")
    on_exit(fixture.close)

    registry = registry(fixture.endpoint)
    manifest = manifest(dir, Map.keys(public_mappings()))

    {:ok, built} = RunBuilder.load_and_build(manifest, registry)
    assert {:ok, result} = Kernel.run(built.entry_source, built.config)

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :invalid_result,
             details: "mcp_unsupported_result"
           } = get_in(result.value, [:value, :value, "structured"])

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
      MCPSource.builder(
        transport: {:streamable_http, endpoint: "http://example.com/mcp"},
        tools: mappings()
      )
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(endpoint: "https://example.com/mcp", tools: mappings())
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport: {:streamable_http, endpoint: "https://example.com/mcp"},
        transport: {:streamable_http, endpoint: "https://example.net/mcp"},
        tools: mappings()
      )
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport:
          {:streamable_http, endpoint: "https://example.com/mcp", allow_insecure_loopback: :yes},
        tools: mappings()
      )
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport:
          {:streamable_http, endpoint: "https://example.com/mcp", command: "/inapplicable"},
        tools: mappings()
      )
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport: {:streamable_http, endpoint: "https://example.com/mcp"},
        tools: %{
          "one" => %{as: "same", effect: :read},
          "two" => %{as: "same", effect: :read}
        }
      )
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport: {:streamable_http, endpoint: "https://example.com/mcp"},
        tools: %{"one" => %{as: "remote.one", effect: :unknown}}
      )
    end
  end

  test "installation enforces transport timeout and shared response ceilings" do
    options = stdio_transport_options("/tmp/unused")

    assert is_function(
             MCPSource.builder(
               transport: {:stdio, options},
               tools: mappings(),
               timeout_ms: 300_000,
               max_result_bytes: 1_048_576
             ),
             2
           )

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport: {:stdio, options},
        tools: mappings(),
        timeout_ms: 300_001
      )
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport: {:stdio, options},
        tools: mappings(),
        max_result_bytes: 1_048_577
      )
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport: {:streamable_http, endpoint: "https://example.com/mcp"},
        tools: mappings(),
        max_result_bytes: 1_048_577
      )
    end

    assert_raise ArgumentError, fn ->
      MCPSource.builder(
        transport: {:stdio, options ++ [launcher: "/duplicate", launcher: "/duplicate"]},
        tools: mappings()
      )
    end
  end

  @tag :tmp_dir
  test "stdio acquisition rejects an oversized launcher before spawning", %{tmp_dir: dir} do
    launcher = Path.join(dir, "oversized-launcher")
    {:ok, device} = File.open(launcher, [:write, :binary])
    {:ok, _position} = :file.position(device, 16_777_216)
    :ok = IO.binwrite(device, <<0>>)
    :ok = File.close(device)
    :ok = File.chmod(launcher, 0o755)

    executable = System.find_executable("sh")

    builder =
      MCPSource.builder(
        transport:
          {:stdio,
           launcher: launcher,
           executable: executable,
           executable_sha256: executable |> File.read!() |> then(&:crypto.hash(:sha256, &1)),
           cwd: @root,
           args: [@stdio_fixture, Path.join(dir, "unused")],
           env: inherited_environment()},
        tools: mappings()
      )

    {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})

    assert {:error, :mcp_transport_error} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry)
  end

  test "stdio rollback cleanup failure overrides the acquisition error" do
    transport = make_ref()

    assert {:error, :mcp_transport_error} =
             MCPSource.rollback_acquisition(
               {:ok, transport},
               :mcp_timeout,
               fn ^transport -> {:error, :mcp_transport_error} end
             )
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

    protocol_error = fixture(parent, rpc_error_tool: "structured", rpc_error_status: 400)

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

    repeated_chunked = fixture(parent, sse?: true, sse_extra_response?: true, sse_chunked?: true)

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

    split_tail = fixture(parent, sse?: true, sse_trailing_bytes: 1_100_000, sse_chunked?: true)

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
    sink_pid = abandoned.config.event_sink.pid
    sink_ref = Process.monitor(sink_pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, @owner_lifecycle_timeout_ms

    assert_receive {:DOWN, ^sink_ref, :process, _sink_pid, sink_reason},
                   @owner_lifecycle_timeout_ms

    # Monitoring can race with the owner-linked sink's normal shutdown. A
    # monitor installed after that shutdown correctly reports :noproc.
    assert sink_reason in [:normal, :noproc]
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
        transport:
          {:streamable_http,
           endpoint: invalid_output.endpoint,
           allow_insecure_loopback: true,
           headers: fn -> raise secret end},
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
        transport:
          {:streamable_http,
           endpoint: invalid_output.endpoint,
           allow_insecure_loopback: true,
           headers: fn ->
             send(parent, {:mcp_header_blocked, self()})

             receive do
               :never -> []
             end
           end},
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
        transport:
          {:streamable_http,
           endpoint: endpoint,
           allow_insecure_loopback: true,
           headers:
             Keyword.get(
               opts,
               :headers,
               fn -> [{"authorization", "Bearer fixture-secret"}] end
             )},
        tools: Keyword.get(opts, :tools, mappings()),
        timeout_ms: Keyword.get(opts, :timeout_ms, 2_000),
        max_result_bytes: Keyword.get(opts, :max_result_bytes, 64_000),
        max_pages: Keyword.get(opts, :max_pages, 16)
      )

    {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})
    registry
  end

  defp oauth_manager(endpoint, interceptor) do
    uri = URI.parse(endpoint)
    private_origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"

    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "source-test",
          "issuer" => endpoint,
          "scope_ceiling" => ["read", "write"],
          "default_scopes" => ["read"],
          "network" => %{
            "additional_origins" => [],
            "private_network_origins" => [private_origin]
          },
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        },
        endpoint,
        MapSet.new(),
        allow_insecure_loopback: true
      )

    {:ok, memory} = Memory.start_link(owner: self())
    {:ok, store} = Memory.store(memory)
    {:ok, context} = OAuthContext.new(tenant_id: "tenant", principal_id: "alice", store: store)

    {:ok, claims} =
      Store.claim_authorities(
        store,
        context.tenant_id,
        [{authority.installation_id, authority.fingerprint}],
        1_000
      )

    epoch = claims[authority.installation_id]
    key = OAuthContext.grant_key(context, authority, epoch)
    {:ok, anchor} = Store.time_anchor(store, 1_000)
    {:ok, lease} = Store.acquire_mutation(store, key, :authorization, 5_000, 1_000)

    :ok =
      Store.begin_mutation_dispatch(
        store,
        key,
        lease.fence,
        %{freshness_anchor: anchor, freshness_anchor_ttl_ms: 5_000},
        1_000
      )

    {:ok, _grant} =
      Store.commit_grant(
        store,
        key,
        lease.fence,
        %{
          access_token: "access",
          requested_scopes: MapSet.new(["read"]),
          granted_scopes: MapSet.new(["read"]),
          refresh_authorized: false,
          redirect_uri: "http://127.0.0.1:49152/callback",
          metadata_revision: 1,
          metadata_binding: nil
        },
        60_000,
        anchor,
        1_000
      )

    {:ok, recording_store} =
      MCPOAuthRecordingStore.wrap(store, self(), interceptor: interceptor)

    {:ok, wrapped_context} =
      OAuthContext.new(
        tenant_id: context.tenant_id,
        principal_id: context.principal_id,
        store: recording_store
      )

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: wrapped_context,
        authority: authority,
        authority_epoch: epoch
      )

    manager
  end

  defp stdio_registry(_dir, marker, mode \\ nil, opts \\ []) do
    builder =
      MCPSource.builder(
        transport: {:stdio, stdio_transport_options(marker, mode)},
        tools: Keyword.get(opts, :tools, mappings()),
        timeout_ms: 5_000,
        max_result_bytes: Keyword.get(opts, :max_result_bytes, 64_000)
      )

    {:ok, registry} = ProviderRegistry.new(%{"fixture-mcp" => builder})
    registry
  end

  defp stdio_transport_options(marker, mode \\ nil) do
    executable = System.find_executable("sh")
    args = [@stdio_fixture, marker] ++ if(mode, do: [mode], else: [])

    [
      executable: executable,
      executable_sha256: executable |> File.read!() |> then(&:crypto.hash(:sha256, &1)),
      cwd: @root,
      args: args,
      env: inherited_environment(),
      grace_ms: 50,
      start_timeout_ms: 5_000
    ]
  end

  defp inherited_environment do
    @inherited_environment
    |> Enum.flat_map(fn name ->
      case System.get_env(name) do
        value when is_binary(value) -> [{name, value}]
        _missing -> []
      end
    end)
    |> Map.new()
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp capability_contracts(built) do
    built.config.mission_environment.capabilities
    |> Map.values()
    |> Enum.map(&Capability.metadata/1)
    |> Enum.sort_by(& &1.name)
  end

  defp common_snapshot(snapshot) do
    snapshot
    |> Map.drop([
      "transport",
      "snapshot_hash",
      "launcher_protocol_version",
      "launcher_sha256",
      "server_executable_sha256"
    ])
    |> Map.update!("tools", fn tools ->
      Enum.map(tools, &Map.drop(&1, ["http_headers_hash"]))
    end)
  end

  defp mappings do
    %{
      "structured" => %{as: "remote.structured", effect: :read},
      "text" => %{as: "remote.text", effect: :read},
      "fail" => %{as: "remote.fail", effect: :read}
    }
  end

  defp mappings_with_effect(upstream, effect) do
    Map.update!(mappings(), upstream, &Map.put(&1, :effect, effect))
  end

  defp single_call_program(public_name, query) do
    ~s|(return (tool/#{public_name} {"query" #{Jason.encode!(query)}}))|
  end

  defp assert_effect_state(failure, :read),
    do: refute(Map.has_key?(failure, :mutation_state))

  defp assert_effect_state(failure, :write),
    do: assert(failure.mutation_state == :indeterminate)

  defp input_required_state_only do
    %{
      "resultType" => "input_required",
      "requestState" => "eyJwcm9ncmVzcyI6IjUwJSJ9"
    }
  end

  defp input_required_with_requests do
    %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "github_login" => %{
          "method" => "elicitation/create",
          "params" => %{
            "message" => "Please provide your GitHub username",
            "requestedSchema" => %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}},
              "required" => ["name"]
            }
          }
        }
      }
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
    opts = Keyword.put(opts, :observer, parent)

    MCPHTTPFixture.start(fn request ->
      method = request.body["method"]
      send(parent, {:mcp_request, method, request.headers})
      if opts[:capture_body?], do: send(parent, {:mcp_body, method, request.body})

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

      disconnect_tool = get_in(request.body, ["params", "name"])

      if (opts[:disconnect?] && method == "server/discover") ||
           (method == "tools/call" && opts[:disconnect_tool] == disconnect_tool) do
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
      Map.drop(metadata, ["traceparent"]) == %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientInfo" => %{"name" => "ptc_runner", "version" => "0.x"},
        "io.modelcontextprotocol/clientCapabilities" => %{}
      } and valid_traceparent?(metadata["traceparent"], method) and
      case method do
        "tools/call" ->
          request.headers["mcp-name"] == name and
            request.headers["mcp-param-query"] == arguments["query"]

        _method ->
          not Map.has_key?(request.headers, "mcp-name")
      end
  end

  defp valid_traceparent?(nil, method), do: method != "tools/call"

  defp valid_traceparent?(traceparent, "tools/call") when is_binary(traceparent),
    do: traceparent =~ ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-01\z/

  defp valid_traceparent?(_traceparent, _method), do: false

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
        "cacheScope" => Keyword.get(opts, :second_page_cache_scope, "private")
      })
    end
  end

  defp response(
         %{body: %{"method" => "tools/call", "id" => id, "params" => params}},
         opts
       ) do
    case opts[:tool_http_error] do
      {:status_only, status} ->
        send(Keyword.fetch!(opts, :observer), {:fixture_tool_http_error, status})
        {:status_only, status}

      {status, headers} ->
        send(Keyword.fetch!(opts, :observer), {:fixture_tool_http_error, status})
        {status, headers, ""}

      {:headers_only, status, headers} ->
        send(Keyword.fetch!(opts, :observer), {:fixture_tool_http_error, status})
        {:headers_only, status, headers}

      {status, headers, body} ->
        send(Keyword.fetch!(opts, :observer), {:fixture_tool_http_error, status})
        {status, headers, body}

      nil ->
        case params["name"] do
          "structured" ->
            structured_response(id, opts)

          "text" ->
            text =
              cond do
                text_bytes = opts[:text_bytes] -> String.duplicate("x", text_bytes)
                opts[:large_text?] -> String.duplicate("x", 40_000)
                true -> "hello"
              end

            json(id, %{
              "resultType" => "complete",
              "content" => [%{"type" => "text", "text" => text}]
            })

          "fail" ->
            failure_response(id, params, opts)
        end
    end
  end

  defp failure_response(id, params, opts) do
    if opts[:recoverable_error?] && params["arguments"]["query"] == "x" do
      json(id, %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => "recovered"}]
      })
    else
      content =
        case opts[:error_text] do
          text when is_binary(text) -> [%{"type" => "text", "text" => text}]
          _missing -> []
        end

      json(id, %{"resultType" => "complete", "isError" => true, "content" => content})
    end
  end

  defp structured_response(id, opts) do
    cond do
      opts[:rpc_error_tool] == "structured" ->
        rpc_error(
          id,
          -32_602,
          "invalid parameters",
          status: Keyword.get(opts, :rpc_error_status, 200)
        )

      result = opts[:structured_result] ->
        json(id, result)

      opts[:result_and_error?] ->
        value = Keyword.get(opts, :structured_value, 42)

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

      true ->
        json(id, %{
          "resultType" => Keyword.get(opts, :result_type, "complete"),
          "structuredContent" => %{
            "value" => Keyword.get(opts, :structured_value, 42)
          },
          "content" => []
        })
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
          "annotations" => %{
            "readOnlyHint" => true,
            "destructiveHint" => false,
            "idempotentHint" => true
          },
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
          do: ":" <> String.duplicate("x", 2_100_000) <> "\n\ndata: {\n\n",
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
      Keyword.get(
        opts,
        :program,
        ~S|(let [structured (tool/remote.structured {"query" "x"}) text (tool/remote.text {"query" "x"}) failed (tool/remote.fail {"query" "x"})] (return {"structured" structured "text" text "failed" failed}))|
      )

    config =
      Map.merge(
        %{
          "allow" => allow,
          "timeout_ms" => Keyword.get(opts, :timeout_ms, 1_000),
          "max_result_bytes" => Keyword.get(opts, :max_result_bytes, 32_000)
        },
        Keyword.get(opts, :config_extra, %{})
      )
      |> then(fn config ->
        if Keyword.get(opts, :omit_allow?, false), do: Map.delete(config, "allow"), else: config
      end)

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
        Map.merge(
          if(opts[:evaluation_timeout_ms],
            do: %{"evaluation_timeout_ms" => opts[:evaluation_timeout_ms]},
            else: %{}
          ),
          Keyword.get(opts, :limits, %{})
        )
    }

    body =
      case Keyword.get(opts, :mission_source) do
        source when is_binary(source) ->
          File.write!(Path.join(dir, "mission.clj"), source)

          Map.put(body, "mission", %{
            "components" => [%{"id" => "actions", "path" => "mission.clj"}],
            "data" => %{}
          })

        _missing ->
          body
      end

    path = Path.join(dir, "#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(body))
    path
  end
end
