defmodule PtcRunnerMcp.Http.RouterCase do
  @moduledoc """
  Shared setup and conn helpers for the router dispatch integration tests
  (`http/router_*_test.exs`).

  These tests exercise `Router.call/2` in-process and all depend on the same
  ~20-line setup: a fresh `SessionRegistry`, a seeded `:http_config`, an
  initialized `ConcurrencyGate`, and trace/log cleanup. Extracted here (issue
  #1076) so the four concern-split files share one setup instead of drifting
  copies.

  Every using module is `async: false`: the tests mutate global `Application`
  env and a named registry, so they cannot run concurrently.
  """
  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import Plug.Conn
  import Plug.Test

  alias PtcRunnerMcp.Http.Config, as: HttpConfig
  alias PtcRunnerMcp.Http.Router
  alias PtcRunnerMcp.Http.SessionRegistry
  alias PtcRunnerMcp.Log
  alias PtcRunnerMcp.McpTestHelpers
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.TraceConfig
  alias PtcRunnerMcp.TraceHandler

  @token String.duplicate("a", 32)

  @doc "The shared bearer token seeded into the test `:http_config`."
  def token, do: @token

  using do
    quote do
      use ExUnit.Case, async: false

      import Plug.Conn
      import Plug.Test
      import PtcRunnerMcp.Http.RouterCase
      import PtcRunnerMcp.TestSupport.WaitHelpers

      @token PtcRunnerMcp.Http.RouterCase.token()
    end
  end

  setup context do
    McpTestHelpers.stop_existing_registry(SessionRegistry)
    {:ok, cfg} = HttpConfig.resolve(%{http: true, http_auth_token: @token})
    cfg = %{cfg | max_sessions: Map.get(context, :max_sessions, cfg.max_sessions)}
    Application.put_env(:ptc_runner_mcp, :http_config, cfg)
    start_supervised!({SessionRegistry, [config: cfg]})
    PtcRunnerMcp.ConcurrencyGate.init()
    PtcRunnerMcp.ConcurrencyGate.reset()

    original_trace = TraceConfig.get()
    original_log_level = Log.level()

    on_exit(fn ->
      SessionsConfig.set(SessionsConfig.defaults())
      TraceConfig.set(original_trace)
      TraceHandler.detach()
      Log.set_level(original_log_level)
    end)

    {:ok, cfg: cfg}
  end

  @doc "Add the valid bearer authorization header."
  def auth(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  @doc """
  Dispatch a conn through `Router.call/2`.

  `Plug.Test.conn/3` defaults the host to `www.example.com`; rewrite that to a
  loopback host so default conns pass the Host guard.
  """
  def call(%{host: host} = conn) when host in ["example.com", "www.example.com"],
    do: conn |> with_host("127.0.0.1") |> Router.call([])

  def call(conn), do: Router.call(conn, [])

  @doc "Override the conn host (and a non-loopback port) for Host-guard tests."
  def with_host(conn, host), do: %{conn | host: host, port: 7332}

  @doc "Initialize an HTTP session and return its `mcp-session-id`."
  def initialize_session(protocol_version \\ nil) do
    params =
      case protocol_version do
        nil -> %{}
        version -> %{"protocolVersion" => version}
      end

    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "i",
          "method" => "initialize",
          "params" => params
        })
      )
      |> auth()
      |> call()

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end
end
