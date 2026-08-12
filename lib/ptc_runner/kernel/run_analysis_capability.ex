defmodule PtcRunner.Kernel.RunAnalysisCapability do
  @moduledoc """
  The single capability builder for question-shaped run analysis.

  Profile sessions receive six stable `analysis-*` capabilities. A sealed host
  recipe may expose the same operations as `<alias>.<operation>`. Both naming
  forms delegate to `PtcRunner.Kernel.RunAnalysis`; neither exposes primitive
  trace or inspection record-family operations.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunAnalysis

  @operations [:runs, :overview, :activity, :conversation, :failure, :source]

  @spec from_snapshots(term(), term() | nil, binary() | nil) ::
          {:ok, [Capability.t()]} | {:error, :invalid_run_analysis_capability}
  def from_snapshots(traces, inspection \\ nil, provider \\ nil) do
    with true <- is_nil(provider) or valid_provider?(provider),
         {:ok, analysis} <- RunAnalysis.new(traces, inspection) do
      assemble(analysis, provider)
    else
      _ -> {:error, :invalid_run_analysis_capability}
    end
  end

  @spec from_analysis(RunAnalysis.t(), binary() | nil) ::
          {:ok, [Capability.t()]} | {:error, :invalid_run_analysis_capability}
  def from_analysis(analysis, provider \\ nil) do
    with true <- is_nil(provider) or valid_provider?(provider),
         {:ok, _probe} <- RunAnalysis.query(analysis, :runs, %{"limit" => 1}) do
      assemble(analysis, provider)
    else
      _ -> {:error, :invalid_run_analysis_capability}
    end
  end

  defp assemble(analysis, provider) do
    Enum.reduce_while(@operations, {:ok, []}, fn operation, {:ok, capabilities} ->
      case capability(analysis, capability_name(provider, operation), operation) do
        {:ok, capability} -> {:cont, {:ok, [capability | capabilities]}}
        {:error, _reason} -> {:halt, {:error, :invalid_run_analysis_capability}}
      end
    end)
    |> case do
      {:ok, capabilities} -> {:ok, Enum.reverse(capabilities)}
      {:error, _reason} = error -> error
    end
  end

  defp capability(analysis, name, operation) do
    Capability.new(
      name: name,
      description: description(operation),
      input_schema: %{"type" => "object", "additionalProperties" => true},
      output_schema: %{"type" => "object", "additionalProperties" => true},
      effect: :read,
      callback: fn arguments -> query(analysis, operation, arguments) end,
      validate: &validate_arguments/1
    )
  end

  defp capability_name(nil, operation), do: "analysis-" <> operation_name(operation)
  defp capability_name(provider, operation), do: provider <> "." <> operation_name(operation)
  defp operation_name(operation), do: operation |> Atom.to_string() |> String.replace("_", "-")

  defp description(:runs), do: "List the runs available in this immutable analysis capture"
  defp description(:overview), do: "Summarize what happened in one run"
  defp description(:activity), do: "Read ordered run activity and authorized exact exchanges"
  defp description(:conversation), do: "Reconstruct the model conversation without record joins"
  defp description(:failure), do: "Explain a failure with conservative program relationships"
  defp description(:source), do: "Read exact generated and effective component source"

  defp validate_arguments(arguments) when is_map(arguments), do: :ok
  defp validate_arguments(_arguments), do: {:error, "map required"}

  defp query(analysis, operation, arguments) do
    case RunAnalysis.query(analysis, operation, arguments) do
      {:ok, result} ->
        {:ok, result}

      {:error, :not_found} ->
        provider_error(:not_found, "analysis run not found")

      {:error, :evidence_unavailable} ->
        provider_error(:invalid_request, "private evidence unavailable in this analysis recipe")

      {:error, :source_changed} ->
        provider_error(:invalid_request, "analysis cursor belongs to another capture")

      {:error, :result_limit_exceeded} ->
        provider_error(:invalid_request, "analysis result limit exceeded")

      {:error, :invalid_query} ->
        provider_error(:invalid_request, "invalid analysis query")

      {:error, _reason} ->
        provider_error(:internal, "analysis snapshot unavailable")
    end
  end

  defp valid_provider?(provider),
    do: is_binary(provider) and provider =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  defp provider_error(kind, details), do: {:error, ProviderError.new(kind, details)}
end
