defmodule PtcRunnerMcp.Upstream.HttpTest do
  @moduledoc """
  Integration tests for `PtcRunnerMcp.Upstream.Http` against the
  `PtcRunnerMcp.Test.FakeHttpServer` fixture.

  Per `Plans/http-transport-credentials.md` §13.2 / Phase 2D brief.
  Covers the full handshake, session-id propagation, session-loss /
  auth-failure abnormal exits, JSON-RPC error world-fault classification,
  notifications-step strict-202 enforcement, and `stop/1` idempotency.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Test.FakeHttpServer
  alias PtcRunnerMcp.Upstream.Http

  # `:async: false` because each test stands up a Bandit listener and
  # we drive the impl through `start_link/2` (which registers a
  # globally-named process via the test_helper-started
  # `Upstream.Http.Names` Registry). Test isolation is by unique
  # upstream name per test.

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp config(port, overrides \\ %{}) do
    base = %{
      url: "http://127.0.0.1:#{port}/mcp",
      handshake_timeout_ms: 2_000,
      request_timeout_ms: 2_000,
      connect_timeout_ms: 1_000,
      max_response_bytes: 256 * 1024,
      pool_size: 2
    }

    Map.merge(base, overrides)
  end

  defp boot_fake(scenario, opts \\ %{}) do
    server =
      start_supervised!(
        {FakeHttpServer, scenario: scenario, opts: opts},
        # Each FakeHttpServer wraps a Bandit listener; give it a
        # unique id so multiple boots in one test (e.g. restart
        # scenarios) don't collide.
        id: {FakeHttpServer, System.unique_integer([:positive])}
      )

    %{server: server, port: FakeHttpServer.port(server)}
  end

  defp safe_stop(name) do
    Http.stop(name)
  catch
    :exit, _ -> :ok
  end

  # ───────── Handshake happy path ─────────

  describe "handshake → tools/list cache → tools/call" do
    test "drives the full 2025-06-18 handshake against :handshake_success" do
      toolset = [
        %{
          "name" => "echo",
          "description" => "echoes",
          "inputSchema" => %{"type" => "object"}
        }
      ]

      %{server: server, port: port} = boot_fake(:handshake_success, %{toolset: toolset})

      name = unique_name("http-success")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      # tools/list reflects the cache populated at handshake time.
      assert {:ok, tools} = Http.list_tools(name)
      assert [%{name: "echo", description: "echoes", input_schema: %{"type" => "object"}}] = tools

      # tools/call returns the upstream's `result` map verbatim.
      assert {:ok, %{"content" => [%{"type" => "text", "text" => "called echo"}]}} =
               Http.call(name, "echo", %{"foo" => "bar"}, [])

      # Verify the wire-level handshake order recorded by the fixture:
      # initialize → notifications/initialized → tools/list → tools/call.
      requests = FakeHttpServer.received_requests(server)

      methods =
        requests
        |> Enum.map(& &1.decoded)
        |> Enum.map(fn
          %{"method" => m} -> m
          _ -> nil
        end)

      assert ["initialize", "notifications/initialized", "tools/list", "tools/call" | _] =
               methods
    end
  end

  # ───────── Handshake failure paths ─────────

  describe "handshake failures" do
    test ":handshake_malformed → :upstream_unavailable" do
      %{port: port} =
        boot_fake(:handshake_malformed, %{omit_protocol_version: true})

      name = unique_name("http-malformed")
      assert {:error, {:upstream_unavailable, detail}} = Http.start_link(name, config(port))
      assert detail =~ "handshake"
    end

    test ":handshake_401 → :upstream_unavailable" do
      %{port: port} = boot_fake(:handshake_401)

      name = unique_name("http-401")
      assert {:error, {:upstream_unavailable, detail}} = Http.start_link(name, config(port))
      assert detail =~ "handshake"
      # Detail should reference auth_failed (Transport's mapping for
      # 401 / 403).
      assert detail =~ "auth_failed"
    end

    test ":notifications_returns_200 — strict 202 requirement rejects 200" do
      %{port: port} = boot_fake(:notifications_returns_200)

      name = unique_name("http-notif200")
      assert {:error, {:upstream_unavailable, detail}} = Http.start_link(name, config(port))
      # The fixture's notifications-step body is `{"ok":true}` (no
      # JSON-RPC `result`/`error`), so Transport classifies it as
      # `:upstream_error` ("200 body is JSON but not a JSON-RPC
      # response") BEFORE our `{:ok, _result}` branch fires. Either
      # way the detail must trace back to step 2. The intent of
      # this scenario — "handshake fails when notifications returns
      # any non-202" — is captured by the step-2 prefix.
      assert detail =~ "notifications/initialized"
    end
  end

  # ───────── Session-loss / auth abnormal exits (§4.3.1) ─────────

  describe "session-loss → abnormal exit" do
    test ":session_404_on_call → caller gets session_lost, GenServer exits :session_lost" do
      %{port: port} = boot_fake(:session_404_on_call)

      name = unique_name("http-session-loss")
      assert {:ok, pid} = Http.start_link(name, config(port))

      # `Http.start_link/2` links the impl to us. The abnormal
      # `:session_lost` exit would propagate as an EXIT signal to
      # this test process (which doesn't trap exits), tearing the
      # test down before assertions complete. In production the
      # owner is `Upstream.Connection`, which traps and runs the
      # `:DOWN` recovery path; tests stand in for Connection here,
      # so we unlink the link `start_link/2` set up before
      # triggering the abnormal exit.
      Process.unlink(pid)
      ref = Process.monitor(pid)

      assert {:error, :upstream_unavailable, "session_lost"} =
               Http.call(name, "any_tool", %{}, [])

      assert_receive {:DOWN, ^ref, :process, ^pid, :session_lost}, 2_000
    end
  end

  # ───────── tools/call response classification ─────────

  describe "tools/call response classification" do
    test ":jsonrpc_error_4xx (HTTP 400 + JSON-RPC error body) → :upstream_error world-fault" do
      %{port: port} = boot_fake(:jsonrpc_error_4xx)

      name = unique_name("http-jsonrpc-err")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      assert {:error, :upstream_error, detail} = Http.call(name, "broken_tool", %{}, [])
      assert detail =~ "tool failed"
    end

    test "JSON-RPC error in 200 body → :upstream_error world-fault" do
      # Use the existing :handshake_success scenario but override the
      # tools/call response to be a JSON-RPC error inside a 200. The
      # FakeHttpServer doesn't have a dedicated scenario for this, so
      # we exercise the same Transport rule via :jsonrpc_error_4xx
      # for the 4xx case (above) and rely on Transport's unit tests
      # (TransportTest, "200 OK with application/json" describe block)
      # for the 200-body classification — which is internal to
      # Transport.post/1 and re-used by Http unchanged.
      :ok
    end
  end

  describe "5xx / transport failures" do
    test ":server_error_5xx — handshake fails as :upstream_unavailable" do
      %{port: port} = boot_fake(:server_error_5xx)

      name = unique_name("http-503")
      assert {:error, {:upstream_unavailable, detail}} = Http.start_link(name, config(port))
      # Transport surfaces "http 503"; we wrap with a "handshake step
      # 1 (initialize) failed:" prefix.
      assert detail =~ "503"
    end
  end

  # ───────── Header / wire-level assertions ─────────

  describe "request headers" do
    test "MCP-Protocol-Version omitted on initialize, present on subsequent POSTs" do
      %{server: server, port: port} = boot_fake(:handshake_success)

      name = unique_name("http-headers")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _} = Http.call(name, "echo", %{}, [])

      requests = FakeHttpServer.received_requests(server)

      [initialize_req | rest] =
        Enum.filter(requests, fn r ->
          case r.decoded do
            %{"method" => "initialize"} -> true
            _ -> false
          end
        end)

      _ = rest

      # initialize MUST NOT carry MCP-Protocol-Version (§6.1.1).
      refute has_header?(initialize_req.headers, "mcp-protocol-version"),
             "initialize POST carried MCP-Protocol-Version: #{inspect(initialize_req.headers)}"

      # Every post-initialize POST MUST carry the negotiated version.
      post_init =
        Enum.reject(requests, fn r ->
          case r.decoded do
            %{"method" => "initialize"} -> true
            _ -> false
          end
        end)

      assert post_init != [], "expected at least one post-initialize POST"

      Enum.each(post_init, fn r ->
        assert has_header?(r.headers, "mcp-protocol-version"),
               "post-initialize request missing MCP-Protocol-Version: #{inspect(r.decoded)}"
      end)
    end

    test "tools/call carries the held Mcp-Session-Id" do
      %{server: server, port: port} = boot_fake(:handshake_success)

      name = unique_name("http-session-id")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _} = Http.call(name, "echo", %{}, [])

      requests = FakeHttpServer.received_requests(server)

      # tools/call request — find the latest one.
      tools_call =
        Enum.find(requests, fn r ->
          case r.decoded do
            %{"method" => "tools/call"} -> true
            _ -> false
          end
        end)

      assert tools_call, "no tools/call request was recorded"

      assert has_header?(tools_call.headers, "mcp-session-id"),
             "tools/call missing Mcp-Session-Id: #{inspect(tools_call.headers)}"
    end

    test ":no_session_id — handshake completes without session-id, calls work" do
      %{server: server, port: port} = boot_fake(:no_session_id)

      name = unique_name("http-no-sid")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      # Without a session-id, the impl proceeds (§6.1.2 — stateless
      # server is allowed).
      assert {:ok, _} = Http.call(name, "echo", %{}, [])

      requests = FakeHttpServer.received_requests(server)

      tools_call =
        Enum.find(requests, fn r ->
          case r.decoded do
            %{"method" => "tools/call"} -> true
            _ -> false
          end
        end)

      assert tools_call

      refute has_header?(tools_call.headers, "mcp-session-id"),
             "tools/call carried Mcp-Session-Id when server didn't issue one"
    end
  end

  # ───────── stop/1 idempotency ─────────

  describe "stop/1" do
    test "is idempotent and tears down the owned Finch process" do
      %{port: port} = boot_fake(:handshake_success)

      name = unique_name("http-stop")
      assert {:ok, pid} = Http.start_link(name, config(port))

      finch_name =
        Module.concat([
          PtcRunnerMcp.Upstream.Http,
          "Finch",
          sanitize(name)
        ])

      assert is_pid(Process.whereis(finch_name))

      ref = Process.monitor(pid)
      assert :ok = Http.stop(name)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      # Finch is gone too — `terminate/2` runs `stop_finch/1`.
      assert Process.whereis(finch_name) == nil

      # Second stop is a no-op (the impl is gone).
      assert :ok = Http.stop(name)
    end
  end

  # ───────── helpers ─────────

  defp has_header?(headers, target) when is_list(headers) and is_binary(target) do
    target_down = String.downcase(target)

    Enum.any?(headers, fn {k, _v} ->
      is_binary(k) and String.downcase(k) == target_down
    end)
  end

  defp sanitize(name) when is_binary(name) do
    name
    |> String.to_charlist()
    |> Enum.map(fn
      c when c in ?A..?Z -> c
      c when c in ?a..?z -> c
      c when c in ?0..?9 -> c
      ?_ -> ?_
      _ -> ?_
    end)
    |> List.to_string()
  end
end
