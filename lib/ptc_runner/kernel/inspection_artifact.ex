defmodule PtcRunner.Kernel.InspectionArtifact do
  @moduledoc """
  Persists and loads one immutable private inspection JSONL artifact.

  Destinations must end in `.inspection.jsonl`, must not already exist, and are
  installed atomically with a hard-link create from a file inside a mode-0700
  temporary sibling directory. The file is restricted to `0600` before
  content is written or the hard link is published. The create fails when the
  destination already exists; unlike a rename, it cannot replace an existing
  artifact. Temporary cleanup after the link is best-effort and cannot turn a
  committed publication into a reported failure. A relative destination is
  anchored once before validation so a VM-wide working-directory change cannot
  redirect later filesystem operations. Loading opens a raw descriptor,
  revalidates its identity, and performs two exact whole-file reads through EOF
  whose bytes must match. It rejects symlinks,
  changed files, content above 16 MB, any record above 2,000,000 encoded bytes,
  excessive structural depth, malformed lines, mixed identities or schema
  versions, non-contiguous sequences, and records outside the exact V1 or V2
  vocabulary. V2 adds paired MCP request/response bodies correlated to an
  existing capability attempt.

  Secure publication is supported on Unix hosts with POSIX-compatible `mkdir`
  and `id` executables available on `PATH`; persistence fails closed when those
  authority/mode primitives are unavailable, a physical or lexical ancestor
  has an untrusted owner, or any ancestor is group/other-writable without
  sticky-directory protection. Preflight also rejects a final parent whose
  effective permission class lacks create access. The same structural-depth
  ceiling applies before in-memory retention, persistence, and loading.
  """

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.PrivateDirectory

  @max_bytes 16_000_000
  @max_record_bytes 2_000_000
  @suffix ".inspection.jsonl"
  @record_types_v1 ~w(capability-input capability-output evaluation-source prelude-source)
  @record_types_v2 @record_types_v1 ++ ~w(mcp-request mcp-response)
  @envelope_keys ~w(schema_version run_id trace_id sequence timestamp record_type correlation payload)

  @spec preflight_destination(term()) ::
          :ok
          | {:error,
             :invalid_inspection_path
             | :inspection_destination_exists
             | :inspection_destination_unavailable
             | :inspection_destination_unsafe
             | :inspection_persistence_failed}
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
    with :ok <- valid_path(path),
         {:ok, path} <- anchor_path(path, :invalid_inspection_path) do
      preflight_anchored(path)
    end
  end

  def preflight_destination(_path), do: {:error, :invalid_inspection_path}

  @spec persist(binary(), [map()], [map()]) :: :ok | {:error, atom()}
  @doc "Validates and atomically persists one previously absent artifact."
  def persist(path, records, canonical_events)
      when is_binary(path) and is_list(records) and is_list(canonical_events) do
    persist(path, records, canonical_events, nil)
  end

  def persist(_path, _records, _events), do: {:error, :invalid_inspection_artifact}

  @doc false
  @spec persist(binary(), [map()], [map()], nil | (atom() -> term())) ::
          :ok | {:error, atom()}
  def persist(path, records, canonical_events, fault_hook)
      when is_binary(path) and is_list(records) and is_list(canonical_events) do
    with true <- is_nil(fault_hook) or is_function(fault_hook, 1),
         :ok <- valid_path(path),
         {:ok, path} <- anchor_path(path, :invalid_inspection_artifact),
         false <- File.exists?(path),
         :ok <- validate_records(records),
         :ok <- validate_correlations(records, canonical_events),
         {:ok, encoded} <- encode(records),
         true <- byte_size(encoded) <= @max_bytes,
         :ok <- persist_new(path, encoded, fault_hook) do
      :ok
    else
      true -> {:error, :inspection_destination_exists}
      false -> {:error, :invalid_inspection_artifact}
      {:error, _reason} = error -> error
      _reason -> {:error, :invalid_inspection_artifact}
    end
  end

  def persist(_path, _records, _events, _fault_hook),
    do: {:error, :invalid_inspection_artifact}

  defp anchor_path(path, error) do
    case PrivateDirectory.anchor(path) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, error}
    end
  end

  defp preflight_anchored(path) do
    case File.lstat(path) do
      {:ok, _stat} -> {:error, :inspection_destination_exists}
      {:error, :enoent} -> preflight_private_directory(path)
      {:error, _reason} -> {:error, :inspection_destination_unavailable}
    end
  end

  @spec load(binary(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  @doc "Loads one exact fixed artifact with optional lower aggregate and per-record limits."
  def load(path, opts \\ [])

  def load(path, opts) when is_binary(path) and is_list(opts) do
    load(path, opts, nil)
  end

  def load(_path, _opts), do: {:error, :invalid_inspection_artifact}

  @doc false
  @spec load(binary(), keyword(), nil | (-> term())) ::
          {:ok, [map()]} | {:error, atom()}
  def load(path, opts, verification_hook)
      when is_binary(path) and is_list(opts) and
             (is_nil(verification_hook) or is_function(verification_hook, 0)) do
    load(path, opts, verification_hook, &:file.read/2)
  end

  def load(_path, _opts, _verification_hook), do: {:error, :invalid_inspection_artifact}

  @doc false
  @spec load(binary(), keyword(), nil | (-> term()), (:file.io_device(), non_neg_integer() ->
                                                        {:ok, binary()} | :eof | {:error, term()})) ::
          {:ok, [map()]} | {:error, atom()}
  def load(path, opts, verification_hook, reader)
      when is_binary(path) and is_list(opts) and
             (is_nil(verification_hook) or is_function(verification_hook, 0)) and
             is_function(reader, 2) do
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
         {:ok, content, opened} <-
           read_regular_file(path, before, max_bytes, verification_hook, reader),
         {:ok, after_read} <- regular_file(path),
         :ok <- unchanged(before, opened),
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

  def load(_path, _opts, _verification_hook, _reader),
    do: {:error, :invalid_inspection_artifact}

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
    with true <- MCPProtocol.within_inspection_document_depth?(line),
         {:ok, decoded} <- Jason.decode(line, objects: :ordered_objects),
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
    schema_version = first["schema_version"]

    result =
      records
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {record, sequence}, :ok ->
        if valid_record?(record, run_id, trace_id, schema_version, sequence),
          do: {:cont, :ok},
          else: {:halt, {:error, :invalid_inspection_artifact}}
      end)

    case result do
      :ok -> validate_record_set(records)
      {:error, _reason} = error -> error
    end
  end

  defp validate_record_set(records) do
    initial = %{
      inputs: %{},
      outputs: MapSet.new(),
      mcp_requests: %{},
      mcp_responses: MapSet.new(),
      evaluations: MapSet.new(),
      preludes: MapSet.new()
    }

    records
    |> Enum.reduce_while({:ok, initial}, fn record, {:ok, state} ->
      validate_record_join(record, state)
    end)
    |> case do
      {:ok, state} ->
        if Map.keys(state.mcp_requests) |> MapSet.new() == state.mcp_responses,
          do: :ok,
          else: {:error, :invalid_inspection_artifact}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_record_join(
         %{
           "record_type" => "capability-input",
           "correlation" => %{"capability_id" => id},
           "payload" => %{"environment" => environment, "name" => name}
         },
         state
       ) do
    if Map.has_key?(state.inputs, id),
      do: invalid_record_join(),
      else: {:cont, {:ok, put_in(state, [:inputs, id], {environment, name})}}
  end

  defp validate_record_join(
         %{
           "record_type" => "capability-output",
           "correlation" => %{"capability_id" => id},
           "payload" => %{"environment" => environment, "name" => name}
         },
         state
       ) do
    if Map.get(state.inputs, id) == {environment, name} and
         not MapSet.member?(state.outputs, id),
       do: {:cont, {:ok, %{state | outputs: MapSet.put(state.outputs, id)}}},
       else: invalid_record_join()
  end

  defp validate_record_join(
         %{
           "record_type" => "mcp-request",
           "correlation" => %{"capability_id" => capability_id, "request_id" => request_id},
           "payload" => %{"transport" => transport}
         },
         state
       ) do
    key = {capability_id, request_id}

    if Map.has_key?(state.inputs, capability_id) and
         not Map.has_key?(state.mcp_requests, key),
       do: {:cont, {:ok, put_in(state, [:mcp_requests, key], transport)}},
       else: invalid_record_join()
  end

  defp validate_record_join(
         %{
           "record_type" => "mcp-response",
           "correlation" => %{"capability_id" => capability_id, "request_id" => request_id},
           "payload" => %{"transport" => transport}
         },
         state
       ) do
    key = {capability_id, request_id}

    if Map.get(state.mcp_requests, key) == transport and
         not MapSet.member?(state.mcp_responses, key),
       do: {:cont, {:ok, %{state | mcp_responses: MapSet.put(state.mcp_responses, key)}}},
       else: invalid_record_join()
  end

  defp validate_record_join(
         %{"record_type" => "evaluation-source", "correlation" => %{"evaluation_id" => id}},
         state
       ),
       do: unique_record(state, :evaluations, id)

  defp validate_record_join(
         %{
           "record_type" => "prelude-source",
           "correlation" => %{"component_id" => id},
           "payload" => %{"environment" => environment}
         },
         state
       ),
       do: unique_record(state, :preludes, {environment, id})

  defp invalid_record_join, do: {:halt, {:error, :invalid_inspection_artifact}}

  defp unique_record(state, field, key) do
    seen = Map.fetch!(state, field)

    if MapSet.member?(seen, key) do
      invalid_record_join()
    else
      {:cont, {:ok, Map.put(state, field, MapSet.put(seen, key))}}
    end
  end

  defp valid_record?(record, run_id, trace_id, schema_version, sequence) do
    MCPProtocol.within_inspection_document_depth?(record) and
      is_map(record) and Map.keys(record) |> Enum.sort() == Enum.sort(@envelope_keys) and
      schema_version in [1, 2] and record["schema_version"] == schema_version and
      record["run_id"] == run_id and
      record["trace_id"] == trace_id and is_binary(run_id) and is_binary(trace_id) and
      record["sequence"] == sequence and valid_timestamp?(record["timestamp"]) and
      record["record_type"] in record_types(schema_version) and valid_shape?(record)
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
         "record_type" => "mcp-request",
         "correlation" =>
           %{"capability_id" => capability_id, "request_id" => request_id} =
             correlation,
         "payload" => payload
       }) do
    exact_keys?(correlation, ~w(capability_id request_id)) and
      exact_keys?(payload, ~w(transport body)) and valid_id?(capability_id) and
      valid_request_id?(request_id) and payload["transport"] in ["stdio", "streamable_http"] and
      MCPProtocol.valid_exchange_request?(payload["body"], request_id)
  end

  defp valid_shape?(%{
         "record_type" => "mcp-response",
         "correlation" =>
           %{"capability_id" => capability_id, "request_id" => request_id} =
             correlation,
         "payload" => payload
       }) do
    exact_keys?(correlation, ~w(capability_id request_id)) and
      exact_keys?(payload, ~w(transport body)) and valid_id?(capability_id) and
      valid_request_id?(request_id) and payload["transport"] in ["stdio", "streamable_http"] and
      MCPProtocol.valid_exchange_response?(payload["body"], request_id)
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

    with {:ok, capabilities} <- canonical_capabilities(events) do
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
           %{
             "correlation" => %{"capability_id" => id},
             "payload" => %{"environment" => environment, "name" => name}
           } ->
             Map.get(capabilities, id) == {environment, name}

           %{
             "record_type" => record_type,
             "correlation" => %{"capability_id" => id, "request_id" => request_id}
           }
           when record_type in ["mcp-request", "mcp-response"] ->
             Map.has_key?(capabilities, id) and valid_request_id?(request_id)

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
  end

  def validate_correlations(_records, _events), do: {:error, :inspection_correlation_missing}

  defp canonical_capabilities(events) do
    Enum.reduce_while(events, {:ok, %{}}, fn event, {:ok, capabilities} ->
      id = event_data(event, :capability_id)
      environment = event_data(event, :environment) |> string_value()
      name = event_data(event, :name)

      cond do
        event_value(event, :type) != "capability-started" or not is_binary(id) or
          environment not in ["workflow", "mission"] or not is_binary(name) ->
          {:cont, {:ok, capabilities}}

        Map.has_key?(capabilities, id) ->
          {:halt, {:error, :inspection_correlation_missing}}

        true ->
          {:cont, {:ok, Map.put(capabilities, id, {environment, name})}}
      end
    end)
  end

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

  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: nil

  defp persist_new(path, encoded, fault_hook) do
    {temporary_directory, temporary} = PrivateDirectory.temporary_sibling(path, "artifact")
    persist_temporary(path, temporary_directory, temporary, encoded, fault_hook)
  end

  defp persist_temporary(path, temporary_directory, temporary, encoded, fault_hook) do
    case PrivateDirectory.create(temporary_directory) do
      :ok ->
        persist_created(path, temporary_directory, temporary, encoded, fault_hook)

      {:error, _reason} ->
        {:error, :inspection_persistence_failed}
    end
  end

  defp persist_created(path, temporary_directory, temporary, encoded, fault_hook) do
    with {:ok, :ok} <- write_private_file(temporary, encoded, fault_hook),
         :ok <- File.ln(temporary, path) do
      :ok
    else
      {:error, :eexist} -> {:error, :inspection_destination_exists}
      {:error, _reason} -> {:error, :inspection_persistence_failed}
    end
  after
    _ = File.rm(temporary)
    _ = File.rmdir(temporary_directory)
  end

  # An untrusted ancestor names a directory the operator can go fix; a missing
  # `mkdir`/`id` does not. They are reported apart rather than both arriving as
  # a bare persistence failure.
  defp preflight_private_directory(path) do
    case PrivateDirectory.preflight(path) do
      :ok ->
        :ok

      {:error, :private_directory_parent_unavailable} ->
        {:error, :inspection_destination_unavailable}

      {:error, :private_directory_parent_unsafe} ->
        {:error, :inspection_destination_unsafe}

      {:error, _reason} ->
        {:error, :inspection_persistence_failed}
    end
  end

  defp write_private_file(path, encoded, fault_hook) do
    case File.open(path, [:write, :binary, :exclusive], fn device ->
           with :ok <- persistence_fault(fault_hook, :before_chmod),
                :ok <- File.chmod(path, 0o600),
                :ok <- persistence_fault(fault_hook, :before_write) do
             IO.binwrite(device, encoded)
           end
         end) do
      {:ok, :ok} = success -> success
      {:ok, {:error, _reason}} -> {:error, :inspection_persistence_failed}
      {:error, _reason} = error -> error
      _unexpected -> {:error, :inspection_persistence_failed}
    end
  end

  defp persistence_fault(nil, _stage), do: :ok

  defp persistence_fault(fault_hook, stage) do
    case fault_hook.(stage) do
      :ok -> :ok
      _failure -> {:error, :inspection_persistence_failed}
    end
  rescue
    _exception -> {:error, :inspection_persistence_failed}
  catch
    _kind, _reason -> {:error, :inspection_persistence_failed}
  end

  defp regular_file(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, _stat} -> {:error, :invalid_inspection_source}
      {:error, _reason} -> {:error, :inspection_source_unavailable}
    end
  end

  defp read_regular_file(path, expected, max_bytes, verification_hook, reader) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          with {:ok, info} <- :file.read_file_info(device, time: :posix),
               opened = File.Stat.from_record(info),
               :ok <- same_file(expected, opened),
               :ok <- within_limit(opened, max_bytes),
               {:ok, content} <- read_exact(device, opened.size, reader),
               :ok <- run_verification_hook(verification_hook),
               {:ok, 0} <- :file.position(device, :bof),
               {:ok, verification} <- read_exact(device, opened.size, reader),
               true <- verification == content,
               {:ok, after_info} <- :file.read_file_info(device, time: :posix),
               after_read = File.Stat.from_record(after_info),
               :ok <- unchanged(opened, after_read) do
            {:ok, content, opened}
          else
            false -> {:error, :inspection_source_changed}
            {:error, _reason} = error -> error
          end
        after
          :file.close(device)
        end

      {:error, _reason} ->
        {:error, :inspection_source_unavailable}
    end
  end

  defp run_verification_hook(nil), do: :ok

  defp run_verification_hook(verification_hook) do
    case verification_hook.() do
      :ok -> :ok
      _other -> {:error, :inspection_source_unavailable}
    end
  rescue
    _exception -> {:error, :inspection_source_unavailable}
  catch
    _kind, _reason -> {:error, :inspection_source_unavailable}
  end

  defp read_exact(device, expected_bytes, reader),
    do: read_exact(device, expected_bytes, reader, [])

  defp read_exact(device, 0, reader, chunks) do
    case reader.(device, 1) do
      :eof -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {:ok, _unexpected} -> {:error, :inspection_source_changed}
      {:error, _reason} -> {:error, :inspection_source_unavailable}
    end
  end

  defp read_exact(device, remaining, reader, chunks) do
    case reader.(device, remaining) do
      {:ok, chunk}
      when is_binary(chunk) and byte_size(chunk) > 0 and byte_size(chunk) <= remaining ->
        read_exact(device, remaining - byte_size(chunk), reader, [chunk | chunks])

      :eof ->
        {:error, :inspection_source_changed}

      {:ok, _unexpected} ->
        {:error, :inspection_source_changed}

      {:error, _reason} ->
        {:error, :inspection_source_unavailable}
    end
  end

  defp same_file(
         %File.Stat{major_device: major, minor_device: minor, inode: inode},
         %File.Stat{major_device: major, minor_device: minor, inode: inode}
       ),
       do: :ok

  defp same_file(_expected, _opened), do: {:error, :inspection_source_changed}

  defp unchanged(before, after_read) do
    with :ok <- same_file(before, after_read),
         true <- before.size == after_read.size and before.mtime == after_read.mtime do
      :ok
    else
      false -> {:error, :inspection_source_changed}
      {:error, _reason} = error -> error
    end
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
  defp record_types(1), do: @record_types_v1
  defp record_types(2), do: @record_types_v2
  defp valid_request_id?(id), do: is_integer(id) and id > 0
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
