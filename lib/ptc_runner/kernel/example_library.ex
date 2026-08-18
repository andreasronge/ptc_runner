defmodule PtcRunner.Kernel.ExampleLibrary do
  @moduledoc """
  Runnable example projects embedded at compile time and materialized by
  `ptc init DIRECTORY --example NAME`.

  The documentation prints `ptc run examples/…` commands. A release is a bare
  Mix release tree that copies no `examples/` directory, so those commands read
  as runnable and are not — and even in a checkout they work from exactly one
  directory. Each example is therefore embedded the way documentation pages are,
  and `ptc init --example` writes the tree wherever the caller asks for it.

  A tree is embedded byte-for-byte, including its relative layout, so a
  materialized example is the same project the repository tests exercise. Paths
  inside it stay valid because nothing is rewritten and nothing is flattened.
  """

  @root Path.expand("../../..", __DIR__)

  # One entry per self-contained walkthrough. A tree is the unit rather than a
  # single project because these walkthroughs are multi-project by design: the
  # debug example's host document reads the trace directory the failing project
  # writes, and the tutorial's five steps share one host document.
  @catalog [
    {"kernel-tutorial", "examples/kernel-tutorial",
     "Five numbered projects: deterministic workflow, model extraction, file agent, multi-turn agent, signature feedback"},
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

            if map_size(files) == 0 do
              raise "example #{name} embeds no files"
            end

            %{
              name: name,
              description: description,
              files: files,
              created:
                files
                |> Map.keys()
                |> Enum.map(&(&1 |> Path.split() |> hd()))
                |> Enum.uniq()
                |> Enum.sort(),
              bytes: files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()
            }
          end)

  for tree <- @trees, {relative, _content} <- tree.files do
    @external_resource Path.join([@root, "examples", tree.name, relative])
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
