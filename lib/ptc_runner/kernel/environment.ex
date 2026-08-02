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
  alias PtcRunner.Kernel.SafeMetadata

  @reserved ~w(
    kernel-check-source kernel-eval kernel-mission-inventory
    kernel-mission-model-context kernel-result-contract
    kernel-result-contract-description runtime-usage runtime-remaining
    cap-list cap-describe workflow-annotate
  )

  @doc "Validates common environment fields and returns normalized attributes."
  def assemble(bundle, capabilities, data, kind)
      when kind in [:workflow, :mission] do
    with :ok <- valid_bundle(bundle),
         :ok <- consistent_annotations(bundle),
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
  Returns the closed vocabularies the environment's components declare.

  A namespace declares the application failure kinds and annotation types its
  own code emits, so the vocabulary is covered by the component source hash
  and cannot drift from the `fail`/`annotate` calls beside it. The union is
  taken across namespaces and filtered here rather than trusted: a name that
  is not declarable, or that would shadow a framework failure kind, is
  dropped, so the worst a malformed declaration can do is leave a value
  fingerprinted or an annotation rejected.

  Merging annotation types is safe because `assemble/4` has already refused a
  bundle whose namespaces declare one type with conflicting counters.
  """
  @spec vocabulary(term()) :: %{failure_kinds: [binary()], annotations: %{binary() => [binary()]}}
  def vocabulary(%{bundle: %FrozenBundle{prelude: %{metadata: %{namespaces: namespaces}}}})
      when is_map(namespaces) do
    namespaces
    |> Map.values()
    |> Enum.reduce(%{failure_kinds: [], annotations: %{}}, fn declared, acc ->
      %{
        failure_kinds:
          acc.failure_kinds ++
            Enum.filter(
              Map.get(declared, :failure_kinds, []),
              &SafeMetadata.declarable_failure_kind?/1
            ),
        annotations: Map.merge(acc.annotations, declarable_annotations(declared))
      }
    end)
    |> Map.update!(:failure_kinds, &(&1 |> Enum.uniq() |> Enum.sort()))
  end

  def vocabulary(_environment), do: %{failure_kinds: [], annotations: %{}}

  # Two namespaces declaring one annotation type with different counters is a
  # conflict, not a merge: keeping either list by fold order would silently
  # reject the other namespace's own annotations, and a rejected annotation
  # emits no event and counts no protocol error, so nothing would surface it.
  # Refused here for the same reason the prelude compiler refuses a redeclared
  # namespace. Agreeing declarations are fine, and counter order is not part
  # of the declaration.
  defp consistent_annotations(%FrozenBundle{
         prelude: %{metadata: %{namespaces: namespaces}}
       })
       when is_map(namespaces) do
    conflict? =
      namespaces
      |> Map.values()
      |> Enum.flat_map(&Map.to_list(declarable_annotations(&1)))
      |> Enum.group_by(&elem(&1, 0), &Enum.sort(elem(&1, 1)))
      |> Enum.any?(fn {_type, declarations} -> length(Enum.uniq(declarations)) > 1 end)

    if conflict?, do: {:error, :conflicting_annotation_declaration}, else: :ok
  end

  defp consistent_annotations(_bundle), do: :ok

  defp declarable_annotations(declared) do
    declared
    |> Map.get(:annotations, %{})
    |> Enum.filter(fn {type, counters} -> SafeMetadata.declarable_annotation?(type, counters) end)
    |> Map.new()
  end

  @doc """
  Returns the whole-environment capability view.

  Dispatch and the runtime routes read nothing but `:capabilities`. Callbacks
  handed to a sandboxed evaluation must capture a view rather than the
  environment itself: the spawn copy does not preserve sharing, so capturing
  the environment would copy its frozen bundle once per capability callback.

  Only the discovery routes need every capability. A callback that dispatches
  one capability must capture `capability_view/2` instead — capturing the whole
  map from each of them costs the hand-over `O(capabilities²)`, which a
  tool-rich MCP environment blows the sandbox setup ceiling with.
  """
  # The whole-environment view also carries the declared annotation vocabulary.
  # The runtime annotate route needs it and must not capture the environment —
  # the bundle behind it dominates the spawn copy. The vocabulary is at most 16
  # types of at most 16 bounded names, so carrying it costs nothing measurable.
  def capability_view(%{capabilities: capabilities} = environment),
    do: %{capabilities: capabilities, annotations: vocabulary(environment).annotations}

  @doc """
  Returns the single-capability view one dispatch callback needs.

  `Dispatcher.dispatch/7` resolves `name` against the `:capabilities` of the
  value it is given, so a callback bound to one capability can carry only that
  capability and dispatch identically.
  """
  def capability_view(name, %Capability{} = capability) when is_binary(name),
    do: %{capabilities: %{name => capability}}

  @doc "Returns sorted model-visible capability metadata for one environment."
  def metadata(%{capabilities: capabilities}) do
    capabilities
    |> Map.values()
    |> Enum.filter(& &1.model_visible)
    |> Enum.map(&Capability.metadata/1)
    |> Enum.sort_by(& &1.name)
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

  defp bundle_requirements(%{prelude: %{exports: exports}}, capabilities, kind) do
    granted_names = Map.new(Map.keys(capabilities) ++ implicit_capabilities(kind), &{&1, true})

    missing =
      exports
      |> Enum.flat_map(&Map.get(&1, :tool_refs, []))
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(granted_names, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_capability_requirement, Enum.sort(missing)}}
  end

  defp bundle_requirements(_bundle, _capabilities, _kind), do: :ok

  defp implicit_capabilities(:workflow), do: @reserved

  defp implicit_capabilities(:mission),
    do: ~w(runtime-usage runtime-remaining cap-list cap-describe)
end
