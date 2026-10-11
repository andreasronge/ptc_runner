defmodule PtcRunner.Lisp.DirectoryCreation do
  @moduledoc false

  alias PtcRunner.Lisp.Sandbox

  @external_command_timeout_ms 10_000
  @type error :: atom()

  @spec anchor(binary()) :: {:ok, binary()} | {:error, :private_directory_parent_unavailable}
  def anchor(path) when is_binary(path) do
    case Path.type(path) do
      :absolute ->
        {:ok, path}

      :relative ->
        case File.cwd() do
          {:ok, cwd} -> anchor(path, cwd)
          {:error, _reason} -> {:error, :private_directory_parent_unavailable}
        end

      _other ->
        {:error, :private_directory_parent_unavailable}
    end
  rescue
    _exception -> {:error, :private_directory_parent_unavailable}
  end

  def anchor(_path), do: {:error, :private_directory_parent_unavailable}

  @doc false
  @spec anchor(binary(), binary() | nil) ::
          {:ok, binary()} | {:error, :private_directory_parent_unavailable}
  def anchor(path, cwd) when is_binary(path) do
    case Path.type(path) do
      :absolute ->
        {:ok, path}

      :relative when is_binary(cwd) ->
        {:ok, Path.join(cwd, path)}

      _other ->
        {:error, :private_directory_parent_unavailable}
    end
  rescue
    _exception -> {:error, :private_directory_parent_unavailable}
  end

  def anchor(_path, _cwd), do: {:error, :private_directory_parent_unavailable}

  @spec create(binary(), (File.Stat.t(), non_neg_integer() -> boolean())) ::
          :ok | {:error, atom()}
  def create(path, validator \\ &owner_only_directory?/2)

  def create(path, validator) when is_binary(path) do
    with {:ok, executables} <- creation_executables(),
         {:ok, uid} <- read_authority_uid(executables.id),
         {:ok, groups} <- read_authority_groups(executables.id),
         {:ok, path} <- anchor(path),
         :ok <- safe_parent_hierarchy(path, uid),
         {:ok, %File.Stat{type: :directory} = parent} <-
           File.stat(Path.dirname(path), time: :posix),
         :ok <- writable_directory(parent, uid, groups),
         :ok <- create_unix(executables.mkdir, path) do
      verify_created_directory(path, uid, validator)
    end
  end

  def create(_path, _validator), do: {:error, :private_directory_creation_failed}

  def authority_executable do
    case :os.type() do
      {:unix, _name} ->
        case System.find_executable("id") do
          id when is_binary(id) -> {:ok, id}
          nil -> {:error, :private_directory_unavailable}
        end

      _other ->
        {:error, :private_directory_unsupported}
    end
  end

  def creation_executables do
    with {:ok, id} <- authority_executable(),
         mkdir when is_binary(mkdir) <- System.find_executable("mkdir") do
      {:ok, %{mkdir: mkdir, id: id}}
    else
      {:error, _reason} = error -> error
      nil -> {:error, :private_directory_unavailable}
    end
  end

  defp create_unix(executable, path) do
    path = if Path.type(path) == :relative, do: "./" <> path, else: path

    case command(
           executable,
           ["-m", "700", path],
           @external_command_timeout_ms,
           [{"LC_ALL", "C"}]
         ) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, _status}} -> {:error, creation_failure_reason(output)}
      {:error, _reason} -> {:error, :private_directory_creation_failed}
    end
  rescue
    _exception -> {:error, :private_directory_creation_failed}
  end

  # A BEAM process cannot change its own uid or supplementary groups after it
  # starts, so both are read once per VM and kept. Without this every private
  # directory costs three subprocesses -- `id -u`, `id -G`, `mkdir` -- and the
  # two identity reads are over half of that. Under suite concurrency each of
  # those spawns is a chance for the bounded command worker to fail or exceed its
  # bound, which surfaces as :private_directory_unavailable in whichever test
  # happened to be capturing a trace.
  # Deliberately not single-flighted. Concurrent cold callers can each run the
  # read once, which costs a handful of duplicate subprocesses in the first
  # milliseconds of a VM against the thousands this removes over its life.
  # Serialising that window would mean an owner process or a cross-node lock on
  # a path that must stay callable from anywhere, which is a worse trade than
  # the duplicates. The read is idempotent, so a race only repeats work.
  defp cached(kind, executable, read) do
    case identity(executable) do
      {:ok, identity} -> cached_by({__MODULE__, kind, executable, identity}, read)
      :error -> read.()
    end
  end

  defp cached_by(key, read) do
    case :persistent_term.get(key, :missing) do
      :missing ->
        case read.() do
          {:ok, value} = ok ->
            :persistent_term.put(key, value)
            ok

          {:error, _reason} = error ->
            error
        end

      value ->
        {:ok, value}
    end
  end

  # An entry answers "what did this exact binary report", so the key carries the
  # binary's content digest, not its pathname. `authority_executable/0` resolves
  # through `System.find_executable/1`, so PATH decides which `id` answers and a
  # stand-in on PATH is a different question -- which is how the ownership tests
  # exercise an authority mismatch. A pathname alone is not enough: replacing the
  # binary at that path would be served a stale uid forever. Nor is stat
  # metadata: rewriting a small script in place keeps its device, inode and size
  # and, at the one-second resolution Erlang reports, usually its mtime too.
  # Digesting costs 0.53ms against the 12.26ms of subprocesses it guards, and an
  # unreadable executable simply does not cache.
  def read_authority_uid(executable),
    do:
      cached(:authority_uid, executable, fn ->
        read_authority_uid_uncached(executable)
      end)

  def read_authority_groups(executable),
    do:
      cached(:authority_groups, executable, fn ->
        read_authority_groups_uncached(executable)
      end)

  defp identity(executable) do
    case File.read(executable) do
      {:ok, contents} -> {:ok, :crypto.hash(:sha256, contents)}
      _unreadable -> :error
    end
  end

  defp read_authority_uid_uncached(executable) do
    case command(executable, ["-u"], @external_command_timeout_ms) do
      {:ok, {output, 0}} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> {:ok, uid}
          _invalid -> {:error, :private_directory_unavailable}
        end

      _failed_or_timed_out ->
        {:error, :private_directory_unavailable}
    end
  rescue
    _exception -> {:error, :private_directory_unavailable}
  end

  defp read_authority_groups_uncached(executable) do
    case command(executable, ["-G"], @external_command_timeout_ms) do
      {:ok, {output, 0}} ->
        groups =
          output
          |> String.split()
          |> Enum.reduce_while({:ok, MapSet.new()}, fn value, {:ok, groups} ->
            case Integer.parse(value) do
              {group, ""} when group >= 0 -> {:cont, {:ok, MapSet.put(groups, group)}}
              _invalid -> {:halt, {:error, :private_directory_unavailable}}
            end
          end)

        case groups do
          {:ok, groups} ->
            if MapSet.size(groups) > 0,
              do: {:ok, groups},
              else: {:error, :private_directory_unavailable}

          _invalid ->
            {:error, :private_directory_unavailable}
        end

      _failed_or_timed_out ->
        {:error, :private_directory_unavailable}
    end
  rescue
    _exception -> {:error, :private_directory_unavailable}
  end

  def safe_parent_hierarchy(path, uid) do
    case locate_parent_fault(path, uid) do
      {:ok, _parent} -> :ok
      {:error, {reason, _faulted, _intended}} -> {:error, reason}
    end
  end

  # The located form of the hierarchy walk: every refusal carries the exact
  # directory that earned it, plus the path the walk was resolving toward, so
  # a caller can both name what went wrong and name what has to be created.
  def locate_parent_fault(path, uid) do
    with :ok <- validate_directory("/", uid) do
      parent = Path.dirname(path)
      resolve_components("/", tl(Path.split(parent)), 0, uid)
    end
  rescue
    _exception -> {:error, {:private_directory_parent_unavailable, path, path}}
  end

  defp resolve_components(current, _components, hops, _uid) when hops > 40,
    do: {:error, {:private_directory_parent_unavailable, current, current}}

  defp resolve_components(current, [], _hops, uid) do
    with :ok <- validate_directory(current, uid), do: {:ok, current}
  end

  defp resolve_components(current, ["." | rest], hops, uid),
    do: resolve_components(current, rest, hops, uid)

  defp resolve_components(current, [".." | rest], hops, uid),
    do: resolve_components(Path.dirname(current), rest, hops, uid)

  defp resolve_components(current, [component | rest], hops, uid) do
    candidate = Path.join(current, component)

    case File.lstat(candidate, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        with :ok <- safe_directory(candidate, stat, uid),
             do: resolve_components(candidate, rest, hops, uid)

      {:ok, %File.Stat{type: :symlink} = stat} ->
        with :ok <- safe_symlink(candidate, stat, uid),
             {:ok, target} <- File.read_link(candidate),
             {:ok, target_root, target_components} <- symlink_target(current, target) do
          resolve_components(target_root, target_components ++ rest, hops + 1, uid)
        else
          {:error, {reason, faulted, intended}}
          when reason in [
                 :private_directory_parent_unsafe,
                 :private_directory_parent_unavailable
               ] ->
            {:error, {reason, faulted, intended}}

          _error ->
            {:error, {:private_directory_parent_unavailable, candidate, candidate}}
        end

      # The intended path keeps the components still unwalked, so a caller can
      # create every level at once — and, past a symlink, create the resolved
      # target rather than the link's own name, which already exists.
      _missing_or_invalid ->
        {:error,
         {:private_directory_parent_unavailable, candidate, Path.join([candidate | rest])}}
    end
  end

  defp symlink_target(current, target) do
    case Path.type(target) do
      :absolute -> {:ok, "/", tl(Path.split(target))}
      :relative -> {:ok, current, Path.split(target)}
      _other -> {:error, {:private_directory_parent_unavailable, current, current}}
    end
  end

  defp validate_directory(path, uid) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        safe_directory(path, stat, uid)

      _invalid ->
        {:error, {:private_directory_parent_unavailable, path, path}}
    end
  end

  # Sticky semantics protect entries owned by this process authority or root,
  # but not entries owned by a peer. Requiring trusted ownership for symlinks
  # closes the remaining replacement window in a trusted sticky directory.
  defp safe_symlink(path, %File.Stat{uid: owner}, uid) do
    if owner in [0, uid],
      do: :ok,
      else: {:error, {:private_directory_parent_unsafe, path, path}}
  end

  # Every controlling directory must be owned by this process authority or
  # root, as well as non-replaceable by group/other writers.
  defp safe_directory(path, %File.Stat{uid: owner, mode: mode}, uid) do
    owner_safe? = owner in [0, uid]
    mode_safe? = Bitwise.band(mode, 0o022) == 0 or Bitwise.band(mode, 0o1000) != 0

    if owner_safe? and mode_safe?,
      do: :ok,
      else: {:error, {:private_directory_parent_unsafe, path, path}}
  end

  def writable_directory(stat, uid, groups),
    do: writable(stat, uid, groups, 0o300, 0o030, 0o003)

  def writable_file(stat, uid, groups),
    do: writable(stat, uid, groups, 0o200, 0o020, 0o002)

  defp writable(
         %File.Stat{uid: owner, gid: group, mode: mode},
         uid,
         groups,
         owner_mask,
         group_mask,
         other_mask
       ) do
    mask =
      cond do
        owner == uid -> owner_mask
        MapSet.member?(groups, group) -> group_mask
        true -> other_mask
      end

    if Bitwise.band(mode, mask) == mask,
      do: :ok,
      else: {:error, :private_directory_parent_unavailable}
  end

  @doc false
  @spec creation_failure_reason(binary()) :: atom()
  defp creation_failure_reason(output) do
    cond do
      String.contains?(output, "File exists") -> :eexist
      String.contains?(output, "Permission denied") -> :eacces
      String.contains?(output, "Disk quota exceeded") -> :edquot
      String.contains?(output, "No space left on device") -> :enospc
      String.contains?(output, "Read-only file system") -> :erofs
      true -> :private_directory_creation_failed
    end
  end

  defp command(executable, arguments, timeout_ms, environment \\ []) do
    Sandbox.run_bounded(
      fn -> System.cmd(executable, arguments, stderr_to_stdout: true, env: environment) end,
      timeout: timeout_ms,
      max_heap: 100_000,
      link: true
    )
  end

  defp verify_created_directory(path, uid, validator) do
    with {:ok, stat} <- File.lstat(path, time: :posix),
         true <- validator.(stat, uid) do
      :ok
    else
      _changed_or_invalid -> {:error, :private_directory_creation_failed}
    end
  end

  defp owner_only_directory?(%File.Stat{type: :directory, uid: uid, mode: mode}, uid),
    do: Bitwise.band(mode, 0o777) == 0o700

  defp owner_only_directory?(_stat, _uid), do: false
end
