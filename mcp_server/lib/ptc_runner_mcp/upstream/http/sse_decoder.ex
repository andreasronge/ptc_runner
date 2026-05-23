defmodule PtcRunnerMcp.Upstream.Http.SseDecoder do
  @moduledoc """
  SSE decoder for the Streamable HTTP transport (MCP rev 2025-06-18).

  Decodes a stream of Server-Sent-Events (SSE) chunks into a single
  JSON-RPC response message correlated to an in-flight request id.

  ## Wire format (`Plans/http-transport-credentials.md` §6.4.1)

  A `200 OK` + `text/event-stream` response carries one or more SSE
  events. Each event is terminated by `\\n\\n` (per RFC; we also
  tolerate `\\r\\n\\r\\n`). Within an event, lines starting with
  `data: ` carry the JSON-RPC payload. Multiple `data:` lines per
  event are joined with `\\n` per RFC. `event:`, `id:`, and `retry:`
  lines (and any unrecognised lines) are ignored.

  The `data:` payload is parsed as JSON and dispatched:

    * **Single-message form (2025-06-18 default).** The parsed value
      is a JSON-RPC object — treat it as one message.
    * **Array-form (backward-compat).** The parsed value is a JSON
      array — iterate, treating each element as one JSON-RPC message.
      Telemetry event
      `[:ptc_lisp, :upstream, :http, :sse_array_compat]` is
      emitted with `%{count: 1}` so operators notice when an upstream
      is using legacy framing. See OQ-9.

  For each decoded message: if `msg["id"] == request_id`, complete
  the call with `{:ok, msg}`. Notifications (no `id`) and different-id
  messages are dropped — v1 does not consume server-pushed
  notifications. If the stream terminates before a matching id
  arrives, return `{:error, :stream_closed_before_response, _}`.

  ## `:max_bytes`

  Cumulative wire bytes (not decoded message count). Enforced
  **pre-decode**: the decoder counts bytes as they come off the
  stream and aborts with `{:error, :response_too_large, _}` once the
  cap is exceeded, regardless of whether mid-event. This mirrors the
  NDJSON pre-decode cap in `PtcRunnerMcp.Upstream.Stdio`.

  ## Design

  Pure functional. No GenServer, no process state, no port. The
  caller (`Upstream.Http.Transport`) feeds a `Req` streaming-response
  body Enumerable in; the decoder reduces over it with a small buffer
  carrying the trailing partial event between chunks.
  """

  @telemetry_event [:ptc_lisp, :upstream, :http, :sse_array_compat]

  @type opts :: [
          request_id: integer() | String.t() | nil,
          max_bytes: pos_integer()
        ]

  @type decode_result ::
          {:ok, map()}
          | {:error, :stream_closed_before_response, String.t()}
          | {:error, :response_too_large, String.t()}

  @doc """
  Decode an SSE response stream into the JSON-RPC response message
  whose `id` matches `:request_id`.

  `stream` is any Enumerable yielding binary chunks (as produced by
  `Req`'s streaming-response support). Notifications and different-id
  messages are dropped.

  Required opts:

    * `:request_id` — integer/string id of the in-flight request, or
      `nil`. With `nil`, only a notification (no `id`) would match,
      and since v1 drops notifications the result is necessarily
      `:stream_closed_before_response`.
    * `:max_bytes` — cumulative wire-byte cap. Required (the cap is
      load-bearing safety; we refuse to silently use a default).
  """
  @spec decode_stream(Enumerable.t(), opts()) :: decode_result()
  def decode_stream(stream, opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    max_bytes = Keyword.fetch!(opts, :max_bytes)

    init = %{
      buffer: "",
      bytes: 0,
      request_id: request_id,
      max_bytes: max_bytes
    }

    result =
      Enum.reduce_while(stream, {:cont, init}, fn chunk, {:cont, state} ->
        chunk_bin = IO.iodata_to_binary(chunk)
        new_bytes = state.bytes + byte_size(chunk_bin)

        if new_bytes > state.max_bytes do
          # Pre-decode cap: abort BEFORE attempting to parse this
          # chunk. The detail string reports cumulative bytes
          # (post-chunk) so operators can see how much over budget
          # we got before cutting the stream.
          {:halt,
           {:error, :response_too_large,
            "SSE response #{new_bytes} bytes exceeds max_bytes (#{state.max_bytes})"}}
        else
          state = %{state | bytes: new_bytes, buffer: state.buffer <> chunk_bin}

          case process_buffer(state) do
            {:done, msg} -> {:halt, {:ok, msg}}
            {:cont, state} -> {:cont, {:cont, state}}
          end
        end
      end)

    case result do
      {:ok, msg} ->
        {:ok, msg}

      {:error, _, _} = err ->
        err

      {:cont, state} ->
        # Stream ran out. Flush any final event without trailing
        # `\\n\\n` (some servers don't emit it).
        case flush_remaining(state) do
          {:done, msg} ->
            {:ok, msg}

          :exhausted ->
            {:error, :stream_closed_before_response,
             "SSE stream closed before response with id=#{inspect(state.request_id)} arrived"}
        end
    end
  end

  @doc """
  Convenience: decode a fully-buffered SSE response binary. Equivalent
  to `decode_stream([bytes], opts)`.
  """
  @spec decode_binary(binary(), opts()) :: decode_result()
  def decode_binary(bytes, opts) when is_binary(bytes) do
    decode_stream([bytes], opts)
  end

  # ----------------------------------------------------------------
  # Internal: buffer-and-event processing
  # ----------------------------------------------------------------

  # Split the buffer on event boundaries (`\n\n`, tolerating `\r\n\r\n`),
  # process each complete event in order, retain the trailing partial
  # event in `state.buffer`. Stops as soon as a matching-id message is
  # found.
  defp process_buffer(state) do
    case split_event(state.buffer) do
      :no_event ->
        {:cont, state}

      {:event, raw_event, rest} ->
        case dispatch_event(raw_event, state.request_id) do
          {:done, msg} ->
            {:done, msg}

          :continue ->
            process_buffer(%{state | buffer: rest})
        end
    end
  end

  # Find the first `\n\n` (or `\r\n\r\n`) boundary in `buffer`.
  # Returns the raw event bytes (excluding the boundary) and the
  # remainder, or `:no_event` if no complete boundary present yet.
  defp split_event(buffer) do
    case :binary.match(buffer, ["\n\n", "\r\n\r\n"]) do
      :nomatch ->
        :no_event

      {pos, len} ->
        <<raw_event::binary-size(^pos), _boundary::binary-size(^len), rest::binary>> = buffer
        {:event, raw_event, rest}
    end
  end

  # On stream close, treat any non-empty buffer as one final event
  # (servers may omit the trailing `\n\n`).
  defp flush_remaining(%{buffer: ""}), do: :exhausted

  defp flush_remaining(state) do
    case dispatch_event(state.buffer, state.request_id) do
      {:done, msg} -> {:done, msg}
      :continue -> :exhausted
    end
  end

  # Decode one raw SSE event (lines, no trailing boundary). Returns
  # `{:done, msg}` if a matching-id message is present, else
  # `:continue` (notification/different-id/parse-error → drop).
  defp dispatch_event(raw_event, request_id) do
    raw_event
    |> extract_data_payload()
    |> case do
      :no_data ->
        :continue

      {:ok, payload} ->
        case Jason.decode(payload) do
          {:ok, value} -> dispatch_value(value, request_id)
          {:error, _} -> :continue
        end
    end
  end

  # Per RFC 6.4.1 step 2 / SSE RFC: collect all `data: ...` lines
  # within the event, joined by `\n` (after stripping the prefix).
  # Returns `:no_data` if the event has no `data:` lines (e.g. a
  # `:keepalive` comment, or only `event:` / `id:` lines).
  defp extract_data_payload(raw_event) do
    raw_event
    |> :binary.split("\n", [:global])
    |> Enum.map(&strip_cr/1)
    |> Enum.flat_map(&data_line/1)
    |> case do
      [] -> :no_data
      lines -> {:ok, Enum.join(lines, "\n")}
    end
  end

  # Strip a single trailing `\r` (covers `\r\n` line endings inside
  # a `\n\n`-separated event).
  defp strip_cr(line) do
    size = byte_size(line) - 1

    case line do
      <<rest::binary-size(^size), "\r">> -> rest
      _ -> line
    end
  end

  # SSE RFC: `data: foo` and `data:foo` (no space) are both valid;
  # the optional single space after the colon is consumed if present.
  # Comments (`: ...`), `event:`, `id:`, `retry:`, and unrecognised
  # line types are ignored.
  defp data_line("data:" <> rest), do: [strip_leading_space(rest)]
  defp data_line(_), do: []

  defp strip_leading_space(<<" ", rest::binary>>), do: rest
  defp strip_leading_space(rest), do: rest

  # JSON-RPC dispatch: object → one message; array → backward-compat
  # path (telemetry + iterate).
  defp dispatch_value(value, request_id) when is_map(value) do
    match_message(value, request_id)
  end

  defp dispatch_value(value, request_id) when is_list(value) do
    :telemetry.execute(@telemetry_event, %{count: 1}, %{})
    dispatch_array(value, request_id)
  end

  defp dispatch_value(_other, _request_id), do: :continue

  defp dispatch_array([], _request_id), do: :continue

  defp dispatch_array([head | tail], request_id) do
    case match_message(head, request_id) do
      {:done, msg} -> {:done, msg}
      :continue -> dispatch_array(tail, request_id)
    end
  end

  # A JSON-RPC message is "the response" if it carries `"id"` and
  # that id equals the in-flight `request_id`. Notifications (no
  # `"id"`) and different-id messages are dropped.
  defp match_message(%{"id" => id} = msg, request_id) when id == request_id do
    {:done, msg}
  end

  defp match_message(_msg, _request_id), do: :continue
end
