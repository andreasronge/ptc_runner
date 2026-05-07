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

  alias PtcRunnerMcp.{Lifecycle, Log, Tools, TraceFile, TracePayload, Version}

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
    notification? = not Map.has_key?(frame, "id")

    result =
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

    suppress_reply_if_notification(result, notification?)
  rescue
    error ->
      stack = __STACKTRACE__
      id = Map.get(frame, "id")

      Log.log(:error, "handler_crash", %{
        request_id: id,
        kind: error.__struct__ |> inspect(),
        message: Exception.message(error),
        stacktrace: Exception.format_stacktrace(stack)
      })

      # Notifications (no `id` member, per JSON-RPC 2.0) must NEVER
      # receive a reply, including error replies on internal crashes.
      if Map.has_key?(frame, "id") do
        {:reply, error_reply(id, -32_603, "Internal error"), :continue}
      else
        {:noreply, :continue}
      end
  end

  defp handle(_other) do
    {:reply, error_reply(nil, -32_600, "Invalid Request"), :continue}
  end

  # JSON-RPC 2.0 § 4.1: a Notification is a Request without an `id` member;
  # the Server MUST NOT reply to it. Drop any handler-built reply when the
  # incoming frame is a notification, but preserve the lifecycle directive
  # so legitimate notifications (e.g. `exit`) still take effect.
  defp suppress_reply_if_notification({:reply, _frame, lifecycle}, true) do
    {:noreply, lifecycle}
  end

  defp suppress_reply_if_notification(other, _), do: other

  defp handle_tools_call(id, params) when is_map(params) do
    Log.log(:info, "tools_call_start", %{
      request_id: id,
      tool: Map.get(params, "name")
    })

    envelope = traced_tools_call(id, params)

    Log.log(:info, "tools_call_stop", %{
      request_id: id,
      is_error: Map.get(envelope, "isError")
    })

    {:reply, success_reply(id, envelope), :continue}
  end

  defp handle_tools_call(id, _) do
    {:reply, error_reply(id, -32_602, "Invalid params"), :continue}
  end

  # Wrap the `Tools.call/1` invocation in:
  #
  #   1. `PtcRunnerMcp.TraceFile.with_traced_call/4` — opens a JSONL
  #      trace file under `--trace-dir` (no-op when tracing is off).
  #   2. `:telemetry.span([:ptc_runner_mcp, :call], ...)` — emits the
  #      MCP-level start/stop/exception events from § 6.7. These events
  #      fire whether or not tracing is enabled (they're useful for any
  #      subscriber).
  #
  # `:telemetry.span` is INSIDE the trace wrapper so the events land in
  # the active collector; the Lisp execute span (already inside
  # `Lisp.run/2`) lands too.
  defp traced_tools_call(request_id, params) do
    payload_level = PtcRunnerMcp.TraceConfig.trace_payloads()
    args = extract_arguments(params)
    program = Map.get(args, "program")

    query =
      if is_binary(program) do
        TracePayload.redact_program(program, payload_level)
      end

    query_str =
      case query do
        nil -> ""
        s when is_binary(s) -> s
        other -> Jason.encode!(other)
      end

    TraceFile.with_traced_call(request_id, query_str, [], fn ->
      span_meta = call_start_meta(request_id, params, args)

      :telemetry.span([:ptc_runner_mcp, :call], span_meta, fn ->
        envelope = Tools.call(params)
        stop_meta = call_stop_meta(span_meta, envelope)
        {envelope, stop_meta}
      end)
    end)
  end

  # The `tools/call` outer params shape:
  #   %{"name" => "...", "arguments" => %{...}}
  # Tracing reads `program` / `context` / `signature` from the inner
  # arguments map (NOT the outer params).
  defp extract_arguments(%{"arguments" => args}) when is_map(args), do: args
  defp extract_arguments(_), do: %{}

  defp call_start_meta(request_id, params, args) do
    program = Map.get(args, "program")
    context = Map.get(args, "context")

    program_bytes = if is_binary(program), do: byte_size(program), else: 0

    context_bytes =
      case context do
        m when is_map(m) ->
          case Jason.encode(m) do
            {:ok, json} -> byte_size(json)
            _ -> 0
          end

        _ ->
          0
      end

    # § 6.7 telemetry table: only counts and presence flags. Raw
    # `program` / `context` MUST NOT appear in telemetry metadata —
    # any third-party subscriber would bypass `--trace-payloads`.
    # The redacted program preview lives on the trace.start header's
    # `query` field, not here.
    %{
      request_id: to_string(request_id || ""),
      tool_name: Map.get(params, "name"),
      program_bytes: program_bytes,
      context_bytes: context_bytes,
      signature_present?: Map.has_key?(args, "signature") and not is_nil(args["signature"]),
      protocol_version: Version.negotiated()
    }
  end

  defp call_stop_meta(start_meta, envelope) do
    is_error = Map.get(envelope, "isError", false) == true
    sc = Map.get(envelope, "structuredContent", %{})

    {status, reason} =
      case sc do
        %{"status" => "ok"} -> {:ok, nil}
        %{"status" => "error", "reason" => r} -> {:error, r}
        _ -> {if(is_error, do: :error, else: :ok), nil}
      end

    # § 6.7 telemetry table: only `validated_present?` (boolean), not
    # the full `validated` value or `prints`. Same payload-policy
    # bypass concern as call_start_meta — third-party subscribers
    # MUST NOT receive raw user content via telemetry.
    base = %{
      request_id: start_meta.request_id,
      tool_name: start_meta.tool_name,
      protocol_version: start_meta.protocol_version,
      status: status,
      is_error: is_error,
      validated_present?: Map.has_key?(sc, "validated")
    }

    case reason do
      nil -> base
      r -> Map.put(base, :reason, r)
    end
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
