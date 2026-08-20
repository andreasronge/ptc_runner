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
    {"building-agents", "docs/guides/building-agents.md"},
    {"manifests-and-capabilities", "docs/guides/manifests-and-capabilities.md"},
    {"components-and-preludes", "docs/guides/components-and-preludes.md"},
    {"using-models", "docs/guides/using-models.md"},
    {"host-configuration", "docs/guides/host-configuration.md"},
    {"project-configuration", "docs/guides/project-configuration.md"},
    {"connecting-tools-with-mcp", "docs/guides/connecting-tools-with-mcp.md"},
    {"running-and-debugging", "docs/guides/running-and-debugging.md"},
    {"debugging-a-failed-run", "docs/guides/debugging-a-failed-run.md"},
    {"evaluating-with-replay", "docs/guides/evaluating-with-replay.md"},
    {"kernel-repl", "docs/guides/kernel-repl.md"},
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
    {"host", "docs/reference/host-installation.md"},
    {"mcp", "docs/reference/mcp.md"},
    {"limits", "docs/kernel-limits-reference.md"},
    {"repl", "docs/reference/repl.md"},
    {"debug", "docs/reference/debug-navigation.md"},
    {"traces", "docs/reference/trace-log-contract.md"},
    {"install", "docs/installation/standalone.md"},
    {"install-docker", "docs/installation/docker.md"},
    {"install-source", "docs/installation/source.md"},
    {"schema-manifest", "priv/schemas/ptc-application-manifest.schema.json"},
    {"schema-project", "priv/schemas/ptc-project-config.schema.json"},
    {"schema-host", "priv/schemas/ptc-host-config.schema.json"},
    {"schema-envelope", "priv/schemas/ptc-command-envelope-v2.schema.json"}
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
end
