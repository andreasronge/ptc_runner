defmodule PtcRunner.Kernel.InspectionArtifact.Admission do
  @moduledoc """
  One streaming ingest pass validates every complete frame, identities,
  sequences, lifecycle, joins, conversation facts, and paired trace claims;
  inserts bounded ETS rows; and releases each evidence payload before the next
  frame is read. After that ingest scan, seal confirmation rehashes evidence
  bytes without decoding records so a same-size overwrite cannot publish a
  snapshot. A caller that has already proven the artifact identity belongs to
  an isolated trace component may return `:run_isolated` at the trace-facts
  boundary; admission then returns the sealed frame indexes for disposal
  without materializing trace-dependent projections.
  """

  alias PtcRunner.Kernel.InspectionArtifact.Assembler
  alias PtcRunner.Kernel.InspectionArtifact.Codec
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.InspectionArtifact.Handle
  alias PtcRunner.Kernel.InspectionArtifact.Indexes
  alias PtcRunner.Kernel.InspectionRecord

  @spec run(
          Handle.t(),
          Indexes.t(),
          (binary(), binary() -> {:ok, map()} | {:error, atom()}),
          map(),
          keyword()
        ) ::
          {:ok, map()} | {:isolated, map()} | {:error, atom()}
  def run(handle, indexes, trace_facts, limits, opts \\ [])
      when is_map(handle) and is_map(indexes) and is_function(trace_facts, 2) and is_map(limits) and
             is_list(opts) do
    hook = Keyword.get(opts, :checkpoint_hook)
    mutate_hook = Keyword.get(opts, :during_admission_hook)
    identity = Keyword.get(opts, :expected_identity)
    admit(handle, indexes, trace_facts, limits, hook, mutate_hook, identity)
  end

  defp admit(handle, indexes, trace_facts, limits, hook, mutate_hook, identity) do
    state = Assembler.new(indexes, limits, identity)
    offset = Format.header_size()
    evidence_hash = :crypto.hash_init(:sha256)

    ctx = %{
      handle: handle,
      evidence_end: handle.footer.evidence_offset + handle.footer.evidence_bytes,
      hook: hook,
      limits: limits
    }

    with :ok <- maybe_hook(mutate_hook, :before_frames),
         :ok <- Handle.assert_stable(handle),
         {:ok, state, evidence_hash} <- stream_frames(ctx, state, offset, evidence_hash),
         :ok <- maybe_hook(mutate_hook, :after_frames),
         :ok <- Handle.assert_stable(handle),
         streamed <- :crypto.hash_final(evidence_hash),
         :ok <-
           Handle.confirm_seal(
             handle,
             streamed,
             %{
               record_count: state.record_count,
               first_sequence: state.first_sequence,
               last_sequence: state.last_sequence,
               run_id: state.run_id,
               trace_id: state.trace_id
             },
             limits.io_buffer_bytes
           ),
         :ok <- Handle.assert_stable(handle) do
      finish_admission(state, trace_facts)
    end
  end

  defp finish_admission(state, trace_facts) do
    case trace_facts.(state.run_id, state.trace_id) do
      {:ok, trace_facts} ->
        with {:ok, state} <- Assembler.finish(state, trace_facts) do
          {:ok,
           %{
             indexes: state.indexes,
             run_id: state.run_id,
             trace_id: state.trace_id,
             record_count: state.record_count,
             trace_facts: trace_facts,
             turn_evidence: state.evidence
           }}
        end

      {:error, :run_isolated} ->
        with :ok <- Assembler.validate_complete(state) do
          {:isolated,
           %{
             indexes: state.indexes,
             run_id: state.run_id,
             trace_id: state.trace_id,
             record_count: state.record_count
           }}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp stream_frames(ctx, state, offset, evidence_hash) do
    cond do
      offset == ctx.evidence_end ->
        {:ok, state, evidence_hash}

      offset > ctx.evidence_end ->
        {:error, :malformed_source}

      state.record_count >= ctx.limits.max_records ->
        {:error, :max_records}

      true ->
        read_one_frame(ctx, state, offset, evidence_hash)
    end
  end

  defp read_one_frame(ctx, state, offset, evidence_hash) do
    with {:ok, <<length::unsigned-big-64>>} <- Handle.pread(ctx.handle, offset, 8),
         payload_offset = offset + 8,
         :ok <- frame_bounds(length, payload_offset, ctx.evidence_end, ctx.limits),
         {:ok, payload} <- Handle.pread(ctx.handle, payload_offset, length),
         evidence_hash <-
           :crypto.hash_update(evidence_hash, [<<length::unsigned-big-64>>, payload]),
         {:ok, record} <- Codec.decode_record(payload),
         :ok <-
           InspectionRecord.validate(
             record,
             state.run_id,
             state.trace_id,
             state.record_count + 1
           ),
         digest <- :crypto.hash(:sha256, payload),
         {:ok, state} <- Assembler.ingest(state, record, payload_offset, length, digest) do
      _ = payload
      _ = record
      if is_function(ctx.hook, 1), do: ctx.hook.(:frame_released)

      stream_frames(ctx, state, payload_offset + length, evidence_hash)
    end
  end

  defp frame_bounds(length, _payload_offset, _evidence_end, limits)
       when length > limits.max_record_bytes,
       do: {:error, :source_limit_exceeded}

  defp frame_bounds(length, payload_offset, evidence_end, _limits) do
    if length <= evidence_end - payload_offset,
      do: :ok,
      else: {:error, :malformed_source}
  end

  defp maybe_hook(nil, _name), do: :ok
  defp maybe_hook(hook, name) when is_function(hook, 1), do: hook.(name)
  defp maybe_hook(hook, :before_frames) when is_function(hook, 0), do: hook.()
  defp maybe_hook(hook, _name) when is_function(hook, 0), do: :ok
end
