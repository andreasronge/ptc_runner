defmodule PtcRunner.Kernel.DocumentationLibrary do
  @moduledoc """
  Documentation pages embedded at compile time and served by `ptc docs`.

  Each page is read from its repository source while the application compiles,
  so an installed executable serves documentation describing its own version
  without filesystem or network access. Page titles are derived from the source
  document rather than restated here.

  The catalog is closed under linking. Every relative markdown link is rewritten
  to the `ptc docs NAME` command that serves the same document, and a link that
  resolves to no served page fails the compile — so a reader who follows what a
  shipped page prints reaches a page this executable actually carries.

  This module is the only declaration of the served set. `PtcRunner.Kernel.CommandContract`
  derives the accepted page names from `names/0`, and the catalog order below is
  the order `ptc docs` lists.
  """

  alias PtcRunner.Kernel.DocumentationLinks

  @root Path.expand("../../..", __DIR__)

  # Ordered by the sequence an author needs them: orientation, then the guides
  # that teach one task each, then the references, then evidence, then the
  # machine-readable schemas.
  #
  # The set is closed under linking: every document a served page links to is
  # itself served, and the compile-time check below refuses any page that is
  # not. A reference the release cannot carry — a maintainer document, a
  # conformance audit — must therefore not be written as a link in a served
  # page.
  @catalog [
    {"agent-guide", "docs/guides/agent-cli-usage.md"},
    {"quickstart", "docs/guides/quickstart.md"},
    {"getting-started", "docs/guides/getting-started.md"},
    {"concepts", "docs/guides/concepts.md"},
    {"building-agents", "docs/guides/building-agents.md"},
    {"manifests-and-capabilities", "docs/guides/manifests-and-capabilities.md"},
    {"components-and-preludes", "docs/guides/components-and-preludes.md"},
    {"designing-agent-workflows", "docs/guides/designing-agent-workflows.md"},
    {"agent-workflow-patterns", "docs/guides/agent-workflow-patterns.md"},
    {"using-models", "docs/guides/using-models.md"},
    {"host-configuration", "docs/guides/host-configuration.md"},
    {"project-configuration", "docs/guides/project-configuration.md"},
    {"connecting-tools-with-mcp", "docs/guides/connecting-tools-with-mcp.md"},
    {"running-and-debugging", "docs/guides/running-and-debugging.md"},
    {"self-improvement", "docs/guides/self-improvement.md"},
    {"evaluating-with-replay", "docs/guides/evaluating-with-replay.md"},
    {"kernel-repl", "docs/guides/kernel-repl.md"},
    {"inspect-source", "docs/guides/inspecting-source-and-programs.md"},
    {"cli", "docs/reference/cli.md"},
    {"ptc-lisp", "docs/ptc-lisp-specification.md"},
    {"functions", "docs/function-reference.md"},
    {"preludes", "docs/prelude-reference.md"},
    {"agent-library", "docs/agent-library-reference.md"},
    {"signatures", "docs/signature-syntax.md"},
    {"java-interop", "docs/java-interop.md"},
    {"conformance-gaps", "docs/clojure-conformance-gaps.md"},
    {"manifest", "docs/reference/application-manifest.md"},
    {"components", "docs/reference/component-contracts.md"},
    {"project", "docs/reference/project-files.md"},
    {"examples", "docs/reference/examples.md"},
    {"host", "docs/reference/host-installation.md"},
    {"mcp", "docs/reference/mcp.md"},
    {"limits", "docs/kernel-limits-reference.md"},
    {"viewer", "docs/reference/viewer.md"},
    {"repl", "docs/reference/repl.md"},
    {"source-inspection", "docs/reference/source-inspection.md"},
    {"debug", "docs/reference/debug-navigation.md"},
    {"traces", "docs/maintainers/trace-log-contract.md"},
    {"install", "docs/installation/standalone.md"},
    {"install-docker", "docs/installation/docker.md"},
    {"install-source", "docs/installation/source.md"},
    {"schema-manifest", "priv/schemas/ptc-application-manifest.schema.json"},
    {"schema-project", "priv/schemas/ptc-project-config.schema.json"},
    {"schema-host", "priv/schemas/ptc-host-config.schema.json"},
    {"schema-mcp", "site/schemas/mcp-2026-07-28.schema.json"},
    {"schema-envelope", "priv/schemas/ptc-command-envelope-v4.schema.json"}
  ]

  @names_by_path Map.new(@catalog, fn {name, path} -> {path, name} end)

  for {_name, path} <- @catalog do
    @external_resource Path.join(@root, path)
  end

  @pages (for {name, path} <- @catalog do
            source = File.read!(Path.join(@root, path))

            {title, content} =
              if String.ends_with?(path, ".json") do
                {source |> Jason.decode!() |> Map.fetch!("title"), source}
              else
                title =
                  source
                  |> String.split("\n")
                  |> Enum.find_value(fn
                    "# " <> heading -> String.trim(heading)
                    _line -> nil
                  end) || raise("documentation page #{path} has no level-1 heading")

                case DocumentationLinks.rewrite(source, path, @names_by_path) do
                  {:ok, rewritten} ->
                    {title, rewritten}

                  {:error, unresolved} ->
                    raise "documentation page #{path} links to documents this executable " <>
                            "does not serve: #{Enum.join(unresolved, ", ")}"
                end
              end

            %{name: name, title: title, bytes: byte_size(content), content: content}
          end)

  @names Enum.map(@pages, & &1.name)

  if length(Enum.uniq(@names)) != length(@names) do
    raise "duplicate ptc docs page name"
  end

  @listing Enum.map(@pages, fn page ->
             %{"name" => page.name, "title" => page.title, "bytes" => page.bytes}
           end)
  @contents Map.new(@pages, &{&1.name, &1.content})
  @source_paths Map.new(@catalog, fn {name, path} -> {name, path} end)
  @max_search_pages 10
  @max_search_lines_per_page 3
  @max_search_line_length 160

  @doc """
  Returns every served page name, in catalog order.
  """
  @spec names() :: [binary()]
  def names, do: @names

  @doc """
  Returns the public listing of served pages, in catalog order.

  Each entry carries the page `name` accepted by `fetch/1`, the `title` derived
  from the source document, and the exact embedded size in `bytes`.
  """
  @spec listing() :: [%{optional(binary()) => binary() | non_neg_integer()}]
  def listing, do: @listing

  @doc false
  @spec source_path(binary()) :: binary() | nil
  def source_path(name) when is_binary(name), do: Map.get(@source_paths, name)

  @doc """
  Returns the embedded content of one page.

  ## Examples

      iex> {:ok, content} = PtcRunner.Kernel.DocumentationLibrary.fetch("agent-guide")
      iex> String.starts_with?(content, "# Drive ptc as an agent")
      true

      iex> PtcRunner.Kernel.DocumentationLibrary.fetch("nonexistent")
      :error
  """
  @spec fetch(binary()) :: {:ok, binary()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(@contents, name)
  def fetch(_name), do: :error

  @doc """
  Searches the embedded prose pages for a case-insensitive substring.

  Pages with a heading match rank first, followed by total match count and
  catalog order. Results retain at most three lines from each of ten pages.
  """
  @spec search(binary()) :: map()
  def search(term) when is_binary(term) and byte_size(term) > 0 do
    pattern = Regex.compile!(Regex.escape(term), "iu")

    pages =
      @pages
      |> Enum.with_index()
      |> Enum.reject(fn {page, _index} -> String.starts_with?(page.name, "schema-") end)
      |> Enum.flat_map(&page_matches(&1, pattern))
      |> Enum.sort_by(fn page ->
        {if(page.heading_match?, do: 0, else: 1), -length(page.matches), page.index}
      end)

    included_pages = Enum.take(pages, @max_search_pages)

    matches =
      Enum.flat_map(included_pages, fn page ->
        Enum.take(page.matches, @max_search_lines_per_page)
      end)

    %{
      "term" => term,
      "matches" => matches,
      "omitted_matches" => Enum.sum(Enum.map(pages, &length(&1.matches))) - length(matches),
      "omitted_pages" => max(length(pages) - length(included_pages), 0)
    }
  end

  @doc false
  @spec suggested_search(binary()) :: binary() | nil
  def suggested_search(term) when is_binary(term) do
    segment = term |> String.split([".", "/"]) |> List.last()

    if segment not in [nil, "", term] and search(segment)["matches"] != [],
      do: segment,
      else: nil
  end

  defp page_matches({page, index}, pattern) do
    if Regex.match?(pattern, page.content) do
      {matches, heading_match?} =
        page.content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce({[], false}, fn {line, line_number}, {matches, heading_match?} ->
          if Regex.match?(pattern, line),
            do: {
              [
                %{
                  "page" => page.name,
                  "line" => line_number,
                  "text" => line |> String.trim() |> String.slice(0, @max_search_line_length)
                }
                | matches
              ],
              heading_match? or Regex.match?(~r/^ {0,3}\#{1,6}(?:\s|$)/, line)
            },
            else: {matches, heading_match?}
        end)

      matches = Enum.reverse(matches)

      [%{index: index, heading_match?: heading_match?, matches: matches}]
    else
      []
    end
  end
end
