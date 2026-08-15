defmodule PtcRunner.Kernel.PublicationHandle do
  @moduledoc false

  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationHandleOwner
  alias PtcRunner.Kernel.TraceLog

  @type identity :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type kind :: :trace | :inspection | :result | :recovery

  @enforce_keys [
    :kind,
    :path,
    :parent,
    :parent_identity,
    :file_identity,
    :reservation_path,
    :reservation_identity,
    :device,
    :mode,
    :staging_directory,
    :staging_path,
    :visible?,
    :append?,
    :expected_size,
    :expected_digest,
    :owner
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          kind: kind(),
          path: binary(),
          parent: binary(),
          parent_identity: identity(),
          file_identity: identity(),
          reservation_path: binary(),
          reservation_identity: identity(),
          device: :file.io_device(),
          mode: non_neg_integer(),
          staging_directory: binary() | nil,
          staging_path: binary(),
          visible?: boolean(),
          append?: boolean(),
          expected_size: non_neg_integer() | nil,
          expected_digest: binary() | nil,
          owner: pid()
        }

  @spec reserve(binary(), kind(), non_neg_integer()) ::
          {:ok, t()} | {:error, atom()}
  def reserve(path, kind, mode)
      when is_binary(path) and kind in [:trace, :inspection, :result, :recovery] and
             is_integer(mode) and mode >= 0 do
    reserve_for(path, kind, mode, self())
  end

  def reserve(_path, _kind, _mode), do: {:error, :invalid_destination}

  @doc false
  @spec reserve_for(binary(), kind(), non_neg_integer(), pid()) ::
          {:ok, t()} | {:error, atom()}
  def reserve_for(path, kind, mode, controller)
      when is_binary(path) and kind in [:trace, :inspection, :result, :recovery] and
             is_integer(mode) and mode >= 0 and is_pid(controller) do
    with {:ok, owner} <- PublicationHandleOwner.start(controller) do
      PublicationHandleOwner.reserve(owner, path, kind, mode)
    end
  end

  def reserve_for(_path, _kind, _mode, _controller), do: {:error, :invalid_destination}

  @doc false
  @spec reserve_direct(binary(), kind(), non_neg_integer(), pid()) ::
          {:ok, t()} | {:error, atom()}
  def reserve_direct(path, kind, mode, owner)
      when is_binary(path) and kind in [:trace, :inspection, :result, :recovery] and
             is_integer(mode) and mode >= 0 and is_pid(owner) do
    with :ok <- valid_path(path),
         {:ok, path} <- PrivateDirectory.anchor(path),
         :ok <- parent_present(path),
         :ok <- PrivateDirectory.preflight(path),
         {:ok, parent, parent_identity} <- parent_identity(path),
         {:error, :enoent} <- File.lstat(path) do
      reserve_staged(path, kind, mode, parent, parent_identity, owner)
    else
      {:ok, _stat} -> {:error, :destination_exists}
      {:error, _reason} = error -> normalize_error(error)
    end
  rescue
    _exception -> {:error, :destination_unavailable}
  end

  def reserve_direct(_path, _kind, _mode, _owner), do: {:error, :invalid_destination}

  @doc false
  @spec reserve_visible(binary(), kind(), non_neg_integer()) ::
          {:ok, t()} | {:error, atom()}
  def reserve_visible(path, kind, mode)
      when is_binary(path) and kind in [:trace, :inspection, :result, :recovery] and
             is_integer(mode) and mode >= 0 do
    reserve_visible_for(path, kind, mode, self())
  end

  def reserve_visible(_path, _kind, _mode), do: {:error, :invalid_destination}

  @doc false
  @spec reserve_visible_for(binary(), kind(), non_neg_integer(), pid()) ::
          {:ok, t()} | {:error, atom()}
  def reserve_visible_for(path, kind, mode, controller)
      when is_binary(path) and kind in [:trace, :inspection, :result, :recovery] and
             is_integer(mode) and mode >= 0 and is_pid(controller) do
    with {:ok, owner} <- PublicationHandleOwner.start(controller) do
      PublicationHandleOwner.reserve_visible(owner, path, kind, mode)
    end
  end

  def reserve_visible_for(_path, _kind, _mode, _controller), do: {:error, :invalid_destination}

  @doc false
  @spec reserve_visible_direct(binary(), kind(), non_neg_integer(), pid()) ::
          {:ok, t()} | {:error, atom()}
  def reserve_visible_direct(path, kind, mode, owner)
      when is_binary(path) and kind in [:trace, :inspection, :result, :recovery] and
             is_integer(mode) and mode >= 0 and is_pid(owner) do
    with :ok <- valid_path(path),
         {:ok, path} <- PrivateDirectory.anchor(path),
         :ok <- PrivateDirectory.preflight(path),
         {:ok, parent, parent_identity} <- parent_identity(path),
         {:error, :enoent} <- File.lstat(path) do
      reserve_visible_file(path, kind, mode, parent, parent_identity, owner)
    else
      {:ok, _stat} -> {:error, :destination_exists}
      {:error, _reason} = error -> normalize_error(error)
    end
  rescue
    _exception -> {:error, :destination_unavailable}
  end

  def reserve_visible_direct(_path, _kind, _mode, _owner), do: {:error, :invalid_destination}

  @doc false
  @spec reserve_append_direct(binary(), :trace, non_neg_integer(), pid()) ::
          {:ok, t()} | {:error, atom()}
  def reserve_append_direct(path, :trace, mode, owner)
      when is_binary(path) and is_integer(mode) and mode >= 0 and is_pid(owner) do
    reserve_append_direct(path, :trace, mode, owner, nil)
  end

  def reserve_append_direct(_path, _kind, _mode, _owner), do: {:error, :invalid_destination}

  @doc false
  @spec reserve_append_direct(
          binary(),
          :trace,
          non_neg_integer(),
          pid(),
          nil | (atom() -> term())
        ) ::
          {:ok, t()} | {:error, atom()}
  def reserve_append_direct(path, :trace, mode, owner, fault_hook)
      when is_binary(path) and is_integer(mode) and mode >= 0 and is_pid(owner) and
             (is_nil(fault_hook) or is_function(fault_hook, 1)) do
    with :ok <- valid_path(path),
         {:ok, path} <- PrivateDirectory.anchor(path),
         :ok <- preflight_append(path, mode),
         {:ok, parent, parent_identity} <- parent_identity(path) do
      case File.lstat(path) do
        {:error, :enoent} ->
          reserve_staged(path, :trace, mode, parent, parent_identity, owner, true)

        {:ok, %File.Stat{type: :regular}} ->
          reserve_append_file(path, :trace, mode, parent, parent_identity, owner, fault_hook)

        {:ok, _stat} ->
          {:error, :invalid_destination}

        {:error, _reason} ->
          {:error, :destination_unavailable}
      end
    else
      {:error, _reason} = error -> normalize_error(error)
    end
  rescue
    _exception -> {:error, :destination_unavailable}
  end

  def reserve_append_direct(_path, _kind, _mode, _owner, _fault_hook),
    do: {:error, :invalid_destination}

  @doc false
  @spec reserve_append_for(binary(), kind(), non_neg_integer(), pid()) ::
          {:ok, t()} | {:error, atom()}
  def reserve_append_for(path, kind, mode, controller)
      when is_binary(path) and kind == :trace and is_integer(mode) and mode >= 0 and
             is_pid(controller) do
    with {:ok, owner} <- PublicationHandleOwner.start(controller) do
      PublicationHandleOwner.reserve_append(owner, path, kind, mode)
    end
  end

  def reserve_append_for(_path, _kind, _mode, _controller), do: {:error, :invalid_destination}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = handle) do
    handle.kind in [:trace, :inspection, :result, :recovery] and
      valid_path(handle.path) == :ok and
      is_binary(handle.parent) and
      valid_identity?(handle.parent_identity) and
      valid_identity?(handle.file_identity) and
      valid_path(handle.reservation_path) == :ok and
      valid_identity?(handle.reservation_identity) and
      is_integer(handle.mode) and handle.mode >= 0 and
      is_binary(handle.staging_path) and is_boolean(handle.visible?) and
      is_boolean(handle.append?) and
      valid_content_attestation?(handle.expected_size, handle.expected_digest) and
      is_pid(handle.owner)
  end

  def valid?(_handle), do: false

  @spec identity(t()) :: identity()
  def identity(%__MODULE__{file_identity: identity}), do: identity

  @spec path(t()) :: binary()
  def path(%__MODULE__{path: path}), do: path

  @spec write(t(), iodata()) :: :ok | {:error, atom()}
  def write(%__MODULE__{} = handle, bytes), do: call_owner(handle, {:write, bytes})

  @doc false
  @spec write_if_unchanged(t(), binary(), iodata()) :: :ok | {:error, atom()}
  def write_if_unchanged(%__MODULE__{} = handle, expected_source, bytes)
      when is_binary(expected_source),
      do: call_owner(handle, {:write_if_unchanged, expected_source, bytes})

  @doc false
  @spec read(t(), pos_integer()) :: {:ok, binary()} | {:error, atom()}
  def read(%__MODULE__{} = handle, max_bytes) when is_integer(max_bytes) and max_bytes > 0,
    do: call_owner(handle, {:read, max_bytes})

  def read(_handle, _max_bytes), do: {:error, :invalid_destination}

  @doc false
  @spec append?(t()) :: boolean()
  def append?(%__MODULE__{append?: append?}), do: append?

  @doc false
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{visible?: visible?}), do: visible?

  @doc false
  def owner_execute(%__MODULE__{owner: owner} = handle, operation) when owner == self(),
    do: direct_execute(handle, operation)

  def owner_execute(_handle, _operation), do: {:error, :publication_collision}

  defp direct_execute(handle, {:write, bytes}), do: direct_write(handle, bytes)

  defp direct_execute(handle, {:write_if_unchanged, expected_source, bytes}),
    do: direct_write_if_unchanged(handle, expected_source, bytes)

  defp direct_execute(handle, {:read, max_bytes}), do: direct_read(handle, max_bytes)
  defp direct_execute(handle, :sync), do: direct_sync(handle)
  defp direct_execute(handle, :sync_and_retain), do: direct_sync_and_retain(handle)

  defp direct_execute(handle, {:sync_and_retain, fault_hook}),
    do: direct_sync_and_retain(handle, fault_hook)

  defp direct_execute(handle, :release), do: direct_release(handle)
  defp direct_execute(handle, :verify), do: direct_verify(handle)
  defp direct_execute(handle, :publish), do: direct_publish(handle)
  defp direct_execute(handle, :remove), do: direct_remove(handle)

  defp direct_execute(handle, {:link_recovery_to, recovery_handle, requested_path}),
    do: direct_link_recovery_to(handle, recovery_handle, requested_path)

  defp direct_execute(handle, {:link_to_verified, requested_path}),
    do: direct_link_to_verified(handle, requested_path)

  defp direct_execute(handle, :unlink), do: direct_unlink(handle)
  defp direct_execute(handle, :verify_recovery), do: direct_verify(handle)

  defp direct_execute(handle, :close) do
    _ = direct_close(handle)
    :close
  end

  # Releases the device without touching the filesystem. Staging and
  # reservation names are reused by later handles for the same destination, so
  # a handle whose removal already succeeded must never identity-check and
  # remove those names a second time.
  defp direct_execute(handle, :close_device) do
    _ = :file.close(handle.device)
    :close
  end

  defp direct_write(%__MODULE__{} = handle, bytes) do
    with {:ok, bytes} <- binary_iodata(bytes),
         :ok <- direct_verify(handle),
         true <- not recovery_already_written?(handle),
         {:ok, _position} <-
           :file.position(handle.device, if(handle.append?, do: :eof, else: :bof)),
         :ok <- truncate_recovery(handle),
         :ok <- :file.write(handle.device, bytes) do
      write_result(handle, bytes)
    else
      false -> {:error, :publication_collision}
      {:error, :publication_collision} = error -> error
      _other -> {:error, :publication_failed}
    end
  rescue
    _exception -> {:error, :publication_failed}
  end

  defp direct_write_if_unchanged(
         %__MODULE__{append?: true} = handle,
         expected_source,
         bytes
       )
       when is_binary(expected_source) do
    with {:ok, bytes} <- binary_iodata(bytes),
         :ok <- direct_verify(handle),
         :ok <- source_matches_device(handle, expected_source),
         {:ok, _position} <- :file.position(handle.device, :eof),
         :ok <- :file.write(handle.device, bytes) do
      :ok
    else
      {:error, :publication_collision} = error -> error
      {:error, :source_changed} = error -> error
      _other -> {:error, :publication_failed}
    end
  rescue
    _exception -> {:error, :publication_failed}
  end

  defp direct_write_if_unchanged(_handle, _expected_source, _bytes),
    do: {:error, :invalid_destination}

  defp write_result(%__MODULE__{kind: :recovery} = handle, bytes) do
    {:updated,
     %{
       handle
       | expected_size: byte_size(bytes),
         expected_digest: :crypto.hash(:sha256, bytes)
     }}
  end

  defp write_result(_handle, _bytes), do: :ok

  defp binary_iodata(bytes) do
    {:ok, IO.iodata_to_binary(bytes)}
  rescue
    _exception -> {:error, :publication_failed}
  end

  defp recovery_already_written?(%__MODULE__{kind: :recovery, expected_size: size}),
    do: size != 0

  defp recovery_already_written?(_handle), do: false

  defp truncate_recovery(%__MODULE__{kind: :recovery, device: device}),
    do: :file.truncate(device)

  defp truncate_recovery(_handle), do: :ok

  defp direct_read(%__MODULE__{visible?: false} = handle, _max_bytes) do
    with :ok <- direct_verify(handle), do: {:ok, ""}
  end

  defp direct_read(%__MODULE__{} = handle, max_bytes) do
    with :ok <- direct_verify(handle),
         {:ok, 0} <- :file.position(handle.device, :bof),
         result <- :file.read(handle.device, max_bytes + 1),
         {:ok, source} <- bounded_read(result, max_bytes),
         :ok <- direct_verify(handle) do
      {:ok, source}
    else
      {:error, :publication_collision} = error -> error
      {:error, :source_limit_exceeded} = error -> error
      _other -> {:error, :source_unavailable}
    end
  rescue
    _exception -> {:error, :source_unavailable}
  end

  defp bounded_read(:eof, _max_bytes), do: {:ok, ""}

  defp bounded_read({:ok, source}, max_bytes) when byte_size(source) <= max_bytes,
    do: {:ok, source}

  defp bounded_read(_result, _max_bytes), do: {:error, :source_limit_exceeded}

  defp source_matches_device(handle, expected_source) do
    with {:ok, size} <- device_size(handle.device),
         true <- size == byte_size(expected_source),
         {:ok, 0} <- :file.position(handle.device, :bof),
         {:ok, current_source} <- read_exact(handle.device, size),
         true <- current_source == expected_source,
         :ok <- direct_verify(handle),
         {:ok, final_size} <- device_size(handle.device),
         true <- final_size == byte_size(expected_source) do
      :ok
    else
      false -> {:error, :source_changed}
      _other -> {:error, :source_changed}
    end
  end

  defp read_exact(_device, 0), do: {:ok, ""}

  defp read_exact(device, size) when is_integer(size) and size > 0 do
    case :file.read(device, size) do
      {:ok, source} when byte_size(source) == size -> {:ok, source}
      _other -> {:error, :source_changed}
    end
  end

  defp device_size(device) do
    case :file.read_file_info(device, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info).size}
      _other -> {:error, :source_changed}
    end
  end

  @spec sync(t()) :: :ok | {:error, atom()}
  def sync(%__MODULE__{kind: :recovery}), do: {:error, :invalid_destination}
  def sync(%__MODULE__{} = handle), do: call_owner(handle, :sync)

  @doc false
  @spec sync_and_retain(t()) :: :ok | {:error, atom()}
  def sync_and_retain(%__MODULE__{kind: :recovery} = handle),
    do: call_owner(handle, :sync_and_retain)

  def sync_and_retain(_handle), do: {:error, :invalid_destination}

  @doc false
  @spec sync_and_retain(t(), nil | (atom() -> term())) :: :ok | {:error, atom()}
  def sync_and_retain(%__MODULE__{kind: :recovery} = handle, fault_hook)
      when is_nil(fault_hook) or is_function(fault_hook, 1),
      do: call_owner(handle, {:sync_and_retain, fault_hook})

  def sync_and_retain(_handle, _fault_hook), do: {:error, :invalid_destination}

  defp direct_sync(%__MODULE__{} = handle) do
    direct_sync(handle, false, nil)
  end

  defp direct_sync_and_retain(%__MODULE__{} = handle) do
    direct_sync(handle, true, nil)
  end

  defp direct_sync_and_retain(%__MODULE__{} = handle, fault_hook) do
    direct_sync(handle, true, fault_hook)
  end

  defp direct_sync(%__MODULE__{} = handle, retain_on_directory_failure?, fault_hook) do
    with :ok <- direct_verify(handle),
         :ok <- sync_device(handle.device),
         :ok <- direct_verify(handle),
         result <- sync_directory_if_required(handle, fault_hook),
         :ok <- maybe_retain_directory_failure(result, retain_on_directory_failure?),
         :ok <- direct_verify(handle) do
      :ok
    else
      {:preserve, {:error, _reason} = error} -> {:preserve, error}
      {:error, :publication_collision} = error -> error
      {:error, :file_sync_failed} = error -> error
      {:error, :directory_sync_failed} = error -> error
      _other -> {:error, :publication_failed}
    end
  rescue
    _exception -> {:error, :publication_failed}
  end

  defp maybe_retain_directory_failure(:ok, _retain?), do: :ok

  defp maybe_retain_directory_failure(
         {:error, :directory_sync_failed} = error,
         true
       ),
       do: {:preserve, error}

  defp maybe_retain_directory_failure(result, _retain?), do: result

  defp sync_directory_if_required(%__MODULE__{append?: true, visible?: true}, _fault_hook),
    do: :ok

  defp sync_directory_if_required(%__MODULE__{parent: parent}, fault_hook),
    do: sync_directory(parent, fault_hook)

  @spec verify(t()) :: :ok | {:error, atom()}
  def verify(%__MODULE__{} = handle), do: call_owner(handle, :verify)

  defp direct_verify(%__MODULE__{} = handle) do
    with {:ok, parent} <- File.stat(handle.parent, time: :posix),
         :ok <- same_identity(parent, handle.parent_identity),
         {:ok, reservation} <- File.lstat(handle.reservation_path, time: :posix),
         true <- reservation.type == :directory,
         :ok <- same_identity(reservation, handle.reservation_identity),
         {:ok, current} <- File.lstat(handle.staging_path, time: :posix),
         :ok <- same_identity(current, handle.file_identity),
         {:ok, opened} <- device_identity(handle.device),
         true <- opened == handle.file_identity,
         :ok <- target_state(handle),
         :ok <- verify_attested_contents(handle) do
      :ok
    else
      _other -> {:error, :publication_collision}
    end
  rescue
    _exception -> {:error, :publication_collision}
  end

  defp verify_attested_contents(%__MODULE__{
         kind: :recovery,
         expected_size: expected_size,
         expected_digest: expected_digest,
         device: device
       })
       when is_integer(expected_size) and expected_size >= 0 and is_binary(expected_digest) do
    with {:ok, size} <- device_size(device),
         true <- size == expected_size,
         {:ok, 0} <- :file.position(device, :bof),
         {:ok, contents} <- read_exact(device, expected_size),
         true <- :crypto.hash(:sha256, contents) == expected_digest do
      :ok
    else
      _other -> {:error, :publication_collision}
    end
  end

  defp verify_attested_contents(_handle), do: :ok

  @spec publish(t()) :: :ok | {:error, atom()}
  def publish(%__MODULE__{} = handle), do: call_owner(handle, :publish)

  defp direct_publish(%__MODULE__{visible?: true} = handle), do: direct_verify(handle)

  defp direct_publish(%__MODULE__{} = handle) do
    with :ok <- direct_verify(handle),
         {:error, :enoent} <- File.lstat(handle.path),
         :ok <- File.ln(handle.staging_path, handle.path) do
      complete_link(handle, handle.path)
    else
      {:ok, _stat} -> {:error, :publication_collision}
      {:error, :eexist} -> {:error, :publication_collision}
      {:error, :publication_collision} = error -> error
      _other -> {:error, :publication_failed}
    end
  rescue
    _exception -> {:error, :publication_failed}
  end

  @spec remove(t()) :: :ok | {:error, atom()}
  def remove(%__MODULE__{} = handle), do: call_owner(handle, :remove)

  defp direct_remove(%__MODULE__{append?: true, visible?: true} = handle),
    do: direct_release(handle)

  defp direct_remove(%__MODULE__{} = handle) do
    case File.lstat(handle.staging_path) do
      {:error, :enoent} ->
        remove_reservation(handle)

      {:ok, _stat} ->
        with :ok <- direct_verify(handle),
             :ok <- File.rm(handle.staging_path),
             :ok <- remove_staging_directory(handle),
             :ok <- sync_directory(handle.parent),
             :ok <- remove_reservation(handle) do
          :ok
        else
          _other -> {:error, :publication_cleanup_failed}
        end

      _other ->
        {:error, :publication_cleanup_failed}
    end
  rescue
    _exception -> {:error, :publication_cleanup_failed}
  end

  @spec link_to(t(), binary(), t()) :: :ok | {:error, atom()}
  def link_to(
        %__MODULE__{} = handle,
        requested_path,
        %__MODULE__{} = requested_handle
      )
      when is_binary(requested_path),
      do: link_requested_owner(requested_handle.owner, handle, requested_path)

  defp direct_link_recovery_to(
         %__MODULE__{kind: :result} = requested_handle,
         %__MODULE__{kind: :recovery, owner: recovery_owner} = recovery_handle,
         requested_path
       )
       when is_binary(requested_path) do
    with {:ok, requested_path} <- PrivateDirectory.anchor(requested_path),
         true <- requested_handle.path == requested_path,
         true <- valid?(recovery_handle),
         :ok <- direct_verify(requested_handle),
         :ok <- link_recovery_owner(recovery_owner, requested_path) do
      :ok
    else
      false -> {:error, :publication_collision}
      {:error, _reason} = error -> error
      _other -> {:error, :publication_collision}
    end
  end

  defp direct_link_recovery_to(_requested_handle, _recovery_handle, _requested_path),
    do: {:error, :publication_collision}

  defp direct_link_to_verified(
         %__MODULE__{} = handle,
         requested_path
       )
       when is_binary(requested_path) do
    with :ok <- direct_verify(handle),
         {:ok, requested_path} <- PrivateDirectory.anchor(requested_path),
         :ok <- same_parent(handle, requested_path),
         {:error, :enoent} <- File.lstat(requested_path),
         :ok <- File.ln(handle.staging_path, requested_path) do
      complete_link(handle, requested_path)
    else
      {:ok, _stat} -> {:error, :publication_collision}
      {:error, :eexist} -> {:error, :publication_collision}
      {:error, :publication_collision} = error -> error
      _other -> {:error, :publication_failed}
    end
  rescue
    _exception -> {:error, :publication_failed}
  end

  defp link_recovery_owner(recovery_owner, requested_path) do
    PublicationHandleOwner.call(recovery_owner, {:link_to_verified, requested_path})
  catch
    :exit, _reason -> {:error, :publication_collision}
  end

  defp link_requested_owner(requested_owner, recovery_handle, requested_path) do
    PublicationHandleOwner.call(
      requested_owner,
      {:link_recovery_to, recovery_handle, requested_path}
    )
  catch
    :exit, _reason -> {:error, :requested_reservation_lost}
  end

  @spec unlink(t()) :: :ok | {:error, atom()}
  def unlink(%__MODULE__{} = handle), do: call_owner(handle, :unlink)

  @doc false
  @spec discard(t()) :: :ok | {:error, atom()}
  def discard(%__MODULE__{} = handle), do: call_owner(handle, :discard)

  @doc false
  @spec release(t()) :: :ok | {:error, atom()}
  def release(%__MODULE__{} = handle), do: call_owner(handle, :release)

  defp direct_unlink(%__MODULE__{append?: true, visible?: true} = handle),
    do: direct_release(handle)

  defp direct_unlink(%__MODULE__{visible?: true} = handle) do
    with :ok <- direct_verify(handle),
         :ok <- File.rm(handle.path),
         :ok <- sync_directory(handle.parent),
         :ok <- remove_reservation(handle) do
      :ok
    else
      {:error, :enoent} -> {:error, :publication_collision}
      _other -> {:error, :publication_failed}
    end
  rescue
    _exception -> {:error, :publication_failed}
  end

  defp direct_unlink(%__MODULE__{} = handle), do: direct_remove(handle)

  defp rollback_link(handle, path) do
    with {:ok, stat} <- File.lstat(path, time: :posix),
         :ok <- same_identity(stat, handle.file_identity),
         :ok <- File.rm(path),
         :ok <- sync_directory(handle.parent),
         :ok <- direct_verify(handle) do
      {:error, :publication_rollback_recovered}
    else
      _other -> {:error, :publication_finalization_uncertain}
    end
  end

  defp complete_link(handle, path) do
    case File.lstat(path, time: :posix) do
      {:ok, linked} ->
        case same_identity(linked, handle.file_identity) do
          :ok ->
            complete_verified_link(handle, path)

          _mismatch ->
            rollback_link(handle, path)
        end

      _unavailable ->
        rollback_link(handle, path)
    end
  end

  defp complete_verified_link(handle, path) do
    case sync_directory(handle.parent) do
      :ok ->
        unless handle.visible? do
          # The destination link and its first directory sync are the durable
          # publication boundary. Cleanup of the private staging name is
          # identity-checked and best effort; it must not report a committed
          # destination as failed.
          _ = cleanup_staging(handle)
        end

        :ok

      _error ->
        rollback_link(handle, path)
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{} = handle), do: call_owner(handle, :close)

  defp direct_close(%__MODULE__{device: device} = handle) do
    _ = :file.close(device)
    _ = cleanup_staging(handle)
    _ = remove_reservation(handle)
    :ok
  rescue
    _exception -> :ok
  end

  defp direct_release(%__MODULE__{device: device} = handle) do
    _ = :file.close(device)

    with :ok <- cleanup_staging(handle),
         :ok <- remove_reservation(handle) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :publication_cleanup_failed}
  end

  @spec parent(t()) :: binary()
  def parent(%__MODULE__{parent: parent}), do: parent

  @spec same_parent?(t(), binary()) :: boolean()
  def same_parent?(%__MODULE__{} = handle, path) when is_binary(path),
    do: same_parent(handle, path) == :ok

  def same_parent?(_handle, _path), do: false

  @doc false
  @spec recovery_reachable?(t()) :: boolean()
  def recovery_reachable?(%__MODULE__{} = handle),
    do: call_owner(handle, :verify_recovery) == :ok

  def recovery_reachable?(_handle), do: false

  defp reserve_staged(path, kind, mode, parent, parent_identity, owner, append? \\ false) do
    reservation =
      if append? do
        fn fun -> with_append_reservation(path, fun) end
      else
        fn fun -> with_reservation(path, parent_identity, fun) end
      end

    reservation.(fn reservation_path, reservation_identity ->
      {staging_directory, staging_path} = PrivateDirectory.temporary_sibling(path, "artifact")

      with :ok <- ensure_target_absent(path),
           :ok <- PrivateDirectory.create(staging_directory),
           {:ok, device} <- open_exclusive(staging_path) do
        case staged_handle(
               path,
               kind,
               mode,
               {parent, parent_identity},
               {reservation_path, reservation_identity},
               {staging_directory, staging_path, device},
               owner,
               append?
             ) do
          {:ok, _handle} = success ->
            success

          {:error, _reason} = error ->
            cleanup_open_staging(device, staging_directory, staging_path)
            error
        end
      else
        {:error, reason} ->
          _ = remove_directory_if_empty(staging_directory)
          {:error, reason}
      end
    end)
  end

  defp staged_handle(
         path,
         kind,
         mode,
         {parent, parent_identity},
         {reservation_path, reservation_identity},
         {staging_directory, staging_path, device},
         owner,
         append?
       ) do
    with {:ok, file_identity} <- device_identity(device),
         :ok <- ensure_path_identity(staging_path, file_identity),
         :ok <- restrict(staging_path, mode),
         :ok <- ensure_path_identity(staging_path, file_identity),
         {:error, :enoent} <- File.lstat(path) do
      {:ok,
       %__MODULE__{
         kind: kind,
         path: path,
         parent: parent,
         parent_identity: parent_identity,
         file_identity: file_identity,
         reservation_path: reservation_path,
         reservation_identity: reservation_identity,
         device: device,
         mode: mode,
         staging_directory: staging_directory,
         staging_path: staging_path,
         visible?: false,
         append?: append?,
         expected_size: nil,
         expected_digest: nil,
         owner: owner
       }}
    else
      {:ok, _stat} -> {:error, :destination_exists}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :destination_unavailable}
    end
  end

  defp reserve_visible_file(path, kind, mode, parent, parent_identity, owner) do
    with_reservation(path, parent_identity, fn reservation_path, reservation_identity ->
      case open_exclusive(path) do
        {:ok, device} ->
          case visible_handle(
                 path,
                 kind,
                 mode,
                 parent,
                 parent_identity,
                 {reservation_path, reservation_identity},
                 device,
                 owner
               ) do
            {:ok, _handle} = success ->
              success

            {:error, _reason} = error ->
              cleanup_open_visible(device, path)
              error
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp visible_handle(
         path,
         kind,
         mode,
         parent,
         parent_identity,
         {reservation_path, reservation_identity},
         device,
         owner
       ) do
    with {:ok, file_identity} <- device_identity(device),
         :ok <- ensure_path_identity(path, file_identity),
         :ok <- restrict(path, mode),
         :ok <- ensure_path_identity(path, file_identity) do
      {:ok,
       %__MODULE__{
         kind: kind,
         path: path,
         parent: parent,
         parent_identity: parent_identity,
         file_identity: file_identity,
         reservation_path: reservation_path,
         reservation_identity: reservation_identity,
         device: device,
         mode: mode,
         staging_directory: nil,
         staging_path: path,
         visible?: true,
         append?: false,
         expected_size: recovery_expected_size(kind),
         expected_digest: recovery_expected_digest(kind),
         owner: owner
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :destination_unavailable}
    end
  end

  defp reserve_append_file(path, kind, mode, parent, parent_identity, owner, fault_hook) do
    with_append_reservation(path, fn reservation_path, reservation_identity ->
      case open_append(path) do
        {:ok, device} ->
          reserve_open_append(
            device,
            {path, kind, mode},
            {parent, parent_identity},
            {reservation_path, reservation_identity},
            owner,
            fault_hook
          )

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp reserve_open_append(
         device,
         {path, kind, mode},
         {parent, parent_identity},
         {reservation_path, reservation_identity},
         owner,
         fault_hook
       ) do
    case append_initialization_fault(fault_hook) do
      :ok ->
        append_handle(
          path,
          kind,
          mode,
          parent,
          parent_identity,
          {reservation_path, reservation_identity},
          device,
          owner
        )
        |> keep_or_close_open_append(device)

      {:error, _reason} = error ->
        close_open_append(device, error)
    end
  end

  defp keep_or_close_open_append({:ok, _handle} = success, _device), do: success

  defp keep_or_close_open_append({:error, _reason} = error, device),
    do: close_open_append(device, error)

  defp close_open_append(device, error) do
    close_open_visible(device)
    error
  end

  defp append_initialization_fault(nil), do: :ok

  defp append_initialization_fault(fault_hook) do
    case fault_hook.(:after_open) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :destination_unavailable}
    end
  end

  defp append_handle(
         path,
         kind,
         mode,
         parent,
         parent_identity,
         {reservation_path, reservation_identity},
         device,
         owner
       ) do
    with {:ok, file_identity} <- device_identity(device),
         :ok <- ensure_path_identity(path, file_identity),
         :ok <- restrict(path, mode),
         :ok <- ensure_path_identity(path, file_identity) do
      {:ok,
       %__MODULE__{
         kind: kind,
         path: path,
         parent: parent,
         parent_identity: parent_identity,
         file_identity: file_identity,
         reservation_path: reservation_path,
         reservation_identity: reservation_identity,
         device: device,
         mode: mode,
         staging_directory: nil,
         staging_path: path,
         visible?: true,
         append?: true,
         expected_size: nil,
         expected_digest: nil,
         owner: owner
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :destination_unavailable}
    end
  end

  defp cleanup_open_staging(device, directory, path) do
    cleanup_open_file(device, path)
    _ = remove_directory_if_empty(directory)
    :ok
  end

  defp cleanup_open_visible(device, path), do: cleanup_open_file(device, path)

  defp close_open_visible(device) do
    _ = :file.close(device)
    :ok
  end

  defp with_reservation(path, parent_identity, fun) do
    with_reservation_path(reservation_path(path, parent_identity), Path.dirname(path), fun)
  end

  defp with_append_reservation(path, fun) do
    case TraceLog.append_reservation_path(path) do
      {:ok, reservation_path} ->
        with_reservation_path(reservation_path, Path.dirname(reservation_path), fun)

      {:error, _reason} = error ->
        error
    end
  end

  defp with_reservation_path(reservation_path, sync_parent, fun) do
    case create_reservation(reservation_path) do
      {:ok, reservation_path, reservation_identity} ->
        case fun.(reservation_path, reservation_identity) do
          {:ok, _handle} = success ->
            success

          {:error, _reason} = error ->
            _ = cleanup_open_reservation(reservation_path, reservation_identity, sync_parent)

            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp create_reservation(reservation_path) do
    case PrivateDirectory.create(reservation_path) do
      :ok ->
        with {:ok, stat} <- File.lstat(reservation_path, time: :posix),
             true <- stat.type == :directory,
             {:ok, identity} <- stat_identity(stat) do
          {:ok, reservation_path, identity}
        else
          _other ->
            _ = File.rmdir(reservation_path)
            {:error, :destination_unavailable}
        end

      {:error, _reason} ->
        case File.lstat(reservation_path) do
          {:ok, _stat} -> {:error, :destination_exists}
          _other -> {:error, :destination_unavailable}
        end
    end
  end

  defp preflight_append(path, mode) when mode in [0, 0o600] do
    case File.lstat(path) do
      {:error, :enoent} ->
        PrivateDirectory.preflight(path)

      {:ok, %File.Stat{type: :regular}} when mode == 0 ->
        PrivateDirectory.preflight_writable_file(path)

      {:ok, %File.Stat{type: :regular, uid: owner, mode: file_mode}} ->
        with {:ok, uid} <- PrivateDirectory.preflight_owner(path),
             true <- owner in [0, uid] and Bitwise.band(file_mode, 0o777) == 0o600,
             :ok <- PrivateDirectory.preflight_writable_file(path) do
          :ok
        else
          false -> {:error, :destination_unavailable}
          {:error, _reason} -> {:error, :destination_unavailable}
        end

      {:ok, _stat} ->
        {:error, :invalid_destination}

      {:error, _reason} ->
        {:error, :destination_unavailable}
    end
  end

  defp preflight_append(path, _mode), do: PrivateDirectory.preflight(path)

  defp open_append(path),
    do: :file.open(String.to_charlist(path), [:read, :append, :binary, :raw])

  defp reservation_path(path, parent_identity) do
    digest_key = {parent_identity, PrivateDirectory.casefold_name(Path.basename(path))}

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(digest_key, [:deterministic]))
      |> Base.encode16(case: :lower)

    Path.join(Path.dirname(path), ".#{digest}.ptc-reservation")
  end

  defp ensure_target_absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :destination_exists}
      _other -> {:error, :destination_unavailable}
    end
  end

  defp cleanup_open_reservation(path, identity, parent) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory} = stat} ->
        case same_identity(stat, identity) do
          :ok -> _ = File.rmdir(path)
          _other -> :ok
        end

      _other ->
        :ok
    end

    _ = sync_directory(parent)
    :ok
  end

  defp cleanup_open_file(device, path) do
    identity = device_identity(device)
    _ = :file.close(device)

    case {identity, File.lstat(path, time: :posix)} do
      {{:ok, expected}, {:ok, current}} ->
        if same_identity(current, expected) == :ok, do: _ = File.rm(path)

      _other ->
        :ok
    end

    :ok
  end

  defp remove_directory_if_empty(directory) do
    case File.rmdir(directory) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :publication_cleanup_failed}
    end
  end

  defp open_exclusive(path) do
    case :file.open(String.to_charlist(path), [:read, :write, :binary, :raw, :exclusive]) do
      {:ok, device} -> {:ok, device}
      {:error, :eexist} -> {:error, :destination_exists}
      {:error, _reason} -> {:error, :destination_unavailable}
    end
  end

  # Decided before the private-directory preflight, which answers for a missing
  # parent with the same reason it uses for every unusable one. `--trace-dir`
  # already reports this condition by name; this is what lets `--output`,
  # `--private-output`, and `--inspect` do the same.
  defp parent_present(path) do
    case File.stat(Path.dirname(path), time: :posix) do
      {:error, :enoent} -> {:error, :destination_directory_missing}
      _other -> :ok
    end
  end

  defp parent_identity(path) do
    parent = Path.dirname(path)

    case File.stat(parent, time: :posix) do
      {:ok, %{type: :directory} = stat} ->
        case stat_identity(stat) do
          {:ok, identity} -> {:ok, parent, identity}
          :error -> {:error, :destination_unavailable}
        end

      # An absent parent directory is the ordinary operator mistake here, and
      # the only one with an obvious remedy, so it keeps its own reason rather
      # than joining every other way a destination can be unusable.
      {:error, :enoent} ->
        {:error, :destination_directory_missing}

      _other ->
        {:error, :destination_unavailable}
    end
  end

  defp device_identity(device) do
    case :file.read_file_info(device, time: :posix) do
      {:ok, info} -> stat_identity(File.Stat.from_record(info))
      _other -> {:error, :destination_unavailable}
    end
  end

  defp stat_identity(%{major_device: major, minor_device: minor, inode: inode})
       when is_integer(major) and is_integer(minor) and is_integer(inode),
       do: {:ok, {major, minor, inode}}

  defp stat_identity(_stat), do: :error

  defp ensure_path_identity(path, expected) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular} = stat} -> same_identity(stat, expected)
      _other -> {:error, :publication_collision}
    end
  end

  defp same_identity(
         %{major_device: major, minor_device: minor, inode: inode},
         {major, minor, inode}
       ),
       do: :ok

  defp same_identity(_stat, _identity), do: {:error, :publication_collision}

  defp valid_identity?({major, minor, inode}),
    do: Enum.all?([major, minor, inode], &is_integer/1)

  defp valid_identity?(_identity), do: false

  defp valid_content_attestation?(nil, nil), do: true

  defp valid_content_attestation?(size, digest)
       when is_integer(size) and size >= 0 and is_binary(digest),
       do: byte_size(digest) == 32

  defp valid_content_attestation?(_size, _digest), do: false

  defp recovery_expected_size(:recovery), do: 0
  defp recovery_expected_size(_kind), do: nil

  defp recovery_expected_digest(:recovery), do: :crypto.hash(:sha256, "")
  defp recovery_expected_digest(_kind), do: nil

  defp valid_path(path) do
    cond do
      not String.valid?(path) -> {:error, :invalid_destination}
      path == "" or String.contains?(path, <<0>>) -> {:error, :invalid_destination}
      Path.type(path) != :absolute -> {:error, :invalid_destination}
      true -> :ok
    end
  end

  defp restrict(path, mode) do
    if mode == 0 do
      :ok
    else
      case File.chmod(path, mode) do
        :ok -> :ok
        {:error, _reason} -> {:error, :destination_unavailable}
      end
    end
  end

  defp same_parent(handle, requested_path) do
    case parent_identity(requested_path) do
      {:ok, parent, identity}
      when parent == handle.parent and identity == handle.parent_identity ->
        :ok

      _other ->
        {:error, :publication_collision}
    end
  end

  defp target_state(%__MODULE__{visible?: true}), do: :ok

  defp target_state(%__MODULE__{visible?: false, path: path}) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _other -> {:error, :publication_collision}
    end
  end

  defp remove_staging_directory(%__MODULE__{staging_directory: nil}), do: :ok

  defp remove_staging_directory(%__MODULE__{staging_directory: directory}) do
    case File.rmdir(directory) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :publication_cleanup_failed}
    end
  end

  defp remove_reservation(%__MODULE__{} = handle) do
    case File.lstat(handle.reservation_path, time: :posix) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory} = stat} ->
        with :ok <- same_identity(stat, handle.reservation_identity),
             :ok <- File.rmdir(handle.reservation_path),
             :ok <- sync_directory(Path.dirname(handle.reservation_path)) do
          :ok
        else
          _other -> {:error, :publication_cleanup_failed}
        end

      _other ->
        {:error, :publication_cleanup_failed}
    end
  rescue
    _exception -> {:error, :publication_cleanup_failed}
  end

  defp cleanup_staging(%__MODULE__{visible?: true}), do: :ok

  defp cleanup_staging(%__MODULE__{} = handle) do
    with {:ok, parent} <- File.stat(handle.parent, time: :posix),
         :ok <- same_identity(parent, handle.parent_identity),
         {:ok, current} <- File.lstat(handle.staging_path, time: :posix),
         :ok <- same_identity(current, handle.file_identity),
         :ok <- File.rm(handle.staging_path),
         :ok <- remove_staging_directory(handle),
         :ok <- sync_directory(handle.parent) do
      :ok
    else
      {:error, :enoent} -> :ok
      _other -> {:error, :publication_cleanup_failed}
    end
  rescue
    _exception -> {:error, :publication_cleanup_failed}
  end

  defp call_owner(%__MODULE__{owner: owner}, operation) do
    PublicationHandleOwner.call(owner, operation)
  catch
    :exit, _reason ->
      case operation do
        :close -> :ok
        :remove -> {:error, :publication_cleanup_failed}
        :unlink -> {:error, :publication_cleanup_failed}
        _other -> {:error, :publication_failed}
      end
  end

  defp sync_device(device) do
    case :file.sync(device) do
      :ok -> :ok
      _other -> {:error, :file_sync_failed}
    end
  end

  defp sync_directory(directory), do: sync_directory(directory, nil)

  defp sync_directory(directory, fault_hook) when is_function(fault_hook, 1) do
    case fault_hook.(:directory_sync) do
      :ok -> sync_directory(directory, nil)
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :directory_sync_failed}
    end
  rescue
    _exception -> {:error, :directory_sync_failed}
  end

  defp sync_directory(directory, nil) do
    case :file.open(String.to_charlist(directory), [:directory, :read, :raw]) do
      {:ok, device} ->
        try do
          case :file.sync(device) do
            :ok -> :ok
            _other -> {:error, :directory_sync_failed}
          end
        after
          :file.close(device)
        end

      _other ->
        {:error, :directory_sync_failed}
    end
  end

  defp normalize_error({:error, :destination_exists}), do: {:error, :destination_exists}
  defp normalize_error({:error, :invalid_destination}), do: {:error, :invalid_destination}
  defp normalize_error({:error, reason}) when is_atom(reason), do: {:error, reason}
end
