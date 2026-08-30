defmodule Mix.Tasks.Ptc.VerifyDocs do
  @shortdoc "Verify published Markdown and rendered ExDoc links"
  @moduledoc """
  Rejects relative Markdown links that ExDoc would silently resolve to a
  different extra with the same basename, then verifies that local links and
  assets inside rendered page content remain under the documentation root,
  exist, and name real anchors.

      mix ptc.verify_docs

  Run this after `mix docs`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    root = File.cwd!()
    docs = Mix.Project.config() |> Keyword.fetch!(:docs)
    extras = Keyword.fetch!(docs, :extras)
    doc_root = Path.join(root, "doc")

    errors = source_errors(extras, root) ++ rendered_errors(doc_root)

    case errors do
      [] -> Mix.shell().info("Verified published documentation links")
      errors -> Mix.raise("Documentation link verification failed:\n" <> Enum.join(errors, "\n"))
    end
  end

  @doc false
  def source_errors(extras, root) do
    published = published_extras(extras, root)
    by_basename = Map.new(published, &{Path.basename(&1), &1})

    duplicate_basename_errors(published) ++
      Enum.flat_map(published, fn source ->
        if Path.extname(source) in [".md", ".livemd", ".cheatmd"] do
          markdown = File.read!(source)

          indented_link_errors(markdown, source) ++
            (markdown
             |> markdown_targets()
             |> Enum.flat_map(&source_target_errors(&1, source, published, by_basename)))
        else
          []
        end
      end)
  end

  @doc false
  def rendered_errors(doc_root) do
    root = Path.expand(doc_root)

    root
    |> Path.join("**/*.html")
    |> Path.wildcard()
    |> Enum.flat_map(fn page ->
      page
      |> File.read!()
      |> main_content()
      |> rendered_targets()
      |> Enum.flat_map(&rendered_target_errors(&1, page, root))
    end)
  end

  defp published_extras(extras, root) do
    Enum.flat_map(extras, fn
      path when is_binary(path) ->
        [Path.expand(path, root)]

      {path, options} when is_binary(path) and is_list(options) ->
        if Keyword.has_key?(options, :url), do: [], else: [Path.expand(path, root)]
    end)
  end

  defp duplicate_basename_errors(published) do
    published
    |> Enum.group_by(&Path.basename/1)
    |> Enum.flat_map(fn
      {_basename, [_one]} ->
        []

      {basename, paths} ->
        [
          "published extras share basename #{basename}: #{Enum.map_join(paths, ", ", &relative/1)}"
        ]
    end)
  end

  defp markdown_targets(markdown) do
    {_status, ast, _messages} = EarmarkParser.as_ast(markdown)
    ast_targets(ast)
  end

  defp ast_targets(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &ast_targets/1)

  defp ast_targets({tag, attributes, children, _metadata}) when tag in ["a", "img"] do
    attribute = if tag == "a", do: "href", else: "src"
    own_target = for {^attribute, target} <- attributes, do: target
    own_target ++ ast_targets(children)
  end

  defp ast_targets({_tag, _attributes, children, _metadata}), do: ast_targets(children)
  defp ast_targets(_other), do: []

  defp indented_link_errors(markdown, source) do
    lines = String.split(markdown, "\n")
    fenced = fenced_line_numbers(lines)

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(~r/^ {4,}!?\[[^\]]+\]\([^)]+\)\s*$/, line) and
           line_number not in fenced and
           not nested_in_list?(lines, line_number, leading_spaces(line)) do
        [
          "#{relative(source)}:#{line_number} indents a Markdown link as a code block"
        ]
      else
        []
      end
    end)
  end

  defp fenced_line_numbers(lines) do
    {_open_fence, line_numbers} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({nil, MapSet.new()}, fn {line, line_number}, {open_fence, line_numbers} ->
        cond do
          open_fence && closes_fence?(line, open_fence) ->
            {nil, MapSet.put(line_numbers, line_number)}

          open_fence ->
            {open_fence, MapSet.put(line_numbers, line_number)}

          marker = opening_fence(line) ->
            {marker, MapSet.put(line_numbers, line_number)}

          true ->
            {nil, line_numbers}
        end
      end)

    line_numbers
  end

  defp opening_fence(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})/, line, capture: :all_but_first) do
      [marker] -> {String.first(marker), String.length(marker)}
      nil -> nil
    end
  end

  defp closes_fence?(line, {character, minimum_length}) do
    marker = Regex.escape(String.duplicate(character, minimum_length))
    extension = Regex.escape(character)
    Regex.match?(Regex.compile!("^ {0,3}#{marker}#{extension}*\\s*$"), line)
  end

  defp nested_in_list?(lines, line_number, link_indent) do
    lines
    |> Enum.take(line_number - 1)
    |> Enum.reverse()
    |> Enum.reduce_while(false, fn preceding, _nested? ->
      cond do
        String.trim(preceding) == "" ->
          {:cont, false}

        content_indent = list_content_indent(preceding) ->
          {:halt, link_indent >= content_indent}

        Regex.match?(~r/^\s+/, preceding) ->
          {:cont, false}

        true ->
          {:halt, false}
      end
    end)
  end

  defp list_content_indent(line) do
    case Regex.run(~r/^( {0,3})([-+*]|\d{1,9}[.)])( {1,4})\S/, line, capture: :all_but_first) do
      [leading, marker, spacing] ->
        String.length(leading) + String.length(marker) + String.length(spacing)

      nil ->
        nil
    end
  end

  defp leading_spaces(line), do: byte_size(line) - byte_size(String.trim_leading(line, " "))

  defp source_target_errors(target, source, published, by_basename) do
    uri = URI.parse(target)

    if relative_markdown_uri?(uri) do
      resolved =
        uri.path
        |> URI.decode()
        |> Path.expand(Path.dirname(source))

      selected = Map.get(by_basename, Path.basename(resolved))

      cond do
        resolved not in published ->
          ["#{relative(source)} links to unpublished Markdown #{target}"]

        selected != resolved ->
          ["#{relative(source)} links to #{target}, but ExDoc selects #{relative(selected)}"]

        true ->
          []
      end
    else
      []
    end
  end

  defp relative_markdown_uri?(%URI{scheme: nil, host: nil, path: path}) when is_binary(path),
    do: path != "" and Path.extname(path) in [".md", ".livemd", ".cheatmd"]

  defp relative_markdown_uri?(_uri), do: false

  defp main_content(html) do
    case Regex.run(~r/<main\b[^>]*>(.*)<\/main>/s, html, capture: :all_but_first) do
      [main] -> main
      nil -> ""
    end
  end

  defp rendered_targets(html) do
    ~r/(?:href|src)="([^"]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, "&amp;", "&"))
  end

  defp rendered_target_errors(target, page, root) do
    uri = URI.parse(target)

    if local_uri?(uri) do
      path = if uri.path in [nil, ""], do: page, else: resolve_target(uri.path, page)

      cond do
        not within?(path, root) ->
          ["#{relative(page)} escapes the rendered docs root: #{target}"]

        not File.exists?(path) ->
          ["#{relative(page)} links to missing rendered target #{target}"]

        uri.fragment && not anchor_exists?(path, URI.decode(uri.fragment)) ->
          ["#{relative(page)} links to missing anchor #{target}"]

        true ->
          []
      end
    else
      []
    end
  end

  defp local_uri?(%URI{scheme: nil, host: nil}), do: true
  defp local_uri?(_uri), do: false

  defp resolve_target(path, page) do
    path
    |> URI.decode()
    |> Path.expand(Path.dirname(page))
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp anchor_exists?(path, anchor) do
    File.regular?(path) and Regex.match?(~r/\bid="#{Regex.escape(anchor)}"/, File.read!(path))
  end

  defp relative(nil), do: "unknown"
  defp relative(path), do: Path.relative_to_cwd(path)
end
