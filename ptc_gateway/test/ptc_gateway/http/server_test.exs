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

  test "wildcard bind is an explicit operator choice" do
    {:ok, gateway} =
      PtcGateway.start_http(
        tools: tools(),
        token: @token,
        max_in_flight: 1,
        ip: {0, 0, 0, 0},
        port: 0
      )

    assert {:ok, {{0, 0, 0, 0}, port}} = PtcGateway.listener_info(gateway)
    assert port > 0
    {200, _} = HTTPClient.get(url(port, "/health"))
    PtcGateway.stop(gateway)
  end

  defp start_http do
    PtcGateway.start_http(tools: tools(), token: @token, max_in_flight: 2, port: 0)
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

  defp request(id, method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end
end
