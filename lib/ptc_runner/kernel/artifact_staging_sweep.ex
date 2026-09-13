defmodule PtcRunner.Kernel.ArtifactStagingSweep do
  @moduledoc false

  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.TraceLog

  @entries 256
  @candidates 16
  @children ~w(envelopes inspection results traces)

  @spec sweep(binary()) :: :ok
  def sweep(root) do
    launcher = Module.concat(["PtcRunnerLauncher"])

    with true <- Code.ensure_loaded?(launcher),
         true <- function_exported?(launcher, :list_directory_bounded, 3),
         true <- function_exported?(launcher, :remove_staging_bounded, 4),
         {:ok, _executable} <- launcher.executable_path() do
      sweep_available(root)
    else
      _unavailable -> :ok
    end
  end

  defp sweep_available(root) do
    with {:ok, uid} <- PrivateDirectory.preflight_owner(Path.join(root, "unused")),
         {:ok, root_stat} <- directory(root, uid) do
      Enum.reduce_while(
        Enum.with_index([root | Enum.map(@children, &Path.join(root, &1))]),
        {@entries, @candidates},
        fn {parent, index}, {entries, candidates} ->
          if entries == 0 or candidates == 0 do
            {:halt, {entries, candidates}}
          else
            parents = 5 - index
            entry_quota = div(entries + parents - 1, parents)
            candidate_quota = div(candidates + parents - 1, parents)

            {left_entries, left_candidates} =
              inspect_parent(parent, root, root_stat, uid, entry_quota, candidate_quota)

            {:cont,
             {entries - entry_quota + left_entries,
              candidates - candidate_quota + left_candidates}}
          end
        end
      )
    end

    :ok
  rescue
    _exception -> :ok
  end

  # One fixed lock per parent is shared with creators. Random staging names
  # must not introduce a permanent OS lock file for every run.
  defp inspect_parent(parent, root, root_stat, uid, entries, candidates) do
    lock = PrivateDirectory.staging_lock_path(Path.join(parent, "unused"))

    case TraceLog.with_append_authority_lock(lock, fn ->
           inspect_locked_parent(parent, root, root_stat, uid, entries, candidates)
         end) do
      {remaining_entries, remaining_candidates} when is_integer(remaining_entries) ->
        {remaining_entries, remaining_candidates}

      _unavailable ->
        {entries, candidates}
    end
  end

  defp inspect_locked_parent(parent, root, root_stat, uid, entries, candidates) do
    with {:ok, parent_stat} <- directory(parent, uid),
         {:ok, names, inspected} <- list(parent, entries, candidates) do
      remaining =
        Enum.reduce_while(names, candidates, fn name, budget ->
          cond do
            budget == 0 ->
              {:halt, 0}

            Regex.match?(~r/\A\.ptc-private-[0-9a-f]{12}\z/, name) ->
              path = Path.join(parent, name)

              _ = reclaim(path, parent, parent_stat, root, root_stat, uid)

              {:cont, budget - 1}

            true ->
              {:cont, budget}
          end
        end)

      {entries - inspected, remaining}
    else
      _unavailable -> {entries, candidates}
    end
  end

  # The native helper rechecks the exact marker and identities while holding
  # directory descriptors. It never recursively walks staging contents.
  defp reclaim(path, parent, parent_stat, root, root_stat, uid) do
    with {:ok, stat} <- directory(path, uid),
         marker = PrivateDirectory.owner_marker(path),
         true <- PrivateDirectory.stale_marker?(marker, stat),
         true <- unchanged?(root, root_stat) and unchanged?(parent, parent_stat),
         true <- unchanged?(path, stat) do
      owner =
        case marker do
          {:ok, pid} -> pid
          :missing -> "-"
        end

      launcher = Module.concat(["PtcRunnerLauncher"])
      launcher.remove_staging_bounded(path, parent_stat, stat, owner)
    else
      _live_or_uncertain -> :ok
    end
  end

  defp directory(path, uid) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory, uid: ^uid, mode: mode} = stat}
      when Bitwise.band(mode, 0o777) == 0o700 ->
        {:ok, stat}

      _unsafe ->
        {:error, :unsafe_directory}
    end
  end

  defp unchanged?(path, expected) do
    case File.lstat(path) do
      {:ok, current} ->
        {current.type, current.uid, Bitwise.band(current.mode, 0o777), current.major_device,
         current.minor_device, current.inode} ==
          {expected.type, expected.uid, Bitwise.band(expected.mode, 0o777), expected.major_device,
           expected.minor_device, expected.inode}

      _changed ->
        false
    end
  end

  defp list(path, limit, candidates) do
    launcher = Module.concat(["PtcRunnerLauncher"])

    if Code.ensure_loaded?(launcher) and function_exported?(launcher, :list_directory_bounded, 3),
      do: launcher.list_directory_bounded(path, limit, candidates),
      else: {:error, :unavailable}
  end
end
