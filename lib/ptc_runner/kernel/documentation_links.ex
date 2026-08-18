defmodule PtcRunner.Kernel.DocumentationLinks do
  @moduledoc false

  # Rewrites the relative markdown links of an embedded documentation page into
  # the `ptc docs NAME` command that serves the same page.
  #
  # An installed executable carries no repository, so a relative path is not a
  # link its reader can follow: it is an instruction to go and find a checkout,
  # printed by the one surface whose whole promise is that they do not need one.
  # Every link whose target this executable also serves is therefore rewritten
  # while the page is embedded, and any link that survives names a document the
  # release does not carry — which `PtcRunner.Kernel.DocumentationLibrary`
  # refuses to compile rather than ship.
  #
  # The rewrite applies to the embedded copy only. The files on disk keep
  # ordinary relative links, which is what the website and HexDocs render.

  # Fence-aware, because a fenced block may legitimately contain link syntax as
  # sample text and rewriting it would corrupt an example rather than repair a
  # link. Link text may wrap across lines, so the pattern is applied to whole
  # unfenced spans rather than line by line.
  @link ~r/(!?)\[([^\]]*)\]\(([^)\s]+)\)/
  @absolute ~w(http:// https:// mailto: //)

  @doc """
  Rewrites `content`, read from `source_path`, against the served page map.

  Returns `{:error, targets}` listing every relative link that resolves to no
  served page, in first-seen order.
  """
  @spec rewrite(binary(), binary(), %{optional(binary()) => binary()}) ::
          {:ok, binary()} | {:error, [binary()]}
  def rewrite(content, source_path, names_by_path)
      when is_binary(content) and is_binary(source_path) and is_map(names_by_path) do
    directory = Path.dirname(source_path)

    {spans, unresolved} =
      content
      |> spans()
      |> Enum.map_reduce([], fn
        {:code, span}, unresolved ->
          {span, unresolved}

        {:text, span}, unresolved ->
          {rewritten, span_unresolved} = rewrite_span(span, directory, names_by_path)
          {rewritten, unresolved ++ span_unresolved}
      end)

    case unresolved do
      [] -> {:ok, Enum.join(spans, "\n")}
      targets -> {:error, Enum.uniq(targets)}
    end
  end

  # Alternating text and fenced-code spans, each a joined run of lines. Fence
  # markers stay with the code span they open or close.
  defp spans(content) do
    content
    |> String.split("\n")
    |> Enum.reduce({[], :text}, fn line, {spans, kind} ->
      fence? = String.starts_with?(String.trim_leading(line), "```")
      next = if fence?, do: flip(kind), else: kind
      line_kind = if fence?, do: :code, else: kind

      case spans do
        [{^line_kind, lines} | earlier] -> {[{line_kind, [line | lines]} | earlier], next}
        _other -> {[{line_kind, [line]} | spans], next}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(fn {kind, lines} -> {kind, lines |> Enum.reverse() |> Enum.join("\n")} end)
  end

  defp flip(:text), do: :code
  defp flip(:code), do: :text

  defp rewrite_span(span, directory, names_by_path) do
    @link
    |> Regex.scan(span, return: :binary)
    |> Enum.reduce({span, []}, fn [matched, bang, text, target], {span, unresolved} ->
      case replacement(bang, text, target, directory, names_by_path) do
        {:ok, replacement} ->
          {String.replace(span, matched, replacement, global: false), unresolved}

        :keep ->
          {span, unresolved}

        {:error, resolved} ->
          {span, unresolved ++ [resolved]}
      end
    end)
  end

  defp replacement(bang, text, target, directory, names_by_path) do
    cond do
      String.starts_with?(target, @absolute) ->
        :keep

      String.starts_with?(target, "#") ->
        :keep

      # An image cannot be served as a page at all, so it is reported rather
      # than rewritten into a command that would not render one.
      bang != "" ->
        {:error, target}

      true ->
        resolve(text, target, directory, names_by_path)
    end
  end

  defp resolve(text, target, directory, names_by_path) do
    resolved = directory |> Path.join(anchorless(target)) |> normalize()

    case Map.fetch(names_by_path, resolved) do
      # The anchor is dropped: `ptc docs` serves a whole page, and a fragment
      # that cannot be jumped to reads as a promise the terminal does not keep.
      {:ok, name} when text == "" -> {:ok, "`ptc docs #{name}`"}
      {:ok, name} -> {:ok, "#{text} (`ptc docs #{name}`)"}
      :error -> {:error, resolved}
    end
  end

  defp anchorless(target), do: target |> String.split("#", parts: 2) |> hd()

  defp normalize(path) do
    path
    |> Path.split()
    |> Enum.reduce([], fn
      ".", segments -> segments
      "..", [_parent | segments] -> segments
      "..", [] -> []
      segment, segments -> [segment | segments]
    end)
    |> Enum.reverse()
    |> Path.join()
  end
end
