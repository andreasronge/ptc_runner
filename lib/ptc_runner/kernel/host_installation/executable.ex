defmodule PtcRunner.Kernel.HostInstallation.Executable do
  @moduledoc false

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.MCPLauncher

  @max_executable_bytes 268_435_456
  @max_launcher_bytes 16_777_216

  def resolve_command(host_directory, command, environment) do
    case Path.type(command) do
      :absolute ->
        canonical_mcp_executable(command)

      :relative ->
        if Path.basename(command) == command do
          resolve_bare_command(command, Map.get(environment, "PATH"))
        else
          command
          |> Path.expand(host_directory)
          |> canonical_mcp_executable()
        end
    end
  end

  defp resolve_bare_command(_command, nil), do: {:error, :mcp_command_not_found}

  defp resolve_bare_command(command, path) do
    path
    |> String.split(":", trim: true)
    |> Enum.reduce_while({:error, :mcp_command_not_found}, fn directory, previous_error ->
      if Path.type(directory) == :absolute do
        case canonical_mcp_executable(Path.join(directory, command)) do
          {:ok, _path, _digest} = success -> {:halt, success}
          {:error, :mcp_command_not_found} -> {:cont, previous_error}
          {:error, :invalid_mcp_executable} = error -> {:cont, error}
        end
      else
        {:cont, previous_error}
      end
    end)
  end

  defp canonical_mcp_executable(path) do
    case ConfinedFile.resolve_absolute(path) do
      {:ok, canonical} ->
        case validate_executable(canonical, @max_executable_bytes) do
          {:ok, digest} -> {:ok, canonical, digest}
          {:error, _reason} -> {:error, :invalid_mcp_executable}
        end

      {:error, :not_found} ->
        {:error, :mcp_command_not_found}

      {:error, _reason} ->
        {:error, :invalid_mcp_executable}
    end
  end

  def resolve_launcher(nil) do
    with {:ok, path} <- MCPLauncher.companion(), do: resolve_launcher(path)
  end

  def resolve_launcher(path) do
    case canonical_executable(path, @max_launcher_bytes, :mcp_stdio_launcher_unavailable) do
      {:ok, canonical, digest} -> {:ok, canonical, digest}
      {:error, _reason} = error -> error
    end
  end

  defp canonical_executable(path, max_bytes, error) do
    with {:ok, canonical} <- ConfinedFile.resolve_absolute(path),
         {:ok, digest} <- validate_executable(canonical, max_bytes) do
      {:ok, canonical, digest}
    else
      _reason -> {:error, error}
    end
  end

  defp validate_executable(canonical, max_bytes) do
    with {:ok, stat} <- File.stat(canonical),
         true <- stat.type == :regular and stat.size in 1..max_bytes,
         true <- Bitwise.band(stat.mode, 0o111) != 0,
         {:ok, digest} <- hash_file(canonical, max_bytes) do
      {:ok, digest}
    else
      _invalid -> {:error, :invalid_executable}
    end
  end

  defp hash_file(path, max_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          hash_chunks(device, :crypto.hash_init(:sha256), 0, max_bytes)
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp hash_chunks(device, hash, bytes, max_bytes) do
    case IO.binread(device, 65_536) do
      :eof ->
        {:ok, :crypto.hash_final(hash)}

      chunk when is_binary(chunk) and bytes + byte_size(chunk) <= max_bytes ->
        hash_chunks(
          device,
          :crypto.hash_update(hash, chunk),
          bytes + byte_size(chunk),
          max_bytes
        )

      _error_or_exceeded ->
        {:error, :unreadable}
    end
  end
end
