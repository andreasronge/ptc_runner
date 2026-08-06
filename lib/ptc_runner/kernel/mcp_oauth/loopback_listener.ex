defmodule PtcRunner.Kernel.MCPOAuth.LoopbackListener do
  @moduledoc """
  Single-shot, dependency-free OAuth loopback callback interaction.

  The listener binds an ephemeral port on one configured loopback IP literal.
  It accepts only an HTTP/1.1 origin-form `GET` for the exact callback path
  with one exact `Host` header and no request body. The socket is passive and
  owned by the foreground caller; callback parameters never enter another
  process, Logger, Telemetry, or command-line arguments.

  The pending authorization's deadline is absolute. An interaction that has
  already expired accepts no connection and reads no bytes, including bytes the
  socket has already buffered, so a client cannot complete or extend an
  authorization after its deadline. Expiry at any point reports
  `:authorization_timeout`; only malformed input or a socket failure reports
  `:invalid_callback_request`.
  """

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.PendingAuthorization

  @enforce_keys [:socket, :host, :address, :port, :path, :redirect_uri]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          socket: port(),
          host: binary(),
          address: :inet.ip_address(),
          port: :inet.port_number(),
          path: binary(),
          redirect_uri: binary()
        }

  @max_request_bytes 16_384
  @max_headers 32

  @spec start(Authority.t()) :: {:ok, t()} | {:error, atom()}
  def start(%Authority{client: %{redirect: {:loopback, descriptor}}} = authority) do
    with true <- Authority.cli_compatible?(authority),
         {:ok, address} <- parse_loopback(descriptor.host),
         family = if(tuple_size(address) == 4, do: :inet, else: :inet6),
         {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             family,
             active: false,
             packet: :raw,
             reuseaddr: false,
             ip: address
           ]),
         {:ok, {_address, port}} <- :inet.sockname(socket) do
      redirect_uri =
        "http://" <>
          authority_host(descriptor.host) <>
          ":" <>
          Integer.to_string(port) <>
          descriptor.path

      {:ok,
       %__MODULE__{
         socket: socket,
         host: descriptor.host,
         address: address,
         port: port,
         path: descriptor.path,
         redirect_uri: redirect_uri
       }}
    else
      _invalid -> {:error, :invalid_loopback_listener}
    end
  end

  def start(_authority), do: {:error, :invalid_loopback_listener}

  @spec await(t(), Context.t(), PendingAuthorization.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def await(
        %__MODULE__{} = listener,
        %Context{} = context,
        %PendingAuthorization{} = pending,
        opts
      )
      when is_list(opts) do
    result = await_callback(listener, context, pending, opts)

    :gen_tcp.close(listener.socket)

    case result do
      {:ok, _grant} = success ->
        success

      {:error, _reason} = error ->
        cancel_pending(context, pending, opts, error)
    end
  end

  def await(_listener, _context, _pending, _opts),
    do: {:error, :authorization_callback_failed}

  # A failed interaction must not leave a live pending authorization behind, so
  # an unsettled cancellation outranks the reason that triggered it rather than
  # being discarded. Cancellation is the first terminal action here, so it
  # anchors the lifecycle owner's one cleanup deadline through the supplied
  # operation and spends that deadline; the session close that follows consumes
  # what is left of the same one rather than minting the budget again.
  defp cancel_pending(context, pending, opts, error) do
    with {:ok, deadline} <- anchor_cleanup_deadline(opts),
         :ok <-
           Authorization.cancel_authorization(context, pending, cleanup_deadline: deadline) do
      error
    else
      _unsettled -> {:error, :authorization_cleanup_failed}
    end
  end

  defp anchor_cleanup_deadline(opts) do
    case Keyword.get(opts, :anchor_cleanup_deadline) do
      anchor when is_function(anchor, 0) -> anchor.()
      _missing -> :error
    end
  end

  defp await_callback(listener, context, pending, opts) do
    case remaining(pending.deadline_ms) do
      0 ->
        {:error, :authorization_timeout}

      remaining ->
        case :gen_tcp.accept(listener.socket, remaining) do
          {:ok, socket} -> handle_connection(socket, listener, context, pending, opts)
          {:error, :timeout} -> {:error, :authorization_timeout}
          {:error, _reason} -> {:error, :authorization_callback_failed}
        end
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket}) do
    _ = :gen_tcp.close(socket)
    :ok
  end

  def close(_listener), do: :ok

  defp handle_connection(socket, listener, context, pending, opts) do
    result =
      with {:ok, raw} <- receive_request(socket, "", pending.deadline_ms),
           {:ok, parameters} <- parse_request(raw, listener) do
        Authorization.complete_authorization(context, pending, parameters, opts)
      end

    response =
      case result do
        {:ok, _grant} ->
          response(200, "OK", "Authorization complete. You may close.")

        {:error, _reason} ->
          response(400, "Bad Request", "Authorization could not finish.")
      end

    _ = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
    result
  end

  defp receive_request(socket, accumulator, deadline_ms) do
    cond do
      byte_size(accumulator) > @max_request_bytes ->
        {:error, :invalid_callback_request}

      :binary.match(accumulator, "\r\n\r\n") != :nomatch ->
        {:ok, accumulator}

      true ->
        receive_chunk(socket, accumulator, deadline_ms, remaining(deadline_ms))
    end
  end

  # `:gen_tcp.recv/3` returns bytes the socket has already buffered even with a
  # zero timeout, so a client that keeps trickling would extend an expired
  # interaction past its deadline, potentially until the request cap stops it.
  # Expiry is therefore decided before the call rather than delegated to its
  # timeout.
  defp receive_chunk(_socket, _accumulator, _deadline_ms, 0),
    do: {:error, :authorization_timeout}

  defp receive_chunk(socket, accumulator, deadline_ms, timeout_ms) do
    case :gen_tcp.recv(socket, 0, timeout_ms) do
      {:ok, chunk} -> receive_request(socket, accumulator <> chunk, deadline_ms)
      {:error, :timeout} -> {:error, :authorization_timeout}
      _failure -> {:error, :invalid_callback_request}
    end
  end

  defp parse_request(raw, listener) do
    with {head, ""} <- split_head(raw),
         [request_line | header_lines] <- :binary.split(head, "\r\n", [:global]),
         true <- length(header_lines) in 1..@max_headers,
         {:ok, target} <- request_line(request_line),
         {:ok, headers} <- headers(header_lines),
         :ok <- validate_host(headers, listener),
         false <- header_present?(headers, "content-length"),
         false <- header_present?(headers, "transfer-encoding"),
         {:ok, parameters} <- target(target, listener.path) do
      {:ok, parameters}
    else
      _invalid -> {:error, :invalid_callback_request}
    end
  end

  defp split_head(raw) do
    case :binary.split(raw, "\r\n\r\n") do
      [head, body] -> {head, body}
      _invalid -> :invalid
    end
  end

  defp request_line(line) do
    case :binary.split(line, " ", [:global]) do
      ["GET", target, "HTTP/1.1"] when byte_size(target) in 1..8_192 ->
        if String.starts_with?(target, "/") and not String.starts_with?(target, "//"),
          do: {:ok, target},
          else: {:error, :invalid_request_target}

      _invalid ->
        {:error, :invalid_request_line}
    end
  end

  defp headers(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, headers} ->
      case :binary.split(line, ":") do
        [name, value]
        when byte_size(name) in 1..256 and byte_size(value) <= 8_192 ->
          if valid_header_name?(name) and valid_header_value?(value) do
            {:cont, {:ok, [{ascii_downcase(name), String.trim(value)} | headers]}}
          else
            {:halt, {:error, :invalid_header}}
          end

        _invalid ->
          {:halt, {:error, :invalid_header}}
      end
    end)
  end

  defp validate_host(headers, listener) do
    expected = authority_host(listener.host) <> ":" <> Integer.to_string(listener.port)

    case for({"host", value} <- headers, do: value) do
      [^expected] -> :ok
      _invalid -> {:error, :invalid_host}
    end
  end

  defp target(target, path) do
    case :binary.split(target, "?", [:global]) do
      [^path, query] when query != "" ->
        decode_query(query)

      [^path] ->
        {:ok, []}

      _invalid ->
        {:error, :invalid_callback_path}
    end
  end

  defp decode_query(query) do
    parameters = Enum.to_list(URI.query_decoder(query))

    if length(parameters) <= 32 and
         Enum.all?(parameters, fn {name, value} ->
           is_binary(name) and is_binary(value) and String.valid?(name) and String.valid?(value)
         end),
       do: {:ok, parameters},
       else: {:error, :invalid_callback_query}
  rescue
    _exception -> {:error, :invalid_callback_query}
  end

  defp parse_loopback(host) do
    with {:ok, address} <- :inet.parse_address(String.to_charlist(host)),
         true <- address in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      {:ok, address}
    else
      _invalid -> {:error, :invalid_loopback}
    end
  end

  defp authority_host(host) do
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  defp header_present?(headers, name),
    do: Enum.any?(headers, fn {header_name, _value} -> header_name == name end)

  defp valid_header_name?(name) do
    Enum.all?(:binary.bin_to_list(name), fn byte ->
      byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or
        byte in ~c"!#$%&'*+-.^_`|~"
    end)
  end

  defp valid_header_value?(value),
    do: String.valid?(value) and not String.contains?(value, ["\r", "\n", <<0>>])

  defp ascii_downcase(value) do
    for <<byte <- value>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end

  # Zero, not one: an expired interaction must reach the explicit timeout
  # branches above instead of buying another millisecond of accept or receive.
  defp remaining(deadline_ms),
    do: max(deadline_ms - System.monotonic_time(:millisecond), 0)

  defp response(status, reason, body) do
    "HTTP/1.1 #{status} #{reason}\r\n" <>
      "content-type: text/plain; charset=utf-8\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <> body
  end
end
