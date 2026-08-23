defmodule PtcRunner.Kernel.InspectionSink do
  @moduledoc """
  Required, bounded in-memory owner for sensitive developer inspection records.

  Capture is host-enabled, fail-closed, and V7-only. The closed vocabulary
  contains capability input/exception/output, subordinate evaluation source and static
  prelude-call analysis, effective prelude source, correlated exact MCP
  request/response bodies, and workflow execution prints/errors, plus at most
  one strictly JSON terminal result bound to its deterministic canonical hash.
  Mission-owned source, analysis, capability, prelude, and MCP records require
  `mission_name`; workflow-owned records forbid it. Other record types normalize
  atom keys and enum values to JSON
  strings; the terminal result must already be strict JSON. The sink assigns
  the run identity, sequence, and UTC timestamp, and rejects a record before
  retention when either its retained or encoded size exceeds the installed
  bounds.

  This sink is independent of Logger, Telemetry, EventSink policy, manifests,
  and Lisp. Records remain private until the host explicitly persists them as
  a `0600` `.inspection.jsonl` artifact.
  """

  use GenServer

  alias PtcRunner.Kernel.InspectionRecordTypes
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.OwnerHandoff
  alias PtcRunner.Kernel.ResultIdentity
  alias PtcRunner.Lisp.RetainedSize

  @default_record_bytes 2_000_000
  @default_total_bytes 16_000_000
  @stop_timeout_ms 5_000

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(keyword()) :: {:ok, t()} | {:error, :invalid_inspection_sink}
  @doc "Starts one required sink for an exact run and trace identity."
  def start(opts) when is_list(opts) do
    allowed = [
      :run_id,
      :trace_id,
      :owner,
      :max_record_bytes,
      :max_total_bytes
    ]

    run_id = Keyword.get(opts, :run_id)
    trace_id = Keyword.get(opts, :trace_id)
    max_record_bytes = Keyword.get(opts, :max_record_bytes, @default_record_bytes)
    max_total_bytes = Keyword.get(opts, :max_total_bytes, @default_total_bytes)

    if Keyword.keys(opts) -- allowed == [] and valid_id?(run_id) and
         valid_id?(trace_id) and
         is_integer(max_record_bytes) and max_record_bytes > 0 and
         max_record_bytes <= @default_record_bytes and is_integer(max_total_bytes) and
         max_total_bytes > 0 and max_total_bytes <= @default_total_bytes and
         max_record_bytes <= max_total_bytes do
      token = make_ref()
      owner = Keyword.get(opts, :owner, self())

      {:ok, pid} =
        GenServer.start(
          __MODULE__,
          {token, owner, run_id, trace_id, max_record_bytes, max_total_bytes}
        )

      {:ok, %__MODULE__{pid: pid, token: token}}
    else
      {:error, :invalid_inspection_sink}
    end
  end

  def start(_opts), do: {:error, :invalid_inspection_sink}

  @spec emit(t(), binary(), map(), map()) :: :ok | {:error, :inspection_sink_error}
  @doc "Validates and retains one record from the sink's fixed vocabulary."
  def emit(%__MODULE__{} = sink, record_type, correlation, payload)
      when is_binary(record_type) and is_map(correlation) and is_map(payload) do
    call(sink, {:emit, record_type, correlation, payload})
  end

  def emit(%__MODULE__{} = sink, _record_type, _correlation, _payload),
    do: call(sink, :fail)

  @doc false
  @spec emit_mcp_exchange(t(), map(), map(), map(), map() | nil) ::
          :ok | {:error, :inspection_sink_error}
  def emit_mcp_exchange(
        sink,
        correlation,
        request_payload,
        response_payload,
        stderr_payload \\ nil
      )

  def emit_mcp_exchange(
        %__MODULE__{} = sink,
        correlation,
        request_payload,
        response_payload,
        stderr_payload
      )
      when is_map(correlation) and is_map(request_payload) and is_map(response_payload) and
             (is_map(stderr_payload) or is_nil(stderr_payload)) do
    call(
      sink,
      {:emit_mcp_exchange, correlation, request_payload, response_payload, stderr_payload}
    )
  end

  def emit_mcp_exchange(
        %__MODULE__{} = sink,
        _correlation,
        _request_payload,
        _response_payload,
        _stderr_payload
      ),
      do: call(sink, :fail)

  @spec records(t()) :: {:ok, [map()]} | {:error, :inspection_sink_error}
  @doc "Returns retained records in sequence order while the required sink is healthy."
  def records(%__MODULE__{} = sink), do: call(sink, :records)

  @doc false
  @spec owner?(t()) :: boolean()
  def owner?(sink), do: call(sink, :owner?) == true

  @doc false
  @spec owner(t()) :: {:ok, pid()} | {:error, :inspection_sink_error}
  def owner(sink), do: call(sink, :owner)

  @doc false
  @spec transfer_owner(t(), pid()) :: :ok | {:error, :inspection_sink_error}
  def transfer_owner(%__MODULE__{} = sink, owner) when is_pid(owner),
    do: call(sink, {:transfer_owner, owner})

  def transfer_owner(_sink, _owner), do: {:error, :inspection_sink_error}

  @doc false
  @spec identity(t()) ::
          {:ok, %{run_id: binary(), trace_id: binary()}} | {:error, :inspection_sink_error}
  def identity(sink), do: call(sink, :identity)

  @doc false
  @spec stop_timeout_ms() :: pos_integer()
  def stop_timeout_ms, do: @stop_timeout_ms

  @spec stop(t()) :: :ok
  @doc "Stops the sink; repeated or owner-driven stops are harmless."
  def stop(sink), do: stop(sink, @stop_timeout_ms)

  @doc false
  @spec stop(t(), timeout()) :: :ok
  def stop(%__MODULE__{pid: pid}, timeout) do
    ref = Process.monitor(pid)

    try do
      try do
        GenServer.stop(pid, :normal, timeout)
      catch
        :exit, _reason -> :ok
      end

      if Process.alive?(pid), do: Process.exit(pid, :kill)
      await_stop(ref, pid, timeout)
    after
      Process.demonitor(ref, [:flush])
    end
  end

  @impl GenServer
  def init({token, owner, run_id, trace_id, max_record_bytes, max_total_bytes}) do
    {:ok,
     %{
       token: token,
       owner: owner,
       owner_ref: Process.monitor(owner),
       owner_transferable?: true,
       run_id: run_id,
       trace_id: trace_id,
       schema_version: 7,
       max_record_bytes: max_record_bytes,
       max_total_bytes: max_total_bytes,
       sequence: 0,
       encoded_bytes: 0,
       records: [],
       result?: false,
       failed?: false
     }}
  end

  @impl GenServer
  def handle_call({token, :owner}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.owner}, state}

  def handle_call({token, :identity}, _from, %{token: token} = state),
    do: {:reply, {:ok, Map.take(state, [:run_id, :trace_id])}, state}

  def handle_call({token, :owner?}, {caller, _tag}, %{token: token} = state),
    do: {:reply, caller == state.owner, state}

  def handle_call(
        {token, {:transfer_owner, owner}},
        {caller, _tag},
        %{token: token, owner: caller, owner_transferable?: true} = state
      )
      when is_pid(owner) do
    case OwnerHandoff.transfer_once(state, owner) do
      {:ok, next} -> {:reply, :ok, next}
      :error -> {:reply, {:error, :inspection_sink_error}, state}
    end
  end

  def handle_call({token, :records}, _from, %{token: token, failed?: false} = state),
    do: {:reply, {:ok, Enum.reverse(state.records)}, state}

  def handle_call(
        {token, {:emit, record_type, correlation, payload}},
        _from,
        %{token: token} = state
      ) do
    if state.failed? do
      {:reply, {:error, :inspection_sink_error}, state}
    else
      retain(state, record_type, correlation, payload)
    end
  end

  def handle_call(
        {token,
         {:emit_mcp_exchange, correlation, request_payload, response_payload, stderr_payload}},
        _from,
        %{token: token} = state
      ) do
    if state.failed? do
      {:reply, {:error, :inspection_sink_error}, state}
    else
      retain_mcp_exchange(state, correlation, request_payload, response_payload, stderr_payload)
    end
  end

  def handle_call({token, :fail}, _from, %{token: token} = state),
    do: {:reply, {:error, :inspection_sink_error}, %{state | failed?: true}}

  def handle_call({_token, _request}, _from, state),
    do: {:reply, {:error, :inspection_sink_error}, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :inspection_sink_error}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp retain(state, record_type, correlation, payload) do
    case retain_record(state, record_type, correlation, payload) do
      {:ok, next} -> {:reply, :ok, next}
      :error -> {:reply, {:error, :inspection_sink_error}, %{state | failed?: true}}
    end
  end

  defp retain_mcp_exchange(state, correlation, request_payload, response_payload, stderr_payload) do
    with {:ok, next} <- retain_record(state, "mcp-request", correlation, request_payload),
         {:ok, next} <- retain_record(next, "mcp-response", correlation, response_payload),
         {:ok, next} <- retain_stderr(next, correlation, stderr_payload) do
      {:reply, :ok, next}
    else
      :error -> {:reply, {:error, :inspection_sink_error}, %{state | failed?: true}}
    end
  end

  defp retain_stderr(state, _correlation, nil), do: {:ok, state}

  defp retain_stderr(state, correlation, payload) when is_map(payload) do
    case Map.get(payload, :text, Map.get(payload, "text")) do
      text when is_binary(text) and text != "" ->
        retain_record(state, "mcp-stderr", correlation, payload)

      _empty ->
        {:ok, state}
    end
  end

  defp retain_record(state, record_type, correlation, payload) do
    with true <- record_type in record_types(),
         true <- record_type != "run-result" or not state.result?,
         true <- within_record_depth?(correlation, payload),
         :ok <- validate_raw_result(record_type, payload, state.schema_version),
         {:ok, correlation} <- normalize(correlation),
         {:ok, payload} <- normalize(payload),
         :ok <- shape(record_type, correlation, payload, state.schema_version),
         record <- record(state, record_type, correlation, payload),
         true <- retained_within_limit?(record, state.max_record_bytes),
         {:ok, encoded} <- Jason.encode(record),
         bytes = byte_size(encoded) + 1,
         true <- bytes <= state.max_record_bytes,
         true <- state.encoded_bytes + bytes <= state.max_total_bytes do
      retained_record = RetainedSize.detach_binaries(record)

      {:ok,
       %{
         state
         | sequence: state.sequence + 1,
           encoded_bytes: state.encoded_bytes + bytes,
           records: [retained_record | state.records],
           result?: state.result? or record_type == "run-result"
       }}
    else
      _reason -> :error
    end
  end

  defp shape("run-result", correlation, payload, 7) do
    valid? =
      if correlation == %{} and exact_payload(payload, ~w(result_hash value)) and
           ResultIdentity.valid_hash?(payload["result_hash"]) do
        ResultIdentity.strict_json_hash(payload["value"]) == {:ok, payload["result_hash"]}
      else
        false
      end

    ok_or_error(valid?)
  end

  defp shape("capability-input", %{"capability_id" => id}, payload, 7) do
    valid? =
      valid_id?(id) and
        ((payload["environment"] == "workflow" and
            exact_payload(payload, ~w(environment name arguments))) or
           (payload["environment"] == "mission" and
              exact_payload(payload, ~w(environment mission_name name arguments)) and
              valid_id?(payload["mission_name"]))) and
        valid_capability_payload?(payload, "arguments")

    ok_or_error(valid?)
  end

  defp shape("capability-exception", %{"capability_id" => id}, payload, 7),
    do: ok_or_error(InspectionRecordTypes.valid_capability_exception?(id, payload))

  defp shape("capability-output", %{"capability_id" => id}, payload, 7) do
    valid? =
      valid_id?(id) and
        ((payload["environment"] == "workflow" and
            exact_payload(payload, ~w(environment name result))) or
           (payload["environment"] == "mission" and
              exact_payload(payload, ~w(environment mission_name name result)) and
              valid_id?(payload["mission_name"]))) and
        valid_capability_payload?(payload, "result")

    ok_or_error(valid?)
  end

  defp shape("evaluation-source", %{"evaluation_id" => id}, payload, 7) do
    valid? =
      exact_payload(
        payload,
        ~w(environment mission_name program_kind source source_hash source_bytes)
      ) and valid_id?(id) and valid_id?(payload["mission_name"]) and
        payload["environment"] == "mission" and payload["program_kind"] == "ptc-lisp" and
        is_binary(payload["source"]) and payload["source_hash"] == sha256(payload["source"]) and
        payload["source_bytes"] == byte_size(payload["source"])

    ok_or_error(valid?)
  end

  defp shape("evaluation-analysis", %{"evaluation_id" => id}, payload, 7) do
    valid? =
      exact_payload(payload, ~w(environment mission_name prelude_calls)) and valid_id?(id) and
        valid_id?(payload["mission_name"]) and payload["environment"] == "mission" and
        valid_prelude_calls?(payload["prelude_calls"])

    ok_or_error(valid?)
  end

  defp shape("prelude-source", %{"component_id" => id}, payload, 7) do
    valid? =
      valid_id?(id) and
        ((payload["environment"] == "workflow" and
            exact_payload(payload, ~w(environment source source_hash source_bytes))) or
           (payload["environment"] == "mission" and
              exact_payload(payload, ~w(environment mission_name source source_hash source_bytes)) and
              valid_id?(payload["mission_name"]))) and is_binary(payload["source"]) and
        payload["source_hash"] == sha256(payload["source"]) and
        payload["source_bytes"] == byte_size(payload["source"])

    ok_or_error(valid?)
  end

  defp shape(record_type, correlation, payload, 7)
       when record_type in ["mcp-request", "mcp-response"] do
    request_id = correlation["request_id"]

    valid? =
      exact_payload(correlation, ~w(capability_id request_id)) and
        (exact_payload(payload, ~w(transport body)) or
           (exact_payload(payload, ~w(transport body mission_name)) and
              valid_id?(payload["mission_name"]))) and
        valid_id?(correlation["capability_id"]) and valid_request_id?(request_id) and
        payload["transport"] in ["stdio", "streamable_http"] and
        MCPProtocol.valid_inspection_exchange?(record_type, payload["body"], request_id)

    ok_or_error(valid?)
  end

  defp shape("mcp-stderr", correlation, payload, 7),
    do: ok_or_error(InspectionRecordTypes.valid_mcp_stderr?(correlation, payload))

  defp shape("execution-prints", %{"evaluation_id" => id}, payload, 7) do
    valid? =
      exact_payload(payload, ~w(environment prints truncated)) and valid_id?(id) and
        payload["environment"] == "workflow" and
        is_list(payload["prints"]) and Enum.all?(payload["prints"], &is_binary/1) and
        is_boolean(payload["truncated"])

    ok_or_error(valid?)
  end

  defp shape("execution-error", %{"evaluation_id" => id}, payload, 7) do
    valid? =
      exact_payload(payload, ~w(environment kind reason details)) and valid_id?(id) and
        payload["environment"] == "workflow" and
        valid_id?(payload["kind"]) and valid_id?(payload["reason"]) and
        is_map(payload["details"]) and
        InspectionRecordTypes.valid_boundary_producer_details?(payload["details"])

    ok_or_error(valid?)
  end

  defp shape("explicit-failure-value", %{"evaluation_id" => id}, payload, 7) do
    valid? =
      exact_payload(payload, ~w(environment value)) and valid_id?(id) and
        payload["environment"] == "workflow" and JSONValue.value?(payload["value"])

    ok_or_error(valid?)
  end

  defp shape(_record_type, _correlation, _payload, 7), do: {:error, :invalid_record}

  # `normalize/1` recurses, so nesting is bounded before it runs. The retained
  # record wraps correlation and payload at exactly one level, so bounding that
  # envelope bounds the record itself without building the record — and without
  # stamping a timestamp the check would discard.
  defp within_record_depth?(correlation, payload) do
    MCPProtocol.within_inspection_document_depth?(%{
      "correlation" => correlation,
      "payload" => payload
    })
  end

  defp record(state, record_type, correlation, payload) do
    %{
      "schema_version" => state.schema_version,
      "run_id" => state.run_id,
      "trace_id" => state.trace_id,
      "sequence" => state.sequence + 1,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "record_type" => record_type,
      "correlation" => correlation,
      "payload" => payload
    }
  end

  defp validate_raw_result("run-result", payload, 7) when is_map(payload) do
    case {Map.fetch(payload, :value), Map.fetch(payload, "value")} do
      {{:ok, value}, :error} -> strict_json(value)
      {:error, {:ok, value}} -> strict_json(value)
      _missing_or_duplicate -> {:error, :invalid_record}
    end
  end

  defp validate_raw_result("run-result", _payload, 7), do: {:error, :invalid_record}
  defp validate_raw_result(_record_type, _payload, _schema_version), do: :ok

  defp strict_json(value) do
    case ResultIdentity.strict_json_hash(value) do
      {:ok, _hash} -> :ok
      {:error, _reason} -> {:error, :invalid_record}
    end
  end

  defp exact_payload(payload, keys) do
    Map.keys(payload) |> Enum.sort() == Enum.sort(keys) and JSONValue.map?(payload)
  end

  defp valid_capability_payload?(payload, value_key) do
    payload["environment"] in ["workflow", "mission"] and
      valid_id?(payload["name"]) and is_map(payload[value_key])
  end

  defp valid_prelude_calls?(calls) when is_list(calls) do
    Enum.all?(calls, fn call ->
      is_map(call) and exact_payload(call, ~w(ref component_id)) and
        valid_id?(call["ref"]) and valid_id?(call["component_id"])
    end) and calls == Enum.uniq(calls) and
      calls == Enum.sort_by(calls, &{&1["ref"], &1["component_id"]})
  end

  defp valid_prelude_calls?(_calls), do: false

  defp record_types, do: InspectionRecordTypes.all()
  defp valid_request_id?(id), do: is_integer(id) and id > 0

  defp ok_or_error(true), do: :ok
  defp ok_or_error(false), do: {:error, :invalid_record}

  defp retained_within_limit?(record, cap) do
    case RetainedSize.bytes_with_cap(record, cap) do
      bytes when is_integer(bytes) and bytes <= cap -> true
      _bytes -> false
    end
  end

  defp normalize(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key),
           {:ok, item} <- normalize(item) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        _reason -> {:halt, {:error, :invalid_record}}
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

  defp valid_id?(id),
    do: is_binary(id) and String.valid?(id) and byte_size(id) in 1..256

  defp await_stop(ref, pid, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> :ok
    end
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp call(%__MODULE__{pid: pid, token: token}, request) do
    GenServer.call(pid, {token, request})
  catch
    :exit, _reason -> {:error, :inspection_sink_error}
  end
end
