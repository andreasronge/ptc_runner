defmodule PtcRunner.Kernel.InspectionArtifact do
  @moduledoc """
  Persists and loads one immutable private inspection JSONL artifact.

  Destinations must end in `.inspection.jsonl`, must not already exist, and are
  installed atomically from an exclusive temporary sibling whose permissions
  are restricted to `0600` before content is written. Loading rejects symlinks,
  changed files, oversized content, malformed lines, mixed identities,
  non-contiguous sequences, and records outside the exact V1 vocabulary.
  """

  @max_bytes 16_000_000
  @suffix ".inspection.jsonl"
  @record_types ~w(capability-input capability-output evaluation-source)
  @envelope_keys ~w(schema_version run_id trace_id sequence timestamp record_type correlation payload)

  @spec persist(binary(), [map()], [map()]) :: :ok | {:error, atom()}
  @doc "Validates and atomically persists one previously absent artifact."
  def persist(path, records, canonical_events)
      when is_binary(path) and is_list(records) and is_list(canonical_events) do
    with :ok <- valid_path(path),
         false <- File.exists?(path),
         :ok <- validate_records(records),
         :ok <- validate_correlations(records, canonical_events),
         {:ok, encoded} <- encode(records),
         true <- byte_size(encoded) <= @max_bytes,
         :ok <- persist_new(path, encoded) do
      :ok
    else
      true -> {:error, :inspection_destination_exists}
      false -> {:error, :invalid_inspection_artifact}
      {:error, _reason} = error -> error
      _reason -> {:error, :invalid_inspection_artifact}
    end
  end

  def persist(_path, _records, _events), do: {:error, :invalid_inspection_artifact}

  @spec load(binary(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  @doc "Loads one exact fixed artifact with optional lower `:max_bytes`."
  def load(path, opts \\ [])

  def load(path, opts) when is_binary(path) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    with true <- Keyword.keys(opts) -- [:max_bytes] == [],
         true <- is_integer(max_bytes) and max_bytes > 0 and max_bytes <= @max_bytes,
         :ok <- valid_path(path),
         {:ok, before} <- regular_file(path),
         :ok <- within_limit(before, max_bytes),
         {:ok, content} <- File.read(path),
         {:ok, after_read} <- regular_file(path),
         :ok <- unchanged(before, after_read),
         {:ok, records} <- decode(content),
         :ok <- validate_records(records) do
      {:ok, records}
    else
      false -> {:error, :inspection_source_limit_exceeded}
      {:error, _reason} = error -> error
      _reason -> {:error, :invalid_inspection_artifact}
    end
  end

  def load(_path, _opts), do: {:error, :invalid_inspection_artifact}

  defp valid_path(path) do
    if String.valid?(path) and String.ends_with?(path, @suffix),
      do: :ok,
      else: {:error, :invalid_inspection_path}
  end

  defp encode(records) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, lines} ->
      case Jason.encode(record) do
        {:ok, line} -> {:cont, {:ok, [line | lines]}}
        {:error, _reason} -> {:halt, {:error, :invalid_inspection_artifact}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.map_join("", &(&1 <> "\n"))}
      error -> error
    end
  end

  defp decode(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, records} ->
      case Jason.decode(line) do
        {:ok, record} when is_map(record) -> {:cont, {:ok, [record | records]}}
        _error -> {:halt, {:error, :malformed_inspection_artifact}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp validate_records([]), do: {:error, :empty_inspection_artifact}

  defp validate_records([first | _rest] = records) do
    run_id = first["run_id"]
    trace_id = first["trace_id"]

    records
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {record, sequence}, :ok ->
      if valid_record?(record, run_id, trace_id, sequence),
        do: {:cont, :ok},
        else: {:halt, {:error, :invalid_inspection_artifact}}
    end)
  end

  defp valid_record?(record, run_id, trace_id, sequence) do
    is_map(record) and Map.keys(record) |> Enum.sort() == Enum.sort(@envelope_keys) and
      record["schema_version"] == 1 and record["run_id"] == run_id and
      record["trace_id"] == trace_id and is_binary(run_id) and is_binary(trace_id) and
      record["sequence"] == sequence and valid_timestamp?(record["timestamp"]) and
      record["record_type"] in @record_types and valid_shape?(record)
  end

  defp valid_shape?(%{
         "record_type" => "capability-input",
         "correlation" => %{"capability_id" => id},
         "payload" => payload
       }),
       do:
         valid_id?(id) and exact_keys?(payload, ~w(environment name arguments)) and
           valid_capability_payload?(payload, "arguments")

  defp valid_shape?(%{
         "record_type" => "capability-output",
         "correlation" => %{"capability_id" => id},
         "payload" => payload
       }),
       do:
         valid_id?(id) and exact_keys?(payload, ~w(environment name result)) and
           valid_capability_payload?(payload, "result")

  defp valid_shape?(%{
         "record_type" => "evaluation-source",
         "correlation" => %{"evaluation_id" => id},
         "payload" => payload
       }) do
    exact_keys?(payload, ~w(environment program_kind source source_hash source_bytes)) and
      valid_id?(id) and payload["environment"] == "mission" and
      payload["program_kind"] == "ptc-lisp" and is_binary(payload["source"]) and
      payload["source_bytes"] == byte_size(payload["source"]) and
      payload["source_hash"] == sha256(payload["source"])
  end

  defp valid_shape?(_record), do: false

  defp validate_correlations(records, events) do
    capability_ids =
      events
      |> Enum.flat_map(fn event ->
        [get_in(event, [:data, :capability_id]), get_in(event, ["data", "capability_id"])]
      end)
      |> MapSet.new()

    evaluation_ids =
      events
      |> Enum.flat_map(fn event ->
        [get_in(event, [:data, :evaluation_id]), get_in(event, ["data", "evaluation_id"])]
      end)
      |> MapSet.new()

    if Enum.all?(records, fn
         %{"correlation" => %{"capability_id" => id}} -> MapSet.member?(capability_ids, id)
         %{"correlation" => %{"evaluation_id" => id}} -> MapSet.member?(evaluation_ids, id)
       end),
       do: :ok,
       else: {:error, :inspection_correlation_missing}
  end

  defp persist_new(path, encoded) do
    temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    persist_temporary(path, temporary, encoded)
  end

  defp persist_temporary(path, temporary, encoded) do
    with {:ok, :ok} <-
           File.open(temporary, [:write, :binary, :exclusive], fn device ->
             case File.chmod(temporary, 0o600) do
               :ok -> IO.binwrite(device, encoded)
               {:error, _reason} = error -> error
             end
           end),
         :ok <- File.ln(temporary, path),
         :ok <- File.rm(temporary) do
      :ok
    else
      {:error, :eexist} -> {:error, :inspection_destination_exists}
      {:error, _reason} -> {:error, :inspection_persistence_failed}
    end
  after
    _ = File.rm(temporary)
  end

  defp regular_file(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, _stat} -> {:error, :invalid_inspection_source}
      {:error, _reason} -> {:error, :inspection_source_unavailable}
    end
  end

  defp stable?(before, after_read),
    do:
      before.size == after_read.size and before.mtime == after_read.mtime and
        before.inode == after_read.inode

  defp unchanged(before, after_read) do
    if stable?(before, after_read), do: :ok, else: {:error, :inspection_source_changed}
  end

  defp within_limit(stat, max_bytes) do
    if stat.size <= max_bytes, do: :ok, else: {:error, :inspection_source_limit_exceeded}
  end

  defp exact_keys?(map, keys),
    do: is_map(map) and Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp valid_capability_payload?(payload, value_key) do
    payload["environment"] in ["workflow", "mission"] and
      valid_id?(payload["name"]) and is_map(payload[value_key])
  end

  defp valid_timestamp?(timestamp) when is_binary(timestamp),
    do: match?({:ok, _datetime, 0}, DateTime.from_iso8601(timestamp))

  defp valid_timestamp?(_timestamp), do: false
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
