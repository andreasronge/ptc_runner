defmodule PtcRunner.Kernel.TraceCapability do
  @moduledoc """
  Source-scoped Lisp capabilities over the canonical TraceLog query layer.

  One explicit trace source produces four capabilities: `trace-list-runs`,
  `trace-get-run`, `trace-list-turns`, and `trace-counters`. Granting these
  capabilities exposes only the selected source and bounded query results; it
  does not grant ambient filesystem or cross-environment access.
  Snapshot-backed results carry a `snapshot_hash` that matches the frozen
  provider's `content_snapshot_hash`, so citations remain bound to the exact
  captured catalog across every cursor page.

  Internal analysis profiles may instead construct the same four
  capabilities from a tokenized snapshot handle. Capability closures retain
  only that opaque handle and still delegate to the canonical TraceLog query
  implementation.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot

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

  @doc false
  @spec from_snapshot(TraceSnapshot.t()) ::
          {:ok, [Capability.t()]} | {:error, :invalid_trace_capability}
  def from_snapshot(snapshot), do: assemble_snapshot(snapshot, :profile)

  @doc false
  @spec from_snapshot(TraceSnapshot.t(), binary()) ::
          {:ok, [Capability.t()]} | {:error, :invalid_trace_capability}
  def from_snapshot(snapshot, provider) when is_binary(provider) do
    if provider =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/ do
      assemble_snapshot(snapshot, {:provider, provider})
    else
      {:error, :invalid_trace_capability}
    end
  end

  def from_snapshot(_snapshot, _provider), do: {:error, :invalid_trace_capability}

  defp assemble_snapshot(snapshot, naming) do
    with true <- TraceSnapshot.valid?(snapshot),
         {:ok, list_runs} <-
           snapshot_capability(snapshot, capability_name(naming, :list_runs), :list_runs),
         {:ok, get_run} <-
           snapshot_capability(snapshot, capability_name(naming, :get_run), :get_run),
         {:ok, list_turns} <-
           snapshot_capability(snapshot, capability_name(naming, :list_turns), :list_turns),
         {:ok, counters} <-
           snapshot_capability(snapshot, capability_name(naming, :counters), :counters) do
      {:ok, [list_runs, get_run, list_turns, counters]}
    else
      _ -> {:error, :invalid_trace_capability}
    end
  end

  defp capability_name(:profile, :list_runs), do: "trace-list-runs"
  defp capability_name(:profile, :get_run), do: "trace-get-run"
  defp capability_name(:profile, :list_turns), do: "trace-list-turns"
  defp capability_name(:profile, :counters), do: "trace-counters"
  defp capability_name({:provider, provider}, :list_runs), do: provider <> ".list-runs"
  defp capability_name({:provider, provider}, :get_run), do: provider <> ".get-run"
  defp capability_name({:provider, provider}, :list_turns), do: provider <> ".list-turns"
  defp capability_name({:provider, provider}, :counters), do: provider <> ".counters"

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

  defp snapshot_capability(snapshot, name, operation) do
    Capability.new(
      name: name,
      description: "Bounded source-scoped canonical trace query",
      input_schema: %{"type" => "object", "additionalProperties" => true},
      output_schema: %{"type" => "object", "additionalProperties" => true},
      effect: :read,
      callback: fn arguments -> query_snapshot(snapshot, operation, arguments) end,
      validate: &validate_arguments/1
    )
  end

  defp validate_arguments(arguments) when is_map(arguments), do: :ok
  defp validate_arguments(_arguments), do: {:error, "map required"}

  defp query(trace_log, operation, arguments) do
    trace_log
    |> query_source(operation, arguments)
    |> normalize_query_result()
  end

  defp query_snapshot(snapshot, operation, arguments) do
    snapshot
    |> TraceSnapshot.query(operation, arguments)
    |> normalize_query_result()
  end

  defp normalize_query_result(result) do
    case result do
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

  defp query_source(%TraceLog{} = trace_log, operation, arguments),
    do: TraceLog.query(trace_log, operation, arguments)

  defp provider_error(kind, details), do: {:error, ProviderError.new(kind, details)}
end
