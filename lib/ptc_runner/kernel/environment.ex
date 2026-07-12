defmodule PtcRunner.Kernel.Environment do
  @moduledoc false

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.JSONValue

  @reserved ~w(kernel-eval runtime-usage runtime-remaining cap-list cap-describe workflow-annotate)

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
