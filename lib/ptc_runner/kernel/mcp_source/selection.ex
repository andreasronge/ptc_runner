defmodule PtcRunner.Kernel.MCPSource.Selection do
  @moduledoc false

  def normalize(installed, selection, context) do
    with true <- is_map(selection) and not is_struct(selection),
         catalog? <- Map.get(selection, "catalog", false),
         true <-
           (context.destination == :mission and catalog? == false) or
             (context.destination == :workflow and catalog? == true),
         true <-
           Map.keys(selection) -- ~w(allow catalog model_visible timeout_ms max_result_bytes) ==
             [],
         true <- is_boolean(catalog?),
         true <- read_only_installation?(installed) or Map.has_key?(selection, "allow"),
         public_names =
           Map.new(installed.tools, fn {_upstream, mapping} -> {mapping.as, mapping} end),
         allow when is_list(allow) and length(allow) in 1..128 <-
           Map.get(selection, "allow", public_names |> Map.keys() |> Enum.sort()),
         true <- Enum.all?(allow, &is_binary/1) and Enum.uniq(allow) == allow,
         true <- Enum.all?(allow, &Map.has_key?(public_names, &1)),
         installed_visible =
           Enum.filter(allow, fn name -> Map.fetch!(public_names, name).model_visible end),
         model_visible when is_list(model_visible) and length(model_visible) <= 128 <-
           Map.get(selection, "model_visible", installed_visible),
         true <-
           Enum.all?(model_visible, &is_binary/1) and
             Enum.uniq(model_visible) == model_visible,
         true <- Enum.all?(model_visible, &(&1 in allow)),
         timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 <-
           Map.get(
             selection,
             "timeout_ms",
             min(installed.timeout_ms, destination_timeout(context))
           ),
         true <- timeout_ms <= installed.timeout_ms,
         true <- timeout_ms <= destination_timeout(context),
         max_result_bytes when is_integer(max_result_bytes) and max_result_bytes > 0 <-
           Map.get(
             selection,
             "max_result_bytes",
             min(installed.max_result_bytes, context.limits.capability_result_bytes)
           ),
         true <- max_result_bytes <= installed.max_result_bytes,
         true <- max_result_bytes <= context.limits.capability_result_bytes do
      {:ok,
       %{
         allow: MapSet.new(allow),
         model_visible: MapSet.new(model_visible),
         timeout_ms: timeout_ms,
         max_result_bytes: max_result_bytes,
         catalog?: catalog?
       }}
    else
      _reason -> {:error, :invalid_mcp_selection}
    end
  end

  defp destination_timeout(%{destination: :mission, limits: limits}),
    do: limits.evaluation_timeout_ms

  defp destination_timeout(%{destination: :workflow, limits: limits}),
    do: limits.workflow_timeout_ms

  defp read_only_installation?(installed),
    do: Enum.all?(installed.tools, fn {_upstream, mapping} -> mapping.effect == :read end)
end
