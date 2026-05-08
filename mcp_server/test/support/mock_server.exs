#!/usr/bin/env elixir
#
# Minimal MCP server fixture used by Phase 1b stdio tests.
# Spec: `Plans/ptc-runner-mcp-aggregator.md` §6.3 / §12.3.2.
#
# Speaks NDJSON JSON-RPC 2.0 on stdin/stdout. Behavior is driven
# by environment variables so tests can simulate the full matrix
# of upstream conditions:
#
#   MOCK_INIT_FAIL=1                 — `initialize` replies with a JSON-RPC error.
#   MOCK_LIST_FAIL=1                 — `tools/list` replies with a JSON-RPC error.
#   MOCK_REQUIRE_INITIALIZED=1       — reject any `tools/call` until
#                                      `notifications/initialized` is received.
#   MOCK_TOOL_DELAY_MS=<ms>          — delay every `tools/call` reply by N ms.
#   MOCK_TOOL_ERROR=<json-rpc-msg>   — `tools/call` replies with a JSON-RPC
#                                      error carrying that message.
#   MOCK_TOOL_RESULT=<json>          — `tools/call` replies with this JSON
#                                      as `result` (default: echoes args).
#   MOCK_OVERSIZED_RESPONSE=<bytes>  — `tools/call` returns a string of
#                                      length N inside `result`, exercising
#                                      the size-cap path.
#   MOCK_CRASH_ON_CALL=1             — exit(1) on the first `tools/call`.
#   MOCK_CRASH_DELAY_MS=<ms>         — delay before the crash so the
#                                      test can observe an in-flight call.

defmodule MockServer do
  def main(argv) do
    write_probe(argv)
    loop()
  end

  # Optional side-channel for tests asserting that args/env from a
  # JSON config faithfully reach the subprocess. When MOCK_PROBE_PATH
  # is set, drop a JSON record of the received argv + MOCK_-prefixed
  # env vars at startup. Used by the [P1] regression test in
  # `application_phase1b_test.exs`.
  defp write_probe(argv) do
    case System.get_env("MOCK_PROBE_PATH") do
      nil ->
        :ok

      "" ->
        :ok

      path ->
        env =
          System.get_env()
          |> Enum.filter(fn {k, _} -> String.starts_with?(k, "MOCK_") end)
          |> Enum.into(%{})

        record = %{
          "argv" => argv,
          "env" => env
        }

        File.write!(path, Jason.encode!(record))
    end
  end

  defp loop do
    case IO.read(:stdio, :line) do
      :eof ->
        # stdin closed → graceful shutdown (§4.3 Stdio shutdown via stdin EOF).
        :ok

      {:error, _reason} ->
        :ok

      line when is_binary(line) ->
        line = String.trim_trailing(line, "\n")

        if line == "" do
          loop()
        else
          handle_line(line)
          loop()
        end
    end
  end

  defp handle_line(line) do
    case Jason.decode(line) do
      {:ok, frame} ->
        handle_frame(frame)

      {:error, _} ->
        # Drop malformed input — the real upstream would too.
        :ok
    end
  end

  defp handle_frame(%{"method" => "initialize", "id" => id}) do
    if env_flag?("MOCK_INIT_FAIL") do
      send_error(id, -32_603, "mock initialize failure")
    else
      # Optional handshake-delay knob used by the codex [P2] #3
      # regression test (parent EXIT mid-handshake). The mock
      # blocks the `initialize` reply by `:timer.sleep`, so the
      # client (Stdio) sits in `wait_for_id/3` long enough for
      # the test to fire `Process.exit(parent, :shutdown)`.
      delay_ms = parse_int_env("MOCK_INIT_DELAY_MS", 0)
      if delay_ms > 0, do: :timer.sleep(delay_ms)

      send_result(id, %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "serverInfo" => %{
          "name" => "mock-mcp-server",
          "version" => "0.1.0"
        }
      })
    end
  end

  defp handle_frame(%{"method" => "notifications/initialized"}) do
    Process.put(:initialized?, true)
    :ok
  end

  defp handle_frame(%{"method" => "tools/list", "id" => id}) do
    if env_flag?("MOCK_LIST_FAIL") do
      send_error(id, -32_603, "mock tools/list failure")
    else
      send_result(id, %{
        "tools" => [
          %{
            "name" => "echo",
            "description" => "echoes its args",
            "inputSchema" => %{"type" => "object"}
          },
          %{
            "name" => "slow",
            "inputSchema" => %{"type" => "object"}
          },
          %{
            "name" => "big",
            "inputSchema" => %{"type" => "object"}
          }
        ]
      })
    end
  end

  defp handle_frame(%{"method" => "tools/call", "id" => id, "params" => params}) do
    cond do
      env_flag?("MOCK_REQUIRE_INITIALIZED") and not Process.get(:initialized?, false) ->
        send_error(id, -32_600, "tools/call before notifications/initialized")

      env_flag?("MOCK_CRASH_ON_CALL") ->
        delay_ms = parse_int_env("MOCK_CRASH_DELAY_MS", 0)
        if delay_ms > 0, do: :timer.sleep(delay_ms)
        System.halt(1)

      true ->
        delay_ms = parse_int_env("MOCK_TOOL_DELAY_MS", 0)
        if delay_ms > 0, do: :timer.sleep(delay_ms)

        case System.get_env("MOCK_TOOL_ERROR") do
          msg when is_binary(msg) and msg != "" ->
            send_error(id, -32_000, msg)

          _ ->
            handle_tool_call(id, params)
        end
    end
  end

  defp handle_frame(%{"id" => id, "method" => _other}) do
    send_error(id, -32_601, "method not found")
  end

  defp handle_frame(_other), do: :ok

  defp handle_tool_call(id, params) do
    cond do
      (bytes = parse_int_env("MOCK_OVERSIZED_RESPONSE", 0)) > 0 ->
        big = String.duplicate("x", bytes)
        send_result(id, %{"content" => [%{"type" => "text", "text" => big}]})

      (raw = System.get_env("MOCK_TOOL_RESULT")) != nil and raw != "" ->
        case Jason.decode(raw) do
          {:ok, value} -> send_result(id, value)
          {:error, _} -> send_result(id, raw)
        end

      true ->
        # Default: echo the args back.
        args = Map.get(params, "arguments", %{})

        send_result(id, %{
          "content" => [%{"type" => "text", "text" => Jason.encode!(args)}],
          "structuredContent" => args,
          "isError" => false
        })
    end
  end

  defp send_result(id, result) do
    write_frame(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp send_error(id, code, message) do
    write_frame(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp write_frame(frame) do
    line = Jason.encode!(frame)

    try do
      IO.write(:stdio, line <> "\n")
    rescue
      # The parent closed our stdout (e.g. graceful shutdown via
      # stdin EOF or a transient call timeout that drained the
      # caller). Treat as silent EOF.
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp env_flag?(name) do
    case System.get_env(name) do
      nil -> false
      "" -> false
      "0" -> false
      _ -> true
    end
  end

  defp parse_int_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {n, _} -> n
          _ -> default
        end
    end
  end
end

MockServer.main(System.argv())
