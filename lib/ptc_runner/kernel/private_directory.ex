defmodule PtcRunner.Kernel.PrivateDirectory do
  @moduledoc false

  @temporary_prefix ".ptc-private-"
  @temporary_random_bytes 6

  @type error ::
          :private_directory_unsupported
          | :private_directory_unavailable
          | :private_directory_parent_unavailable
          | :private_directory_parent_unsafe
          | :private_directory_creation_failed

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
      with {:ok, executables} <- creation_executables(),
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
    with {:ok, id} <- authority_executable(),
         do: preflight_owner_with(path, id)
  end

  def preflight_owner(_path), do: {:error, :private_directory_parent_unavailable}

  @doc false
  @spec preflight_writable_parent(binary()) :: :ok | {:error, error()}
  def preflight_writable_parent(path) when is_binary(path) do
    with {:ok, id} <- authority_executable(),
         {:ok, uid} <- read_authority_uid(id),
         {:ok, groups} <- read_authority_groups(id),
         {:ok, path} <- anchor(path),
         :ok <- safe_parent_hierarchy(path, uid),
         {:ok, %File.Stat{type: :directory} = parent} <-
           File.stat(Path.dirname(path), time: :posix),
         :ok <- writable_directory(parent, uid, groups) do
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
    with {:ok, id} <- authority_executable(),
         {:ok, uid} <- read_authority_uid(id),
         {:ok, groups} <- read_authority_groups(id) do
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
         :ok <- writable_file(file, uid, groups) do
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
    with {:ok, uid} <- read_authority_uid(id),
         {:ok, path} <- anchor(path),
         :ok <- safe_parent_hierarchy(path, uid) do
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
    with {:ok, uid} <- read_authority_uid(id),
         {:ok, groups} <- read_authority_groups(id),
         {:ok, path} <- anchor(path),
         :ok <- safe_parent_hierarchy(path, uid),
         {:ok, %File.Stat{type: :directory} = parent} <-
           File.stat(Path.dirname(path), time: :posix),
         :ok <- writable_directory(parent, uid, groups),
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

  @spec create(binary()) :: :ok | {:error, error()}
  def create(path) when is_binary(path) do
    with {:ok, executables} <- creation_executables(),
         {:ok, uid} <- read_authority_uid(executables.id),
         {:ok, groups} <- read_authority_groups(executables.id),
         {:ok, path} <- anchor(path),
         :ok <- safe_parent_hierarchy(path, uid),
         {:ok, %File.Stat{type: :directory} = parent} <-
           File.stat(Path.dirname(path), time: :posix),
         :ok <- writable_directory(parent, uid, groups),
         :ok <- create_unix(executables.mkdir, path) do
      verify_created_directory(path, uid)
    end
  end

  def create(_path), do: {:error, :private_directory_creation_failed}

  defp authority_executable do
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

  defp creation_executables do
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

    case System.cmd(executable, ["-m", "700", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :private_directory_creation_failed}
    end
  rescue
    _exception -> {:error, :private_directory_creation_failed}
  end

  defp read_authority_uid(executable) do
    case System.cmd(executable, ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> {:ok, uid}
          _invalid -> {:error, :private_directory_unavailable}
        end

      {_output, _status} ->
        {:error, :private_directory_unavailable}
    end
  rescue
    _exception -> {:error, :private_directory_unavailable}
  end

  defp read_authority_groups(executable) do
    case System.cmd(executable, ["-G"], stderr_to_stdout: true) do
      {output, 0} ->
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

      {_output, _status} ->
        {:error, :private_directory_unavailable}
    end
  rescue
    _exception -> {:error, :private_directory_unavailable}
  end

  defp safe_parent_hierarchy(path, uid) do
    with :ok <- validate_directory("/", uid) do
      parent = Path.dirname(path)
      resolve_components("/", tl(Path.split(parent)), 0, uid)
    end
  rescue
    _exception -> {:error, :private_directory_parent_unavailable}
  end

  defp resolve_components(_current, _components, hops, _uid) when hops > 40,
    do: {:error, :private_directory_parent_unavailable}

  defp resolve_components(current, [], _hops, uid) do
    case File.lstat(current, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} -> safe_directory(stat, uid)
      _invalid -> {:error, :private_directory_parent_unavailable}
    end
  end

  defp resolve_components(current, ["." | rest], hops, uid),
    do: resolve_components(current, rest, hops, uid)

  defp resolve_components(current, [".." | rest], hops, uid),
    do: resolve_components(Path.dirname(current), rest, hops, uid)

  defp resolve_components(current, [component | rest], hops, uid) do
    candidate = Path.join(current, component)

    case File.lstat(candidate, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        with :ok <- safe_directory(stat, uid),
             do: resolve_components(candidate, rest, hops, uid)

      {:ok, %File.Stat{type: :symlink} = stat} ->
        with :ok <- safe_symlink(stat, uid),
             {:ok, target} <- File.read_link(candidate),
             {:ok, target_root, target_components} <- symlink_target(current, target) do
          resolve_components(target_root, target_components ++ rest, hops + 1, uid)
        else
          {:error, reason}
          when reason in [
                 :private_directory_parent_unsafe,
                 :private_directory_parent_unavailable
               ] ->
            {:error, reason}

          _error ->
            {:error, :private_directory_parent_unavailable}
        end

      _missing_or_invalid ->
        {:error, :private_directory_parent_unavailable}
    end
  end

  defp symlink_target(current, target) do
    case Path.type(target) do
      :absolute -> {:ok, "/", tl(Path.split(target))}
      :relative -> {:ok, current, Path.split(target)}
      _other -> {:error, :private_directory_parent_unavailable}
    end
  end

  defp validate_directory(path, uid) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        safe_directory(stat, uid)

      _invalid ->
        {:error, :private_directory_parent_unavailable}
    end
  end

  # Sticky semantics protect entries owned by this process authority or root,
  # but not entries owned by a peer. Requiring trusted ownership for symlinks
  # closes the remaining replacement window in a trusted sticky directory.
  defp safe_symlink(%File.Stat{uid: owner}, uid) do
    if owner in [0, uid],
      do: :ok,
      else: {:error, :private_directory_parent_unsafe}
  end

  # Every controlling directory must be owned by this process authority or
  # root, as well as non-replaceable by group/other writers.
  defp safe_directory(%File.Stat{uid: owner, mode: mode}, uid) do
    owner_safe? = owner in [0, uid]
    mode_safe? = Bitwise.band(mode, 0o022) == 0 or Bitwise.band(mode, 0o1000) != 0

    if owner_safe? and mode_safe?,
      do: :ok,
      else: {:error, :private_directory_parent_unsafe}
  end

  defp writable_directory(stat, uid, groups),
    do: writable(stat, uid, groups, 0o300, 0o030, 0o003)

  defp writable_file(stat, uid, groups),
    do: writable(stat, uid, groups, 0o200, 0o020, 0o002)

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

  defp verify_created_directory(path, uid) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}}
      when Bitwise.band(mode, 0o777) == 0o700 ->
        :ok

      _changed_or_invalid ->
        {:error, :private_directory_creation_failed}
    end
  end
end
