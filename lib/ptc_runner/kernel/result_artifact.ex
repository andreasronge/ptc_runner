defmodule PtcRunner.Kernel.ResultArtifact do
  @moduledoc """
  Persists one run result as a standalone JSON artifact.

  A multi-run application passes values between ordinary runs. Scraping them
  from stdout is not good enough: terminal output interleaves with logs, has no
  atomicity, and cannot express that a value must never be published. This
  writer gives a run one explicit destination instead. Its read-only preflight
  validates deterministic destination conflicts before provider acquisition
  or run execution; exclusive publication remains authoritative against races.

  Persistence is atomic and refuses to clobber. Content is deterministic
  canonical JSON: the SHA-256 digest of the exact artifact bytes is therefore a
  stable identity for the successful value. Content is written to an exclusive
  file inside a mode-0700 temporary sibling directory, linked into place, and
  the temporary directory is then cleaned up best-effort, so a reader never
  observes a partial artifact and an existing destination fails rather than
  being overwritten. Once the link succeeds, cleanup cannot turn the committed
  publication into a reported failure. A relative destination is anchored once
  before validation so a VM-wide working-directory change cannot redirect later
  filesystem operations. A private artifact is restricted to `0600` before any
  content is written, never after.

  Secure publication is supported on Unix hosts with POSIX-compatible `mkdir`
  and `id` executables available on `PATH`; persistence fails closed when those
  authority/mode primitives are unavailable, a physical or lexical ancestor
  has an untrusted owner, or any ancestor is group/other-writable without
  sticky-directory protection. Preflight also rejects a final parent whose
  effective permission class lacks create access.

  The private/normal distinction is authority, not formatting. A private result
  may only reach a private destination; the caller decides the class and this
  module refuses to write a private value to a normal artifact.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationHandle

  @type class :: :normal | :private

  @type error ::
          :result_destination_exists
          | :result_persistence_failed
          | :result_destination_unsafe
          | :file_sync_failed
          | :directory_sync_failed
          | :publication_collision
          | {:result_not_json_encodable, atom()}
          | :invalid_result_destination
          | :private_result_requires_private_destination
          | {:recovery_written, term()}
          | {:finalization_uncertain, term()}

  @doc """
  Writes `value` to `path` as JSON.

  `class` is the effective class of the value and `destination` is the class of
  the artifact being written. A `:private` value written to a `:normal`
  destination fails before the destination is created.
  """
  @spec persist(binary(), term(), class(), class()) :: :ok | {:error, error()}
  def persist(path, value, class, destination)
      when is_binary(path) and class in [:normal, :private] and
             destination in [:normal, :private] do
    persist(path, value, class, destination, nil)
  end

  def persist(_path, _value, _class, _destination), do: {:error, :invalid_result_destination}

  @doc false
  @spec persist(binary(), term(), class(), class(), nil | (atom() -> term())) ::
          :ok | {:error, error()}
  def persist(path, value, class, destination, fault_hook)
      when is_binary(path) and class in [:normal, :private] and
             destination in [:normal, :private] and
             (is_nil(fault_hook) or is_function(fault_hook, 1)) do
    with :ok <- compatible(class, destination),
         :ok <- validate_destination(path),
         {:ok, path} <- anchor_destination(path),
         :ok <- preflight_anchored(path),
         {:ok, encoded} <- encode(value) do
      persist_new(path, encoded, destination, fault_hook)
    end
  end

  def persist(_path, _value, _class, _destination, _fault_hook),
    do: {:error, :invalid_result_destination}

  @doc false
  @spec prepare(term(), class(), class()) :: {:ok, binary()} | {:error, error()}
  def prepare(value, class, destination)
      when class in [:normal, :private] and destination in [:normal, :private] do
    with :ok <- compatible(class, destination) do
      encode(value)
    end
  end

  def prepare(_value, _class, _destination),
    do: {:error, :invalid_result_destination}

  @doc false
  @spec persist_handle(PublicationHandle.t(), term(), class(), class(), nil | (atom() -> term())) ::
          :ok | {:error, error()}
  def persist_handle(handle, value, class, destination, fault_hook \\ nil)

  def persist_handle(%PublicationHandle{} = handle, value, class, destination, fault_hook)
      when class in [:normal, :private] and destination in [:normal, :private] and
             (is_nil(fault_hook) or is_function(fault_hook, 1)) do
    with true <- PublicationHandle.valid?(handle),
         :ok <- compatible(class, destination),
         {:ok, encoded} <- prepare(value, class, destination),
         :ok <- persistence_fault(fault_hook, :before_write),
         :ok <- PublicationHandle.write(handle, encoded),
         :ok <- persistence_fault(fault_hook, :after_write),
         :ok <- sync_after_write(handle, destination, fault_hook),
         result <- publish_after_sync(handle, fault_hook) do
      result
    else
      false ->
        {:error, :invalid_result_destination}

      {:error, {:result_not_json_encodable, _kind} = error} ->
        error

      {:error, :private_result_requires_private_destination} = error ->
        error

      {:error, reason}
      when reason in [:file_sync_failed, :directory_sync_failed, :publication_collision] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :result_persistence_failed}
    end
  end

  def persist_handle(_handle, _value, _class, _destination, _fault_hook),
    do: {:error, :invalid_result_destination}

  @doc false
  @spec persist_prepared_handle(
          PublicationHandle.t(),
          binary(),
          class(),
          nil | (atom() -> term())
        ) :: :ok | {:error, error()}
  def persist_prepared_handle(handle, encoded, destination, fault_hook \\ nil)

  def persist_prepared_handle(%PublicationHandle{} = handle, encoded, destination, fault_hook)
      when is_binary(encoded) and destination in [:normal, :private] and
             (is_nil(fault_hook) or is_function(fault_hook, 1)) do
    with true <- PublicationHandle.valid?(handle),
         :ok <- persistence_fault(fault_hook, :before_write),
         :ok <- PublicationHandle.write(handle, encoded),
         :ok <- persistence_fault(fault_hook, :after_write),
         :ok <- sync_after_write(handle, destination, fault_hook),
         result <- publish_after_sync(handle, fault_hook) do
      result
    else
      false ->
        {:error, :invalid_result_destination}

      {:error, reason}
      when reason in [:file_sync_failed, :directory_sync_failed, :publication_collision] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :result_persistence_failed}
    end
  end

  def persist_prepared_handle(_handle, _encoded, _destination, _fault_hook),
    do: {:error, :invalid_result_destination}

  @doc "Read-only validation of a result destination before run execution."
  @spec preflight_destination(term(), class(), class()) :: :ok | {:error, error()}
  def preflight_destination(path, class, destination)
      when is_binary(path) and class in [:normal, :private] and
             destination in [:normal, :private] do
    with :ok <- compatible(class, destination),
         :ok <- validate_destination(path),
         {:ok, path} <- anchor_destination(path) do
      preflight_anchored(path)
    end
  end

  def preflight_destination(_path, _class, _destination),
    do: {:error, :invalid_result_destination}

  defp compatible(:private, :normal), do: {:error, :private_result_requires_private_destination}
  defp compatible(_class, _destination), do: :ok

  defp anchor_destination(path) do
    case PrivateDirectory.anchor(path) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, :invalid_result_destination}
    end
  end

  defp preflight_anchored(path) do
    case File.lstat(path) do
      {:ok, _stat} -> {:error, :result_destination_exists}
      {:error, :enoent} -> preflight_private_directory(path)
      {:error, _reason} -> {:error, :invalid_result_destination}
    end
  end

  defp validate_destination(path) do
    cond do
      path == "" or String.contains?(path, <<0>>) -> {:error, :invalid_result_destination}
      not String.valid?(path) -> {:error, :invalid_result_destination}
      true -> :ok
    end
  end

  # An untrusted ancestor names a directory the operator can go fix; a missing
  # `mkdir`/`id` does not. They are reported apart rather than both arriving as
  # a bare persistence failure.
  defp preflight_private_directory(path) do
    case PrivateDirectory.preflight(path) do
      :ok -> :ok
      {:error, :private_directory_parent_unavailable} -> {:error, :invalid_result_destination}
      {:error, :private_directory_parent_unsafe} -> {:error, :result_destination_unsafe}
      {:error, _reason} -> {:error, :result_persistence_failed}
    end
  end

  # A value that cannot be encoded did not fail to be written; it was never
  # writable. `Kernel.run` legitimately answers Elixir terms — `tool/kernel-eval`
  # returns an atom-keyed envelope, and embedding hosts read it — so the JSON
  # requirement belongs to the artifact, not to the boundary. Reporting it as a
  # persistence failure sent an operator looking at permissions and paths.
  defp encode(value) do
    case DeterministicJSON.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, {:result_not_json_encodable, value_kind(value)}}
    end
  end

  defp value_kind(value) when is_map(value) and not is_struct(value), do: :object
  defp value_kind(value) when is_list(value), do: :array
  defp value_kind(value) when is_binary(value), do: :string
  defp value_kind(value) when is_atom(value), do: :atom
  defp value_kind(_value), do: :unknown

  # `File.ln/2` fails when the destination exists, so the no-clobber guarantee
  # survives a race between the check above and the link.
  defp persist_new(path, encoded, destination, fault_hook) do
    {temporary_directory, temporary} = PrivateDirectory.temporary_sibling(path, "artifact")

    case PrivateDirectory.create(temporary_directory) do
      :ok ->
        persist_created(
          path,
          temporary_directory,
          temporary,
          encoded,
          destination,
          fault_hook
        )

      {:error, _reason} ->
        {:error, :result_persistence_failed}
    end
  end

  defp persist_created(
         path,
         temporary_directory,
         temporary,
         encoded,
         destination,
         fault_hook
       ) do
    with {:ok, :ok} <- write_temporary(temporary, encoded, destination, fault_hook),
         :ok <- File.ln(temporary, path) do
      :ok
    else
      {:error, :eexist} -> {:error, :result_destination_exists}
      {:error, _reason} -> {:error, :result_persistence_failed}
    end
  after
    _ = File.rm(temporary)
    _ = File.rmdir(temporary_directory)
  end

  defp write_temporary(temporary, encoded, destination, fault_hook) do
    case File.open(temporary, [:write, :binary, :exclusive], fn device ->
           with :ok <- persistence_fault(fault_hook, :before_restrict),
                :ok <- restrict(temporary, destination),
                :ok <- persistence_fault(fault_hook, :before_write) do
             IO.binwrite(device, encoded)
           end
         end) do
      {:ok, :ok} = success -> success
      {:ok, {:error, _reason}} -> {:error, :result_persistence_failed}
      {:error, _reason} = error -> error
      _unexpected -> {:error, :result_persistence_failed}
    end
  end

  defp restrict(temporary, :private), do: File.chmod(temporary, 0o600)
  defp restrict(_temporary, :normal), do: :ok

  defp publish_handle(%PublicationHandle{kind: :recovery}), do: :ok
  defp publish_handle(%PublicationHandle{} = handle), do: PublicationHandle.publish(handle)

  defp publish_after_sync(handle, fault_hook) do
    case persistence_fault(fault_hook, :after_sync) do
      :ok -> publish_handle(handle)
      {:error, reason} -> persisted_failure(handle, reason)
    end
  end

  defp sync_after_write(%PublicationHandle{kind: :recovery} = handle, :private, fault_hook),
    do: PublicationHandle.sync_and_retain(handle, fault_hook)

  defp sync_after_write(handle, _destination, _fault_hook), do: PublicationHandle.sync(handle)

  defp persisted_failure(%PublicationHandle{kind: :recovery} = handle, reason) do
    state =
      if PublicationHandle.recovery_reachable?(handle),
        do: :recovery_written,
        else: :finalization_uncertain

    {:error, {state, reason}}
  end

  defp persisted_failure(_handle, reason), do: {:error, reason}

  defp persistence_fault(nil, _stage), do: :ok

  defp persistence_fault(fault_hook, stage) do
    case fault_hook.(stage) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _failure -> {:error, :result_persistence_failed}
    end
  rescue
    _exception -> {:error, :result_persistence_failed}
  catch
    _kind, _reason -> {:error, :result_persistence_failed}
  end
end
