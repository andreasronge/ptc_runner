defmodule PtcRunner.Kernel.ArtifactPruneTransaction do
  @moduledoc false

  alias PtcRunner.Kernel.ArtifactIdentity
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.RunArtifactName
  alias PtcRunner.Kernel.TraceLog

  @attempts 4
  @stage_pattern ~r/\A\.ptc-prune-[0-9a-f]{16}\z/

  @spec ensure_no_pending(binary()) :: :ok | {:error, :delete_failed}
  def ensure_no_pending(root) do
    case stages(root) do
      {:ok, []} -> :ok
      _ -> {:error, :delete_failed}
    end
  end

  @spec recover(binary(), non_neg_integer()) :: :ok | {:error, :delete_failed}
  def recover(root, uid) do
    case stages(root) do
      {:ok, names} ->
        names
        |> Enum.reduce_while(:ok, fn name, :ok ->
          case recover_stage(root, Path.join(root, name), uid) do
            :ok -> {:cont, :ok}
            _ -> {:halt, {:error, :delete_failed}}
          end
        end)

      _ ->
        {:error, :delete_failed}
    end
  end

  defp stages(root) do
    case File.ls(root) do
      {:ok, names} ->
        {:ok, names |> Enum.filter(&Regex.match?(@stage_pattern, &1)) |> Enum.sort()}

      _ ->
        {:error, :delete_failed}
    end
  end

  @spec delete([{binary(), File.Stat.t()}], binary()) :: :ok | {:error, :delete_failed}
  def delete(artifacts, root), do: delete(artifacts, root, &unlink_one/2)

  @doc false
  @spec delete([{binary(), File.Stat.t()}], binary(), (binary(), File.Stat.t() -> term())) ::
          :ok | {:error, :delete_failed}
  def delete(artifacts, root, unlink) when is_function(unlink, 2) do
    with {:ok, stage} <- create_stage(root),
         {:ok, backups} <- backup_all(artifacts, stage) do
      case unlink_all(backups, unlink) do
        :ok -> commit_or_restore(stage, backups)
        _ -> rollback(stage, backups)
      end
    else
      _ -> {:error, :delete_failed}
    end
  end

  defp commit_or_restore(stage, backups) do
    case mark_commit(stage) do
      :ok -> cleanup(stage, backups)
      _ -> rollback(stage, backups)
    end
  end

  defp rollback(stage, backups) do
    if restore_all(backups) == :ok, do: cleanup(stage, backups)
    {:error, :delete_failed}
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
        copy = Path.join(stage, RunArtifactName.staged_name(path))

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
    if Path.basename(Path.dirname(path)) == "traces" do
      TraceLog.with_append_authority_lock(path, fn -> restore_unlocked(path, copy, stat) end)
    else
      restore_unlocked(path, copy, stat)
    end
  end

  defp restore_unlocked(path, copy, stat) do
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

  defp mark_commit(stage), do: File.write(Path.join(stage, "committed"), "", [:exclusive])

  defp recover_stage(root, stage, uid) do
    with {:ok, _} <- ArtifactIdentity.owner_directory(stage, uid),
         {:ok, names} <- File.ls(stage),
         {:ok, committed?} <- committed?(stage, uid),
         {:ok, backups} <- recovered_backups(root, stage, names) do
      if committed? or restore_all(backups) == :ok,
        do: cleanup(stage, backups),
        else: {:error, :delete_failed}
    else
      _ -> {:error, :delete_failed}
    end
  end

  defp committed?(stage, uid) do
    case File.lstat(Path.join(stage, "committed")) do
      {:ok, %File.Stat{type: :regular, size: 0, uid: ^uid}} -> {:ok, true}
      {:error, :enoent} -> {:ok, false}
      _ -> {:error, :delete_failed}
    end
  end

  defp recovered_backups(root, stage, names) do
    names
    |> Enum.reject(&(&1 == "committed"))
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, backups} ->
      path = RunArtifactName.staged_target(root, name)
      copy = Path.join(stage, name)

      case {path, File.lstat(copy, time: :posix)} do
        {path, {:ok, %File.Stat{type: :regular} = stat}} when is_binary(path) ->
          {:cont, {:ok, [{path, copy, stat} | backups]}}

        _ ->
          {:halt, {:error, :delete_failed}}
      end
    end)
  end

  defp cleanup(stage, backups) do
    results = Enum.map(backups, fn {_path, copy, _stat} -> File.rm(copy) end)

    if Enum.all?(results, &(&1 == :ok)) do
      marker = Path.join(stage, "committed")

      case File.rm(marker) do
        :ok -> File.rmdir(stage)
        {:error, :enoent} -> File.rmdir(stage)
        _ -> {:error, :delete_failed}
      end
    else
      {:error, :delete_failed}
    end
  end
end
