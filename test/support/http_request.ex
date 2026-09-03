defmodule PtcRunner.TestSupport.HTTPRequest do
  @moduledoc false

  def receive_complete(socket, timeout \\ 2_000), do: receive_complete(socket, "", timeout)

  defp receive_complete(socket, buffered, timeout) do
    case complete?(buffered) do
      true ->
        {:ok, buffered}

      false ->
        with {:ok, bytes} <- :gen_tcp.recv(socket, 0, timeout),
             do: receive_complete(socket, buffered <> bytes, timeout)
    end
  end

  defp complete?(request) do
    case :binary.split(request, "\r\n\r\n") do
      [headers, body] -> byte_size(body) >= content_length(headers)
      [_headers_only] -> false
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "content-length", do: String.to_integer(String.trim(value))

        _other ->
          nil
      end
    end)
  end
end
