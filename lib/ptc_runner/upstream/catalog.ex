defmodule PtcRunner.Upstream.Catalog do
  @moduledoc false

  @spec snapshot([map()]) :: [map()]
  def snapshot(upstreams) when is_list(upstreams) do
    Enum.map(upstreams, fn upstream ->
      %{
        "name" => upstream.name,
        "transport" => Atom.to_string(upstream.transport),
        "description" => get_in(upstream, [:metadata, "description"]) || "",
        "tool_count" => length(upstream.tools || []),
        "catalog_loaded" => upstream.tools != nil,
        "tools" => upstream.tools || []
      }
    end)
  end

  @spec render_text([map()], atom(), keyword()) :: String.t()
  def render_text(snapshot, exposure_mode \\ :auto, opts \\ []) when is_list(snapshot) do
    exposure_mode = effective_mode(snapshot, exposure_mode, opts)

    snapshot
    |> Enum.flat_map(&server_lines(&1, exposure_mode))
    |> Enum.join("\n")
  end

  defp effective_mode(snapshot, :auto, opts) do
    max_tools = Keyword.get(opts, :catalog_inline_max_tools, 8)
    max_chars = Keyword.get(opts, :catalog_inline_max_chars, 800)
    inline_text = render_text(snapshot, :inline, opts)
    tool_count = Enum.reduce(snapshot, 0, &(&2 + (&1["tool_count"] || 0)))

    if tool_count > max_tools or String.length(inline_text) > max_chars do
      :lazy
    else
      :inline
    end
  end

  defp effective_mode(_snapshot, mode, _opts), do: mode

  defp server_lines(server, :lazy), do: ["#{server["name"]} (#{server["tool_count"]} tools)"]

  defp server_lines(server, _mode) do
    header = ["#{server["name"]} (#{server["tool_count"]} tools)"]

    tools =
      Enum.map(server["tools"], fn tool ->
        "  #{server["name"]}/#{tool["name"]} - #{tool["description"] || ""}"
      end)

    header ++ tools
  end
end
