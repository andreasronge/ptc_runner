defmodule PtcRunnerMcp.CatalogDescription do
  @moduledoc """
  Mode-aware catalog description rendering for the `lisp_eval`
  MCP tool description.

  Per `Plans/ptc-runner-mcp-catalog-exposure.md` §5-§6, the catalog
  section of the tool description varies based on `catalog_mode`
  (auto|inline|lazy), upstream catalog availability, and size
  thresholds. This module resolves the effective mode and renders the
  appropriate description fragment.

  The existing `Upstream.Catalog` module retains its rendering for the
  detailed per-tool signature format. This module produces compact dynamic
  catalog tails: one-line-per-tool signatures in inline mode, or configured
  server names only in lazy mode. Static discovery guidance is front-loaded
  by the prompt cards that include this dynamic tail.
  """

  alias PtcRunnerMcp.CatalogConfig
  alias PtcRunnerMcp.Upstream.Catalog, as: UpstreamCatalog

  @inline_description_max_chars 120

  @type snapshot_entry :: %{
          required(:name) => String.t(),
          required(:tools) => [map()] | nil,
          optional(:impl) => module() | nil,
          optional(:metadata) => map()
        }

  @doc """
  Returns the catalog description fragment for the `lisp_eval`
  tool description, or `nil` if no catalog should be rendered.

  Reads the frozen snapshot and config, resolves the effective mode,
  and renders the appropriate description.
  """
  @spec render() :: String.t() | nil
  def render do
    entries = UpstreamCatalog.frozen_snapshot()

    case entries do
      [] -> nil
      _ -> render_for_entries(entries, CatalogConfig.get())
    end
  end

  @doc """
  Renders the catalog description for explicit entries and config.

  Used directly by tests to exercise rendering without persistent_term.
  """
  @spec render_for_entries([snapshot_entry()], CatalogConfig.t()) :: String.t() | nil
  def render_for_entries([], _config), do: nil

  def render_for_entries(entries, config) do
    case resolve_mode(entries, config) do
      {:inline, warnings} ->
        render_inline(entries, warnings, config)

      :lazy ->
        render_lazy(entries)
    end
  end

  @doc """
  Resolves the effective catalog mode from entries and config.

  Returns `{:inline, warnings}` or `:lazy`. Warnings is a list of
  server names whose catalogs are unknown (only populated when forced
  inline encounters unknown catalogs).
  """
  @spec resolve_mode([snapshot_entry()], CatalogConfig.t()) ::
          {:inline, [String.t()]} | :lazy
  def resolve_mode(entries, config) do
    case config.catalog_mode do
      :lazy ->
        :lazy

      :inline ->
        unknown = unknown_servers(entries)

        {:inline, unknown}

      :auto ->
        resolve_auto(entries, config)
    end
  end

  defp resolve_auto(entries, config) do
    if has_unknown_catalogs?(entries) do
      :lazy
    else
      total_tools = count_tools(entries)

      if total_tools > config.catalog_inline_max_tools do
        :lazy
      else
        inline_text = render_inline_body(entries, :signature_only)

        if String.length(inline_text) > config.catalog_inline_max_chars do
          :lazy
        else
          {:inline, []}
        end
      end
    end
  end

  # -- Inline rendering (§6.2) --

  defp render_inline(entries, [], config) do
    render_inline_body(entries, description_mode(entries, config))
  end

  defp render_inline(entries, unknown_servers, config) do
    body = render_inline_body(entries, description_mode(entries, config))
    warnings = render_unknown_warnings(unknown_servers)

    body <> "\n\n" <> warnings
  end

  defp render_inline_body(entries, description_mode) do
    server_blocks =
      entries
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", &render_inline_server(&1, description_mode))

    "Configured upstream MCP servers:\n" <> server_blocks
  end

  defp render_inline_server(%{name: server, tools: tools} = entry, description_mode)
       when is_list(tools) and tools != [] do
    header = render_server_header(entry)
    tool_lines = Enum.map_join(tools, "\n", &render_inline_tool(server, &1, description_mode))
    header <> "\n  Tools:\n" <> tool_lines
  end

  defp render_inline_server(entry, _description_mode), do: render_server_header(entry)

  defp render_inline_tool(server, tool, description_mode) do
    name = tool_field(tool, :name, "unknown")
    input_schema = tool_schema(tool, :input_schema)
    output_schema = tool_schema(tool, :output_schema)
    description = tool_field(tool, :description, "")
    args = render_args(input_schema)
    output = render_output(output_schema)
    desc_part = render_inline_description(description, description_mode)
    "  - #{server}.#{name}(#{args})#{output}#{desc_part}"
  end

  defp description_mode(entries, config) do
    with_descriptions = render_inline_body(entries, :with_descriptions)

    if String.length(with_descriptions) <= config.catalog_inline_max_chars do
      :with_descriptions
    else
      :signature_only
    end
  end

  defp render_inline_description(_description, :signature_only), do: ""

  defp render_inline_description(description, :with_descriptions) do
    description
    |> compact_description()
    |> truncate(@inline_description_max_chars)
    |> case do
      "" -> ""
      desc -> " #{desc}"
    end
  end

  # -- Lazy rendering (§6.3) --

  defp render_lazy(entries) do
    server_names =
      entries
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join(", ", & &1.name)

    "Configured upstream MCP servers: " <> server_names
  end

  defp render_server_header(%{name: name, tools: nil} = entry) do
    desc = server_description(entry)
    "- #{name}: #{desc}Catalog loads on first use."
  end

  defp render_server_header(%{name: name, tools: []} = entry) do
    desc = server_description(entry)
    "- #{name}: #{desc}0 tools."
  end

  defp render_server_header(%{name: name, tools: tools} = entry) when is_list(tools) do
    desc = server_description(entry)
    capabilities = server_capabilities(entry)
    tool_count = length(tools)
    "- #{name}: #{desc}#{tool_count} tools.#{capabilities}"
  end

  # -- Shared helpers --

  defp server_description(%{metadata: %{description: desc}})
       when is_binary(desc) and desc != "" do
    compact_description(desc) <> ". "
  end

  defp server_description(%{metadata: %{"description" => desc}})
       when is_binary(desc) and desc != "" do
    compact_description(desc) <> ". "
  end

  defp server_description(_), do: ""

  defp server_capabilities(%{metadata: %{capabilities: caps}})
       when is_list(caps) and caps != [] do
    " " <> Enum.join(caps, ", ") <> "."
  end

  defp server_capabilities(%{metadata: %{"capabilities" => caps}})
       when is_list(caps) and caps != [] do
    " " <> Enum.join(caps, ", ") <> "."
  end

  defp server_capabilities(_), do: ""

  defp compact_description(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(text, max_chars) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "..."
    else
      text
    end
  end

  defp render_unknown_warnings(servers) do
    lines = Enum.map_join(servers, "\n", &"Warning: catalog for \"#{&1}\" not loaded yet.")
    lines
  end

  defp has_unknown_catalogs?(entries) do
    Enum.any?(entries, fn entry -> entry.tools == nil end)
  end

  defp unknown_servers(entries) do
    entries
    |> Enum.filter(fn entry -> entry.tools == nil end)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp count_tools(entries) do
    Enum.reduce(entries, 0, fn entry, acc ->
      case entry.tools do
        nil -> acc
        tools when is_list(tools) -> acc + length(tools)
      end
    end)
  end

  defp tool_field(tool, key, default) do
    case tool do
      %{^key => v} -> v
      _ -> Map.get(tool, to_string(key), default)
    end
  end

  defp tool_schema(tool, key) do
    {string_key, camel_atom, camel_string} = schema_keys(key)

    case tool do
      %{^key => schema} when is_map(schema) -> schema
      %{^camel_atom => schema} when is_map(schema) -> schema
      _ -> Map.get(tool, string_key, Map.get(tool, camel_string, %{}))
    end
  end

  defp schema_keys(:input_schema), do: {"input_schema", :inputSchema, "inputSchema"}
  defp schema_keys(:output_schema), do: {"output_schema", :outputSchema, "outputSchema"}

  defp render_args(schema) when is_map(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))
    required = Map.get(schema, "required", Map.get(schema, :required, []))

    properties_by_string =
      Map.new(properties, fn {key, value} -> {to_string(key), value} end)

    required_names =
      required
      |> Enum.map(&to_string/1)

    required_set = MapSet.new(required_names)

    optional_names =
      properties_by_string
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(required_set, &1))
      |> Enum.sort()

    (required_names ++ optional_names)
    |> Enum.map_join(", ", fn name ->
      optional = if MapSet.member?(required_set, name), do: "", else: "?"
      "#{name}: #{render_arg_type(Map.get(properties_by_string, name, %{}))}#{optional}"
    end)
  end

  defp render_args(_), do: ""

  defp render_output(schema) when is_map(schema) do
    case render_output_type(schema) do
      "" -> ""
      type -> " -> #{type}"
    end
  end

  defp render_output(_), do: ""

  defp render_arg_type(schema) when is_map(schema) do
    cond do
      Map.has_key?(schema, "const") or Map.has_key?(schema, :const) ->
        "const"

      is_list(Map.get(schema, "enum", Map.get(schema, :enum))) ->
        "enum"

      true ->
        case Map.get(schema, "type", Map.get(schema, :type)) do
          "string" -> "string"
          "integer" -> "integer"
          "number" -> "number"
          "boolean" -> "boolean"
          "object" -> "object"
          "array" -> "array"
          list when is_list(list) -> Enum.map_join(list, "|", &to_string/1)
          nil -> infer_arg_type(schema)
          other -> to_string(other)
        end
    end
  end

  defp render_arg_type(_), do: "any"

  defp infer_arg_type(schema) do
    cond do
      Map.has_key?(schema, "properties") or Map.has_key?(schema, :properties) -> "object"
      Map.has_key?(schema, "items") or Map.has_key?(schema, :items) -> "array"
      true -> "any"
    end
  end

  defp render_output_type(schema) when is_map(schema) do
    case Map.get(schema, "type", Map.get(schema, :type)) do
      "string" -> ":string"
      "integer" -> ":int"
      "number" -> ":float"
      "boolean" -> ":bool"
      "array" -> "[:any]"
      "object" -> render_output_object(schema)
      _ -> ""
    end
  end

  defp render_output_type(_), do: ""

  defp render_output_object(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    if is_map(properties) and map_size(properties) > 0 do
      required =
        case Map.get(schema, "required", Map.get(schema, :required, [])) do
          list when is_list(list) -> Enum.map(list, &to_string/1)
          _ -> []
        end

      fields =
        properties
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.take(5)
        |> Enum.map_join(", ", fn {key, value} ->
          key = to_string(key)
          optional = if key in required, do: "", else: "?"
          "#{key} #{render_output_type(value)}#{optional}"
        end)

      "{#{fields}}"
    else
      ":map"
    end
  end
end
