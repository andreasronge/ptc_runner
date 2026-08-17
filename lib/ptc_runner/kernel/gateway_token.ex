defmodule PtcRunner.Kernel.GatewayToken do
  @moduledoc """
  Loads the HTTP gateway bearer token from a private file.

  Environment variables are not a token source: they are VM-global. The file
  must be a regular file owned by the serving user, owner-readable, with no
  group or other permissions, reached through ancestors that pass
  `PrivateDirectory` preflight. Symlinks are resolved hop by hop and
  re-validated. The file is opened once: `fstat`, a bounded read of at most
  1025 bytes, then `fstat` again, so a replacement during the read is
  refused. Empty files refuse startup. A single trailing newline is stripped;
  remaining CR, LF, or NUL bytes refuse the file. Rotation is restart, not
  reload. The token is never logged.
  """

  alias PtcRunner.Kernel.PrivateDirectory

  @max_bytes 1_024
  @max_symlink_hops 40

  @spec load(binary()) :: {:ok, binary()} | {:error, :invalid_gateway_token}
  def load(path) when is_binary(path) and path != "", do: load(path, [])

  def load(_path), do: {:error, :invalid_gateway_token}

  @doc false
  @spec load(binary(), keyword()) :: {:ok, binary()} | {:error, :invalid_gateway_token}
  def load(path, opts) when is_binary(path) and path != "" and is_list(opts) do
    with true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- [:after_open] == [],
         {:ok, anchored} <- PrivateDirectory.anchor(path),
         {:ok, uid} <- PrivateDirectory.preflight_owner(anchored),
         {:ok, resolved} <- resolve(anchored, uid, 0),
         {:ok, ^uid} <- PrivateDirectory.preflight_owner(resolved),
         {:ok, expected} <- lstat(resolved),
         :ok <- secret_file(expected, uid),
         {:ok, bytes} <- read_verified(resolved, expected, uid, Keyword.get(opts, :after_open)),
         {:ok, ^uid} <- PrivateDirectory.preflight_owner(resolved),
         {:ok, after_stat} <- lstat(resolved),
         :ok <- same_file(expected, after_stat),
         :ok <- secret_file(after_stat, uid),
         {:ok, token} <- unwrap(bytes) do
      {:ok, token}
    else
      _reason -> {:error, :invalid_gateway_token}
    end
  end

  def load(_path, _opts), do: {:error, :invalid_gateway_token}

  defp resolve(_path, _uid, hops) when hops > @max_symlink_hops,
    do: {:error, :invalid_gateway_token}

  defp resolve(path, uid, hops) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, path}

      {:ok, %File.Stat{type: :symlink, uid: owner}} when owner in [0, uid] ->
        case File.read_link(path) do
          {:ok, target} -> resolve(expand_link(path, target), uid, hops + 1)
          _error -> {:error, :invalid_gateway_token}
        end

      _invalid ->
        {:error, :invalid_gateway_token}
    end
  end

  defp expand_link(path, target) do
    case Path.type(target) do
      :absolute -> target
      :relative -> Path.expand(target, Path.dirname(path))
      _other -> path
    end
  end

  defp read_verified(path, expected, uid, after_open) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          with {:ok, before} <- descriptor_stat(device),
               :ok <- same_file(expected, before),
               :ok <- secret_file(before, uid),
               :ok <- after_open(after_open),
               {:ok, content} <- read_content(device),
               {:ok, after_stat} <- descriptor_stat(device),
               :ok <- same_file(expected, after_stat),
               :ok <- secret_file(after_stat, uid),
               :ok <- same_secret_stat(before, after_stat) do
            {:ok, content}
          else
            _reason -> {:error, :invalid_gateway_token}
          end
        after
          :file.close(device)
        end

      {:error, _reason} ->
        {:error, :invalid_gateway_token}
    end
  end

  defp descriptor_stat(device) do
    case :file.read_file_info(device) do
      {:ok, file_info} -> {:ok, File.Stat.from_record(file_info)}
      {:error, _reason} -> {:error, :invalid_gateway_token}
    end
  end

  defp after_open(nil), do: :ok
  defp after_open(fun) when is_function(fun, 0), do: fun.()
  defp after_open(_other), do: {:error, :invalid_gateway_token}

  defp read_content(device) do
    case :file.read(device, @max_bytes + 1) do
      {:ok, content} when byte_size(content) <= @max_bytes -> {:ok, content}
      {:ok, _content} -> {:error, :invalid_gateway_token}
      :eof -> {:ok, ""}
      {:error, _reason} -> {:error, :invalid_gateway_token}
    end
  end

  defp lstat(path) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat}
      {:error, _reason} -> {:error, :invalid_gateway_token}
    end
  end

  defp secret_file(%File.Stat{type: :regular, uid: owner, mode: mode}, uid)
       when owner in [0, uid] do
    readable? = Bitwise.band(mode, 0o400) == 0o400
    private? = Bitwise.band(mode, 0o077) == 0

    if readable? and private?, do: :ok, else: {:error, :invalid_gateway_token}
  end

  defp secret_file(_stat, _uid), do: {:error, :invalid_gateway_token}

  # ex_dna:disable-for-next-line — inode identity check, independently owned from ConfinedFile
  defp same_file(
         %File.Stat{major_device: device, minor_device: minor, inode: inode, type: type},
         %File.Stat{major_device: device, minor_device: minor, inode: inode, type: type}
       ),
       do: :ok

  defp same_file(_expected, _current), do: {:error, :invalid_gateway_token}

  defp same_secret_stat(
         %File.Stat{mode: mode, uid: uid, size: size},
         %File.Stat{mode: mode, uid: uid, size: size}
       ),
       do: :ok

  defp same_secret_stat(_before, _after), do: {:error, :invalid_gateway_token}

  defp unwrap(bytes) when is_binary(bytes) do
    token = strip_trailing_newline(bytes)

    if token != "" and String.valid?(token) and :binary.match(token, <<0>>) == :nomatch and
         not String.contains?(token, "\n") and not String.contains?(token, "\r") do
      {:ok, token}
    else
      {:error, :invalid_gateway_token}
    end
  end

  defp strip_trailing_newline(bytes) do
    cond do
      String.ends_with?(bytes, "\r\n") -> binary_part(bytes, 0, byte_size(bytes) - 2)
      String.ends_with?(bytes, "\n") -> binary_part(bytes, 0, byte_size(bytes) - 1)
      true -> bytes
    end
  end
end
