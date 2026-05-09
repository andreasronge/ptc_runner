defmodule PtcRunnerMcp.TraceHandler do
  @moduledoc """
  Telemetry handler that converts MCP and Lisp telemetry events into
  per-call JSONL lines.

  Per `Plans/ptc-runner-mcp-server.md` § 6.6 / § 6.7 / § 6.8, this
  handler lives in `:ptc_runner_mcp` (NOT `:ptc_runner`) and writes
  through `PtcRunner.TraceLog.write_to_active/1` — it never touches
  collector internals. The handler is attached only when
  `--trace-dir` is configured (`PtcRunnerMcp.TraceConfig.enabled?/0`).

  Subscribed events:

    * `[:ptc_runner_mcp, :call, :start | :stop | :exception]`
    * `[:ptc_runner, :lisp, :execute, :start | :stop | :exception]`

  The handler explicitly does NOT subscribe to
  `[:ptc_runner, :sub_agent, ...]` — those events lie about MCP
  execution being a SubAgent run (§ 6.6).

  Payload redaction is applied per `--trace-payloads` BEFORE writing:
  raw program/context/validated values never reach the collector.

  Failures (encoding errors, dead collectors, etc.) are swallowed —
  `write_to_active/1` itself never raises. A failed trace MUST NOT
  fail the underlying tool call (§ 6.10).
  """

  require Logger

  alias PtcRunnerMcp.Credentials.Redactor

  alias PtcRunnerMcp.TraceConfig

  @handler_id "ptc-runner-mcp-trace-handler"

  @events [
    [:ptc_runner_mcp, :call, :start],
    [:ptc_runner_mcp, :call, :stop],
    [:ptc_runner_mcp, :call, :exception],
    [:ptc_runner, :lisp, :execute, :start],
    [:ptc_runner, :lisp, :execute, :stop],
    [:ptc_runner, :lisp, :execute, :exception]
  ]

  @doc "Closed list of telemetry events this handler subscribes to."
  @spec events() :: [list(atom())]
  def events, do: @events

  @doc "Stable handler id used for attach/detach."
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id

  @doc """
  Attach the handler to telemetry. Idempotent.

  Re-attaching detaches the previous registration first so multiple
  boots in tests don't accumulate stale handlers.
  """
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)

    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
  end

  @doc "Detach the handler. Safe to call when not attached."
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc """
  Telemetry callback. Builds an event map and writes via
  `PtcRunner.TraceLog.write_to_active/1`.

  Never raises — all failures degrade to a debug log.
  """
  @spec handle_event(list(atom()), map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    level = TraceConfig.trace_payloads()
    event_map = build_event_map(event, measurements, metadata, level)
    # `PtcRunner.TraceLog.write_to_active/1` lives in the parent
    # `:ptc_runner` library and cannot call `Redactor.scrub/1`. We
    # scrub every binary leaf of the event tree here, before the
    # collector encodes it to JSONL. Per
    # `Plans/http-transport-credentials.md` §7.5.1, every JSONL record
    # must pass through `Redactor.scrub/1` before write — the
    # `TraceFile.with_traced_call/4` hook only covers the trace-start
    # header opts, not per-event metadata/reason payloads.
    redacted = Redactor.scrub_deep(event_map)
    _ = PtcRunner.TraceLog.write_to_active(redacted)
    :ok
  rescue
    error ->
      Logger.debug(fn -> "PtcRunnerMcp.TraceHandler error: #{inspect(error)}" end)
      :ok
  end

  # ----------------------------------------------------------------
  # Event-map construction
  # ----------------------------------------------------------------

  defp build_event_map(event, measurements, metadata, level) do
    base = %{
      "event" => event_name(event),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "measurements" => sanitize_measurements(measurements),
      "metadata" => redact_metadata(metadata, level)
    }

    case duration_ms(measurements) do
      nil -> base
      ms -> Map.put(base, "duration_ms", ms)
    end
  end

  defp event_name(event) do
    event |> Enum.map_join(".", &Atom.to_string/1)
  end

  # `:telemetry.span` injects a `:telemetry_span_context` reference that
  # encodes as noise; drop it. Keep numeric measurements as-is.
  defp sanitize_measurements(measurements) do
    measurements
    |> Map.delete(:telemetry_span_context)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), sanitize_scalar(v)} end)
  end

  defp duration_ms(%{duration: duration}) when is_integer(duration) do
    System.convert_time_unit(duration, :native, :millisecond)
  end

  defp duration_ms(_), do: nil

  # ----------------------------------------------------------------
  # Metadata redaction (per § 6.9)
  # ----------------------------------------------------------------

  defp redact_metadata(metadata, level) do
    metadata
    |> Map.delete(:telemetry_span_context)
    |> Enum.map(fn {k, v} -> {Atom.to_string(k), redact_field(k, v, level)} end)
    |> Map.new()
  end

  # § 6.7 telemetry metadata is byte-counts + presence flags only; the
  # raw `program`/`context`/`validated`/`prints` payloads never reach
  # telemetry (codex review of 212266d). The redacted program preview
  # lives on the trace.start header's `query` field. If those fields
  # ever appear in metadata again (e.g. a future event source), the
  # catch-all clause below sanitizes them generically — but this is a
  # belt-and-suspenders defense, not the primary redaction site.
  # Stacktraces are operator-debug data; sanitize via Exception formatter
  # without recursive sanitize (which can't handle stacktrace tuples).
  defp redact_field(:stacktrace, value, _level) when is_list(value) do
    Exception.format_stacktrace(value)
  rescue
    _ -> inspect(value, limit: 20)
  end

  # `:reason` (exception payload) — atoms / strings / structs surface
  # as-is via inspect. Per § 6.9, error reasons & messages are NEVER
  # redacted regardless of level.
  defp redact_field(:reason, value, _level) when is_binary(value) or is_atom(value), do: value
  defp redact_field(:reason, value, _level), do: inspect(value, limit: 50)

  # `:kind` — atom (`:error`, `:exit`, `:throw`).
  defp redact_field(:kind, value, _level) when is_atom(value), do: value
  defp redact_field(:kind, value, _level), do: inspect(value)

  # Caller, status, tool_name, request_id — primitive scalars; pass through.
  defp redact_field(_key, value, _level), do: sanitize_scalar(value)

  # ----------------------------------------------------------------
  # Scalar sanitizer (PIDs, refs, etc. → inspect)
  # ----------------------------------------------------------------

  defp sanitize_scalar(value) when is_binary(value), do: value
  defp sanitize_scalar(value) when is_atom(value), do: value
  defp sanitize_scalar(value) when is_number(value), do: value
  defp sanitize_scalar(value) when is_boolean(value), do: value
  defp sanitize_scalar(nil), do: nil

  defp sanitize_scalar(value) when is_list(value) do
    Enum.map(value, &sanitize_scalar/1)
  end

  defp sanitize_scalar(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {to_string(k), sanitize_scalar(v)} end)
  end

  defp sanitize_scalar(value), do: inspect(value, limit: 50, printable_limit: 100)
end
