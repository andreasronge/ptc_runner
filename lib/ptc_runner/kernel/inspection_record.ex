defmodule PtcRunner.Kernel.InspectionRecord do
  @moduledoc false

  alias PtcRunner.Kernel.InspectionArtifact.Codec
  alias PtcRunner.Kernel.InspectionRecordTypes
  alias PtcRunner.Kernel.InspectionValueIdentity
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.ResultIdentity
  alias PtcRunner.Lisp.RetainedSize

  @schema_version 9
  @envelope_keys ~w(schema_version run_id trace_id sequence timestamp record_type correlation payload)

  @spec build(binary(), binary(), pos_integer(), binary(), map(), map(), pos_integer()) ::
          {:ok, map(), binary()} | {:error, :invalid_record | :limit_exceeded}
  def build(run_id, trace_id, sequence, record_type, correlation, payload, max_record_bytes)
      when is_binary(run_id) and is_binary(trace_id) and is_integer(sequence) and sequence > 0 and
             is_binary(record_type) and is_map(correlation) and is_map(payload) and
             is_integer(max_record_bytes) and max_record_bytes > 0 do
    with true <- record_type in InspectionRecordTypes.all(),
         :ok <- validate_raw_result(record_type, payload),
         true <- within_depth?(correlation, payload),
         {:ok, correlation} <- normalize(correlation),
         {:ok, payload} <- normalize(payload),
         record <- %{
           "schema_version" => @schema_version,
           "run_id" => run_id,
           "trace_id" => trace_id,
           "sequence" => sequence,
           "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
           "record_type" => record_type,
           "correlation" => correlation,
           "payload" => payload
         },
         :ok <- validate(record, run_id, trace_id, sequence),
         true <- retained_within_limit?(record, max_record_bytes),
         {:ok, encoded} <- Codec.encode_record(record),
         true <- byte_size(encoded) <= max_record_bytes do
      {:ok, record, encoded}
    else
      false -> {:error, :limit_exceeded}
      _invalid -> {:error, :invalid_record}
    end
  end

  def build(_run_id, _trace_id, _sequence, _type, _correlation, _payload, _limit),
    do: {:error, :invalid_record}

  @spec validate(map(), binary() | nil, binary() | nil, pos_integer()) ::
          :ok | {:error, :invalid_record}
  def validate(record, run_id, trace_id, sequence) do
    valid? =
      MCPProtocol.within_inspection_document_depth?(record) and
        is_map(record) and Enum.sort(Map.keys(record)) == Enum.sort(@envelope_keys) and
        record["schema_version"] == @schema_version and
        (is_nil(run_id) or record["run_id"] == run_id) and
        (is_nil(trace_id) or record["trace_id"] == trace_id) and
        valid_id?(record["run_id"]) and valid_id?(record["trace_id"]) and
        record["sequence"] == sequence and valid_timestamp?(record["timestamp"]) and
        record["record_type"] in InspectionRecordTypes.all() and valid_shape?(record)

    if valid?, do: :ok, else: {:error, :invalid_record}
  end

  defp valid_shape?(%{
         "record_type" => "run-result",
         "correlation" => correlation,
         "payload" => payload
       }) do
    correlation == %{} and exact_keys?(payload, ~w(result_hash value)) and
      ResultIdentity.valid_hash?(payload["result_hash"]) and
      ResultIdentity.strict_json_hash(payload["value"]) == {:ok, payload["result_hash"]}
  end

  defp valid_shape?(%{
         "record_type" => record_type,
         "correlation" => %{"capability_id" => id},
         "payload" => payload
       })
       when record_type in ["capability-input", "capability-output"] do
    value_keys =
      case record_type do
        "capability-input" -> ["arguments"]
        "capability-output" -> ["result", "result_identity"]
      end

    Enum.any?(value_keys, fn value_key ->
      valid_id?(id) and valid_capability_payload?(payload, value_key) and
        (value_key != "result_identity" or
           InspectionValueIdentity.valid?(payload[value_key])) and
        ((payload["environment"] == "workflow" and
            exact_keys?(payload, ["environment", "name", value_key])) or
           (payload["environment"] == "mission" and
              exact_keys?(payload, ["environment", "mission_name", "name", value_key]) and
              valid_id?(payload["mission_name"])))
    end)
  end

  defp valid_shape?(%{
         "record_type" => "capability-exception",
         "correlation" => %{"capability_id" => id},
         "payload" => payload
       }),
       do: InspectionRecordTypes.valid_capability_exception?(id, payload)

  defp valid_shape?(%{
         "record_type" => record_type,
         "correlation" => correlation,
         "payload" => payload
       })
       when record_type in ["mcp-request", "mcp-response"] do
    request_id = correlation["request_id"]

    exact_keys?(correlation, ~w(capability_id request_id)) and
      valid_id?(correlation["capability_id"]) and valid_request_id?(request_id) and
      (exact_keys?(payload, ~w(transport body)) or
         exact_keys?(payload, ~w(transport body_identity)) or
         ((exact_keys?(payload, ~w(transport body mission_name)) or
             exact_keys?(payload, ~w(transport body_identity mission_name))) and
            valid_id?(payload["mission_name"]))) and
      payload["transport"] in ["stdio", "streamable_http"] and
      if(Map.has_key?(payload, "body"),
        do: MCPProtocol.valid_inspection_exchange?(record_type, payload["body"], request_id),
        else:
          record_type == "mcp-response" and
            InspectionValueIdentity.valid?(payload["body_identity"])
      )
  end

  defp valid_shape?(%{
         "record_type" => "mcp-stderr",
         "correlation" => correlation,
         "payload" => payload
       }),
       do: InspectionRecordTypes.valid_mcp_stderr?(correlation, payload)

  defp valid_shape?(%{
         "record_type" => "prelude-source",
         "correlation" => %{"component_id" => id},
         "payload" => payload
       }) do
    valid_id?(id) and is_binary(payload["source"]) and
      payload["source_bytes"] == byte_size(payload["source"]) and
      payload["source_hash"] == sha256(payload["source"]) and
      ((payload["environment"] == "workflow" and
          exact_keys?(payload, ~w(environment source source_hash source_bytes))) or
         (payload["environment"] == "mission" and valid_id?(payload["mission_name"]) and
            exact_keys?(payload, ~w(environment mission_name source source_hash source_bytes))))
  end

  defp valid_shape?(%{
         "record_type" => "evaluation-source",
         "correlation" => %{"evaluation_id" => id},
         "payload" => payload
       }) do
    exact_keys?(
      payload,
      ~w(environment mission_name program_kind source source_hash source_bytes)
    ) and
      valid_id?(id) and valid_id?(payload["mission_name"]) and
      payload["environment"] == "mission" and payload["program_kind"] == "ptc-lisp" and
      is_binary(payload["source"]) and
      payload["source_bytes"] == byte_size(payload["source"]) and
      payload["source_hash"] == sha256(payload["source"])
  end

  defp valid_shape?(%{
         "record_type" => "evaluation-analysis",
         "correlation" => %{"evaluation_id" => id},
         "payload" => payload
       }) do
    exact_keys?(payload, ~w(environment mission_name prelude_calls)) and valid_id?(id) and
      valid_id?(payload["mission_name"]) and payload["environment"] == "mission" and
      valid_prelude_calls?(payload["prelude_calls"])
  end

  defp valid_shape?(%{
         "record_type" => "execution-prints",
         "correlation" => %{"evaluation_id" => id},
         "payload" => payload
       }) do
    exact_keys?(payload, ~w(environment prints truncated)) and valid_id?(id) and
      payload["environment"] == "workflow" and is_list(payload["prints"]) and
      Enum.all?(payload["prints"], &is_binary/1) and is_boolean(payload["truncated"])
  end

  defp valid_shape?(%{
         "record_type" => "execution-error",
         "correlation" => %{"evaluation_id" => id},
         "payload" => payload
       }) do
    exact_keys?(payload, ~w(environment kind reason details)) and valid_id?(id) and
      payload["environment"] == "workflow" and valid_id?(payload["kind"]) and
      valid_id?(payload["reason"]) and is_map(payload["details"]) and
      InspectionRecordTypes.valid_boundary_producer_details?(payload["details"])
  end

  defp valid_shape?(%{
         "record_type" => "explicit-failure-value",
         "correlation" => %{"evaluation_id" => id},
         "payload" => payload
       }) do
    exact_keys?(payload, ~w(environment value)) and valid_id?(id) and
      payload["environment"] == "workflow" and JSONValue.value?(payload["value"])
  end

  defp valid_shape?(_record), do: false

  defp validate_raw_result("run-result", payload) do
    case {Map.fetch(payload, :value), Map.fetch(payload, "value")} do
      {{:ok, value}, :error} -> strict_json(value)
      {:error, {:ok, value}} -> strict_json(value)
      _missing_or_duplicate -> {:error, :invalid_record}
    end
  end

  defp validate_raw_result(_record_type, _payload), do: :ok

  defp strict_json(value) do
    case ResultIdentity.strict_json_hash(value) do
      {:ok, _hash} -> :ok
      {:error, _reason} -> {:error, :invalid_record}
    end
  end

  defp within_depth?(correlation, payload) do
    MCPProtocol.within_inspection_document_depth?(%{
      "correlation" => correlation,
      "payload" => payload
    })
  end

  defp normalize(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key),
           {:ok, item} <- normalize(item) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        _invalid -> {:halt, {:error, :invalid_record}}
      end
    end)
  end

  defp normalize(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case normalize(value) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize(value) when is_atom(value) and value not in [true, false, nil],
    do: {:ok, Atom.to_string(value)}

  defp normalize(value) when is_binary(value), do: {:ok, value}

  defp normalize(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp normalize(_value), do: {:error, :invalid_record}

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_record}

  defp retained_within_limit?(record, cap) do
    case RetainedSize.bytes_with_cap(record, cap) do
      bytes when is_integer(bytes) and bytes <= cap -> true
      _bytes -> false
    end
  end

  defp exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp valid_capability_payload?(payload, value_key) do
    payload["environment"] in ["workflow", "mission"] and valid_id?(payload["name"]) and
      is_map(payload[value_key])
  end

  defp valid_prelude_calls?(calls) when is_list(calls) do
    Enum.all?(calls, fn call ->
      is_map(call) and exact_keys?(call, ~w(ref component_id)) and valid_id?(call["ref"]) and
        valid_id?(call["component_id"])
    end) and calls == Enum.uniq(calls) and
      calls == Enum.sort_by(calls, &{&1["ref"], &1["component_id"]})
  end

  defp valid_prelude_calls?(_calls), do: false

  defp valid_timestamp?(timestamp) when is_binary(timestamp),
    do: match?({:ok, _datetime, 0}, DateTime.from_iso8601(timestamp))

  defp valid_timestamp?(_timestamp), do: false
  defp valid_request_id?(id), do: is_integer(id) and id > 0
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
