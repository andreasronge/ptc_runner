defmodule PtcRunner.Labs.PersistentTLSFixture do
  @moduledoc false

  # Minimal HTTP/1.1 TLS peer for the transport pilot. Unlike the general test
  # fixture, it accepts multiple requests on one connection and records the
  # physical connection/request ratio. It deliberately supports only bounded
  # content-length requests and responses needed by this lab.
  def start(handler, server_options) when is_function(handler, 1) do
    {:ok, listener} =
      :ssl.listen(
        0,
        [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++
          server_options
      )

    {:ok, {_, port}} = :ssl.sockname(listener)

    {:ok, stats} =
      Agent.start_link(fn ->
        %{accepted_connections: 0, connections: 0, requests: 0, per_connection: %{}}
      end)

    {:ok, supervisor} = Task.Supervisor.start_link(max_children: 32)

    {:ok, acceptor} =
      Task.Supervisor.start_child(supervisor, fn ->
        accept_loop(listener, supervisor, stats, handler)
      end)

    %{
      endpoint: "https://localhost:#{port}/mcp",
      snapshot: fn -> Agent.get(stats, &project_stats/1) end,
      close: fn ->
        :ssl.close(listener)
        if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)

        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _ -> :ok
        end

        if Process.alive?(stats), do: Agent.stop(stats)
        :ok
      end
    }
  end

  defp accept_loop(listener, supervisor, stats, handler) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        Agent.update(stats, &Map.update!(&1, :accepted_connections, fn count -> count + 1 end))

        {:ok, worker} =
          Task.Supervisor.start_child(supervisor, fn ->
            receive do
              {:socket, owned_socket} -> serve_connection(owned_socket, stats, handler)
            end
          end)

        :ok = :ssl.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept_loop(listener, supervisor, stats, handler)

      {:error, _} ->
        :ok
    end
  end

  defp serve_connection(socket, stats, handler) do
    connection = System.unique_integer([:positive, :monotonic])

    try do
      with {:ok, socket} <- :ssl.handshake(socket, 5_000) do
        Agent.update(stats, fn state ->
          %{
            state
            | connections: state.connections + 1,
              per_connection: Map.put(state.per_connection, connection, 0)
          }
        end)

        serve_requests(socket, stats, connection, handler, "")
      end
    after
      :ssl.close(socket)
    end
  end

  defp serve_requests(socket, stats, connection, handler, buffered) do
    with {:ok, head, rest} <- read_head(socket, buffered),
         {:ok, request, length} <- parse_head(head),
         {:ok, body, tail} <- read_body(socket, rest, length) do
      request = Map.put(request, :body, decode_body(body))

      Agent.update(stats, fn state ->
        %{
          state
          | requests: state.requests + 1,
            per_connection:
              Map.update!(state.per_connection, connection, fn requests -> requests + 1 end)
        }
      end)

      case handler.(request) do
        {status, headers, response_body} ->
          close? = request.headers["connection"] == "close"
          :ok = send_response(socket, status, headers, response_body, close?)
          if not close?, do: serve_requests(socket, stats, connection, handler, tail)

        other ->
          raise "persistent TLS fixture received unsupported response: #{inspect(other)}"
      end
    else
      {:error, :closed} -> :ok
      {:error, _} -> :ok
    end
  end

  defp read_head(socket, acc) when byte_size(acc) <= 65_536 do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_partial] ->
        case :ssl.recv(socket, 0, 5_000) do
          {:ok, chunk} -> read_head(socket, acc <> chunk)
          {:error, :closed} -> {:error, :closed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_head(_socket, _acc), do: {:error, :head_exceeded}

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")

    with [method, path, "HTTP/1.1"] <- String.split(request_line, " "),
         {:ok, headers} <- parse_headers(header_lines),
         {length, ""} <- Integer.parse(Map.get(headers, "content-length", "0")) do
      {:ok, %{method: method, path: path, headers: headers}, length}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, headers} ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          {:cont, {:ok, Map.put(headers, String.downcase(name), String.trim(value))}}

        _ ->
          {:halt, {:error, :invalid_header}}
      end
    end)
  end

  defp read_body(_socket, rest, length) when byte_size(rest) >= length do
    <<body::binary-size(^length), tail::binary>> = rest
    {:ok, body, tail}
  end

  defp read_body(socket, rest, length) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_body(socket, rest <> chunk, length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_body(""), do: nil

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp send_response(socket, status, headers, body, close?) do
    reason = if status in 200..299, do: "OK", else: "Error"
    connection = if close?, do: "close", else: "keep-alive"

    headers =
      headers ++
        [
          {"content-length", Integer.to_string(byte_size(body))},
          {"connection", connection}
        ]

    encoded_headers = Enum.map_join(headers, "\r\n", fn {name, value} -> "#{name}: #{value}" end)
    :ssl.send(socket, "HTTP/1.1 #{status} #{reason}\r\n#{encoded_headers}\r\n\r\n#{body}")
  end

  defp project_stats(state) do
    counts = Map.values(state.per_connection)

    %{
      accepted_connections: state.accepted_connections,
      connections: state.connections,
      requests: state.requests,
      requests_by_connection: state.per_connection,
      reused_connections: Enum.count(counts, &(&1 > 1)),
      max_requests_per_connection: Enum.max(counts, fn -> 0 end)
    }
  end
end
