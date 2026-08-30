defmodule PtcRunner.Kernel.RunAnalysisCapability do
  @moduledoc """
  The single capability builder for bounded run-evidence navigation.

  Profile sessions receive four stable `analysis-*` capabilities. A sealed host
  recipe may expose the same operations as `<alias>.<operation>`. Both naming
  forms delegate to `PtcRunner.Kernel.RunAnalysis`; neither exposes primitive
  trace or inspection record-family operations. Installed provider aliases are
  capped at 119 ASCII bytes so every derived name, including `.counters`, fits
  `Capability`'s 128-byte name ceiling.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunAnalysis

  @operations [:runs, :open, :read, :counters]
  @max_provider_bytes 119
  @provider_name ~r/\A[a-z][a-z0-9._-]{0,118}\z/

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
      input_schema: input_schema(operation),
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
  defp description(:open), do: "Open one run's metadata and discover its evidence collections"
  defp description(:read), do: "Read one bounded page from a named run evidence collection"

  defp description(:counters),
    do:
      "Return canonical trace counters for a filtered run cohort, including adapter-attested model usage"

  defp input_schema(:runs) do
    object_schema(%{
      "limit" => limit_schema(),
      "cursor" => string_schema(),
      "status" => string_schema(),
      "run_id" => string_schema(),
      "trace_id" => string_schema(),
      "tags" => %{"type" => "object"},
      "name" => string_schema(),
      "bundle" => string_schema(),
      "model" => string_schema(),
      "provider" => string_schema(),
      "from" => string_schema(),
      "to" => string_schema(),
      "view" => %{"type" => "string", "enum" => ["summary", "full"]}
    })
  end

  defp input_schema(:open),
    do: object_schema(%{"run_id" => string_schema()}, ["run_id"])

  defp input_schema(:read) do
    collection_names = Enum.map(RunAnalysis.collections(), & &1.name)

    filter_names =
      RunAnalysis.collections()
      |> Enum.flat_map(& &1.filters)
      |> Enum.uniq()

    filter_schemas =
      Map.new(filter_names, fn
        name when name in ["input_sequence", "request_id"] -> {name, positive_integer_schema()}
        name -> {name, string_schema()}
      end)

    object_schema(
      Map.merge(filter_schemas, %{
        "run_id" => string_schema(),
        "collection" => %{"type" => "string", "enum" => collection_names},
        "limit" => limit_schema(),
        "cursor" => string_schema()
      }),
      ["run_id", "collection"]
    )
  end

  defp input_schema(:counters) do
    object_schema(%{
      "status" => filter_string_schema(),
      "run_id" => filter_string_schema(),
      "trace_id" => filter_string_schema(),
      "tags" => tags_schema(),
      "name" => filter_string_schema(),
      "bundle" => filter_string_schema(),
      "model" => filter_string_schema(),
      "provider" => filter_string_schema(),
      "from" => filter_string_schema(),
      "to" => filter_string_schema(),
      "mission_name" => filter_string_schema()
    })
  end

  defp object_schema(properties, required \\ []) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp string_schema, do: %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
  defp filter_string_schema, do: %{"type" => "string", "maxLength" => 256}

  defp tags_schema do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "maxProperties" => 16,
      "propertyNames" => %{"type" => "string", "maxLength" => 256}
    }
  end

  defp limit_schema, do: %{"type" => "integer", "minimum" => 1, "maximum" => 100}
  defp positive_integer_schema, do: %{"type" => "integer", "minimum" => 1}

  defp validate_arguments(arguments) when is_map(arguments), do: :ok
  defp validate_arguments(_arguments), do: {:error, "map required"}

  defp query(analysis, operation, arguments) do
    case RunAnalysis.query(analysis, operation, arguments) do
      {:ok, result} ->
        {:ok, result}

      {:error, :not_found} ->
        provider_error(:not_found, "analysis run not found")

      {:error, :run_isolated} ->
        provider_error(:unavailable, "analysis run is isolated by damaged trace evidence")

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
    do:
      is_binary(provider) and byte_size(provider) <= @max_provider_bytes and
        provider =~ @provider_name

  defp provider_error(kind, details), do: {:error, ProviderError.new(kind, details)}
end
