defmodule PtcGateway.HTTP.ServerTest do
  use ExUnit.Case, async: true

  alias PtcGateway.HTTPClient

  @token "gateway-token-fixture"

  @input_schema %{
    "type" => "object",
    "properties" => %{"n" => %{"type" => "integer"}},
    "required" => ["n"],
    "additionalProperties" => false
  }
  @output_schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  test "binds loopback, serves health without a bearer, and lists tools over JSON POST" do
    {:ok, gateway} = start_http()
    assert {:ok, {{127, 0, 0, 1}, port}} = PtcGateway.listener_info(gateway)
    assert port > 0

    {200, health} = HTTPClient.get(url(port, "/health"))
    assert health == %{"status" => "ok"}

    {401, _} = HTTPClient.get(url(port, "/ready"))

    {200, listed} =
      HTTPClient.post(url(port, "/mcp"), request(1, "tools/list", %{}), [
        {"authorization", "Bearer #{@token}"}
      ])

    names = listed["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["double", "echo"]

    {200, called} =
      HTTPClient.post(
        url(port, "/mcp"),
        request(2, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 4}}),
        [{"authorization", "Bearer #{@token}"}]
      )

    assert called["result"]["structuredContent"] == %{"answer" => 4}

    {200, sse} =
      HTTPClient.post(
        url(port, "/mcp"),
        request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 5}}),
        [
          {"authorization", "Bearer #{@token}"},
          {"accept", "text/event-stream"}
        ]
      )

    assert is_binary(sse)
    assert sse =~ "data:"
    decoded = sse_json(sse)
    assert decoded["result"]["structuredContent"] == %{"answer" => 5}

    PtcGateway.stop(gateway)
    assert {:error, _reason} = HTTPClient.get(url(port, "/health"))
  end

  test "rejects a non-loopback bind that is not the explicit wildcard" do
    assert {:error, :invalid_gateway_config} =
             PtcGateway.start_http(
               tools: tools(),
               token: @token,
               max_in_flight: 1,
               ip: {8, 8, 8, 8},
               port: 0
             )
  end

  test "refuses an empty token" do
    assert {:error, :invalid_gateway_config} =
             PtcGateway.start_http(tools: tools(), token: "", max_in_flight: 1, port: 0)
  end

  test "wildcard bind requires an explicit Host name" do
    assert {:error, :invalid_gateway_config} =
             PtcGateway.start_http(
               tools: tools(),
               token: @token,
               max_in_flight: 1,
               ip: {0, 0, 0, 0},
               port: 0
             )

    assert {:error, :invalid_gateway_config} =
             PtcGateway.start_http(
               tools: tools(),
               token: @token,
               max_in_flight: 1,
               ip: {0, 0, 0, 0},
               host: "http://example.com",
               port: 0
             )

    for host <- ["example.com\t", "foo@bar", "foo?bar", "foo#bar", "foo\\bar", "exam ple"] do
      assert {:error, :invalid_gateway_config} =
               PtcGateway.start_http(
                 tools: tools(),
                 token: @token,
                 max_in_flight: 1,
                 ip: {0, 0, 0, 0},
                 host: host,
                 port: 0
               )
    end
  end

  test "wildcard bind is an explicit operator choice" do
    {:ok, gateway} =
      PtcGateway.start_http(
        tools: tools(),
        token: @token,
        max_in_flight: 1,
        ip: {0, 0, 0, 0},
        host: "127.0.0.1",
        port: 0
      )

    assert {:ok, {{0, 0, 0, 0}, port}} = PtcGateway.listener_info(gateway)
    assert port > 0
    {200, _} = HTTPClient.get(url(port, "/health"))

    {200, ready} =
      HTTPClient.get(url(port, "/ready"), [{"authorization", "Bearer #{@token}"}])

    assert ready == %{"status" => "ready"}
    PtcGateway.stop(gateway)
  end

  test "Bandit stop telemetry does not carry the bearer token" do
    parent = self()
    handler = "gateway-http-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:bandit, :request, :start],
        [:bandit, :request, :stop],
        [:bandit, :request, :exception]
      ],
      &__MODULE__.capture_telemetry/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, gateway} = start_http()
    refute inspect(:sys.get_status(gateway)) =~ @token
    {:ok, {_ip, port}} = PtcGateway.listener_info(gateway)

    {200, ready} =
      HTTPClient.get(url(port, "/ready"), [{"authorization", "Bearer #{@token}"}])

    assert ready == %{"status" => "ready"}

    assert_receive {:telemetry, :start, start_inspected}, 1_000
    assert_receive {:telemetry, :stop, stop_inspected}, 1_000
    refute_received {:telemetry, :exception, _}

    refute stop_inspected =~ @token
    refute stop_inspected =~ "Bearer "
    assert start_inspected =~ @token

    PtcGateway.stop(gateway)
  end

  test "secret-holder death stops the HTTP gateway" do
    {:ok, gateway} = start_http()
    ref = Process.monitor(gateway)
    secret = child_pid!(gateway, PtcGateway.HTTP.Secret)
    Process.exit(secret, :kill)

    assert_receive {:DOWN, ^ref, :process, ^gateway, _reason}
  end

  test "closing an SSE tools/call stream kills the request owner" do
    parent = self()

    tools = [
      %{
        name: "block",
        description: "Block",
        input_schema: @input_schema,
        output_schema: @output_schema,
        meta: %{"ptc/application_content_digest" => "c"},
        call: fn _arguments ->
          send(parent, {:owner, self()})
          receive do: (:never -> :never)
        end
      }
    ]

    {:ok, gateway} =
      PtcGateway.start_http(
        tools: tools,
        token: @token,
        max_in_flight: 1,
        port: 0,
        heartbeat_ms: 25
      )

    {:ok, {_ip, port}} = PtcGateway.listener_info(gateway)
    body = request(1, "tools/call", %{"name" => "block", "arguments" => %{"n" => 1}})

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false])

    request = [
      "POST /mcp HTTP/1.1\r\n",
      "Host: 127.0.0.1:#{port}\r\n",
      "Authorization: Bearer #{@token}\r\n",
      "Accept: text/event-stream\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ]

    :ok = :gen_tcp.send(socket, request)
    headers = recv_until(socket, "\r\n\r\n")
    assert headers =~ "text/event-stream"
    assert_receive {:owner, owner}, 1_000
    ref = Process.monitor(owner)
    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 1_000
    PtcGateway.stop(gateway)
  end

  def capture_telemetry([:bandit, :request, kind], _measurements, metadata, parent) do
    send(parent, {:telemetry, kind, inspect(metadata)})
  end

  defp start_http do
    PtcGateway.start_http(tools: tools(), token: @token, max_in_flight: 2, port: 0)
  end

  defp child_pid!(supervisor, id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp tools do
    [
      %{
        name: "echo",
        description: "Echo n",
        input_schema: @input_schema,
        output_schema: @output_schema,
        meta: %{"ptc/application_content_digest" => "a"},
        call: fn arguments -> {:ok, %{"answer" => arguments["n"]}} end
      },
      %{
        name: "double",
        description: "Double n",
        input_schema: @input_schema,
        output_schema: @output_schema,
        meta: %{"ptc/application_content_digest" => "b"},
        call: fn arguments -> {:ok, %{"answer" => arguments["n"] * 2}} end
      }
    ]
  end

  defp url(port, path), do: "http://127.0.0.1:#{port}#{path}"

  defp sse_json(body) when is_binary(body) do
    body
    |> String.split("\n\n")
    |> Enum.find_value(fn event ->
      data =
        event
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &String.trim_leading(&1, "data:"))
        |> String.trim()

      if data != "", do: Jason.decode!(data)
    end)
  end

  defp recv_until(socket, marker) do
    recv_until(socket, marker, "")
  end

  defp recv_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
      recv_until(socket, marker, acc <> data)
    end
  end

  defp request(id, method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end
end
