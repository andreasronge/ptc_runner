defmodule PtcRunnerMcp.Agentic.CapabilitySummary do
  @moduledoc """
  Deterministic compact summaries for the `ptc_task` advertised surface.

  The renderer consumes the structured frozen catalog snapshot rather than
  parsing the human-oriented upstream catalog text.
  """

  alias PtcRunnerMcp.Upstream.Catalog

  @default_max_bytes 800

  @type entry :: %{
          required(:name) => String.t(),
          required(:tools) => list() | nil,
          optional(:impl) => module() | nil
        }

  @doc """
  Generates a deterministic capability summary from the frozen catalog snapshot.
  """
  @spec from_frozen(keyword()) :: String.t()
  def from_frozen(opts \\ []) do
    generate(Catalog.frozen_snapshot(), opts)
  end

  @doc """
  Generates a deterministic capability summary from explicit catalog entries.

  Output never exceeds `:max_bytes`. Empty input returns an empty string.
  """
  @spec generate([entry()], keyword()) :: String.t()
  def generate(entries, opts \\ []) when is_list(entries) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    entries
    |> normalize_entries()
    |> render_budgeted(max_bytes)
  end

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

  defp render_budgeted([], _max_bytes), do: ""

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
    "- #{name}: " <> Enum.join(tool_names(tools), ", ")
  end

  defp full_bullet(%{name: name}), do: "- #{name}: (no tools advertised)"

  defp clipped_bullet(%{tools: tools} = entry, lines, max_bytes)
       when is_list(tools) and tools != [] do
    names = tool_names(tools)

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

  defp tool_names(tools) do
    tools
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp tool_name(%{name: name}), do: to_string(name)
  defp tool_name(%{"name" => name}), do: to_string(name)
  defp tool_name(_), do: ""

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
