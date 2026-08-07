defmodule PtcRunner.Kernel.MCPHTTPAdapter do
  @moduledoc """
  Bounded, non-pooling HTTP transport for MCP and MCP OAuth traffic.

  The adapter talks to Mint directly so request headers and bodies never enter
  a pool process or global Telemetry events. Each call owns one socket,
  rejects redirects at the caller's protocol layer, observes one absolute
  timeout budget, and closes the connection after the response or on caller
  exit. Socket ownership and Mint message handling run in a dedicated worker,
  so synchronous requests cannot consume unrelated messages from the caller's
  mailbox.

  `request/1` accepts optional `:on_status`, `:on_headers`, and `:on_data`
  callbacks for bounded streaming. The status callback receives the response
  as soon as a status line is parsed, the header callback receives it after
  each header block, and the data callback receives the current response and
  one data chunk. Each returns either `{:cont, response}` or
  `{:halt, response}`. Halting closes the socket immediately; MCP uses this to
  act on a definitive `401` even when the remaining header block is malformed
  or stalls, act on a complete `403` challenge without waiting for its body,
  stop after one complete SSE response, or stop at a response ceiling.

  This module deliberately emits no request-bearing Logger or Telemetry data.
  Returned errors are closed atoms and never retain Mint exceptions, endpoint
  strings, headers, or bodies.

  ## Receive ceiling

  `:max_body_bytes`, `:max_headers`, and `:max_header_bytes` bound what is
  *kept*. They cannot bound what a peer may *deliver*, because they are applied
  to values Mint has already parsed out of a socket message that reached this
  process whole. Two further bounds cover that gap, and both are enforced
  before any parsing.

  `:max_receive_bytes` is the per-message ceiling. It is applied as the
  socket's `buffer` option, which is the size of the driver's user-level read
  buffer and therefore the largest single `{:tcp, _, data}` the driver will
  deliver. Mint cannot carry it: its private inet-options helper raises `buffer`
  to `max(buffer, sndbuf, recbuf)` on every `initiate/5`, so a value passed
  through `:transport_opts` is overwritten with an operating-system-derived
  size — 400 KiB on an ordinary loopback socket. The connection is therefore
  opened in `:passive` mode, which is the one mode whose `initiate/5` does not
  arm `active: :once`, the ceiling is applied to the unarmed socket, and only
  then is the connection switched to `:active`. Setting the ceiling on an
  already-armed socket is too late: the driver has a read outstanding under the
  old buffer, and a 160 KiB message can still arrive under a 16 KiB ceiling.

  Over TLS the ceiling bounds the *ciphertext* read, so a record left over from
  a previous read may be delivered alongside a full buffer. One TLS record
  (16_384 bytes, the protocol's plaintext maximum) is the documented allowance;
  `:max_receive_bytes` is required to be a whole number of records so the two
  are expressed in the same unit.

  The socket option makes the bound true; it does not *enforce* it, so the
  receive loop also refuses any single message over the declared maximum. One
  window needs that: Mint raises `buffer` at the end of its connect, and over
  TLS the `ssl` connection process accumulates under the raised value if this
  worker is descheduled before the ceiling is reapplied. A 30 ms gap delivers a
  whole operating-system receive buffer — 400 KiB against a 16 KiB ceiling.
  Lowering `buffer` afterwards does not shrink what has already accumulated,
  and Mint's raise cannot be prevented: it is `max(buffer, sndbuf, recbuf)`, and
  the operating system clamps a small `recbuf` back up. The refusal costs a
  legitimate peer nothing, because the window closes before the request is sent
  and anything accumulating inside it was unsolicited.

  The second ceiling is derived rather than passed, and bounds what Mint may
  buffer *unparsed* — the one thing none of the other limits can see. A peer
  that never completes a status line, a chunk-size line, or a chunk extension
  produces no Mint response at all, so no limit on a parsed value ever runs,
  while Mint buffers the remainder with no ceiling of its own. Without this
  count, 64 MiB from such a peer becomes 64 MiB resident in this process.

  It is counted over raw socket payloads before they reach Mint, and **reset
  whenever Mint returns any response**, because a response means Mint consumed
  what it had rather than kept it. That reset is what keeps the ceiling off the
  transfer encoding: chunked framing costs about six bytes per chunk, so a
  cumulative wire ceiling would have to guess how finely a peer chunks its body
  and would refuse a legitimate 2 MiB `text/event-stream` sent as 100-byte
  events. Only a peer sending bytes that yield nothing accumulates. The ceiling
  is `max_header_bytes` plus one whole delivered message — the largest header
  block Mint will accept before emitting anything, plus the largest thing the
  transport can hand over in one piece — and a peer that crosses it is refused
  with `:response_exceeded`.

  Resident bytes for one response are bounded, but not by a plain sum of the
  four numbers, and the difference is worth stating because it is easy to get
  wrong: a reset zeroes the *counter* while Mint's leftover survives it, so the
  unparsed remainder is the pending ceiling plus the message that carried the
  reset. It does not ratchet beyond that — Mint's leftover is always a prefix of
  the incomplete token at the front, and emitting anything consumes that prefix
  whole, so leftover at a reset is at most one message. The bound is therefore
  the accumulated body and headers, plus the pending ceiling, plus two delivered
  messages: the one that carried the last reset and the one in flight.

  What is *not* bounded here is total bytes read. A peer may send bare `1xx`
  informational responses indefinitely: Mint emits a response for each, so the
  counter resets, and none of them advances a header or body ceiling either.
  That costs bandwidth and scheduling but not memory, and the operation deadline
  is what ends it. Bounding it would mean a cumulative wire ceiling, which is
  the thing the reset exists to avoid.
  """

  @typedoc "A bounded response with downcased header names."
  @type response :: %{
          required(:status) => non_neg_integer(),
          required(:headers) => [{binary(), binary()}],
          required(:body) => term(),
          optional(:authorization_result) => term()
        }

  @type dispatch_provenance :: :not_dispatched | :possibly_dispatched
  @type reason :: :invalid_request | :timeout | :transport_error | :response_exceeded

  @default_max_headers 64
  @default_max_header_bytes 32_768
  @default_max_body_bytes 2_097_152
  @default_max_receive_bytes 65_536

  # The TLS record plaintext maximum (RFC 8446 §5.1). It is both the smallest
  # per-message ceiling TLS can honour and the size of the carry-over a TLS
  # delivery may add to one buffer's worth of ciphertext.
  @tls_record_bytes 16_384
  @max_max_receive_bytes 1_048_576

  @spec request(keyword()) ::
          {:ok, response()}
          | {:error, reason(), dispatch_provenance()}
  def request(opts) when is_list(opts) do
    case validate_request(opts) do
      {:ok, request} -> request_in_worker(request)
      {:error, :invalid_request} -> {:error, :invalid_request, :not_dispatched}
    end
  rescue
    _exception -> {:error, :transport_error, :not_dispatched}
  catch
    _kind, _reason -> {:error, :transport_error, :not_dispatched}
  end

  def request(_opts), do: {:error, :invalid_request, :not_dispatched}

  defp request_in_worker(request) do
    caller = self()
    reply_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        watcher = start_caller_watcher(caller)
        result = perform_request(request, caller)
        send(caller, {reply_ref, result})
        send(watcher, {:stop, self()})
      end)

    await_worker(pid, monitor_ref, reply_ref, request)
  end

  defp await_worker(pid, monitor_ref, reply_ref, request) do
    remaining = remaining_ms(request)

    if remaining <= 0 do
      stop_worker(pid, monitor_ref, reply_ref)
      {:error, :timeout, :possibly_dispatched}
    else
      receive do
        {^reply_ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          result

        {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
          {:error, :transport_error, :possibly_dispatched}
      after
        remaining ->
          stop_worker(pid, monitor_ref, reply_ref)
          {:error, :timeout, :possibly_dispatched}
      end
    end
  end

  defp stop_worker(pid, monitor_ref, reply_ref) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    end

    receive do
      {^reply_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp start_caller_watcher(caller) do
    worker = self()

    watcher =
      spawn(fn ->
        caller_ref = Process.monitor(caller)
        worker_ref = Process.monitor(worker)
        send(worker, {:caller_watcher_ready, self()})

        receive do
          {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
            Process.exit(worker, :kill)

          {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
            :ok

          {:stop, ^worker} ->
            Process.demonitor(caller_ref, [:flush])
            Process.demonitor(worker_ref, [:flush])
        end
      end)

    receive do
      {:caller_watcher_ready, ^watcher} -> watcher
    end
  end

  defp perform_request(request, caller) do
    with true <- Process.alive?(caller),
         {:ok, connection} <- connect(request) do
      if Process.alive?(caller) do
        safe_perform(connection, request)
      else
        close(connection)
        {:error, :transport_error, :not_dispatched}
      end
    else
      false -> {:error, :transport_error, :not_dispatched}
      {:error, :timeout} -> {:error, :timeout, :not_dispatched}
      {:error, _reason} -> {:error, :transport_error, :not_dispatched}
    end
  rescue
    _exception -> {:error, :transport_error, :not_dispatched}
  catch
    _kind, _reason -> {:error, :transport_error, :not_dispatched}
  end

  @doc """
  Returns all values for a response header using an ASCII-insensitive name.
  """
  @spec get_header(response(), binary()) :: [binary()]
  def get_header(%{headers: headers}, name) when is_list(headers) and is_binary(name) do
    downcased = ascii_downcase(name)

    for {header_name, value} <- headers,
        ascii_downcase(header_name) == downcased,
        do: value
  end

  def get_header(_response, _name), do: []

  defp validate_request(opts) do
    allowed = [
      :method,
      :url,
      :headers,
      :body,
      :timeout_ms,
      :max_body_bytes,
      :max_headers,
      :max_header_bytes,
      :max_receive_bytes,
      :on_status,
      :on_headers,
      :on_data,
      :address,
      :connected_peer
    ]

    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys -- allowed == [] and Enum.uniq(keys) == keys,
         method when method in [:get, :post] <- Keyword.get(opts, :method),
         url when is_binary(url) <- Keyword.get(opts, :url),
         {:ok, uri} <- parse_uri(url),
         headers when is_list(headers) <- Keyword.get(opts, :headers, []),
         true <- valid_request_headers?(headers),
         body when is_binary(body) <- Keyword.get(opts, :body, ""),
         timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 <-
           Keyword.get(opts, :timeout_ms),
         max_body_bytes when is_integer(max_body_bytes) and max_body_bytes > 0 <-
           Keyword.get(opts, :max_body_bytes, @default_max_body_bytes),
         max_headers when is_integer(max_headers) and max_headers in 1..256 <-
           Keyword.get(opts, :max_headers, @default_max_headers),
         max_header_bytes
         when is_integer(max_header_bytes) and max_header_bytes in 1..262_144 <-
           Keyword.get(opts, :max_header_bytes, @default_max_header_bytes),
         max_receive_bytes when is_integer(max_receive_bytes) <-
           Keyword.get(opts, :max_receive_bytes, @default_max_receive_bytes),
         true <-
           max_receive_bytes in @tls_record_bytes..@max_max_receive_bytes and
             rem(max_receive_bytes, @tls_record_bytes) == 0,
         on_status when is_function(on_status, 1) <-
           Keyword.get(opts, :on_status, &continue_headers/1),
         on_headers when is_function(on_headers, 1) <-
           Keyword.get(opts, :on_headers, &continue_headers/1),
         on_data when is_function(on_data, 2) <-
           Keyword.get(opts, :on_data, &accumulate_data/2),
         {:ok, address} <- optional_address(Keyword.get(opts, :address), uri),
         {:ok, connected_peer} <-
           optional_connected_peer(Keyword.get(opts, :connected_peer)) do
      {:ok,
       %{
         scheme: String.to_existing_atom(uri.scheme),
         address: address,
         hostname: uri.host,
         port: uri.port || default_port(uri.scheme),
         path: request_path(uri),
         method: method |> Atom.to_string() |> String.upcase(),
         headers: headers,
         body: body,
         timeout_ms: timeout_ms,
         deadline_ms: System.monotonic_time(:millisecond) + timeout_ms,
         max_body_bytes: max_body_bytes,
         max_headers: max_headers,
         max_header_bytes: max_header_bytes,
         max_receive_bytes: max_receive_bytes,
         max_message_bytes: max_receive_bytes + @tls_record_bytes,
         # The ceiling has to admit one whole delivered message or a single
         # legitimate https message could exceed it on its own.
         max_pending_bytes: max_header_bytes + max_receive_bytes + @tls_record_bytes,
         on_status: on_status,
         on_headers: on_headers,
         on_data: on_data,
         connected_peer: connected_peer
       }}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{
        scheme: scheme,
        host: host,
        userinfo: nil,
        fragment: nil
      } = uri
      when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
        {:ok, uri}

      _invalid ->
        {:error, :invalid_request}
    end
  end

  defp optional_address(nil, %URI{host: host}), do: {:ok, host}

  defp optional_address(address, _uri)
       when is_tuple(address) or is_binary(address),
       do: {:ok, address}

  defp optional_address(_address, _uri), do: {:error, :invalid_request}

  defp optional_connected_peer(nil), do: {:ok, nil}
  defp optional_connected_peer(callback) when is_function(callback, 1), do: {:ok, callback}
  defp optional_connected_peer(_callback), do: {:error, :invalid_request}

  defp valid_request_headers?(headers) do
    length(headers) <= 256 and
      Enum.all?(headers, fn
        {name, value} when is_binary(name) and is_binary(value) ->
          byte_size(name) in 1..256 and byte_size(value) <= 16_384 and
            not String.contains?(name, ["\r", "\n", <<0>>]) and
            not String.contains?(value, ["\r", "\n", <<0>>])

        _invalid ->
          false
      end)
  end

  defp request_path(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if is_nil(query), do: path, else: path <> "?" <> query
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp connect(request) do
    with remaining when remaining > 0 <- remaining_ms(request),
         transport_opts = transport_opts(request.scheme, request.address, remaining),
         opts = [
           hostname: request.hostname,
           protocols: [:http1],
           max_header_list_size: request.max_header_bytes,
           # Passive is the only mode whose `initiate/5` leaves the socket
           # unarmed, which is what makes the receive ceiling below authoritative
           # rather than a race against a read already in flight.
           mode: :passive,
           transport_opts: transport_opts
         ],
         {:ok, connection} <-
           Mint.HTTP.connect(request.scheme, request.address, request.port, opts) do
      activate(connection, request)
    else
      remaining when is_integer(remaining) and remaining <= 0 ->
        {:error, :timeout}

      {:error, reason} ->
        if timeout_reason?(reason), do: {:error, :timeout}, else: {:error, :transport_error}
    end
  end

  defp activate(connection, request) do
    # The ceiling goes on before the peer verifier, not after. Over TLS the
    # `ssl` connection process reads and decrypts on its own schedule, under
    # whatever buffer is in force at the time, so every step between connecting
    # and applying the ceiling widens the window in which an unsolicited
    # response arrives under Mint's raised one. The verifier is the only step
    # here that runs caller-supplied code, and so the only one with no bound at
    # all. A rejected peer is closed either way, so nothing is spent by
    # capping first.
    with :ok <- apply_receive_cap(connection, request.scheme, request.max_receive_bytes),
         :ok <- verify_connected_peer(connection, request.scheme, request.connected_peer),
         {:ok, connection} <- Mint.HTTP.set_mode(connection, :active) do
      {:ok, connection}
    else
      {:error, _reason} = error ->
        close(connection)
        error
    end
  end

  # Public only so the `:https` branch can be exercised against a real TLS
  # socket. `request/1` trusts the operating system certificate store alone, by
  # design, so no test server it can reach speaks TLS.
  @doc false
  @spec apply_receive_cap(Mint.HTTP.t(), :http | :https, pos_integer()) ::
          :ok | {:error, :transport_error}
  def apply_receive_cap(connection, scheme, max_receive_bytes) do
    socket = Mint.HTTP.get_socket(connection)

    case socket_module(scheme).setopts(socket, buffer: max_receive_bytes) do
      :ok -> :ok
      {:error, _reason} -> {:error, :transport_error}
    end
  rescue
    _exception -> {:error, :transport_error}
  catch
    _kind, _reason -> {:error, :transport_error}
  end

  defp socket_module(:http), do: :inet
  defp socket_module(:https), do: :ssl

  defp transport_opts(:http, address, timeout_ms),
    do: address_family_options(address) ++ [timeout: timeout_ms, send_timeout: timeout_ms]

  defp transport_opts(:https, address, timeout_ms) do
    address_family_options(address) ++
      [
        cacerts: :public_key.cacerts_get(),
        timeout: timeout_ms,
        send_timeout: timeout_ms,
        verify: :verify_peer
      ]
  end

  defp address_family_options(address) when is_tuple(address) and tuple_size(address) == 8,
    do: [inet6: true, inet4: false]

  defp address_family_options(address) when is_tuple(address) and tuple_size(address) == 4,
    do: [inet6: false, inet4: true]

  defp address_family_options(address) when is_binary(address),
    do: [inet6: true, inet4: true]

  defp verify_connected_peer(_connection, _scheme, nil), do: :ok

  defp verify_connected_peer(connection, scheme, callback) do
    case socket_peername(connection, scheme) do
      {:ok, address} ->
        case callback.(address) do
          :ok -> :ok
          _rejected -> {:error, :peer_rejected}
        end

      {:error, _reason} = error ->
        error
    end
  rescue
    _exception -> {:error, :peer_rejected}
  catch
    _kind, _reason -> {:error, :peer_rejected}
  end

  defp socket_peername(connection, scheme),
    do: peername(socket_module(scheme), Mint.HTTP.get_socket(connection))

  defp peername(module, socket) do
    case module.peername(socket) do
      {:ok, {address, _port}} -> {:ok, address}
      {:error, _reason} = error -> error
    end
  end

  defp perform(connection, request) do
    result =
      with remaining when remaining > 0 <- remaining_ms(request),
           {:ok, connection, ref} <-
             Mint.HTTP.request(
               connection,
               request.method,
               request.path,
               request.headers,
               request.body
             ) do
        receive_response(connection, ref, request, nil, 0)
      else
        remaining when is_integer(remaining) and remaining <= 0 ->
          {:error, :timeout, :not_dispatched}

        {:error, connection, reason} ->
          close(connection)

          if timeout_reason?(reason),
            do: {:error, :timeout, :possibly_dispatched},
            else: {:error, :transport_error, :possibly_dispatched}
      end

    case result do
      {:ok, response, connection} ->
        close(connection)
        {:ok, response}

      {:error, reason, provenance, connection} ->
        close(connection)
        {:error, reason, provenance}

      other ->
        close(connection)
        other
    end
  end

  defp safe_perform(connection, request) do
    perform(connection, request)
  rescue
    _exception ->
      close(connection)
      {:error, :transport_error, :possibly_dispatched}
  catch
    _kind, _reason ->
      close(connection)
      {:error, :transport_error, :possibly_dispatched}
  end

  defp receive_response(connection, ref, request, state, pending_bytes) do
    remaining = remaining_ms(request)

    if remaining <= 0 do
      {:error, :timeout, :possibly_dispatched, connection}
    else
      receive do
        message ->
          case count_pending_bytes(message, request, pending_bytes) do
            {:ok, pending_bytes} ->
              handle_stream(
                connection,
                Mint.HTTP.stream(connection, message),
                ref,
                request,
                state,
                pending_bytes
              )

            {:error, reason} ->
              # Refused before `Mint.HTTP.stream/2` sees it, so the bytes over
              # the ceiling are never added to Mint's unparsed buffer.
              {:error, reason, :possibly_dispatched, connection}
          end
      after
        remaining ->
          {:error, :timeout, :possibly_dispatched, connection}
      end
    end
  end

  # Every payload-bearing socket message counts, without checking which socket
  # it came from. The worker owns exactly one connection, so there is no other
  # socket to confuse it with, and matching on the connection's socket would
  # fail open — a comparison that stopped matching would silently disable the
  # ceiling rather than refusing.
  defp count_pending_bytes({transport, _socket, data}, request, pending_bytes)
       when transport in [:tcp, :ssl] and is_binary(data) do
    cond do
      # The socket ceiling is what normally makes this true, but it is a
      # configured bound rather than an enforced one, and there is one window
      # where it does not hold: Mint raises `buffer` at the end of its connect,
      # and over TLS the `ssl` process accumulates under the raised value if
      # this worker is descheduled before the ceiling is reapplied. Measured at
      # a 30 ms gap, that delivers a whole operating-system receive buffer —
      # 400 KiB against a 16 KiB ceiling. Refusing here turns an undocumented
      # overshoot into the documented bound, and costs a legitimate peer
      # nothing: the window closes before the request is sent, so anything
      # accumulating in it was unsolicited.
      byte_size(data) > request.max_message_bytes ->
        {:error, :response_exceeded}

      pending_bytes + byte_size(data) > request.max_pending_bytes ->
        {:error, :response_exceeded}

      true ->
        {:ok, pending_bytes + byte_size(data)}
    end
  end

  defp count_pending_bytes(_message, _request, pending_bytes), do: {:ok, pending_bytes}

  defp handle_stream(connection, :unknown, ref, request, state, pending_bytes),
    do: receive_response(connection, ref, request, state, pending_bytes)

  defp handle_stream(_previous, {:ok, connection, responses}, ref, request, state, pending_bytes) do
    # Anything Mint parsed out is progress: what it kept is now smaller than
    # what arrived, and the ceiling is on what it kept. Only a peer that sends
    # bytes yielding no response at all accumulates towards the refusal.
    pending_bytes = if responses == [], do: pending_bytes, else: 0

    case consume_responses(responses, ref, request, state) do
      {:continue, state} -> receive_response(connection, ref, request, state, pending_bytes)
      {:done, response} -> {:ok, response, connection}
      {:halt, response} -> {:ok, response, connection}
      {:error, reason} -> {:error, reason, :possibly_dispatched, connection}
    end
  end

  defp handle_stream(
         _previous,
         {:error, connection, reason, responses},
         ref,
         request,
         state,
         _pending_bytes
       ) do
    case consume_responses(responses, ref, request, state) do
      {:done, response} ->
        {:ok, response, connection}

      {:halt, response} ->
        {:ok, response, connection}

      {:error, response_reason} ->
        {:error, response_reason, :possibly_dispatched, connection}

      {:continue, _state} ->
        classified =
          cond do
            timeout_reason?(reason) -> :timeout
            response_exceeded_reason?(reason) -> :response_exceeded
            true -> :transport_error
          end

        {:error, classified, :possibly_dispatched, connection}
    end
  end

  defp consume_responses(responses, ref, request, state) do
    Enum.reduce_while(responses, {:continue, state}, fn
      {:status, ^ref, status}, {:continue, state} ->
        case put_status(state, status, request) do
          {:cont, state} -> {:cont, {:continue, state}}
          {:halt, response} -> {:halt, {:halt, response}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:headers, ^ref, headers}, {:continue, state} ->
        case put_headers(state, headers, request) do
          {:cont, state} -> {:cont, {:continue, state}}
          {:halt, response} -> {:halt, {:halt, response}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:data, ^ref, data}, {:continue, state} when is_binary(data) ->
        case put_data(state, data, request) do
          {:cont, state} -> {:cont, {:continue, state}}
          {:halt, response} -> {:halt, {:halt, response}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:done, ^ref}, {:continue, state} ->
        case complete_response(state) do
          {:ok, response} -> {:halt, {:done, response}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, accumulator ->
        {:cont, accumulator}
    end)
  end

  defp put_status(nil, status, request) do
    state = %{
      status: status,
      headers: [],
      body: "",
      received_body_bytes: 0,
      received_header_count: 0,
      received_header_bytes: 0
    }

    apply_headers(request.on_status, state)
  end

  defp put_status(%{status: previous} = state, status, request)
       when previous in 100..199 and status >= 200 do
    state = state |> Map.put(:status, status) |> Map.put(:headers, [])
    apply_headers(request.on_status, state)
  end

  defp put_status(state, status, request),
    do: apply_headers(request.on_status, Map.put(state, :status, status))

  defp put_headers(nil, headers, request),
    do:
      put_headers(
        %{
          status: nil,
          headers: [],
          body: "",
          received_body_bytes: 0,
          received_header_count: 0,
          received_header_bytes: 0
        },
        headers,
        request
      )

  defp put_headers(state, headers, request) do
    normalized = Enum.map(headers, fn {name, value} -> {ascii_downcase(name), value} end)
    header_count = Map.get(state, :received_header_count, 0) + length(normalized)
    header_bytes = Map.get(state, :received_header_bytes, 0) + header_wire_bytes(normalized)

    if header_count <= request.max_headers and header_bytes <= request.max_header_bytes do
      state =
        state
        |> Map.update(:headers, normalized, &(&1 ++ normalized))
        |> Map.put(:received_header_count, header_count)
        |> Map.put(:received_header_bytes, header_bytes)

      apply_headers(request.on_headers, state)
    else
      {:error, :response_exceeded}
    end
  end

  defp apply_headers(callback, state) do
    case callback.(strip_counters(state)) do
      {:cont, response} when is_map(response) -> {:cont, restore_counters(response, state)}
      {:halt, response} when is_map(response) -> {:halt, response}
      _invalid -> {:error, :transport_error}
    end
  rescue
    _exception -> {:error, :transport_error}
  catch
    _kind, _reason -> {:error, :transport_error}
  end

  defp put_data(nil, _data, _request), do: {:error, :transport_error}

  defp put_data(state, data, request) do
    received_body_bytes = Map.get(state, :received_body_bytes, 0) + byte_size(data)

    if received_body_bytes > request.max_body_bytes do
      {:error, :response_exceeded}
    else
      case request.on_data.(state, data) do
        {:cont, response} when is_map(response) ->
          {:cont,
           response
           |> Map.put(:received_body_bytes, received_body_bytes)
           |> Map.put(:body_started?, true)}

        {:halt, response} when is_map(response) ->
          {:halt, response |> Map.put(:body_started?, true) |> strip_counters()}

        _invalid ->
          {:error, :transport_error}
      end
    end
  rescue
    _exception -> {:error, :transport_error}
  catch
    _kind, _reason -> {:error, :transport_error}
  end

  defp complete_response(%{status: status, headers: headers} = response)
       when is_integer(status) and is_list(headers),
       do: {:ok, strip_counters(response)}

  defp complete_response(_state), do: {:error, :transport_error}

  defp accumulate_data(response, data) do
    body = if is_binary(response.body), do: response.body, else: ""
    {:cont, %{response | body: body <> data}}
  end

  defp continue_headers(response), do: {:cont, response}

  defp restore_counters(response, state) do
    response
    |> Map.put(:received_body_bytes, state.received_body_bytes)
    |> Map.put(:received_header_count, state.received_header_count)
    |> Map.put(:received_header_bytes, state.received_header_bytes)
  end

  defp strip_counters(response),
    do:
      Map.drop(response, [
        :received_body_bytes,
        :received_header_count,
        :received_header_bytes,
        :body_started?
      ])

  defp header_wire_bytes(headers) do
    Enum.reduce(headers, 0, fn {name, value}, total ->
      total + byte_size(name) + byte_size(value) + 4
    end)
  end

  defp remaining_ms(request),
    do: request.deadline_ms - System.monotonic_time(:millisecond)

  defp timeout_reason?(%Mint.TransportError{reason: reason}), do: timeout_detail?(reason)
  defp timeout_reason?(%Mint.HTTPError{reason: reason}), do: timeout_detail?(reason)

  defp timeout_detail?(:timeout), do: true
  defp timeout_detail?({:timeout, _detail}), do: true
  defp timeout_detail?({:transport, :timeout}), do: true
  defp timeout_detail?(_reason), do: false

  defp response_exceeded_reason?(%Mint.HTTPError{
         reason: {:max_header_list_size_exceeded, _size, _maximum}
       }),
       do: true

  defp response_exceeded_reason?(_reason), do: false

  defp close(connection) do
    _ = Mint.HTTP.close(connection)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp ascii_downcase(value) when is_binary(value) do
    for <<byte <- value>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end
end
