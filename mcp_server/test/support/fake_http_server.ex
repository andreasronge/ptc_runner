defmodule PtcRunnerMcp.Test.FakeHttpServer do
  @moduledoc """
  Configurable Streamable HTTP MCP fixture for Phase 2 tests.

  Spec: `Plans/http-transport-credentials.md` §6 (Streamable HTTP
  Transport). The fixture serves the 2025-06-18 wire format.

  ## Usage

      server =
        start_supervised!(
          {PtcRunnerMcp.Test.FakeHttpServer,
           scenario: :handshake_success,
           opts: %{toolset: [%{"name" => "echo", "description" => "..."}]}}
        )

      port = PtcRunnerMcp.Test.FakeHttpServer.port(server)
      url = "http://127.0.0.1:\#{port}/mcp"

      # ...drive Upstream.Http against the URL...

      requests = PtcRunnerMcp.Test.FakeHttpServer.received_requests(server)

  ## Scenarios

  Pass `scenario:` option at start. See
  `Plans/http-transport-credentials.md` §13.2 for scope.

    * `:handshake_success` — full 2025-06-18 handshake; `tools/list`
      returns the configured `:toolset`; `tools/call` returns
      `{"result": ...}`.
    * `:handshake_malformed` — `initialize` response is missing
      `protocolVersion` (or returns a wrong one via
      `opts.protocol_version`).
    * `:handshake_401` — `initialize` returns HTTP 401.
    * `:handshake_timeout` — `initialize` hangs forever (test must
      wrap in its own timeout).
    * `:no_session_id` — handshake succeeds but no `Mcp-Session-Id`
      header is set on the initialize response (stateless server).
    * `:session_404_on_call` — handshake succeeds with a session id;
      every `tools/call` returns HTTP 404 (session-loss simulation).
    * `:notifications_returns_200` — invalid: spec requires 202 on
      notifications-only POST. Used to assert handshake-rejection.
    * `:sse_response_single_message` — `tools/call` returns
      `text/event-stream` with one event carrying one JSON-RPC
      message.
    * `:sse_response_array_form` — `tools/call` returns
      `text/event-stream` with one event whose `data:` is a JSON
      array of messages (legacy/compat path).
    * `:large_response_body` — `tools/call` returns a 4 MiB JSON
      body to exercise `:response_too_large`.
    * `:large_sse_stream` — `tools/call` streams indefinitely; each
      chunk a few KB; never sends a terminating message — used to
      exercise the cumulative SSE cap.
    * `:server_error_5xx` — every request returns HTTP 503.
    * `:rate_limited_429` — every request returns HTTP 429.
    * `:jsonrpc_error_4xx` — handshake succeeds; `tools/call` returns
      HTTP 400 + JSON-RPC error body (must classify as
      `:upstream_error` world-fault per §6.4).
    * `:tools_call_401` — handshake succeeds; `tools/call` returns
      HTTP 401 (post-handshake auth-rotation signal). Phase 3C
      (§4.3.1) — exercises the impl's `:auth_failed` abnormal-exit
      path.
    * `:tools_call_slow` — handshake succeeds; `tools/call` sleeps
      `opts.delay_ms` (default 500) before returning a 200 success
      body. Used to drive pool-exhaustion / queue-timeout coverage
      with a small `pool_size` and `request_timeout_ms` on the
      client side. Phase 2G (§13.2).

  Each scenario MAY accept a per-test `opts:` map for fine-tuning:

    * `:toolset` — list of tool descriptors for `tools/list`
      (`:handshake_success`, `:jsonrpc_error_4xx`, SSE scenarios).
      Default `[]`.
    * `:protocol_version` — string for the negotiated
      `protocolVersion` (defaults to `"2025-06-18"`; set to
      something else for `:handshake_malformed`).
    * `:omit_protocol_version` — `true` to omit `protocolVersion`
      from the initialize response (`:handshake_malformed`).
    * `:session_id` — pre-baked session id; default is a
      `unique_integer` derived value.

  ## Header / body introspection

  Every request is recorded into the agent state; `received_requests/1`
  returns the records in arrival order. Records are
  `%{method: binary, path: binary, headers: [{binary, binary}],
     body: binary, decoded: nil | term}` where `decoded` is the
  Jason-decoded body when the request was JSON, else `nil`.
  """

  use Agent

  alias PtcRunnerMcp.Test.FakeHttpServer.Plug, as: FakePlug

  @type request_record :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          decoded: nil | map() | list()
        }

  @type state :: %{
          port: non_neg_integer(),
          scenario: atom(),
          opts: map(),
          received: [request_record()],
          session_id: String.t() | nil,
          bandit: pid() | nil,
          call_counts: %{optional(String.t()) => non_neg_integer()}
        }

  @doc """
  Start the fixture. Boots a Bandit server on an ephemeral port and
  returns the agent pid that owns it.

  Required option `:scenario` selects request behavior. Optional
  `:opts` map fine-tunes the scenario (see moduledoc).
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(start_opts) do
    scenario = Keyword.fetch!(start_opts, :scenario)
    opts = Keyword.get(start_opts, :opts, %{}) |> Map.new()

    Agent.start_link(fn -> boot(scenario, opts) end)
  end

  @doc "Returns the listening TCP port of the fixture."
  @spec port(Agent.agent()) :: non_neg_integer()
  def port(server) do
    Agent.get(server, & &1.port)
  end

  @doc """
  Returns the recorded request log in arrival order. Each entry is a
  `t:request_record/0` map.
  """
  @spec received_requests(Agent.agent()) :: [request_record()]
  def received_requests(server) do
    Agent.get(server, fn s -> Enum.reverse(s.received) end)
  end

  @doc """
  Stops the fixture and the underlying Bandit server. Idempotent.

  Tests that use `start_supervised!/1` do not need to call this —
  ExUnit terminates the agent when the test ends, which in turn
  terminates the Bandit child via the agent's link.
  """
  @spec stop(Agent.agent()) :: :ok
  def stop(server) do
    if Process.alive?(server) do
      try do
        Agent.stop(server, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ───────── Plug callbacks (called from request process) ─────────

  @doc false
  @spec record_request(pid(), request_record()) :: :ok
  def record_request(server, record) do
    Agent.update(server, fn s -> %{s | received: [record | s.received]} end)
  end

  @doc false
  @spec snapshot(pid()) :: %{scenario: atom(), opts: map(), session_id: String.t() | nil}
  def snapshot(server) do
    Agent.get(server, fn s ->
      %{scenario: s.scenario, opts: s.opts, session_id: s.session_id}
    end)
  end

  @doc false
  @spec bump_call_count(pid(), String.t()) :: non_neg_integer()
  def bump_call_count(server, key) do
    Agent.get_and_update(server, fn s ->
      n = Map.get(s.call_counts, key, 0) + 1
      {n, %{s | call_counts: Map.put(s.call_counts, key, n)}}
    end)
  end

  # ───────── boot ─────────

  defp boot(scenario, opts) do
    session_id =
      Map.get_lazy(opts, :session_id, fn ->
        "test-session-#{:erlang.unique_integer([:positive])}"
      end)

    bandit_opts = [
      plug: {FakePlug, %{controller: self()}},
      scheme: :http,
      port: 0,
      ip: {127, 0, 0, 1},
      # Quiet startup info — tests start many of these.
      startup_log: false
    ]

    {:ok, bandit} = Bandit.start_link(bandit_opts)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(bandit)

    %{
      port: port,
      scenario: scenario,
      opts: opts,
      received: [],
      session_id: session_id,
      bandit: bandit,
      call_counts: %{}
    }
  end
end
