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

  def main([marker, "mcp-unicode"]) do
    marker
    |> mcp_loop()
    |> System.halt()
  end

  defp mcp_loop(marker) do
    case IO.read(:stdio, :line) do
      :eof ->
        0

      {:error, _reason} ->
        1

      line when is_binary(line) ->
        handle_mcp_request(extract_id(line), extract_method(line), marker)
        mcp_loop(marker)
    end
  end

  defp handle_mcp_request(id, "server/discover", marker) when is_integer(id) do
    File.write!(marker, "server/discover\n", [:append])

    IO.write(
      :stdio,
      ~s({"jsonrpc":"2.0","id":#{id},"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"unicode-fixture","version":"1.0"}},"ttlMs":0,"cacheScope":"private"}}\n)
    )
  end

  defp handle_mcp_request(id, "tools/list", marker) when is_integer(id) do
    File.write!(marker, "tools/list\n", [:append])

    IO.write(
      :stdio,
      ~s({"jsonrpc":"2.0","id":#{id},"result":{"resultType":"complete","tools":[{"name":"unicode","description":"Return non-ASCII text.","inputSchema":{"type":"object","properties":{}}}],"ttlMs":0,"cacheScope":"private"}}\n)
    )
  end

  defp handle_mcp_request(id, "tools/call", marker) when is_integer(id) do
    File.write!(marker, "tools/call\n", [:append])

    IO.write(
      :stdio,
      ~s({"jsonrpc":"2.0","id":#{id},"result":{"resultType":"complete","content":[{"type":"text","text":"behaviour — correct"}]}}\n)
    )
  end

  defp handle_mcp_request(_id, _method, _marker), do: System.halt(65)

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
    handle_request(extract_id(line), extract_method(line), line, marker)
  end

  defp handle_request(nil, "notifications/cancelled", line, marker),
    do: File.write!(marker, line, [:append])

  defp handle_request(id, "slow", _line, _marker) when is_integer(id),
    do: respond_after(id, "slow", 75)

  defp handle_request(id, "fast", _line, _marker) when is_integer(id),
    do: respond_after(id, "fast", 5)

  defp handle_request(id, "never", _line, _marker) when is_integer(id), do: :ok

  defp handle_request(id, "junk", _line, _marker) when is_integer(id),
    do: IO.write(:stdio, "not-json\n")

  defp handle_request(id, "large", _line, _marker) when is_integer(id),
    do: respond(id, "large", String.duplicate("x", 2_048))

  defp handle_request(id, "exact", _line, _marker) when is_integer(id) do
    body = response_body(id, "exact", "")
    respond(id, "exact", String.duplicate("x", 1_048_576 - byte_size(body)))
  end

  defp handle_request(id, "exact-crlf", _line, _marker) when is_integer(id) do
    body = response_body(id, "exact-crlf", "")
    padding = String.duplicate("x", 1_048_576 - byte_size(body))
    IO.write(:stdio, [response_body(id, "exact-crlf", padding), "\r\n"])
  end

  defp handle_request(id, method, line, _marker)
       when is_integer(id) and method in ["notify", "notify-flood"],
       do: emit_notifications(id, method, line)

  defp handle_request(id, "unscoped-notify", _line, _marker) when is_integer(id) do
    padding = String.duplicate("x", 600_000)

    IO.write(
      :stdio,
      ~s({"jsonrpc":"2.0","method":"notifications/message","params":{"data":"#{padding}"}}\n)
    )

    respond(id, "unscoped-notify")
  end

  defp handle_request(id, "stale-response", _line, _marker)
       when is_integer(id) and id > 1 do
    respond(id - 1, "late")
    respond(id, "stale-response")
  end

  defp handle_request(id, "stale-reset-flood", _line, _marker)
       when is_integer(id) and id > 1 do
    emit_unscoped_notifications(3)
    respond(id - 1, "late")
    emit_unscoped_notifications(1)
    respond(id, "stale-reset-flood")
  end

  defp handle_request(id, "stale-response-flood", _line, _marker)
       when is_integer(id) and id > 1 do
    padding = String.duplicate("x", 600_000)

    for _response <- 1..4 do
      respond(id - 1, "late", padding)
    end

    respond(id, "stale-response-flood")
  end

  defp handle_request(id, "stderr-echo", _line, _marker) when is_integer(id) do
    IO.write(:stderr, "child diagnostic\n")
    respond(id, "stderr-echo")
  end

  defp handle_request(id, method, _line, _marker)
       when is_integer(id) and is_binary(method),
       do: respond(id, method)

  defp handle_request(_id, _method, _line, _marker),
    do: IO.write(:stdio, "invalid request\n")

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

  defp emit_unscoped_notifications(count) do
    padding = String.duplicate("x", 600_000)

    for _notification <- 1..count do
      IO.write(
        :stdio,
        ~s({"jsonrpc":"2.0","method":"notifications/message","params":{"data":"#{padding}"}}\n)
      )
    end
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
