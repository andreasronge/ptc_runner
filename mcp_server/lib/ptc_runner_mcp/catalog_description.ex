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
    entries = Enum.sort_by(entries, & &1.name)

    discovery_blocks =
      [render_servers_snapshot(entries)] ++
        Enum.flat_map(entries, &render_inline_server(&1, description_mode)) ++
        render_doc_example(entries, description_mode)

    "Synthetic discovery snapshot for configured upstreams:\n\n" <>
      Enum.join(discovery_blocks, "\n\n")
  end

  defp render_inline_server(%{name: server, tools: tools}, description_mode)
       when is_list(tools) and tools != [] do
    lines =
      tools
      |> Enum.sort_by(&tool_field(&1, :name, "unknown"))
      |> Enum.map(&render_inline_tool(server, &1, description_mode))

    [render_command_result(~s|(dir #{lisp_string(server)} {:limit 20})|, lines)]
  end

  defp render_inline_server(_entry, _description_mode), do: []

  defp render_inline_tool(_server, tool, description_mode) do
    name = tool_field(tool, :name, "unknown")
    description = tool_field(tool, :description, "")

    case render_inline_description(description, description_mode) do
      "" -> name
      desc_part -> "#{name} - #{String.trim(desc_part)}"
    end
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
    entries = Enum.sort_by(entries, & &1.name)

    "Synthetic discovery snapshot for configured upstreams:\n\n" <>
      render_servers_snapshot(entries)
  end

  # -- Shared helpers --

  defp render_servers_snapshot(entries) do
    values = Enum.map(entries, &server_snapshot_map/1)

    render_command_result("(mcp/servers)", values)
  end

  defp server_snapshot_map(%{name: name, tools: tools} = entry) do
    %{
      "name" => name,
      "description" => server_description_text(entry),
      "tool_count" => if(is_list(tools), do: length(tools), else: nil),
      "catalog_loaded" => is_list(tools)
    }
  end

  defp render_command_result(command, values) when is_list(values) do
    rendered =
      case values do
        [] ->
          "[]"

        [single] ->
          "[" <> render_snapshot_value(single) <> "]"

        [first | rest] ->
          first_line = "[" <> render_snapshot_value(first)

          rest_lines =
            Enum.map(rest, fn value ->
              "    " <> render_snapshot_value(value)
            end)

          Enum.join([first_line | rest_lines], "\n") <> "]"
      end

    command <> "\n=> " <> rendered
  end

  defp render_snapshot_value(value) when is_map(value) do
    fields = [
      {"name", Map.get(value, "name")},
      {"description", Map.get(value, "description")},
      {"tool_count", Map.get(value, "tool_count")},
      {"catalog_loaded", Map.get(value, "catalog_loaded")}
    ]

    inner =
      fields
      |> Enum.map_join(" ", fn {key, value} -> "#{lisp_string(key)} #{lisp_literal(value)}" end)

    "{" <> inner <> "}"
  end

  defp render_snapshot_value(value) when is_binary(value), do: lisp_string(value)
  defp render_snapshot_value(value), do: lisp_literal(value)

  defp render_doc_example(entries, description_mode) do
    entries
    |> Enum.sort_by(& &1.name)
    |> Enum.find_value(fn
      %{name: server, tools: tools} when is_list(tools) and tools != [] ->
        tool = Enum.min_by(tools, &tool_field(&1, :name, "unknown"))
        [render_doc_block(server, tool, description_mode)]

      _ ->
        nil
    end)
    |> case do
      nil -> []
      block -> block
    end
  end

  defp render_doc_block(server, tool, description_mode) do
    name = tool_field(tool, :name, "unknown")
    ref = "#{server}/#{name}"
    doc = detailed_tool_text(server, tool, description_mode)

    ~s|(doc #{lisp_string(ref)})| <> "\n=> " <> lisp_string(doc)
  end

  defp detailed_tool_text(server, tool, description_mode) do
    name = tool_field(tool, :name, "unknown")
    input_schema = tool_schema(tool, :input_schema)
    output_schema = tool_schema(tool, :output_schema)
    required = tool_required_keys(tool)

    [
      "#{server}/#{name}",
      maybe_description_line(tool_field(tool, :description, ""), description_mode),
      "",
      "Args: #{render_schema_arg_map(input_schema)}",
      "Required args: #{required_args_text(required)}",
      "",
      "Call:",
      build_call_example(server, name, tool_arg_keys(tool), required),
      "",
      "Returns: Result<#{render_schema_type(output_schema)}>",
      "Use `(:value r)` after checking `(:ok r)`."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp maybe_description_line(_description, :signature_only), do: nil

  defp maybe_description_line(description, :with_descriptions) do
    case description |> compact_description() |> truncate(@inline_description_max_chars) do
      "" -> nil
      desc -> "Description: #{desc}"
    end
  end

  defp required_args_text([]), do: "none"

  defp required_args_text(required) when is_list(required) do
    Enum.map_join(required, ", ", &keyword_name/1)
  end

  defp build_call_example(server, name, arg_keys, required) do
    placeholders =
      cond do
        required != [] -> required
        arg_keys != [] -> Enum.take(arg_keys, 1)
        true -> []
      end

    args_clause =
      case placeholders do
        [] ->
          " :args {}"

        keys ->
          inner = Enum.map_join(keys, " ", fn key -> "#{keyword_name(key)} ..." end)
          " :args {#{inner}}"
      end

    "(tool/mcp-call {:server #{lisp_string(server)} :tool #{lisp_string(name)}#{args_clause}})"
  end

  defp tool_arg_keys(tool) do
    schema = tool_schema(tool, :input_schema)
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    properties
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp tool_required_keys(tool) do
    schema = tool_schema(tool, :input_schema)

    case Map.get(schema, "required", Map.get(schema, :required, [])) do
      list when is_list(list) -> list |> Enum.map(&to_string/1) |> Enum.uniq()
      _ -> []
    end
  end

  defp lisp_literal(nil), do: "nil"
  defp lisp_literal(true), do: "true"
  defp lisp_literal(false), do: "false"
  defp lisp_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp lisp_literal(value) when is_binary(value), do: lisp_string(value)
  defp lisp_literal(value), do: inspect(value)

  defp lisp_string(value) when is_binary(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(value)
    end
  end

  defp server_description(%{metadata: %{description: desc}})
       when is_binary(desc) and desc != "" do
    compact_description(desc) <> ". "
  end

  defp server_description(%{metadata: %{"description" => desc}})
       when is_binary(desc) and desc != "" do
    compact_description(desc) <> ". "
  end

  defp server_description(_), do: ""

  defp server_description_text(entry) do
    entry
    |> server_description()
    |> String.trim()
    |> String.trim_trailing(".")
    |> truncate(80)
  end

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

  defp render_schema_arg_map(schema) when is_map(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))
    ordered_names = ordered_property_names(schema, properties)

    properties_by_string =
      Map.new(properties, fn {key, value} -> {to_string(key), value} end)

    case ordered_names do
      [] ->
        "{}"

      names ->
        fields =
          Enum.map_join(names, " ", fn name ->
            value = Map.get(properties_by_string, name, %{})
            "#{keyword_name(name)} #{render_schema_type(value)}#{optional_suffix(schema, name)}"
          end)

        "{#{fields}}"
    end
  end

  defp render_schema_arg_map(_), do: "{}"

  defp render_schema_type(nil), do: "any"

  defp render_schema_type(schema) when is_map(schema) do
    cond do
      Map.has_key?(schema, "const") or Map.has_key?(schema, :const) ->
        inspect(Map.get(schema, "const", Map.get(schema, :const)))

      is_list(Map.get(schema, "enum", Map.get(schema, :enum))) ->
        render_enum_type(Map.get(schema, "enum", Map.get(schema, :enum)))

      true ->
        render_schema_type_by_type(Map.get(schema, "type", Map.get(schema, :type)), schema)
    end
  end

  defp render_schema_type(_), do: "any"

  defp render_schema_type_by_type(type, schema) when is_list(type) do
    type
    |> Enum.reject(&(&1 in ["null", :null]))
    |> case do
      [] -> "nil"
      [one] -> render_schema_type_by_type(one, schema)
      many -> Enum.map_join(many, "|", &render_schema_type_by_type(&1, schema))
    end
  end

  defp render_schema_type_by_type("string", _schema), do: "string"
  defp render_schema_type_by_type("integer", _schema), do: "int"
  defp render_schema_type_by_type("number", _schema), do: "float"
  defp render_schema_type_by_type("boolean", _schema), do: "bool"

  defp render_schema_type_by_type("array", schema) do
    items = Map.get(schema, "items", Map.get(schema, :items))
    "[#{render_schema_type(items)}]"
  end

  defp render_schema_type_by_type("object", schema), do: render_object_type(schema)
  defp render_schema_type_by_type(nil, schema), do: infer_schema_type(schema)
  defp render_schema_type_by_type(other, _schema), do: to_string(other)

  defp render_enum_type([]), do: "enum"

  defp render_enum_type(values) do
    Enum.map_join(values, "|", &render_literal_type/1)
  end

  defp render_literal_type(value) when is_binary(value), do: lisp_string(value)
  defp render_literal_type(value), do: inspect(value)

  defp infer_schema_type(schema) do
    cond do
      Map.has_key?(schema, "properties") or Map.has_key?(schema, :properties) ->
        render_object_type(schema)

      Map.has_key?(schema, "items") or Map.has_key?(schema, :items) ->
        render_schema_type_by_type("array", schema)

      true ->
        "any"
    end
  end

  defp render_object_type(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    if is_map(properties) and map_size(properties) > 0 do
      properties_by_string =
        Map.new(properties, fn {key, value} -> {to_string(key), value} end)

      fields =
        schema
        |> ordered_property_names(properties)
        |> Enum.map_join(" ", fn name ->
          value = Map.fetch!(properties_by_string, name)
          "#{keyword_name(name)} #{render_schema_type(value)}#{optional_suffix(schema, name)}"
        end)

      "{#{fields}}"
    else
      "map"
    end
  end

  defp ordered_property_names(schema, properties) when is_map(properties) do
    properties_by_string = Map.new(properties, fn {key, value} -> {to_string(key), value} end)

    required_names =
      schema
      |> required_key_names()
      |> Enum.filter(&Map.has_key?(properties_by_string, &1))

    optional_names =
      properties_by_string
      |> Map.keys()
      |> Enum.reject(&(&1 in required_names))
      |> Enum.sort()

    required_names ++ optional_names
  end

  defp ordered_property_names(_schema, _properties), do: []

  defp optional_suffix(schema, name) do
    if name in required_key_names(schema), do: "", else: "?"
  end

  defp required_key_names(schema) when is_map(schema) do
    case Map.get(schema, "required", Map.get(schema, :required, [])) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp required_key_names(_), do: []

  defp keyword_name(key) do
    ":" <> (key |> to_string() |> String.replace("_", "-"))
  end
end
