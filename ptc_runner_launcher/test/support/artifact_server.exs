defmodule PtcRunnerLauncher.TestSupport.ArtifactServer do
  @moduledoc false

  @max_request_bytes 16_384
  @receive_timeout_ms 5_000

  def main([directory, address_file]) do
    directory = Path.expand(directory)
    true = File.dir?(directory)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    File.write!(address_file, "http://127.0.0.1:#{port}\n")
    accept(listener, directory)
  end

  def main(_args) do
    IO.puts(:stderr, "usage: artifact_server.exs DIRECTORY ADDRESS_FILE")
    System.halt(64)
  end

  defp accept(listener, directory) do
    {:ok, socket} = :gen_tcp.accept(listener)
    serve(socket, directory)
    accept(listener, directory)
  end

  defp serve(socket, directory) do
    response =
      with {:ok, request} <- receive_headers(socket, ""),
           {:ok, filename} <- requested_filename(request),
           path = Path.join(directory, filename),
           true <- File.regular?(path),
           {:ok, body} <- File.read(path) do
        [
          "HTTP/1.1 200 OK\r\n",
          "Content-Type: application/octet-stream\r\n",
          "Content-Length: #{byte_size(body)}\r\n",
          "Connection: close\r\n\r\n",
          body
        ]
      else
        _reason ->
          "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      end

    :ok = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp receive_headers(_socket, request) when byte_size(request) > @max_request_bytes,
    do: {:error, :request_too_large}

  defp receive_headers(socket, request) do
    if String.contains?(request, "\r\n\r\n") do
      {:ok, request}
    else
      case :gen_tcp.recv(socket, 0, @receive_timeout_ms) do
        {:ok, bytes} -> receive_headers(socket, request <> bytes)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp requested_filename(request) do
    with [request_line | _headers] <- String.split(request, "\r\n"),
         ["GET", "/" <> filename, "HTTP/1.1"] <- String.split(request_line, " "),
         true <- filename != "" and filename == Path.basename(filename) do
      {:ok, filename}
    else
      _reason -> {:error, :invalid_request}
    end
  end
end

PtcRunnerLauncher.TestSupport.ArtifactServer.main(System.argv())
