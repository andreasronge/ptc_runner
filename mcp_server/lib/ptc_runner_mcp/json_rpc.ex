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

  Phase 4 introduces three new outcomes:

    * `{:async_call, request_id, work_fn, on_busy, on_discard, lifecycle}` —
      `tools/call` that has passed argument validation and is ready to
      execute in a per-call worker. The caller (`PtcRunnerMcp.Stdio`)
      acquires a concurrency permit, spawns the worker to run
      `work_fn.()`, and writes the resulting envelope wrapped in
      `success_reply/2`. Permit ownership stays with the caller
      (release-on-DOWN). When the caller is at its concurrency cap it
      writes a `busy` envelope instead and invokes `on_busy.(envelope)`
      — a 1-arity callback that records the rejected call into the
      `ptc_debug` ring (no-op when the debug tool is disabled).
    * `{:cancel, request_id, lifecycle}` — `notifications/cancelled`
      with a `requestId`. The caller looks up the worker pid in its
      in-flight table; hits kill it (no reply emitted), misses are
      silently ignored (§ 6.4 row 4).
    * `{:reply_drain, frame, lifecycle}` — `tools/call` rejected
      because the server is in `:drain` state (§ 6.4 row 2). The
      caller writes the rejection envelope as a normal reply but
      stays in drain.
  """

  alias PtcRunnerMcp.{
    DebugConfig,
    DebugRecorder,
    DebugTool,
    Envelope,
    Lifecycle,
    Log,
    Sessions,
    Tools,
    TraceFile,
    TracePayload,
    Version
  }

  @typedoc "Lifecycle directive returned alongside any dispatch result."
  @type lifecycle :: :continue | :drain | :exit

  @typedoc "Dispatch outcome."
  @type result ::
          {:reply, map(), lifecycle()}
          | {:noreply, lifecycle()}
          | {:async_call, term(), (-> map()), (map() -> any()), (-> any()), lifecycle()}
          | {:cancel, term(), lifecycle()}

  @doc """
  Dispatch a single decoded JSON value (or a parse-error tag).

  Inputs:

    * `{:ok, value}` — a successfully parsed JSON value.
    * `{:error, :parse_error}` — the line wasn't valid JSON or
      exceeded `max_frame_bytes`.
  """
  @spec dispatch({:ok, term()} | {:error, :parse_error}, keyword()) :: result()
  def dispatch(input, opts \\ [])

  def dispatch({:error, :parse_error}, _opts) do
    {:reply, parse_error_reply(), :continue}
  end

  def dispatch({:ok, frame}, opts) when is_map(frame) do
    handle(frame, opts)
  end

  def dispatch({:ok, _other}, _opts) do
    # JSON-RPC 2.0 batch requests (arrays) and bare JSON values are
    # invalid for this server.
    {:reply, error_reply(nil, -32_600, "Invalid Request"), :continue}
  end

  # ----------------------------------------------------------------
  # Per-method handling
  # ----------------------------------------------------------------

  defp handle(%{"jsonrpc" => "2.0", "method" => method} = frame, opts) do
    id = Map.get(frame, "id")
    params = Map.get(frame, "params")
    notification? = not Map.has_key?(frame, "id")
    draining? = Keyword.get(opts, :draining, false)

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
          handle_cancelled(params)

        "tools/list" ->
          Log.log(:debug, "tools_list", %{request_id: id})
          {:reply, success_reply(id, Tools.list()), :continue}

        "tools/call" ->
          handle_tools_call(id, params, draining?)

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

  defp handle(_other, _opts) do
    {:reply, error_reply(nil, -32_600, "Invalid Request"), :continue}
  end

  # § 6.4 row 3: `notifications/cancelled` for an in-flight requestId
  # signals stdio to kill that worker and emit no response. § 6.4
  # row 4: missing/unknown ids are silently ignored. The lookup
  # against the in-flight table happens in `Stdio.handle_cast/2` —
  # we just package the requestId here.
  defp handle_cancelled(%{"requestId" => req_id}) when not is_nil(req_id) do
    Log.log(:debug, "notifications_cancelled", %{request_id: req_id})
    Lifecycle.on_cancelled(%{"requestId" => req_id})
    {:cancel, req_id, :continue}
  end

  defp handle_cancelled(params) do
    # Missing or null requestId: silent ignore per § 6.4 row 4.
    Lifecycle.on_cancelled(params || %{})
    {:noreply, :continue}
  end

  # JSON-RPC 2.0 § 4.1: a Notification is a Request without an `id` member;
  # the Server MUST NOT reply to it. Drop any handler-built reply when the
  # incoming frame is a notification, but preserve the lifecycle directive
  # so legitimate notifications (e.g. `exit`) still take effect.
  defp suppress_reply_if_notification({:reply, _frame, lifecycle}, true) do
    {:noreply, lifecycle}
  end

  # `tools/call` sent as a notification is malformed but tolerated:
  # no reply, no worker spawn — discard the work_fn / on_busy.
  defp suppress_reply_if_notification(
         {:async_call, _id, _work_fn, _on_busy, on_discard, lifecycle},
         true
       ) do
    safe_invoke(on_discard)
    {:noreply, lifecycle}
  end

  defp suppress_reply_if_notification(other, _), do: other

  defp handle_tools_call(id, params, draining?) when is_map(params) do
    Log.log(:info, "tools_call_start", %{
      request_id: id,
      tool: Map.get(params, "name")
    })

    cond do
      draining? ->
        # § 6.4 row 2: after `shutdown`, reject new tools/call requests.
        # We surface this as an MCP-only `shutting_down` envelope (parallel
        # to `:busy` and `:unknown_tool`) rather than widening
        # `PtcToolProtocol.error_reason()` or returning a transport-level
        # `-32600` (which would conflate transport vs application errors).
        envelope = Envelope.shutting_down()

        Log.log(:info, "tools_call_rejected_shutting_down", %{request_id: id})

        {:reply, success_reply(id, envelope), :drain}

      DebugConfig.enabled?() and Map.get(params, "name") == DebugTool.tool_name() ->
        # `ptc_debug` (only when `--debug-tool` is set): handled synchronously,
        # NO concurrency permit, NOT through the async `Tools.call/1` path, and
        # NEVER written to the ring (no self-noise, no recursion). When
        # `--debug-tool` is *off*, `ptc_debug` is just an unknown tool and
        # falls through to the generic unknown-tool branch below — so it gets
        # the same trace/telemetry treatment as any other unknown tool name.
        envelope = DebugTool.call(params, success_frame_overhead(id))

        Log.log(:info, "tools_call_stop", %{
          request_id: id,
          is_error: Map.get(envelope, "isError")
        })

        {:reply, success_reply(id, envelope), :continue}

      not known_tool_name?(Map.get(params, "name")) ->
        # Unknown tool: handled synchronously (no Lisp execution, no
        # gate). We still trace + emit `[:ptc_runner_mcp, :call, :*]`
        # so subscribers see the call regardless of outcome.
        envelope = traced_tools_call(id, params, fn -> Tools.call(params) end)

        Log.log(:info, "tools_call_stop", %{
          request_id: id,
          is_error: Map.get(envelope, "isError")
        })

        {:reply, success_reply(id, envelope), :continue}

      Sessions.tool_name?(Map.get(params, "name")) and
          not Sessions.async_tool_name?(Map.get(params, "name")) ->
        envelope =
          traced_tools_call(id, params, fn ->
            Tools.call(params)
          end)

        Log.log(:info, "tools_call_stop", %{
          request_id: id,
          is_error: Map.get(envelope, "isError")
        })

        DebugRecorder.record_outcome(id, params, envelope, duration_ms: 0)

        {:reply, success_reply(id, envelope), :continue}

      true ->
        async_tools_call(id, params)
    end
  end

  defp handle_tools_call(id, _, _draining?) do
    {:reply, error_reply(id, -32_602, "Invalid params"), :continue}
  end

  # Validate the inner `arguments` synchronously, then return either:
  #
  #   * `{:reply, ..., :continue}` — args_error envelope, no worker
  #     spawn. The args_error is recorded into the `ptc_debug` ring
  #     here (it's a recognized-tool outcome — § 5.1).
  #   * `{:async_call, request_id, work_fn, on_busy, :continue}` —
  #     work_fn closes over the validated tuple and the raw params (for
  #     tracing metadata + the post-execution ring record); on_busy is
  #     a 1-arity callback Stdio invokes (passing the `busy` envelope it
  #     built) when it rejects the call at the concurrency cap, so that
  #     rejection is also recorded. Stdio acquires the permit, spawns a
  #     worker that runs work_fn(), and replies with the resulting
  #     envelope.
  #
  # The `ptc_debug` ring records (success / args_error / busy) are
  # built via `DebugRecorder.record_outcome/4`, which no-ops when
  # `--debug-tool` is disabled and swallows + `warn`-logs any failure
  # — it can never affect the response.
  defp async_tools_call(id, params) do
    args = extract_arguments(params)

    case validate_tool_args(params, args) do
      {:error, args_error_envelope} ->
        Log.log(:info, "tools_call_stop", %{
          request_id: id,
          is_error: true
        })

        DebugRecorder.record_outcome(id, params, args_error_envelope, duration_ms: 0)

        {:reply, success_reply(id, args_error_envelope), :continue}

      {:ok, :ptc_lisp_execute, {program, context, parsed_signature}} ->
        work_fn =
          recorded_work_fn(id, params, fn ->
            traced_tools_call(id, params, fn ->
              # Phase 1a §10: thread the JSON-RPC request id into
              # `Tools.call_validated/4` so the
              # `[:ptc_runner_mcp, :upstream, :call, :*]` telemetry
              # metadata can correlate upstream calls back to the
              # parent `tools/call` request.
              Tools.call_validated(program, context, parsed_signature, request_id: id)
            end)
          end)

        {:async_call, id, work_fn, busy_record_fn(id, params), noop_fn(), :continue}

      {:ok, :ptc_task, validated} ->
        work_fn =
          recorded_work_fn(id, params, fn ->
            traced_tools_call(id, params, fn ->
              Tools.call_agentic_validated(validated, request_id: id)
            end)
          end)

        {:async_call, id, work_fn, busy_record_fn(id, params), noop_fn(), :continue}

      {:ok, :ptc_session_eval, validated} ->
        work_fn =
          recorded_work_fn(id, params, fn ->
            traced_tools_call(id, params, fn ->
              Tools.call_session_eval_reserved(validated, request_id: id)
            end)
          end)

        on_discard = fn ->
          _ = Tools.abort_session_eval_reserved(validated, :discarded)
        end

        on_busy = fn busy_envelope ->
          _ = Tools.abort_session_eval_reserved(validated, :global_busy)
          DebugRecorder.record_outcome(id, params, busy_envelope, duration_ms: 0)
        end

        {:async_call, id, work_fn, on_busy, on_discard, :continue}
    end
  end

  # Wrap an executing closure so that after it produces the envelope we
  # record the call into the `ptc_debug` ring with the measured
  # duration. The recorder itself is fault-isolated; this wrapper adds
  # the timing only.
  defp recorded_work_fn(id, params, run_fn) when is_function(run_fn, 0) do
    fn ->
      started = System.monotonic_time(:millisecond)
      envelope = run_fn.()
      duration_ms = max(System.monotonic_time(:millisecond) - started, 0)
      DebugRecorder.record_outcome(id, params, envelope, duration_ms: duration_ms)
      strip_private_result(envelope)
    end
  end

  # 1-arity callback Stdio runs (passing the `busy` envelope it built)
  # when it rejects this call at the concurrency cap.
  defp busy_record_fn(id, params) do
    fn busy_envelope ->
      DebugRecorder.record_outcome(id, params, busy_envelope, duration_ms: 0)
    end
  end

  defp noop_fn, do: fn -> :ok end

  defp safe_invoke(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp validate_tool_args(%{"name" => "ptc_lisp_execute"}, args) do
    case Tools.validate(args) do
      {:ok, program, context, parsed_signature} ->
        {:ok, :ptc_lisp_execute, {program, context, parsed_signature}}

      {:error, envelope} ->
        {:error, envelope}
    end
  end

  defp validate_tool_args(%{"name" => "ptc_task"}, args) do
    if Tools.agentic_advertised?() do
      case PtcRunnerMcp.Agentic.validate(args) do
        {:ok, validated} -> {:ok, :ptc_task, validated}
        {:error, envelope} -> {:error, envelope}
      end
    else
      {:error, Envelope.unknown_tool("ptc_task")}
    end
  end

  defp validate_tool_args(%{"name" => "ptc_session_eval"}, args) do
    case Tools.validate_session_eval(args) do
      {:ok, validated} ->
        case Sessions.reserve_eval(validated, make_ref()) do
          {:ok, reservation} -> {:ok, :ptc_session_eval, reservation}
          {:error, response} -> {:error, Envelope.error_envelope(response)}
        end

      {:error, envelope} ->
        {:error, envelope}
    end
  end

  defp known_tool_name?(name) when name in ["ptc_lisp_execute", "ptc_task"], do: true
  defp known_tool_name?(name) when is_binary(name), do: Sessions.tool_name?(name)
  defp known_tool_name?(_), do: false

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
  @doc """
  Wrap the actual tools-call execution (`run_fn`) in tracing and
  telemetry. Public for `Stdio` workers; called inside the worker
  process so the per-process trace collector and the
  `[:ptc_runner_mcp, :call, :*]` span both land on the right pid.

  `run_fn` is a 0-arity function that returns the MCP envelope. In
  Phase 4 it's `fn -> Tools.call_validated(program, ctx, sig) end`;
  the gate is owned by `Stdio` outside this wrap.
  """
  @spec traced_tools_call(term(), map(), (-> map())) :: map()
  def traced_tools_call(request_id, params, run_fn) when is_function(run_fn, 0) do
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
        envelope = run_fn.()
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
    %{"jsonrpc" => "2.0", "id" => id, "result" => strip_private_result(result)}
  end

  defp strip_private_result(result) when is_map(result),
    do: Map.delete(result, "__ptc_debug_structured")

  defp strip_private_result(result), do: result

  # Bytes the JSON-RPC success frame adds *around* the `result` value, i.e.
  # `{"jsonrpc":"2.0","id":<id>,"result":<value>}` minus `<value>`. `ptc_debug`'s
  # `--max-debug-response-bytes` is a bound on the whole frame, so the
  # (client-chosen) `id` must count against it. Serialize with an empty-string
  # result placeholder and subtract its 2 bytes (`""`).
  defp success_frame_overhead(id) do
    case Jason.encode(success_reply(id, "")) do
      {:ok, json} -> max(byte_size(json) - 2, 0)
      _ -> 64
    end
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
