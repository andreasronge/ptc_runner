defmodule PtcRunner.Kernel.InspectionArtifact do
  @moduledoc """
  Sealed V1 private inspection artifact publication and path contract.

  A `.ptcins` artifact contains one fixed header, deterministic length-framed
  JSON evidence, and one fixed footer. Production writes evidence directly to
  a missing-destination reservation as records are emitted; no complete record
  list or complete artifact binary is retained. Publication hard-links only a
  synchronized, sealed staging file and never replaces an existing path.

  Readers pin one opened file, independently admit every frame against its
  paired canonical trace, and keep only bounded derived ETS metadata. Queries
  read and digest-check the payload ranges required for returned content.
  """

  alias PtcRunner.Kernel.InspectionArtifact.Codec
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.InspectionArtifact.Handle
  alias PtcRunner.Kernel.InspectionArtifact.Limits
  alias PtcRunner.Kernel.InspectionRecord
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationHandle

  @suffix ".ptcins"

  @type seal :: %{
          artifact_digest: binary(),
          file_digest: binary(),
          evidence_bytes: non_neg_integer(),
          record_count: non_neg_integer(),
          total_bytes: pos_integer()
        }

  @spec suffix() :: binary()
  def suffix, do: @suffix

  @spec max_artifact_bytes() :: pos_integer()
  def max_artifact_bytes, do: Limits.max_artifact_bytes()

  @spec preflight_destination(term()) :: :ok | {:error, atom()}
  def preflight_destination(path) when is_binary(path) do
    with :ok <- validate_destination_path(path),
         {:ok, path} <- PrivateDirectory.anchor(path) do
      case File.lstat(path) do
        {:ok, _stat} -> {:error, :inspection_destination_exists}
        {:error, :enoent} -> preflight_private_directory(path)
        {:error, _reason} -> {:error, :inspection_destination_unavailable}
      end
    else
      {:error, :invalid_inspection_path} = error -> error
      {:error, _reason} -> {:error, :invalid_inspection_path}
    end
  end

  def preflight_destination(_path), do: {:error, :invalid_inspection_path}

  @doc false
  @spec validate_destination_path(term()) :: :ok | {:error, :invalid_inspection_path}
  def validate_destination_path(path) when is_binary(path) do
    if String.valid?(path) and String.ends_with?(path, @suffix),
      do: :ok,
      else: {:error, :invalid_inspection_path}
  end

  def validate_destination_path(_path), do: {:error, :invalid_inspection_path}

  @doc false
  @spec publish_handle(PublicationHandle.t(), seal(), nil | (atom() -> term())) ::
          :ok | {:error, atom()}
  def publish_handle(handle, seal, fault_hook \\ nil)

  def publish_handle(%PublicationHandle{kind: :inspection} = handle, seal, fault_hook)
      when is_map(seal) and (is_nil(fault_hook) or is_function(fault_hook, 1)) do
    with true <- valid_seal?(seal),
         :ok <- PublicationHandle.attest(handle, seal.total_bytes, seal.file_digest),
         :ok <- PublicationHandle.verify(handle),
         :ok <- publication_fault(fault_hook, :before_publish),
         :ok <- PublicationHandle.verify(handle),
         :ok <- PublicationHandle.publish(handle) do
      :ok
    else
      false -> {:error, :invalid_inspection_artifact}
      {:error, _reason} = error -> error
    end
  end

  def publish_handle(_handle, _seal, _fault_hook),
    do: {:error, :invalid_inspection_artifact}

  @doc false
  @spec open(binary()) :: {:ok, Handle.t()} | {:error, atom()}
  def open(path), do: Handle.open(path)

  @doc false
  @spec identity(binary()) :: {:ok, %{run_id: binary(), trace_id: binary()}} | {:error, atom()}
  def identity(path) when is_binary(path) do
    with {:ok, handle} <- Handle.open(path) do
      result = read_identity(handle)
      Handle.close(handle)
      result
    end
  end

  def identity(_path), do: {:error, :malformed_source}

  @doc false
  @spec empty_identity_hashes(binary()) ::
          {:ok, %{run_id_sha256: binary(), trace_id_sha256: binary()}} | {:error, atom()}
  def empty_identity_hashes(path) when is_binary(path) do
    with {:ok, handle} <- Handle.open(path) do
      result =
        case handle.footer do
          %{record_count: 0, run_id_sha256: run_hash, trace_id_sha256: trace_hash} ->
            {:ok, %{run_id_sha256: run_hash, trace_id_sha256: trace_hash}}

          _nonempty ->
            {:error, :malformed_source}
        end

      Handle.close(handle)
      result
    end
  end

  def empty_identity_hashes(_path), do: {:error, :malformed_source}

  @doc false
  @spec format_contract() :: map()
  def format_contract do
    %{
      format_version: Format.format_version(),
      schema_version: Format.schema_version(),
      header_bytes: Format.header_size(),
      footer_bytes: Format.footer_size(),
      max_record_bytes: Limits.max_record_bytes(),
      max_evidence_bytes: Limits.max_total_bytes(),
      max_artifact_bytes: Limits.max_artifact_bytes(),
      default_max_records: Limits.default_records(),
      maintained_max_records: Limits.max_records(),
      max_retained_bytes: Limits.max_retained_bytes()
    }
  end

  defp valid_seal?(seal) do
    match?(
      %{
        artifact_digest: digest,
        file_digest: file_digest,
        evidence_bytes: evidence_bytes,
        record_count: record_count,
        total_bytes: total_bytes
      }
      when is_binary(digest) and byte_size(digest) == 32 and
             is_binary(file_digest) and byte_size(file_digest) == 32 and
             is_integer(evidence_bytes) and evidence_bytes >= 0 and
             is_integer(record_count) and record_count >= 0 and
             is_integer(total_bytes) and total_bytes > 0,
      seal
    ) and
      seal.total_bytes == Format.header_size() + seal.evidence_bytes + Format.footer_size()
  end

  defp read_identity(handle) do
    with true <- handle.footer.record_count > 0 and handle.footer.evidence_bytes >= 8,
         {:ok, <<length::unsigned-big-64>>} <- Handle.pread(handle, Format.header_size(), 8),
         true <- length <= Limits.max_record_bytes(),
         true <- length + 8 <= handle.footer.evidence_bytes,
         {:ok, payload} <- Handle.pread(handle, Format.header_size() + 8, length),
         {:ok, record} <- Codec.decode_record(payload),
         :ok <- InspectionRecord.validate(record, nil, nil, 1) do
      {:ok, %{run_id: record["run_id"], trace_id: record["trace_id"]}}
    else
      _invalid -> {:error, :malformed_source}
    end
  end

  defp preflight_private_directory(path) do
    case PrivateDirectory.preflight(path) do
      :ok ->
        :ok

      {:error, :private_directory_parent_unavailable} ->
        {:error, :inspection_destination_unavailable}

      {:error, :private_directory_parent_unsafe} ->
        {:error, :inspection_destination_unsafe}

      {:error, _reason} ->
        {:error, :inspection_persistence_failed}
    end
  end

  defp publication_fault(nil, _stage), do: :ok

  defp publication_fault(hook, stage) do
    if hook.(stage) == :ok, do: :ok, else: {:error, :inspection_persistence_failed}
  rescue
    _exception -> {:error, :inspection_persistence_failed}
  catch
    _kind, _reason -> {:error, :inspection_persistence_failed}
  end
end
