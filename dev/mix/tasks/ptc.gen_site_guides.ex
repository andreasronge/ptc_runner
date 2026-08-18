defmodule Mix.Tasks.Ptc.GenSiteGuides do
  @shortdoc "Generate the static-site guide pages from docs/guides"
  @moduledoc """
  Renders every guide into a committed page under `site/guides/`, plus the
  directory page at `site/guides/index.html`.

  The sidebar structure is read from the same `mix.exs` configuration ExDoc
  uses — the guide groups in `:groups_for_extras` name the sections, and the
  `:extras` list orders the pages — so the HexDocs sidebar and the site
  sidebar cannot drift apart.

      mix ptc.gen_site_guides
      mix ptc.gen_site_guides --check

  `--check` verifies the checked-in pages without rewriting them and fails
  on a stale, missing, or orphaned page (a renamed guide leaves an orphan
  behind). `mix ptc.gen_docs` runs this task, so regenerating the docs
  regenerates these pages too.

  Relative links to a sibling guide become site links; relative links to any
  other repository file become GitHub links and must name a file that
  exists. Everything else the renderer does not recognise fails the run —
  see `PtcRunner.SiteGuides.MarkdownHTML`.
  """
  use Mix.Task

  alias PtcRunner.SiteGuides.MarkdownHTML

  @output_root "site/guides"
  @site_origin "https://ptc-runner.dev"
  @github "https://github.com/andreasronge/ptc_runner"
  @guide_prefix "docs/guides/"

  @impl Mix.Task
  def run(args) do
    check? = "--check" in args
    sections = sections!()
    pages = render_pages(sections)

    expected =
      Map.new(pages, fn page -> {page.output_path, page_document(page, sections, pages)} end)

    expected =
      Map.put(expected, Path.join(@output_root, "index.html"), index_document(sections, pages))

    if check? do
      check!(expected)
    else
      write!(expected)
    end
  end

  # ── Section structure, from the ExDoc configuration ─────────────────────

  defp sections! do
    docs = Mix.Project.config() |> Keyword.fetch!(:docs)
    guide_extras = docs |> Keyword.fetch!(:extras) |> Enum.flat_map(&extra_guide_path/1)

    guide_groups =
      docs
      |> Keyword.fetch!(:groups_for_extras)
      |> Enum.filter(fn {_title, members} ->
        is_list(members) and members != [] and Enum.all?(members, &guide_path?/1)
      end)

    grouped = Enum.flat_map(guide_groups, fn {_title, members} -> members end)

    unless Enum.sort(grouped) == Enum.sort(guide_extras) and
             Enum.uniq(grouped) == grouped do
      Mix.raise("""
      The guide groups in mix.exs must contain every docs/guides extra exactly once.
      In groups but not extras: #{inspect(grouped -- guide_extras)}
      In extras but not groups: #{inspect(guide_extras -- grouped)}
      """)
    end

    Enum.each(guide_groups, fn {title, members} ->
      extras_order = Enum.filter(guide_extras, &(&1 in members))

      unless members == extras_order do
        Mix.raise("""
        Guide group #{inspect(title)} lists its pages in a different order than
        :extras. ExDoc orders pages by :extras; make both orders agree.
        """)
      end
    end)

    Enum.map(guide_groups, fn {title, members} ->
      %{title: to_string(title), sources: members}
    end)
  end

  defp extra_guide_path(path) when is_binary(path),
    do: if(guide_path?(path), do: [path], else: [])

  defp extra_guide_path({path, options}) when is_binary(path) and is_list(options),
    do: if(Keyword.has_key?(options, :url), do: [], else: extra_guide_path(path))

  defp guide_path?(path) when is_binary(path),
    do: String.starts_with?(path, @guide_prefix) and Path.extname(path) == ".md"

  defp guide_path?(_other), do: false

  # ── Rendering ───────────────────────────────────────────────────────────

  defp render_pages(sections) do
    sources = Enum.flat_map(sections, & &1.sources)
    slug_by_source = Map.new(sources, &{&1, Path.basename(&1, ".md")})

    ordered =
      Enum.flat_map(sections, fn section ->
        Enum.map(section.sources, fn source ->
          rendered =
            source
            |> File.read!()
            |> MarkdownHTML.render!(source, &rewrite_link(&1, source, slug_by_source))

          slug = Map.fetch!(slug_by_source, source)

          %{
            source: source,
            slug: slug,
            url: "/guides/#{slug}/",
            output_path: Path.join([@output_root, slug, "index.html"]),
            section: section.title,
            title: rendered.title,
            description: rendered.description,
            html: rendered.html
          }
        end)
      end)

    Enum.with_index(ordered, fn page, index ->
      previous = if index > 0, do: Enum.at(ordered, index - 1)

      page
      |> Map.put(:previous, previous)
      |> Map.put(:next, Enum.at(ordered, index + 1))
    end)
  end

  # Sibling guides become site pages; anything else relative must exist in
  # the repository and is published as a GitHub link. Unknown shapes raise so
  # a typo cannot ship as a dead link.
  @doc false
  def rewrite_link(target, source, slug_by_source) do
    uri = URI.parse(target)
    fragment = if uri.fragment, do: "#" <> uri.fragment, else: ""

    cond do
      uri.scheme in ["http", "https", "mailto"] ->
        target

      uri.scheme != nil or uri.host != nil ->
        Mix.raise("#{source} links to unsupported target #{target}")

      uri.path in [nil, ""] ->
        target

      true ->
        repo_path =
          uri.path
          |> URI.decode()
          |> Path.expand(Path.dirname(source))
          |> Path.relative_to(File.cwd!())

        cond do
          slug = Map.get(slug_by_source, repo_path) -> "/guides/#{slug}/#{fragment}"
          File.regular?(repo_path) -> "#{@github}/blob/main/#{repo_path}#{fragment}"
          File.dir?(repo_path) -> "#{@github}/tree/main/#{repo_path}"
          true -> Mix.raise("#{source} links to missing repository target #{target}")
        end
    end
  end

  # ── Page assembly ───────────────────────────────────────────────────────

  defp page_document(page, sections, pages) do
    document(
      title: "#{page.title} · PtcRunner",
      description: page.description,
      canonical: @site_origin <> page.url,
      sidebar: sidebar(sections, pages, page.slug),
      main: """
      <p class="crumb mobile-crumb"><a href="/guides/">&larr; All guides</a></p>
      <article>
      #{page.html}
      </article>
      #{pager(page)}
      <footer>
        Found a problem? <a href="#{@github}/edit/main/#{page.source}">Edit this
        guide on GitHub</a>.
      </footer>
      """
    )
  end

  defp index_document(sections, pages) do
    pages_by_source = Map.new(pages, &{&1.source, &1})

    section_html =
      Enum.map_join(sections, "\n", fn section ->
        entries =
          Enum.map_join(section.sources, "\n", fn source ->
            page = Map.fetch!(pages_by_source, source)

            """
            <li><a href="#{page.url}">#{MarkdownHTML.escape(page.title)}</a>
              <span class="desc">#{MarkdownHTML.escape(page.description)}</span></li>
            """
          end)

        """
        <h2>#{MarkdownHTML.escape(section.title)}</h2>
        <ul class="links">
        #{entries}
        </ul>
        """
      end)

    document(
      title: "Guides · PtcRunner",
      description:
        "Task-focused guides for building, configuring, and debugging PtcRunner projects.",
      canonical: @site_origin <> "/guides/",
      sidebar: sidebar(sections, pages, nil),
      main: """
      <article>
      <h1>Guides</h1>
      <p class="lead">Task-focused guides, in reading order. Start at the top if
      PtcRunner is new to you.</p>
      #{section_html}
      </article>
      """
    )
  end

  defp sidebar(sections, pages, current_slug) do
    pages_by_source = Map.new(pages, &{&1.source, &1})

    section_html =
      Enum.map_join(sections, "\n", fn section ->
        entries =
          Enum.map_join(section.sources, "\n", fn source ->
            page = Map.fetch!(pages_by_source, source)

            current =
              if page.slug == current_slug,
                do: ~s( class="current" aria-current="page"),
                else: ""

            ~s(<li><a href="#{page.url}"#{current}>#{MarkdownHTML.escape(page.title)}</a></li>)
          end)

        """
        <h2>#{MarkdownHTML.escape(section.title)}</h2>
        <ul>
        #{entries}
        </ul>
        """
      end)

    """
    <aside class="guide-nav">
      <p class="brand"><a href="/">PtcRunner</a></p>
      <nav aria-label="Guides">
        <p class="nav-home"><a href="/guides/">All guides</a></p>
    #{section_html}
      </nav>
    </aside>
    """
  end

  defp pager(page) do
    previous =
      if page.previous do
        ~s(<a class="pager-previous" href="#{page.previous.url}">&larr; #{MarkdownHTML.escape(page.previous.title)}</a>)
      else
        ""
      end

    next =
      if page.next do
        ~s(<a class="pager-next" href="#{page.next.url}">#{MarkdownHTML.escape(page.next.title)} &rarr;</a>)
      else
        ""
      end

    if previous == "" and next == "" do
      ""
    else
      ~s(<nav class="pager" aria-label="Guide order">#{previous}#{next}</nav>)
    end
  end

  defp document(assigns) do
    title = Keyword.fetch!(assigns, :title)
    description = Keyword.fetch!(assigns, :description)
    canonical = Keyword.fetch!(assigns, :canonical)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{MarkdownHTML.escape(title)}</title>
    <meta name="description" content="#{MarkdownHTML.escape(description)}">
    <link rel="canonical" href="#{canonical}">
    <meta property="og:title" content="#{MarkdownHTML.escape(title)}">
    <meta property="og:description" content="#{MarkdownHTML.escape(description)}">
    <meta property="og:url" content="#{canonical}">
    <meta property="og:type" content="article">
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>&#9883;</text></svg>">
    <link rel="stylesheet" href="/style.css">
    <link rel="stylesheet" href="/guides.css">
    </head>
    <body>
    <div class="guide-shell">
    #{Keyword.fetch!(assigns, :sidebar)}
    <main class="guide-main">
    #{Keyword.fetch!(assigns, :main)}
    </main>
    </div>
    </body>
    </html>
    """
  end

  # ── Write and check, with orphan detection ──────────────────────────────

  defp published_pages do
    [Path.join(@output_root, "**/*.html"), Path.join(@output_root, "*.html")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp check!(expected) do
    stale =
      Enum.flat_map(expected, fn {path, content} ->
        case File.read(path) do
          {:ok, ^content} -> []
          {:ok, _stale} -> ["stale: #{path}"]
          {:error, _reason} -> ["missing: #{path}"]
        end
      end)

    orphaned =
      for path <- published_pages(), not Map.has_key?(expected, path), do: "orphaned: #{path}"

    case stale ++ orphaned do
      [] ->
        Mix.shell().info("Verified #{map_size(expected)} site guide pages")

      problems ->
        Mix.raise("""
        Site guide pages are out of date; run `mix ptc.gen_docs` (or
        `mix ptc.gen_site_guides`) and stage site/guides.
        #{Enum.join(problems, "\n")}
        """)
    end
  end

  defp write!(expected) do
    Enum.each(expected, fn {path, content} ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    for path <- published_pages(), not Map.has_key?(expected, path) do
      File.rm!(path)
      # A renamed guide leaves its old directory behind; remove it once empty.
      _ = File.rmdir(Path.dirname(path))
      Mix.shell().info("Removed orphaned #{path}")
    end

    Mix.shell().info("Generated #{map_size(expected)} site guide pages")
  end
end
