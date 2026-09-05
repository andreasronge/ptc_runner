defmodule PtcRunner.Kernel.ProjectArtifactRoot do
  @moduledoc false

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProjectContext

  @children ~w(envelopes inspection results traces)
  @attempts 16

  @type ensure_error ::
          :project_artifact_root_invalid
          | {:project_artifact_root_not_owner_only, binary()}
          | {:project_artifact_root_incomplete, binary()}
          | {:project_artifact_root_parent_missing, binary(), binary()}
          | {:project_artifact_root_parent_unsafe_mode, binary()}
          | {:project_artifact_root_parent_foreign_owner, binary()}

  @spec ensure_for(CommandArguments.t()) :: :ok | {:error, ensure_error()}
  def ensure_for(%CommandArguments{
        command: :run,
        project: %ProjectContext{config: %{artifact_root: root}, derived_options: derived}
      })
      when is_binary(root) do
    if MapSet.disjoint?(
         derived,
         MapSet.new([:trace_dir, :inspect, :result, :envelope_ledger])
       ),
       do: :ok,
       else: ensure(root)
  end

  def ensure_for(%CommandArguments{}), do: :ok

  @spec ensure(binary()) :: :ok | {:error, ensure_error()}
  def ensure(root) when is_binary(root) do
    case File.lstat(root) do
      {:ok, _stat} -> validate(root)
      {:error, :enoent} -> create(root)
      {:error, _reason} -> {:error, :project_artifact_root_invalid}
    end
  rescue
    _exception -> {:error, :project_artifact_root_invalid}
  catch
    _kind, _reason -> {:error, :project_artifact_root_invalid}
  end

  def ensure(_root), do: {:error, :project_artifact_root_invalid}

  defp create(root), do: create(root, @attempts)
  defp create(_root, 0), do: {:error, :project_artifact_root_invalid}

  defp create(root, attempts) do
    with :ok <- PrivateDirectory.preflight(root),
         {staging, _child} = PrivateDirectory.temporary_sibling(root, "unused"),
         :ok <- PrivateDirectory.create(staging) do
      case assemble(staging) do
        :ok -> publish(staging, root)
        {:error, _reason} -> cleanup(staging)
      end
    else
      {:error, :private_directory_creation_failed} -> create(root, attempts - 1)
      {:error, _reason} -> parent_failure(root)
    end
  end

  # `ptc` creates the artifact root and its fixed children, never their
  # ancestors: a directory above the root is the caller's, and its mode and
  # ownership are not this command's to choose. Naming the ancestor that
  # stopped the creation is therefore the whole remedy. A missing ancestor
  # carries the requested parent too, because `mkdir -p` on the parent creates
  # every level, while creating only the shallowest one fails again on the next.
  defp parent_failure(root) do
    anchored = anchored(root)

    case PrivateDirectory.parent_fault(anchored) do
      {:missing, path} ->
        {:error, {:project_artifact_root_parent_missing, path, Path.dirname(anchored)}}

      {:unsafe_mode, path} ->
        {:error, {:project_artifact_root_parent_unsafe_mode, path}}

      {:foreign_owner, path} ->
        {:error, {:project_artifact_root_parent_foreign_owner, path}}

      :none ->
        {:error, :project_artifact_root_invalid}
    end
  end

  defp anchored(root) do
    case PrivateDirectory.anchor(root) do
      {:ok, anchored} -> anchored
      {:error, _reason} -> root
    end
  end

  defp assemble(staging) do
    Enum.reduce_while(@children, :ok, fn child, :ok ->
      case PrivateDirectory.create(Path.join(staging, child)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp publish(staging, root) do
    case publish_directory(staging, root) do
      :ok ->
        validate(root)

      {:error, :collision} ->
        cleanup(staging)
        validate(root)

      {:error, :publication_status_unknown} ->
        case validate(root) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            _ = cleanup(staging)
            error
        end

      {:error, _reason} ->
        cleanup(staging)
    end
  end

  defp validate(root) do
    with :ok <- require_owner_directory(root),
         {:ok, names} <- File.ls(root),
         :ok <- complete_children(root, names),
         :ok <- require_owner_children(root) do
      :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :project_artifact_root_invalid}
    end
  end

  defp complete_children(root, names) do
    if Enum.sort(names) == @children,
      do: :ok,
      else: {:error, {:project_artifact_root_incomplete, root}}
  end

  defp require_owner_children(root) do
    Enum.reduce_while(@children, :ok, fn child, :ok ->
      case require_owner_directory(Path.join(root, child)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp require_owner_directory(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mode: mode}}
      when Bitwise.band(mode, 0o077) == 0 ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        {:error, {:project_artifact_root_not_owner_only, path}}

      _invalid ->
        {:error, :project_artifact_root_invalid}
    end
  end

  defp cleanup(staging) do
    case require_owner_directory(staging) do
      :ok ->
        Enum.each(@children, fn child ->
          path = Path.join(staging, child)
          if require_owner_directory(path) == :ok, do: File.rmdir(path)
        end)

        File.rmdir(staging)
        {:error, :project_artifact_root_invalid}

      {:error, _reason} ->
        {:error, :project_artifact_root_invalid}
    end
  end

  defp publish_directory(staging, root) do
    launcher = Module.concat(["PtcRunnerLauncher"])

    if Code.ensure_loaded?(launcher) and
         function_exported?(launcher, :publish_directory_noreplace, 2),
       do: launcher.publish_directory_noreplace(staging, root),
       else: {:error, :unsupported_platform}
  end
end
