defmodule PtcRunnerMcp.Upstream.Http do
  @moduledoc """
  Streamable HTTP transport implementation of `PtcRunnerMcp.Upstream`
  (MCP rev 2025-06-18).

  Conforms to the same behaviour as `PtcRunnerMcp.Upstream.Stdio`; the
  Connection layer dispatches against `impl: PtcRunnerMcp.Upstream.Http`
  for upstreams configured with `transport: "http"`. No behaviour
  shape change (`Plans/http-transport-credentials.md` §4.1).

  ## Lifecycle

    * `start_link/2` opens a dedicated named Finch process for the
      upstream's pool, then runs the three-step handshake
      synchronously: `initialize` → `notifications/initialized`
      (expects HTTP 202) → `tools/list`. On any handshake-step failure
      `init/1` returns `{:stop, {:upstream_unavailable, detail}}`,
      which the owning Connection observes as a non-fatal init error
      (catalog renders the upstream as "(unavailable at startup)"
      per §4.3).
    * `call/4` issues a `tools/call` POST per request, threading a
      monotonically-increasing JSON-RPC id and the held
      `Mcp-Session-Id` (if any) through `Session.headers_for_post/2`.
      Per-call `:timeout` and `:max_response_bytes` are clamped
      against the upstream-level defaults.
    * `stop/1` is idempotent; on `terminate/2` we issue a best-effort
      `DELETE <url>` to release the session id (§6.1, third bullet)
      and stop the owned Finch process.

  ## Session loss → impl exits abnormally (§4.3.1 / §6.3)

  When the server returns HTTP 404 to a request that carried our
  held `Mcp-Session-Id`, we reply to the in-flight caller with
  `{:error, :upstream_unavailable, "session_lost"}` and then
  `{:stop, :session_lost, state}` ourselves. The owning Connection's
  `:DOWN` monitor (`upstream/connection.ex:446`) fires;
  `abnormal_exit?(:session_lost)` returns `true` per
  `connection.ex:629`, so Connection invalidates `cached_tools`,
  transitions to `:not_started`, and arms `backoff_until_ms`.
  The next `(tool/mcp-call …)` cold-starts a fresh impl with a fresh
  handshake. Same path applies to `:auth_failed` (post-handshake 401
  / 403 — wired here even though Phase 2 has no auth, so Phase 3 only
  needs to add credential rotation).

  Connection itself is NOT modified by this stream; the `:DOWN` +
  `abnormal_exit?/1` path is reused verbatim.

  ## Optional `:req` dependency

  `:req` is an optional Mix dep (`mix.exs`). The compile path here
  has no `alias Req` and does not call `Req.*` at module scope; all
  network calls go through `Upstream.Http.Transport` which uses
  `Code.ensure_loaded?(Req)` plus fully-qualified `Req.post/2` call
  sites. `PtcRunnerMcp.Application.check_http_deps!/3` raises at
  config load if any HTTP upstream is configured without `:req`,
  so reaching `init/1` here implies `:req` is loaded.

  See `Plans/http-transport-credentials.md` §6 for the wire format
  and §4.3 / §4.3.1 / §6.3 for lifecycle semantics.
  """

  @behaviour PtcRunnerMcp.Upstream

  use GenServer

  alias PtcRunnerMcp.Log
  alias PtcRunnerMcp.Upstream
  alias PtcRunnerMcp.Upstream.Http.{Session, Transport}

  @registry __MODULE__.Names

  @default_handshake_timeout_ms 10_000
  @default_request_timeout_ms 30_000
  @default_connect_timeout_ms 5_000
  @default_max_response_bytes 2 * 1024 * 1024
  @default_pool_size 4

  @client_info %{"name" => "ptc-runner-mcp", "version" => "0.1.0"}

  # ----------------------------------------------------------------
  # Behaviour callbacks
  # ----------------------------------------------------------------

  @impl Upstream
  @spec start_link(Upstream.server_name(), map()) :: GenServer.on_start()
  def start_link(name, config) when is_binary(name) and is_map(config) do
    # Mirror `Upstream.Stdio.start_link/2`: trap exits around the
    # inner `GenServer.start_link/3` so an `init/1` returning
    # `{:stop, _}` (handshake failure path) does NOT propagate as
    # an EXIT signal that crashes the caller. The caller is
    # typically `Upstream.Connection`'s `init/1`, which has not yet
    # enabled trap_exit at the moment it invokes us.
    parent_trap = Process.flag(:trap_exit, true)

    try do
      GenServer.start_link(__MODULE__, {name, config}, name: via(name))
    after
      Process.flag(:trap_exit, parent_trap)
    end
  end

  @impl Upstream
  @spec list_tools(Upstream.server_name()) ::
          {:ok, [Upstream.tool_schema()]} | {:error, Upstream.reason(), String.t()}
  def list_tools(name) when is_binary(name) do
    case whereis(name) do
      nil -> {:error, :upstream_unavailable, "http upstream '#{name}' is not running"}
      pid -> GenServer.call(pid, :list_tools)
    end
  end

  @impl Upstream
  @spec call(Upstream.server_name(), Upstream.tool_name(), map(), Upstream.call_opts()) ::
          {:ok, Upstream.json()} | {:error, Upstream.reason(), String.t()}
  def call(name, tool_name, args, opts)
      when is_binary(name) and is_binary(tool_name) and is_map(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_request_timeout_ms)
    max_bytes = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    case whereis(name) do
      nil ->
        {:error, :upstream_unavailable, "http upstream '#{name}' is not running"}

      pid ->
        # Add a small buffer over the application timeout so the impl
        # gets a chance to surface `:timeout` from the HTTP layer
        # before the GenServer call gives up. If the GenServer call
        # itself times out (impl wedged), the caller gets
        # `:upstream_error` rather than `:timeout` — same convention
        # as `Upstream.Stdio.call/4`.
        try do
          GenServer.call(pid, {:tools_call, tool_name, args, timeout, max_bytes}, timeout + 1_000)
        catch
          :exit, {:timeout, _} ->
            {:error, :upstream_error, "http transport timeout"}

          :exit, {:noproc, _} ->
            {:error, :upstream_unavailable, "http upstream '#{name}' exited"}

          :exit, reason ->
            {:error, :upstream_error, "http call exited: #{inspect(reason, limit: 50)}"}
        end
    end
  rescue
    e -> {:error, :upstream_error, "http call raised: #{Exception.message(e)}"}
  end

  @impl Upstream
  @spec stop(Upstream.server_name()) :: :ok
  def stop(name) when is_binary(name) do
    case whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # ----------------------------------------------------------------
  # Public helper for the supervision tree
  # ----------------------------------------------------------------

  @doc false
  @spec child_spec_for_registry() :: {module(), keyword()}
  def child_spec_for_registry do
    {Registry, keys: :unique, name: @registry}
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl GenServer
  def init({name, config}) do
    # Snapshot the parent pid so we can stop cleanly if it dies before
    # invoking `stop/1` — same defense as `Upstream.Stdio` (codex
    # review of `fe72ff6`). Without this, a Connection killed before
    # its `terminate/2` runs would leave the impl GenServer running
    # and the per-name `Names` registration occupied.
    parent_pid =
      case Process.info(self(), :links) do
        {:links, [pid | _]} when is_pid(pid) -> pid
        _ -> nil
      end

    Process.flag(:trap_exit, true)

    state = %{
      name: name,
      config: config,
      session: Session.new(),
      finch_name: nil,
      tools: nil,
      url: Map.fetch!(config, :url),
      static_headers: Map.get(config, :static_headers, []) || [],
      handshake_timeout_ms: Map.get(config, :handshake_timeout_ms, @default_handshake_timeout_ms),
      request_timeout_ms: Map.get(config, :request_timeout_ms, @default_request_timeout_ms),
      connect_timeout_ms: Map.get(config, :connect_timeout_ms, @default_connect_timeout_ms),
      max_response_bytes: Map.get(config, :max_response_bytes, @default_max_response_bytes),
      pool_size: Map.get(config, :pool_size, @default_pool_size),
      proxy: Map.get(config, :proxy, nil),
      parent_pid: parent_pid
    }

    case start_finch(state) do
      {:ok, state} ->
        case do_handshake(state) do
          {:ok, state} ->
            {:ok, state}

          {:error, detail} ->
            stop_finch(state)
            {:stop, {:upstream_unavailable, detail}}
        end

      {:error, detail} ->
        {:stop, {:upstream_unavailable, detail}}
    end
  end

  @impl GenServer
  def handle_call(:list_tools, _from, state) do
    {:reply, {:ok, state.tools || []}, state}
  end

  def handle_call({:tools_call, tool_name, args, timeout_ms, max_bytes}, from, state) do
    {id, session} = Session.next_request_id(state.session)

    headers = Session.headers_for_post(session, state.static_headers)

    body_map = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => args}
    }

    state = %{state | session: session}

    case encode_body(body_map) do
      {:ok, encoded} ->
        post_opts = [
          finch: state.finch_name,
          url: state.url,
          headers: headers,
          body: encoded,
          request_timeout_ms: min(state.request_timeout_ms, timeout_ms),
          connect_timeout_ms: state.connect_timeout_ms,
          max_response_bytes: min(state.max_response_bytes, max_bytes),
          jsonrpc_id: id
        ]

        case Transport.post(post_opts) do
          {:ok, result} ->
            {:reply, {:ok, result}, state}

          :ok ->
            # Transport returned 202 to a `tools/call` — the spec says
            # 202 is reserved for notifications-only POSTs. Treat as
            # a server contract violation (world-fault).
            {:reply,
             {:error, :upstream_error, "tools/call returned 202 (expected 200 with result)"},
             state}

          {:error, :upstream_unavailable, "http 404"} ->
            handle_possible_session_loss(from, state)

          {:error, :upstream_unavailable, "auth_failed"} ->
            handle_auth_failure(from, state)

          {:error, reason, detail}
          when reason in [
                 :upstream_unavailable,
                 :upstream_error,
                 :timeout,
                 :response_too_large
               ] ->
            {:reply, {:error, reason, detail}, state}
        end

      {:error, detail} ->
        {:reply, {:error, :upstream_error, "encode failed: #{detail}"}, state}
    end
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{parent_pid: parent} = state)
      when is_pid(pid) and pid == parent do
    # Parent (owning `Upstream.Connection` in production) is shutting
    # us down via a link signal. Stop cleanly so `terminate/2` runs
    # the best-effort DELETE and stops Finch — mirrors Stdio.
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Trap-exit also catches Finch's exit (we own it), plus any other
    # linked process. Finch death mid-request will surface as a
    # transport error on the next `Transport.post/1`; pass-through
    # here.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # §6.1, third bullet: best-effort `DELETE <url>` to release the
    # session id. A 404 / connection-refused is fine — we are tearing
    # down anyway. Wrap in try/rescue/catch because Req may raise on
    # malformed URL or if the host has gone away.
    try do
      delete_session(state)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    stop_finch(state)
    :ok
  end

  # ----------------------------------------------------------------
  # Handshake
  # ----------------------------------------------------------------

  defp do_handshake(state) do
    with {:ok, state} <- handshake_initialize(state),
         {:ok, state} <- handshake_notifications_initialized(state) do
      handshake_tools_list(state)
    end
  end

  defp handshake_initialize(state) do
    # `MCP-Protocol-Version` MUST be omitted on the initialize POST
    # itself per §6.1.1 — `Session.headers_for_initialize/2` enforces
    # this. `Session.initialize_body/2` allocates id=1 (the first id
    # from a fresh session) but doesn't bump the session itself, so
    # we burn the id explicitly via `next_request_id/1` to keep the
    # invariant "every wire id is allocated exactly once."
    body_map = Session.initialize_body(state.session, @client_info)
    {id, session} = Session.next_request_id(state.session)
    state = %{state | session: session}

    headers = Session.headers_for_initialize(state.session, state.static_headers)

    case post_with_meta(state, headers, body_map, id) do
      {:ok, %{status: status, headers: resp_headers, body: body}} ->
        case Session.apply_initialize_response(state.session, %{
               status: status,
               headers: headers_to_list(resp_headers),
               body: body
             }) do
          {:ok, session} ->
            {:ok, %{state | session: session}}

          {:error, _reason, detail} ->
            {:error, "handshake step 1 (initialize) failed: #{detail}"}
        end

      :ok ->
        {:error, "handshake step 1 (initialize) returned 202 (expected 200 with result)"}

      {:error, _reason, detail} ->
        {:error, "handshake step 1 (initialize) failed: #{detail}"}
    end
  end

  defp handshake_notifications_initialized(state) do
    body_map = Session.notifications_initialized_body()
    headers = Session.headers_for_post(state.session, state.static_headers)

    # Notifications carry no JSON-RPC id; pass `nil` for SSE
    # correlation. Per §6.2 step 2, the server MUST return 202
    # (Transport's mapper translates to `:ok`).
    case post(state, headers, body_map, nil) do
      :ok ->
        {:ok, %{state | session: Session.apply_handshake_complete(state.session)}}

      {:ok, _result} ->
        {:error, "handshake step 2 (notifications/initialized) returned 200 (expected 202)"}

      {:error, _reason, detail} ->
        {:error, "handshake step 2 (notifications/initialized) failed: #{detail}"}
    end
  end

  defp handshake_tools_list(state) do
    {body_map, session} = Session.tools_list_body(state.session)
    state = %{state | session: session}

    headers = Session.headers_for_post(state.session, state.static_headers)
    id = body_map["id"]

    case post(state, headers, body_map, id) do
      {:ok, result} ->
        # Transport's contract guarantees `result` is a map on the
        # `:ok` branch (it surfaces `body["result"]` from a 200 +
        # `application/json` response, and the JSON-RPC `result`
        # field for `tools/list` is the `%{"tools" => [...]}` object).
        # `extract_tools/1` defends against the off-spec case where
        # `tools` is missing or non-list by returning `[]`.
        tools = extract_tools(result)
        {:ok, %{state | tools: tools}}

      :ok ->
        {:error, "handshake step 3 (tools/list) returned 202 (expected 200)"}

      {:error, _reason, detail} ->
        {:error, "handshake step 3 (tools/list) failed: #{detail}"}
    end
  end

  defp extract_tools(%{"tools" => tools}) when is_list(tools) do
    Enum.map(tools, fn t ->
      base = %{
        name: Map.get(t, "name") || "",
        input_schema: Map.get(t, "inputSchema") || Map.get(t, "input_schema") || %{}
      }

      case Map.get(t, "description") do
        nil -> base
        "" -> base
        desc when is_binary(desc) -> Map.put(base, :description, desc)
      end
    end)
  end

  defp extract_tools(_), do: []

  # ----------------------------------------------------------------
  # Session-loss / auth-failure handling (§4.3.1)
  # ----------------------------------------------------------------

  defp handle_possible_session_loss(from, state) do
    if Session.session_lost?(state.session, %{status: 404}) do
      # Hold a session id and the server returned 404 — this is the
      # spec's session-loss signal. Reply to the caller, then exit
      # abnormally so the owning Connection arms backoff per §4.3.
      GenServer.reply(from, {:error, :upstream_unavailable, "session_lost"})

      Log.log(:info, "http_upstream_session_lost", %{
        name: state.name,
        url: state.url
      })

      {:stop, :session_lost, state}
    else
      # 404 without a held session id is just a 404 (likely a
      # misconfigured URL or upstream-side route mismatch). Surface
      # it as `:upstream_unavailable` and stay alive.
      {:reply, {:error, :upstream_unavailable, "http 404"}, state}
    end
  end

  defp handle_auth_failure(from, state) do
    # §4.3.1: post-handshake 401/403 is the spec's auth-rotation
    # signal. Reply to the caller, then exit abnormally. Phase 2 has
    # no auth (so this is unreachable in practice unless a server
    # spuriously returns 401 to an unauthenticated POST), but the
    # wiring lives here so Phase 3 only adds credential rotation.
    GenServer.reply(from, {:error, :upstream_unavailable, "auth_failed"})

    Log.log(:info, "http_upstream_auth_failed", %{
      name: state.name,
      url: state.url
    })

    {:stop, :auth_failed, state}
  end

  # ----------------------------------------------------------------
  # Transport wrappers
  # ----------------------------------------------------------------

  defp post(state, headers, body_map, jsonrpc_id) do
    case encode_body(body_map) do
      {:ok, encoded} ->
        Transport.post(
          finch: state.finch_name,
          url: state.url,
          headers: headers,
          body: encoded,
          request_timeout_ms: state.handshake_timeout_ms,
          connect_timeout_ms: state.connect_timeout_ms,
          max_response_bytes: state.max_response_bytes,
          jsonrpc_id: jsonrpc_id
        )

      {:error, detail} ->
        {:error, :upstream_error, "encode failed: #{detail}"}
    end
  end

  defp post_with_meta(state, headers, body_map, jsonrpc_id) do
    case encode_body(body_map) do
      {:ok, encoded} ->
        Transport.post_with_meta(
          finch: state.finch_name,
          url: state.url,
          headers: headers,
          body: encoded,
          request_timeout_ms: state.handshake_timeout_ms,
          connect_timeout_ms: state.connect_timeout_ms,
          max_response_bytes: state.max_response_bytes,
          jsonrpc_id: jsonrpc_id
        )

      {:error, detail} ->
        {:error, :upstream_error, "encode failed: #{detail}"}
    end
  end

  defp encode_body(body_map) do
    case Jason.encode(body_map) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, inspect(reason, limit: 5)}
    end
  end

  # Req surfaces response headers as a map of lowercased name → list
  # of values; `Session.apply_initialize_response/2` wants
  # `[{name, value}]` (case-insensitive lookup happens inside
  # Session). Flatten the map.
  # Req.Response.headers is always a map of lowercased name → list of
  # values; `Transport.post_with_meta/1` surfaces it directly. We
  # flatten to `[{name, value}]` for `Session.apply_initialize_response/2`,
  # which is built around the case-insensitive list-of-tuples shape.
  defp headers_to_list(headers) when is_map(headers) do
    Enum.flat_map(headers, fn
      {k, vs} when is_list(vs) -> Enum.map(vs, fn v -> {k, to_string(v)} end)
      {k, v} -> [{k, to_string(v)}]
    end)
  end

  # ----------------------------------------------------------------
  # Finch lifecycle
  # ----------------------------------------------------------------

  defp start_finch(state) do
    finch_name = finch_name(state.name)

    # Connect-timeout lives on the Finch pool's `:conn_opts` because
    # Req rejects `:connect_options` together with `:finch` (the
    # pool owns connect-time configuration when caller-supplied).
    # `:transport_opts` is the Mint-level option that takes
    # `:timeout` for the TCP/TLS handshake.
    conn_opts = [transport_opts: [timeout: state.connect_timeout_ms]]

    conn_opts =
      case state.proxy do
        nil -> conn_opts
        url when is_binary(url) -> Keyword.put(conn_opts, :proxy, parse_proxy(url))
      end

    pool_opts = [size: state.pool_size, conn_opts: conn_opts]

    case Finch.start_link(name: finch_name, pools: %{:default => pool_opts}) do
      {:ok, _pid} ->
        {:ok, %{state | finch_name: finch_name}}

      {:error, {:already_started, _pid}} ->
        # Re-using an existing Finch pool with the same name is fine
        # — typically happens in tests where the GenServer init/1
        # crashes during handshake but we don't tear down Finch
        # before the supervisor restarts us. Treat as success.
        {:ok, %{state | finch_name: finch_name}}

      {:error, reason} ->
        {:error, "finch start_link failed: #{inspect(reason, limit: 5)}"}
    end
  end

  defp stop_finch(%{finch_name: nil}), do: :ok

  defp stop_finch(%{finch_name: name}) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> safe_stop_finch(pid)
    end
  end

  defp safe_stop_finch(pid) do
    try do
      # Finch is a Supervisor; stop it cleanly. 5 s is plenty — pool
      # connections close on their own.
      Supervisor.stop(pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # The Finch process name MUST be a unique atom per upstream. Build
  # it from a sanitized version of the upstream name to avoid
  # `String.to_atom/1` on user input (memory leak / atom-table
  # exhaustion). `Module.concat/1` interns atoms but only if the
  # input is well-formed — we restrict to `[A-Za-z0-9_]`.
  defp finch_name(name) when is_binary(name) do
    safe = safe_name(name)
    Module.concat([__MODULE__, "Finch", safe])
  end

  defp safe_name(name) when is_binary(name) do
    sanitized =
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

    case sanitized do
      "" -> "Anon"
      s -> s
    end
  end

  defp parse_proxy(url) when is_binary(url) do
    # Req accepts `proxy: {scheme, host, port, opts}` — we delegate
    # parsing to `URI.new!/1` and let Mint handle the rest.
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port}}
      when is_binary(scheme) and is_binary(host) and is_integer(port) ->
        {String.to_atom(scheme), host, port, []}

      _ ->
        # Malformed proxy URL — pass through verbatim and let Req
        # reject it at request time.
        url
    end
  end

  # ----------------------------------------------------------------
  # Session DELETE on stop
  # ----------------------------------------------------------------

  defp delete_session(state) do
    if state.session.handshake_complete? and Code.ensure_loaded?(Req) do
      headers = Session.headers_for_post(state.session, state.static_headers)

      Req.request(
        method: :delete,
        url: state.url,
        headers: headers,
        finch: state.finch_name,
        receive_timeout: 1_000,
        connect_options: [timeout: 1_000],
        retry: false
      )
    else
      :ok
    end
  end

  # ----------------------------------------------------------------
  # Registry helpers
  # ----------------------------------------------------------------

  defp via(name) do
    {:via, Registry, {@registry, name}}
  end

  defp whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
