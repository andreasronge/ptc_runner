defmodule PtcRunner.Kernel.LLMRouter do
  @moduledoc false

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.RoutedCapability

  @alias ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @sources ~w(llm llm_replay custom)
  @route_keys [:alias, :source, :installation_revision, :default?, :capability]

  @type route :: %{
          alias: binary(),
          source: binary(),
          installation_revision: binary(),
          default?: boolean(),
          capability: Capability.t()
        }

  @spec new([route()]) :: {:ok, RoutedCapability.t()} | {:error, :invalid_llm_router}
  def new(routes) when is_list(routes) and length(routes) in 1..128 do
    with true <- Enum.all?(routes, &valid_route?/1),
         routes = Enum.sort_by(routes, & &1.alias),
         aliases = Enum.map(routes, & &1.alias),
         true <- aliases == Enum.uniq(aliases),
         defaults = Enum.filter(routes, & &1.default?),
         true <- length(defaults) <= 1,
         first = List.first(routes),
         true <- compatible_routes?(routes, first.capability),
         {:ok, advertised_input_schema} <- routed_input_schema(first.capability.input_schema),
         route_map <- Map.new(routes, &{&1.alias, &1.capability}),
         default_alias <- defaults |> List.first() |> then(&(&1 && &1.alias)),
         resolver <- resolver(routes, default_alias),
         discovery <- %{"model_aliases" => Enum.map(routes, &discovery_row/1)},
         {:ok, routed} <-
           RoutedCapability.new(
             name: "llm-request",
             description: "Submit one provider-neutral bounded language-model request",
             input_schema: advertised_input_schema,
             output_schema: first.capability.output_schema,
             routes: route_map,
             resolve: resolver,
             validation_arguments: &Map.delete(&1, "model"),
             discovery: discovery
           ) do
      # The bounded schema profile deliberately excludes union types. Runtime
      # validation removes `model` before using this compiled schema; the
      # resolver separately enforces the selector's exact string contract.
      {:ok, routed}
    else
      _invalid -> {:error, :invalid_llm_router}
    end
  end

  def new(_routes), do: {:error, :invalid_llm_router}

  defp valid_route?(route) when is_map(route) do
    Map.keys(route) |> Enum.sort() == Enum.sort(@route_keys) and
      is_binary(route.alias) and route.alias =~ @alias and route.source in @sources and
      is_binary(route.installation_revision) and route.installation_revision =~ @alias and
      is_boolean(route.default?) and match?(%Capability{name: "llm-request"}, route.capability)
  end

  defp valid_route?(_route), do: false

  defp compatible_routes?(routes, first) do
    Enum.all?(routes, fn route ->
      route.capability.input_schema == first.input_schema and
        route.capability.output_schema == first.output_schema
    end)
  end

  defp routed_input_schema(%{"type" => "object"} = schema) do
    properties = Map.get(schema, "properties", %{})

    if is_map(properties) and not Map.has_key?(properties, "model") do
      {:ok,
       Map.put(
         schema,
         "properties",
         Map.put(properties, "model", %{
           "type" => "string",
           "description" => "Selected provider installation alias"
         })
       )}
    else
      {:error, :invalid_llm_router}
    end
  end

  defp routed_input_schema(_schema), do: {:error, :invalid_llm_router}

  defp resolver(routes, default_alias) do
    by_alias = Map.new(routes, &{&1.alias, &1})
    labels = Enum.map_join(routes, ", ", &alias_label/1)

    fn arguments ->
      case Map.fetch(arguments, "model") do
        :error ->
          resolve_omitted(arguments, routes, by_alias, default_alias)

        {:ok, nil} ->
          {:error, :invalid_model_alias,
           "model alias must be a string; null does not mean omitted"}

        {:ok, alias_name} when is_binary(alias_name) ->
          case Map.fetch(by_alias, alias_name) do
            {:ok, route} -> invocation(route, Map.delete(arguments, "model"))
            :error -> {:error, :unknown_model_alias, unknown_alias(alias_name, labels)}
          end

        {:ok, _invalid} ->
          {:error, :invalid_model_alias, "model alias must be a string"}
      end
    end
  end

  defp resolve_omitted(arguments, [route], _by_alias, _default_alias),
    do: invocation(route, arguments)

  defp resolve_omitted(arguments, _routes, by_alias, default_alias)
       when is_binary(default_alias),
       do: invocation(Map.fetch!(by_alias, default_alias), arguments)

  defp resolve_omitted(_arguments, routes, _by_alias, nil) do
    aliases = Enum.map_join(routes, ", ", & &1.alias)

    {:error, :model_alias_required,
     "#{length(routes)} model aliases selected (#{aliases}) and no default declared; " <>
       "this call must name one"}
  end

  defp invocation(route, arguments) do
    {:ok,
     %CapabilityInvocation{
       capability: route.capability,
       arguments: arguments,
       route_key: route.alias,
       event_attributes: %{
         alias: route.alias,
         installation_revision: route.installation_revision
       },
       error_attributes: %{model: route.alias},
       usage_projection: :llm_tokens
     }}
  end

  defp alias_label(%{alias: alias_name, default?: true}), do: alias_name <> " (default)"
  defp alias_label(%{alias: alias_name}), do: alias_name

  defp unknown_alias(alias_name, labels),
    do: ~s(unknown model alias "#{alias_name}"; selected aliases are: #{labels})

  defp discovery_row(route) do
    %{
      "alias" => route.alias,
      "source" => route.source,
      "installation_revision" => route.installation_revision,
      "default" => route.default?
    }
  end
end
