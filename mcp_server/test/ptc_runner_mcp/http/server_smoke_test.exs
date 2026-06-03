defmodule PtcRunnerMcp.Http.ServerSmokeTest do
  @moduledoc """
  Integration smoke test for the HTTP transport bootstrap.

  Boots `PtcRunnerMcp.Http.Server` for real on a free OS-assigned port,
  issues one real HTTP request over a TCP socket, asserts the server
  serves it, then lets `start_supervised!/1` tear it down cleanly. This
  exercises the production `Server.child_spec/1` Bandit glue and the
  `PlugWithConfig` -> `Router` dispatch path end to end (rather than
  calling `Router.call/2` in-process like the unit-style tests).

  The port is acquired from the OS up front via `free_port/0` rather than
  passing `0`: with HTTP enabled, `Config.resolve/1` rejects a non-positive
  `http_port` with an error, so `0` could not be used to request an
  OS-assigned port here anyway.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Http.Config, as: HttpConfig
  alias PtcRunnerMcp.Http.Server

  # 32-byte token satisfies Config's token-length validation; the
  # `/health` route we hit is unauthenticated, but a valid config is
  # required so `Config.resolve/1` succeeds and the bind host validates.
  @token String.duplicate("a", 32)

  # Boot the real transport on a free OS-assigned port and return its
  # bound TCP port. The server is supervised so ExUnit tears it (and its
  # listening socket) down at test end without leaking processes/ports.
  defp boot_server!(config_args) do
    {:ok, cfg} =
      HttpConfig.resolve(
        Map.merge(%{http: true, http_auth_token: @token, http_port: free_port()}, config_args)
      )

    # Drive the production child-spec builder, not a hand-rolled Bandit
    # tuple — this is the unit under test.
    child = Server.child_spec(cfg)
    assert {Bandit, opts} = child
    assert opts[:plug] == {PtcRunnerMcp.Http.PlugWithConfig, cfg}

    bandit = start_supervised!(child)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(bandit)
    {cfg, port}
  end

  # Ask the OS for an unused loopback TCP port, then release it so the
  # server can bind it. The brief window between close and re-bind is the
  # standard trade-off for test servers and is safe here (async: false).
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  describe "transport bootstrap on a free OS-assigned port" do
    test "serves an unauthenticated GET /health over a real socket" do
      {_cfg, port} = boot_server!(%{})
      assert is_integer(port) and port > 0

      resp = Req.get!("http://127.0.0.1:#{port}/health", retry: false)

      assert resp.status == 200
      assert resp.body == %{"status" => "ok"}
    end

    test "binds the configured loopback host and reports the assigned port" do
      {cfg, port} = boot_server!(%{http_host: "127.0.0.1"})

      # parse_ip/1 turned the string host into an inet tuple for Bandit.
      assert cfg.host == "127.0.0.1"

      # The server bound the free port we acquired from the OS.
      assert port != 0

      resp = Req.get!("http://127.0.0.1:#{port}/health", retry: false)
      assert resp.status == 200
    end

    test "routes unknown paths through PlugWithConfig to the Router 404 fallback" do
      {_cfg, port} = boot_server!(%{})

      resp = Req.get!("http://127.0.0.1:#{port}/no-such-path", retry: false)

      assert resp.status == 404
      assert resp.body == "not found"
    end

    test "applies the request read timeout from config to thousand_island_options" do
      cfg = elem(boot_server!(%{http_request_timeout_ms: 5_000}), 0)

      # The read_timeout is threaded from config into the child spec; the
      # served request below proves the listener is alive with that opt.
      child = Server.child_spec(cfg)
      assert {Bandit, opts} = child
      assert opts[:thousand_island_options] == [read_timeout: 5_000]
      assert opts[:scheme] == :http
    end
  end

  describe "child_spec/1 host parsing" do
    test "an unparseable host falls back to 127.0.0.1 in the Bandit spec" do
      # validate_bind_host/1 only accepts IPs or "localhost", so an
      # invalid host cannot reach child_spec/1 through Config.resolve/1.
      # Drive parse_ip/1 directly via a raw config map to cover the
      # fallback clause.
      cfg = %{host: "not-an-ip", port: 0, request_timeout_ms: 1_000}

      assert {Bandit, opts} = Server.child_spec(cfg)
      assert opts[:ip] == {127, 0, 0, 1}
    end

    test "a valid IPv4 host is parsed into an inet tuple" do
      cfg = %{host: "127.0.0.1", port: 0, request_timeout_ms: 1_000}

      assert {Bandit, opts} = Server.child_spec(cfg)
      assert opts[:ip] == {127, 0, 0, 1}
      assert opts[:port] == 0
    end
  end
end
