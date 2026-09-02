defmodule PtcRunner.Kernel.ExampleLibrary do
  @moduledoc """
  Runnable example projects embedded at compile time and materialized by
  `ptc init DIRECTORY --example NAME`.

  The documentation prints `ptc run examples/…` commands. A release is a bare
  Mix release tree that copies no `examples/` directory, so those commands read
  as runnable and are not — and even in a checkout they work from exactly one
  directory. Each example is therefore embedded the way documentation pages are,
  and `ptc init --example` writes the tree wherever the caller asks for it.

  A tree is embedded from its checked-in files. `.env` stubs are generated from
  host credential declarations when a project names an `env_file`, and a
  `.gitignore` is generated when the tree has none, so a materialized copy can
  run without a checkout. Paths inside the tree stay valid because nothing is
  rewritten and nothing is flattened.
  """

  @root Path.expand("../../..", __DIR__)

  # One entry per self-contained walkthrough. A tree is the unit rather than a
  # single project because these walkthroughs are multi-project by design: the
  # debug example's host document reads the trace directory the failing project
  # writes, and the tutorial's live success steps share one host document.
  @catalog [
    {"kernel-tutorial", "examples/kernel-tutorial",
     "Six numbered projects: deterministic workflow, model extraction, file agent, multi-turn agent, signature feedback, deliberate cost-budget refusal"},
    {"support-triage", "examples/support-triage",
     "Three numbered projects growing one support-inbox scenario: one bounded question, a triage policy as a mission API, two specialist missions with a result contract"},
    {"debug-a-failed-run", "examples/debug-a-failed-run",
     "A failing project plus the deterministic and agent debuggers that read its evidence"},
    {"llm-replay", "examples/llm-replay",
     "A frozen-model project with the replay fixture its host document selects"}
  ]

  # Everything under an example tree ships, except artifacts a run produces and
  # local environment files, which are per-machine rather than part of the
  # example.
  @excluded_directories [".ptc"]
  @excluded_files [".env"]
  @gitignore """
  .env
  .ptc/
  .ptc-private-*
  .ptc-private-result-*
  """

  env_file_paths = fn files ->
    files
    |> Enum.flat_map(fn {_path, content} ->
      case Jason.decode(content) do
        {:ok, %{"kind" => "ptc-project", "host" => %{"env_file" => %{"path" => path}}}}
        when is_binary(path) and path != "" ->
          [path]

        _other ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  credential_env_names = fn files ->
    files
    |> Enum.flat_map(fn {_path, content} ->
      case Jason.decode(content) do
        {:ok, %{"credentials" => credentials}} when is_map(credentials) ->
          for {_name, %{"env" => env}} <- credentials, is_binary(env) and env != "", do: env

        _other ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  env_stub = fn
    [] ->
      "# Local environment for this example.\n"

    names ->
      "# Local credentials for this example. Export them or add non-empty assignments here; do not commit secrets.\n" <>
        Enum.map_join(names, "", &"# #{&1}\n")
  end

  with_generated_files = fn files ->
    files =
      if Map.has_key?(files, ".gitignore"),
        do: files,
        else: Map.put(files, ".gitignore", @gitignore)

    stub = env_stub.(credential_env_names.(files))

    Enum.reduce(env_file_paths.(files), files, fn path, acc ->
      if Map.has_key?(acc, path), do: acc, else: Map.put(acc, path, stub)
    end)
  end

  created_entries = fn files ->
    files
    |> Map.keys()
    |> Enum.map(&(&1 |> Path.split() |> hd()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @trees (for {name, directory, description} <- @catalog do
            absolute = Path.join(@root, directory)

            files =
              absolute
              |> Path.join("**")
              |> Path.wildcard(match_dot: false)
              |> Enum.filter(&File.regular?/1)
              |> Enum.map(&Path.relative_to(&1, absolute))
              |> Enum.reject(fn relative ->
                segments = Path.split(relative)

                Enum.any?(segments, &(&1 in @excluded_directories)) or
                  List.last(segments) in @excluded_files
              end)
              |> Enum.sort()
              |> Map.new(&{&1, File.read!(Path.join(absolute, &1))})
              |> with_generated_files.()

            if map_size(files) == 0 do
              raise "example #{name} embeds no files"
            end

            %{
              name: name,
              description: description,
              files: files,
              created: created_entries.(files),
              bytes: files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()
            }
          end)

  for tree <- @trees,
      {relative, _content} <- tree.files,
      source = Path.join([@root, "examples", tree.name, relative]),
      File.regular?(source) do
    @external_resource source
  end

  @names Enum.map(@trees, & &1.name)

  if length(Enum.uniq(@names)) != length(@names) do
    raise "duplicate ptc init example name"
  end

  @listing Enum.map(@trees, fn tree ->
             %{
               "name" => tree.name,
               "description" => tree.description,
               "files" => map_size(tree.files),
               "bytes" => tree.bytes
             }
           end)
  @files Map.new(@trees, &{&1.name, &1.files})
  @created Map.new(@trees, &{&1.name, &1.created})

  @doc "Returns every embedded example name, in catalog order."
  @spec names() :: [binary()]
  # This accessor pair matches DocumentationLibrary's because both are
  # compile-time embedded catalogs with a closed name set. Their payloads differ
  # — one page of text against a file tree with its own created list — so
  # sharing them would mean a macro hiding two shapes behind one name.
  # ex_dna:disable-for-next-line — two independent embedded catalogs, deliberately alike
  def names, do: @names

  @doc "Returns the public listing of embedded examples, in catalog order."
  @spec listing() :: [map()]
  def listing, do: @listing

  @doc """
  Returns one example's files as a map of tree-relative path to exact content.

  ## Examples

      iex> {:ok, files} = PtcRunner.Kernel.ExampleLibrary.fetch("llm-replay")
      iex> Map.has_key?(files, "replay.jsonl")
      true

      iex> PtcRunner.Kernel.ExampleLibrary.fetch("nonexistent")
      :error
  """
  @spec fetch(binary()) :: {:ok, %{binary() => binary()}} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(@files, name)
  def fetch(_name), do: :error

  @doc """
  Returns the sorted top-level entries `ptc init --example NAME` creates.

  The command envelope seals this list per example, the way it seals the
  scaffold's own, so a published tree cannot quietly gain or lose a top-level
  entry.
  """
  @spec created(binary()) :: {:ok, [binary()]} | :error
  def created(name) when is_binary(name), do: Map.fetch(@created, name)
  def created(_name), do: :error
end
