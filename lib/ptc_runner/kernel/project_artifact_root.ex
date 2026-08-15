defmodule PtcRunner.Kernel.ProjectArtifactRoot do
  @moduledoc false

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ProjectContext

  @children ~w(envelopes inspection results traces)
  @attempts 16

  @spec ensure_for(CommandArguments.t()) :: :ok | {:error, :project_artifact_root_invalid}
  def ensure_for(%CommandArguments{
        command: :run,
        project: %ProjectContext{config: %{artifact_root: root}, derived_options: derived}
      })
      when is_binary(root) do
    if MapSet.disjoint?(derived, MapSet.new([:trace_dir, :inspect, :result, :envelope])),
      do: :ok,
      else: ensure(root)
  end

  def ensure_for(%CommandArguments{}), do: :ok

  @spec ensure(binary()) :: :ok | {:error, :project_artifact_root_invalid}
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
      _failure -> {:error, :project_artifact_root_invalid}
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
          :ok -> :ok
          {:error, _reason} -> cleanup(staging)
        end

      {:error, _reason} ->
        cleanup(staging)
    end
  end

  defp validate(root) do
    with :ok <- owner_directory(root),
         {:ok, names} <- File.ls(root),
         true <- Enum.sort(names) == @children,
         true <- Enum.all?(@children, &(owner_directory(Path.join(root, &1)) == :ok)) do
      :ok
    else
      _invalid -> {:error, :project_artifact_root_invalid}
    end
  end

  defp owner_directory(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mode: mode}}
      when Bitwise.band(mode, 0o077) == 0 ->
        :ok

      _invalid ->
        {:error, :project_artifact_root_invalid}
    end
  end

  defp cleanup(staging) do
    case owner_directory(staging) do
      :ok ->
        Enum.each(@children, fn child ->
          path = Path.join(staging, child)
          if owner_directory(path) == :ok, do: File.rmdir(path)
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
