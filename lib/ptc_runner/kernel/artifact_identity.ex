defmodule PtcRunner.Kernel.ArtifactIdentity do
  @moduledoc false

  alias PtcRunner.Kernel.PrivateDirectory

  @spec owner_directory(binary(), non_neg_integer()) :: {:ok, File.Stat.t()} | {:error, atom()}
  def owner_directory(path, uid) do
    with :ok <- PrivateDirectory.preflight_owner(path) |> owner_matches(uid),
         {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode} = stat} <-
           File.lstat(path, time: :posix),
         true <- Bitwise.band(mode, 0o777) == 0o700 do
      {:ok, stat}
    else
      _ -> {:error, :unsafe_directory}
    end
  end

  defp owner_matches({:ok, uid}, uid), do: :ok
  defp owner_matches(_result, _uid), do: {:error, :unsafe_directory}

  @spec unchanged?(binary(), File.Stat.t()) :: boolean()
  def unchanged?(path, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, current} -> identity(current) == identity(expected)
      _ -> false
    end
  end

  @spec stable_file?(binary(), File.Stat.t()) :: boolean()
  def stable_file?(path, expected) do
    with true <- unchanged_file?(path, expected),
         {:ok, io} <- File.open(path, [:read, :raw]) do
      try do
        case :file.read_file_info(io, time: :posix) do
          {:ok, record} ->
            file_identity(File.Stat.from_record(record)) == file_identity(expected) and
              unchanged_file?(path, expected)

          _ ->
            false
        end
      after
        File.close(io)
      end
    else
      _ -> false
    end
  end

  defp identity(stat) do
    {stat.type, stat.uid, Bitwise.band(stat.mode, 0o777), stat.major_device, stat.minor_device,
     stat.inode}
  end

  defp file_identity(stat), do: {identity(stat), stat.size, stat.mtime}

  defp unchanged_file?(path, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, current} -> file_identity(current) == file_identity(expected)
      _ -> false
    end
  end
end
