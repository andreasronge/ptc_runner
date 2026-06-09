defmodule PtcRunner.Upstream.Effect do
  @moduledoc false

  alias PtcRunner.Upstream.Runtime

  @type effect :: :read | :write | :unknown

  @spec classify(struct() | pid(), String.t(), String.t()) :: effect()
  def classify(runtime, server, tool) when is_binary(server) and is_binary(tool) do
    runtime
    |> Runtime.upstream(server)
    |> tool_entry(tool)
    |> classify_tool()
  end

  def classify(_runtime, _server, _tool), do: :unknown

  defp tool_entry(%{tools: tools}, tool) when is_list(tools) do
    Enum.find(tools, &(Map.get(&1, "name") == tool))
  end

  defp tool_entry(_upstream, _tool), do: nil

  defp classify_tool(%{"_ptc" => %{"transport" => "openapi", "method" => "GET"}}), do: :read

  defp classify_tool(%{"_ptc" => %{"transport" => "openapi", "method" => method}})
       when is_binary(method),
       do: :write

  defp classify_tool(%{"annotations" => %{"readOnlyHint" => true, "destructiveHint" => true}}),
    do: :unknown

  defp classify_tool(%{"annotations" => %{"readOnlyHint" => true}}), do: :read
  defp classify_tool(%{"annotations" => %{"destructiveHint" => true}}), do: :write
  defp classify_tool(_tool), do: :unknown
end
