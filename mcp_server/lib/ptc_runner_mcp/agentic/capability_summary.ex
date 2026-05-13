defmodule PtcRunnerMcp.Agentic.CapabilitySummary do
  @moduledoc """
  Deterministic compact summaries for the `ptc_task` advertised surface.

  The renderer consumes the structured frozen catalog snapshot rather than
  parsing the human-oriented upstream catalog text.
  """

  alias PtcRunnerMcp.CatalogConfig
  alias PtcRunnerMcp.Upstream.Catalog

  @default_max_bytes 800

  # This pointer is shown to MCP clients in the `ptc_task` tool
  # description. `ptc_task` callers describe what they want in plain
  # English — they do not write PTC-Lisp themselves. The pointer
  # therefore stays on the agentic surface: it tells the calling LLM
  # that the catalog is loaded lazily by the internal planner, so it
  # should still ask `ptc_task` (no need to pre-discover servers).
  # The planner's own system prompt has a separate lazy block (in
  # `PtcRunnerMcp.Agentic.Prompt`) that does instruct it to call
  # `(catalog/...)` from inside the generated PTC-Lisp program.
  @lazy_pointer "Upstream catalog is loaded lazily (catalog mode: lazy); " <>
                  "ptc_task's internal planner discovers configured upstream servers " <>
                  "and their tools at runtime. Describe the task you want in plain English " <>
                  "and the planner will pick the right upstream calls."

  @type entry :: %{
          required(:name) => String.t(),
          required(:tools) => list() | nil,
          optional(:impl) => module() | nil
        }

  @doc """
  Generates a deterministic capability summary from the frozen catalog snapshot.

  Honors `CatalogConfig.get().catalog_mode` (override with `:catalog_mode`
  in `opts`): `:lazy` returns a short pointer telling the planner to
  use `(catalog/*)` at runtime; `:inline` and `:auto` render the
  snapshot (subject to `:max_bytes` for `:auto`).
  """
  @spec from_frozen(keyword()) :: String.t()
  def from_frozen(opts \\ []) do
    generate(Catalog.frozen_snapshot(), opts)
  end

  @doc """
  Generates a deterministic capability summary from explicit catalog entries.

  - `:catalog_mode` — `:auto` (default — render with `:max_bytes` budget,
    clipping entries that don't fit), `:inline` (render every entry,
    ignoring `:max_bytes`), or `:lazy` (return the runtime-discovery
    pointer instead). Defaults to `CatalogConfig.get().catalog_mode`.
  - `:max_bytes` — byte cap for `:auto` mode (default 800).

  Empty input returns an empty string in `:auto` / `:inline`; `:lazy`
  still returns the pointer when something is configured (and an empty
  string when nothing is).
  """
  @spec generate([entry()], keyword()) :: String.t()
  def generate(entries, opts \\ []) when is_list(entries) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    mode =
      Keyword.get_lazy(opts, :catalog_mode, fn -> CatalogConfig.get().catalog_mode end)

    normalized = normalize_entries(entries)

    case {mode, normalized} do
      {_mode, []} ->
        ""

      {:lazy, _entries} ->
        @lazy_pointer

      {:inline, entries} ->
        render_unbounded(entries)

      {_auto_or_unknown, entries} ->
        render_budgeted(entries, max_bytes)
    end
  end

  @doc """
  Returns the runtime-discovery pointer used in `:lazy` mode.
  """
  @spec lazy_pointer() :: String.t()
  def lazy_pointer, do: @lazy_pointer

  @doc """
  Reads an operator-supplied override summary without truncating it.

  Returns an error when the file contents exceed `max_bytes`.
  """
  @spec read_override(Path.t(), pos_integer()) ::
          {:ok, String.t()}
          | {:error, {:too_large, non_neg_integer(), pos_integer()}}
          | {:error, term()}
  def read_override(path, max_bytes) when is_binary(path) and is_integer(max_bytes) do
    case File.read(path) do
      {:ok, text} ->
        size = byte_size(text)

        if size <= max_bytes do
          {:ok, text}
        else
          {:error, {:too_large, size, max_bytes}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_entries(entries) do
    entries
    |> Enum.map(fn entry ->
      %{name: entry_name(entry), tools: entry_tools(entry)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp entry_name(%{name: name}), do: to_string(name)
  defp entry_name(%{"name" => name}), do: to_string(name)

  defp entry_tools(%{tools: tools}), do: tools
  defp entry_tools(%{"tools" => tools}), do: tools
  defp entry_tools(_), do: []

  defp render_unbounded(entries) do
    Enum.map_join(entries, "\n", &full_bullet/1)
  end

  # The `[]` head used to live here, but `generate/2` now short-circuits
  # empty input upstream, so dialyzer flagged the clause as unreachable.
  defp render_budgeted(_entries, max_bytes) when not is_integer(max_bytes) or max_bytes <= 0,
    do: ""

  defp render_budgeted(entries, max_bytes) do
    do_render_budgeted(entries, max_bytes, [], length(entries))
  end

  defp do_render_budgeted([], _max_bytes, lines, _total), do: Enum.join(lines, "\n")

  defp do_render_budgeted([entry | rest], max_bytes, lines, total) do
    full = full_bullet(entry)

    cond do
      fits?(lines, full, max_bytes) ->
        do_render_budgeted(rest, max_bytes, lines ++ [full], total)

      clipped = clipped_bullet(entry, lines, max_bytes) ->
        lines
        |> Kernel.++([clipped])
        |> maybe_append_more_upstreams(length(rest), max_bytes)

      true ->
        maybe_append_more_upstreams(lines, total - length(lines), max_bytes)
    end
  end

  defp full_bullet(%{name: name, tools: nil}), do: "- #{name}: (unavailable at startup)"
  defp full_bullet(%{name: name, tools: []}), do: "- #{name}: (no tools advertised)"

  defp full_bullet(%{name: name, tools: tools}) when is_list(tools) do
    "- #{name}: " <> Enum.join(tool_labels(tools), ", ")
  end

  defp full_bullet(%{name: name}), do: "- #{name}: (no tools advertised)"

  defp clipped_bullet(%{tools: tools} = entry, lines, max_bytes)
       when is_list(tools) and tools != [] do
    names = tool_labels(tools)

    names
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.find_value(fn {_tool_name, count} ->
      more = length(names) - count
      shown = Enum.take(names, count)
      marker = if more > 0, do: ["(+#{more} more)"], else: []
      candidate = "- #{entry.name}: " <> Enum.join(shown ++ marker, ", ")

      if fits?(lines, candidate, max_bytes), do: candidate
    end)
    |> case do
      nil ->
        marker = "- #{entry.name}: (+#{length(names)} more)"
        if fits?(lines, marker, max_bytes), do: marker

      candidate ->
        candidate
    end
  end

  defp clipped_bullet(_entry, _lines, _max_bytes), do: nil

  defp tool_labels(tools) do
    tools
    |> Enum.map(&tool_label/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp tool_label(tool) do
    name = tool_name(tool)

    if name == "" do
      ""
    else
      "#{name}->#{output_type(tool)}"
    end
  end

  defp tool_name(%{name: name}), do: to_string(name)
  defp tool_name(%{"name" => name}), do: to_string(name)
  defp tool_name(_), do: ""

  defp output_type(%{output_schema: schema}), do: signature_type(schema)
  defp output_type(%{"output_schema" => schema}), do: signature_type(schema)
  defp output_type(%{"outputSchema" => schema}), do: signature_type(schema)
  defp output_type(_), do: ":unknown_content"

  defp signature_type(%{"type" => "string"}), do: ":string"
  defp signature_type(%{"type" => "integer"}), do: ":int"
  defp signature_type(%{"type" => "number"}), do: ":float"
  defp signature_type(%{"type" => "boolean"}), do: ":bool"
  defp signature_type(%{"type" => "array", "items" => items}), do: "[#{signature_type(items)}]"
  defp signature_type(%{"type" => "array"}), do: "[:any]"

  defp signature_type(%{"type" => "object", "properties" => properties})
       when is_map(properties) do
    if map_size(properties) == 0 do
      ":map"
    else
      fields =
        properties
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.take(3)
        |> Enum.map_join(",", fn {key, value} -> "#{key} #{signature_type(value)}" end)

      "{#{fields}}"
    end
  end

  defp signature_type(%{"type" => "object"}), do: ":map"
  defp signature_type(schema) when is_map(schema), do: ":any"
  defp signature_type(_), do: ":unknown_content"

  defp maybe_append_more_upstreams(lines, omitted, max_bytes) when omitted > 0 do
    marker = "- (+#{omitted} more upstreams)"

    if fits?(lines, marker, max_bytes) do
      Enum.join(lines ++ [marker], "\n")
    else
      Enum.join(lines, "\n")
    end
  end

  defp maybe_append_more_upstreams(lines, _omitted, _max_bytes), do: Enum.join(lines, "\n")

  defp fits?(lines, line, max_bytes) do
    lines
    |> Kernel.++([line])
    |> Enum.join("\n")
    |> byte_size()
    |> Kernel.<=(max_bytes)
  end
end
