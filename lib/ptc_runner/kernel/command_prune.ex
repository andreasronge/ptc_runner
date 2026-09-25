defmodule PtcRunner.Kernel.CommandPrune do
  @moduledoc false

  alias PtcRunner.Kernel.ArtifactIdentity
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.TraceDirectoryAdmission
  alias PtcRunner.Kernel.TraceLog

  @artifact_dirs ~w(traces inspection results envelopes)
  @grace_seconds 600
  @seconds_per_day 86_400

  @spec run(map()) :: {:ok, map()} | {:error, atom()}
  def run(%{project: %{config: %{artifact_root: root}}, options: options}) when is_binary(root) do
    with {:ok, uid} <- PrivateDirectory.preflight_owner(Path.join(root, "unused")),
         {:ok, directories} <- directories(root, uid),
         {:ok, files, staging} <- artifacts(directories),
         {:ok, markers} <- markers(root, uid),
         {:ok, result} <- prune(files, staging, markers, directories, options) do
      {:ok, result}
    else
      {:error, :unsafe_directory} -> {:error, :prune_unsafe_directory}
      {:error, :delete_failed} -> {:error, :prune_delete_failed}
      _ -> {:error, :prune_unavailable}
    end
  end

  def run(_), do: {:error, :prune_unavailable}

  defp directories(root, uid) do
    paths = [root | Enum.map(@artifact_dirs, &Path.join(root, &1))]

    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, found} ->
      case ArtifactIdentity.owner_directory(path, uid) do
        {:ok, stat} -> {:cont, {:ok, Map.put(found, path, stat)}}
        error -> {:halt, error}
      end
    end)
  end

  defp artifacts(directories) do
    directories
    |> Map.keys()
    |> Enum.filter(&(Path.basename(&1) in @artifact_dirs))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn directory, {:ok, files, staging} ->
      case scan_directory(directory, files, staging) do
        {:ok, files, staging} -> {:cont, {:ok, files, staging}}
        error -> {:halt, error}
      end
    end)
  end

  defp scan_directory(directory, files, staging) do
    case File.ls(directory) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, files, staging}, fn name, {:ok, files, staging} ->
          case scan_name(directory, name, files, staging) do
            {:ok, files, staging} -> {:cont, {:ok, files, staging}}
            error -> {:halt, error}
          end
        end)

      _ ->
        {:error, :unavailable}
    end
  end

  defp scan_name(directory, name, files, staging) do
    case artifact_ref(Path.basename(directory), name) do
      nil -> {:ok, files, staging_from_name(staging, name)}
      ref -> scan_artifact(Path.join(directory, name), ref, files, staging)
    end
  end

  defp scan_artifact(path, ref, files, staging) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, Map.update(files, ref, [{path, stat}], &[{path, stat} | &1]), staging}

      _ ->
        {:error, :unsafe_directory}
    end
  end

  defp artifact_ref("traces", name), do: TraceDirectoryAdmission.run_claim(name)

  defp artifact_ref(directory, name) do
    suffix = if directory == "inspection", do: ".ptcins", else: ".json"

    if String.ends_with?(name, suffix) do
      name
      |> String.trim_trailing(suffix)
      |> TraceDirectoryAdmission.canonical_stem()
    end
  end

  defp staging_from_name(staging, name) do
    case String.split(name, ~r/\.ptc-(?:tmp|marker)-/, parts: 2) do
      [base, _token] ->
        case base do
          "" ->
            MapSet.put(staging, :all)

          _ ->
            ref =
              Enum.find_value(@artifact_dirs, fn directory -> artifact_ref(directory, base) end)

            if ref, do: MapSet.put(staging, ref), else: staging
        end

      _ ->
        staging
    end
  end

  defp markers(root, uid) do
    keep = Path.join(root, "keep")

    case File.lstat(keep, time: :posix) do
      {:error, :enoent} ->
        {:ok, MapSet.new()}

      {:ok, _} ->
        with {:ok, _} <- ArtifactIdentity.owner_directory(keep, uid),
             {:ok, names} <- File.ls(keep) do
          read_markers(keep, names, uid)
        end

      _ ->
        {:error, :unsafe_directory}
    end
  end

  defp read_markers(keep, names, uid) do
    Enum.reduce_while(names, {:ok, MapSet.new()}, fn name, {:ok, refs} ->
      case marker(keep, name, uid) do
        :ignore -> {:cont, {:ok, refs}}
        :ok -> {:cont, {:ok, MapSet.put(refs, name)}}
        error -> {:halt, error}
      end
    end)
  end

  defp marker(keep, name, uid) do
    if TraceDirectoryAdmission.canonical_stem(name) == name do
      case File.lstat(Path.join(keep, name)) do
        {:ok, %File.Stat{type: :regular, size: 0, uid: ^uid}} -> :ok
        _ -> {:error, :unsafe_directory}
      end
    else
      :ignore
    end
  end

  defp prune(files, staging, markers, directories, options) do
    now = System.os_time(:second)
    age = Map.get(options, :max_age_days)
    maximum = Map.get(options, :max_bytes)
    dry? = Map.get(options, :dry_run, false)

    runs =
      files
      |> Enum.map(fn {ref, artifacts} ->
        %{
          ref: ref,
          artifacts: artifacts,
          bytes: Enum.sum(Enum.map(artifacts, fn {_, stat} -> stat.size end)),
          mtime: Enum.max(Enum.map(artifacts, fn {_, stat} -> stat.mtime end)),
          in_progress:
            MapSet.member?(staging, :all) or MapSet.member?(staging, ref) or
              Enum.any?(artifacts, fn {_, stat} -> now - stat.mtime < @grace_seconds end)
        }
      end)
      |> Enum.sort_by(&{&1.mtime, &1.ref})

    total = Enum.sum(Enum.map(runs, & &1.bytes))
    kept = runs |> Enum.filter(&MapSet.member?(markers, &1.ref)) |> Enum.map(& &1.ref)

    {selected, skipped, _projected} =
      Enum.reduce(runs, {[], [], total}, fn run, {selected, skipped, bytes} ->
        age_due? = is_integer(age) and now - run.mtime > age * @seconds_per_day
        size_due? = is_integer(maximum) and bytes > maximum

        cond do
          MapSet.member?(markers, run.ref) -> {selected, skipped, bytes}
          run.in_progress -> {selected, [run.ref | skipped], bytes}
          age_due? or size_due? -> {[run | selected], skipped, bytes - run.bytes}
          true -> {selected, skipped, bytes}
        end
      end)

    selected = Enum.reverse(selected)
    skipped = Enum.sort(skipped)

    with {:ok, deleted, extra_skipped} <- delete(selected, markers, directories, dry?, now) do
      freed = Enum.sum(Enum.map(deleted, & &1.bytes))

      kept_bytes =
        runs |> Enum.filter(&MapSet.member?(markers, &1.ref)) |> Enum.sum_by(& &1.bytes)

      {:ok,
       %{
         "deleted" => Enum.map(deleted, & &1.ref),
         "bytes_freed" => freed,
         "kept" => Enum.sort(kept),
         "skipped" =>
           Enum.map(
             Enum.sort(skipped ++ extra_skipped),
             &%{"run_ref" => &1, "reason" => "in_progress"}
           ),
         "remaining_bytes" => total - freed,
         "dangling_keep_markers" =>
           markers
           |> MapSet.difference(MapSet.new(Map.keys(files)))
           |> MapSet.to_list()
           |> Enum.sort(),
         "kept_exceeds_max_bytes" => is_integer(maximum) and kept_bytes > maximum
       }}
    end
  end

  defp delete(selected, markers, directories, dry?, now) do
    Enum.reduce_while(selected, {:ok, [], []}, fn run, {:ok, deleted, skipped} ->
      if dry? do
        {:cont, {:ok, [run | deleted], skipped}}
      else
        case delete_run(run, markers, directories, now) do
          :ok -> {:cont, {:ok, [run | deleted], skipped}}
          :in_progress -> {:cont, {:ok, deleted, [run.ref | skipped]}}
          _ -> {:halt, {:error, :delete_failed}}
        end
      end
    end)
    |> case do
      {:ok, deleted, skipped} -> {:ok, Enum.reverse(deleted), skipped}
      error -> error
    end
  end

  defp delete_run(run, markers, directories, now) do
    delete_locked(run, markers, directories, now)
  end

  defp root_path(directories) do
    directories
    |> Map.keys()
    |> Enum.find(fn path -> Path.join(path, "traces") in Map.keys(directories) end)
  end

  defp delete_locked(run, markers, directories, now) do
    keep_path = Path.join([root_path(directories), "keep", run.ref])

    if MapSet.member?(markers, run.ref) or match?({:ok, _}, File.lstat(keep_path)) or
         Enum.any?(run.artifacts, fn {_, stat} -> now - stat.mtime < @grace_seconds end) or
         not Enum.all?(directories, fn {path, stat} -> ArtifactIdentity.unchanged?(path, stat) end) or
         not run_files_unchanged?(run, directories) or
         not Enum.all?(run.artifacts, fn {path, stat} ->
           ArtifactIdentity.stable_file?(path, stat)
         end) do
      :in_progress
    else
      run.artifacts
      |> Enum.sort_by(fn {path, _} -> Path.basename(Path.dirname(path)) != "traces" end)
      |> remove_files()
    end
  end

  defp remove_files(artifacts) do
    Enum.reduce_while(artifacts, :ok, fn {path, stat}, :ok ->
      result =
        if Path.basename(Path.dirname(path)) == "traces" do
          TraceLog.with_append_authority_lock(path, fn -> unlink_if_stable(path, stat) end)
        else
          unlink_if_stable(path, stat)
        end

      case result do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :delete_failed}}
      end
    end)
  end

  defp unlink_if_stable(path, stat) do
    if ArtifactIdentity.stable_file?(path, stat),
      do: File.rm(path),
      else: {:error, :delete_failed}
  end

  defp run_files_unchanged?(run, directories) do
    expected = run.artifacts |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    directories
    |> Map.keys()
    |> Enum.filter(&(Path.basename(&1) in @artifact_dirs))
    |> Enum.all?(fn directory ->
      case File.ls(directory) do
        {:ok, names} ->
          current =
            names
            |> Enum.filter(&(artifact_ref(Path.basename(directory), &1) == run.ref))
            |> Enum.map(&Path.join(directory, &1))
            |> MapSet.new()

          staged? =
            Enum.any?(names, fn name ->
              MapSet.member?(staging_from_name(MapSet.new(), name), run.ref) or
                MapSet.member?(staging_from_name(MapSet.new(), name), :all)
            end)

          not staged? and MapSet.subset?(current, expected)

        _ ->
          false
      end
    end)
  end
end
