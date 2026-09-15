defmodule PtcGateway.PrivateAudit do
  @moduledoc """
  Opaque owner for a private bounded append-only audit spool.

  Startup rejects links throughout the hierarchy, validates ownership, creates
  missing directories owner-only, and durably opens a new 0600 file before
  pruning oldest closed files. A create/append/sync probe finishes before
  startup returns. The probe is removed; active files contain no invented audit
  record. Files use increasing numeric names and are never truncated.
  The directory is exclusively locked for this owner's lifetime. Per-call
  records, fencing and shutdown policy belong to the execution integration.
  """
  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction
  alias PtcRunner.Kernel.PrivateDirectory
  import Bitwise

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config)
  @doc false
  def child_spec(config),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [config]}, restart: :temporary}

  @impl true
  def init(config) do
    case open(config) do
      {:ok, state} -> {:ok, state}
      _ -> {:stop, :audit_unavailable}
    end
  end

  defp open(config) do
    directory = config["directory"]
    lock = Path.join(directory, ".gateway-lock")

    with :ok <- hierarchy(directory),
         {:ok, uid} <- PrivateDirectory.preflight_owner(Path.join(directory, "probe")),
         {:ok, %{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(directory),
         true <- band(mode, 0o777) == 0o700,
         :ok <- PrivateDirectory.create(lock) do
      case open_locked(config, uid) do
        {:ok, state} ->
          {:ok, Map.put(state, :lock, lock)}

        _ ->
          File.rmdir(lock)
          {:error, :audit_unavailable}
      end
    else
      _ -> {:error, :audit_unavailable}
    end
  end

  defp hierarchy("/"), do: :ok

  defp hierarchy(path) do
    with :ok <- hierarchy(Path.dirname(path)) do
      case File.lstat(path) do
        {:ok, %{type: :directory}} -> :ok
        {:error, :enoent} -> PrivateDirectory.create(path)
        _ -> {:error, :audit_unavailable}
      end
    end
  end

  defp open_locked(config, uid) do
    directory = config["directory"]

    with {:ok, names} <- File.ls(directory),
         {:ok, files} <-
           inventory(names -- [".gateway-lock"], directory, uid, config["max_file_bytes"]),
         sequence = Enum.reduce(files, 0, fn {n, _}, acc -> max(n, acc) end) + 1,
         true <- sequence < 100_000_000_000_000_000_000,
         path =
           Path.join(
             directory,
             String.pad_leading(Integer.to_string(sequence), 20, "0") <> ".jsonl"
           ),
         {:ok, io} <- File.open(path, [:raw, :binary, :append, :exclusive]) do
      case probe(io, path, directory) do
        :ok ->
          case retain(files, config["max_retained_files"] - 1, directory) do
            :ok ->
              {:ok, %{io: io, path: path, directory: directory, config: config}}

            _ ->
              File.close(io)
              {:error, :audit_unavailable}
          end

        _ ->
          File.close(io)
          {:error, :audit_unavailable}
      end
    else
      _ -> {:error, :audit_unavailable}
    end
  end

  defp inventory(names, directory, uid, max_bytes) do
    Enum.reduce_while(Enum.sort(names), {:ok, []}, fn name, {:ok, acc} ->
      path = Path.join(directory, name)

      with true <- Regex.match?(~r/\A[0-9]{20}\.jsonl\z/, name),
           {:ok, %{type: :regular, uid: ^uid, mode: mode, size: size, links: 1}} <-
             File.lstat(path),
           true <- band(mode, 0o777) == 0o600 and size <= max_bytes,
           {sequence, ".jsonl"} <- Integer.parse(name) do
        {:cont, {:ok, [{sequence, path} | acc]}}
      else
        _ -> {:halt, {:error, :audit_unavailable}}
      end
    end)
  end

  defp probe(io, path, directory) do
    with :ok <- File.chmod(path, 0o600),
         :ok <- append_probe(Path.join(directory, ".gateway-lock/probe")),
         :ok <- :file.sync(io) do
      sync_directory(directory)
    end
  end

  defp sync_directory(directory) do
    with {:ok, dir} <- :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      result = :file.sync(dir)
      closed = :file.close(dir)
      if result == :ok and closed == :ok, do: :ok, else: {:error, :audit_unavailable}
    end
  end

  defp retain(files, count, directory) do
    with :ok <- prune(files, count), do: sync_directory(directory)
  end

  defp append_probe(path) do
    case File.open(path, [:raw, :binary, :append, :exclusive]) do
      {:ok, probe} ->
        result =
          with :ok <- File.chmod(path, 0o600),
               :ok <- :file.write(probe, "probe\n"),
               do: :file.sync(probe)

        closed = File.close(probe)
        removed = File.rm(path)

        if result == :ok and closed == :ok and removed == :ok,
          do: :ok,
          else: {:error, :audit_unavailable}

      _ ->
        {:error, :audit_unavailable}
    end
  end

  defp prune(files, retain) do
    files
    |> Enum.sort()
    |> Enum.take(max(length(files) - retain, 0))
    |> Enum.reduce_while(:ok, fn {_, path}, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :audit_unavailable}}
      end
    end)
  end

  @impl true
  def terminate(_, state) do
    File.close(state.io)
    File.rmdir(state.lock)
    :ok
  end
end
