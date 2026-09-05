defmodule PtcRunner.Kernel.Environment do
  @moduledoc """
  Internal shared validator for workflow and mission environment constructors.

  It verifies bundle attestations, JSON-like data, capability identity,
  reserved routes, and bundle tool requirements. The public environment
  structs remain distinct even though they share this validation path.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.RoutedCapability

  @reserved ~w(kernel-check-source kernel-eval kernel-agent-config-failure kernel-agent-outcome-failure kernel-agent-protocol-error kernel-llm-provider-failure kernel-mission-inventory kernel-mission-model-context kernel-phase-return-contract-failure kernel-result-contract kernel-result-contract-failure kernel-runtime-limit-failure runtime-usage runtime-remaining cap-list cap-describe workflow-annotate)
  @workflow_implicit ~w(kernel-check-source kernel-eval kernel-mission-inventory kernel-mission-model-context kernel-result-contract runtime-usage runtime-remaining cap-list cap-describe workflow-annotate)
  @agent_core_private ~w(kernel-agent-config-failure kernel-agent-outcome-failure kernel-agent-protocol-error kernel-llm-provider-failure kernel-phase-return-contract-failure kernel-result-contract-failure kernel-runtime-limit-failure)

  @doc """
  Validates common environment fields and returns normalized attributes.

  `opts` carries `:authorization`, the workflow package authority that decides
  private diagnostic routes; `:shipped_component_ids`, the shipped library
  selections the bundle represents; and `:inspect_only`, which skips recorded
  tool-requirement checks for compile-and-inspect sessions.
  """
  def assemble(bundle, capabilities, data, kind, opts \\ [])

  def assemble(bundle, capabilities, data, :workflow, opts) when is_list(opts) do
    private_capabilities =
      workflow_private_capabilities(bundle, Keyword.get(opts, :authorization, %{}))

    case do_assemble(bundle, capabilities, data, :workflow, private_capabilities, opts) do
      {:ok, attributes} ->
        {:ok, Map.put(attributes, :private_capabilities, private_capabilities)}

      {:error, _reason} = error ->
        error
    end
  end

  def assemble(bundle, capabilities, data, :mission, opts) when is_list(opts),
    do: do_assemble(bundle, capabilities, data, :mission, [], opts)

  defp skip_tool_requirements?(opts) when is_list(opts),
    do: Keyword.get(opts, :inspect_only) == true

  defp do_assemble(bundle, capabilities, data, kind, private_capabilities, opts) do
    with :ok <- valid_bundle(bundle),
         true <- JSONValue.map?(data),
         {:ok, capability_map} <- capability_map(capabilities),
         :ok <- reserved_names(kind, capability_map),
         :ok <-
           maybe_bundle_requirements(
             bundle,
             capability_map,
             kind,
             private_capabilities,
             skip_tool_requirements?(opts)
           ),
         {:ok, shipped_component_ids} <-
           normalize_shipped_component_ids(bundle, Keyword.get(opts, :shipped_component_ids)) do
      {:ok,
       %{
         bundle: bundle,
         capabilities: capability_map,
         data: data,
         shipped_component_ids: shipped_component_ids,
         inspect_only: skip_tool_requirements?(opts)
       }}
    else
      false -> {:error, :invalid_environment_data}
      error -> error
    end
  end

  defp maybe_bundle_requirements(_bundle, _capabilities, _kind, _private, true), do: :ok

  defp maybe_bundle_requirements(bundle, capabilities, kind, private_capabilities, false),
    do: bundle_requirements(bundle, capabilities, kind, private_capabilities)

  @doc false
  @spec component_ids(%{bundle: FrozenBundle.t() | nil}) :: [binary()]
  def component_ids(%{bundle: nil}), do: []
  def component_ids(%{bundle: %FrozenBundle{component_ids: component_ids}}), do: component_ids

  @doc false
  @spec shipped_component_ids(%{
          optional(:shipped_component_ids) => [binary()] | nil,
          optional(any()) => any()
        }) :: [binary()]
  def shipped_component_ids(%{shipped_component_ids: nil}), do: []
  def shipped_component_ids(%{shipped_component_ids: component_ids}), do: component_ids

  defp normalize_shipped_component_ids(_bundle, nil), do: {:ok, []}

  defp normalize_shipped_component_ids(%FrozenBundle{component_ids: attached}, component_ids)
       when is_list(component_ids) do
    shipped_ids = MapSet.new(Library.component_ids())

    if Enum.all?(component_ids, &is_binary/1) do
      normalized =
        component_ids
        |> Enum.filter(&(&1 in attached and MapSet.member?(shipped_ids, &1)))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, normalized}
    else
      {:error, :invalid_shipped_component_ids}
    end
  end

  defp normalize_shipped_component_ids(nil, component_ids) when is_list(component_ids) do
    if component_ids == [], do: {:ok, []}, else: {:error, :invalid_shipped_component_ids}
  end

  defp normalize_shipped_component_ids(_bundle, _component_ids),
    do: {:error, :invalid_shipped_component_ids}

  @doc """
  Returns the whole-environment capability view.

  Dispatch reads nothing from an environment but `:capabilities`. A callback
  handed to a sandboxed evaluation must capture a view rather than the
  environment itself: `spawn` does not preserve sharing, so capturing the
  environment would copy its frozen bundle once per capability callback.

  Only the discovery routes need every capability. A callback that dispatches
  one capability must capture `capability_view/2` instead — capturing the
  whole map from each of them costs the hand-over `O(capabilities²)`, which a
  tool-rich MCP environment can blow the sandbox setup ceiling with before
  evaluation starts.
  """
  def capability_view(%{capabilities: capabilities}), do: %{capabilities: capabilities}

  @doc """
  Returns the single-capability view one dispatch callback needs.

  `Dispatcher.dispatch/8` resolves `name` against the `:capabilities` of the
  value it is given and reads nothing else from it, so a callback bound to one
  capability can carry only that capability and dispatch identically.
  """
  def capability_view(name, %Capability{} = capability) when is_binary(name),
    do: %{capabilities: %{name => capability}}

  def capability_view(name, %RoutedCapability{} = capability) when is_binary(name),
    do: %{capabilities: %{name => capability}}

  @doc "Returns the attested component catalog for `environment`, if present."
  @spec catalog(map()) :: PtcRunner.Kernel.ComponentCatalog.t() | nil
  def catalog(%{catalog: catalog}), do: catalog
  def catalog(_environment), do: nil

  @doc "Returns sorted model-visible capability metadata for one environment."
  def metadata(%{capabilities: capabilities}) do
    capabilities
    |> Map.values()
    |> Enum.filter(& &1.model_visible)
    |> Enum.map(&capability_metadata/1)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns bounded metadata for every installed capability, regardless of prompt visibility."
  @spec capability_contracts(map()) :: %{binary() => map()}
  def capability_contracts(%{capabilities: capabilities}) when is_map(capabilities) do
    Map.new(capabilities, fn {name, capability} ->
      contract =
        capability
        |> capability_metadata()
        |> Map.take([:name, :description, :input_schema, :effect])

      {name, contract}
    end)
  end

  @doc false
  @spec capability_requirements(FrozenBundle.t() | nil) :: [binary()]
  def capability_requirements(%FrozenBundle{prelude: %{exports: exports}}) do
    exports
    |> Enum.flat_map(fn export ->
      explicit =
        export
        |> Map.get(:requires, [])
        |> Enum.map(fn "tool:" <> name -> name end)

      explicit ++ Map.get(export, :tool_refs, [])
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def capability_requirements(nil), do: []

  @doc false
  @spec missing_capability_requirements(FrozenBundle.t() | nil, [binary()], :workflow | :mission) ::
          [binary()]
  def missing_capability_requirements(bundle, capability_names, kind)
      when is_list(capability_names) and kind in [:workflow, :mission] do
    private_capabilities =
      case kind do
        :workflow -> workflow_private_capabilities(bundle, %{})
        :mission -> []
      end

    missing_capability_requirements(bundle, capability_names, kind, private_capabilities)
  end

  @doc false
  @spec missing_capability_requirements(
          FrozenBundle.t() | nil,
          [binary()],
          :workflow | :mission,
          [binary()]
        ) :: [binary()]
  def missing_capability_requirements(bundle, capability_names, kind, private_capabilities)
      when is_list(capability_names) and is_list(private_capabilities) and
             kind in [:workflow, :mission] do
    granted_names =
      Map.new(
        capability_names ++ implicit_capabilities(kind, private_capabilities),
        &{&1, true}
      )

    bundle
    |> capability_requirements()
    |> Enum.reject(&Map.has_key?(granted_names, &1))
  end

  defp valid_bundle(nil), do: :ok

  defp valid_bundle(%FrozenBundle{} = bundle),
    do: if(FrozenBundle.valid?(bundle), do: :ok, else: {:error, :invalid_bundle})

  defp valid_bundle(_bundle), do: {:error, :invalid_bundle}

  defp capability_map(capabilities) when is_list(capabilities) do
    Enum.reduce_while(capabilities, {:ok, %{}}, fn
      %Capability{name: name} = capability, {:ok, map} ->
        if Map.has_key?(map, name),
          do: {:halt, {:error, :duplicate_capability}},
          else: {:cont, {:ok, Map.put(map, name, capability)}}

      %RoutedCapability{name: name} = capability, {:ok, map} ->
        if Map.has_key?(map, name),
          do: {:halt, {:error, :duplicate_capability}},
          else: {:cont, {:ok, Map.put(map, name, capability)}}

      _capability, _acc ->
        {:halt, {:error, :invalid_capability}}
    end)
  end

  defp capability_map(_capabilities), do: {:error, :invalid_capability}

  defp reserved_names(_kind, capabilities) do
    if Enum.any?(Map.keys(capabilities), &(&1 in @reserved)),
      do: {:error, :reserved_capability},
      else: :ok
  end

  defp bundle_requirements(%FrozenBundle{} = bundle, capabilities, kind, private_capabilities) do
    missing =
      missing_capability_requirements(
        bundle,
        Map.keys(capabilities),
        kind,
        private_capabilities
      )

    if missing == [],
      do: :ok,
      else: {:error, {:missing_capability_requirement, missing}}
  end

  defp bundle_requirements(_bundle, _capabilities, _kind, _private_capabilities), do: :ok

  defp implicit_capabilities(:workflow, private_capabilities),
    do: private_capabilities ++ @workflow_implicit

  defp implicit_capabilities(:mission, _private_capabilities),
    do: ~w(runtime-usage runtime-remaining cap-list cap-describe)

  defp workflow_private_capabilities(bundle, authorization) do
    if Library.shipped_or_verified_override_component?(bundle, "agent.core", authorization),
      do: @agent_core_private,
      else: []
  end

  defp capability_metadata(%Capability{} = capability), do: Capability.metadata(capability)

  defp capability_metadata(%RoutedCapability{} = capability),
    do: RoutedCapability.metadata(capability)
end
