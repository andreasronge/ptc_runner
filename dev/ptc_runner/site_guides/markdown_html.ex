defmodule PtcRunner.SiteGuides.MarkdownHTML do
  @moduledoc """
  Renders the bounded Markdown subset the guides use into HTML for the
  static site.

  The renderer is deliberately fail-closed: an element, attribute, parser
  warning, or link shape it does not recognise raises instead of publishing
  something silently wrong. Extend the whitelists when a guide legitimately
  needs more Markdown.
  """

  @type rendered :: %{title: String.t(), description: String.t(), html: String.t()}

  # Tags the guides are allowed to produce, with the attributes each may
  # carry. EarmarkParser marks inline code with class "inline" and fenced
  # blocks with the "language-" prefix requested below; table cells carry a
  # text-align style derived from the column marker.
  @permitted_attributes %{
    "a" => ["href"],
    "blockquote" => [],
    "code" => ["class"],
    "del" => [],
    "em" => [],
    "h1" => [],
    "h2" => [],
    "h3" => [],
    "h4" => [],
    "h5" => [],
    "h6" => [],
    "hr" => ["class"],
    "li" => [],
    "ol" => [],
    "p" => [],
    "pre" => [],
    "strong" => [],
    "table" => ["style"],
    "tbody" => [],
    "td" => ["style"],
    "th" => ["style"],
    "thead" => [],
    "tr" => [],
    "ul" => []
  }

  @void_tags ["hr"]
  @heading_tags ["h1", "h2", "h3", "h4", "h5", "h6"]
  @description_limit 160

  @doc """
  Renders one guide's Markdown.

  `source` labels errors. `rewrite_link` receives every `href` exactly as
  written in the Markdown and returns the href to publish; it should raise
  on a target it cannot account for.
  """
  @spec render!(String.t(), String.t(), (String.t() -> String.t())) :: rendered
  def render!(markdown, source, rewrite_link) when is_function(rewrite_link, 1) do
    ast = parse!(markdown, source)
    title = title!(ast, source)

    context = %{source: source, rewrite_link: rewrite_link}
    {iodata, _ids} = render_nodes(ast, context, MapSet.new())

    %{
      title: title,
      description: description(ast),
      html: IO.iodata_to_binary(iodata)
    }
  end

  defp parse!(markdown, source) do
    case EarmarkParser.as_ast(markdown, gfm: true, code_class_prefix: "language-") do
      {:ok, ast, []} ->
        ast

      {_status, _ast, messages} ->
        raise ArgumentError,
              "#{source}: Markdown did not parse cleanly: #{inspect(messages)}"
    end
  end

  # Generated references open with an HTML comment (whose AST tag is the atom
  # :comment, outside EarmarkParser's declared node type); the title is the
  # first element with a real tag after it.
  defp title!(ast, source) do
    case Enum.find(ast, &element?/1) do
      {"h1", _attributes, children, _meta} ->
        text_content(children)

      _other ->
        raise ArgumentError, "#{source}: the first Markdown element must be a # title"
    end
  end

  defp element?({tag, _attributes, _children, _meta}), do: is_binary(tag)
  defp element?(_other), do: false

  defp description(ast) do
    case Enum.find(ast, &match?({"p", _attributes, _children, _meta}, &1)) do
      {"p", _attributes, children, _meta} -> children |> text_content() |> truncate()
      nil -> ""
    end
  end

  defp truncate(text) do
    if String.length(text) <= @description_limit do
      text
    else
      String.slice(text, 0, @description_limit - 1) <> "…"
    end
  end

  defp render_nodes(nodes, context, ids) when is_list(nodes) do
    {iodata, ids} =
      Enum.map_reduce(nodes, ids, fn node, ids -> render_node(node, context, ids) end)

    {iodata, ids}
  end

  defp render_node(text, _context, ids) when is_binary(text), do: {escape(text), ids}

  # HTML comments (generated-file banners, region markers) render as nothing.
  defp render_node({:comment, _attributes, _children, _meta}, _context, ids), do: {"", ids}

  # Raw `<a id="..."></a>` anchor targets, used by the conformance-gaps
  # reference for its stable GAP/DIV ids.
  defp render_node({"a", [{"id", id}], [], _meta}, _context, ids) do
    {["<a id=\"", escape(id), "\"></a>"], MapSet.put(ids, id)}
  end

  defp render_node({tag, attributes, children, _meta} = node, context, ids)
       when is_binary(tag) do
    permitted =
      Map.get(@permitted_attributes, tag) ||
        raise ArgumentError,
              "#{context.source}: Markdown produced unsupported element #{inspect(node)}"

    Enum.each(attributes, fn {name, _value} ->
      name in permitted ||
        raise ArgumentError,
              "#{context.source}: element #{tag} carries unsupported attribute #{name}"
    end)

    cond do
      tag in @void_tags ->
        {["<#{tag}", render_attributes(attributes), ">"], ids}

      tag in @heading_tags ->
        {id, ids} = heading_id(text_content(children), ids)
        {inner, ids} = render_nodes(children, context, ids)
        {["<#{tag} id=\"", id, "\">", inner, "</#{tag}>"], ids}

      tag == "a" ->
        href =
          case List.keyfind(attributes, "href", 0) do
            {"href", href} -> context.rewrite_link.(href)
            nil -> raise ArgumentError, "#{context.source}: link without an href"
          end

        {inner, ids} = render_nodes(children, context, ids)
        {["<a href=\"", escape(href), "\">", inner, "</a>"], ids}

      tag == "table" ->
        {inner, ids} = render_nodes(children, context, ids)

        {[
           "<div class=\"table-wrap\"><table",
           render_attributes(attributes),
           ">",
           inner,
           "</table></div>"
         ], ids}

      true ->
        {inner, ids} = render_nodes(children, context, ids)
        {["<#{tag}", render_attributes(attributes), ">", inner, "</#{tag}>"], ids}
    end
  end

  defp render_node(node, context, _ids) do
    raise ArgumentError,
          "#{context.source}: Markdown produced unsupported node #{inspect(node)}"
  end

  defp render_attributes(attributes) do
    Enum.map(attributes, fn {name, value} -> [" ", name, "=\"", escape(value), "\""] end)
  end

  # ExDoc-style anchors — every run of non-alphanumerics becomes one hyphen
  # ("9.8 Public contracts" anchors as "9-8-public-contracts"). That is the
  # scheme the repository's hand-authored fragment links were written
  # against, because `mix ptc.verify_docs` validates them on rendered ExDoc
  # pages. Deduplicated the way readers expect: a second "Limits" heading on
  # a page becomes "limits-1".
  defp heading_id(text, ids) do
    base =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    base = if base == "", do: "section", else: base

    id =
      Stream.concat([[base]], Stream.map(1..1000//1, &"#{base}-#{&1}"))
      |> Enum.find(&(not MapSet.member?(ids, &1)))

    {id, MapSet.put(ids, id)}
  end

  defp text_content(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      text when is_binary(text) -> text
      {_tag, _attributes, children, _meta} -> text_content(children)
    end)
    |> IO.iodata_to_binary()
  end

  @doc false
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
