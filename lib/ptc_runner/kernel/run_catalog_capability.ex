defmodule PtcRunner.Kernel.RunCatalogCapability do
  @moduledoc "The catalog-only capability for bounded private cohort discovery."

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunCatalogSnapshot

  @spec from_snapshot(RunCatalogSnapshot.t()) ::
          {:ok, [Capability.t()]} | {:error, :invalid_run_catalog_capability}
  def from_snapshot(snapshot) do
    with true <- RunCatalogSnapshot.valid?(snapshot),
         {:ok, _info} <- RunCatalogSnapshot.info(snapshot),
         {:ok, capability} <- capability(snapshot) do
      {:ok, [capability]}
    else
      _invalid -> {:error, :invalid_run_catalog_capability}
    end
  end

  defp capability(snapshot) do
    Capability.new(
      name: "analysis-catalog",
      description: "Page and filter safe metadata from this immutable private run catalog",
      input_schema: input_schema(),
      output_schema: %{"type" => "object", "additionalProperties" => true},
      effect: :read,
      callback: fn arguments -> query(snapshot, arguments) end,
      validate: &validate_arguments/1
    )
  end

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "run_id" => string_schema(),
        "trace_id" => string_schema(),
        "status" => string_schema(),
        "name" => string_schema(),
        "model" => string_schema(),
        "provider" => string_schema(),
        "correlation" => string_schema(),
        "state" => string_schema(),
        "tags" => tags_schema(),
        "from" => string_schema(),
        "to" => string_schema(),
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
        "cursor" => %{"type" => "string", "minLength" => 1, "maxLength" => 1_024}
      },
      "additionalProperties" => false
    }
  end

  defp string_schema, do: %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}

  defp tags_schema do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "maxProperties" => 16,
      "propertyNames" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
    }
  end

  defp validate_arguments(arguments) when is_map(arguments), do: :ok
  defp validate_arguments(_arguments), do: {:error, "map required"}

  defp query(snapshot, arguments) do
    case RunCatalogSnapshot.query(snapshot, arguments) do
      {:ok, result} ->
        {:ok, result}

      {:error, :source_changed} ->
        provider_error(:invalid_request, "catalog cursor belongs to another generation")

      {:error, :result_limit_exceeded} ->
        provider_error(:invalid_request, "catalog result limit exceeded")

      {:error, :invalid_query} ->
        provider_error(:invalid_request, "invalid catalog query")

      {:error, _reason} ->
        provider_error(:internal, "catalog generation unavailable")
    end
  end

  defp provider_error(kind, details), do: {:error, ProviderError.new(kind, details)}
end
