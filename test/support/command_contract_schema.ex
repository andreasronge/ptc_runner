defmodule PtcRunner.TestSupport.CommandContractSchema do
  @moduledoc false

  alias PtcRunner.Kernel.CommandContract

  def envelope_schema_root do
    key = {__MODULE__, :root}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, root} = result <-
               JSV.build(CommandContract.schema(), atoms: false, warnings: :silent) do
          :persistent_term.put(key, result)
          {:ok, root}
        end

      result ->
        result
    end
  end

  def catalog_diagnostic_schema do
    %{"anyOf" => CommandContract.schema() |> diagnostic_members() |> Enum.uniq()}
  end

  defp diagnostic_members(
         %{"properties" => %{"phase" => %{"const" => _}, "code" => %{"const" => _}}} = schema
       ),
       do: [schema]

  defp diagnostic_members(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&diagnostic_members/1)

  defp diagnostic_members(value) when is_list(value),
    do: Enum.flat_map(value, &diagnostic_members/1)

  defp diagnostic_members(_value), do: []
end
