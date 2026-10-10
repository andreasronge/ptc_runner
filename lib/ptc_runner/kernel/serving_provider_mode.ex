defmodule PtcRunner.Kernel.ServingProviderMode do
  @moduledoc false
  alias PtcRunner.Kernel.MCPWarmAcquisition

  @spec classify([map()], PtcRunner.Kernel.InstallationCatalog.t()) ::
          :cold | :warm | :unsupported
  def classify(declarations, catalog) do
    sources =
      Enum.map(declarations, &Map.get(Map.get(catalog.descriptors, &1.name, %{}), :source))

    cond do
      Enum.any?(sources, &(&1 in [:ptc_private_trace_snapshot, :ptc_inspection_snapshot])) ->
        :unsupported

      sources != [] and Enum.all?(sources, &(&1 == :ptc_trace_snapshot)) ->
        :cold

      :ptc_trace_snapshot in sources ->
        :unsupported

      Enum.all?(declarations, &MCPWarmAcquisition.supported?(&1, catalog)) ->
        :warm

      true ->
        :unsupported
    end
  end
end
