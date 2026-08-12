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
         {:ok, capabilities} <- recipe.capabilities(resources),
         :ok <- validate_contract(recipe, bundle, capabilities),
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

  @doc """
  Refuses a capture that admitted no artifact from its resource directory.

  Directory capture is one level deep by design, so a directory whose
  artifacts sit in subdirectories admits nothing and then answers every query
  with an empty page — indistinguishable from a capture that genuinely holds
  no runs. Takes the snapshot's own `info/1` result so both snapshot kinds are
  checked the same way, and fails closed on any info the owner cannot report.
  """
  @spec refuse_empty_capture(term(), atom()) :: :ok | {:error, atom()}
  def refuse_empty_capture({:ok, %{file_count: file_count}}, _empty_error)
      when is_integer(file_count) and file_count > 0,
      do: :ok

  def refuse_empty_capture({:ok, %{file_count: 0}}, empty_error) when is_atom(empty_error),
    do: {:error, empty_error}

  def refuse_empty_capture(_info, _empty_error), do: {:error, :source_unavailable}

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
    with :ok <- validate_contract(recipe, bundle, Map.values(mission.capabilities)),
         {:ok, inventory} <- MissionInventory.build(mission, limits),
         identity = identity(recipe, bundle, mission, inventory, limits),
         {:ok, encoded} <- DeterministicJSON.encode(identity) do
      digest = "sha256:" <> sha256(encoded)

      {:ok,
       %{
         id: recipe.id(),
         digest: digest,
         namespaces: namespaces(bundle),
         identity: identity,
         mission_inventory: inventory
       }}
    else
      _ -> {:error, recipe.invalid_profile_error()}
    end
  end

  @doc false
  @spec validate_contract(recipe(), map(), [map()]) ::
          :ok
          | {:error,
             :profile_component_set_mismatch
             | :profile_namespace_set_mismatch
             | :profile_capability_set_mismatch
             | :invalid_profile_contract}
  def validate_contract(
        recipe,
        %{component_ids: component_ids, components: components} = bundle,
        capabilities
      )
      when is_atom(recipe) and is_list(component_ids) and is_list(components) and
             is_list(capabilities) do
    with :ok <-
           validate_members(
             component_ids,
             recipe.component_ids(),
             :profile_component_set_mismatch
           ),
         :ok <-
           validate_members(
             namespaces(bundle),
             recipe.namespaces(),
             :profile_namespace_set_mismatch
           ) do
      validate_members(
        capability_names(capabilities),
        recipe.explicit_capabilities(),
        :profile_capability_set_mismatch
      )
    end
  end

  def validate_contract(_recipe, _bundle, _capabilities),
    do: {:error, :invalid_profile_contract}

  defp comparable_config(%RunConfig{} = config), do: %{config | claim_id: nil}

  defp identity(recipe, bundle, mission, inventory, limits) do
    base = %{
      "profile_id" => recipe.id(),
      "bundle_hash" => bundle.hash,
      "mission_inventory_hash" => inventory.hash,
      "implicit_runtime" => RuntimeTools.mission_contract_descriptor(),
      "limits" => limits |> Map.from_struct() |> stringify_keys(),
      "explicit_capabilities" => mission.capabilities |> Map.keys() |> Enum.sort(),
      "components" => bundle.component_ids,
      "mission_data" => %{},
      "persistence_policy" => recipe.persistence_policy(),
      "result_policy" => recipe.result_policy()
    }

    Map.merge(base, recipe.identity_extension())
  end

  defp fixed_config(recipe, workflow, mission, limits, sink, profile) do
    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
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

  defp validate_members(actual, expected, mismatch)
       when is_list(actual) and is_list(expected) do
    if Enum.sort(actual) == Enum.sort(expected), do: :ok, else: {:error, mismatch}
  end

  defp validate_members(_actual, _expected, mismatch), do: {:error, mismatch}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
