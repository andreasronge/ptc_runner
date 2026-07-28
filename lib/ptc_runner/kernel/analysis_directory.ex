defmodule PtcRunner.Kernel.AnalysisDirectory do
  @moduledoc false

  @type identity :: {integer(), integer(), integer()}
  @type resolved :: %{
          required(:path) => binary(),
          required(:identity) => identity(),
          required(:lineage) => MapSet.t(identity())
        }

  @doc false
  @spec resolve(term()) :: {:ok, resolved()} | {:error, :directory_identity_unavailable}
  def resolve(directory) when is_binary(directory) do
    with true <- String.valid?(directory),
         expanded = Path.expand(directory),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded),
         {:ok, physical} <- physical_directory_path(expanded),
         {:ok, identity} <- raw_identity(physical),
         {:ok, lineage} <- collect_lineage(physical, []) do
      {:ok, %{path: expanded, identity: identity, lineage: MapSet.new(lineage)}}
    else
      _ -> {:error, :directory_identity_unavailable}
    end
  rescue
    _exception -> {:error, :directory_identity_unavailable}
  end

  def resolve(_directory), do: {:error, :directory_identity_unavailable}

  @doc false
  @spec pairwise_separate?([resolved()]) :: boolean()
  def pairwise_separate?(directories) when is_list(directories) do
    Enum.with_index(directories)
    |> Enum.all?(fn {%{identity: identity, lineage: lineage}, index} ->
      directories
      |> Enum.drop(index + 1)
      |> Enum.all?(fn %{identity: other_identity, lineage: other_lineage} ->
        not MapSet.member?(other_lineage, identity) and
          not MapSet.member?(lineage, other_identity)
      end)
    end)
  end

  def pairwise_separate?(_directories), do: false

  defp physical_directory_path(directory) do
    relative = Path.relative_to(directory, "/")
    resolve_physical_segments(Path.split(relative), 0)
  end

  defp resolve_physical_segments(_segments, depth) when depth > 32,
    do: {:error, :directory_identity_unavailable}

  defp resolve_physical_segments(segments, depth) do
    segments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, "/"}, fn {segment, index}, {:ok, parent} ->
      candidate = Path.join(parent, segment)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} ->
          resolve_symlink(candidate, parent, segments, index, depth)

        {:ok, _stat} ->
          {:cont, {:ok, candidate}}

        {:error, _reason} ->
          {:halt, {:error, :directory_identity_unavailable}}
      end
    end)
  end

  defp resolve_symlink(candidate, parent, segments, index, depth) do
    case File.read_link(candidate) do
      {:ok, target} ->
        target_segments =
          target
          |> Path.expand(parent)
          |> Path.relative_to("/")
          |> Path.split()

        remaining = Enum.drop(segments, index + 1)
        {:halt, resolve_physical_segments(target_segments ++ remaining, depth + 1)}

      {:error, _reason} ->
        {:halt, {:error, :directory_identity_unavailable}}
    end
  end

  defp collect_lineage(directory, identities) do
    with {:ok, identity} <- raw_identity(directory) do
      next = [identity | identities]
      parent = Path.dirname(directory)

      if parent == directory,
        do: {:ok, next},
        else: collect_lineage(parent, next)
    end
  end

  defp raw_identity(directory) do
    case File.stat(directory) do
      {:ok,
       %File.Stat{
         type: :directory,
         major_device: major,
         minor_device: minor,
         inode: inode
       }}
      when is_integer(major) and is_integer(minor) and is_integer(inode) ->
        {:ok, {major, minor, inode}}

      _ ->
        {:error, :directory_identity_unavailable}
    end
  end
end
