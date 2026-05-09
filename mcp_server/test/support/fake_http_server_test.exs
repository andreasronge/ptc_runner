defmodule PtcRunnerMcp.Test.FakeHttpServerTest do
  @moduledoc """
  Self-tests for the `PtcRunnerMcp.Test.FakeHttpServer` fixture. These
  prove the fixture correctly serves each scenario at the HTTP layer
  so Phase 2G's full matrix can trust it.

  Scope is the fixture only — `Upstream.Http` is not exercised here.
  """

  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Test.FakeHttpServer

  describe "boot" do
    test "port/1 returns a non-zero ephemeral port" do
      server = start_supervised!({FakeHttpServer, scenario: :handshake_success})
      port = FakeHttpServer.port(server)
      assert is_integer(port) and port > 0
    end

    test "two fixtures get distinct ports" do
      a = start_supervised!({FakeHttpServer, scenario: :handshake_success}, id: :a)
      b = start_supervised!({FakeHttpServer, scenario: :handshake_success}, id: :b)
      refute FakeHttpServer.port(a) == FakeHttpServer.port(b)
    end
  end

  describe ":handshake_success" do
    setup do
      toolset = [
        %{
          "name" => "echo",
          "description" => "Echo input",
          "inputSchema" => %{"type" => "object"}
        }
      ]

      server =
        start_supervised!(
          {FakeHttpServer, scenario: :handshake_success, opts: %{toolset: toolset}}
        )

      url = "http://127.0.0.1:#{FakeHttpServer.port(server)}/mcp"
      {:ok, server: server, url: url, toolset: toolset}
    end

    test "initialize returns 200, protocolVersion, and Mcp-Session-Id", %{url: url} do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        }
      }

      resp = Req.post!(url, json: body)

      assert resp.status == 200
      assert resp.body["jsonrpc"] == "2.0"
      assert resp.body["id"] == 1
      assert resp.body["result"]["protocolVersion"] == "2025-06-18"
      assert get_header(resp, "mcp-session-id") =~ ~r/^test-session-/
    end

    test "notifications/initialized returns 202 with no body", %{url: url} do
      resp =
        Req.post!(url,
          json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
        )

      assert resp.status == 202
      assert resp.body == ""
    end

    test "tools/list returns the configured toolset", %{url: url, toolset: toolset} do
      resp =
        Req.post!(url,
          json: %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"}
        )

      assert resp.status == 200
      assert resp.body["result"]["tools"] == toolset
    end

    test "tools/call returns a result body echoing the tool name", %{url: url} do
      resp =
        Req.post!(url,
          json: %{
            "jsonrpc" => "2.0",
            "id" => 9,
            "method" => "tools/call",
            "params" => %{"name" => "echo", "arguments" => %{}}
          }
        )

      assert resp.status == 200
      assert get_in(resp.body, ["result", "content", Access.at(0), "text"]) == "called echo"
    end
  end

  describe ":handshake_401" do
    test "returns 401 on initialize" do
      server = start_supervised!({FakeHttpServer, scenario: :handshake_401})
      url = "http://127.0.0.1:#{FakeHttpServer.port(server)}/mcp"

      resp = Req.post!(url, json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})

      assert resp.status == 401
    end
  end

  describe ":server_error_5xx" do
    test "returns 503 on every request" do
      server = start_supervised!({FakeHttpServer, scenario: :server_error_5xx})
      url = "http://127.0.0.1:#{FakeHttpServer.port(server)}/mcp"

      resp = Req.post!(url, json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "anything"})

      assert resp.status == 503
    end
  end

  describe "received_requests/1" do
    test "records method, path, headers (intact), and body in arrival order" do
      server = start_supervised!({FakeHttpServer, scenario: :handshake_success})
      url = "http://127.0.0.1:#{FakeHttpServer.port(server)}/mcp"

      Req.post!(url,
        json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"},
        headers: [{"x-test-tag", "alpha"}]
      )

      Req.post!(url,
        json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        headers: [{"x-test-tag", "beta"}]
      )

      requests = FakeHttpServer.received_requests(server)

      assert length(requests) == 2

      [first, second] = requests

      assert first.method == "POST"
      assert first.path == "/mcp"
      assert first.decoded["method"] == "initialize"
      assert header_value(first.headers, "x-test-tag") == "alpha"

      assert second.decoded["method"] == "notifications/initialized"
      assert header_value(second.headers, "x-test-tag") == "beta"
    end
  end

  # ───────── helpers ─────────

  defp get_header(%Req.Response{headers: headers}, name) when is_map(headers) do
    headers
    |> Map.get(name, [])
    |> List.first()
  end

  defp get_header(%Req.Response{headers: headers}, name) do
    header_value(headers, name)
  end

  defp header_value(headers, name) when is_list(headers) do
    name_dc = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name_dc, do: v
    end)
  end
end
