defmodule PtcRunner.Kernel.AnalysisProfile do
  @moduledoc """
  Shared assembler and attestation recipe for code-owned analysis profiles.

  Profiles remain a closed set selected through
  `PtcRunner.Kernel.AnalysisProfileRegistry`. Callers may provide only the
  declared directory resources and trace destination; they cannot supply a
  profile module, component, capability, mission datum, limit, label, or sink
  policy.
  """

  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.SessionTrace
  alias PtcRunner.Kernel.WorkflowEnvironment

  @type recipe :: module()

  @doc false
  @spec assemble(recipe(), AnalysisResources.t(), PtcRunner.Kernel.EventSink.t()) ::
          {:ok, %{config: RunConfig.t(), profile: map()}} | {:error, atom()}
  def assemble(recipe, resources, sink) when is_atom(recipe) do
    limits = recipe.limits()

    with true <- AnalysisResources.valid?(resources),
         true <- resources.profile_id == recipe.id(),
         {:ok, components} <- Library.resolve_components(recipe.component_selections()),
         {:ok, bundle} <- PtcRunner.Kernel.compile_bundle(components),
         true <- namespaces(bundle) == recipe.namespaces(),
         {:ok, capabilities} <- recipe.capabilities(resources),
         true <- capability_names(capabilities) == recipe.explicit_capabilities(),
         {:ok, mission} <-
           MissionEnvironment.new(bundle: bundle, capabilities: capabilities, data: %{}),
         {:ok, workflow} <- WorkflowEnvironment.new([]),
         {:ok, profile} <- descriptor(recipe, bundle, mission, limits),
         {:ok, config} <- fixed_config(recipe, workflow, mission, limits, sink, profile) do
      {:ok, %{config: config, profile: profile}}
    else
      _ -> {:error, recipe.invalid_profile_error()}
    end
  end

  @doc false
  @spec valid_assembly?(
          recipe(),
          term(),
          term(),
          term(),
          term()
        ) :: boolean()
  def valid_assembly?(recipe, config, profile, resources, session_trace)
      when is_atom(recipe) do
    with true <- AnalysisResources.valid?(resources),
         {:ok, sink} <- SessionTrace.sink(session_trace),
         {:ok, expected} <- assemble(recipe, resources, sink) do
      comparable_config(config) === comparable_config(expected.config) and
        profile === expected.profile
    else
      _ -> false
    end
  catch
    :exit, _reason -> false
  end

  @doc false
  @spec descriptor(recipe(), map(), map(), Limits.t()) ::
          {:ok, map()} | {:error, atom()}
  def descriptor(recipe, bundle, mission, %Limits{} = limits) when is_atom(recipe) do
    with true <- namespaces(bundle) == recipe.namespaces(),
         {:ok, inventory} <- MissionInventory.build(mission, limits),
         identity = identity(recipe, bundle, inventory, limits),
         {:ok, encoded} <- DeterministicJSON.encode(identity) do
      digest = "sha256:" <> sha256(encoded)

      {:ok,
       %{
         id: recipe.id(),
         digest: digest,
         namespaces: recipe.namespaces(),
         identity: identity,
         mission_inventory: inventory
       }}
    else
      _ -> {:error, recipe.invalid_profile_error()}
    end
  end

  defp comparable_config(%RunConfig{} = config), do: %{config | claim_id: nil}

  defp identity(recipe, bundle, inventory, limits) do
    base = %{
      "profile_id" => recipe.id(),
      "bundle_hash" => bundle.hash,
      "mission_inventory_hash" => inventory.hash,
      "implicit_runtime" => RuntimeTools.mission_contract_descriptor(),
      "limits" => limits |> Map.from_struct() |> stringify_keys(),
      "explicit_capabilities" => recipe.explicit_capabilities(),
      "components" => recipe.component_ids(),
      "mission_data" => %{},
      "persistence_policy" => recipe.persistence_policy(),
      "result_policy" => recipe.result_policy()
    }

    Map.merge(base, recipe.identity_extension())
  end

  defp fixed_config(recipe, workflow, mission, limits, sink, profile) do
    RunConfig.new(
      workflow_environment: workflow,
      mission_environment: mission,
      input: %{},
      limits: limits,
      event_sink: sink,
      labels: recipe.labels(),
      session_profile: %{"id" => profile.id, "digest" => profile.digest}
    )
  end

  defp capability_names(capabilities),
    do: capabilities |> Enum.map(& &1.name) |> Enum.sort()

  defp namespaces(bundle) do
    bundle.components
    |> Enum.flat_map(& &1.namespaces)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
