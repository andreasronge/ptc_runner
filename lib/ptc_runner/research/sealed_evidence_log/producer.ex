defmodule PtcRunner.Research.SealedEvidenceLog.Producer do
  @moduledoc """
  Streaming sealed-log writer that never retains a record list or artifact binary.

  One process writes the header, then yields, encodes, writes, and releases each
  record before constructing the next. The footer is appended from running
  counts, identity hashes, and incremental SHA-256. Producer heap is bounded
  with `max_heap_size` `kill: true` and `include_shared_binaries: true`.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Research.SealedEvidenceLog.Checkpoints
  alias PtcRunner.Research.SealedEvidenceLog.Codec
  alias PtcRunner.Research.SealedEvidenceLog.Format
  alias PtcRunner.Research.SealedEvidenceLog.Limits

  @spec write(Path.t(), Enumerable.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def write(path, records, limits, opts \\ [])
      when is_binary(path) and is_map(limits) and is_list(opts) do
    hook = Keyword.get(opts, :checkpoint_hook)
    timeout_ms = Keyword.get(opts, :deadline_ms, limits.producer_deadline_ms)

    BoundedWorker.run(
      fn -> produce(path, records, limits, hook) end,
      timeout_ms: timeout_ms,
      max_heap_words: Limits.heap_words(limits.producer_heap_bytes)
    )
    |> wrap_worker()
  end

  defp produce(path, records, limits, hook) do
    File.mkdir_p!(Path.dirname(path))

    {:ok, io} =
      :file.open(path, [
        :raw,
        :write,
        :binary,
        :exclusive,
        {:delayed_write, limits.io_buffer_bytes, 1_000}
      ])

    try do
      write_stream(io, records, limits, hook)
    after
      :file.close(io)
    end
  end

  defp write_stream(io, records, limits, hook) do
    header = Format.encode_header()
    :ok = :file.write(io, header)
    evidence = :crypto.hash_init(:sha256)
    checkpoints = Checkpoints.new()
    pids = [self()]

    acc = %{
      evidence: evidence,
      artifact: :crypto.hash_update(:crypto.hash_init(:sha256), header),
      evidence_bytes: 0,
      record_count: 0,
      first_sequence: 0,
      last_sequence: 0,
      run_id: nil,
      trace_id: nil,
      checkpoints: checkpoints,
      frame_size: nil
    }

    case reduce_records(records, acc, fn record, state ->
           write_record(io, record, state, limits, hook, pids)
         end) do
      {:ok, state} ->
        finish(io, header, state, hook, pids)

      {:error, _reason} = error ->
        error
    end
  end

  defp write_record(io, record, state, limits, hook, pids) do
    state = checkpoint(state, :payload_constructed, hook, pids)

    with {:ok, encoded} <- Codec.encode_record(record),
         true <- byte_size(encoded) <= limits.max_record_bytes,
         {:ok, frame} <- Format.encode_frame(encoded),
         true <- state.evidence_bytes + byte_size(frame) <= limits.max_total_bytes,
         :ok <- identities(state, record),
         :ok <- sequence(state, record) do
      state = checkpoint(state, :encoded, hook, pids)
      :ok = :file.write(io, frame)

      next = %{
        state
        | evidence: :crypto.hash_update(state.evidence, frame),
          artifact: :crypto.hash_update(state.artifact, frame),
          evidence_bytes: state.evidence_bytes + byte_size(frame),
          record_count: state.record_count + 1,
          first_sequence: first_sequence(state, record["sequence"]),
          last_sequence: record["sequence"],
          run_id: record["run_id"],
          trace_id: record["trace_id"],
          frame_size: constant_frame_size(state.frame_size, byte_size(frame))
      }

      _ = encoded
      _ = frame
      _ = record
      {:ok, checkpoint(next, :frame_released, hook, pids)}
    else
      false -> {:error, :limit_exceeded}
      {:error, _reason} = error -> error
      :identity_mismatch -> {:error, :invalid_record}
      :sequence_mismatch -> {:error, :invalid_record}
    end
  end

  defp finish(io, _header, state, hook, pids) do
    :ok = :file.sync(io)
    evidence_sha = :crypto.hash_final(state.evidence)
    total = Format.header_size() + state.evidence_bytes + Format.footer_size()

    unsigned = %{
      total_bytes: total,
      evidence_offset: Format.header_size(),
      evidence_bytes: state.evidence_bytes,
      record_count: state.record_count,
      first_sequence: state.first_sequence,
      last_sequence: state.last_sequence,
      run_id_sha256: identity_hash(state.run_id),
      trace_id_sha256: identity_hash(state.trace_id),
      evidence_sha256: evidence_sha,
      artifact_digest: <<0::unsigned-big-256>>
    }

    artifact_digest =
      state.artifact
      |> :crypto.hash_update(Format.unsigned_footer(unsigned))
      |> :crypto.hash_final()

    footer = Format.encode_footer(%{unsigned | artifact_digest: artifact_digest})
    :ok = :file.write(io, footer)
    :ok = :file.sync(io)

    {:ok,
     %{
       record_count: state.record_count,
       evidence_bytes: state.evidence_bytes,
       total_bytes: total,
       frame_size: state.frame_size,
       artifact_digest: artifact_digest,
       checkpoints: Checkpoints.finalize(checkpoint(state, :encoded, hook, pids).checkpoints)
     }}
  end

  defp identities(%{run_id: nil}, record), do: identity_present(record)

  defp identities(%{run_id: run_id, trace_id: trace_id}, record) do
    if record["run_id"] == run_id and record["trace_id"] == trace_id,
      do: :ok,
      else: :identity_mismatch
  end

  defp identity_present(%{"run_id" => run_id, "trace_id" => trace_id})
       when is_binary(run_id) and is_binary(trace_id),
       do: :ok

  defp identity_present(_record), do: :identity_mismatch

  defp sequence(%{record_count: 0}, %{"sequence" => sequence})
       when is_integer(sequence) and sequence > 0,
       do: :ok

  defp sequence(%{last_sequence: last}, %{"sequence" => sequence})
       when is_integer(sequence) and sequence == last + 1,
       do: :ok

  defp sequence(_state, _record), do: :sequence_mismatch

  defp first_sequence(%{record_count: 0}, sequence), do: sequence
  defp first_sequence(%{first_sequence: first}, _sequence), do: first

  defp constant_frame_size(nil, size), do: size
  defp constant_frame_size(size, size), do: size
  defp constant_frame_size(_previous, _size), do: :mixed

  defp identity_hash(nil), do: :crypto.hash(:sha256, "")
  defp identity_hash(value), do: Format.identity_sha256(value)

  defp checkpoint(state, name, hook, pids) do
    checkpoints = Checkpoints.record(state.checkpoints, name, pids)
    if is_function(hook, 1), do: hook.(name)
    %{state | checkpoints: checkpoints}
  end

  defp reduce_records(records, acc, fun) do
    Enum.reduce_while(records, {:ok, acc}, fn record, {:ok, state} ->
      case fun.(record, state) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp wrap_worker({:ok, result}), do: result
  defp wrap_worker({:error, :heap_exceeded}), do: {:error, :heap_exceeded}
  defp wrap_worker({:error, :timeout}), do: {:error, :deadline_exceeded}
  defp wrap_worker(_other), do: {:error, :producer_failed}
end
