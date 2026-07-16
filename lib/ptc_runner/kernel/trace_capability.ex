defmodule PtcRunner.Kernel.TraceCapability do
  @moduledoc """
  Source-scoped Lisp capabilities over the canonical TraceLog query layer.

  One explicit trace source produces four capabilities: `trace-list-runs`,
  `trace-get-run`, `trace-list-turns`, and `trace-counters`. Granting these
  capabilities exposes only the selected source and bounded query results; it
  does not grant ambient filesystem or cross-environment access.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.TraceLog

  @spec new(keyword()) :: {:ok, [Capability.t()]} | {:error, :invalid_trace_capability}
  @doc "Builds the four trace-query capabilities from `PtcRunner.Kernel.TraceLog` options."
  def new(opts) when is_list(opts) do
    with {:ok, trace_log} <- TraceLog.new(opts),
         {:ok, list_runs} <- capability(trace_log, "trace-list-runs", :list_runs),
         {:ok, get_run} <- capability(trace_log, "trace-get-run", :get_run),
         {:ok, list_turns} <- capability(trace_log, "trace-list-turns", :list_turns),
         {:ok, counters} <- capability(trace_log, "trace-counters", :counters) do
      {:ok, [list_runs, get_run, list_turns, counters]}
    else
      _ -> {:error, :invalid_trace_capability}
    end
  end

  def new(_opts), do: {:error, :invalid_trace_capability}

  defp capability(trace_log, name, operation) do
    Capability.new(
      name: name,
      description: "Bounded source-scoped canonical trace query",
      input_schema: %{"type" => "object", "additionalProperties" => true},
      output_schema: %{"type" => "object", "additionalProperties" => true},
      effect: :read,
      callback: fn arguments -> query(trace_log, operation, arguments) end,
      validate: &validate_arguments/1
    )
  end

  defp validate_arguments(arguments) when is_map(arguments), do: :ok
  defp validate_arguments(_arguments), do: {:error, "map required"}

  defp query(trace_log, operation, arguments) do
    case TraceLog.query(trace_log, operation, arguments) do
      {:ok, result} ->
        {:ok, result}

      {:error, :not_found} ->
        provider_error(:not_found, "run not found")

      {:error, :source_changed} ->
        provider_error(:invalid_request, "trace source changed")

      {:error, :source_limit_exceeded} ->
        provider_error(:invalid_request, "trace source limit exceeded")

      {:error, :result_limit_exceeded} ->
        provider_error(:invalid_request, "trace result limit exceeded")

      {:error, :malformed_source} ->
        provider_error(:invalid_request, "malformed trace source")

      {:error, :unsupported_version} ->
        provider_error(:invalid_request, "unsupported trace version")

      {:error, :invalid_query} ->
        provider_error(:invalid_request, "invalid trace query")

      {:error, _reason} ->
        provider_error(:internal, "trace source unavailable")
    end
  end

  defp provider_error(kind, details), do: {:error, ProviderError.new(kind, details)}
end
