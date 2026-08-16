defmodule PtcRunner.Kernel.AnalysisDirectory do
  @moduledoc false

  @type identity :: {integer(), integer(), integer()}
  @type resolved :: %{
          required(:path) => binary(),
          required(:identity) => identity(),
          required(:lineage) => MapSet.t(identity())
        }

  @typedoc """
  How two resolved directories sit relative to each other on the filesystem.

  `:same` covers both an identical path and distinct paths that resolve to one
  physical directory through a symbolic link; an alias is a cause of `:same`,
  not a relationship of its own. Only `:separate` satisfies the physical
  separation rule.
  """
  @type relationship :: :separate | :same | :left_contains_right | :right_contains_left

  @typedoc """
  A resolved directory tagged with the caller's own name for its role.

  Roles are opaque here: the kernel never interprets them, and callers use
  them to attribute a rejection to the option or resource that supplied the
  directory.
  """
  @type labelled :: {term(), resolved()}

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
    directories
    |> Enum.map(&{nil, &1})
    |> first_conflict()
    |> is_nil()
  end

  def pairwise_separate?(_directories), do: false

  @doc false
  @spec relationship(resolved(), resolved()) :: relationship()
  def relationship(
        %{identity: left_identity, lineage: left_lineage},
        %{identity: right_identity, lineage: right_lineage}
      ) do
    cond do
      left_identity == right_identity -> :same
      MapSet.member?(right_lineage, left_identity) -> :left_contains_right
      MapSet.member?(left_lineage, right_identity) -> :right_contains_left
      true -> :separate
    end
  end

  @doc """
  Returns the first pair of labelled directories that are not physically
  separate, in the caller's own order, or `nil` when every pair is separate.

  The pair is reported as `{left_role, right_role, relationship}` so a
  frontend can attribute the rejection without re-deriving it.
  """
  @spec first_conflict([labelled()]) :: {term(), term(), relationship()} | nil
  def first_conflict(directories) when is_list(directories) do
    directories
    |> Enum.with_index()
    |> Enum.find_value(fn {{left_role, left}, index} ->
      directories
      |> Enum.drop(index + 1)
      |> Enum.find_value(fn {right_role, right} ->
        case relationship(left, right) do
          :separate -> nil
          conflict -> {left_role, right_role, conflict}
        end
      end)
    end)
  end

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
