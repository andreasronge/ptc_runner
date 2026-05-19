defmodule PtcRunnerMcp.Upstream.Http.Transport do
  @moduledoc """
  Streamable HTTP transport (MCP rev 2025-06-18) — Req-based POST
  wrapper plus the §6.4 status-code → behaviour-return mapper.

  See `Plans/http-transport-credentials.md` §6.4 for the normative
  status-code table. Briefly:

    * `200 OK` + `application/json` JSON-RPC `result` → `{:ok, result}`
    * `200 OK` + `application/json` JSON-RPC `error`  → `{:error, :upstream_error, ...}`
    * `200 OK` + `text/event-stream`                 → delegate to
      `PtcRunnerMcp.Upstream.Http.SseDecoder.decode_stream/2`
    * `202` empty body                               → `:ok`
    * any 4xx + JSON-RPC error body                  → `:upstream_error, formatted`
                                                       (world-fault — §6.4 / §8.1; checked
                                                       FIRST for ALL 4xx, including 401/
                                                       403/404/429 — codex P1 fix for
                                                       commit `76f68de` that special-cased
                                                       404 before the JSON-RPC branch)
    * `401`/`403` plain                              → `:upstream_unavailable, "auth_failed"`
    * `404` plain                                    → `:upstream_unavailable, "http 404"`
                                                       (caller `Upstream.Http` interprets
                                                       this plus a held session id as the
                                                       §6.3 session-loss signal)
    * `429` plain                                    → `:upstream_unavailable, "rate_limited"`
    * other 4xx plain                                → `:upstream_unavailable, "http <s>"`
    * 5xx                                            → `:upstream_unavailable, "http <s>"`
    * TLS / network / connect-timeout                → `:upstream_unavailable, ...`
    * read timeout                                   → `:timeout, "http read timeout"`
    * response > cap                                 → `:response_too_large, ...`

  ## Why HTTP 4xx + JSON-RPC body is world-fault

  §6.4 / §8.1 of the plan classify "HTTP 4xx with a JSON-RPC error
  body" as `:upstream_error` (world-fault), NOT programmer-fault.
  This matches base aggregator §7.1 row 2 ("upstream returned a
  JSON-RPC error to a `tools/call`"). The codex-1 draft of this plan
  classified it as programmer-fault; the spec was explicitly
  corrected. The PTC-Lisp program sees `nil` and the LLM's
  `(when result …)` / `(remove nil? results)` idiom covers
  transient remote failure.

  ## `:max_response_bytes` enforcement (pre-decode)

  Implemented via Req's `:into` callback: each chunk is appended to
  an iolist accumulator, byte-counted on the way in, and the stream
  is cancelled (`{:halt, ...}`) the moment the cumulative count
  exceeds the cap. This is strictly pre-decode — no JSON parsing
  happens until the whole body has been received under the cap.

  For `text/event-stream` responses the cap is enforced by the SSE
  decoder (which sees the raw bytes the same way), keeping the
  cumulative-cap semantics in §6.4.1.

  ## Optional `:req` dep

  This module compiles even when `:req` is not loaded. There is no
  compile-time `alias Req` and we never reference `Req` at module
  scope. All call sites use the fully-qualified `Req.post/2`. A
  caller that has not added `:req` to deps will see a runtime
  `UndefinedFunctionError` if it ever invokes `post/1` — which is
  fine because `Application.check_http_deps!/2` (§4.5) raises at
  config load if any HTTP upstream is configured without `:req`.
  """

  alias PtcRunnerMcp.Log
  alias PtcRunnerMcp.Upstream.Http.SseDecoder

  @typedoc "Options for `post/1`."
  @type post_opts :: [
          finch: atom() | nil,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          request_timeout_ms: pos_integer(),
          connect_timeout_ms: pos_integer(),
          max_response_bytes: pos_integer(),
          jsonrpc_id: integer() | nil
        ]

  @typedoc "Result of `post/1` — see §6.4 of the plan."
  @type post_result ::
          {:ok, map()}
          | :ok
          | {:error, atom(), String.t()}

  @typedoc """
  Result of `post_with_meta/1`. On the JSON happy path, the caller
  receives the full HTTP response envelope (status + headers + the
  decoded JSON-RPC body) so it can drive `Session.apply_initialize_response/2`.
  Other status codes / content types collapse to the same shape as
  `post/1` (with `:ok` reserved for `202`).
  """
  @type post_meta_result ::
          {:ok, %{status: 200, headers: map(), body: map()}}
          | :ok
          | {:error, atom(), String.t()}

  # `Req` is an optional dep. `Code.ensure_loaded?/1` plus a runtime
  # call site keep the compile working without it; we never reference
  # `Req` at module scope (no compile-time `alias`), and the dialyzer
  # PLT here includes `:req` so the call sites type-check normally.
  # If `:req` is removed from deps, the `Code.ensure_loaded?(Req)`
  # branch returns `false` and `post/1` reports an unavailable
  # upstream without ever hitting `Req.post/2`.

  @doc """
  POST a JSON-RPC envelope and map the response per §6.4.

  Required keys in `opts`: `:url`, `:headers`, `:body`,
  `:request_timeout_ms`, `:connect_timeout_ms`, `:max_response_bytes`.
  Optional: `:finch` (uses Req's default pool when absent),
  `:jsonrpc_id` (used for SSE correlation; pass `nil` for
  notifications-only POSTs).

  The caller is responsible for clamping `:request_timeout_ms`
  against any per-call deadline (§10 / OQ-1-resolved); this module
  uses the value as-is.
  """
  @spec post(post_opts()) :: post_result()
  def post(opts) when is_list(opts) do
    url = fetch_required!(opts, :url)
    headers = fetch_required!(opts, :headers)
    body = fetch_required!(opts, :body)
    request_timeout_ms = fetch_required!(opts, :request_timeout_ms)
    connect_timeout_ms = fetch_required!(opts, :connect_timeout_ms)
    max_response_bytes = fetch_required!(opts, :max_response_bytes)
    jsonrpc_id = Keyword.get(opts, :jsonrpc_id)
    finch = Keyword.get(opts, :finch)

    headers = ensure_user_agent(headers)

    if Code.ensure_loaded?(Req) do
      do_post(
        %{
          url: url,
          headers: headers,
          body: body,
          request_timeout_ms: request_timeout_ms,
          connect_timeout_ms: connect_timeout_ms,
          max_response_bytes: max_response_bytes,
          jsonrpc_id: jsonrpc_id,
          finch: finch
        },
        max_response_bytes
      )
    else
      {:error, :upstream_unavailable, "req library not loaded"}
    end
  end

  @doc """
  Same wire path as `post/1`, but on the `200 OK + application/json`
  happy path returns `{:ok, %{status: 200, headers: headers_map,
  body: decoded_body}}` instead of `{:ok, body["result"]}`. All other
  status codes / failure shapes collapse to the same returns as
  `post/1`.

  This variant exists so `PtcRunnerMcp.Upstream.Http.init/1` can hand
  the full response envelope to
  `PtcRunnerMcp.Upstream.Http.Session.apply_initialize_response/2`,
  which needs to capture `Mcp-Session-Id` from the response headers
  and verify the negotiated `protocolVersion` in the body. The base
  `post/1` extracts `body["result"]` and discards both — fine for
  `tools/call` but loses the data the handshake needs.
  """
  @spec post_with_meta(post_opts()) :: post_meta_result()
  def post_with_meta(opts) when is_list(opts) do
    url = fetch_required!(opts, :url)
    headers = fetch_required!(opts, :headers)
    body = fetch_required!(opts, :body)
    request_timeout_ms = fetch_required!(opts, :request_timeout_ms)
    connect_timeout_ms = fetch_required!(opts, :connect_timeout_ms)
    max_response_bytes = fetch_required!(opts, :max_response_bytes)
    jsonrpc_id = Keyword.get(opts, :jsonrpc_id)
    finch = Keyword.get(opts, :finch)

    headers = ensure_user_agent(headers)

    if Code.ensure_loaded?(Req) do
      do_post_with_meta(
        %{
          url: url,
          headers: headers,
          body: body,
          request_timeout_ms: request_timeout_ms,
          connect_timeout_ms: connect_timeout_ms,
          max_response_bytes: max_response_bytes,
          jsonrpc_id: jsonrpc_id,
          finch: finch
        },
        max_response_bytes
      )
    else
      {:error, :upstream_unavailable, "req library not loaded"}
    end
  end

  # ----------------------------------------------------------------
  # Req call + status mapping
  # ----------------------------------------------------------------

  defp do_post(req_opts, max_response_bytes) do
    full_opts = build_req_opts(req_opts, max_response_bytes)
    jsonrpc_id = req_opts.jsonrpc_id

    case Req.post(full_opts) do
      {:ok, %{status: status, headers: resp_headers} = resp} ->
        body_state = extract_body_state(resp)
        map_response(status, resp_headers, body_state, jsonrpc_id, max_response_bytes)

      {:error, exception} ->
        map_exception(exception)
    end
  end

  # Build the Req options keyword list. When `:finch` names a
  # caller-owned Finch pool, Req rejects `:connect_options` because
  # the pool itself owns the connect-time configuration; we instead
  # rely on the pool having been started with the right
  # `:conn_opts: [transport_opts: [timeout: ...]]`. When `:finch` is
  # absent, Req auto-starts a default pool and `:connect_options`
  # applies normally.
  defp build_req_opts(req_opts, max_response_bytes) do
    %{
      url: url,
      headers: headers,
      body: body,
      request_timeout_ms: request_timeout_ms,
      connect_timeout_ms: connect_timeout_ms,
      finch: finch
    } = req_opts

    base_opts = [
      url: url,
      method: :post,
      headers: headers,
      body: body,
      receive_timeout: request_timeout_ms,
      retry: false,
      decode_body: false,
      into: cap_collector(max_response_bytes)
    ]

    case finch do
      nil ->
        Keyword.put(base_opts, :connect_options, timeout: connect_timeout_ms)

      name when is_atom(name) ->
        Keyword.put(base_opts, :finch, name)
    end
  end

  # `:into` callback for Req. Closes over the cap, accumulates chunks
  # in `resp.private[:cap_state]`, and returns `{:halt, ...}` the
  # moment the cumulative byte count exceeds the cap. Req's
  # `into: fun` contract (see `Req.new/1` docs) lets us mutate the
  # `resp` returned in `{:cont, {req, resp}}`, so we thread the
  # state through `:private`.
  #
  # Pre-decode cap: chunks are appended to an iolist; no JSON
  # parsing happens until the whole response is buffered. Once the
  # cap is exceeded we set `overflow: true` and halt — the body we
  # surface to the mapper is whatever we managed to buffer up to that
  # point (may be empty if the first chunk overshoots), and the
  # mapper short-circuits to `:response_too_large` regardless of
  # status code.
  defp cap_collector(cap) do
    fn {:data, data}, {req, resp} ->
      state =
        resp.private
        |> Map.get(:cap_state, %{bytes: 0, chunks: [], overflow: false})
        |> Map.put(:cap, cap)

      new_size = state.bytes + byte_size(data)

      cond do
        state.overflow ->
          # Already over — keep halting until Req stops calling us.
          {:halt, {req, resp}}

        new_size > cap ->
          new_state = %{state | overflow: true}
          {:halt, {req, put_in(resp.private[:cap_state], new_state)}}

        true ->
          new_state = %{state | bytes: new_size, chunks: [state.chunks, data]}
          {:cont, {req, put_in(resp.private[:cap_state], new_state)}}
      end
    end
  end

  defp extract_body_state(%{private: private}) do
    case Map.get(private, :cap_state) do
      nil ->
        # Empty body / no chunks delivered — Req still gives us a
        # successful response, just with nothing in our accumulator.
        {:ok, "", false}

      %{chunks: chunks, overflow: overflow?} ->
        {:ok, IO.iodata_to_binary(chunks), overflow?}
    end
  end

  defp do_post_with_meta(req_opts, max_response_bytes) do
    full_opts = build_req_opts(req_opts, max_response_bytes)
    jsonrpc_id = req_opts.jsonrpc_id

    case Req.post(full_opts) do
      {:ok, %{status: status, headers: resp_headers} = resp} ->
        body_state = extract_body_state(resp)
        map_response_with_meta(status, resp_headers, body_state, jsonrpc_id, max_response_bytes)

      {:error, exception} ->
        map_exception(exception)
    end
  end

  # Like `map_response/5` but on the `200 + application/json` happy
  # path, surfaces `{:ok, %{status, headers, body}}` (decoded body
  # map) instead of unwrapping `result`. All other status codes
  # share the §6.4 mapping verbatim by delegating to the existing
  # `do_map_response/5`.
  defp map_response_with_meta(_status, _headers, {:ok, _body, true}, _jsonrpc_id, max) do
    {:error, :response_too_large, "http response exceeded cap of #{max} bytes"}
  end

  defp map_response_with_meta(200, headers, {:ok, body, false}, jsonrpc_id, max_bytes) do
    case content_type(headers) do
      :json ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, %{status: 200, headers: headers, body: decoded}}

          {:ok, _other} ->
            {:error, :upstream_error, "200 body is JSON but not an object"}

          {:error, %Jason.DecodeError{} = e} ->
            {:error, :upstream_error, "200 body is not valid JSON: #{Exception.message(e)}"}
        end

      :sse ->
        decode_sse_response_with_meta(headers, body, jsonrpc_id, max_bytes)

      :other ->
        {:error, :upstream_error,
         "handshake response had unexpected content-type (expected application/json)"}
    end
  end

  defp map_response_with_meta(status, headers, {:ok, body, false}, jsonrpc_id, max_bytes) do
    do_map_response(status, headers, body, jsonrpc_id, max_bytes)
  end

  # ----------------------------------------------------------------
  # §6.4 status-code mapping
  # ----------------------------------------------------------------

  defp map_response(_status, _headers, {:ok, _body, true}, _jsonrpc_id, max) do
    {:error, :response_too_large, "http response exceeded cap of #{max} bytes"}
  end

  defp map_response(status, headers, {:ok, body, false}, jsonrpc_id, max_bytes) do
    do_map_response(status, headers, body, jsonrpc_id, max_bytes)
  end

  defp do_map_response(202, _headers, _body, _jsonrpc_id, _max), do: :ok

  defp do_map_response(200, headers, body, jsonrpc_id, max_bytes) do
    case content_type(headers) do
      :json ->
        decode_json_response(body)

      :sse ->
        decode_sse_response(body, jsonrpc_id, max_bytes)

      :other ->
        {:error, :upstream_error,
         "200 with unexpected content-type (not application/json or text/event-stream)"}
    end
  end

  defp do_map_response(status, _headers, body, _jsonrpc_id, _max)
       when status >= 400 and status < 500 do
    # Check for a JSON-RPC error body FIRST (codex P1 fix for `76f68de`):
    # any 4xx — including 401, 403, 404, 429 — that carries a JSON-RPC
    # error body classifies as `:upstream_error` (world-fault) per
    # §6.4 / §8.1. Plain 4xx without a JSON-RPC body falls through to
    # the status-specific defaults below.
    case decode_jsonrpc_error(body) do
      {:ok, formatted} ->
        {:error, :upstream_error, formatted}

      :not_jsonrpc ->
        plain_4xx(status)
    end
  end

  defp do_map_response(status, _headers, _body, _jsonrpc_id, _max) when status >= 500 do
    {:error, :upstream_unavailable, "http #{status}"}
  end

  defp do_map_response(status, _headers, _body, _jsonrpc_id, _max) do
    # 1xx / 3xx: Req follows redirects by default but we disabled it
    # via :retry false; a 3xx surfacing here is a server contract
    # violation. Treat as unavailable.
    {:error, :upstream_unavailable, "http #{status}"}
  end

  # Status-specific defaults for plain 4xx (no JSON-RPC error body).
  # `Upstream.Http.call/4` interprets `"http 404"` plus a held
  # session id as the §6.3 session-loss signal.
  defp plain_4xx(401), do: {:error, :upstream_unavailable, "auth_failed"}
  defp plain_4xx(403), do: {:error, :upstream_unavailable, "auth_failed"}
  defp plain_4xx(404), do: {:error, :upstream_unavailable, "http 404"}
  defp plain_4xx(429), do: {:error, :upstream_unavailable, "rate_limited"}
  defp plain_4xx(status), do: {:error, :upstream_unavailable, "http #{status}"}

  # ----------------------------------------------------------------
  # 200 handling — JSON
  # ----------------------------------------------------------------

  defp decode_json_response(body) do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, %{"error" => err}} ->
        {:error, :upstream_error, format_jsonrpc_error(err)}

      {:ok, _other} ->
        {:error, :upstream_error, "200 body is JSON but not a JSON-RPC response"}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, :upstream_error, "200 body is not valid JSON: #{Exception.message(e)}"}
    end
  end

  # ----------------------------------------------------------------
  # 200 handling — SSE (delegate to 2C's decoder)
  # ----------------------------------------------------------------

  # 2C-integration note (resolved): the spec the parent stream passed
  # me documented `decode_stream/2` as returning `{:ok, [map()]}`
  # (list of messages). The actual `SseDecoder.decode_stream/2`
  # contract returns `{:ok, msg}` for a single in-flight-id-matched
  # message, matching v1's "drop notifications, surface only the
  # response message" semantics (§6.4.1). I match the actual
  # contract here. The spec call site also assumed the decoder takes
  # a streaming `Enumerable`; in this Transport we have already
  # buffered the body into a binary because cancellation is byte-cap
  # driven, so we wrap the binary in a single-element list to feed
  # the decoder its expected `Enumerable`.
  defp decode_sse_response(body, jsonrpc_id, max_bytes) do
    if Code.ensure_loaded?(SseDecoder) do
      case SseDecoder.decode_stream([body],
             request_id: jsonrpc_id,
             max_bytes: max_bytes
           ) do
        {:ok, %{"result" => result}} ->
          {:ok, result}

        {:ok, %{"error" => err}} ->
          {:error, :upstream_error, format_jsonrpc_error(err)}

        {:ok, _other_message} ->
          # The decoder filtered to the matching-id response, so
          # anything reaching here is a JSON-RPC message that's
          # neither result nor error — server contract violation.
          {:error, :upstream_error, "200 SSE message has neither result nor error"}

        {:error, :stream_closed_before_response, detail} ->
          {:error, :upstream_unavailable, detail}

        {:error, :response_too_large, detail} ->
          {:error, :response_too_large, detail}
      end
    else
      Log.log(:warn, "http_transport_sse_decoder_unavailable", %{})
      {:error, :upstream_unavailable, "sse decoder not loaded"}
    end
  end

  defp decode_sse_response_with_meta(headers, body, jsonrpc_id, max_bytes) do
    if Code.ensure_loaded?(SseDecoder) do
      case SseDecoder.decode_stream([body],
             request_id: jsonrpc_id,
             max_bytes: max_bytes
           ) do
        {:ok, message} when is_map(message) ->
          {:ok, %{status: 200, headers: headers, body: message}}

        {:error, :stream_closed_before_response, detail} ->
          {:error, :upstream_unavailable, detail}

        {:error, :response_too_large, detail} ->
          {:error, :response_too_large, detail}
      end
    else
      Log.log(:warn, "http_transport_sse_decoder_unavailable", %{})
      {:error, :upstream_unavailable, "sse decoder not loaded"}
    end
  end

  # ----------------------------------------------------------------
  # JSON-RPC error formatting
  # ----------------------------------------------------------------

  # Returns `{:ok, formatted}` if `body` parses as a proper JSON-RPC
  # error envelope (must carry `"jsonrpc": "2.0"` per the JSON-RPC
  # 2.0 spec), else `:not_jsonrpc`. Used by the 4xx-with-body branch
  # so a server that returns an arbitrary `{"error": "..."}` shape on
  # auth failure (e.g. an OAuth-style error body) is NOT misclassified
  # as a JSON-RPC protocol error.
  defp decode_jsonrpc_error(body) do
    case Jason.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "error" => err}} -> {:ok, format_jsonrpc_error(err)}
      _ -> :not_jsonrpc
    end
  end

  defp format_jsonrpc_error(%{"code" => code, "message" => msg}) when is_integer(code) do
    "jsonrpc error #{code}: #{msg}"
  end

  defp format_jsonrpc_error(%{"message" => msg}) when is_binary(msg) do
    "jsonrpc error: #{msg}"
  end

  defp format_jsonrpc_error(other) do
    "jsonrpc error (unparseable): #{inspect(other, limit: 5, printable_limit: 80)}"
  end

  # ----------------------------------------------------------------
  # Content-type sniffing
  # ----------------------------------------------------------------

  defp content_type(headers) do
    case header_get(headers, "content-type") do
      nil ->
        :other

      ct when is_binary(ct) ->
        ct_lower = String.downcase(ct)

        cond do
          String.contains?(ct_lower, "application/json") -> :json
          String.contains?(ct_lower, "text/event-stream") -> :sse
          true -> :other
        end
    end
  end

  # `Req.Response.headers` is a map of lowercased name → list of
  # values (HTTP allows multi-valued headers). We do a case-folded
  # lookup so a server that emits "Content-Type" with a non-standard
  # casing still resolves.
  defp header_get(headers, target) when is_map(headers) and is_binary(target) do
    target_down = String.downcase(target)

    case Map.get(headers, target_down) do
      [v | _] when is_binary(v) ->
        v

      nil ->
        case Enum.find(headers, fn {k, _} ->
               is_binary(k) and String.downcase(k) == target_down
             end) do
          {_, [v | _]} when is_binary(v) -> v
          {_, v} when is_binary(v) -> v
          _ -> nil
        end

      v when is_binary(v) ->
        v

      _ ->
        nil
    end
  end

  # ----------------------------------------------------------------
  # Exception → error mapping
  # ----------------------------------------------------------------

  # Req surfaces transport errors as `Req.TransportError` (wraps
  # `Mint.TransportError`) and protocol errors as `Req.HTTPError`.
  # We pattern-match by struct module name (string) so this module
  # compiles without `Req` loaded.
  defp map_exception(%{__struct__: Req.TransportError, reason: reason}),
    do: classify_transport_error(reason)

  defp map_exception(%{__struct__: Req.HTTPError, reason: reason}),
    do: {:error, :upstream_unavailable, "http error: #{inspect(reason)}"}

  defp map_exception(%Jason.DecodeError{} = e),
    do: {:error, :upstream_error, "json decode: #{Exception.message(e)}"}

  defp map_exception(other) when is_exception(other) do
    {:error, :upstream_unavailable, "request failed: #{Exception.message(other)}"}
  end

  defp map_exception(other) do
    {:error, :upstream_unavailable, "request failed: #{inspect(other, limit: 5)}"}
  end

  # Mint transport reasons:
  #   :timeout                       — receive timeout (HTTP read)
  #   :econnrefused / :nxdomain / etc — network errors
  #   {:tls_alert, _} / {:options, _} — TLS errors
  #   :closed                        — stream closed before response
  defp classify_transport_error(:timeout),
    do: {:error, :timeout, "http read timeout"}

  defp classify_transport_error(:econnrefused),
    do: {:error, :upstream_unavailable, "connection refused"}

  defp classify_transport_error(:nxdomain),
    do: {:error, :upstream_unavailable, "dns: nxdomain"}

  defp classify_transport_error(:closed),
    do: {:error, :upstream_unavailable, "connection closed"}

  defp classify_transport_error({:tls_alert, _} = reason),
    do: {:error, :upstream_unavailable, "tls: #{inspect(reason)}"}

  defp classify_transport_error({:options, _} = reason),
    do: {:error, :upstream_unavailable, "tls: #{inspect(reason)}"}

  defp classify_transport_error({:bad_alpn_protocol, _} = reason),
    do: {:error, :upstream_unavailable, "tls: #{inspect(reason)}"}

  defp classify_transport_error(reason),
    do: {:error, :upstream_unavailable, transport_detail(reason)}

  defp transport_detail(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_detail(reason), do: inspect(reason, limit: 5, printable_limit: 80)

  # ----------------------------------------------------------------
  # Misc
  # ----------------------------------------------------------------

  # `User-Agent` is impl-controlled (§6 / codex P1 fix for `76f68de`).
  # Strip any caller-supplied `User-Agent` (case-insensitive) and
  # always append our own. The config loader's `static_headers`
  # denylist rejects `user-agent` at load time; this enforces the
  # invariant on the wire path too.
  defp ensure_user_agent(headers) do
    headers
    |> Enum.reject(fn
      {k, _} when is_binary(k) -> String.downcase(k) == "user-agent"
      _ -> false
    end)
    |> Kernel.++([{"user-agent", user_agent()}])
  end

  defp user_agent do
    vsn =
      case Application.spec(:ptc_runner_mcp, :vsn) do
        nil -> "unknown"
        v when is_list(v) -> List.to_string(v)
        v when is_binary(v) -> v
      end

    "ptc-runner-mcp/#{vsn}"
  end

  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} ->
        v

      :error ->
        raise ArgumentError, "Upstream.Http.Transport.post/1 missing required opt #{inspect(key)}"
    end
  end
end
