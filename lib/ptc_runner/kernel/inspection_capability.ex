defmodule PtcRunner.Kernel.InspectionCapability do
  @moduledoc """
  Fixed read-only capabilities over one private `InspectionSnapshot`.

  Profile-backed sessions receive stable `inspection-*` names. A manifest
  installation derives the same six operations from its selected alias as
  `<alias>.<operation>`. Both forms retain only an opaque snapshot handle and
  delegate to the same query layer. Every result carries the frozen capture's
  `snapshot_hash`, matching the provider snapshot's `content_snapshot_hash`,
  so private citations never depend on a path or an unbound page.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.ProviderError

  @operations [
    :list_runs,
    :model_exchanges,
    :capability_calls,
    :generated_sources,
    :effective_preludes,
    :provider_exchanges
  ]

  @doc false
  @spec from_snapshot(InspectionSnapshot.t()) ::
          {:ok, [Capability.t()]} | {:error, :invalid_inspection_capability}
  def from_snapshot(snapshot), do: assemble(snapshot, :profile)

  @doc false
  @spec from_snapshot(InspectionSnapshot.t(), binary()) ::
          {:ok, [Capability.t()]} | {:error, :invalid_inspection_capability}
  def from_snapshot(snapshot, provider) when is_binary(provider) do
    if provider =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/ do
      assemble(snapshot, {:provider, provider})
    else
      {:error, :invalid_inspection_capability}
    end
  end

  def from_snapshot(_snapshot, _provider), do: {:error, :invalid_inspection_capability}

  defp assemble(snapshot, naming) do
    if InspectionSnapshot.valid?(snapshot) do
      Enum.reduce_while(@operations, {:ok, []}, fn operation, {:ok, capabilities} ->
        case capability(snapshot, capability_name(naming, operation), operation) do
          {:ok, capability} -> {:cont, {:ok, [capability | capabilities]}}
          {:error, _reason} -> {:halt, {:error, :invalid_inspection_capability}}
        end
      end)
      |> case do
        {:ok, capabilities} -> {:ok, Enum.reverse(capabilities)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_inspection_capability}
    end
  end

  defp capability_name(:profile, :list_runs), do: "inspection-list-runs"
  defp capability_name(:profile, :model_exchanges), do: "inspection-model-exchanges"
  defp capability_name(:profile, :capability_calls), do: "inspection-capability-calls"
  defp capability_name(:profile, :generated_sources), do: "inspection-generated-sources"
  defp capability_name(:profile, :effective_preludes), do: "inspection-effective-preludes"
  defp capability_name(:profile, :provider_exchanges), do: "inspection-provider-exchanges"

  defp capability_name({:provider, provider}, operation),
    do: provider <> "." <> operation_name(operation)

  defp operation_name(:list_runs), do: "list-runs"
  defp operation_name(:model_exchanges), do: "model-exchanges"
  defp operation_name(:capability_calls), do: "capability-calls"
  defp operation_name(:generated_sources), do: "generated-sources"
  defp operation_name(:effective_preludes), do: "effective-preludes"
  defp operation_name(:provider_exchanges), do: "provider-exchanges"

  defp capability(snapshot, name, operation) do
    Capability.new(
      name: name,
      description: "Bounded source-scoped private inspection query",
      input_schema: %{"type" => "object", "additionalProperties" => true},
      output_schema: %{"type" => "object", "additionalProperties" => true},
      effect: :read,
      callback: fn arguments -> query(snapshot, operation, arguments) end,
      validate: &validate_arguments/1
    )
  end

  defp validate_arguments(arguments) when is_map(arguments), do: :ok
  defp validate_arguments(_arguments), do: {:error, "map required"}

  defp query(snapshot, operation, arguments) do
    case InspectionSnapshot.query(snapshot, operation, arguments) do
      {:ok, result} ->
        {:ok, result}

      {:error, :not_found} ->
        provider_error(:not_found, "inspection run not found")

      {:error, :source_changed} ->
        provider_error(:invalid_request, "inspection cursor belongs to another capture")

      {:error, :result_limit_exceeded} ->
        provider_error(:invalid_request, "inspection result limit exceeded")

      {:error, :invalid_query} ->
        provider_error(:invalid_request, "invalid inspection query")

      {:error, _reason} ->
        provider_error(:internal, "inspection snapshot unavailable")
    end
  end

  defp provider_error(kind, details), do: {:error, ProviderError.new(kind, details)}
end
