defmodule PtcRunner.Kernel.DocumentationLibrary do
  @moduledoc """
  Documentation pages embedded at compile time and served by `ptc docs`.

  Each page is read from its repository source while the application compiles,
  so an installed executable serves documentation describing its own version
  without filesystem or network access. Page titles are derived from the source
  document rather than restated here.

  This module is the only declaration of the served set. `PtcRunner.Kernel.CommandContract`
  derives the accepted page names from `names/0`, and the catalog order below is
  the order `ptc docs` lists.
  """

  @root Path.expand("../../..", __DIR__)

  # Ordered by the sequence an author needs them: orientation, then authoring,
  # then execution, then evidence, then the machine-readable schemas.
  @catalog [
    {"agent-guide", "docs/guides/agent-cli-usage.md"},
    {"cli", "docs/reference/cli.md"},
    {"ptc-lisp", "docs/ptc-lisp-specification.md"},
    {"functions", "docs/function-reference.md"},
    {"preludes", "docs/prelude-reference.md"},
    {"agent-library", "docs/agent-library-reference.md"},
    {"signatures", "docs/signature-syntax.md"},
    {"manifest", "docs/reference/application-manifest.md"},
    {"components", "docs/reference/component-contracts.md"},
    {"project", "docs/reference/project-files.md"},
    {"host", "docs/reference/host-installation.md"},
    {"mcp", "docs/reference/mcp.md"},
    {"limits", "docs/kernel-limits-reference.md"},
    {"repl", "docs/reference/repl.md"},
    {"debug", "docs/reference/debug-navigation.md"},
    {"traces", "docs/trace-log-contract.md"},
    {"schema-manifest", "priv/schemas/ptc-application-manifest.schema.json"},
    {"schema-project", "priv/schemas/ptc-project-config.schema.json"},
    {"schema-host", "priv/schemas/ptc-host-config.schema.json"}
  ]

  for {_name, path} <- @catalog do
    @external_resource Path.join(@root, path)
  end

  @pages (for {name, path} <- @catalog do
            content = File.read!(Path.join(@root, path))

            title =
              if String.ends_with?(path, ".json") do
                content |> Jason.decode!() |> Map.fetch!("title")
              else
                content
                |> String.split("\n")
                |> Enum.find_value(fn
                  "# " <> heading -> String.trim(heading)
                  _line -> nil
                end) || raise("documentation page #{path} has no level-1 heading")
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
