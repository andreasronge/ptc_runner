defmodule PtcRunner.Kernel.InnerPrelude do
  @moduledoc false

  alias PtcRunner.Lisp.Prelude

  @spec validate(Prelude.t(), Prelude.t() | nil, map()) ::
          {:ok, MapSet.t(String.t())} | {:error, map()}
  def validate(%Prelude{}, nil, _mission_tools), do: {:ok, MapSet.new()}

  def validate(%Prelude{} = loop, %Prelude{} = inner, mission_tools) when is_map(mission_tools) do
    with :ok <- disjoint?(loop, inner),
         :ok <- safe_components?(inner),
         :ok <- safe_exports?(inner, mission_tools) do
      {:ok, inner.exports |> Enum.map(& &1.ref) |> MapSet.new()}
    end
  end

  defp disjoint?(loop, inner) do
    overlap = MapSet.intersection(MapSet.new(loop.namespaces), MapSet.new(inner.namespaces))
    loop_ids = component_ids(loop)
    component_overlap = MapSet.intersection(loop_ids, component_ids(inner))

    cond do
      MapSet.size(overlap) > 0 ->
        invalid(:namespace_overlap, MapSet.to_list(overlap))

      MapSet.size(component_overlap) > 0 ->
        invalid(:component_overlap, MapSet.to_list(component_overlap))

      true ->
        :ok
    end
  end

  defp safe_components?(inner) do
    forbidden =
      (inner.namespaces ++ MapSet.to_list(component_ids(inner)))
      |> Enum.filter(&agent_name?/1)

    if forbidden == [], do: :ok, else: invalid(:forbidden_agent_namespace, forbidden)
  end

  defp safe_exports?(inner, mission_tools) do
    Enum.reduce_while(inner.exports, :ok, fn export, :ok ->
      requirements = Map.get(export, :requires, [])
      tool_refs = Map.get(export, :tool_refs, [])

      cond do
        not is_nil(Map.get(export, :provider_ref)) ->
          {:halt, invalid(:upstream_export, export.ref)}

        Enum.any?(requirements, &String.starts_with?(to_string(&1), "upstream:")) ->
          {:halt, invalid(:upstream_requirement, export.ref)}

        Enum.any?(tool_refs, &(to_string(&1) == "call")) ->
          {:halt, invalid(:dynamic_upstream_dispatch, export.ref)}

        missing_tool(requirements, mission_tools) != nil ->
          {:halt,
           invalid(:missing_mission_tool, %{
             ref: export.ref,
             tool: missing_tool(requirements, mission_tools)
           })}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp missing_tool(requirements, mission_tools) do
    Enum.find_value(requirements, fn
      "tool:" <> tool -> if Map.has_key?(mission_tools, tool), do: nil, else: tool
      _ -> nil
    end)
  end

  defp component_ids(prelude) do
    prelude.metadata
    |> Map.get(:components, [])
    |> Enum.map(&Map.get(&1, :id))
    |> MapSet.new()
  end

  defp agent_name?(value) when is_binary(value),
    do: value == "agent" or String.starts_with?(value, "agent.")

  defp agent_name?(_value), do: false

  defp invalid(reason, offending),
    do:
      {:error,
       %{reason: :invalid_inner_prelude, details: %{reason: reason, offending: offending}}}
end
