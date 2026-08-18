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

  # Fence- and code-span-aware, because sample text may legitimately contain link
  # syntax and rewriting it would corrupt an example rather than repair a link.
  # Link text may wrap across lines, so the pattern is applied to whole prose
  # spans rather than line by line. The optional title group covers
  # `](target "Title")`; a reference-style definition is handled separately,
  # because a link label cannot hold a command.
  # Link text may wrap once and carries no brackets of its own. Allowing either
  # let a stray `[` — `at main.clj bytes [45,58)` — pair with a `]` paragraphs
  # away and swallow everything between them.
  @link ~r/(!?)\[([^\[\]\n]*(?:\n[^\[\]\n]*)?)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)/
  @reference_definition ~r/^ {0,3}\[[^\]]+\]:\s*<?([^>\s]+)>?/m
  # Line-scoped, so an unpaired backtick cannot pair with one paragraphs away and
  # mask a real link between them. A code span that wraps lines therefore
  # protects nothing, which is the harmless direction: the rewrite of a link
  # inside one would be cosmetic, while a masked link ships dead.
  @code_span ~r/(`+[^`\n]*`+)/
  @fence ~w(``` ~~~)
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
          {rewritten, unresolved ++ span_unresolved ++ reference_definitions(span)}
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
      fence? = String.starts_with?(String.trim_leading(line), @fence)
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

  # A reference-style definition cannot become a command, because the label it
  # binds is used elsewhere as `[text][label]`. Report it rather than leave a
  # relative destination the executable cannot follow.
  defp reference_definitions(span) do
    @reference_definition
    |> Regex.scan(span, return: :binary)
    |> Enum.map(fn [_matched, target] -> target end)
    |> Enum.reject(&(String.starts_with?(&1, @absolute) or String.starts_with?(&1, "#")))
  end

  # Matches are located by byte offset rather than by content, so a link is
  # replaced where it occurs and a code span is skipped only when it is the whole
  # match. Splitting on code spans first would tear apart the common
  # ``[`docs/x.md`](x.md)`` form, whose link text is itself a code span.
  defp rewrite_span(span, directory, names_by_path) do
    code = code_ranges(span)

    {replacements, unresolved} =
      @link
      |> Regex.scan(span, return: :index)
      |> Enum.reject(fn [{start, _length} | _groups] -> inside?(code, start) end)
      |> Enum.map_reduce([], fn match, unresolved ->
        [whole, bang, text, target] = Enum.take(match, 4)

        case replacement(
               slice(span, bang),
               slice(span, text),
               slice(span, target),
               directory,
               names_by_path
             ) do
          {:ok, replacement} -> {{whole, replacement}, unresolved}
          :keep -> {nil, unresolved}
          {:error, resolved} -> {nil, unresolved ++ [resolved]}
        end
      end)

    {apply_replacements(span, Enum.filter(replacements, & &1)), unresolved}
  end

  # Right to left, so an earlier replacement cannot move a later offset.
  defp apply_replacements(span, replacements) do
    replacements
    |> Enum.sort_by(fn {{start, _length}, _replacement} -> start end, :desc)
    |> Enum.reduce(span, fn {{start, length}, replacement}, span ->
      binary_part(span, 0, start) <>
        replacement <> binary_part(span, start + length, byte_size(span) - start - length)
    end)
  end

  defp code_ranges(span) do
    @code_span
    |> Regex.scan(span, return: :index)
    |> Enum.map(fn [{start, length} | _groups] -> {start, start + length} end)
  end

  defp inside?(ranges, offset),
    do: Enum.any?(ranges, fn {start, stop} -> offset >= start and offset < stop end)

  defp slice(_span, {_start, 0}), do: ""
  defp slice(span, {start, length}), do: binary_part(span, start, length)

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
