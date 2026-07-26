defmodule PtcRunner.TestSupport.MCPStdioFixture do
  @moduledoc false

  def main([_marker, "no-read"]) do
    receive do
      :stop -> 0
    end
  end

  def main([marker, "delayed-read"]) do
    receive do
    after
      200 -> :ok
    end

    case IO.read(:stdio, :eof) do
      bytes when is_binary(bytes) -> File.write!(marker, Integer.to_string(byte_size(bytes)))
      _error -> File.write!(marker, "0")
    end
  end

  def main([marker, "close-output"]) do
    IO.read(:stdio, :line)
    File.write!(marker, "ready")
    IO.read(:stdio, :eof)
    IO.write(:stdio, "trailing non-protocol output\n")
  end

  def main([marker, "read"]) do
    marker
    |> loop()
    |> System.halt()
  end

  defp loop(marker) do
    case IO.read(:stdio, :line) do
      :eof ->
        0

      {:error, _reason} ->
        1

      line when is_binary(line) ->
        handle_line(line, marker)
        loop(marker)
    end
  end

  defp handle_line(line, marker) do
    case {extract_id(line), extract_method(line)} do
      {nil, "notifications/cancelled"} ->
        File.write!(marker, line, [:append])

      {id, "slow"} when is_integer(id) ->
        respond_after(id, "slow", 75)

      {id, "fast"} when is_integer(id) ->
        respond_after(id, "fast", 5)

      {id, "never"} when is_integer(id) ->
        :ok

      {id, "junk"} when is_integer(id) ->
        IO.write(:stdio, "not-json\n")

      {id, "large"} when is_integer(id) ->
        respond(id, "large", String.duplicate("x", 2_048))

      {id, "exact"} when is_integer(id) ->
        body = response_body(id, "exact", "")
        respond(id, "exact", String.duplicate("x", 1_048_576 - byte_size(body)))

      {id, "exact-crlf"} when is_integer(id) ->
        body = response_body(id, "exact-crlf", "")
        padding = String.duplicate("x", 1_048_576 - byte_size(body))
        IO.write(:stdio, [response_body(id, "exact-crlf", padding), "\r\n"])

      {id, method} when is_integer(id) and method in ["notify", "notify-flood"] ->
        emit_notifications(id, method, line)

      {id, method} when is_integer(id) and is_binary(method) ->
        respond(id, method)

      _invalid ->
        IO.write(:stdio, "invalid request\n")
    end
  end

  defp extract_id(line) do
    case Regex.run(~r/"id"\s*:\s*([1-9][0-9]*)/, line, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      _missing -> nil
    end
  end

  defp extract_method(line) do
    case Regex.run(~r/"method"\s*:\s*"([^"]+)"/, line, capture: :all_but_first) do
      [method] -> method
      _missing -> nil
    end
  end

  defp extract_progress_token(line) do
    case Regex.run(~r/"progressToken"\s*:\s*([1-9][0-9]*)/, line, capture: :all_but_first) do
      [token] -> String.to_integer(token)
      _missing -> nil
    end
  end

  defp emit_notifications(id, method, line) do
    token = extract_progress_token(line)
    count = if method == "notify", do: 1, else: 4
    padding = if method == "notify", do: "", else: String.duplicate("x", 64)

    for progress <- 1..count do
      IO.write(
        :stdio,
        ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"padding":"#{padding}","progress":#{progress},"progressToken":#{token}}}\n)
      )
    end

    respond(id, method)
  end

  defp respond_after(id, method, delay_ms) do
    Task.start(fn ->
      receive do
      after
        delay_ms -> respond(id, method)
      end
    end)
  end

  defp respond(id, method, padding \\ "") do
    IO.write(:stdio, [response_body(id, method, padding), "\n"])
  end

  defp response_body(id, method, padding),
    do: ~s({"jsonrpc":"2.0","id":#{id},"result":{"method":"#{method}","padding":"#{padding}"}})
end

PtcRunner.TestSupport.MCPStdioFixture.main(System.argv())
