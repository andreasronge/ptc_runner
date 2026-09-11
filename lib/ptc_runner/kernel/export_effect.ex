defmodule PtcRunner.Kernel.ExportEffect do
  @moduledoc false

  @spec resolve(PtcRunner.Lisp.Prelude.Export.t(), %{binary() => atom()}) ::
          :read | :write | :unknown
  def resolve(export, capability_effects) do
    dependency_effects =
      (export.tool_refs ++ required_names(export.requires))
      |> Enum.uniq()
      |> Enum.map(&Map.get(capability_effects, &1, :unknown))

    join([export.effect | dependency_effects])
  end

  defp required_names(requirements) do
    Enum.flat_map(requirements, fn
      "tool:" <> name -> [name]
      _requirement -> []
    end)
  end

  defp join(effects) do
    cond do
      :write in effects -> :write
      :unknown in effects -> :unknown
      :read in effects -> :read
      true -> :unknown
    end
  end
end
