defmodule PtcRunner.Research.SealedEvidenceLog.Format do
  @moduledoc """
  Header, length-framed evidence, and terminal footer for the ETS-index prototype.

  This is a test/benchmark-only container. Production inspection routing still
  uses JSONL. The layout is the simple candidate from issue #1646:

  ```text
  16-byte versioned header
  length-framed deterministic JSON evidence
  192-byte terminal footer
  ```

  Multibyte integers are unsigned big-endian. Offsets are absolute. A reader
  rejects a size that does not match the opened file, a header/footer version
  mismatch, overlap, or nonzero reserved bytes before following any range.
  """

  @header_magic "PTCINS01"
  @footer_magic "PTCIFTR1"
  @format_version 1
  @schema_version 8
  @header_size 16
  @footer_size 192

  @type footer :: %{
          total_bytes: non_neg_integer(),
          evidence_offset: non_neg_integer(),
          evidence_bytes: non_neg_integer(),
          record_count: non_neg_integer(),
          first_sequence: non_neg_integer(),
          last_sequence: non_neg_integer(),
          run_id_sha256: binary(),
          trace_id_sha256: binary(),
          evidence_sha256: binary(),
          artifact_digest: binary()
        }

  @spec header_magic() :: binary()
  def header_magic, do: @header_magic

  @spec footer_magic() :: binary()
  def footer_magic, do: @footer_magic

  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec header_size() :: pos_integer()
  def header_size, do: @header_size

  @spec footer_size() :: pos_integer()
  def footer_size, do: @footer_size

  @spec encode_header() :: binary()
  def encode_header do
    <<@header_magic::binary, @format_version::unsigned-big-16, @schema_version::unsigned-big-16,
      @header_size::unsigned-big-32>>
  end

  @spec decode_header(binary()) :: {:ok, :header} | {:error, :malformed_source}
  def decode_header(
        <<@header_magic::binary, @format_version::unsigned-big-16,
          @schema_version::unsigned-big-16, @header_size::unsigned-big-32>>
      ),
      do: {:ok, :header}

  def decode_header(_other), do: {:error, :malformed_source}

  @spec encode_frame(binary()) :: {:ok, binary()} | {:error, :invalid_frame}
  def encode_frame(payload) when is_binary(payload) do
    size = byte_size(payload)

    if size <= 0xFFFF_FFFF_FFFF_FFFF do
      {:ok, <<size::unsigned-big-64, payload::binary>>}
    else
      {:error, :invalid_frame}
    end
  end

  def encode_frame(_payload), do: {:error, :invalid_frame}

  @spec frame_payload_offset(non_neg_integer()) :: non_neg_integer()
  def frame_payload_offset(frame_offset) when is_integer(frame_offset) and frame_offset >= 0,
    do: frame_offset + 8

  @spec encode_footer(footer()) :: binary()
  def encode_footer(footer) when is_map(footer) do
    encode_footer_bytes(footer, footer.artifact_digest)
  end

  @spec unsigned_footer(footer()) :: binary()
  def unsigned_footer(footer) when is_map(footer) do
    encode_footer_bytes(footer, <<0::unsigned-big-256>>)
  end

  @spec decode_footer(binary()) :: {:ok, footer()} | {:error, :malformed_source}
  def decode_footer(
        <<@footer_magic::binary, @format_version::unsigned-big-16,
          @schema_version::unsigned-big-16, @footer_size::unsigned-big-32,
          total_bytes::unsigned-big-64, evidence_offset::unsigned-big-64,
          evidence_bytes::unsigned-big-64, record_count::unsigned-big-64,
          first_sequence::unsigned-big-64, last_sequence::unsigned-big-64,
          run_id_sha256::binary-size(32), trace_id_sha256::binary-size(32),
          evidence_sha256::binary-size(32), artifact_digest::binary-size(32)>>
      ) do
    {:ok,
     %{
       total_bytes: total_bytes,
       evidence_offset: evidence_offset,
       evidence_bytes: evidence_bytes,
       record_count: record_count,
       first_sequence: first_sequence,
       last_sequence: last_sequence,
       run_id_sha256: run_id_sha256,
       trace_id_sha256: trace_id_sha256,
       evidence_sha256: evidence_sha256,
       artifact_digest: artifact_digest
     }}
  end

  def decode_footer(_other), do: {:error, :malformed_source}

  @spec identity_sha256(binary()) :: binary()
  def identity_sha256(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  @spec artifact_digest(binary(), binary(), footer()) :: binary()
  def artifact_digest(header, evidence, footer)
      when is_binary(header) and is_binary(evidence) and is_map(footer) do
    :crypto.hash(:sha256, [header, evidence, unsigned_footer(footer)])
  end

  defp encode_footer_bytes(footer, digest) do
    <<@footer_magic::binary, @format_version::unsigned-big-16, @schema_version::unsigned-big-16,
      @footer_size::unsigned-big-32, footer.total_bytes::unsigned-big-64,
      footer.evidence_offset::unsigned-big-64, footer.evidence_bytes::unsigned-big-64,
      footer.record_count::unsigned-big-64, footer.first_sequence::unsigned-big-64,
      footer.last_sequence::unsigned-big-64, footer.run_id_sha256::binary-size(32),
      footer.trace_id_sha256::binary-size(32), footer.evidence_sha256::binary-size(32),
      digest::binary-size(32)>>
  end
end
