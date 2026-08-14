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
  excessive structural depth, malformed lines, mixed identities, non-contiguous
  sequences, and records outside the exact V6 vocabulary. Private records use
  a required `mission_name` on mission-owned source and capability
  records while forbidding it on workflow-owned records. V6 joins at most one
  static prelude-call analysis to each subordinate evaluation source and also
  admits at most one strictly JSON terminal result whose self-hash must match
  the successful canonical `run-stopped` event. A missing capability or
  evaluation correlation is accepted only when the same canonical trace's
  `events-dropped` marker and terminal usage agree on enough dropped events of
  that exact type. The retained trace marker therefore identifies the
  inspection artifact as partial; an existing but mismatched correlation still
  fails closed.

  A syntactically decoded artifact whose records uniformly declare another
  integer schema version is rejected with both the declared and supported
  versions. It is not validated against a deleted historical vocabulary.

  Secure publication is supported on Unix hosts with POSIX-compatible `mkdir`
  and `id` executables available on `PATH`; persistence fails closed when those
  authority/mode primitives are unavailable, a physical or lexical ancestor
  has an untrusted owner, or any ancestor is group/other-writable without
  sticky-directory protection. Preflight also rejects a final parent whose
  effective permission class lacks create access. The same structural-depth
  ceiling applies before in-memory retention, persistence, and loading.
  """

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.InspectionRecordTypes
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.ResultIdentity

  @max_bytes 16_000_000
  @max_record_bytes 2_000_000
  @schema_version 6
  @suffix ".inspection.jsonl"
  @envelope_keys ~w(schema_version run_id trace_id sequence timestamp record_type correlation payload)

  @type unsupported_schema_error ::
          {:unsupported_inspection_schema_version,
           %{artifact_version: integer(), supported_version: pos_integer()}}

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
    with :ok <- validate_destination_path(path),
         {:ok, path} <- anchor_path(path, :invalid_inspection_path) do
      preflight_anchored(path)
    end
  end

  def preflight_destination(_path), do: {:error, :invalid_inspection_path}

  @doc false
  @spec validate_destination_path(term()) :: :ok | {:error, :invalid_inspection_path}
  def validate_destination_path(path) when is_binary(path), do: valid_path(path)
  def validate_destination_path(_path), do: {:error, :invalid_inspection_path}

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

  @doc false
  @spec persist_handle(
          PublicationHandle.t(),
          [map()],
          [map()],
          nil | (atom() -> term())
        ) :: :ok | {:error, atom()}
  def persist_handle(handle, records, canonical_events, fault_hook \\ nil)

  def persist_handle(%PublicationHandle{} = handle, records, canonical_events, fault_hook)
      when is_list(records) and is_list(canonical_events) and
             (is_nil(fault_hook) or is_function(fault_hook, 1)) do
    with true <- PublicationHandle.valid?(handle),
         :ok <- validate_records(records),
         :ok <- validate_correlations(records, canonical_events),
         {:ok, encoded} <- encode(records),
         true <- byte_size(encoded) <= @max_bytes,
         :ok <- persistence_fault(fault_hook, :before_write),
         :ok <- PublicationHandle.write(handle, encoded),
         :ok <- persistence_fault(fault_hook, :after_write),
         :ok <- PublicationHandle.sync(handle),
         :ok <- persistence_fault(fault_hook, :after_sync),
         :ok <- PublicationHandle.publish(handle) do
      :ok
    else
      false -> {:error, :invalid_inspection_artifact}
      {:error, _reason} = error -> error
      _other -> {:error, :inspection_persistence_failed}
    end
  end

  def persist_handle(_handle, _records, _events, _fault_hook),
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

  @spec load(binary(), keyword()) ::
          {:ok, [map()]} | {:error, atom() | unsupported_schema_error()}
  @doc "Loads one exact fixed artifact with optional lower aggregate and per-record limits."
  def load(path, opts \\ [])

  def load(path, opts) when is_binary(path) and is_list(opts) do
    load(path, opts, nil)
  end

  def load(_path, _opts), do: {:error, :invalid_inspection_artifact}

  @doc false
  @spec load(binary(), keyword(), nil | (-> term())) ::
          {:ok, [map()]} | {:error, atom() | unsupported_schema_error()}
  def load(path, opts, verification_hook)
      when is_binary(path) and is_list(opts) and
             (is_nil(verification_hook) or is_function(verification_hook, 0)) do
    load(path, opts, verification_hook, &:file.read/2)
  end

  def load(_path, _opts, _verification_hook), do: {:error, :invalid_inspection_artifact}

  @doc false
  @spec load(binary(), keyword(), nil | (-> term()), (:file.io_device(), non_neg_integer() ->
                                                        {:ok, binary()} | :eof | {:error, term()})) ::
          {:ok, [map()]} | {:error, atom() | unsupported_schema_error()}
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
         :ok <- validate_loaded_schema_version(records),
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

  defp validate_loaded_schema_version([]), do: :ok

  defp validate_loaded_schema_version([first | _rest] = records) do
    artifact_version = first["schema_version"]

    if is_integer(artifact_version) and artifact_version != @schema_version and
         Enum.all?(records, fn record ->
           is_map(record) and Enum.sort(Map.keys(record)) == Enum.sort(@envelope_keys) and
             record["schema_version"] == artifact_version
         end) do
      {:error,
       {:unsupported_inspection_schema_version,
        %{artifact_version: artifact_version, supported_version: @schema_version}}}
    else
      :ok
    end
  end

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
      analyses: MapSet.new(),
      preludes: MapSet.new(),
      execution_prints: MapSet.new(),
      execution_errors: MapSet.new(),
      result?: false
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
           "payload" => %{"environment" => environment, "name" => name} = payload
         },
         state
       ) do
    if Map.has_key?(state.inputs, id),
      do: invalid_record_join(),
      else:
        {:cont, {:ok, put_in(state, [:inputs, id], {environment, payload["mission_name"], name})}}
  end

  defp validate_record_join(
         %{
           "record_type" => "capability-output",
           "correlation" => %{"capability_id" => id},
           "payload" => %{"environment" => environment, "name" => name} = payload
         },
         state
       ) do
    if Map.get(state.inputs, id) == {environment, payload["mission_name"], name} and
         not MapSet.member?(state.outputs, id),
       do: {:cont, {:ok, %{state | outputs: MapSet.put(state.outputs, id)}}},
       else: invalid_record_join()
  end

  defp validate_record_join(
         %{
           "record_type" => "mcp-request",
           "correlation" => %{"capability_id" => capability_id, "request_id" => request_id},
           "payload" => %{"transport" => transport} = payload
         },
         state
       ) do
    key = {capability_id, request_id}

    if Map.has_key?(state.inputs, capability_id) and
         mission_join?(state.inputs[capability_id], payload["mission_name"]) and
         not Map.has_key?(state.mcp_requests, key),
       do:
         {:cont, {:ok, put_in(state, [:mcp_requests, key], {transport, payload["mission_name"]})}},
       else: invalid_record_join()
  end

  defp validate_record_join(
         %{
           "record_type" => "mcp-response",
           "correlation" => %{"capability_id" => capability_id, "request_id" => request_id},
           "payload" => %{"transport" => transport} = payload
         },
         state
       ) do
    key = {capability_id, request_id}

    if Map.get(state.mcp_requests, key) == {transport, payload["mission_name"]} and
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
         %{"record_type" => "evaluation-analysis", "correlation" => %{"evaluation_id" => id}},
         state
       ) do
    if MapSet.member?(state.evaluations, id),
      do: unique_record(state, :analyses, id),
      else: invalid_record_join()
  end

  defp validate_record_join(
         %{
           "record_type" => "prelude-source",
           "correlation" => %{"component_id" => id},
           "payload" => %{"environment" => environment} = payload
         },
         state
       ),
       do: unique_record(state, :preludes, {environment, payload["mission_name"], id})

  defp validate_record_join(
         %{"record_type" => "execution-prints", "correlation" => %{"evaluation_id" => id}},
         state
       ),
       do: unique_record(state, :execution_prints, id)

  defp validate_record_join(
         %{"record_type" => "execution-error", "correlation" => %{"evaluation_id" => id}},
         state
       ),
       do: unique_record(state, :execution_errors, id)

  defp validate_record_join(%{"record_type" => "run-result"}, %{result?: false} = state),
    do: {:cont, {:ok, %{state | result?: true}}}

  defp validate_record_join(%{"record_type" => "run-result"}, _state),
    do: invalid_record_join()

  defp mission_join?({"mission", mission_name, _name}, mission_name) when is_binary(mission_name),
    do: true

  defp mission_join?({"workflow", nil, _name}, nil), do: true
  defp mission_join?(_input, _mission_name), do: false

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
      schema_version == @schema_version and record["schema_version"] == schema_version and
      record["run_id"] == run_id and
      record["trace_id"] == trace_id and is_binary(run_id) and is_binary(trace_id) and
      record["sequence"] == sequence and valid_timestamp?(record["timestamp"]) and
      record["record_type"] in record_types(schema_version) and
      valid_shape?(record, schema_version)
  end

  defp valid_shape?(
         %{
           "record_type" => "run-result",
           "correlation" => correlation,
           "payload" => payload
         },
         6
       ) do
    correlation == %{} and exact_keys?(payload, ~w(result_hash value)) and
      ResultIdentity.valid_hash?(payload["result_hash"]) and
      ResultIdentity.strict_json_hash(payload["value"]) == {:ok, payload["result_hash"]}
  end

  defp valid_shape?(
         %{
           "record_type" => record_type,
           "correlation" => %{"capability_id" => id},
           "payload" => payload
         },
         6
       )
       when record_type in ["capability-input", "capability-output"] do
    value_key = if record_type == "capability-input", do: "arguments", else: "result"

    valid_id?(id) and valid_capability_payload?(payload, value_key) and
      ((payload["environment"] == "workflow" and
          exact_keys?(payload, ["environment", "name", value_key])) or
         (payload["environment"] == "mission" and
            exact_keys?(payload, ["environment", "mission_name", "name", value_key]) and
            valid_id?(payload["mission_name"])))
  end

  defp valid_shape?(
         %{
           "record_type" => record_type,
           "correlation" => correlation,
           "payload" => payload
         },
         6
       )
       when record_type in ["mcp-request", "mcp-response"] do
    request_id = correlation["request_id"]

    exact_keys?(correlation, ~w(capability_id request_id)) and
      valid_id?(correlation["capability_id"]) and valid_request_id?(request_id) and
      (exact_keys?(payload, ~w(transport body)) or
         (exact_keys?(payload, ~w(transport body mission_name)) and
            valid_id?(payload["mission_name"]))) and
      payload["transport"] in ["stdio", "streamable_http"] and
      MCPProtocol.valid_inspection_exchange?(record_type, payload["body"], request_id)
  end

  defp valid_shape?(
         %{
           "record_type" => "prelude-source",
           "correlation" => %{"component_id" => id},
           "payload" => payload
         },
         6
       ) do
    valid_id?(id) and is_binary(payload["source"]) and
      payload["source_bytes"] == byte_size(payload["source"]) and
      payload["source_hash"] == sha256(payload["source"]) and
      ((payload["environment"] == "workflow" and
          exact_keys?(payload, ~w(environment source source_hash source_bytes))) or
         (payload["environment"] == "mission" and valid_id?(payload["mission_name"]) and
            exact_keys?(payload, ~w(environment mission_name source source_hash source_bytes))))
  end

  defp valid_shape?(
         %{
           "record_type" => "evaluation-source",
           "correlation" => %{"evaluation_id" => id},
           "payload" => payload
         },
         6
       ) do
    exact_keys?(
      payload,
      ~w(environment mission_name program_kind source source_hash source_bytes)
    ) and valid_id?(id) and valid_id?(payload["mission_name"]) and
      payload["environment"] == "mission" and payload["program_kind"] == "ptc-lisp" and
      is_binary(payload["source"]) and payload["source_bytes"] == byte_size(payload["source"]) and
      payload["source_hash"] == sha256(payload["source"])
  end

  defp valid_shape?(
         %{
           "record_type" => "evaluation-analysis",
           "correlation" => %{"evaluation_id" => id},
           "payload" => payload
         },
         6
       ) do
    exact_keys?(payload, ~w(environment mission_name prelude_calls)) and valid_id?(id) and
      valid_id?(payload["mission_name"]) and payload["environment"] == "mission" and
      valid_prelude_calls?(payload["prelude_calls"])
  end

  defp valid_shape?(
         %{
           "record_type" => "execution-prints",
           "correlation" => %{"evaluation_id" => id},
           "payload" => payload
         },
         6
       ) do
    exact_keys?(payload, ~w(environment prints truncated)) and
      valid_id?(id) and payload["environment"] == "workflow" and
      is_list(payload["prints"]) and Enum.all?(payload["prints"], &is_binary/1) and
      is_boolean(payload["truncated"])
  end

  defp valid_shape?(
         %{
           "record_type" => "execution-error",
           "correlation" => %{"evaluation_id" => id},
           "payload" => payload
         },
         6
       ) do
    exact_keys?(payload, ~w(environment kind reason details)) and
      valid_id?(id) and payload["environment"] == "workflow" and
      valid_id?(payload["kind"]) and valid_id?(payload["reason"]) and
      is_map(payload["details"]) and
      InspectionRecordTypes.valid_boundary_producer_details?(payload["details"])
  end

  defp valid_shape?(_record, 6), do: false

  defp valid_prelude_calls?(calls) when is_list(calls) do
    Enum.all?(calls, fn call ->
      is_map(call) and exact_keys?(call, ~w(ref component_id)) and valid_id?(call["ref"]) and
        valid_id?(call["component_id"])
    end) and calls == Enum.uniq(calls) and
      calls == Enum.sort_by(calls, &{&1["ref"], &1["component_id"]})
  end

  defp valid_prelude_calls?(_calls), do: false

  @spec validate_correlations([map()], [map()]) :: :ok | {:error, :inspection_correlation_missing}
  @doc "Validates every record identity and correlation against one canonical event set."
  def validate_correlations([first | _rest] = records, events) do
    events =
      Enum.filter(events, fn event ->
        event_value(event, :run_id) == first["run_id"] and
          event_value(event, :trace_id) == first["trace_id"]
      end)

    with {:ok, capabilities} <- canonical_capabilities(events),
         {:ok, evaluations} <- canonical_evaluations(events),
         :ok <- validate_result_correlation(records, events) do
      prelude_components =
        Enum.reduce(events, %{}, fn event, acc ->
          acc
          |> merge_prelude_ids({"workflow", nil}, event_data(event, :workflow_prelude))
          |> merge_named_prelude_ids(event_data(event, :missions))
        end)

      validate_record_correlations(
        records,
        capabilities,
        evaluations,
        prelude_components,
        proven_dropped_counts(events)
      )
    end
  end

  def validate_correlations(_records, _events), do: {:error, :inspection_correlation_missing}

  defp validate_result_correlation(records, events) do
    case Enum.filter(records, &(&1["record_type"] == "run-result")) do
      [] ->
        :ok

      [%{"payload" => %{"result_hash" => result_hash, "value" => value}}] ->
        with {:ok, ^result_hash} <- ResultIdentity.strict_json_hash(value),
             true <- ResultIdentity.valid_hash?(result_hash),
             [terminal] <- Enum.filter(events, &(event_value(&1, :type) == "run-stopped")),
             "ok" <- string_value(event_data(terminal, :outcome)),
             ^result_hash <- event_data(terminal, :result_hash) do
          :ok
        else
          _invalid -> {:error, :inspection_correlation_missing}
        end

      _invalid ->
        {:error, :inspection_correlation_missing}
    end
  end

  defp canonical_capabilities(events) do
    Enum.reduce_while(events, {:ok, %{}}, fn event, {:ok, capabilities} ->
      id = event_data(event, :capability_id)
      environment = event_data(event, :environment) |> string_value()
      mission_name = event_data(event, :mission_name)
      name = event_data(event, :name)

      cond do
        event_value(event, :type) != "capability-started" or not is_binary(id) ->
          {:cont, {:ok, capabilities}}

        Map.has_key?(capabilities, id) ->
          {:halt, {:error, :inspection_correlation_missing}}

        true ->
          {:cont, {:ok, Map.put(capabilities, id, {environment, mission_name, name})}}
      end
    end)
  end

  defp canonical_evaluations(events) do
    Enum.reduce_while(events, {:ok, %{}}, fn event, {:ok, evaluations} ->
      id = event_data(event, :evaluation_id)
      environment = event_data(event, :environment) |> string_value()
      mission_name = event_data(event, :mission_name)

      cond do
        event_value(event, :type) != "evaluation-started" or not is_binary(id) ->
          {:cont, {:ok, evaluations}}

        Map.has_key?(evaluations, id) ->
          {:halt, {:error, :inspection_correlation_missing}}

        true ->
          source = {event_data(event, :source_hash), event_data(event, :source_bytes)}
          {:cont, {:ok, Map.put(evaluations, id, {environment, mission_name, source})}}
      end
    end)
  end

  defp validate_record_correlations(
         records,
         capabilities,
         evaluations,
         prelude_components,
         dropped
       ) do
    initial = %{capabilities: MapSet.new(), evaluations: %{}}

    records
    |> Enum.reduce_while({:ok, initial}, fn record, {:ok, missing} ->
      validate_record_correlation(
        record,
        capabilities,
        evaluations,
        prelude_components,
        missing
      )
    end)
    |> case do
      {:ok, missing} -> validate_missing_correlations(missing, dropped)
      {:error, :inspection_correlation_missing} = error -> error
    end
  end

  defp validate_record_correlation(
         %{"record_type" => "run-result"},
         _capabilities,
         _evaluations,
         _prelude_components,
         missing
       ),
       do: {:cont, {:ok, missing}}

  defp validate_record_correlation(
         %{
           "correlation" => %{"capability_id" => id},
           "payload" => %{"environment" => environment, "name" => name} = payload
         },
         capabilities,
         _evaluations,
         _prelude_components,
         missing
       ) do
    correlate_or_mark_missing(
      capabilities,
      id,
      {environment, payload["mission_name"], name},
      missing,
      :capabilities
    )
  end

  defp validate_record_correlation(
         %{
           "record_type" => record_type,
           "correlation" => %{"capability_id" => id, "request_id" => request_id},
           "payload" => payload
         },
         capabilities,
         _evaluations,
         _prelude_components,
         missing
       )
       when record_type in ["mcp-request", "mcp-response"] do
    if valid_request_id?(request_id),
      do:
        correlate_or_mark_missing(
          capabilities,
          id,
          payload["mission_name"],
          missing,
          :capabilities,
          fn {_environment, actual_mission, _name}, expected_mission ->
            actual_mission == expected_mission
          end
        ),
      else: missing_correlation()
  end

  defp validate_record_correlation(
         %{
           "record_type" => "evaluation-source",
           "correlation" => %{"evaluation_id" => id},
           "payload" => %{"source_hash" => hash, "source_bytes" => bytes} = payload
         },
         _capabilities,
         evaluations,
         _prelude_components,
         missing
       ),
       do:
         correlate_evaluation_or_mark_missing(
           evaluations,
           id,
           {"mission", payload["mission_name"], {hash, bytes}},
           missing
         )

  defp validate_record_correlation(
         %{
           "record_type" => "evaluation-analysis",
           "correlation" => %{"evaluation_id" => id},
           "payload" => %{"mission_name" => mission_name, "prelude_calls" => calls}
         },
         _capabilities,
         evaluations,
         prelude_components,
         missing
       ) do
    component_ids = Map.get(prelude_components, {"mission", mission_name}, MapSet.new())

    if Enum.all?(calls, &MapSet.member?(component_ids, &1["component_id"])),
      do:
        correlate_evaluation_or_mark_missing(
          evaluations,
          id,
          {"mission", mission_name, :any},
          missing
        ),
      else: missing_correlation()
  end

  defp validate_record_correlation(
         %{
           "record_type" => record_type,
           "correlation" => %{"evaluation_id" => id}
         },
         _capabilities,
         evaluations,
         _prelude_components,
         missing
       )
       when record_type in ["execution-prints", "execution-error"],
       do: correlate_evaluation_or_mark_missing(evaluations, id, {"workflow", nil, :any}, missing)

  defp validate_record_correlation(
         %{
           "correlation" => %{"component_id" => id},
           "payload" => %{"environment" => environment} = payload
         },
         _capabilities,
         _evaluations,
         prelude_components,
         missing
       ) do
    key = {environment, payload["mission_name"]}

    if MapSet.member?(Map.get(prelude_components, key, MapSet.new()), id),
      do: {:cont, {:ok, missing}},
      else: missing_correlation()
  end

  defp validate_record_correlation(
         _record,
         _capabilities,
         _evaluations,
         _prelude_components,
         _missing
       ),
       do: missing_correlation()

  defp correlate_or_mark_missing(canonical, id, expected, missing, field, matcher \\ &(&1 == &2)) do
    case Map.fetch(canonical, id) do
      {:ok, actual} ->
        if matcher.(actual, expected),
          do: {:cont, {:ok, missing}},
          else: missing_correlation()

      :error ->
        {:cont, {:ok, Map.update!(missing, field, &MapSet.put(&1, id))}}
    end
  end

  defp correlate_evaluation_or_mark_missing(canonical, id, expected, missing) do
    case Map.fetch(canonical, id) do
      {:ok, actual} ->
        if evaluation_matches?(actual, expected),
          do: {:cont, {:ok, missing}},
          else: missing_correlation()

      :error ->
        owner = evaluation_owner(expected)

        case Map.fetch(missing.evaluations, id) do
          :error ->
            {:cont, {:ok, put_in(missing, [:evaluations, id], owner)}}

          {:ok, ^owner} ->
            {:cont, {:ok, missing}}

          {:ok, _conflicting_owner} ->
            missing_correlation()
        end
    end
  end

  defp evaluation_owner({environment, mission_name, _source}),
    do: {environment, mission_name}

  defp evaluation_matches?({"workflow", nil, _source}, {"workflow", nil, :any}), do: true

  defp evaluation_matches?(
         {"mission", mission_name, _source},
         {"mission", mission_name, :any}
       ),
       do: true

  defp evaluation_matches?(actual, expected), do: actual == expected

  defp validate_missing_correlations(missing, dropped) do
    if MapSet.size(missing.capabilities) <= Map.get(dropped, "capability-started", 0) and
         map_size(missing.evaluations) <= Map.get(dropped, "evaluation-started", 0),
       do: :ok,
       else: {:error, :inspection_correlation_missing}
  end

  defp proven_dropped_counts(events) do
    markers = Enum.filter(events, &(event_value(&1, :type) == "events-dropped"))
    stopped = Enum.filter(events, &(event_value(&1, :type) == "run-stopped"))

    with [marker, terminal] <- Enum.take(events, -2),
         "events-dropped" <- event_value(marker, :type),
         "run-stopped" <- event_value(terminal, :type),
         [^marker] <- markers,
         [^terminal] <- stopped,
         {:ok, marker_counts} <- event_counts(event_data(marker, :counts)),
         usage when is_map(usage) <- event_data(terminal, :usage),
         {:ok, terminal_counts} <- event_counts(map_value(usage, :events_dropped)),
         true <- marker_counts == terminal_counts do
      marker_counts
    else
      _unproven -> %{}
    end
  end

  defp event_counts(counts) when is_map(counts) and not is_struct(counts) do
    if Enum.all?(counts, fn {type, count} ->
         is_binary(type) and is_integer(count) and count > 0
       end),
       do: {:ok, counts},
       else: :error
  end

  defp event_counts(_counts), do: :error

  defp missing_correlation, do: {:halt, {:error, :inspection_correlation_missing}}

  defp merge_prelude_ids(acc, key, prelude) when is_map(prelude) do
    ids =
      (Map.get(prelude, :component_ids) || Map.get(prelude, "component_ids") || [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    Map.update(acc, key, MapSet.new(ids), &MapSet.union(&1, MapSet.new(ids)))
  end

  defp merge_prelude_ids(acc, _key, _prelude), do: acc

  defp merge_named_prelude_ids(acc, missions) when is_map(missions) do
    Enum.reduce(missions, acc, fn {name, metadata}, inner_acc ->
      prelude =
        if is_map(metadata),
          do: Map.get(metadata, :prelude) || Map.get(metadata, "prelude"),
          else: nil

      merge_prelude_ids(inner_acc, {"mission", to_string(name)}, prelude)
    end)
  end

  defp merge_named_prelude_ids(acc, _missions), do: acc

  defp event_value(event, key), do: Map.get(event, key) || Map.get(event, Atom.to_string(key))

  defp event_data(event, key) do
    case event_value(event, :data) do
      data when is_map(data) -> Map.get(data, key) || Map.get(data, Atom.to_string(key))
      _data -> nil
    end
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

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
  defp record_types(6), do: InspectionRecordTypes.all()
  defp valid_request_id?(id), do: is_integer(id) and id > 0
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
