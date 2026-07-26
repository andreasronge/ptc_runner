defmodule PtcRunner.Kernel.ConfinedFile do
  @moduledoc """
  Reads one bounded UTF-8 file from a trusted root.

  This is PtcRunner's own loading primitive for host configuration, manifests,
  PTC-Lisp components, contracts, and selected input. It is not a capability
  and is never reachable from a generated program: nothing here is exposed
  through Lisp discovery metadata or a provider callback.

  Confinement is enforced before any content is read. A relative path is
  rejected outright when it is absolute, empty, oversized, contains a NUL
  byte, or carries an empty, `.`, or `..` segment. Symbolic links are then
  resolved segment by segment; a link is followed only while its target stays
  inside the root, and the fully resolved path is re-checked against the root
  before it is opened. Traversal therefore fails as an explicit error rather
  than resolving to a path outside the grant.

  The bounded read rejects a non-regular file, a file larger than the caller's
  ceiling, and invalid UTF-8. The target is stat-checked before opening, after
  opening, and again after reading, so a file replaced mid-read fails instead
  of returning a mixture of two files.

  Trusted loading previously borrowed this behavior from the removed public
  file capability, freezing the entire root to return one manifest. This
  primitive now owns the trusted-loading contract independently; generated
  programs use explicitly installed MCP filesystem tools instead.
  """

  @max_path_bytes 1_024
  @max_symlink_depth 16

  @type error ::
          :invalid_path
          | :symlink_escape
          | :symlink_depth_exceeded
          | :not_found
          | :not_regular
          | :too_large
          | :invalid_utf8
          | :changed_during_read

  @doc """
  Reads `relative_path` beneath `root`, returning at most `max_bytes` of UTF-8
  content.

  `root` must be an existing directory. The path is confined to that root as
  described in the module documentation.
  """
  @spec read(binary(), binary(), pos_integer()) :: {:ok, binary()} | {:error, error()}
  def read(root, relative_path, max_bytes)
      when is_binary(root) and is_binary(relative_path) and is_integer(max_bytes) and
             max_bytes > 0 do
    with :ok <- validate_relative(relative_path),
         canonical_root = Path.expand(root),
         {:ok, %File.Stat{type: :directory}} <- lstat(canonical_root),
         {:ok, resolved} <- resolve_relative(canonical_root, relative_path),
         absolute = Path.expand(Path.join(canonical_root, resolved)),
         true <- within_root?(canonical_root, absolute) do
      read_bounded(absolute, max_bytes)
    else
      {:error, reason} when is_atom(reason) -> {:error, normalize(reason)}
      _other -> {:error, :invalid_path}
    end
  end

  def read(_root, _relative_path, _max_bytes), do: {:error, :invalid_path}

  @doc """
  Resolves an absolute path, following only symbolic links that stay within the
  filesystem root, and returns the canonical absolute path.
  """
  @spec resolve_absolute(binary()) :: {:ok, binary()} | {:error, error()}
  def resolve_absolute(path) when is_binary(path) do
    relative = Path.relative_to(path, "/")

    case resolve_segments("/", Path.split(relative), 0) do
      {:ok, resolved} -> {:ok, Path.join("/", resolved)}
      {:error, reason} -> {:error, normalize(reason)}
    end
  end

  def resolve_absolute(_path), do: {:error, :invalid_path}

  # Deliberately private. Resolution alone does not confine: it follows links
  # and reports where they land, and only `read/3`'s surrounding
  # `validate_relative/1` and `within_root?/2` re-check make the result safe.
  # Exposing it would invite a caller to treat a resolved path as a confined
  # one.
  defp resolve_relative(root, relative_path) do
    case resolve_segments(root, Path.split(relative_path), 0) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, normalize(reason)}
    end
  end

  # A `..` segment must fail rather than resolve: the previous implementation
  # relied on a frozen-snapshot lookup missing to contain it, which a direct
  # read does not provide.
  defp validate_relative(path) do
    valid? =
      String.valid?(path) and byte_size(path) in 1..@max_path_bytes and
        not String.contains?(path, <<0>>) and Path.type(path) == :relative and
        Enum.all?(Path.split(path), &(&1 not in ["", ".", ".."]))

    if valid?, do: :ok, else: {:error, :invalid_path}
  end

  defp resolve_segments(_root, _segments, depth) when depth > @max_symlink_depth,
    do: {:error, :symlink_depth_exceeded}

  defp resolve_segments(root, segments, depth) do
    segments
    |> Enum.reduce_while({:ok, {root, []}}, fn segment, {:ok, {parent, consumed}} ->
      candidate = Path.join(parent, segment)

      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} ->
          with {:ok, target} <- File.read_link(candidate),
               target = Path.expand(target, parent),
               true <- within_root?(root, target) do
            remaining = Enum.drop(segments, length(consumed) + 1)
            target_segments = target |> Path.relative_to(root) |> Path.split()
            {:halt, resolve_segments(root, target_segments ++ remaining, depth + 1)}
          else
            _reason -> {:halt, {:error, :symlink_escape}}
          end

        {:ok, _stat} ->
          {:cont, {:ok, {candidate, consumed ++ [segment]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {resolved, _consumed}} -> {:ok, Path.relative_to(resolved, root)}
      {:ok, resolved} when is_binary(resolved) -> {:ok, resolved}
      error -> error
    end
  end

  defp within_root?("/", target), do: Path.type(target) == :absolute

  defp within_root?(root, target) do
    if target == root, do: true, else: String.starts_with?(target, root <> "/")
  end

  # Stat before opening, after opening, and after reading. A file swapped
  # between those points fails rather than yielding bytes from two files.
  defp read_bounded(path, max_bytes) do
    with {:ok, expected} <- lstat(path),
         :ok <- regular?(expected),
         :ok <- within_size?(expected, max_bytes),
         {:ok, content} <- read_verified(path, expected, max_bytes),
         {:ok, current} <- lstat(path),
         :ok <- same_file(expected, current) do
      if String.valid?(content), do: {:ok, content}, else: {:error, :invalid_utf8}
    end
  end

  defp read_verified(path, expected, max_bytes) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          with {:ok, file_info} <- :file.read_file_info(device),
               opened = File.Stat.from_record(file_info),
               :ok <- same_file(expected, opened),
               :ok <- regular?(opened),
               :ok <- within_size?(opened, max_bytes) do
            read_content(device, max_bytes)
          else
            {:error, reason} -> {:error, normalize(reason)}
          end
        after
          :file.close(device)
        end

      {:error, reason} ->
        {:error, normalize(reason)}
    end
  end

  defp read_content(device, max_bytes) do
    case :file.read(device, max_bytes + 1) do
      {:ok, content} when byte_size(content) <= max_bytes -> {:ok, content}
      {:ok, _content} -> {:error, :too_large}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, normalize(reason)}
    end
  end

  defp lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, normalize(reason)}
    end
  end

  defp regular?(%File.Stat{type: :regular}), do: :ok
  defp regular?(%File.Stat{type: :symlink}), do: {:error, :symlink_escape}
  defp regular?(%File.Stat{}), do: {:error, :not_regular}

  defp within_size?(%File.Stat{size: size}, max_bytes) when size <= max_bytes, do: :ok
  defp within_size?(%File.Stat{}, _max_bytes), do: {:error, :too_large}

  defp same_file(
         %File.Stat{major_device: device, minor_device: minor, inode: inode, type: type},
         %File.Stat{major_device: device, minor_device: minor, inode: inode, type: type}
       ),
       do: :ok

  defp same_file(_expected, _current), do: {:error, :changed_during_read}

  defp normalize(:enoent), do: :not_found
  defp normalize(:enotdir), do: :not_found
  defp normalize(:eloop), do: :symlink_depth_exceeded
  defp normalize(:eisdir), do: :not_regular

  defp normalize(reason)
       when reason in [
              :invalid_path,
              :symlink_escape,
              :symlink_depth_exceeded,
              :not_found,
              :not_regular,
              :too_large,
              :invalid_utf8,
              :changed_during_read
            ],
       do: reason

  defp normalize(_reason), do: :not_found
end
