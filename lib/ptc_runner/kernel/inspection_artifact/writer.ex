defmodule PtcRunner.Kernel.InspectionArtifact.Writer do
  @moduledoc false

  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.InspectionRecord
  alias PtcRunner.Kernel.PublicationHandle

  @spec new(PublicationHandle.t(), binary(), binary(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def new(handle, run_id, trace_id, limits, opts \\ []) do
    header = Format.encode_header()
    hook = Keyword.get(opts, :writer_hook)

    with %PublicationHandle{kind: :inspection} <- handle,
         :ok <- checkpoint(hook, :before_header),
         {:ok, 0} <- PublicationHandle.append(handle, header),
         :ok <- checkpoint(hook, :after_header) do
      {:ok,
       %{
         handle: handle,
         run_id: run_id,
         trace_id: trace_id,
         limits: limits,
         hook: hook,
         evidence_hash: :crypto.hash_init(:sha256),
         artifact_hash: :crypto.hash_update(:crypto.hash_init(:sha256), header),
         evidence_bytes: 0,
         record_count: 0,
         sealed: nil
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :inspection_persistence_failed}
    end
  end

  @spec append(map(), binary(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def append(%{sealed: nil} = state, record_type, correlation, payload) do
    sequence = state.record_count + 1

    with true <- state.record_count < state.limits.max_records,
         {:ok, _record, encoded} <-
           InspectionRecord.build(
             state.run_id,
             state.trace_id,
             sequence,
             record_type,
             correlation,
             payload,
             state.limits.max_record_bytes
           ),
         length = byte_size(encoded),
         frame_bytes = length + 8,
         true <- state.evidence_bytes + frame_bytes <= state.limits.max_total_bytes,
         :ok <- checkpoint(state.hook, :before_frame),
         frame = [<<length::unsigned-big-64>>, encoded],
         expected_offset = Format.header_size() + state.evidence_bytes,
         {:ok, ^expected_offset} <- PublicationHandle.append(state.handle, frame),
         :ok <- checkpoint(state.hook, :after_frame) do
      {:ok,
       %{
         state
         | evidence_hash: :crypto.hash_update(state.evidence_hash, frame),
           artifact_hash: :crypto.hash_update(state.artifact_hash, frame),
           evidence_bytes: state.evidence_bytes + frame_bytes,
           record_count: sequence
       }}
    else
      false -> {:error, :inspection_limit_exceeded}
      {:error, :limit_exceeded} -> {:error, :inspection_limit_exceeded}
      {:error, :invalid_record} -> {:error, :invalid_record}
      {:error, _reason} = error -> error
      _other -> {:error, :inspection_persistence_failed}
    end
  end

  def append(_state, _record_type, _correlation, _payload),
    do: {:error, :inspection_persistence_failed}

  @spec seal(map()) :: {:ok, map(), map()} | {:error, atom()}
  def seal(%{sealed: nil} = state) do
    evidence_digest = :crypto.hash_final(state.evidence_hash)
    total_bytes = Format.header_size() + state.evidence_bytes + Format.footer_size()

    unsigned = %{
      total_bytes: total_bytes,
      evidence_offset: Format.header_size(),
      evidence_bytes: state.evidence_bytes,
      record_count: state.record_count,
      first_sequence: if(state.record_count == 0, do: 0, else: 1),
      last_sequence: state.record_count,
      run_id_sha256: Format.identity_sha256(state.run_id),
      trace_id_sha256: Format.identity_sha256(state.trace_id),
      evidence_sha256: evidence_digest,
      artifact_digest: <<0::256>>
    }

    digest =
      state.artifact_hash
      |> :crypto.hash_update(Format.unsigned_footer(unsigned))
      |> :crypto.hash_final()

    footer = Format.encode_footer(%{unsigned | artifact_digest: digest})

    file_digest =
      state.artifact_hash
      |> :crypto.hash_update(footer)
      |> :crypto.hash_final()

    expected_offset = Format.header_size() + state.evidence_bytes

    with :ok <- checkpoint(state.hook, :before_footer),
         {:ok, ^expected_offset} <- PublicationHandle.append(state.handle, footer),
         :ok <- checkpoint(state.hook, :after_footer),
         :ok <- PublicationHandle.sync(state.handle),
         :ok <- checkpoint(state.hook, :after_sync) do
      seal = %{
        artifact_digest: digest,
        file_digest: file_digest,
        evidence_bytes: state.evidence_bytes,
        record_count: state.record_count,
        total_bytes: total_bytes
      }

      {:ok, seal, %{state | sealed: seal}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :inspection_persistence_failed}
    end
  end

  def seal(%{sealed: seal} = state) when is_map(seal), do: {:ok, seal, state}
  def seal(_state), do: {:error, :inspection_persistence_failed}

  defp checkpoint(nil, _stage), do: :ok

  defp checkpoint(hook, stage) do
    if hook.(stage) == :ok, do: :ok, else: {:error, :inspection_persistence_failed}
  rescue
    _exception -> {:error, :inspection_persistence_failed}
  catch
    _kind, _reason -> {:error, :inspection_persistence_failed}
  end
end
