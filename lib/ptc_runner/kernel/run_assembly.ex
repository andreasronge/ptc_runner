defmodule PtcRunner.Kernel.RunAssembly do
  @moduledoc """
  Assembles workflow and mission environments from admitted bundles and grants.

  This layer opens no sinks, sessions or providers. The supplied capabilities
  are the complete authority available to each environment.
  """
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.ComponentCatalog
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.SourceIntern
  alias PtcRunner.Kernel.WorkflowEnvironment

  # One environment per declared mission, each assembled from its already
  # prepared bundle and granted only the mission providers that mission named.
  # A grant a mission did not name is simply absent from its environment, so
  # authority is enforced by assembly rather than by anything the model is
  # asked to respect.
  defp mission_environments(package, mission_bundles, providers, intern) do
    by_occurrence = Map.get(providers.mission, :by_occurrence, %{})

    Enum.reduce_while(Map.get(package, :missions) || %{}, {:ok, intern, %{}}, fn {name, spec},
                                                                                 {:ok, intern,
                                                                                  acc} ->
      capabilities =
        spec.provider_occurrences
        |> Enum.flat_map(&Map.get(by_occurrence, &1, []))

      with {:ok, bundle} <- Map.fetch(mission_bundles, name),
           {:ok, intern, catalog} <- environment_catalog(spec.components, bundle, intern),
           {:ok, environment} <-
             MissionEnvironment.new(
               bundle: bundle,
               capabilities: capabilities,
               data: spec.data,
               catalog: catalog,
               shipped_component_ids: library_component_ids(spec.kinds)
             ) do
        {:cont, {:ok, intern, Map.put(acc, name, environment)}}
      else
        {:error, {:missing_capability_requirement, _names}} = error -> {:halt, error}
        {:error, :source_hash_collision} = error -> {:halt, error}
        {:error, :catalog_bundle_mismatch} = error -> {:halt, error}
        _error -> {:halt, {:error, :invalid_mission_environment}}
      end
    end)
    |> case do
      {:ok, _intern, environments} -> {:ok, environments}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def environment_catalog([], nil, intern), do: {:ok, intern, ComponentCatalog.empty()}

  @doc false
  def environment_catalog(components, bundle, intern),
    do: ComponentCatalog.build(components, bundle, intern)

  @doc false
  @spec assemble_environments(ApplicationPackage.t(), FrozenBundle.t(), map(), map()) ::
          {:ok, WorkflowEnvironment.t(), map()} | {:error, term()}
  def assemble_environments(package, workflow_bundle, mission_bundles, providers) do
    with {:ok, intern, workflow_catalog} <-
           environment_catalog(package.workflow_components, workflow_bundle, SourceIntern.new()),
         {:ok, workflow} <-
           WorkflowEnvironment.new_for_package(
             [
               bundle: workflow_bundle,
               capabilities: providers.workflow.capabilities,
               catalog: workflow_catalog,
               shipped_component_ids: library_component_ids(package.workflow_component_kinds)
             ],
             package
           ),
         {:ok, missions} <- mission_environments(package, mission_bundles, providers, intern) do
      {:ok, workflow, missions}
    end
  end

  @doc false
  def library_component_ids(kinds) do
    for {id, :library} <- kinds, do: id
  end
end
