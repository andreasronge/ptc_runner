defmodule PtcRunner.Kernel.MCPHTTPCancellationTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.TestSupport.MCPHTTPFixture

  @transport_limit 2_097_152
  @receive_timeout 6_000

  test "timeout closes the HTTP response stream without a cancellation notification" do
    %{capability: capability, close: close} = source(:incomplete, 250)
    on_exit(close)

    assert {:error, %ProviderError{kind: :timeout}} = call(capability)
    assert_stream_closed()
    refute_cancellation_notification()
  end

  test "caller death closes the HTTP response stream" do
    %{capability: capability, close: close} = source(:incomplete, 5_000)
    on_exit(close)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:unexpected_call_result, call(capability)})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:mcp_stream_holding, stream}, @receive_timeout
    stream_ref = Process.monitor(stream)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @receive_timeout
    assert_receive {:mcp_stream_closed, ^stream}, @receive_timeout
    assert_stream_down(stream_ref, stream)
    refute_receive {:unexpected_call_result, _result}
    refute_cancellation_notification()
  end

  test "provider close kills the active caller and closes the HTTP response stream" do
    %{capability: capability, close: close} = source(:incomplete, 5_000)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:unexpected_call_result, call(capability)})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:mcp_stream_holding, stream}, @receive_timeout
    stream_ref = Process.monitor(stream)

    assert :ok = close.()
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @receive_timeout
    assert_receive {:mcp_stream_closed, ^stream}, @receive_timeout
    assert_stream_down(stream_ref, stream)
    refute_receive {:unexpected_call_result, _result}
    refute_cancellation_notification()
  end

  test "source-owner death kills the active caller and closes the HTTP response stream" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    owner_ref = Process.monitor(owner)
    %{capability: capability, close: close} = source(:incomplete, 5_000, owner)
    on_exit(close)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:unexpected_call_result, call(capability)})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:mcp_stream_holding, stream}, @receive_timeout
    stream_ref = Process.monitor(stream)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, @receive_timeout
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @receive_timeout
    assert_receive {:mcp_stream_closed, ^stream}, @receive_timeout
    assert_stream_down(stream_ref, stream)
    refute_receive {:unexpected_call_result, _result}
    refute_cancellation_notification()
  end

  test "complete SSE response closes the stream as soon as the result is decoded" do
    %{capability: capability, close: close} = source(:complete_sse, 5_000)
    on_exit(close)

    assert {:ok, %{"text" => ["done"]}} = call(capability)
    assert_stream_closed()
    refute_cancellation_notification()
  end

  test "oversized JSON, oversized SSE, and malformed SSE close their response streams" do
    for {mode, details} <- [
          {:oversized_body, "mcp_response_exceeded"},
          {:oversized_sse, "mcp_response_exceeded"},
          {:malformed_sse, "mcp_protocol_error"}
        ] do
      %{capability: capability, close: close} = source(mode, 5_000)

      assert {:error, %ProviderError{kind: :invalid_result, details: ^details}} =
               call(capability)

      assert_stream_closed()
      refute_cancellation_notification()
      assert :ok = close.()
    end
  end

  test "repeated caller cancellation drains every request and server stream" do
    %{capability: capability, close: close} = source(:incomplete, 5_000)
    parent = self()

    for iteration <- 1..20 do
      caller =
        spawn(fn ->
          send(parent, {:unexpected_call_result, iteration, call(capability)})
        end)

      caller_ref = Process.monitor(caller)
      assert_receive {:mcp_stream_holding, stream}, @receive_timeout
      stream_ref = Process.monitor(stream)
      request_task = linked_request_task(caller)
      request_task_ref = Process.monitor(request_task)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @receive_timeout

      assert_receive {:DOWN, ^request_task_ref, :process, ^request_task, :killed},
                     @receive_timeout

      assert_receive {:mcp_stream_closed, ^stream}, @receive_timeout
      assert_stream_down(stream_ref, stream)
    end

    assert :ok = close.()
    refute_receive {:unexpected_call_result, _iteration, _result}
    refute_cancellation_notification()
  end

  defp assert_stream_closed do
    assert_receive {:mcp_stream_holding, stream}, @receive_timeout
    stream_ref = Process.monitor(stream)
    assert_receive {:mcp_stream_closed, ^stream}, @receive_timeout
    assert_stream_down(stream_ref, stream)
  end

  defp assert_stream_down(stream_ref, stream) do
    assert_receive {:DOWN, ^stream_ref, :process, ^stream, reason}, @receive_timeout
    assert reason in [:normal, :noproc]
  end

  defp linked_request_task(caller) do
    assert {:links, links} = Process.info(caller, :links)
    assert [request_task] = Enum.filter(links, &is_pid/1)
    request_task
  end

  defp refute_cancellation_notification do
    refute_receive {:mcp_cancellation_method, "notifications/cancelled"}, 200
  end

  defp call(capability), do: capability.callback.(%{}, %{inspection_sink: nil})

  defp source(mode, timeout_ms, owner \\ self()) do
    parent = self()

    fixture =
      MCPHTTPFixture.start(fn request ->
        method = request.body["method"]
        send(parent, {:mcp_cancellation_method, method})
        response(method, request.body["id"], mode)
      end)

    on_exit(fixture.close)

    builder =
      MCPSource.builder(
        transport: {:streamable_http, endpoint: fixture.endpoint, allow_insecure_loopback: true},
        tools: %{"fixture" => %{as: "remote.fixture", effect: :read}},
        timeout_ms: timeout_ms
      )

    {:ok, registry} = ProviderRegistry.new(%{"remote" => builder})

    {:ok, limits} =
      Limits.new(
        run_duration_ms: max(timeout_ms * 4, 30_000),
        evaluation_timeout_ms: timeout_ms
      )

    assert {:ok, %{capabilities: [capability], close: close}} =
             ProviderRegistry.build(
               registry,
               "remote",
               %{"allow" => ["remote.fixture"]},
               %{
                 application_content_digest: String.duplicate("0", 64),
                 destination: :mission,
                 limits: limits,
                 installed_limits: limits,
                 owner: owner
               }
             )

    %{capability: capability, close: close}
  end

  defp response("server/discover", id, _mode) do
    json(id, %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp response("tools/list", id, _mode) do
    json(id, %{
      "resultType" => "complete",
      "tools" => [
        %{
          "name" => "fixture",
          "inputSchema" => %{
            "type" => "object",
            "additionalProperties" => false
          }
        }
      ],
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp response("tools/call", _id, :incomplete) do
    chunked("text/event-stream", [": keep-alive\n\n"])
  end

  defp response("tools/call", id, :complete_sse) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "resultType" => "complete",
          "content" => [%{"type" => "text", "text" => "done"}]
        }
      })

    chunked("text/event-stream", ["data: #{body}\n\n"])
  end

  defp response("tools/call", _id, :malformed_sse) do
    chunked("text/event-stream", ["data: not-json\n\n"])
  end

  defp response("tools/call", _id, :oversized_body) do
    chunked("application/json", [String.duplicate("x", @transport_limit + 1)])
  end

  defp response("tools/call", _id, :oversized_sse) do
    chunked("text/event-stream", [String.duplicate("x", @transport_limit + 1)])
  end

  defp json(id, result) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    {200, [{"content-type", "application/json"}], body}
  end

  defp chunked(content_type, chunks),
    do: {:chunked, 200, [{"content-type", content_type}], chunks}
end
