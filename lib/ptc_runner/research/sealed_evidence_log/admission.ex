defmodule PtcRunner.Research.SealedEvidenceLog.Admission do
  @moduledoc """
  One streaming admission pass over a sealed evidence artifact.

  The pass validates every complete frame, identities, sequences, lifecycle,
  joins, conversation facts, and paired trace claims; inserts bounded ETS rows;
  and releases each evidence payload before the next frame is read.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Research.SealedEvidenceLog.Assembler
  alias PtcRunner.Research.SealedEvidenceLog.Checkpoints
  alias PtcRunner.Research.SealedEvidenceLog.Codec
  alias PtcRunner.Research.SealedEvidenceLog.Format
  alias PtcRunner.Research.SealedEvidenceLog.Handle
  alias PtcRunner.Research.SealedEvidenceLog.Indexes
  alias PtcRunner.Research.SealedEvidenceLog.Limits

  @spec run(Handle.t(), Indexes.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def run(handle, indexes, trace_facts, limits, opts \\ [])
      when is_map(handle) and is_map(indexes) and is_map(trace_facts) and is_map(limits) and
             is_list(opts) do
    hook = Keyword.get(opts, :checkpoint_hook)
    mutate_hook = Keyword.get(opts, :during_admission_hook)
    timeout_ms = Keyword.get(opts, :deadline_ms, limits.admission_deadline_ms)
    owner = self()

    BoundedWorker.run(
      fn -> admit(handle, indexes, trace_facts, limits, hook, mutate_hook, owner) end,
      timeout_ms: timeout_ms,
      max_heap_words: Limits.heap_words(limits.admission_heap_bytes),
      cancel_with: owner
    )
    |> wrap_worker()
  end

  defp admit(handle, indexes, trace_facts, limits, hook, mutate_hook, owner) do
    checkpoints = Checkpoints.new()
    pids = [self(), owner]
    state = Assembler.new(indexes, limits)
    offset = Format.header_size()
    evidence_hash = :crypto.hash_init(:sha256)

    ctx = %{
      handle: handle,
      evidence_end: handle.footer.evidence_offset + handle.footer.evidence_bytes,
      hook: hook,
      pids: pids,
      limits: limits
    }

    with :ok <- maybe_hook(mutate_hook, :before_frames),
         :ok <- Handle.assert_stable(handle),
         {:ok, state, evidence_hash, checkpoints} <-
           stream_frames(ctx, state, offset, evidence_hash, checkpoints),
         :ok <- maybe_hook(mutate_hook, :after_frames),
         :ok <- Handle.assert_stable(handle),
         :ok <- verify_evidence_digest(handle, evidence_hash),
         {:ok, state} <- Assembler.finish(state, trace_facts),
         true <- Indexes.within_retained?(state.indexes, limits) do
      checkpoints = Checkpoints.record(checkpoints, :ets_inserted, pids)

      {:ok,
       %{
         indexes: state.indexes,
         run_id: state.run_id,
         trace_id: state.trace_id,
         record_count: state.record_count,
         turn_evidence: state.evidence,
         checkpoints: Checkpoints.finalize(checkpoints)
       }}
    else
      false ->
        Indexes.delete_all(indexes)
        Handle.close(handle)
        {:error, :max_retained_bytes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_frames(ctx, state, offset, evidence_hash, checkpoints) do
    cond do
      offset == ctx.evidence_end ->
        {:ok, state, evidence_hash, checkpoints}

      offset > ctx.evidence_end ->
        {:error, :malformed_source}

      state.record_count >= ctx.limits.max_records ->
        {:error, :max_records}

      true ->
        read_one_frame(ctx, state, offset, evidence_hash, checkpoints)
    end
  end

  defp read_one_frame(ctx, state, offset, evidence_hash, checkpoints) do
    with {:ok, <<length::unsigned-big-64>>} <- Handle.pread(ctx.handle, offset, 8),
         true <- length <= ctx.limits.max_record_bytes,
         payload_offset = offset + 8,
         true <- payload_offset + length <= ctx.evidence_end,
         {:ok, payload} <- Handle.pread(ctx.handle, payload_offset, length),
         evidence_hash <-
           :crypto.hash_update(evidence_hash, [<<length::unsigned-big-64>>, payload]),
         checkpoints <- Checkpoints.record(checkpoints, :decoded, ctx.pids),
         {:ok, record} <- Codec.decode_record(payload),
         digest <- :crypto.hash(:sha256, payload),
         {:ok, state} <- Assembler.ingest(state, record, payload_offset, length, digest) do
      _ = payload
      _ = record
      checkpoints = Checkpoints.record(checkpoints, :frame_released, ctx.pids)
      checkpoints = Checkpoints.record(checkpoints, :ets_inserted, ctx.pids)
      if is_function(ctx.hook, 1), do: ctx.hook.(:frame_released)

      stream_frames(ctx, state, payload_offset + length, evidence_hash, checkpoints)
    else
      false -> {:error, :limit_exceeded}
      {:error, :source_changed} -> {:error, :source_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_evidence_digest(handle, evidence_hash) do
    if :crypto.hash_final(evidence_hash) == handle.footer.evidence_sha256,
      do: :ok,
      else: {:error, :malformed_source}
  end

  defp maybe_hook(nil, _name), do: :ok
  defp maybe_hook(hook, name) when is_function(hook, 1), do: hook.(name)

  defp wrap_worker({:ok, result}), do: result
  defp wrap_worker({:error, :heap_exceeded}), do: {:error, :heap_exceeded}
  defp wrap_worker({:error, :timeout}), do: {:error, :deadline_exceeded}
  defp wrap_worker({:error, :cancelled}), do: {:error, :cancelled}
  defp wrap_worker({:error, reason}) when is_atom(reason), do: {:error, reason}
end
