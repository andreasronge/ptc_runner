defmodule PtcRunner.Kernel.ArtifactPruneTransaction do
  @moduledoc false

  alias PtcRunner.Kernel.ArtifactIdentity
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.TraceLog

  @attempts 4

  @spec delete([{binary(), File.Stat.t()}], binary()) :: :ok | {:error, :delete_failed}
  def delete(artifacts, root), do: delete(artifacts, root, &unlink_one/2)

  @doc false
  @spec delete([{binary(), File.Stat.t()}], binary(), (binary(), File.Stat.t() -> term())) ::
          :ok | {:error, :delete_failed}
  def delete(artifacts, root, unlink) when is_function(unlink, 2) do
    with {:ok, stage} <- create_stage(root),
         {:ok, backups} <- backup_all(artifacts, stage) do
      case unlink_all(backups, unlink) do
        :ok ->
          cleanup(stage, backups)

        {:error, :delete_failed} = error ->
          if restore_all(backups) == :ok, do: cleanup(stage, backups)
          error
      end
    else
      _ -> {:error, :delete_failed}
    end
  end

  defp create_stage(root, attempts \\ @attempts)
  defp create_stage(_root, 0), do: {:error, :delete_failed}

  defp create_stage(root, attempts) do
    name = ".ptc-prune-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    stage = Path.join(root, name)

    case PrivateDirectory.create(stage) do
      :ok -> {:ok, stage}
      {:error, :private_directory_creation_failed} -> create_stage(root, attempts - 1)
      _ -> {:error, :delete_failed}
    end
  end

  defp backup_all(artifacts, stage) do
    result =
      Enum.reduce_while(artifacts, {:ok, []}, fn {path, stat}, {:ok, backups} ->
        copy = Path.join(stage, Path.basename(Path.dirname(path)) <> "-" <> Path.basename(path))

        case File.ln(path, copy) do
          :ok ->
            backup = {path, copy, stat}

            if ArtifactIdentity.stable_file?(copy, stat) and
                 ArtifactIdentity.stable_file?(path, stat) do
              {:cont, {:ok, [backup | backups]}}
            else
              {:halt, {:error, [backup | backups]}}
            end

          _ ->
            {:halt, {:error, backups}}
        end
      end)

    case result do
      {:ok, backups} ->
        {:ok, Enum.reverse(backups)}

      {:error, backups} ->
        _ = cleanup(stage, backups)
        {:error, :delete_failed}
    end
  end

  defp unlink_all(backups, unlink) do
    backups
    |> Enum.sort_by(fn {path, _, _} -> Path.basename(Path.dirname(path)) != "traces" end)
    |> Enum.reduce_while(:ok, fn {path, _copy, stat}, :ok ->
      case unlink.(path, stat) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :delete_failed}}
      end
    end)
  end

  defp unlink_one(path, stat) do
    if Path.basename(Path.dirname(path)) == "traces" do
      TraceLog.with_append_authority_lock(path, fn -> unlink_if_stable(path, stat) end)
    else
      unlink_if_stable(path, stat)
    end
  end

  defp unlink_if_stable(path, stat) do
    if ArtifactIdentity.stable_file?(path, stat),
      do: File.rm(path),
      else: {:error, :delete_failed}
  end

  defp restore_all(backups) do
    results = Enum.map(backups, &restore_one/1)
    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :delete_failed}
  end

  defp restore_one({path, copy, stat}) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with true <- ArtifactIdentity.stable_file?(copy, stat),
             :ok <- File.ln(copy, path),
             true <- ArtifactIdentity.stable_file?(path, stat) do
          :ok
        else
          _ -> {:error, :delete_failed}
        end

      {:ok, _} ->
        if ArtifactIdentity.stable_file?(path, stat),
          do: :ok,
          else: {:error, :delete_failed}

      _ ->
        {:error, :delete_failed}
    end
  end

  defp cleanup(stage, backups) do
    results = Enum.map(backups, fn {_path, copy, _stat} -> File.rm(copy) end)
    removed = File.rmdir(stage)

    if Enum.all?(results, &(&1 == :ok)) and removed == :ok,
      do: :ok,
      else: {:error, :delete_failed}
  end
end
