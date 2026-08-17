defmodule PtcGateway.Catalog do
  @moduledoc false

  @spec valid?(term()) :: boolean()
  def valid?(tools) when is_list(tools) do
    names = Enum.map(tools, & &1.name)
    Enum.all?(tools, &valid_tool?/1) and names == Enum.uniq(names)
  end

  def valid?(_tools), do: false

  @spec index([map()]) :: %{binary() => map()}
  def index(tools) when is_list(tools), do: Map.new(tools, &{&1.name, &1})

  defp valid_tool?(tool) do
    is_map(tool) and is_binary(tool.name) and tool.name != "" and
      is_binary(tool.description) and is_map(tool.input_schema) and
      is_map(tool.output_schema) and is_map(tool.meta) and
      is_function(tool.call, 1)
  end
end
