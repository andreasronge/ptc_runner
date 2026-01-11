defmodule PtcRunner.SubAgent.SystemPrompt.Tools do
  @moduledoc """
  Tool schema section generation for SubAgent prompts.

  Generates the Available Tools section that shows all available tools
  with their signatures and descriptions. Optionally includes a separate
  "Tools for planning (do not call)" section for tools in the catalog.
  """

  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.Tool

  @doc """
  Generate the tool schemas section.

  Shows all available tools with their signatures and descriptions.
  Optionally includes a separate "Tools for planning (do not call)" section
  for tools in the catalog.

  ## Parameters

  - `tools` - Map of tool name to function
  - `tool_catalog` - Optional map of tool names for planning (default: nil)

  ## Returns

  A string containing the tool schemas section.

  ## Examples

      iex> tools = %{"add" => fn %{x: x, y: y} -> x + y end}
      iex> schemas = PtcRunner.SubAgent.SystemPrompt.Tools.generate(tools)
      iex> schemas =~ "# Available Tools"
      true

      iex> tools = %{"search" => fn _ -> [] end}
      iex> catalog = %{"email_agent" => nil}
      iex> schemas = PtcRunner.SubAgent.SystemPrompt.Tools.generate(tools, catalog)
      iex> schemas =~ "## Tools for planning (do not call)"
      true

  """
  @spec generate(map(), map() | nil, boolean()) :: String.t()
  def generate(tools, tool_catalog \\ nil, multi_turn? \\ true)

  def generate(tools, tool_catalog, multi_turn?) when map_size(tools) == 0 do
    # Only show return/fail in multi-turn mode
    standard_tools = if multi_turn?, do: format_return_fail_tools(), else: ""

    callable_section =
      if standard_tools == "" do
        """
        # Available Tools

        No tools available.
        """
      else
        """
        # Available Tools

        ## Tools you can call

        #{standard_tools}
        """
      end

    # Add catalog section if present
    catalog_section = generate_catalog_section(tool_catalog)

    if catalog_section == "" do
      callable_section
    else
      callable_section <> "\n" <> catalog_section
    end
  end

  def generate(tools, tool_catalog, multi_turn?) do
    # Normalize tools to %Tool{} structs so signatures are rendered
    normalized_tools =
      tools
      |> Enum.map(fn {name, format} -> {name, normalize_tool_for_prompt(name, format)} end)
      |> Map.new()

    # Format user tools
    tool_docs =
      normalized_tools
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("\n\n", fn {name, tool} -> format_tool(name, tool) end)

    # Only add return/fail in multi-turn mode
    standard_tools = if multi_turn?, do: format_return_fail_tools(tools), else: ""

    tools_section =
      if tool_docs == "" do
        standard_tools
      else
        tool_docs <>
          if standard_tools != "", do: "\n\n" <> standard_tools, else: ""
      end

    callable_section = """
    # Available Tools

    ## Tools you can call

    #{tools_section}
    """

    # Add catalog section if present
    catalog_section = generate_catalog_section(tool_catalog)

    if catalog_section == "" do
      callable_section
    else
      callable_section <> "\n" <> catalog_section
    end
  end

  # Format return/fail tools, optionally excluding if already present in user tools
  defp format_return_fail_tools(user_tools \\ %{}) do
    [
      unless Map.has_key?(user_tools, "return") do
        format_tool("return")
      end,
      unless Map.has_key?(user_tools, "fail") do
        format_tool("fail")
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # ============================================================
  # Private Helpers - Tool Formatting
  # ============================================================

  # 1-arity format_tool for special tools and fallback
  defp format_tool("return") do
    """
    ### return
    ```
    return(data :any) -> :exit-success
    ```
    Complete the mission successfully. Return the required data.
    """
  end

  defp format_tool("fail") do
    """
    ### fail
    ```
    fail(error {:reason :keyword, :message :string, :op :string?, :details :map?}) -> :exit-error
    ```
    Terminate with an error. Use when the mission cannot be completed.
    """
  end

  defp format_tool(name) do
    # Fallback for tool names without struct (used by tool_catalog)
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
    ctx/#{name}#{display_sig}
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
  # Private Helpers - Catalog Section
  # ============================================================

  defp generate_catalog_section(nil), do: ""
  defp generate_catalog_section(tool_catalog) when map_size(tool_catalog) == 0, do: ""

  defp generate_catalog_section(tool_catalog) do
    catalog_tools =
      tool_catalog
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join("\n\n", fn name -> format_tool(name) end)

    """
    ## Tools for planning (do not call)

    These tools are shown for context but cannot be called directly:

    #{catalog_tools}
    """
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
  # This matches how the tool is actually called: (ctx/search {:query "..."})
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
        "Example: `(ctx/#{name})`"

      {:ok, {:signature, params, _return_type}} ->
        args = generate_example_args(params)
        "Example: `(ctx/#{name} {#{args}})`"

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
