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

  ## Caller-process dispatch (§4.1)

  `call/4` runs the HTTP request from the caller process so multiple
  concurrent `tools/call` invocations against the same upstream
  proceed in parallel (Finch's pool, sized via `:pool_size`, governs
  HTTP-level concurrency). The impl GenServer is consulted only for
  a fast `:checkout_request` mailbox call that atomically allocates
  the next JSON-RPC id and returns a snapshot of the wire-config.
  This mirrors `Upstream.Stdio`, which also serializes only the
  per-request bookkeeping at the impl mailbox while the wire I/O
  runs from the caller.

  ## Session loss → impl exits abnormally (§4.3.1 / §6.3)

  When the server returns HTTP 404 to a request that carried our
  held `Mcp-Session-Id`, the caller process gets
  `{:error, :upstream_unavailable, "session_lost"}` and fires a
  `GenServer.cast(impl, :session_lost)` so the impl exits abnormally.
  The owning Connection's `:DOWN` monitor
  (`upstream/connection.ex:446`) fires; `abnormal_exit?(:session_lost)`
  returns `true` per `connection.ex:629`, so Connection invalidates
  `cached_tools`, transitions to `:not_started`, and arms
  `backoff_until_ms`. The next `(tool/mcp-call …)` cold-starts a
  fresh impl with a fresh handshake. Same path applies to
  `:auth_failed` (post-handshake 401, plus per-request auth-resolution
  failures — wired here even though Phase 2 has no auth, so Phase 3
  only needs to add credential rotation).

  If two concurrent callers both detect session-loss, both cast —
  whichever arrives first triggers the stop, the rest are dropped by
  the GenServer (or fall through `safe_cast/2`'s noproc catch).

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

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.RedactedHeaders
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
        # Two-phase dispatch (fix for codex P1 against `76f68de` —
        # serialized HTTP calls violate §§4.1, 6.5, 10):
        #
        #   1. Fast `GenServer.call(pid, :checkout_request)` — atomically
        #      allocates the next JSON-RPC id and returns a snapshot of
        #      everything `Transport.post/1` needs (url, finch_name,
        #      headers, timeouts, max_bytes). This call holds the impl's
        #      mailbox for microseconds — id allocation only.
        #   2. Caller process runs `Transport.post/1` directly so
        #      multiple in-flight `tools/call`s against the same upstream
        #      proceed in parallel; Finch's connection pool handles
        #      queueing per `pool_size`.
        #
        # On session-loss / auth-failure we fire-and-forget a
        # `GenServer.cast(pid, ...)` to trigger the impl's abnormal exit
        # so the owning Connection's `:DOWN` path arms backoff per §4.3.
        # Multiple concurrent callers detecting the same session-loss
        # both cast — the second cast is a no-op on a stopping
        # GenServer.
        try do
          do_call(pid, name, tool_name, args, timeout, max_bytes)
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

  # Caller-process implementation of `call/4`. Splits into a fast
  # mailbox-bound id-allocation step plus a long-running
  # `Transport.post/1` that runs concurrently across callers.
  defp do_call(pid, name, tool_name, args, timeout_ms, max_bytes) do
    # Tight checkout — id allocation only. 5_000 ms ceiling protects
    # against an impl wedged in `init/1` or a long `terminate/2`; in
    # the steady state this returns in microseconds.
    case GenServer.call(pid, :checkout_request, 5_000) do
      {:ok, snap} ->
        body_map = %{
          "jsonrpc" => "2.0",
          "id" => snap.request_id,
          "method" => "tools/call",
          "params" => %{"name" => tool_name, "arguments" => args}
        }

        case encode_body(body_map) do
          {:ok, encoded} ->
            post_opts = [
              finch: snap.finch_name,
              url: snap.url,
              headers: snap.headers,
              body: encoded,
              request_timeout_ms: min(snap.request_timeout_ms, timeout_ms),
              connect_timeout_ms: snap.connect_timeout_ms,
              max_response_bytes: min(snap.max_response_bytes, max_bytes),
              jsonrpc_id: snap.request_id
            ]

            # §11 telemetry — wrap the wire call with
            # `:upstream, :http, :request, :start | :stop`. Try/rescue/catch
            # ensures `:stop` fires even if `Transport.post/1` raises
            # (it shouldn't — its public contract is total — but
            # operators rely on `:stop`-counts as the canonical
            # "request happened" signal).
            result =
              with_request_telemetry(snap.name, "tools/call", fn ->
                Transport.post(post_opts)
              end)

            classify_post_result(result, pid, snap)

          {:error, detail} ->
            {:error, :upstream_error, "encode failed: #{detail}"}
        end

      {:error, reason, detail} ->
        {:error, reason, detail}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :upstream_unavailable, "http upstream '#{name}' exited"}

    :exit, {:timeout, _} ->
      {:error, :upstream_error, "http checkout timeout"}
  end

  # Map `Transport.post/1` results, casting session-loss / auth-failure
  # signals back to the impl GenServer so its abnormal exit triggers
  # Connection backoff per §4.3.1.
  defp classify_post_result({:ok, result}, _pid, _snap), do: {:ok, result}

  defp classify_post_result(:ok, _pid, _snap) do
    # 202 to a `tools/call` is a server contract violation (§6.4
    # reserves 202 for notifications-only POSTs).
    {:error, :upstream_error, "tools/call returned 202 (expected 200 with result)"}
  end

  defp classify_post_result({:error, :upstream_unavailable, "http 404"}, pid, snap) do
    if snap.has_session_id? do
      # Held a session id and the server returned 404 — §6.3 session-
      # loss signal. Cast to the impl so it exits :session_lost; the
      # owning Connection's `:DOWN` monitor arms backoff. Cast is
      # fire-and-forget; if the GenServer is already dead (race with
      # another concurrent caller's cast), the message is dropped.
      #
      # §11 telemetry — `:session_lost` event fires here (caller-side)
      # so the `prior_session_id_hash` reflects the id we actually
      # held. The impl's `handle_cast(:session_lost, ...)` does NOT
      # double-emit; it only logs + exits. Multiple concurrent callers
      # may both detect 404 + held-session — each emits its own event,
      # which is correct (each was an independent failed request).
      :telemetry.execute(
        [:ptc_lisp, :upstream, :http, :session_lost],
        %{count: 1},
        %{name: snap.name, prior_session_id_hash: hash_session_id(snap.session_id)}
      )

      _ = safe_cast(pid, :session_lost)
      {:error, :upstream_unavailable, "session_lost"}
    else
      # 404 without a held session id is just a 404 (likely a
      # misconfigured URL). Surface as `:upstream_unavailable`; impl
      # stays alive.
      {:error, :upstream_unavailable, "http 404"}
    end
  end

  defp classify_post_result({:error, :upstream_unavailable, "auth_failed"}, pid, _snap) do
    # §4.3.1: post-handshake 401 is the spec's auth-rotation signal.
    # Cast to the impl so it exits :auth_failed.
    _ = safe_cast(pid, :auth_failed)
    {:error, :upstream_unavailable, "auth_failed"}
  end

  defp classify_post_result({:error, reason, detail}, _pid, _snap)
       when reason in [:upstream_unavailable, :upstream_error, :timeout, :response_too_large] do
    {:error, reason, detail}
  end

  defp safe_cast(pid, msg) do
    GenServer.cast(pid, msg)
  catch
    :exit, _ -> :ok
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
      # Phase 3C: per-request auth (§5.3.1, §7.3). `auth` is the list
      # of parsed emitter maps (atom-keyed) produced by
      # `Application.parse_http_upstream/3`; `[]` means "no auth, no
      # materialize calls". `credentials` is the GenServer name to
      # call `Credentials.materialize/2` against; defaults to the
      # production singleton but tests override with their per-test
      # pid so they can stand up isolated bindings.
      auth: Map.get(config, :auth, []) || [],
      credentials: Map.get(config, :credentials, Credentials),
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

  def handle_call(:checkout_request, _from, state) do
    # Atomic id allocation + snapshot for caller-process
    # `Transport.post/1` (codex-fix for `76f68de`: serialized HTTP
    # calls). Bumps `next_id` inside the GenServer so concurrent
    # `Upstream.Http.call/4` invocations get distinct ids; everything
    # else returned in the snapshot is read-only state.
    #
    # Phase 3C: resolve `auth:` emitters into HTTP headers per request
    # (§7.3 — re-derive on every call to keep structural-isolation
    # guarantee tight). Materialize calls happen INSIDE this handler so
    # they're serialized through the impl (cheap; env / file reads only)
    # and the resolved headers leave with the snapshot. The caller
    # process drops its reference to them once `Transport.post/1`
    # returns.
    {id, session} = Session.next_request_id(state.session)

    case resolve_auth_headers(state) do
      {:ok, auth_headers} ->
        headers = Session.headers_for_post(session, state.static_headers) ++ auth_headers

        snapshot = %{
          url: state.url,
          finch_name: state.finch_name,
          headers: headers,
          request_timeout_ms: state.request_timeout_ms,
          connect_timeout_ms: state.connect_timeout_ms,
          max_response_bytes: state.max_response_bytes,
          request_id: id,
          has_session_id?: is_binary(session.session_id),
          # §11 telemetry — caller-process `tools/call` emits its own
          # `:upstream, :http, :request, :start | :stop` events; needs
          # the upstream name + the held session id (for hashing on
          # session-loss). The session id never leaves this process
          # except as a SHA-256 hash via `hash_session_id/1`.
          name: state.name,
          session_id: session.session_id
        }

        {:reply, {:ok, snapshot}, %{state | session: session}}

      {:error, _reason, detail} ->
        # §5.5 #7 third bullet: per-request auth-resolution failure is
        # treated like a credential failure — caller sees `:upstream_unavailable`
        # with `"auth_failed: <specific>"`, and the impl exits
        # `:auth_failed` so Connection arms backoff and the next call
        # cold-starts with a fresh materialization (operators rotating
        # env vars / files get picked up automatically).
        Log.log(:info, "http_upstream_auth_failed", %{
          name: state.name,
          url: state.url,
          detail: detail
        })

        # Bump session id even on failure so the wire-id invariant
        # ("every allocated id is allocated exactly once") holds even
        # though we never actually issue this request. Cheap and
        # defensive.
        {:stop, :auth_failed, {:error, :upstream_unavailable, "auth_failed: #{detail}"},
         %{state | session: session}}
    end
  end

  @impl GenServer
  def handle_cast(:session_lost, state) do
    # Caller-process detected 404 + held-session-id and is signalling
    # us to exit so Connection arms backoff per §4.3.1. Multiple
    # concurrent callers may both cast; whichever arrives first
    # triggers the stop, the rest are dropped by the GenServer.
    Log.log(:info, "http_upstream_session_lost", %{
      name: state.name,
      url: state.url
    })

    {:stop, :session_lost, state}
  end

  def handle_cast(:auth_failed, state) do
    # §4.3.1: post-handshake auth-rotation signal.
    Log.log(:info, "http_upstream_auth_failed", %{
      name: state.name,
      url: state.url
    })

    {:stop, :auth_failed, state}
  end

  def handle_cast(_, state), do: {:noreply, state}

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

    # §6.1.1: auth headers are required on EVERY POST including
    # `initialize` (some upstreams, e.g. GitHub MCP, refuse to
    # handshake without auth). Materialize fresh per request (§7.3).
    # Boot-time auth failure short-circuits before any wire I/O so
    # the detail string in `init/1`'s `{:stop, {:upstream_unavailable,
    # detail}}` is the clean §8.3 form (`"resolution_failed: <binding>"`)
    # rather than wrapped in a `"handshake step 1 ..."` prefix.
    case resolve_auth_headers(state) do
      {:ok, auth_headers} ->
        headers =
          Session.headers_for_initialize(state.session, state.static_headers) ++ auth_headers

        run_initialize(state, headers, body_map, id)

      {:error, _reason, detail} ->
        # Pass the bare detail through unmodified — `do_handshake`
        # caller in `init/1` will surface it as
        # `{:upstream_unavailable, detail}` directly.
        {:error, detail}
    end
  end

  defp run_initialize(state, headers, body_map, id) do
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

    case resolve_auth_headers(state) do
      {:ok, auth_headers} ->
        headers = Session.headers_for_post(state.session, state.static_headers) ++ auth_headers

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

      {:error, _reason, detail} ->
        {:error, "handshake step 2 (notifications/initialized) failed: #{detail}"}
    end
  end

  defp handshake_tools_list(state) do
    {body_map, session} = Session.tools_list_body(state.session)
    state = %{state | session: session}
    id = body_map["id"]

    case resolve_auth_headers(state) do
      {:ok, auth_headers} ->
        headers = Session.headers_for_post(state.session, state.static_headers) ++ auth_headers
        run_tools_list(state, headers, body_map, id)

      {:error, _reason, detail} ->
        {:error, "handshake step 3 (tools/list) failed: #{detail}"}
    end
  end

  defp run_tools_list(state, headers, body_map, id) do
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

      base
      |> maybe_put_description(Map.get(t, "description"))
      |> maybe_put_output_schema(Map.get(t, "outputSchema") || Map.get(t, "output_schema"))
      |> maybe_put_map(:annotations, Map.get(t, "annotations"))
    end)
  end

  defp extract_tools(_), do: []

  defp maybe_put_description(tool, nil), do: tool
  defp maybe_put_description(tool, ""), do: tool

  defp maybe_put_description(tool, description) when is_binary(description),
    do: Map.put(tool, :description, description)

  defp maybe_put_description(tool, _description), do: tool

  defp maybe_put_output_schema(tool, nil), do: tool

  defp maybe_put_output_schema(tool, value) when is_map(value),
    do: Map.put(tool, :output_schema, value)

  defp maybe_put_output_schema(tool, _value), do: tool

  defp maybe_put_map(tool, _key, value) when value in [nil, %{}], do: tool
  defp maybe_put_map(tool, key, value) when is_map(value), do: Map.put(tool, key, value)
  defp maybe_put_map(tool, _key, _value), do: tool

  # ----------------------------------------------------------------
  # Per-request auth resolution (Phase 3C — §5.3.1, §7.3, §8.3)
  # ----------------------------------------------------------------

  # Resolve the upstream's `auth:` emitter list into a flat list of
  # `{header_name, header_value}` tuples by calling
  # `Credentials.materialize/2` and `Credentials.apply_emitter/2` for
  # each emitter, in declared order.
  #
  # Returns:
  #   * `{:ok, []}` when `state.auth == []` (no auth, no calls).
  #   * `{:ok, [{name, value}, ...]}` on full success.
  #   * `{:error, :upstream_unavailable, detail}` on the first failure.
  #     Detail strings:
  #       - `"resolution_failed: <binding-name>"` for `:unknown_binding`
  #         (defensive — Phase 1's cross-reference validator should
  #         catch this at config-load).
  #       - `"resolution_failed: <binding-name>: <inner>"` for
  #         `:resolution_failed` (env var unset, file unreadable).
  #       - `"scheme_mismatch: <inner>"` for `:scheme_mismatch`
  #         (defense-in-depth — config-load validator should catch this
  #         too).
  #       - `"basic_shape_invalid"` for `:unencodable` (basic raw not
  #         in `user:pass` shape; canonical detail per §5.5 #7 third
  #         bullet).
  #
  # The `RedactedHeaders` wrapper is unwrapped here; the bare list
  # leaves this function. Callers must drop the reference once the
  # request completes (caller-process scoping per §7.3).
  defp resolve_auth_headers(%{auth: []}), do: {:ok, []}

  defp resolve_auth_headers(state) do
    Enum.reduce_while(state.auth, {:ok, []}, fn emitter, {:ok, acc} ->
      case resolve_one_emitter(state.credentials, emitter) do
        {:ok, headers} ->
          {:cont, {:ok, acc ++ headers}}

        {:error, _reason, _detail} = err ->
          {:halt, err}
      end
    end)
  end

  defp resolve_one_emitter(credentials, emitter) do
    case Credentials.materialize(credentials, emitter.binding) do
      {:ok, materialization} ->
        apply_emitter(materialization, emitter)

      {:error, :unknown_binding, _detail} ->
        # Binding name only — no value involved (resolution didn't
        # happen). Phase 1's validator should prevent this in
        # production; handled defensively here.
        {:error, :upstream_unavailable, "resolution_failed: #{emitter.binding}"}

      {:error, :resolution_failed, detail} ->
        # Source read failed (env var unset, file missing). Detail
        # already names the source (`env var 'X' is not set`,
        # `file '/p': enoent`); we prefix with the binding name so
        # operators can find the right binding quickly. The binding
        # name is not secret per §8.3; the bytes would be, but
        # resolution failed so there is no value to leak.
        {:error, :upstream_unavailable, "resolution_failed: #{emitter.binding}: #{detail}"}
    end
  end

  defp apply_emitter(materialization, emitter) do
    case Credentials.apply_emitter(materialization, emitter) do
      {:ok, %RedactedHeaders{} = wrapper} ->
        {:ok, RedactedHeaders.headers(wrapper)}

      {:error, :scheme_mismatch, detail} ->
        {:error, :upstream_unavailable, "scheme_mismatch: #{detail}"}

      {:error, :unencodable, detail} ->
        # Detail is the canonical `"basic_shape_invalid"` per §5.5 #7
        # third bullet. Pass it through verbatim — `caller_handle`
        # in `:checkout_request` already prefixes with `"auth_failed: "`
        # to form the final outgoing detail.
        {:error, :upstream_unavailable, detail}
    end
  end

  # ----------------------------------------------------------------
  # Transport wrappers
  # ----------------------------------------------------------------

  defp post(state, headers, body_map, jsonrpc_id) do
    case encode_body(body_map) do
      {:ok, encoded} ->
        # §11 telemetry — wrap each wire call with
        # `:upstream, :http, :request, :start | :stop`. The
        # `jsonrpc_method` is read from `body_map` (not `state`) so
        # each handshake step / notification surfaces with its own
        # method label.
        with_request_telemetry(state.name, jsonrpc_method(body_map), fn ->
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
        end)

      {:error, detail} ->
        {:error, :upstream_error, "encode failed: #{detail}"}
    end
  end

  defp post_with_meta(state, headers, body_map, jsonrpc_id) do
    case encode_body(body_map) do
      {:ok, encoded} ->
        with_request_telemetry(state.name, jsonrpc_method(body_map), fn ->
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
        end)

      {:error, detail} ->
        {:error, :upstream_error, "encode failed: #{detail}"}
    end
  end

  defp jsonrpc_method(%{"method" => m}) when is_binary(m), do: m
  defp jsonrpc_method(_), do: "unknown"

  # §11 telemetry — wrap a wire call with `:upstream, :http, :request,
  # :start | :stop`. Emits:
  #
  #   * `:start` — `%{system_time: ...}`, metadata `%{name, jsonrpc_method}`.
  #   * `:stop` (success) — `%{duration_ms}`, metadata
  #     `%{name, jsonrpc_method, http_status, duration_ms}` so consumers
  #     can index either way (measurement OR metadata-side duration);
  #     §11 didn't pin this, so we surface in both. `http_status` is
  #     `nil` on transport-error stops (§11 says "absent" — we put `nil`
  #     so the metadata shape is invariant for handlers that pattern-match).
  #   * `:stop` (transport error) — `http_status` set to `nil`.
  #
  # Try/rescue/catch ensures `:stop` always fires, even if `fun` raises.
  # The exception is re-raised after emission.
  defp with_request_telemetry(name, jsonrpc_method, fun)
       when is_binary(name) and is_binary(jsonrpc_method) and is_function(fun, 0) do
    start_metadata = %{name: name, jsonrpc_method: jsonrpc_method}
    start_mono = System.monotonic_time()

    :telemetry.execute(
      [:ptc_lisp, :upstream, :http, :request, :start],
      %{system_time: System.system_time()},
      start_metadata
    )

    try do
      result = fun.()

      duration_ms =
        System.convert_time_unit(
          System.monotonic_time() - start_mono,
          :native,
          :millisecond
        )

      :telemetry.execute(
        [:ptc_lisp, :upstream, :http, :request, :stop],
        %{duration_ms: duration_ms},
        Map.merge(start_metadata, %{
          http_status: http_status_from_result(result),
          duration_ms: duration_ms
        })
      )

      result
    rescue
      e ->
        emit_request_stop_error(start_metadata, start_mono)
        reraise(e, __STACKTRACE__)
    catch
      kind, reason ->
        emit_request_stop_error(start_metadata, start_mono)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_request_stop_error(start_metadata, start_mono) do
    duration_ms =
      System.convert_time_unit(
        System.monotonic_time() - start_mono,
        :native,
        :millisecond
      )

    :telemetry.execute(
      [:ptc_lisp, :upstream, :http, :request, :stop],
      %{duration_ms: duration_ms},
      Map.merge(start_metadata, %{http_status: nil, duration_ms: duration_ms})
    )
  end

  # `Transport.post/1` and `Transport.post_with_meta/1` collapse status
  # codes into shaped error returns rather than threading the raw
  # status through. We can recover it from the success payload (200 →
  # `{:ok, _}`, 202 → `:ok`, post_with_meta success → `{:ok, %{status,
  # ...}}`); on the error branch (`{:error, reason, detail}`) status
  # is not directly recoverable without changing Transport's contract,
  # so we surface `nil` — operators reading the telemetry stream still
  # see latency + error reason via the metadata's `:jsonrpc_method` and
  # the lifetime of the request.
  defp http_status_from_result({:ok, %{status: s}}) when is_integer(s), do: s
  defp http_status_from_result({:ok, _result}), do: 200
  defp http_status_from_result(:ok), do: 202
  defp http_status_from_result({:error, _reason, _detail}), do: nil

  # §11 — `prior_session_id_hash` for the `:session_lost` event.
  # SHA-256 (hex, lowercase) truncated to 16 chars. 16 hex chars is
  # 64 bits of correlation strength — plenty for cross-referencing
  # session-loss events without leaking the opaque session ID into
  # operator dashboards / metric pipelines.
  defp hash_session_id(id) when is_binary(id) do
    :crypto.hash(:sha256, id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_session_id(_), do: nil

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
    # `:timeout` for the TCP/TLS handshake. Direct IPv6-literal
    # connections also need `:inet6`; proxied requests connect to the
    # proxy host, so proxy address-family handling is left to Mint.
    transport_opts =
      if ipv6_literal_url?(state.url) and is_nil(state.proxy) do
        [timeout: state.connect_timeout_ms, inet6: true]
      else
        [timeout: state.connect_timeout_ms]
      end

    conn_opts = [transport_opts: transport_opts]

    with {:ok, conn_opts} <- maybe_put_proxy(conn_opts, state.proxy) do
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
  end

  defp maybe_put_proxy(conn_opts, nil), do: {:ok, conn_opts}

  defp maybe_put_proxy(conn_opts, url) when is_binary(url) do
    case parse_proxy(url) do
      {:ok, proxy} -> {:ok, Keyword.put(conn_opts, :proxy, proxy)}
      {:error, detail} -> {:error, detail}
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

  defp ipv6_literal_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.contains?(host, ":")
      _ -> false
    end
  end

  defp parse_proxy(url) when is_binary(url) do
    # Req accepts `proxy: {scheme, host, port, opts}` — we delegate
    # parsing to `URI.new/1`. Keep scheme conversion on a closed
    # allowlist so arbitrary proxy URL schemes do not intern permanent
    # atoms.
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port}}
      when is_binary(scheme) and is_binary(host) and host != "" and is_integer(port) ->
        case proxy_scheme(scheme) do
          {:ok, atom_scheme} -> {:ok, {atom_scheme, host, port, []}}
          :error -> {:error, "unsupported proxy scheme: #{inspect(scheme)}"}
        end

      _ ->
        {:error, "malformed proxy URL: #{inspect(url)}"}
    end
  end

  defp proxy_scheme("http"), do: {:ok, :http}
  defp proxy_scheme("https"), do: {:ok, :https}
  defp proxy_scheme(_scheme), do: :error

  # ----------------------------------------------------------------
  # Session DELETE on stop
  # ----------------------------------------------------------------

  defp delete_session(state) do
    if state.session.handshake_complete? and Code.ensure_loaded?(Req) do
      headers = Session.headers_for_post(state.session, state.static_headers)

      Req.request(delete_session_req_opts(state, headers))
    else
      :ok
    end
  end

  defp delete_session_req_opts(state, headers) do
    base_opts = [
      method: :delete,
      url: state.url,
      headers: headers,
      receive_timeout: 1_000,
      retry: false
    ]

    case state.finch_name do
      nil -> Keyword.put(base_opts, :connect_options, timeout: 1_000)
      name when is_atom(name) -> Keyword.put(base_opts, :finch, name)
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
