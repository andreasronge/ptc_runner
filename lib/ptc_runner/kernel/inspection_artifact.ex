defmodule PtcRunner.Kernel.InspectionArtifact do
  @moduledoc """
  Persists and loads one immutable private inspection JSONL artifact.

  Destinations must end in `.inspection.jsonl`, must not already exist, and are
  installed atomically with a hard-link create from an exclusive temporary
  sibling whose permissions are restricted to `0600` before content is
  written. The create fails when the destination already exists; unlike a
  rename, it cannot replace an existing artifact. Loading rejects symlinks,
  changed files, content above 16 MB, any record above 2,000,000 encoded bytes,
  malformed lines, mixed identities, non-contiguous sequences, and records
  outside the exact V1 vocabulary.
  """

  alias Jason.OrderedObject

  @max_bytes 16_000_000
  @max_record_bytes 2_000_000
  @suffix ".inspection.jsonl"
  @record_types ~w(capability-input capability-output evaluation-source prelude-source)
  @envelope_keys ~w(schema_version run_id trace_id sequence timestamp record_type correlation payload)

  @spec preflight_destination(term()) ::
          :ok
          | {:error,
             :invalid_inspection_path
             | :inspection_destination_exists
             | :inspection_destination_unavailable}
  @doc """
  Read-only destination preflight using the same path rules as `persist/3`.

  Classifies common deterministic conflicts — an invalid path or suffix, an
  existing file, symlink, or directory, or an unreadable location — before
  expensive work such as provider discovery or model calls begins. It never
  authorizes overwrite: a destination can appear after this check, so
  `persist/3`'s exclusive atomic creation remains authoritative, and a free
  preflight does not promise the destination stays creatable.
  """
  def preflight_destination(path) when is_binary(path) do
    with :ok <- valid_path(path) do
      case File.lstat(path) do
        {:ok, _stat} -> {:error, :inspection_destination_exists}
        {:error, :enoent} -> :ok
        {:error, _reason} -> {:error, :inspection_destination_unavailable}
      end
    end
  end

  def preflight_destination(_path), do: {:error, :invalid_inspection_path}

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
  @doc "Loads one exact fixed artifact with optional lower aggregate and per-record limits."
  def load(path, opts \\ [])

  def load(path, opts) when is_binary(path) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    max_record_bytes = Keyword.get(opts, :max_record_bytes, @max_record_bytes)

    with true <- Keyword.keys(opts) -- [:max_bytes, :max_record_bytes] == [],
         true <- is_integer(max_bytes) and max_bytes > 0 and max_bytes <= @max_bytes,
         true <-
           is_integer(max_record_bytes) and max_record_bytes > 0 and
             max_record_bytes <= @max_record_bytes,
         :ok <- valid_path(path),
         {:ok, before} <- regular_file(path),
         :ok <- within_limit(before, max_bytes),
         {:ok, content} <- File.read(path),
         {:ok, after_read} <- regular_file(path),
         :ok <- unchanged(before, after_read),
         {:ok, records} <- decode(content, max_record_bytes),
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
        {:ok, line} when byte_size(line) + 1 <= @max_record_bytes ->
          {:cont, {:ok, [line | lines]}}

        {:ok, _line} ->
          {:halt, {:error, :inspection_source_limit_exceeded}}

        {:error, _reason} ->
          {:halt, {:error, :invalid_inspection_artifact}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.map_join("", &(&1 <> "\n"))}
      error -> error
    end
  end

  defp decode(content, max_record_bytes) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, records} ->
      if byte_size(line) + 1 <= max_record_bytes do
        case decode_line(line) do
          {:ok, record} when is_map(record) -> {:cont, {:ok, [record | records]}}
          _error -> {:halt, {:error, :malformed_inspection_artifact}}
        end
      else
        {:halt, {:error, :inspection_source_limit_exceeded}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp decode_line(line) do
    with {:ok, decoded} <- Jason.decode(line, objects: :ordered_objects),
         do: ordered_value(decoded)
  end

  defp ordered_value(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
        case ordered_value(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(normalized, key, value)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_inspection_key}
    end
  end

  defp ordered_value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case ordered_value(value) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_value(value), do: {:ok, value}

  defp validate_records([]), do: {:error, :invalid_inspection_artifact}

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

  defp valid_shape?(%{
         "record_type" => "prelude-source",
         "correlation" => %{"component_id" => id},
         "payload" => payload
       }) do
    exact_keys?(payload, ~w(environment source source_hash source_bytes)) and
      valid_id?(id) and payload["environment"] in ["workflow", "mission"] and
      is_binary(payload["source"]) and
      payload["source_bytes"] == byte_size(payload["source"]) and
      payload["source_hash"] == sha256(payload["source"])
  end

  defp valid_shape?(_record), do: false

  @spec validate_correlations([map()], [map()]) :: :ok | {:error, :inspection_correlation_missing}
  @doc "Validates every record identity and correlation against one canonical event set."
  def validate_correlations([first | _rest] = records, events) do
    events =
      Enum.filter(events, fn event ->
        event_value(event, :run_id) == first["run_id"] and
          event_value(event, :trace_id) == first["trace_id"]
      end)

    capability_ids =
      events
      |> Enum.map(&event_data(&1, :capability_id))
      |> MapSet.new()

    evaluations =
      Enum.reduce(events, %{}, fn event, evaluations ->
        id = event_data(event, :evaluation_id)
        hash = event_data(event, :source_hash)
        bytes = event_data(event, :source_bytes)

        if is_binary(id) and is_binary(hash) and is_integer(bytes),
          do: Map.put(evaluations, id, {hash, bytes}),
          else: evaluations
      end)

    prelude_components =
      Enum.reduce(events, %{}, fn event, acc ->
        acc
        |> merge_prelude_ids("workflow", event_data(event, :workflow_prelude))
        |> merge_prelude_ids("mission", event_data(event, :mission_prelude))
      end)

    if Enum.all?(records, fn
         %{"correlation" => %{"capability_id" => id}} ->
           MapSet.member?(capability_ids, id)

         %{
           "correlation" => %{"evaluation_id" => id},
           "payload" => %{"source_hash" => hash, "source_bytes" => bytes}
         } ->
           Map.get(evaluations, id) == {hash, bytes}

         %{
           "correlation" => %{"component_id" => id},
           "payload" => %{"environment" => environment}
         } ->
           MapSet.member?(Map.get(prelude_components, environment, MapSet.new()), id)
       end),
       do: :ok,
       else: {:error, :inspection_correlation_missing}
  end

  def validate_correlations(_records, _events), do: {:error, :inspection_correlation_missing}

  defp merge_prelude_ids(acc, environment, prelude) when is_map(prelude) do
    ids =
      (Map.get(prelude, :component_ids) || Map.get(prelude, "component_ids") || [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    Map.update(acc, environment, MapSet.new(ids), &MapSet.union(&1, MapSet.new(ids)))
  end

  defp merge_prelude_ids(acc, _environment, _prelude), do: acc

  defp event_value(event, key), do: Map.get(event, key) || Map.get(event, Atom.to_string(key))

  defp event_data(event, key) do
    case event_value(event, :data) do
      data when is_map(data) -> Map.get(data, key) || Map.get(data, Atom.to_string(key))
      _data -> nil
    end
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
