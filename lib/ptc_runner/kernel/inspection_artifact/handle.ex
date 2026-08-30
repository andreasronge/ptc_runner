defmodule PtcRunner.Kernel.InspectionArtifact.Handle do
  @moduledoc """
  Pinned reader for one sealed evidence artifact.

  The descriptor is a file-server IoDevice so admission and query workers can
  `pread/3` the same opened inode. `:raw` descriptors are process-local and
  cannot be shared with bounded workers. Queries continue against this
  descriptor after the path is replaced. Size and footer accounting detect
  append or truncate. Same-size overwrites are detected when a queried range's
  digest disagrees with admission, or during admission seal confirmation.
  """

  alias PtcRunner.Kernel.InspectionArtifact.Format

  @type t :: %{
          io: :file.io_device(),
          size: non_neg_integer(),
          footer: Format.footer(),
          digest: binary()
        }

  @spec open(Path.t()) ::
          {:ok, t()} | {:error, :malformed_source | :source_changed | :source_unavailable}
  def open(path) when is_binary(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = expected} -> open(path, expected)
      {:ok, %File.Stat{}} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :source_unavailable}
    end
  end

  def open(_path), do: {:error, :malformed_source}

  @doc false
  @spec open(Path.t(), File.Stat.t()) ::
          {:ok, t()} | {:error, :malformed_source | :source_changed | :source_unavailable}
  def open(path, %File.Stat{type: :regular} = expected) when is_binary(path) do
    with {:ok, before_open} <- File.lstat(path, time: :posix),
         :ok <- same_file(expected, before_open) do
      open_verified(path, expected)
    else
      _changed -> {:error, :source_changed}
    end
  end

  def open(_path, _expected), do: {:error, :malformed_source}

  defp open_verified(path, expected) do
    case :file.open(path, [:read, :binary]) do
      {:ok, io} ->
        result =
          with {:ok, opened} <- opened_stat(io),
               :ok <- same_file(expected, opened),
               {:ok, after_open} <- File.lstat(path, time: :posix),
               :ok <- same_file(expected, after_open),
               {:ok, handle} <- inspect_opened(io) do
            {:ok, handle}
          else
            {:error, :malformed_source} = error -> error
            _changed -> {:error, :source_changed}
          end

        case result do
          {:ok, handle} ->
            {:ok, handle}

          {:error, reason} ->
            :file.close(io)
            {:error, reason}
        end

      {:error, _reason} ->
        {:error, :source_unavailable}
    end
  end

  @spec close(t() | nil) :: :ok
  def close(%{io: io}) do
    :file.close(io)
    :ok
  end

  def close(_handle), do: :ok

  @spec usable?(t()) :: boolean()
  def usable?(%{io: io}) do
    case :file.position(io, {:cur, 0}) do
      {:ok, _offset} -> true
      _error -> false
    end
  end

  def usable?(_handle), do: false

  @spec current_size(t()) :: {:ok, non_neg_integer()} | {:error, :source_changed}
  def current_size(%{io: io}) do
    case :file.position(io, {:eof, 0}) do
      {:ok, size} ->
        _ = :file.position(io, {:bof, 0})
        {:ok, size}

      _error ->
        {:error, :source_changed}
    end
  end

  @spec assert_stable(t()) :: :ok | {:error, :source_changed}
  def assert_stable(%{size: size, footer: footer} = handle) do
    with {:ok, current} <- current_size(handle),
         true <- current == size,
         {:ok, bytes} <- pread(handle, size - Format.footer_size(), Format.footer_size()),
         {:ok, current_footer} <- Format.decode_footer(bytes),
         true <- current_footer == footer do
      :ok
    else
      _other -> {:error, :source_changed}
    end
  end

  @spec pread(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :source_changed}
  def pread(%{io: io}, offset, length)
      when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 do
    case :file.pread(io, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      :eof -> {:error, :source_changed}
      {:error, _reason} -> {:error, :source_changed}
      {:ok, _short} -> {:error, :source_changed}
    end
  end

  def pread(_handle, _offset, _length), do: {:error, :source_changed}

  @spec verify_range(t(), non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, :source_changed}
  def verify_range(handle, offset, length, digest) do
    with {:ok, bytes} <- pread(handle, offset, length),
         true <- :crypto.hash(:sha256, bytes) == digest do
      {:ok, bytes}
    else
      false -> {:error, :source_changed}
      {:error, _reason} = error -> error
    end
  end

  @spec confirm_seal(t(), binary(), map(), pos_integer()) ::
          :ok | {:error, :malformed_source | :source_changed}
  def confirm_seal(handle, streamed_evidence_sha, state, io_buffer_bytes)
      when is_binary(streamed_evidence_sha) and is_map(state) and
             is_integer(io_buffer_bytes) and io_buffer_bytes > 0 do
    footer = handle.footer

    with true <- footer.record_count == state.record_count,
         true <- footer.first_sequence == state.first_sequence,
         true <- footer.last_sequence == state.last_sequence,
         true <- footer.run_id_sha256 == Format.identity_sha256(state.run_id || ""),
         true <- footer.trace_id_sha256 == Format.identity_sha256(state.trace_id || ""),
         {:ok, file_evidence_sha, artifact_digest} <- hash_opened(handle, io_buffer_bytes),
         :ok <- compare_evidence_hash(streamed_evidence_sha, file_evidence_sha, footer),
         true <- artifact_digest == footer.artifact_digest do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :malformed_source}
    end
  end

  defp compare_evidence_hash(streamed, file_hash, footer) do
    cond do
      streamed != file_hash -> {:error, :source_changed}
      file_hash != footer.evidence_sha256 -> {:error, :malformed_source}
      true -> :ok
    end
  end

  defp hash_opened(handle, io_buffer_bytes) do
    footer = handle.footer

    with {:ok, header} <- pread(handle, 0, Format.header_size()) do
      start = footer.evidence_offset
      ending = start + footer.evidence_bytes

      case hash_range(
             handle,
             start,
             ending,
             :crypto.hash_init(:sha256),
             :crypto.hash_update(:crypto.hash_init(:sha256), header),
             io_buffer_bytes
           ) do
        {:ok, evidence_acc, artifact_acc} ->
          evidence_sha = :crypto.hash_final(evidence_acc)

          artifact_digest =
            artifact_acc
            |> :crypto.hash_update(Format.unsigned_footer(footer))
            |> :crypto.hash_final()

          {:ok, evidence_sha, artifact_digest}

        error ->
          error
      end
    end
  end

  defp hash_range(_handle, offset, ending, evidence_acc, artifact_acc, _buffer)
       when offset >= ending,
       do: {:ok, evidence_acc, artifact_acc}

  defp hash_range(handle, offset, ending, evidence_acc, artifact_acc, buffer) do
    chunk = min(buffer, ending - offset)

    case pread(handle, offset, chunk) do
      {:ok, bytes} ->
        hash_range(
          handle,
          offset + chunk,
          ending,
          :crypto.hash_update(evidence_acc, bytes),
          :crypto.hash_update(artifact_acc, bytes),
          buffer
        )

      error ->
        error
    end
  end

  defp inspect_opened(io) do
    with {:ok, header} <- read_at(io, 0, Format.header_size()),
         {:ok, :header} <- Format.decode_header(header),
         {:ok, size} <- file_size(io),
         true <- size >= Format.header_size() + Format.footer_size(),
         {:ok, footer_bytes} <- read_at(io, size - Format.footer_size(), Format.footer_size()),
         {:ok, footer} <- Format.decode_footer(footer_bytes),
         true <- footer.total_bytes == size,
         true <- footer.evidence_offset == Format.header_size(),
         true <-
           footer.evidence_offset + footer.evidence_bytes + Format.footer_size() == size do
      {:ok,
       %{
         io: io,
         size: size,
         footer: footer,
         digest: footer.artifact_digest
       }}
    else
      _other -> {:error, :malformed_source}
    end
  end

  defp opened_stat(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, file_info} -> {:ok, File.Stat.from_record(file_info)}
      {:error, _reason} -> {:error, :source_changed}
    end
  end

  defp same_file(
         %File.Stat{
           type: :regular,
           size: size,
           major_device: major,
           minor_device: minor,
           inode: inode
         },
         %File.Stat{
           type: :regular,
           size: size,
           major_device: major,
           minor_device: minor,
           inode: inode
         }
       ),
       do: :ok

  defp same_file(_expected, _opened), do: {:error, :source_changed}

  defp file_size(io) do
    case :file.position(io, {:eof, 0}) do
      {:ok, size} -> {:ok, size}
      _error -> {:error, :malformed_source}
    end
  end

  defp read_at(io, offset, length) do
    case :file.pread(io, offset, length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      _other -> {:error, :malformed_source}
    end
  end
end
