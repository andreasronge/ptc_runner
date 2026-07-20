defmodule PtcRunner.Kernel.FileCapability do
  @moduledoc """
  Constructs the read-only `fs-read` mission capability.

  Construction freezes a bounded snapshot of the configured root. The
  callback accepts exactly `%{"path" => relative_path}` and reads only that
  immutable snapshot; it performs no runtime filesystem access. Absolute
  paths, empty or dot segments, symbolic links, non-regular files, oversized
  files, and invalid UTF-8 are rejected.

  The root and frozen contents remain in the host callback closure and are
  never exposed through Lisp discovery metadata.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.ProviderError

  @default_max_bytes 1_000_000
  @max_path_bytes 4_096
  @max_snapshot_entries 4_096
  @max_snapshot_bytes 32_000_000

  @spec new(keyword()) :: {:ok, Capability.t()} | {:error, :invalid_file_capability}
  @doc """
  Constructs `fs-read` with required directory `:root`, optional positive
  per-file `:max_bytes` (default 1,000,000), and optional boolean
  `:model_visible` (default `true`). Visibility controls discovery metadata,
  not authority. Construction fails when the root cannot be frozen within the
  fixed snapshot entry and aggregate-byte ceilings.
  """
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:root, :max_bytes, :model_visible] == [],
         root when is_binary(root) <- Keyword.get(opts, :root),
         true <- String.valid?(root),
         root = Path.expand(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Keyword.get(opts, :max_bytes, @default_max_bytes),
         model_visible when is_boolean(model_visible) <-
           Keyword.get(opts, :model_visible, true),
         {:ok, snapshot} <- freeze_root(root, max_bytes),
         {:ok, capability} <-
           Capability.new(
             name: "fs-read",
             description: "Read one bounded UTF-8 file from the frozen granted root",
             model_visible: model_visible,
             input_schema: %{
               "type" => "object",
               "properties" => %{"path" => %{"type" => "string", "minLength" => 1}},
               "required" => ["path"]
             },
             output_schema: %{
               "type" => "object",
               "properties" => %{
                 "path" => %{"type" => "string"},
                 "content" => %{"type" => "string"},
                 "bytes" => %{"type" => "integer", "minimum" => 0}
               },
               "required" => ["path", "content", "bytes"]
             },
             effect: :read,
             validate: &validate_arguments/1,
             callback: fn arguments -> read_snapshot(snapshot, arguments) end
           ) do
      {:ok, capability}
    else
      _ -> {:error, :invalid_file_capability}
    end
  end

  def new(_opts), do: {:error, :invalid_file_capability}

  defp validate_arguments(%{"path" => path} = arguments)
       when map_size(arguments) == 1 and is_binary(path) do
    if valid_relative_path?(path), do: :ok, else: {:error, "invalid path"}
  end

  defp validate_arguments(_arguments), do: {:error, "expected one path string"}

  defp read_snapshot(snapshot, %{"path" => relative_path}) do
    with :ok <- confined_path(relative_path),
         {:ok, content} <- snapshot_entry(snapshot, relative_path) do
      {:ok,
       %{
         "path" => relative_path,
         "content" => content,
         "bytes" => byte_size(content)
       }}
    end
  end

  defp confined_path(path) do
    if valid_relative_path?(path),
      do: :ok,
      else: provider_error(:denied, "path is outside the granted root")
  end

  defp valid_relative_path?(path) do
    String.valid?(path) and byte_size(path) in 1..@max_path_bytes and
      not String.contains?(path, <<0>>) and Path.type(path) == :relative and
      Enum.all?(Path.split(path), &(&1 not in ["", ".", ".."]))
  end

  defp snapshot_entry(snapshot, relative_path) do
    case Map.fetch(snapshot, relative_path) do
      {:ok, {:file, content}} -> {:ok, content}
      {:ok, :symlink} -> provider_error(:denied, "symbolic links are outside the file grant")
      {:ok, :too_large} -> provider_error(:invalid_request, "file is too large")
      {:ok, :invalid_utf8} -> provider_error(:invalid_request, "file is not valid UTF-8")
      {:ok, :not_regular} -> provider_error(:invalid_request, "path is not a regular file")
      :error -> provider_error(:not_found, "file not found")
    end
  end

  defp freeze_root(root, max_bytes) do
    initial = %{entries: 0, bytes: 0, files: %{}}

    with {:ok, root_stat} <- File.lstat(root),
         {:ok, snapshot} <- freeze_directory(root, "", max_bytes, initial),
         {:ok, current_root} <- File.lstat(root),
         :ok <- same_file(root_stat, current_root) do
      {:ok, snapshot.files}
    end
  end

  defp freeze_directory(directory, relative_directory, max_bytes, snapshot) do
    with {:ok, expected} <- File.lstat(directory),
         true <- expected.type == :directory,
         {:ok, names} <- File.ls(directory),
         {:ok, next} <-
           Enum.reduce_while(Enum.sort(names), {:ok, snapshot}, fn name, {:ok, acc} ->
             relative = relative_path(relative_directory, name)
             path = Path.join(directory, name)

             case freeze_entry(path, relative, max_bytes, acc) do
               {:ok, frozen} -> {:cont, {:ok, frozen}}
               {:error, _reason} = error -> {:halt, error}
             end
           end),
         {:ok, current} <- File.lstat(directory),
         :ok <- same_file(expected, current) do
      {:ok, next}
    else
      _ -> {:error, :snapshot_changed}
    end
  end

  defp freeze_entry(path, relative, max_bytes, snapshot) do
    with true <- snapshot.entries < @max_snapshot_entries,
         {:ok, stat} <- File.lstat(path) do
      next = %{snapshot | entries: snapshot.entries + 1}

      case stat.type do
        :directory ->
          with {:ok, nested} <- freeze_directory(path, relative, max_bytes, next),
               do: put_snapshot_entry(nested, relative, :not_regular)

        :regular ->
          freeze_regular(path, relative, stat, max_bytes, next)

        :symlink ->
          put_snapshot_entry(next, relative, :symlink)

        _other ->
          put_snapshot_entry(next, relative, :not_regular)
      end
    else
      _ -> {:error, :snapshot_limit}
    end
  end

  defp freeze_regular(_path, relative, %File.Stat{size: size}, max_bytes, snapshot)
       when size > max_bytes,
       do: put_snapshot_entry(snapshot, relative, :too_large)

  defp freeze_regular(path, relative, expected, max_bytes, snapshot) do
    with {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular and opened.size <= max_bytes,
             {:ok, content} <- read_content(device, max_bytes),
             {:ok, current} <- File.lstat(path),
             :ok <- same_file(expected, current) do
          if String.valid?(content) do
            put_snapshot_content(snapshot, relative, content)
          else
            put_snapshot_entry(snapshot, relative, :invalid_utf8)
          end
        else
          _ -> {:error, :snapshot_changed}
        end
      after
        :file.close(device)
      end
    end
  end

  defp read_content(device, max_bytes) do
    case :file.read(device, max_bytes + 1) do
      {:ok, content} when byte_size(content) <= max_bytes -> {:ok, content}
      :eof -> {:ok, ""}
      _ -> {:error, :snapshot_changed}
    end
  end

  defp put_snapshot_content(snapshot, relative, content) do
    bytes = snapshot.bytes + byte_size(content)

    if bytes <= @max_snapshot_bytes do
      {:ok,
       %{snapshot | bytes: bytes, files: Map.put(snapshot.files, relative, {:file, content})}}
    else
      {:error, :snapshot_limit}
    end
  end

  defp put_snapshot_entry(snapshot, relative, entry),
    do: {:ok, %{snapshot | files: Map.put(snapshot.files, relative, entry)}}

  defp relative_path("", name), do: name
  defp relative_path(directory, name), do: Path.join(directory, name)

  defp same_file(
         %File.Stat{major_device: device, minor_device: minor, inode: inode, type: type},
         %File.Stat{major_device: device, minor_device: minor, inode: inode, type: type}
       ),
       do: :ok

  defp same_file(_expected, _current), do: {:error, :snapshot_changed}

  defp provider_error(kind, details), do: {:error, ProviderError.new(kind, details)}
end
