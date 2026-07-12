defmodule PtcRunner.Kernel.Environment do
  @moduledoc false

  alias PtcRunner.Kernel.Capability

  @reserved MapSet.new(["kernel-eval", "runtime/usage", "runtime/remaining"])

  def assemble(bundle, capabilities, data, kind)
      when kind in [:workflow, :mission] and is_map(data) do
    with :ok <- valid_bundle(bundle),
         {:ok, capability_map} <- capability_map(capabilities),
         :ok <- reserved_names(kind, capability_map) do
      {:ok, %{bundle: bundle, capabilities: capability_map, data: data}}
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
  defp valid_bundle(bundle) when is_map(bundle), do: :ok
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

  defp reserved_names(:workflow, _capabilities), do: :ok

  defp reserved_names(:mission, capabilities) do
    if Enum.any?(Map.keys(capabilities), &MapSet.member?(@reserved, &1)),
      do: {:error, :reserved_capability},
      else: :ok
  end
end
