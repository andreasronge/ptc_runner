# Publication-only executable spike. The representative evidence, index, and
# manifest bytes intentionally do not implement the frozen container format;
# production codec tests must validate that contract independently.
defmodule PtcRunner.Kernel.IndexedInspectionPublicationSpikeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.PublicationHandle

  @header <<"PTCINS01", 1::unsigned-big-16, 8::unsigned-big-16, 16::unsigned-big-32>>
  @footer_magic "PTCIFTR1"
  @footer_bytes 288
  @zero_digest <<0::256>>

  @tag :tmp_dir
  test "staged appends seal and atomically publish opaque container bytes", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "sealed.inspection.ptci")

    assert {:ok, handle} = PublicationHandle.reserve_append_for(path, :trace, 0o600, self())
    assert :ok = PublicationHandle.write(handle, @header)

    artifact_hash = :crypto.hash_init(:sha256) |> :crypto.hash_update(@header)
    evidence_hash = :crypto.hash_init(:sha256)
    evidence_offset = byte_size(@header)

    {artifact_hash, evidence_hash, evidence_size, opaque_index_rows} =
      [
        ~s({"sequence":1,"record_type":"capability-input"}),
        ~s({"sequence":2,"record_type":"capability-output"})
      ]
      |> Enum.with_index(1)
      |> Enum.reduce({artifact_hash, evidence_hash, 0, []}, fn {record, sequence},
                                                               {artifact, evidence, size,
                                                                opaque_index_rows} ->
        frame = <<byte_size(record)::unsigned-big-64, record::binary>>
        offset = evidence_offset + size + 8
        assert :ok = PublicationHandle.write(handle, frame)

        opaque_index_row =
          <<sequence::unsigned-big-64, offset::unsigned-big-64,
            byte_size(record)::unsigned-big-64, 0::unsigned-big-32,
            :crypto.hash(:sha256, record)::binary-32>>

        {:crypto.hash_update(artifact, frame), :crypto.hash_update(evidence, frame),
         size + byte_size(frame), [opaque_index_row | opaque_index_rows]}
      end)

    index = opaque_index_rows |> Enum.reverse() |> IO.iodata_to_binary()
    index_offset = evidence_offset + evidence_size
    assert :ok = PublicationHandle.write(handle, index)
    artifact_hash = :crypto.hash_update(artifact_hash, index)

    manifest =
      Jason.encode!(%{
        "format" => "publication-spike-only",
        "run_id" => "run-spike",
        "trace_id" => "trace-spike"
      })

    manifest_offset = index_offset + byte_size(index)
    assert :ok = PublicationHandle.write(handle, manifest)
    artifact_hash = :crypto.hash_update(artifact_hash, manifest)

    footer_fields = %{
      total_size: manifest_offset + byte_size(manifest) + @footer_bytes,
      evidence_offset: evidence_offset,
      evidence_size: evidence_size,
      index_offset: index_offset,
      index_size: byte_size(index),
      manifest_offset: manifest_offset,
      manifest_size: byte_size(manifest),
      record_count: 2,
      index_entry_count: 2,
      run_digest: :crypto.hash(:sha256, "run-spike"),
      trace_digest: :crypto.hash(:sha256, "trace-spike"),
      evidence_digest: :crypto.hash_final(evidence_hash),
      index_digest: :crypto.hash(:sha256, index),
      manifest_digest: :crypto.hash(:sha256, manifest)
    }

    zeroed_footer = footer(footer_fields, @zero_digest)
    artifact_digest = artifact_hash |> :crypto.hash_update(zeroed_footer) |> :crypto.hash_final()
    sealed_footer = footer(footer_fields, artifact_digest)

    assert byte_size(sealed_footer) == @footer_bytes
    assert :ok = PublicationHandle.write(handle, sealed_footer)
    assert :ok = PublicationHandle.sync(handle)
    refute File.exists?(path)
    assert :ok = PublicationHandle.publish(handle)
    assert :ok = PublicationHandle.close(handle)

    bytes = File.read!(path)
    assert byte_size(bytes) == footer_fields.total_size
    assert binary_part(bytes, byte_size(bytes) - @footer_bytes, @footer_bytes) == sealed_footer
    assert artifact_digest(bytes) == artifact_digest
  end

  @tag :tmp_dir
  test "controller death after terminal sync removes all unpublished staging", %{
    tmp_dir: directory
  } do
    parent = self()
    path = Path.join(directory, "interrupted.inspection.ptci")

    controller =
      spawn(fn ->
        {:ok, handle} = PublicationHandle.reserve_append_for(path, :trace, 0o600, self())
        record = ~s({"sequence":1,"record_type":"run-result"})
        evidence = <<byte_size(record)::unsigned-big-64, record::binary>>
        manifest = ~s({"run_id":"interrupted","trace_id":"trace-spike"})
        manifest_offset = byte_size(@header) + byte_size(evidence)

        fields = %{
          total_size: manifest_offset + byte_size(manifest) + @footer_bytes,
          evidence_offset: byte_size(@header),
          evidence_size: byte_size(evidence),
          index_offset: manifest_offset,
          index_size: 0,
          manifest_offset: manifest_offset,
          manifest_size: byte_size(manifest),
          record_count: 1,
          index_entry_count: 0,
          run_digest: :crypto.hash(:sha256, "interrupted"),
          trace_digest: :crypto.hash(:sha256, "trace-spike"),
          evidence_digest: :crypto.hash(:sha256, evidence),
          index_digest: :crypto.hash(:sha256, ""),
          manifest_digest: :crypto.hash(:sha256, manifest)
        }

        zeroed_footer = footer(fields, @zero_digest)
        digest = :crypto.hash(:sha256, [@header, evidence, manifest, zeroed_footer])
        sealed_footer = footer(fields, digest)

        :ok = PublicationHandle.write(handle, @header)
        :ok = PublicationHandle.write(handle, evidence)
        :ok = PublicationHandle.write(handle, manifest)
        :ok = PublicationHandle.write(handle, sealed_footer)
        :ok = PublicationHandle.sync(handle)
        send(parent, {:terminal_staging_synced, handle.owner})

        receive do
          :publish -> PublicationHandle.publish(handle)
        end
      end)

    assert_receive {:terminal_staging_synced, publication_owner}
    refute File.exists?(path)

    publication_ref = Process.monitor(publication_owner)
    Process.exit(controller, :kill)
    assert_receive {:DOWN, ^publication_ref, :process, ^publication_owner, :normal}

    refute File.exists?(path)

    assert {:ok, replacement} =
             PublicationHandle.reserve_append_for(path, :trace, 0o600, self())

    assert :ok = PublicationHandle.remove(replacement)
    assert :ok = PublicationHandle.close(replacement)
    assert File.ls!(directory) == []
  end

  defp footer(fields, artifact_digest) do
    <<@footer_magic, 1::unsigned-big-16, 8::unsigned-big-16, @footer_bytes::unsigned-big-32,
      fields.total_size::unsigned-big-64, fields.evidence_offset::unsigned-big-64,
      fields.evidence_size::unsigned-big-64, fields.index_offset::unsigned-big-64,
      fields.index_size::unsigned-big-64, fields.manifest_offset::unsigned-big-64,
      fields.manifest_size::unsigned-big-64, fields.record_count::unsigned-big-64,
      fields.index_entry_count::unsigned-big-64, fields.run_digest::binary-32,
      fields.trace_digest::binary-32, fields.evidence_digest::binary-32,
      fields.index_digest::binary-32, fields.manifest_digest::binary-32,
      artifact_digest::binary-32, 0::unsigned-big-64>>
  end

  defp artifact_digest(bytes) do
    body_bytes = byte_size(bytes) - @footer_bytes
    body = binary_part(bytes, 0, body_bytes)
    footer = binary_part(bytes, body_bytes, @footer_bytes)
    digest_offset = @footer_bytes - 40

    zeroed_footer =
      binary_part(footer, 0, digest_offset) <>
        @zero_digest <>
        binary_part(footer, digest_offset + 32, @footer_bytes - digest_offset - 32)

    :crypto.hash(:sha256, body <> zeroed_footer)
  end
end
