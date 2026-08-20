defmodule Mix.Tasks.Ptc.GenSiteGuides do
  @shortdoc "Generate the static-site documentation pages from docs/"
  @moduledoc """
  Renders the published documentation groups into committed pages under
  `site/guides/`, `site/installation/`, and `site/reference/`, plus the
  directory page at `site/guides/index.html`, and rewrites the shared
  sidebar between the generated markers in `site/index.html`.

  The sidebar structure is read from the same `mix.exs` configuration ExDoc
  uses — `:groups_for_extras` names the sections and `:extras` orders the
  pages — so the HexDocs sidebar and the site sidebar cannot drift apart.
  Only the groups named in `@published_roots` are published; maintainer and
  conformance material stays on GitHub.

      mix ptc.gen_site_guides
      mix ptc.gen_site_guides --check

  `--check` verifies the checked-in pages without rewriting them and fails
  on a stale, missing, or orphaned page (a renamed source file leaves an
  orphan behind). `mix ptc.gen_docs` runs this task, so regenerating the
  docs regenerates these pages too.

  Relative links to a published page become site links (validated down to
  the anchor); relative links to any other repository file become GitHub
  links and must name a file that exists. Everything else the renderer does
  not recognise fails the run — see `PtcRunner.SiteGuides.MarkdownHTML`.
  """
  use Mix.Task

  alias PtcRunner.SiteGuides.MarkdownHTML

  @site_origin "https://ptc-runner.dev"
  @github "https://github.com/andreasronge/ptc_runner"

  # Which documentation groups the site publishes, and the URL root each
  # one's pages live under. Sidebar order follows :groups_for_extras.
  @published_roots %{
    "Start" => "guides",
    "Language" => "guides",
    "Configure" => "guides",
    "Build" => "guides",
    "Design" => "guides",
    "Run and debug" => "guides",
    "Installation" => "installation",
    "Reference" => "reference"
  }

  @landing_page "site/index.html"
  @sidebar_begin "<!-- BEGIN GENERATED: site sidebar (mix ptc.gen_site_guides) -->"
  @sidebar_end "<!-- END GENERATED: site sidebar -->"

  @impl Mix.Task
  def run(args) do
    check? = "--check" in args
    sections = sections!()
    pages = render_pages(sections)

    expected =
      Map.new(pages, fn page -> {page.output_path, page_document(page, sections, pages)} end)

    expected =
      expected
      |> Map.put(Path.join("site/guides", "index.html"), index_document(sections, pages))
      |> Map.put(@landing_page, landing_document(sections, pages))
      |> Map.merge(vendored_highlighter())

    validate_anchors!(expected)

    if check? do
      check!(expected)
    else
      write!(expected)
    end
  end

  # ── Section structure, from the ExDoc configuration ─────────────────────

  defp sections! do
    docs = Mix.Project.config() |> Keyword.fetch!(:docs)
    extras = docs |> Keyword.fetch!(:extras) |> Enum.flat_map(&extra_path/1)

    groups =
      docs |> Keyword.fetch!(:groups_for_extras) |> Enum.map(fn {k, v} -> {to_string(k), v} end)

    known = MapSet.new(groups, fn {title, _members} -> title end)

    for {title, _root} <- @published_roots, not MapSet.member?(known, title) do
      Mix.raise("Published group #{inspect(title)} does not exist in mix.exs :groups_for_extras")
    end

    # Mirror ExDoc: each extra belongs to the first group that matches it.
    group_of = fn path ->
      Enum.find_value(groups, fn {title, members} ->
        if group_member?(members, path), do: title
      end)
    end

    members_by_title =
      extras
      |> Enum.map(&{group_of.(&1), &1})
      |> Enum.group_by(fn {title, _path} -> title end, fn {_title, path} -> path end)

    sections =
      groups
      |> Enum.filter(fn {title, _members} -> Map.has_key?(@published_roots, title) end)
      |> Enum.map(fn {title, members} ->
        sources = Map.get(members_by_title, title, [])

        if sources == [] do
          Mix.raise("Published group #{inspect(title)} matches no extras")
        end

        if is_list(members) and members != sources do
          Mix.raise("""
          Group #{inspect(title)} lists its pages in a different order than
          :extras. ExDoc orders pages by :extras; make both orders agree.
          """)
        end

        %{title: title, root: Map.fetch!(@published_roots, title), sources: sources}
      end)

    orphaned_guides =
      Enum.filter(extras, fn path ->
        String.starts_with?(path, "docs/guides/") and
          group_of.(path) not in Map.keys(@published_roots)
      end)

    if orphaned_guides != [] do
      Mix.raise("Guides outside every published group: #{inspect(orphaned_guides)}")
    end

    sections
  end

  defp extra_path(path) when is_binary(path), do: [path]

  defp extra_path({path, options}) when is_binary(path) and is_list(options),
    do: if(Keyword.has_key?(options, :url), do: [], else: [path])

  defp group_member?(members, path) when is_list(members), do: path in members
  defp group_member?(%Regex{} = members, path), do: Regex.match?(members, path)

  # ── Rendering ───────────────────────────────────────────────────────────

  defp render_pages(sections) do
    url_by_source =
      for section <- sections, source <- section.sources, into: %{} do
        {source, "/#{section.root}/#{Path.basename(source, ".md")}/"}
      end

    ordered =
      Enum.flat_map(sections, fn section ->
        Enum.map(section.sources, fn source ->
          rendered =
            source
            |> File.read!()
            |> MarkdownHTML.render!(source, &rewrite_link(&1, source, url_by_source))

          url = Map.fetch!(url_by_source, source)

          %{
            source: source,
            slug: Path.basename(source, ".md"),
            url: url,
            output_path: Path.join(["site", String.trim(url, "/"), "index.html"]),
            section: section.title,
            title: rendered.title,
            description: rendered.description,
            html: rendered.html
          }
        end)
      end)

    outputs = Enum.map(ordered, & &1.output_path)

    if Enum.uniq(outputs) != outputs do
      Mix.raise("Two published pages collide: #{inspect(outputs -- Enum.uniq(outputs))}")
    end

    Enum.with_index(ordered, fn page, index ->
      previous = if index > 0, do: Enum.at(ordered, index - 1)

      page
      |> Map.put(:previous, previous)
      |> Map.put(:next, Enum.at(ordered, index + 1))
    end)
  end

  # Published pages link to each other; anything else relative must exist in
  # the repository and is published as a GitHub link. Unknown shapes raise so
  # a typo cannot ship as a dead link.
  @doc false
  def rewrite_link(target, source, url_by_source) do
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
          url = Map.get(url_by_source, repo_path) -> "#{url}#{fragment}"
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
      <p class="crumb mobile-crumb"><a href="/guides/">&larr; All documentation</a></p>
      <article>
      #{page.html}
      </article>
      #{pager(page)}
      <footer>
        Found a problem? <a href="#{@github}/edit/main/#{page.source}">Edit this
        page on GitHub</a>.
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
      title: "Documentation · PtcRunner",
      description:
        "Task-focused guides, installation routes, and the reference documentation for PtcRunner.",
      canonical: @site_origin <> "/guides/",
      sidebar: sidebar(sections, pages, nil),
      main: """
      <article>
      <h1>Documentation</h1>
      <p class="lead">Guides in reading order, the installation routes, and the
      reference pages. Start at the top if PtcRunner is new to you.</p>
      #{section_html}
      </article>
      """
    )
  end

  # The landing page is hand-written; only the sidebar between the generated
  # markers belongs to this task.
  defp landing_document(sections, pages) do
    content = File.read!(@landing_page)

    unless String.contains?(content, @sidebar_begin) and String.contains?(content, @sidebar_end) do
      Mix.raise("#{@landing_page} is missing its generated sidebar markers")
    end

    [head, rest] = String.split(content, @sidebar_begin, parts: 2)
    [_stale, tail] = String.split(rest, @sidebar_end, parts: 2)

    head <> @sidebar_begin <> "\n" <> sidebar(sections, pages, nil) <> @sidebar_end <> tail
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
      <nav aria-label="Documentation">
        <p class="nav-home"><a href="/guides/">Overview</a></p>
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
      ~s(<nav class="pager" aria-label="Reading order">#{previous}#{next}</nav>)
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
    <script type="module" src="/docs.js"></script>
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

  # The site highlights PTC-Lisp with the same vendored highlight.js core and
  # Clojure grammar as the Viewer; copying at generation time is what keeps
  # the two the same bytes.
  defp vendored_highlighter do
    viewer_vendor = "ptc_viewer/priv/static/js/vendor/highlightjs"

    Map.new(["core.min.js", "clojure.min.js"], fn file ->
      {Path.join("site/vendor/highlightjs", file), File.read!(Path.join(viewer_vendor, file))}
    end)
  end

  # ── Anchor validation across the published pages ────────────────────────

  # Every internal fragment link must name an id that exists on its target
  # page, so a renamed heading fails generation instead of shipping as a
  # dead in-page jump.
  defp validate_anchors!(expected) do
    expected =
      for {path, html} <- expected, String.ends_with?(path, ".html"), into: %{}, do: {path, html}

    ids_by_path =
      Map.new(expected, fn {path, html} ->
        ids =
          ~r/ id="([^"]+)"/
          |> Regex.scan(html, capture: :all_but_first)
          |> List.flatten()
          |> MapSet.new()

        {path, ids}
      end)

    errors =
      Enum.flat_map(expected, fn {path, html} ->
        ~r{href="(/[^"#]*/)#([^"]+)"}
        |> Regex.scan(html, capture: :all_but_first)
        |> Enum.flat_map(fn [target_url, fragment] ->
          target_path = Path.join(["site", String.trim(target_url, "/"), "index.html"])

          case Map.fetch(ids_by_path, target_path) do
            {:ok, ids} ->
              if MapSet.member?(ids, fragment),
                do: [],
                else: ["#{path} links to missing anchor #{target_url}##{fragment}"]

            :error ->
              ["#{path} links to unpublished target #{target_url}##{fragment}"]
          end
        end)
      end)

    if errors != [] do
      Mix.raise("Internal anchors are broken:\n" <> Enum.join(errors, "\n"))
    end
  end

  # ── Write and check, with orphan detection ──────────────────────────────

  defp output_roots do
    @published_roots
    |> Map.values()
    |> Enum.uniq()
    |> Enum.map(&Path.join("site", &1))
  end

  defp published_pages do
    output_roots()
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join(root, "**/*.html")) ++ Path.wildcard(Path.join(root, "*.html"))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp check!(expected) do
    stale =
      Enum.flat_map(expected, fn {path, content} ->
        case File.read(path) do
          {:ok, ^content} -> []
          {:ok, committed} -> ["stale: #{path}\n#{first_difference(committed, content)}"]
          {:error, _reason} -> ["missing: #{path}"]
        end
      end)

    orphaned =
      for path <- published_pages(), not Map.has_key?(expected, path), do: "orphaned: #{path}"

    case stale ++ orphaned do
      [] ->
        Mix.shell().info("Verified #{map_size(expected)} site documentation pages")

      problems ->
        Mix.raise("""
        Site documentation pages are out of date; run `mix ptc.gen_docs` (or
        `mix ptc.gen_site_guides`) and stage site/.
        #{Enum.join(problems, "\n")}
        """)
    end
  end

  # A bare "stale" from CI is undiagnosable when the local render matches, so
  # a mismatch names the first differing line of both versions.
  defp first_difference(committed, rendered) do
    committed_lines = String.split(committed, "\n")
    rendered_lines = String.split(rendered, "\n")
    count = max(length(committed_lines), length(rendered_lines))

    index =
      Enum.find(0..(count - 1), fn i ->
        Enum.at(committed_lines, i) != Enum.at(rendered_lines, i)
      end)

    """
      first difference at line #{index + 1}
      committed: #{inspect(Enum.at(committed_lines, index), printable_limit: 200)}
      rendered:  #{inspect(Enum.at(rendered_lines, index), printable_limit: 200)}\
    """
  end

  defp write!(expected) do
    Enum.each(expected, fn {path, content} ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    for path <- published_pages(), not Map.has_key?(expected, path) do
      File.rm!(path)
      # A renamed source leaves its old directory behind; remove it once empty.
      _ = File.rmdir(Path.dirname(path))
      Mix.shell().info("Removed orphaned #{path}")
    end

    Mix.shell().info("Generated #{map_size(expected)} site documentation pages")
  end
end
