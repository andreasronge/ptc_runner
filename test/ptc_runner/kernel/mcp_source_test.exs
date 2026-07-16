defmodule PtcRunner.Kernel.MCPSourceTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.TestSupport.MCPHTTPFixture

  @input_schema %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string"}},
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
    assert snapshot["protocol"] == "mcp-2025-11-25"
    assert snapshot["snapshot_hash"] =~ ~r/\A[0-9a-f]{64}\z/

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

    assert_receive {:mcp_request, "initialize", initialize_headers}
    refute Map.has_key?(initialize_headers, "mcp-protocol-version")
    assert_receive {:mcp_request, "notifications/initialized", initialized_headers}
    assert initialized_headers["mcp-session-id"] == "fixture-session"
    assert_receive {:mcp_request, "tools/list", _headers}
    assert_receive {:mcp_request, "tools/list", _headers}
    assert_receive {:mcp_request, "tools/call", _headers}
    assert_receive {:mcp_request, "tools/call", _headers}
    assert_receive {:mcp_request, "tools/call", _headers}
    assert_receive :mcp_deleted

    EventSink.stop(built.config.event_sink)
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

    assert_receive {:mcp_request, "initialize", _headers}
    assert_receive {:mcp_request, "notifications/initialized", _headers}
    assert_receive {:mcp_request, "tools/list", _headers}
    assert_receive {:mcp_request, "tools/list", _headers}
    assert_receive :mcp_deleted
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
  test "accepts bounded SSE responses and rejects malformed pagination and selection keys", %{
    tmp_dir: dir
  } do
    parent = self()
    sse = fixture(parent, sse?: true)
    on_exit(sse.close)

    {:ok, built} =
      dir
      |> manifest(["remote.structured"])
      |> RunBuilder.load_and_build(registry(sse.endpoint))

    assert [snapshot] = built.config.connector_snapshots
    assert Enum.map(snapshot["tools"], & &1["name"]) == ["remote.structured"]
    assert :ok = RunBuilder.close(built)
    assert_receive :mcp_deleted

    duplicate = fixture(parent, duplicate_catalog?: true)
    on_exit(duplicate.close)

    assert {:error, :mcp_invalid_catalog} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(duplicate.endpoint))

    assert_receive :mcp_deleted

    excessive = fixture(parent)
    on_exit(excessive.close)

    assert {:error, :mcp_catalog_exceeded} =
             dir
             |> manifest(["remote.structured"])
             |> RunBuilder.load_and_build(registry(excessive.endpoint, max_pages: 1))

    assert_receive :mcp_deleted

    assert {:error, :invalid_mcp_selection} =
             dir
             |> manifest(["remote.structured"], config_extra: %{"endpoint" => "forbidden"})
             |> RunBuilder.load_and_build(registry(excessive.endpoint))
  end

  @tag :tmp_dir
  test "snapshot hashes are stable and the lease closes when its building owner exits", %{
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
    assert_receive :mcp_deleted

    {:ok, second} = RunBuilder.load_and_build(manifest, registry)
    assert second.config.connector_snapshots == first_snapshot
    assert :ok = RunBuilder.close(second)
    assert_receive :mcp_deleted

    {:ok, owner} =
      Task.start(fn ->
        result = RunBuilder.load_and_build(manifest, registry)
        send(parent, {:owner_build, result})
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:owner_build, {:ok, abandoned}}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive :mcp_deleted
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

    blocked = fixture(parent, block_initialize?: true)
    on_exit(blocked.close)
    timeout_registry = registry(blocked.endpoint, timeout_ms: 100)

    task =
      Task.async(fn ->
        dir
        |> manifest(["remote.structured"], timeout_ms: 100)
        |> RunBuilder.load_and_build(timeout_registry)
      end)

    assert_receive {:mcp_blocked, worker}
    assert {:error, :mcp_timeout} = Task.await(task, 2_000)
    send(worker, :release)
  end

  @tag :tmp_dir
  test "run timeout cancels an in-flight MCP call before deleting the session", %{tmp_dir: dir} do
    parent = self()
    fixture = fixture(parent, block_tool: "structured")
    on_exit(fixture.close)
    registry = registry(fixture.endpoint, timeout_ms: 100)

    {:ok, built} =
      dir
      |> manifest(Map.keys(public_mappings()), timeout_ms: 100, evaluation_timeout_ms: 100)
      |> RunBuilder.load_and_build(registry)

    task = Task.async(fn -> Kernel.run(built.entry_source, built.config) end)
    assert_receive {:mcp_blocked, worker}
    assert {:ok, _result} = Task.await(task, 2_000)
    assert_receive :mcp_deleted
    send(worker, :release)
    EventSink.stop(built.config.event_sink)
  end

  defp registry(endpoint, opts \\ []) do
    builder =
      MCPSource.builder(
        endpoint: endpoint,
        allow_insecure_loopback: true,
        headers: fn -> [{"authorization", "Bearer fixture-secret"}] end,
        tools: mappings(),
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

  defp fixture(parent, opts \\ []) do
    MCPHTTPFixture.start(fn request ->
      if request.method == "DELETE" do
        send(parent, :mcp_deleted)
        {200, [{"content-type", "application/json"}], "{}"}
      else
        method = request.body["method"]
        send(parent, {:mcp_request, method, request.headers})

        if opts[:block_initialize?] && method == "initialize" do
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

        if opts[:disconnect?] && method == "initialize" do
          :close
        else
          request |> response(opts) |> maybe_sse(opts)
        end
      end
    end)
  end

  defp response(%{body: %{"method" => "initialize", "id" => id}}, _opts) do
    json(id, %{"protocolVersion" => "2025-11-25", "capabilities" => %{"tools" => %{}}},
      headers: [{"mcp-session-id", "fixture-session"}]
    )
  end

  defp response(%{body: %{"method" => "notifications/initialized"}}, _opts),
    do: {202, [{"content-type", "application/json"}], ""}

  defp response(
         %{body: %{"method" => "tools/list", "id" => id, "params" => params}},
         opts
       ) do
    if is_nil(params["cursor"]) do
      json(id, %{"tools" => [tool("structured", opts)], "nextCursor" => "page-2"})
    else
      tools =
        if opts[:duplicate_catalog?],
          do: [tool("structured", opts)],
          else: [tool("text", opts), tool("fail", opts)]

      json(id, %{"tools" => tools})
    end
  end

  defp response(
         %{body: %{"method" => "tools/call", "id" => id, "params" => params}},
         opts
       ) do
    case params["name"] do
      "structured" ->
        value = Keyword.get(opts, :structured_value, 42)
        json(id, %{"structuredContent" => %{"value" => value}, "content" => []})

      "text" ->
        text = if opts[:large_text?], do: String.duplicate("x", 40_000), else: "hello"
        json(id, %{"content" => [%{"type" => "text", "text" => text}]})

      "fail" ->
        json(id, %{"isError" => true, "content" => []})
    end
  end

  defp tool("structured", opts) do
    input =
      if opts[:invalid_schema?], do: Map.put(@input_schema, "$ref", "remote"), else: @input_schema

    %{
      "name" => "structured",
      "description" => "Return one structured value.",
      "inputSchema" => input,
      "outputSchema" => @output_schema
    }
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

  defp maybe_sse({200, headers, body}, opts) do
    if opts[:sse?] do
      headers =
        headers
        |> Enum.reject(fn {name, _value} -> name == "content-type" end)
        |> Enum.concat([{"content-type", "text/event-stream"}])

      {200, headers, "data: #{body}\n\n"}
    else
      {200, headers, body}
    end
  end

  defp maybe_sse(response, _opts), do: response

  defp manifest(dir, allow, opts \\ []) do
    File.write!(
      Path.join(dir, "workflow.lisp"),
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
        "components" => [%{"id" => "app", "path" => "workflow.lisp"}],
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
