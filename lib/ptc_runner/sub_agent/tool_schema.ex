defmodule PtcRunner.SubAgent.ToolSchema do
  @moduledoc """
  Converts Tool structs to OpenAI-format JSON Schema tool definitions.

  Used by `:tool_calling` mode to provide tool schemas to the LLM API.
  """

  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.Tool

  @doc """
  Convert a tools map to a list of OpenAI-format tool definitions.

  Each tool is converted to a map with `"type" => "function"` and
  a `"function"` key containing name, description, and parameters schema.

  ## Examples

      iex> tools = %{"search" => fn _ -> [] end}
      iex> defs = PtcRunner.SubAgent.ToolSchema.to_tool_definitions(tools)
      iex> length(defs)
      1
      iex> hd(defs)["function"]["name"]
      "search"

  """
  @spec to_tool_definitions(map()) :: [map()]
  def to_tool_definitions(tools) when is_map(tools) do
    Enum.map(tools, fn {name, format} ->
      case Tool.new(name, format) do
        {:ok, tool} -> to_tool_definition(tool)
        {:error, _} -> build_definition(to_string(name), nil, nil)
      end
    end)
  end

  @doc """
  Convert a single Tool struct to an OpenAI-format tool definition.

  ## Examples

      iex> {:ok, tool} = PtcRunner.Tool.new("greet", {fn _ -> "hi" end, signature: "(name :string) -> :string", description: "Greet someone"})
      iex> defn = PtcRunner.SubAgent.ToolSchema.to_tool_definition(tool)
      iex> defn["function"]["name"]
      "greet"
      iex> defn["function"]["parameters"]["properties"]["name"]
      %{"type" => "string"}

  """
  @spec to_tool_definition(Tool.t()) :: map()
  def to_tool_definition(%Tool{} = tool) do
    parameters = build_parameters(tool.signature)
    build_definition(tool.name, tool.description, parameters)
  end

  # Build parameters schema from a signature string.
  # Returns the JSON Schema for parameters, or empty object if no signature.
  defp build_parameters(nil), do: %{"type" => "object", "properties" => %{}}

  defp build_parameters(sig_str) when is_binary(sig_str) do
    case Signature.parse(sig_str) do
      {:ok, {:signature, params, _return_type}} ->
        params_to_json_schema(params)

      {:error, _} ->
        %{"type" => "object", "properties" => %{}}
    end
  end

  # Convert signature params list to JSON Schema object
  defp params_to_json_schema([]) do
    %{"type" => "object", "properties" => %{}}
  end

  defp params_to_json_schema(params) do
    {properties, required} =
      Enum.reduce(params, {%{}, []}, fn {name, type}, {props, req} ->
        {inner_type, is_optional} = Signature.unwrap_optional(type)
        schema = Signature.type_to_json_schema(inner_type)
        props = Map.put(props, name, schema)
        req = if is_optional, do: req, else: [name | req]
        {props, req}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.reverse(required)
    }
  end

  # Build the full tool definition map
  defp build_definition(name, description, parameters) do
    func = %{"name" => name}
    func = if description, do: Map.put(func, "description", description), else: func

    func =
      if parameters,
        do: Map.put(func, "parameters", parameters),
        else: Map.put(func, "parameters", %{"type" => "object", "properties" => %{}})

    %{"type" => "function", "function" => func}
  end
end
