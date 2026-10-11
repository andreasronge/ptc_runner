defmodule PtcRunner.Kernel.PrivateDirectory do
  @moduledoc false

  alias PtcRunner.Kernel.SystemCommand
  alias PtcRunner.Lisp.DirectoryCreation
  alias PtcRunner.Lisp.TemporaryDirectory

  @temporary_prefix ".ptc-private-"
  @temporary_random_bytes 6
  @external_command_timeout_ms 10_000

  @type error ::
          :private_directory_unsupported
          | :private_directory_unavailable
          | :private_directory_parent_unavailable
          | :private_directory_parent_unsafe
          | :private_directory_creation_failed
          | :eexist
          | :eacces
          | :edquot
          | :enospc
          | :erofs

  @spec anchor(binary()) :: {:ok, binary()} | {:error, :private_directory_parent_unavailable}
  defdelegate anchor(path), to: DirectoryCreation
  @doc false
  @spec anchor(binary(), binary() | nil) ::
          {:ok, binary()} | {:error, :private_directory_parent_unavailable}
  defdelegate anchor(path, cwd), to: DirectoryCreation

  @doc false
  @spec casefold_name(binary()) :: binary()
  def casefold_name(name) when is_binary(name) do
    name
    |> String.normalize(:nfc)
    |> String.to_charlist()
    |> :string.casefold()
    |> :unicode.characters_to_binary()
    |> String.normalize(:nfc)
  end

  @doc false
  @spec temporary_sibling(binary(), binary()) :: {binary(), binary()}
  def temporary_sibling(path, leaf) when is_binary(path) and is_binary(leaf) do
    directory =
      Path.join(
        Path.dirname(path),
        @temporary_prefix <>
          Base.encode16(:crypto.strong_rand_bytes(@temporary_random_bytes), case: :lower)
      )

    {directory, Path.join(directory, leaf)}
  end

  @spec preflight(binary()) :: :ok | {:error, error()}
  def preflight(path) when is_binary(path) do
    result =
      with {:ok, executables} <- DirectoryCreation.creation_executables(),
           do: preflight_creation_with(path, executables.id)

    case result do
      {:ok, _uid} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def preflight(_path), do: {:error, :private_directory_parent_unavailable}

  @doc false
  @spec preflight_owner(binary()) :: {:ok, non_neg_integer()} | {:error, error()}
  def preflight_owner(path) when is_binary(path) do
    with {:ok, id} <- DirectoryCreation.authority_executable(),
         do: preflight_owner_with(path, id)
  end

  def preflight_owner(_path), do: {:error, :private_directory_parent_unavailable}

  @doc false
  @spec preflight_writable_parent(binary()) :: :ok | {:error, error()}
  def preflight_writable_parent(path) when is_binary(path) do
    with {:ok, id} <- DirectoryCreation.authority_executable(),
         {:ok, uid} <- DirectoryCreation.read_authority_uid(id),
         {:ok, groups} <- DirectoryCreation.read_authority_groups(id),
         {:ok, path} <- anchor(path),
         :ok <- DirectoryCreation.safe_parent_hierarchy(path, uid),
         {:ok, %File.Stat{type: :directory} = parent} <-
           File.stat(Path.dirname(path), time: :posix),
         :ok <- DirectoryCreation.writable_directory(parent, uid, groups) do
      :ok
    else
      {:error, reason}
      when reason in [
             :private_directory_unsupported,
             :private_directory_unavailable,
             :private_directory_parent_unsafe
           ] ->
        {:error, reason}

      _unavailable_or_unwritable ->
        {:error, :private_directory_parent_unavailable}
    end
  rescue
    _exception -> {:error, :private_directory_parent_unavailable}
  end

  def preflight_writable_parent(_path),
    do: {:error, :private_directory_parent_unavailable}

  @doc false
  @spec preflight_writable_file(binary()) :: :ok | {:error, error()}
  def preflight_writable_file(path) when is_binary(path) do
    with {:ok, id} <- DirectoryCreation.authority_executable(),
         {:ok, uid} <- DirectoryCreation.read_authority_uid(id),
         {:ok, groups} <- DirectoryCreation.read_authority_groups(id) do
      preflight_writable_file(path, %{uid: uid, groups: groups})
    end
  rescue
    _exception -> {:error, :private_directory_parent_unavailable}
  end

  def preflight_writable_file(_path),
    do: {:error, :private_directory_parent_unavailable}

  @doc false
  @spec preflight_writable_file(binary(), %{uid: non_neg_integer(), groups: MapSet.t()}) ::
          :ok | {:error, error()}
  def preflight_writable_file(path, %{uid: uid, groups: %MapSet{} = groups})
      when is_binary(path) and is_integer(uid) and uid >= 0 do
    with {:ok, path} <- anchor(path),
         {:ok, %File.Stat{type: :regular} = file} <- File.stat(path, time: :posix),
         :ok <- DirectoryCreation.writable_file(file, uid, groups) do
      :ok
    else
      _unavailable_or_unwritable ->
        {:error, :private_directory_parent_unavailable}
    end
  rescue
    _exception -> {:error, :private_directory_parent_unavailable}
  end

  def preflight_writable_file(_path, _authority),
    do: {:error, :private_directory_parent_unavailable}

  defp preflight_owner_with(path, id) do
    with {:ok, uid} <- DirectoryCreation.read_authority_uid(id),
         {:ok, path} <- anchor(path),
         :ok <- DirectoryCreation.safe_parent_hierarchy(path, uid) do
      {:ok, uid}
    else
      {:error, reason}
      when reason in [
             :private_directory_unsupported,
             :private_directory_unavailable,
             :private_directory_parent_unavailable,
             :private_directory_parent_unsafe
           ] ->
        {:error, reason}

      _missing_or_invalid_parent ->
        {:error, :private_directory_parent_unavailable}
    end
  end

  defp preflight_creation_with(path, id) do
    with {:ok, uid} <- DirectoryCreation.read_authority_uid(id),
         {:ok, groups} <- DirectoryCreation.read_authority_groups(id),
         {:ok, path} <- anchor(path),
         :ok <- DirectoryCreation.safe_parent_hierarchy(path, uid),
         {:ok, %File.Stat{type: :directory} = parent} <-
           File.stat(Path.dirname(path), time: :posix),
         :ok <- DirectoryCreation.writable_directory(parent, uid, groups),
         :ok <- temporary_sibling_supported(path) do
      {:ok, uid}
    else
      {:error, reason}
      when reason in [
             :private_directory_unsupported,
             :private_directory_unavailable,
             :private_directory_parent_unavailable,
             :private_directory_parent_unsafe
           ] ->
        {:error, reason}

      _missing_or_invalid_parent ->
        {:error, :private_directory_parent_unavailable}
    end
  end

  @typedoc """
  Which ancestor of a refused path earned the refusal, and how.

  `:none` covers both a safe ancestry and an ancestry that changed after the
  refusal; a caller must fall back to its generic code rather than assert a
  cause it can no longer see.
  """
  @type parent_fault ::
          {:missing, binary(), binary()}
          | {:unsafe_mode, binary()}
          | {:foreign_owner, binary()}
          | {:unwritable, binary()}
          | :none

  @doc """
  Names the ancestor that makes `path` unpublishable, for diagnostics only.

  Every safety decision stays with `preflight/1`, `preflight_writable_parent/1`
  and `create/1`; this runs afterwards, on a path one of them already refused,
  so a caller can report *which* directory to create or repair instead of a
  bare "unusable parent". Pass the anchored path those checks used, so the
  answer describes the directory they refused rather than one resolved against
  a since-changed working directory.

  A missing ancestor answers with two paths: the shallowest one that does not
  exist, which is what went wrong, and the fully resolved parent the walk was
  reaching for, which is what has to be created. They differ once a symlink is
  involved — creating the link's own name would fail, because the link already
  exists.

  It walks the ancestry a second time, so an ancestor repaired in between is
  reported as it is now; the refusal itself is not revisited. When the second
  walk finds nothing wrong it answers `:none`, and the caller keeps its
  generic code — that is also what a refusal for some other reason, such as an
  unrepresentable name, looks like from here.
  """
  @spec parent_fault(binary()) :: parent_fault()
  def parent_fault(path) when is_binary(path) do
    with {:ok, id} <- DirectoryCreation.authority_executable(),
         {:ok, uid} <- DirectoryCreation.read_authority_uid(id),
         {:ok, groups} <- DirectoryCreation.read_authority_groups(id),
         {:ok, anchored} <- anchor(path) do
      classify_fault(DirectoryCreation.locate_parent_fault(anchored, uid), uid, groups)
    else
      _unavailable -> :none
    end
  rescue
    _exception -> :none
  end

  def parent_fault(_path), do: :none

  @doc false
  @spec resolved_parent(binary()) :: {:ok, binary()} | :error
  def resolved_parent(path) when is_binary(path) do
    with {:ok, id} <- DirectoryCreation.authority_executable(),
         {:ok, uid} <- DirectoryCreation.read_authority_uid(id),
         {:ok, anchored} <- anchor(path),
         {:ok, parent} <- DirectoryCreation.locate_parent_fault(anchored, uid) do
      {:ok, parent}
    else
      _unavailable_or_unsafe -> :error
    end
  rescue
    _exception -> :error
  end

  def resolved_parent(_path), do: :error

  # Ownership and mode are separate refusals with separate remedies: `chmod`
  # cannot fix a directory another user owns, and a foreign owner is not made
  # safe by narrowing its mode.
  defp classify_fault(
         {:error, {:private_directory_parent_unsafe, faulted, _intended}},
         uid,
         _groups
       ) do
    case File.lstat(faulted, time: :posix) do
      {:ok, %File.Stat{uid: owner}} when owner not in [0, uid] -> {:foreign_owner, faulted}
      {:ok, %File.Stat{}} -> {:unsafe_mode, faulted}
      _gone_or_unreadable -> :none
    end
  end

  defp classify_fault(
         {:error, {:private_directory_parent_unavailable, faulted, intended}},
         _uid,
         _groups
       ) do
    case File.lstat(faulted) do
      {:error, :enoent} -> {:missing, faulted, intended}
      _present_or_unreadable -> :none
    end
  end

  defp classify_fault({:ok, parent}, uid, groups) do
    case File.stat(parent, time: :posix) do
      {:ok, %File.Stat{type: :directory, uid: ^uid} = stat} ->
        if DirectoryCreation.writable_directory(stat, uid, groups) == :ok,
          do: :none,
          else: {:unwritable, parent}

      _foreign_or_invalid ->
        :none
    end
  end

  @doc """
  Checks an lstat or open-descriptor stat for an owner-only directory.
  Private artifacts must belong to the runtime uid, including when root owns
  an ancestor. Symlinks and permissions other than 0700 are refused.
  """
  @spec private_dir?(File.Stat.t(), non_neg_integer()) :: boolean()
  def private_dir?(%File.Stat{type: :directory, uid: uid, mode: mode}, uid),
    do: Bitwise.band(mode, 0o777) == 0o700

  def private_dir?(_stat, _uid), do: false

  @doc """
  Checks a stat for a regular file owned by the runtime uid with mode 0600.
  Uses the same owner policy as `private_dir?/2`.
  """
  @spec private_file?(File.Stat.t(), non_neg_integer()) :: boolean()
  def private_file?(%File.Stat{type: :regular, uid: uid, mode: mode}, uid),
    do: Bitwise.band(mode, 0o777) == 0o600

  def private_file?(_stat, _uid), do: false

  @doc """
  Creates an exclusive random temporary directory with mode 0700 at creation.
  Uses the checked parent and uid policy of `create/1`; existing names are
  retried without adopting or removing them. The caller owns cleanup.
  """
  @spec create_temp(binary(), pos_integer()) :: {:ok, binary()} | {:error, error()}
  def create_temp(prefix, attempts \\ 10),
    do: TemporaryDirectory.create(prefix, attempts, &create/1)

  @spec create(binary()) :: :ok | {:error, error()}
  def create(path), do: DirectoryCreation.create(path, &private_dir?/2)

  @doc false
  @spec staging_lock_path(binary()) :: binary()
  def staging_lock_path(staging),
    do: Path.join(Path.dirname(staging), ".ptc-artifact-staging.reclaim")

  @doc false
  @spec write_owner(binary()) :: :ok | {:error, term()}
  def write_owner(path) do
    owner = Path.join(path, "owner")
    with :ok <- File.write(owner, System.pid(), [:exclusive]), do: File.chmod(owner, 0o600)
  end

  @doc false
  @spec owner_marker(binary()) :: {:ok, binary()} | :missing | :unknown
  def owner_marker(path) do
    owner = Path.join(path, "owner")

    case File.lstat(owner) do
      {:ok, %{type: :regular, size: size, mode: mode} = expected}
      when size <= 10 and
             Bitwise.band(mode, 0o400) != 0 ->
        launcher = Module.concat(["PtcRunnerLauncher"])

        result =
          if Code.ensure_loaded?(launcher) and
               function_exported?(launcher, :read_owner_bounded, 1),
             do: launcher.read_owner_bounded(path),
             else: read_owner_without_launcher(owner, expected)

        case result do
          {:ok, pid} -> {:ok, pid}
          _unreadable -> :unknown
        end

      {:error, :enoent} ->
        :missing

      _invalid ->
        :unknown
    end
  end

  # Reservation recovery also serves hosts that do not load native support.
  # Bound both the read size and command lifetime, including a replaced FIFO.
  defp read_owner_without_launcher(owner, expected) do
    with executable when is_binary(executable) <- System.find_executable("head"),
         {:ok, {pid, 0}} <-
           SystemCommand.run(executable, ["-c", "11", owner], @external_command_timeout_ms),
         true <- byte_size(pid) <= 10,
         {:ok, current} <- File.lstat(owner),
         true <- current.size == byte_size(pid),
         true <- Map.delete(current, :atime) == Map.delete(expected, :atime) do
      {:ok, pid}
    else
      _unreadable -> {:error, :owner_unavailable}
    end
  end

  @doc false
  @spec stale_owner?(binary(), File.Stat.t()) :: boolean()
  def stale_owner?(path, stat), do: stale_marker?(owner_marker(path), stat)

  @doc false
  @spec stale_marker?({:ok, binary()} | :missing | :unknown, File.Stat.t()) :: boolean()
  def stale_marker?({:ok, pid}, _stat), do: owner_dead?(pid)
  def stale_marker?(:missing, stat), do: System.os_time(:second) - stat.mtime > 60
  def stale_marker?(:unknown, _stat), do: false

  @spec owner_dead?(binary()) :: boolean()
  defp owner_dead?(pid) do
    with true <- Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, pid),
         {number, ""} when number <= 2_147_483_647 <- Integer.parse(pid),
         executable when is_binary(executable) <- System.find_executable("kill"),
         env when is_binary(env) <- System.find_executable("env"),
         {:ok, {output, status}} when status != 0 <-
           SystemCommand.run(
             env,
             ["LC_ALL=C", executable, "-0", pid],
             @external_command_timeout_ms
           ) do
      # EPERM and every unrecognized failure count as alive. Only ESRCH
      # proves the same-host owner is gone; normalize the command's locale.
      String.contains?(output, "No such process")
    else
      _alive_or_unknown -> false
    end
  rescue
    _exception -> false
  end

  # Publication uses a short sibling name independent of the destination
  # basename. Probe paths of the exact generated lengths so deterministic
  # NAME_MAX/PATH_MAX failures are caught during read-only preflight.
  defp temporary_sibling_supported(path) do
    {directory, artifact} = temporary_sibling(path, "artifact")

    with :ok <- representable_path(directory),
         do: representable_path(artifact)
  end

  defp representable_path(path) do
    case File.lstat(path) do
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :private_directory_parent_unavailable}
    end
  end
end
