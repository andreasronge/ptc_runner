defmodule PtcRunner.Kernel.DeclaredReadEffectValidator do
  @moduledoc false

  alias PtcRunner.Kernel.ExportEffect
  alias PtcRunner.Kernel.MissionInventory

  @analysis_operations ~w(runs open read counters)

  @spec validate(
          PtcRunner.Kernel.FrozenBundle.t(),
          %{binary() => PtcRunner.Kernel.FrozenBundle.t() | nil},
          map(),
          [map()]
        ) :: :ok | {:error, {:declared_read_effect_violation, binary(), :write | :unknown}}
  def validate(workflow_bundle, mission_bundles, missions, declarations) do
    validate_with(workflow_bundle, mission_bundles, missions, fn destination, occurrences ->
      effects_for(declarations, destination, occurrences)
    end)
  end

  @spec validate_prepared(
          PtcRunner.Kernel.FrozenBundle.t(),
          %{binary() => PtcRunner.Kernel.FrozenBundle.t() | nil},
          map(),
          [map()]
        ) :: :ok | {:error, {:declared_read_effect_violation, binary(), :write | :unknown}}
  def validate_prepared(workflow_bundle, mission_bundles, missions, preparations) do
    declarations =
      Enum.map(preparations, fn preparation ->
        %{
          destination: preparation.destination,
          index: preparation.index,
          capability_effects: preparation.capability_effects
        }
      end)

    validate_with(workflow_bundle, mission_bundles, missions, fn destination, occurrences ->
      prepared_effects(declarations, destination, occurrences)
    end)
  end

  @doc false
  @spec validate_assembled(PtcRunner.Kernel.WorkflowEnvironment.t(), map(), map()) ::
          :ok | {:error, {:declared_read_effect_violation, binary(), :write | :unknown}}
  def validate_assembled(workflow, missions, workflow_effects) do
    with :ok <- validate_bundle(workflow.bundle, workflow_effects) do
      missions
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while(:ok, fn {_name, mission}, :ok ->
        case MissionInventory.validate_declared_read_effects(mission) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_with(workflow_bundle, mission_bundles, missions, effects_for) do
    with :ok <- validate_bundle(workflow_bundle, effects_for.(:workflow, nil)) do
      mission_bundles
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while(:ok, fn {name, bundle}, :ok ->
        occurrences = Map.fetch!(missions, name).provider_occurrences

        case validate_bundle(bundle, effects_for.(:mission, occurrences)) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_bundle(nil, _capability_effects), do: :ok

  defp validate_bundle(%{prelude: %{exports: exports}}, capability_effects) do
    exports
    |> Enum.sort_by(& &1.ref)
    |> Enum.reduce_while(:ok, fn export, :ok ->
      resolved = ExportEffect.resolve(export, capability_effects)

      if export.declared_effect == :read and resolved != :read do
        {:halt, {:error, {:declared_read_effect_violation, export.ref, resolved}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp effects_for(declarations, destination, occurrences) do
    declarations
    |> Enum.filter(fn declaration ->
      declaration.destination == destination and
        (is_nil(occurrences) or declaration.index in occurrences)
    end)
    |> Enum.flat_map(&declaration_effects/1)
    |> Map.new()
  end

  defp prepared_effects(declarations, destination, occurrences) do
    declarations
    |> Enum.filter(fn declaration ->
      declaration.destination == destination and
        (is_nil(occurrences) or declaration.index in occurrences)
    end)
    |> Enum.flat_map(& &1.capability_effects)
    |> Map.new()
  end

  defp declaration_effects(%{descriptor: %{source: :mcp, selection_rules: rules}, config: config}) do
    write = Map.get(rules.named_sets, "write", []) |> MapSet.new()

    Enum.map(Map.get(config, "allow", []), fn name ->
      {name, if(MapSet.member?(write, name), do: :write, else: :read)}
    end)
  end

  defp declaration_effects(%{descriptor: %{source: source}})
       when source in [:llm, :llm_replay],
       do: [{"llm-request", :unknown}]

  defp declaration_effects(%{
         name: name,
         descriptor: %{source: source},
         config: config
       })
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] do
    if Map.get(config, "expose", true), do: analysis_effects(name), else: []
  end

  defp declaration_effects(%{name: name, descriptor: %{source: :ptc_inspection_snapshot}}),
    do: analysis_effects(name)

  defp declaration_effects(_declaration), do: []

  defp analysis_effects(name), do: Enum.map(@analysis_operations, &{"#{name}.#{&1}", :read})
end
