defmodule PtcRunnerMcp.HttpMcpSoakTest do
  @moduledoc """
  Soak test: drive the Streamable HTTP MCP endpoint over a real Bandit
  listener and assert request/session churn does not leak processes,
  memory, concurrency permits, or HTTP-owned PTC-Lisp sessions.

  This complements `mcp_stdio_soak_test.exs`: stdio catches pipe/framing
  leaks, while this test exercises the production HTTP router,
  `Http.SessionRegistry`, `Http.Session`, Bandit request processes, and
  downstream stateful PTC-Lisp session ownership.

  Scenarios:

    * initialize -> notifications/initialized -> stateless
      `ptc_lisp_execute` -> DELETE
    * initialize -> `ptc_session_start` -> forced HTTP registry stop
      and restart

  ## Run

      MIX_ENV=test mix test --only soak \\
        test/soak/http_mcp_soak_test.exs --color

      PTC_SOAK_ITERATIONS=5000 \\
        MIX_ENV=test mix test --only soak \\
        test/soak/http_mcp_soak_test.exs
  """

  use ExUnit.Case, async: false
  import PtcRunnerMcp.TestSupport.WaitHelpers

  alias PtcRunnerMcp.ConcurrencyGate
  alias PtcRunnerMcp.Http.{Config, Server, SessionRegistry}
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.{Owner, Registry}
  alias PtcRunnerMcp.TestSupport.{MemorySoak, SoakHelpers}

  @moduletag :soak
  @moduletag timeout: :infinity

  @token String.duplicate("h", 32)
  @protocol_version "2025-11-25"

  setup do
    SoakHelpers.setup_sessions(%{enabled: true, max_sessions: 100_000})
    ConcurrencyGate.init()
    ConcurrencyGate.reset()

    {:ok, cfg} =
      Config.resolve(%{
        http: true,
        http_auth_token: @token,
        http_max_sessions: 100_000,
        http_max_sessions_per_owner: 100_000,
        http_max_in_flight_per_session: 8,
        http_session_ttl_ms: 3_600_000,
        http_session_idle_timeout_ms: 3_600_000,
        http_request_timeout_ms: 30_000
      })

    cfg = %{cfg | port: 0}
    start_registry!(cfg)
    bandit = start_supervised!(Server.child_spec(cfg))
    {:ok, {_addr, port}} = ThousandIsland.listener_info(bandit)

    on_exit(fn ->
      stop_registry()
      SessionsConfig.reset()
      ConcurrencyGate.reset()
    end)

    {:ok,
     cfg: cfg, url: "http://127.0.0.1:#{port}#{cfg.path}", iters: MemorySoak.iteration_count()}
  end

  test "HTTP session and stateless eval churn returns to baseline", %{url: url, iters: iters} do
    {before, aft} =
      MemorySoak.measure(iters, fn _phase ->
        session_id = initialize!(url)
        initialized!(url, session_id)
        execute_ok!(url, session_id, "(+ 1 2 3)")
        delete!(url, session_id)
      end)

    assert_registry_empty!()

    IO.puts("BEFORE (http stateless churn, n=#{iters}):\n#{MemorySoak.format(before)}")
    IO.puts("AFTER  (http stateless churn, n=#{iters}):\n#{MemorySoak.format(aft)}")

    assert ConcurrencyGate.in_flight() == 0
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 20)
    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 35)
    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 60)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
  end

  test "HTTP registry restart closes owned PTC-Lisp sessions", %{
    cfg: cfg,
    url: url,
    iters: iters
  } do
    registry_iters = max(div(iters, 5), 1)

    {before, aft} =
      MemorySoak.measure(registry_iters, fn _phase ->
        session_id = initialize!(url)
        ptc_session_id = start_ptc_session!(url, session_id)
        owner = Owner.http(session_id)

        assert [_] = Registry.list(owner)

        stop_registry()
        wait_until(fn -> Registry.list(owner) == [] end)
        start_registry!(cfg)

        refute ptc_session_id in Enum.map(Registry.list(owner), & &1.id)
      end)

    assert_registry_empty!()

    IO.puts(
      "BEFORE (http registry restart churn, n=#{registry_iters}):\n#{MemorySoak.format(before)}"
    )

    IO.puts(
      "AFTER  (http registry restart churn, n=#{registry_iters}):\n#{MemorySoak.format(aft)}"
    )

    assert ConcurrencyGate.in_flight() == 0
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 20)
    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 35)
    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 60)
    MemorySoak.assert_atoms_per_iter!(before, aft, registry_iters)
  end

  defp initialize!(url) do
    resp =
      post!(url, %{
        "jsonrpc" => "2.0",
        "id" => "init",
        "method" => "initialize",
        "params" => %{"protocolVersion" => @protocol_version}
      })

    assert resp.status == 200
    assert resp.body["result"]["protocolVersion"] == @protocol_version
    get_header!(resp, "mcp-session-id")
  end

  defp initialized!(url, session_id) do
    resp =
      post!(
        url,
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        session_id: session_id
      )

    assert resp.status == 202
  end

  defp execute_ok!(url, session_id, program) do
    resp =
      post!(
        url,
        %{
          "jsonrpc" => "2.0",
          "id" => "eval",
          "method" => "tools/call",
          "params" => %{
            "name" => "ptc_lisp_execute",
            "arguments" => %{"program" => program, "context" => %{}}
          }
        },
        session_id: session_id
      )

    assert resp.status == 200
    assert get_in(resp.body, ["result", "structuredContent", "status"]) == "ok"
  end

  defp start_ptc_session!(url, session_id) do
    resp =
      post!(
        url,
        %{
          "jsonrpc" => "2.0",
          "id" => "start-session",
          "method" => "tools/call",
          "params" => %{"name" => "ptc_session_start", "arguments" => %{}}
        },
        session_id: session_id
      )

    assert resp.status == 200
    assert get_in(resp.body, ["result", "structuredContent", "status"]) == "ok"
    get_in(resp.body, ["result", "structuredContent", "session_id"])
  end

  defp delete!(url, session_id) do
    resp =
      Req.delete!(url,
        headers: auth_headers(session_id: session_id),
        receive_timeout: 30_000
      )

    assert resp.status == 202
  end

  defp post!(url, body, opts \\ []) do
    Req.post!(url,
      json: body,
      headers: auth_headers(opts),
      receive_timeout: 30_000
    )
  end

  defp auth_headers(opts) do
    [{"authorization", "Bearer " <> @token}] ++ session_headers(opts)
  end

  defp session_headers(opts) do
    case Keyword.get(opts, :session_id) do
      nil ->
        []

      session_id ->
        [
          {"mcp-session-id", session_id},
          {"mcp-protocol-version", @protocol_version}
        ]
    end
  end

  defp get_header!(%Req.Response{headers: headers}, name) do
    name = String.downcase(name)

    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> flunk("missing response header #{name}: #{inspect(headers)}")
    end
  end

  defp start_registry!(cfg) do
    stop_registry()
    {:ok, _pid} = SessionRegistry.start_link(config: cfg)
    :ok
  end

  defp stop_registry do
    case Process.whereis(SessionRegistry) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  defp assert_registry_empty! do
    case Process.whereis(SessionRegistry) do
      nil ->
        :ok

      pid ->
        state = :sys.get_state(pid, 5_000)
        assert map_size(state.sessions) == 0
        assert state.by_owner == %{}
    end
  end
end
