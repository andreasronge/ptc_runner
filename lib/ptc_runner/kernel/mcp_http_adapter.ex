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
           transport_opts: transport_opts
         ],
         {:ok, connection} <-
           Mint.HTTP.connect(request.scheme, request.address, request.port, opts) do
      case verify_connected_peer(connection, request.scheme, request.connected_peer) do
        :ok ->
          {:ok, connection}

        {:error, _reason} = error ->
          close(connection)
          error
      end
    else
      remaining when is_integer(remaining) and remaining <= 0 ->
        {:error, :timeout}

      {:error, reason} ->
        if timeout_reason?(reason), do: {:error, :timeout}, else: {:error, :transport_error}
    end
  end

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

  defp socket_peername(connection, :http),
    do: peername(:inet, Mint.HTTP.get_socket(connection))

  defp socket_peername(connection, :https),
    do: peername(:ssl, Mint.HTTP.get_socket(connection))

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
        receive_response(connection, ref, request, nil)
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

  defp receive_response(connection, ref, request, state) do
    remaining = remaining_ms(request)

    if remaining <= 0 do
      {:error, :timeout, :possibly_dispatched, connection}
    else
      receive do
        message ->
          handle_stream(connection, Mint.HTTP.stream(connection, message), ref, request, state)
      after
        remaining ->
          {:error, :timeout, :possibly_dispatched, connection}
      end
    end
  end

  defp handle_stream(connection, :unknown, ref, request, state),
    do: receive_response(connection, ref, request, state)

  defp handle_stream(_previous, {:ok, connection, responses}, ref, request, state) do
    case consume_responses(responses, ref, request, state) do
      {:continue, state} -> receive_response(connection, ref, request, state)
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
         state
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
