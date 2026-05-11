defmodule PtcRunnerMcp.DebugRecorder do
  @moduledoc """
  Builds redacted call records for `PtcRunnerMcp.DebugBuffer` from the
  raw `tools/call` params + the outcome MCP envelope.

  See `Plans/ptc-runner-mcp-debug-tool.md` § 5.1 / § 7 step 4. The
  recorder runs at the recognized-tool dispatch boundary for
  `ptc_lisp_execute` and `ptc_task` only — never `ptc_debug`. It is a
  side effect of serving the request: `record_outcome/4` swallows and
  `warn`-logs any failure so it can never affect the response.

  Redaction reuses `PtcRunnerMcp.TracePayload` (which itself runs
  `Credentials.Redactor.scrub/1` over every emitted string) at the
  active `--trace-payloads` level.
  """

  alias PtcRunnerMcp.{DebugConfig, Log, TraceConfig, TracePayload, Version}

  @recognized_tools ["ptc_lisp_execute", "ptc_task"]

  @doc """
  Build and record a call record for a recognized-tool `tools/call`.

  - `request_id` — the JSON-RPC request id.
  - `params` — the outer `tools/call` params map (`%{"name" => ...,
    "arguments" => %{...}}`).
  - `envelope` — the outcome MCP envelope (success, `args_error`, or
    `busy`).
  - `opts` — `:duration_ms` (defaults to 0).

  No-op when `--debug-tool` is disabled, when `params["name"]` is not a
  recognized tool, when the envelope is an `unknown_tool` rejection (a
  recognized name that is not currently advertised — § 5.1), or when
  anything raises. Always returns `:ok`.
  """
  @spec record_outcome(term(), map(), map(), keyword()) :: :ok
  def record_outcome(request_id, params, envelope, opts \\ []) do
    if DebugConfig.enabled?() and recognized?(params) and not unknown_tool?(envelope) do
      do_record(request_id, params, envelope, opts)
    end

    :ok
  rescue
    error ->
      Log.log(:warn, "debug_record_failed", %{
        request_id: request_id,
        kind: inspect(error.__struct__),
        message: Exception.message(error)
      })

      :ok
  catch
    kind, reason ->
      Log.log(:warn, "debug_record_failed", %{
        request_id: request_id,
        kind: inspect(kind),
        reason: inspect(reason)
      })

      :ok
  end

  @doc ~S(True iff `params["name"]` is `ptc_lisp_execute` or `ptc_task`.)
  @spec recognized?(map()) :: boolean()
  def recognized?(params) when is_map(params), do: Map.get(params, "name") in @recognized_tools
  def recognized?(_), do: false

  # An `unknown_tool` envelope means the request named a recognized
  # tool that is not currently advertised (e.g. `ptc_task` without
  # `--agentic`). Per § 5.1 those requests are NOT recorded — they
  # can't be attributed to a live tool.
  defp unknown_tool?(%{"structuredContent" => %{"reason" => "unknown_tool"}}), do: true
  defp unknown_tool?(_), do: false

  # ----------------------------------------------------------------
  # Internal
  # ----------------------------------------------------------------

  defp do_record(request_id, params, envelope, opts) do
    tool = Map.get(params, "name")
    args = extract_arguments(params)
    level = TraceConfig.trace_payloads()
    sc = Map.get(envelope, "structuredContent", %{})
    is_error = Map.get(envelope, "isError", false) == true
    {status, reason} = status_and_reason(sc, is_error)
    program = Map.get(args, "program")
    context = Map.get(args, "context")

    record = %{
      request_id: to_string(request_id || ""),
      ts: DateTime.utc_now(),
      tool: tool,
      status: status,
      is_error: is_error,
      reason: reason,
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      program: if(is_binary(program), do: TracePayload.redact_program(program, level)),
      context:
        if(is_map(context) and not is_struct(context),
          do: TracePayload.redact_context(context, level)
        ),
      result_bytes: result_bytes(sc),
      prints_count: prints_count(sc),
      signature_present?: Map.has_key?(args, "signature") and not is_nil(args["signature"]),
      protocol_version: protocol_version(),
      upstream_calls: redacted_upstream_calls(sc),
      agentic: if(tool == "ptc_task", do: agentic_block(sc, args))
    }

    PtcRunnerMcp.DebugBuffer.record(record)
    :ok
  end

  defp extract_arguments(%{"arguments" => args}) when is_map(args), do: args
  defp extract_arguments(_), do: %{}

  defp status_and_reason(sc, is_error) do
    case sc do
      %{"status" => "ok"} -> {:ok, nil}
      %{"status" => "error", "reason" => r} when is_binary(r) -> {:error, r}
      %{"status" => "error"} -> {:error, nil}
      _ -> {if(is_error, do: :error, else: :ok), nil}
    end
  end

  defp result_bytes(%{"result" => r}) when is_binary(r), do: byte_size(r)
  defp result_bytes(_), do: nil

  defp prints_count(%{"prints" => p}) when is_list(p), do: length(p)
  defp prints_count(_), do: nil

  # Keep only the structurally-scalar, non-secret-bearing fields of
  # each `upstream_calls[]` entry. `error` (a free-text detail string)
  # is already `Redactor.scrub/1`-ed at construction time
  # (`UpstreamCalls.error_entry/5` / `Ledger`), but we drop it here
  # anyway — `ptc_debug` surfaces *reasons*, not raw error text — to
  # keep the redaction surface minimal (spec § 8 "residual leakage").
  defp redacted_upstream_calls(sc) do
    case Map.get(sc, "upstream_calls") do
      list when is_list(list) ->
        Enum.map(list, fn entry ->
          %{
            "server" => Map.get(entry, "server"),
            "tool" => Map.get(entry, "tool"),
            "status" => Map.get(entry, "status"),
            "duration_ms" => Map.get(entry, "duration_ms"),
            "reason" => Map.get(entry, "reason")
          }
        end)

      _ ->
        []
    end
  end

  # Build the `agentic` sub-map for an executed `ptc_task` call from
  # the envelope's `planner` / `execution` fields. For validation-error
  # / `busy` records (no `planner`/`execution`), returns `nil`.
  defp agentic_block(sc, _args) do
    planner = Map.get(sc, "planner")
    execution = Map.get(sc, "execution")

    if is_map(planner) or is_map(execution) do
      planner = planner || %{}
      execution = execution || %{}
      turn_count = int_or_nil(Map.get(execution, "turn_count"))
      planner_calls = int_or_nil(Map.get(planner, "calls"))
      program = Map.get(sc, "program")

      %{
        planner_status: if(Map.has_key?(planner, "error"), do: :error, else: :ok),
        # The planner's own latency lives in the `planner` meta map
        # (`Agentic.planner_payload/1`), not in `execution.duration_ms`
        # (which is the SubAgent execution wall-clock).
        planner_duration_ms: int_or_nil(Map.get(planner, "duration_ms")),
        planner_rejects: best_effort_rejects(planner_calls, turn_count),
        retries: best_effort_retries(turn_count),
        program_bytes: if(is_binary(program), do: byte_size(program))
      }
    end
  end

  # LLM calls beyond the per-turn baseline are best-effort proxied as
  # validation rejects / in-turn retries.
  defp best_effort_rejects(calls, turns) when is_integer(calls) and is_integer(turns),
    do: max(calls - turns, 0)

  defp best_effort_rejects(_calls, _turns), do: 0

  defp best_effort_retries(turns) when is_integer(turns) and turns > 0, do: turns - 1
  defp best_effort_retries(_turns), do: 0

  defp int_or_nil(v) when is_integer(v), do: v
  defp int_or_nil(_), do: nil

  defp protocol_version do
    Version.negotiated()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
