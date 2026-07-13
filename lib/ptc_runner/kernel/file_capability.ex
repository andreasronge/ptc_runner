defmodule PtcRunner.Kernel.FileCapability do
  @moduledoc """
  Constructs the read-only `fs-read` mission capability.

  The callback accepts exactly `%{"path" => relative_path}` and returns one
  bounded UTF-8 regular file beneath the configured root. Absolute paths,
  empty or dot segments, symbolic links, non-regular files, descriptor/path
  identity changes, oversized files, and invalid UTF-8 are rejected.

  The root remains in the host callback closure and is never exposed through
  Lisp discovery metadata.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.ProviderError

  @default_max_bytes 1_000_000
  @max_path_bytes 4_096

  @spec new(keyword()) :: {:ok, Capability.t()} | {:error, :invalid_file_capability}
  @doc """
  Constructs `fs-read` with required directory `:root` and optional positive
  `:max_bytes`, which defaults to 1,000,000.
  """
  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:root, :max_bytes] == [],
         root when is_binary(root) <- Keyword.get(opts, :root),
         true <- String.valid?(root),
         root = Path.expand(root),
         {:ok, %{type: :directory}} <- File.lstat(root),
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Keyword.get(opts, :max_bytes, @default_max_bytes),
         {:ok, capability} <-
           Capability.new(
             name: "fs-read",
             description: "Read one bounded UTF-8 file beneath the configured root",
             validate: &validate_arguments/1,
             callback: fn arguments -> read(root, max_bytes, arguments) end
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

  defp read(root, max_bytes, %{"path" => relative_path}) do
    with :ok <- confined_path(relative_path),
         {:ok, {path, expected_stat}} <- reject_symlinks(root, relative_path),
         :ok <- regular_file(expected_stat),
         :ok <- within_size(expected_stat.size, max_bytes),
         {:ok, content} <- bounded_read(path, expected_stat, max_bytes),
         true <- String.valid?(content) do
      {:ok,
       %{
         "path" => relative_path,
         "content" => content,
         "bytes" => byte_size(content)
       }}
    else
      {:error, %ProviderError{} = error} -> {:error, error}
      {:error, :enoent} -> provider_error(:not_found, "file not found")
      false -> provider_error(:invalid_request, "file is not valid UTF-8")
      {:error, _reason} -> provider_error(:internal, "file read failed")
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

  defp reject_symlinks(root, relative_path) do
    relative_path
    |> Path.split()
    |> Enum.reduce_while({:ok, {root, nil}}, fn segment, {:ok, {parent, _parent_stat}} ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %{type: :symlink}} ->
          {:halt, provider_error(:denied, "symbolic links are outside the file grant")}

        {:ok, stat} ->
          {:cont, {:ok, {path, stat}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp regular_file(%File.Stat{type: :regular}), do: :ok

  defp regular_file(%File.Stat{}),
    do: provider_error(:invalid_request, "path is not a regular file")

  defp within_size(size, max_bytes) when size <= max_bytes, do: :ok
  defp within_size(_size, _max_bytes), do: provider_error(:invalid_request, "file is too large")

  defp bounded_read(path, expected_stat, max_bytes) do
    with {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened_stat = File.Stat.from_record(file_info),
             :ok <- same_file(expected_stat, opened_stat),
             :ok <- regular_file(opened_stat),
             :ok <- within_size(opened_stat.size, max_bytes) do
          case :file.read(device, max_bytes + 1) do
            {:ok, content} when byte_size(content) <= max_bytes -> {:ok, content}
            {:ok, _content} -> provider_error(:invalid_request, "file is too large")
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, reason}
          end
        end
      after
        :file.close(device)
      end
    end
  end

  defp same_file(
         %File.Stat{major_device: device, minor_device: minor, inode: inode},
         %File.Stat{major_device: device, minor_device: minor, inode: inode}
       ),
       do: :ok

  defp same_file(_expected, _opened),
    do: provider_error(:denied, "file changed while the grant was being checked")

  defp provider_error(kind, details), do: {:error, ProviderError.new(kind, details)}
end
