defmodule PtcRunner.TestSupport.StreamingInspection do
  @moduledoc false

  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionArtifact.Codec
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.PublicationHandle

  @registry __MODULE__.Registry

  def start(opts) when is_list(opts) do
    ensure_registry()
    directory = Path.join(System.tmp_dir!(), "ptc-streaming-inspection-#{unique_id()}")
    path = Path.join(directory, "artifact.ptcins")
    :ok = File.mkdir(directory)
    :ok = File.chmod(directory, 0o700)

    with {:ok, handle} <- PublicationHandle.reserve_stream_for(path, :inspection, 0o600, self()),
         {:ok, sink} <- InspectionSink.start(Keyword.put(opts, :publication_handle, handle)) do
      true = :ets.insert(@registry, {sink.pid, handle, directory})
      {:ok, sink}
    end
  end

  def start(_opts), do: {:error, :invalid_inspection_sink}

  def records(%InspectionSink{pid: pid} = sink) do
    with [{^pid, handle, _directory}] <- :ets.lookup(@registry, pid),
         {:ok, _seal} <- InspectionSink.seal(sink),
         {:ok, bytes} <- File.read(handle.staging_path) do
      decode_records(bytes)
    else
      _invalid -> {:error, :inspection_sink_error}
    end
  end

  def records(_sink), do: {:error, :inspection_sink_error}

  def read_path(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path), do: decode_records(bytes)
  end

  def rewrite_path(path, records) when is_binary(path) and is_list(records) do
    replacement = path <> ".rewrite-#{unique_id()}.ptcins"
    :ok = write_path(replacement, records)
    :ok = File.rename(replacement, path)
  end

  def write_path(path, [first | _rest] = records) when is_binary(path) do
    with {:ok, handle} <-
           PublicationHandle.reserve_stream_for(path, :inspection, 0o600, self()),
         {:ok, sink} <-
           InspectionSink.start(
             run_id: first["run_id"],
             trace_id: first["trace_id"],
             publication_handle: handle
           ) do
      result =
        with :ok <- emit_all(sink, records),
             {:ok, seal} <- InspectionSink.seal(sink),
             do: InspectionArtifact.publish_handle(handle, seal)

      InspectionSink.stop(sink)
      result
    end
  end

  def write_path(_path, _records), do: {:error, :invalid_inspection_artifact}

  defp emit_all(sink, records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case InspectionSink.emit(
             sink,
             record["record_type"],
             record["correlation"],
             record["payload"]
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_records(bytes) do
    evidence_bytes = byte_size(bytes) - Format.header_size() - Format.footer_size()

    <<_header::binary-size(16), evidence::binary-size(^evidence_bytes),
      _footer::binary-size(192)>> =
      bytes

    decode_frames(evidence, [])
  end

  defp decode_frames(<<>>, records), do: {:ok, Enum.reverse(records)}

  defp decode_frames(
         <<length::unsigned-big-64, payload::binary-size(length), rest::binary>>,
         records
       ) do
    with {:ok, record} <- Codec.decode_record(payload) do
      decode_frames(rest, [record | records])
    end
  end

  defp ensure_registry do
    case :ets.whereis(@registry) do
      :undefined ->
        try do
          :ets.new(@registry, [
            :named_table,
            :public,
            :set,
            {:heir, Process.whereis(:init), :test_registry},
            read_concurrency: true
          ])
        rescue
          ArgumentError -> @registry
        end

      tid ->
        tid
    end
  end

  defp unique_id,
    do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
