defmodule PtcRunner.Examples.KernelInspectionLab.MCPFixture do
  @moduledoc false

  def start(handler) when is_function(handler, 1) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    {:ok, acceptor} = Task.start(fn -> accept_loop(listener, handler) end)

    %{
      endpoint: "http://127.0.0.1:#{port}/mcp",
      close: fn ->
        :gen_tcp.close(listener)
        if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
        :ok
      end
    }
  end

  defp accept_loop(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, worker} = Task.start(fn -> await_socket(handler) end)
        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept_loop(listener, handler)

      {:error, _reason} ->
        :ok
    end
  end

  defp await_socket(handler) do
    receive do
      {:socket, socket} -> handle_socket(socket, handler)
    end
  end

  defp handle_socket(socket, handler) do
    with {:ok, head, rest} <- read_head(socket, ""),
         {:ok, request, length} <- parse_head(head),
         {:ok, body} <- read_body(socket, rest, length) do
      request = Map.put(request, :body, decode_body(body))
      {status, headers, response_body} = handler.(request)
      send_response(socket, status, headers, response_body)
    else
      _reason -> send_response(socket, 400, [], "")
    end
  after
    :gen_tcp.close(socket)
  end

  defp read_head(socket, acc) when byte_size(acc) <= 65_536 do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] -> {:ok, head, rest}
      [_partial] -> recv_head(socket, acc)
    end
  end

  defp read_head(_socket, _acc), do: {:error, :head_exceeded}

  defp recv_head(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_head(socket, acc <> chunk)
      error -> error
    end
  end

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")

    with [method, path, _version] <- String.split(request_line, " "),
         {:ok, headers} <- parse_headers(header_lines),
         {length, ""} <- Integer.parse(Map.get(headers, "content-length", "0")) do
      {:ok, %{method: method, path: path, headers: headers}, length}
    else
      _reason -> {:error, :invalid_request}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, headers} ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          {:cont, {:ok, Map.put(headers, String.downcase(name), String.trim(value))}}

        _parts ->
          {:halt, {:error, :invalid_header}}
      end
    end)
  end

  defp read_body(_socket, rest, length) when byte_size(rest) == length, do: {:ok, rest}

  defp read_body(socket, rest, length) when byte_size(rest) < length do
    case :gen_tcp.recv(socket, length - byte_size(rest), 5_000) do
      {:ok, chunk} -> read_body(socket, rest <> chunk, length)
      error -> error
    end
  end

  defp read_body(_socket, _rest, _length), do: {:error, :invalid_body}
  defp decode_body(""), do: nil
  defp decode_body(body), do: Jason.decode!(body)

  defp send_response(socket, status, headers, body) do
    reason = if status in 200..299, do: "OK", else: "Error"

    headers =
      headers ++
        [{"content-length", Integer.to_string(byte_size(body))}, {"connection", "close"}]

    encoded = Enum.map_join(headers, "\r\n", fn {name, value} -> "#{name}: #{value}" end)
    :gen_tcp.send(socket, "HTTP/1.1 #{status} #{reason}\r\n#{encoded}\r\n\r\n#{body}")
  end
end
