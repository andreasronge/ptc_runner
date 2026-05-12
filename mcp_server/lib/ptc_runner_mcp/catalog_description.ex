defmodule PtcRunnerMcp.CatalogDescription do
  @moduledoc """
  Mode-aware catalog description rendering for the `ptc_lisp_execute`
  MCP tool description.

  Per `Plans/ptc-runner-mcp-catalog-exposure.md` §5-§6, the catalog
  section of the tool description varies based on `catalog_mode`
  (auto|inline|lazy), upstream catalog availability, and size
  thresholds. This module resolves the effective mode and renders the
  appropriate description fragment.

  The existing `Upstream.Catalog` module retains its rendering for the
  detailed per-tool signature format. This module produces the §6.2
  compact inline format and §6.3 lazy format, which are structurally
  different (one-line-per-tool summaries vs. discovery instructions).
  """

  alias PtcRunnerMcp.CatalogConfig
  alias PtcRunnerMcp.Upstream.Catalog, as: UpstreamCatalog

  @type snapshot_entry :: %{
          required(:name) => String.t(),
          required(:tools) => [map()] | nil,
          optional(:impl) => module() | nil,
          optional(:metadata) => map()
        }

  @doc """
  Returns the catalog description fragment for the `ptc_lisp_execute`
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
        render_inline(entries, warnings)

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
        inline_text = render_inline_body(entries)

        if String.length(inline_text) > config.catalog_inline_max_chars do
          :lazy
        else
          {:inline, []}
        end
      end
    end
  end

  # -- Inline rendering (§6.2) --

  defp render_inline(entries, []) do
    render_inline_body(entries)
  end

  defp render_inline(entries, unknown_servers) do
    body = render_inline_body(entries)
    warnings = render_unknown_warnings(unknown_servers)
    discovery = render_discovery_block()

    body <> "\n\n" <> warnings <> "\n\n" <> discovery
  end

  defp render_inline_body(entries) do
    server_blocks =
      entries
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", &render_inline_server/1)

    "Configured upstream MCP servers:\n" <> server_blocks
  end

  defp render_inline_server(%{name: name, tools: nil} = entry) do
    desc = server_description(entry)
    "- #{name}: #{desc}Catalog loads on first use."
  end

  defp render_inline_server(%{name: name, tools: []} = entry) do
    desc = server_description(entry)
    "- #{name}: #{desc}0 tools."
  end

  defp render_inline_server(%{name: name, tools: tools} = entry) when is_list(tools) do
    desc = server_description(entry)
    capabilities = server_capabilities(entry)
    tool_count = length(tools)

    header = "- #{name}: #{desc}#{tool_count} tools.#{capabilities}"

    tool_lines = Enum.map_join(tools, "\n", &render_inline_tool/1)

    header <> "\n  Tools:\n" <> tool_lines
  end

  defp render_inline_tool(tool) do
    name = tool_field(tool, :name, "unknown")
    description = tool_field(tool, :description, "")
    desc_part = if description == "", do: "", else: " #{compact_description(description)}"
    "  - #{name}:#{desc_part}"
  end

  # -- Lazy rendering (§6.3) --

  defp render_lazy(entries) do
    server_lines =
      entries
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", &render_lazy_server/1)

    "Configured upstream MCP servers:\n" <>
      server_lines <>
      "\n\n" <>
      render_discovery_block()
  end

  defp render_lazy_server(%{name: name, tools: nil} = entry) do
    desc = server_description(entry)
    "- #{name}: #{desc}Catalog loads on first use."
  end

  defp render_lazy_server(%{name: name, tools: []} = entry) do
    desc = server_description(entry)
    "- #{name}: #{desc}0 tools."
  end

  defp render_lazy_server(%{name: name, tools: tools} = entry) when is_list(tools) do
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

  defp render_unknown_warnings(servers) do
    lines = Enum.map_join(servers, "\n", &"Warning: catalog for \"#{&1}\" not loaded yet.")
    lines
  end

  defp render_discovery_block do
    """
    Use catalog/search-tools inside the PTC-Lisp program to find relevant \
    upstream tools. If search reports an unloaded server-level match, call \
    catalog/list-tools or catalog/describe-tool for that server to load its \
    catalog. Use catalog/describe-tool before calling unfamiliar tools. Then \
    call upstream tools with tool/mcp-call.

    (catalog/search-tools "query" {:limit 8})
    (catalog/list-tools "server-name" {:limit 20})
    (catalog/describe-tool "server-name" "tool-name")
    (tool/mcp-call {:server "server-name" :tool "tool-name" :args {...}})\
    """
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
end
