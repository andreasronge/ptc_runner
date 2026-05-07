defmodule PtcRunnerMcp.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 dispatcher for the MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 6.4 and § 7, this module
  takes a parsed JSON value (or a parse-error tag) and returns either:

    * `{:reply, response_map, lifecycle}` — the caller writes the
      response to stdout and applies the lifecycle directive.
    * `{:noreply, lifecycle}` — for notifications (no `id` in the
      request) and for `exit`.

  Lifecycle directives:

    * `:continue` — keep serving.
    * `:drain` — `shutdown` received; reply, but stop accepting new
      `tools/call` work.
    * `:exit` — `exit` notification received; the caller terminates.

  Phase 1 has no concept of in-flight calls, so `:drain` and `:exit`
  are equivalent at this layer. Phase 4 expands them.
  """

  alias PtcRunnerMcp.{Lifecycle, Log, Tools}

  @typedoc "Lifecycle directive returned alongside any dispatch result."
  @type lifecycle :: :continue | :drain | :exit

  @typedoc "Dispatch outcome."
  @type result :: {:reply, map(), lifecycle()} | {:noreply, lifecycle()}

  @doc """
  Dispatch a single decoded JSON value (or a parse-error tag).

  Inputs:

    * `{:ok, value}` — a successfully parsed JSON value.
    * `{:error, :parse_error}` — the line wasn't valid JSON or
      exceeded `max_frame_bytes`.
  """
  @spec dispatch({:ok, term()} | {:error, :parse_error}) :: result()
  def dispatch({:error, :parse_error}) do
    {:reply, parse_error_reply(), :continue}
  end

  def dispatch({:ok, frame}) when is_map(frame) do
    handle(frame)
  end

  def dispatch({:ok, _other}) do
    # JSON-RPC 2.0 batch requests (arrays) and bare JSON values are
    # invalid for this server.
    {:reply, error_reply(nil, -32_600, "Invalid Request"), :continue}
  end

  # ----------------------------------------------------------------
  # Per-method handling
  # ----------------------------------------------------------------

  defp handle(%{"jsonrpc" => "2.0", "method" => method} = frame) do
    id = Map.get(frame, "id")
    params = Map.get(frame, "params")

    case method do
      "initialize" ->
        Log.log(:info, "initialize", %{request_id: id})
        {:reply, success_reply(id, Lifecycle.initialize_reply(params)), :continue}

      "notifications/initialized" ->
        Lifecycle.on_initialized()
        {:noreply, :continue}

      "shutdown" ->
        Log.log(:info, "shutdown", %{request_id: id})
        {:reply, success_reply(id, nil), :drain}

      "exit" ->
        Log.log(:info, "exit")
        {:noreply, :exit}

      "notifications/cancelled" ->
        Lifecycle.on_cancelled(params || %{})
        {:noreply, :continue}

      "tools/list" ->
        Log.log(:debug, "tools_list", %{request_id: id})
        {:reply, success_reply(id, Tools.list()), :continue}

      "tools/call" ->
        handle_tools_call(id, params)

      _ ->
        Log.log(:warn, "method_not_found", %{request_id: id, method: method})
        {:reply, error_reply(id, -32_601, "Method not found"), :continue}
    end
  rescue
    error ->
      stack = __STACKTRACE__

      Log.log(:error, "handler_crash", %{
        request_id: Map.get(frame, "id"),
        kind: error.__struct__ |> inspect(),
        message: Exception.message(error),
        stacktrace: Exception.format_stacktrace(stack)
      })

      {:reply, error_reply(Map.get(frame, "id"), -32_603, "Internal error"), :continue}
  end

  defp handle(_other) do
    {:reply, error_reply(nil, -32_600, "Invalid Request"), :continue}
  end

  defp handle_tools_call(id, params) when is_map(params) do
    Log.log(:info, "tools_call_start", %{
      request_id: id,
      tool: Map.get(params, "name")
    })

    envelope = Tools.call(params)

    Log.log(:info, "tools_call_stop", %{
      request_id: id,
      is_error: Map.get(envelope, "isError")
    })

    {:reply, success_reply(id, envelope), :continue}
  end

  defp handle_tools_call(id, _) do
    {:reply, error_reply(id, -32_602, "Invalid params"), :continue}
  end

  # ----------------------------------------------------------------
  # Reply helpers
  # ----------------------------------------------------------------

  defp success_reply(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_reply(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end

  defp parse_error_reply do
    error_reply(nil, -32_700, "Parse error")
  end
end
