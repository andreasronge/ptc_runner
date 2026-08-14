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

  @reserved ~w(kernel-check-source kernel-eval kernel-mission-inventory kernel-mission-model-context kernel-result-contract kernel-runtime-limit-failure runtime-usage runtime-remaining cap-list cap-describe workflow-annotate)
  @workflow_implicit ~w(kernel-check-source kernel-eval kernel-mission-inventory kernel-mission-model-context kernel-result-contract runtime-usage runtime-remaining cap-list cap-describe workflow-annotate)

  @doc "Validates common environment fields and returns normalized attributes."
  def assemble(bundle, capabilities, data, kind)
      when kind in [:workflow, :mission] do
    with :ok <- valid_bundle(bundle),
         true <- JSONValue.map?(data),
         {:ok, capability_map} <- capability_map(capabilities),
         :ok <- reserved_names(kind, capability_map),
         :ok <- bundle_requirements(bundle, capability_map, kind) do
      {:ok, %{bundle: bundle, capabilities: capability_map, data: data}}
    else
      false -> {:error, :invalid_environment_data}
      error -> error
    end
  end

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

  @doc "Returns sorted model-visible capability metadata for one environment."
  def metadata(%{capabilities: capabilities}) do
    capabilities
    |> Map.values()
    |> Enum.filter(& &1.model_visible)
    |> Enum.map(&capability_metadata/1)
    |> Enum.sort_by(& &1.name)
  end

  @doc false
  @spec capability_requirements(FrozenBundle.t() | nil) :: [binary()]
  def capability_requirements(%FrozenBundle{prelude: %{exports: exports}}) do
    exports
    |> Enum.flat_map(&Map.get(&1, :tool_refs, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def capability_requirements(nil), do: []

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

  defp bundle_requirements(%FrozenBundle{} = bundle, capabilities, kind) do
    granted_names =
      Map.new(Map.keys(capabilities) ++ implicit_capabilities(kind, bundle), &{&1, true})

    missing =
      bundle
      |> capability_requirements()
      |> Enum.reject(&Map.has_key?(granted_names, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_capability_requirement, missing}}
  end

  defp bundle_requirements(_bundle, _capabilities, _kind), do: :ok

  defp implicit_capabilities(:workflow, bundle) do
    if Library.shipped_component?(bundle, "agent.core"),
      do: ["kernel-runtime-limit-failure" | @workflow_implicit],
      else: @workflow_implicit
  end

  defp implicit_capabilities(:mission, _bundle),
    do: ~w(runtime-usage runtime-remaining cap-list cap-describe)

  defp capability_metadata(%Capability{} = capability), do: Capability.metadata(capability)

  defp capability_metadata(%RoutedCapability{} = capability),
    do: RoutedCapability.metadata(capability)
end
