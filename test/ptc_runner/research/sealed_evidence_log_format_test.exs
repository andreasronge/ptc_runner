defmodule PtcRunner.Research.SealedEvidenceLog.FormatTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Research.SealedEvidenceLog
  alias PtcRunner.Research.SealedEvidenceLog.Format
  alias PtcRunner.Research.SealedEvidenceLog.Generator

  @moduletag :tmp_dir

  test "header and footer round-trip through a tiny artifact", %{tmp_dir: tmp} do
    corpus = Generator.second_run("format-run")
    path = Path.join(tmp, "format.ptcins")

    assert {:ok, produced} = SealedEvidenceLog.produce(path, corpus.records)
    assert produced.record_count == 1
    assert produced.total_bytes == File.stat!(path).size

    {:ok, io} = :file.open(path, [:raw, :read, :binary])
    {:ok, header} = :file.pread(io, 0, Format.header_size())
    :ok = :file.close(io)

    assert {:ok, :header} = Format.decode_header(header)

    footer_offset = produced.total_bytes - Format.footer_size()

    {:ok, io} = :file.open(path, [:raw, :read, :binary])
    {:ok, footer_bytes} = :file.pread(io, footer_offset, Format.footer_size())
    :ok = :file.close(io)

    assert {:ok, footer} = Format.decode_footer(footer_bytes)
    assert footer.record_count == 1
    assert footer.total_bytes == produced.total_bytes
    assert footer.artifact_digest == produced.artifact_digest
  end

  test "rejects a footer whose record_count does not match evidence", %{tmp_dir: tmp} do
    corpus = Generator.second_run("count-mismatch")
    path = Path.join(tmp, "count-mismatch.ptcins")
    assert {:ok, produced} = SealedEvidenceLog.produce(path, corpus.records)

    footer_offset = produced.total_bytes - Format.footer_size()
    {:ok, io} = :file.open(path, [:raw, :read, :write, :binary])
    {:ok, footer_bytes} = :file.pread(io, footer_offset, Format.footer_size())
    {:ok, footer} = Format.decode_footer(footer_bytes)
    mutated = Format.encode_footer(%{footer | record_count: footer.record_count + 100})
    :ok = :file.pwrite(io, footer_offset, mutated)
    :ok = :file.close(io)

    assert {:error, :malformed_source} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts})
  end

  test "payload stream keeps a constant encoded frame size", %{tmp_dir: tmp} do
    path = Path.join(tmp, "constant.ptcins")
    frame_bytes = 2_048

    assert {:ok, produced} =
             SealedEvidenceLog.produce(
               path,
               Generator.payload_stream("const-run", 2, frame_bytes)
             )

    assert produced.record_count == 2
    assert produced.frame_size == frame_bytes
    assert is_integer(produced.frame_size)
  end

  test "rejects a truncated header", %{tmp_dir: tmp} do
    path = Path.join(tmp, "truncated.ptcins")
    File.write!(path, "PTCINS")
    assert {:error, :malformed_source} = SealedEvidenceLog.admit(%{path: path, trace_facts: %{}})
  end
end
