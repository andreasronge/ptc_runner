defmodule PtcRunner.SubAgent.SystemPrompt.Tools do
  @moduledoc """
  Tool schema section generation for SubAgent prompts.

  Generates the Available Tools section that shows all available tools
  with their signatures and descriptions.
  """

  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.Tool

  @doc """
  Generate the tool schemas section.

  Shows all available tools with their signatures and descriptions.

  ## Parameters

  - `tools` - Map of tool name to function
  - `multi_turn?` - Whether this is a multi-turn context (default: true)

  ## Returns

  A string containing the tool schemas section.

  ## Examples

      iex> tools = %{"add" => fn %{x: x, y: y} -> x + y end}
      iex> schemas = PtcRunner.SubAgent.SystemPrompt.Tools.generate(tools)
      iex> schemas =~ "# Available Tools"
      true

  """
  @spec generate(map(), boolean()) :: String.t()
  def generate(tools, multi_turn? \\ true)

  def generate(tools, _multi_turn?) when map_size(tools) == 0 do
    # No user-defined tools - return/fail are already documented in system prompt
    """
    # Available Tools

    No tools available.
    """
  end

  def generate(tools, _multi_turn?) do
    # Normalize tools to %Tool{} structs so signatures are rendered
    normalized_tools =
      tools
      |> Enum.map(fn {name, format} -> {name, normalize_tool_for_prompt(name, format)} end)
      |> Map.new()

    # Format user tools only - return/fail are already documented in system prompt
    tool_docs =
      normalized_tools
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("\n\n", fn {name, tool} -> format_tool(name, tool) end)

    """
    # Available Tools

    ## Tools you can call

    #{tool_docs}
    """
  end

  # ============================================================
  # Private Helpers - Tool Formatting
  # ============================================================

  # Fallback for tool names without struct
  defp format_tool(name) do
    """
    ### #{name}
    ```
    #{name}(args :map) -> :any
    ```
    User-defined tool. Check implementation for details.
    """
  end

  # 2-arity format_tool for tools with struct
  defp format_tool(name, %Tool{signature: sig, description: desc})
       when not is_nil(sig) do
    # User-defined tool with explicit signature
    desc_line = if desc, do: desc, else: "User-defined tool."
    example = generate_tool_example(name, sig)
    # Simplify signature display for single map parameters
    display_sig = simplify_signature_for_display(sig)

    """
    ### #{name}
    ```
    tool/#{name}#{display_sig}
    ```
    #{desc_line}
    #{example}
    """
  end

  defp format_tool(name, _tool) do
    # For user-defined tools without signature, show basic signature
    format_tool(name)
  end

  # ============================================================
  # Private Helpers - Signature Simplification
  # ============================================================

  # Simplify signatures with a single map parameter for clearer display.
  # When a function has a single map parameter with named fields like:
  #   (args {query :string, limit :int?}) -> ...
  # We display it as:
  #   ({query :string, limit :int?}) -> ...
  #
  # This matches how the tool is actually called: (tool/search {:query "..."})
  defp simplify_signature_for_display(sig) do
    case Signature.parse(sig) do
      {:ok, {:signature, [{_param_name, {:map, fields}}], return_type}} when is_list(fields) ->
        # Single map parameter - render fields directly without the param name
        fields_str = render_map_fields(fields)
        return_str = Signature.Renderer.render_type(return_type)
        "({#{fields_str}}) -> #{return_str}"

      _ ->
        # Keep original signature for other cases
        sig
    end
  end

  defp render_map_fields(fields) do
    Enum.map_join(fields, ", ", fn {name, type} ->
      "#{name} #{Signature.Renderer.render_type(type)}"
    end)
  end

  # ============================================================
  # Private Helpers - Tool Normalization
  # ============================================================

  # Normalize tool format to %Tool{} struct for prompt rendering
  defp normalize_tool_for_prompt(_name, %Tool{} = tool), do: tool

  defp normalize_tool_for_prompt(name, format) do
    case Tool.new(name, format) do
      {:ok, tool} -> tool
      {:error, _reason} -> nil
    end
  end

  # ============================================================
  # Private Helpers - Example Generation
  # ============================================================

  # Generate usage example for a tool based on its signature
  defp generate_tool_example(name, sig) do
    case Signature.parse(sig) do
      {:ok, {:signature, [], _return_type}} ->
        # No parameters
        "Example: `(tool/#{name})`"

      {:ok, {:signature, params, _return_type}} ->
        args = generate_example_args(params)
        "Example: `(tool/#{name} {#{args}})`"

      {:error, _} ->
        ""
    end
  end

  # When a single map parameter with named fields is used, show the inner fields directly.
  # This handles the common pattern where tools accept %{field1: ..., field2: ...}
  # and the signature shows (args {field1 :type, field2 :type}).
  #
  # Example: `(args {query :string})` → `:query "..."`
  #          NOT → `:args {...}`
  defp generate_example_args([{_param_name, {:map, fields}}]) when is_list(fields) do
    Enum.map_join(fields, " ", fn {field_name, type} ->
      ":#{field_name} #{generate_example_value(type)}"
    end)
  end

  defp generate_example_args(params) do
    Enum.map_join(params, " ", fn {param_name, type} ->
      ":#{param_name} #{generate_example_value(type)}"
    end)
  end

  defp generate_example_value(:string), do: "\"...\""
  defp generate_example_value(:int), do: "10"
  defp generate_example_value(:float), do: "1.0"
  defp generate_example_value(:bool), do: "true"
  defp generate_example_value(:keyword), do: ":value"
  defp generate_example_value(:any), do: "..."
  defp generate_example_value(:map), do: "{}"
  defp generate_example_value({:optional, type}), do: generate_example_value(type)
  defp generate_example_value({:list, _type}), do: "[]"
  defp generate_example_value({:map, _fields}), do: "{...}"
end
