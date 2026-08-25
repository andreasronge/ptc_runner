defmodule PtcRunner.Research.SealedEvidenceLog.Handle do
  @moduledoc """
  Pinned raw reader for one sealed evidence artifact.

  Queries continue against this descriptor after the path is replaced. Size and
  footer accounting detect append or truncate. Same-size overwrites are detected
  only when a queried range's digest disagrees with admission.
  """

  alias PtcRunner.Research.SealedEvidenceLog.Format

  @type t :: %{
          io: :file.io_device(),
          size: non_neg_integer(),
          footer: Format.footer(),
          digest: binary()
        }

  @spec open(Path.t()) :: {:ok, t()} | {:error, :malformed_source | :source_changed}
  def open(path) when is_binary(path) do
    case :file.open(path, [:read, :binary]) do
      {:ok, io} ->
        case inspect_opened(io) do
          {:ok, handle} ->
            {:ok, handle}

          {:error, reason} ->
            :file.close(io)
            {:error, reason}
        end

      {:error, _reason} ->
        {:error, :malformed_source}
    end
  end

  def open(_path), do: {:error, :malformed_source}

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
