defmodule PtcRunnerMcp.Upstream.Http.TransportTest do
  @moduledoc """
  Unit tests for `PtcRunnerMcp.Upstream.Http.Transport`.

  These tests stand up a tiny inline Plug under Bandit on an
  ephemeral port. They cover at least half of the §6.4 status-code
  table per the Phase 2B brief; the remaining rows (SSE, session-loss
  interpretation) are exercised by streams 2C / 2D / 2G against the
  shared `PtcRunnerMcp.Test.FakeHttpServer`.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Upstream.Http.Transport

  # ───────── Inline Plug fixture ─────────

  defmodule TestPlug do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      ctrl = Keyword.fetch!(opts, :controller)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(ctrl, {:received, %{path: conn.request_path, body: body}})

      scenario = Keyword.fetch!(opts, :scenario)
      handle(scenario, conn, opts)
    end

    # 200 + JSON-RPC result.
    defp handle(:ok_result, conn, _opts) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{"tools" => [%{"name" => "echo"}]}
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    # 200 + JSON-RPC error.
    defp handle(:ok_jsonrpc_error, conn, _opts) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32_000, "message" => "boom"}
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    defp handle(:ok_sse_initialize, conn, _opts) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "serverInfo" => %{"name" => "sse-fixture", "version" => "1"}
          }
        })

      conn
      |> put_resp_header("mcp-session-id", "session-from-sse")
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, "event: message\ndata: #{body}\n\n")
    end

    # 202 Accepted, empty body — handshake step 2 / notifications POST.
    defp handle(:accepted_202, conn, _opts) do
      send_resp(conn, 202, "")
    end

    defp handle(:auth_401, conn, _opts) do
      send_resp(conn, 401, "")
    end

    defp handle(:auth_403, conn, _opts) do
      send_resp(conn, 403, "")
    end

    defp handle(:host_blocked_403, conn, _opts) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, ~s|Blocked request. This host ("::1:3333") is not allowed.|)
    end

    defp handle(:binary_body_403, conn, _opts) do
      send_resp(conn, 403, <<255, 0, 65>>)
    end

    defp handle(:rate_limited_429, conn, _opts) do
      send_resp(conn, 429, "")
    end

    defp handle(:not_found_404, conn, _opts) do
      send_resp(conn, 404, "")
    end

    # 4xx + JSON-RPC error body — must classify as :upstream_error per
    # §6.4 / §8.1 (world-fault, NOT programmer-fault).
    defp handle(:bad_request_400_with_jsonrpc, conn, _opts) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32_602, "message" => "invalid params"}
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, body)
    end

    # 4xx without JSON-RPC body — must surface as :upstream_unavailable.
    defp handle(:bad_request_400_plain, conn, _opts) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(400, "Bad Request")
    end

    # 404 + JSON-RPC error body — codex P1 fix for `76f68de`: must
    # classify as `:upstream_error`, NOT `:upstream_unavailable, "http 404"`.
    # Pre-fix, `do_map_response/5` special-cased every 404 before the
    # 4xx-with-jsonrpc-body branch could fire.
    defp handle(:not_found_404_with_jsonrpc, conn, _opts) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32_601, "message" => "method not found"}
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, body)
    end

    # 401 + JSON-RPC error body — also classifies as :upstream_error
    # (any 4xx + JSON-RPC body, by the same world-fault rule).
    defp handle(:auth_401_with_jsonrpc, conn, _opts) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32_600, "message" => "invalid request"}
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, body)
    end

    # 401 + an `{"error": "..."}` body that is NOT a JSON-RPC envelope
    # (no `"jsonrpc": "2.0"` field). MUST classify as `:upstream_unavailable,
    # "auth_failed"` — the JSON-RPC matcher requires the protocol marker.
    defp handle(:auth_401_with_oauth_body, conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, ~s({"error":"unauthorized","error_description":"bad token"}))
    end

    # User-Agent reflection — the test reads back what the server saw
    # via the controller's `:received` message, plus we send 200 with
    # an empty result so the call completes cleanly.
    defp handle(:reflect_user_agent, conn, opts) do
      ctrl = Keyword.fetch!(opts, :controller)
      ua = Plug.Conn.get_req_header(conn, "user-agent")
      send(ctrl, {:user_agent, ua})

      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    defp handle(:server_error_503, conn, _opts) do
      send_resp(conn, 503, "")
    end

    # Returns a body bigger than `:max_response_bytes` will tolerate.
    # Sized large enough that any sensible cap (≤4 KiB in tests) gets
    # tripped on the first chunk.
    defp handle(:large_body_200, conn, _opts) do
      big = String.duplicate("x", 64 * 1024)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, big)
    end
  end

  # Boots a Bandit instance with the given scenario; returns
  # `{port, server_pid}`. Caller registers a teardown via `on_exit`.
  defp start_fixture(scenario) do
    {:ok, server} =
      Bandit.start_link(
        plug: {TestPlug, controller: self(), scenario: scenario},
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      ref = Process.monitor(server)
      Process.exit(server, :shutdown)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        2_000 -> :ok
      end
    end)

    %{port: port, url: "http://127.0.0.1:#{port}/mcp"}
  end

  defp post_opts(url, overrides \\ []) do
    [
      url: url,
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
      body: ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}),
      request_timeout_ms: 2_000,
      connect_timeout_ms: 1_000,
      max_response_bytes: 64 * 1024,
      jsonrpc_id: 1
    ]
    |> Keyword.merge(overrides)
  end

  # ───────── Tests ─────────

  describe "200 OK with application/json" do
    test "JSON-RPC result → {:ok, result}" do
      %{url: url} = start_fixture(:ok_result)

      assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = Transport.post(post_opts(url))
    end

    test "JSON-RPC error → {:error, :upstream_error, formatted}" do
      %{url: url} = start_fixture(:ok_jsonrpc_error)

      assert {:error, :upstream_error, detail} = Transport.post(post_opts(url))
      assert detail =~ "boom"
      assert detail =~ "-32000"
    end
  end

  describe "post_with_meta/1 handshake response mapping" do
    test "200 text/event-stream initialize preserves headers and decoded JSON-RPC envelope" do
      %{url: url} = start_fixture(:ok_sse_initialize)

      assert {:ok, %{status: 200, headers: headers, body: body}} =
               Transport.post_with_meta(post_opts(url))

      assert headers["mcp-session-id"] == ["session-from-sse"]
      assert body["id"] == 1
      assert body["result"]["protocolVersion"] == "2025-06-18"
      assert body["result"]["serverInfo"]["name"] == "sse-fixture"
    end
  end

  describe "202 Accepted (notifications-only POST)" do
    test "empty body → :ok" do
      %{url: url} = start_fixture(:accepted_202)
      assert :ok = Transport.post(post_opts(url))
    end
  end

  describe "auth failures" do
    test "401 → {:error, :upstream_unavailable, \"auth_failed\"}" do
      %{url: url} = start_fixture(:auth_401)
      assert {:error, :upstream_unavailable, "auth_failed"} = Transport.post(post_opts(url))
    end

    test "403 preserves response detail instead of reporting auth_failed" do
      %{url: url} = start_fixture(:auth_403)
      assert {:error, :upstream_unavailable, "http 403"} = Transport.post(post_opts(url))
    end

    test "403 with host-allowlist body surfaces the body snippet" do
      %{url: url} = start_fixture(:host_blocked_403)

      assert {:error, :upstream_unavailable, detail} = Transport.post(post_opts(url))
      assert detail =~ "http 403"
      assert detail =~ "Blocked request"
      assert detail =~ "::1:3333"
    end

    test "403 with non-UTF-8 body returns JSON-safe detail" do
      %{url: url} = start_fixture(:binary_body_403)

      assert {:error, :upstream_unavailable, detail} = Transport.post(post_opts(url))
      assert String.valid?(detail)
      assert {:ok, _json} = Jason.encode(%{"error" => detail})
    end
  end

  describe "rate limiting and 404" do
    test "429 → {:error, :upstream_unavailable, \"rate_limited\"}" do
      %{url: url} = start_fixture(:rate_limited_429)
      assert {:error, :upstream_unavailable, "rate_limited"} = Transport.post(post_opts(url))
    end

    test "404 surfaces as upstream_unavailable; Session.session_lost? interprets it" do
      %{url: url} = start_fixture(:not_found_404)
      assert {:error, :upstream_unavailable, "http 404"} = Transport.post(post_opts(url))
    end
  end

  describe "4xx mapping (§6.4 spec correction)" do
    test "4xx + JSON-RPC error body → :upstream_error (world-fault, NOT programmer-fault)" do
      %{url: url} = start_fixture(:bad_request_400_with_jsonrpc)

      # §6.4 / §8.1: HTTP 4xx with a JSON-RPC error body is world-fault.
      # The codex-1 draft incorrectly classified this as
      # programmer-fault; this test pins the correction.
      assert {:error, :upstream_error, detail} = Transport.post(post_opts(url))
      assert detail =~ "invalid params"
    end

    test "4xx without JSON-RPC body → :upstream_unavailable" do
      %{url: url} = start_fixture(:bad_request_400_plain)

      assert {:error, :upstream_unavailable, "http 400: Bad Request"} =
               Transport.post(post_opts(url))
    end
  end

  describe "5xx mapping" do
    test "503 → {:error, :upstream_unavailable, \"http 503\"}" do
      %{url: url} = start_fixture(:server_error_503)
      assert {:error, :upstream_unavailable, "http 503"} = Transport.post(post_opts(url))
    end
  end

  describe ":max_response_bytes enforcement" do
    test "body exceeding the cap → {:error, :response_too_large, _}" do
      %{url: url} = start_fixture(:large_body_200)

      # Cap < the 64 KiB body the fixture emits.
      opts = post_opts(url, max_response_bytes: 1024)

      assert {:error, :response_too_large, detail} = Transport.post(opts)
      assert detail =~ "1024"
    end
  end

  describe "transport-layer errors" do
    test "connection refused → :upstream_unavailable" do
      # No server on this port. We pick a port unlikely to be in use;
      # if it happens to be live, the worst case is a flake we re-run.
      url = "http://127.0.0.1:1/mcp"

      result = Transport.post(post_opts(url, connect_timeout_ms: 200))

      assert match?({:error, :upstream_unavailable, _}, result),
             "expected :upstream_unavailable, got: #{inspect(result)}"
    end

    test "IPv6-literal URL still uses the caller-owned Finch pool" do
      url = "http://[::1]:1/mcp"

      result =
        Transport.post(
          post_opts(url,
            connect_timeout_ms: 200,
            finch: PtcRunnerMcp.Upstream.Http.TransportTest.Ipv6RegressionFinch
          )
        )

      assert {:error, :upstream_unavailable, detail} = result
      assert detail =~ "unknown registry"
      assert detail =~ "Ipv6RegressionFinch"
    end
  end

  # ─────── codex P1 #3 regression: 4xx + JSON-RPC body precedence ───────
  #
  # Pre-fix: `do_map_response/5` special-cased every 404 BEFORE the
  # 4xx-with-jsonrpc-body branch could fire. So a 404 carrying a
  # JSON-RPC error envelope was misclassified as `:upstream_unavailable,
  # "http 404"` (which the impl can interpret as session-loss). Post-fix:
  # any 4xx with a proper JSON-RPC envelope (carrying `"jsonrpc": "2.0"`)
  # is a world-fault `:upstream_error`.
  describe "4xx + JSON-RPC body precedence (codex P1 #3 for `76f68de`)" do
    test "404 with JSON-RPC error body → :upstream_error (NOT \"http 404\")" do
      %{url: url} = start_fixture(:not_found_404_with_jsonrpc)

      assert {:error, :upstream_error, detail} = Transport.post(post_opts(url))
      assert detail =~ "method not found"
    end

    test "404 plain body still surfaces as :upstream_unavailable, \"http 404\"" do
      # This pins that the session-loss path (`Upstream.Http`'s 404 +
      # held-session-id check) is preserved for the non-JSON-RPC case.
      %{url: url} = start_fixture(:not_found_404)
      assert {:error, :upstream_unavailable, "http 404"} = Transport.post(post_opts(url))
    end

    test "401 with JSON-RPC error body → :upstream_error" do
      %{url: url} = start_fixture(:auth_401_with_jsonrpc)

      assert {:error, :upstream_error, detail} = Transport.post(post_opts(url))
      assert detail =~ "invalid request"
    end

    test "401 with OAuth-style {error: ...} body (no jsonrpc field) → auth_failed" do
      # Defence against false positives — an OAuth-style error response
      # carrying `{"error": "..."}` is NOT a JSON-RPC envelope and MUST
      # NOT be misclassified as a JSON-RPC protocol error.
      %{url: url} = start_fixture(:auth_401_with_oauth_body)

      assert {:error, :upstream_unavailable, "auth_failed"} = Transport.post(post_opts(url))
    end
  end

  # ─────── codex P1 #2 regression: User-Agent is impl-controlled ───────
  describe "User-Agent override (codex P1 #2 for `76f68de`)" do
    test "caller-supplied User-Agent is stripped; impl always wins" do
      %{url: url} = start_fixture(:reflect_user_agent)

      opts =
        post_opts(url,
          headers: [
            {"content-type", "application/json"},
            {"accept", "application/json"},
            {"user-agent", "evil-override/1.0"}
          ]
        )

      assert :ok = match_post_result(Transport.post(opts))

      assert_receive {:user_agent, ua_list}, 2_000
      assert [ua] = ua_list
      assert ua =~ "ptc-runner-mcp/"
      refute ua =~ "evil-override"
    end

    test "case-insensitive — `User-Agent` (mixed case) also stripped" do
      %{url: url} = start_fixture(:reflect_user_agent)

      opts =
        post_opts(url,
          headers: [
            {"content-type", "application/json"},
            {"accept", "application/json"},
            {"User-Agent", "Evil/2.0"}
          ]
        )

      assert :ok = match_post_result(Transport.post(opts))
      assert_receive {:user_agent, [ua]}, 2_000
      assert ua =~ "ptc-runner-mcp/"
      refute ua =~ "Evil"
    end
  end

  # Helper: collapse `Transport.post/1` happy-path / 200-empty-result
  # to `:ok` for tests that only care that the call completed.
  defp match_post_result({:ok, _}), do: :ok
  defp match_post_result(:ok), do: :ok
  defp match_post_result(other), do: {:bad, other}
end
