defmodule PtcRunner.Kernel.InspectionSink do
  @moduledoc """
  Required, bounded in-memory owner for sensitive developer inspection records.

  Capture is host-enabled and fail-closed. Version 1 accepts capability-input,
  capability-output, subordinate evaluation-source, and prelude-source.
  Version 2 adds correlated exact MCP request and response bodies. It
  normalizes atom keys and enum values to JSON strings, assigns the run
  identity, sequence, and UTC timestamp, and rejects a record before retention
  when either its retained or encoded size exceeds the installed bounds.

  This sink is independent of Logger, Telemetry, EventSink policy, manifests,
  and Lisp. Records remain private until the host explicitly persists them as
  a `0600` `.inspection.jsonl` artifact.
  """

  use GenServer

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Lisp.RetainedSize

  @default_record_bytes 2_000_000
  @default_total_bytes 16_000_000
  @record_types_v1 ~w(capability-input capability-output evaluation-source prelude-source)
  @record_types_v2 @record_types_v1 ++ ~w(mcp-request mcp-response)
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
      :schema_version,
      :max_record_bytes,
      :max_total_bytes
    ]

    run_id = Keyword.get(opts, :run_id)
    trace_id = Keyword.get(opts, :trace_id)
    schema_version = Keyword.get(opts, :schema_version, 1)
    max_record_bytes = Keyword.get(opts, :max_record_bytes, @default_record_bytes)
    max_total_bytes = Keyword.get(opts, :max_total_bytes, @default_total_bytes)

    if Keyword.keys(opts) -- allowed == [] and schema_version in [1, 2] and valid_id?(run_id) and
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
          {token, owner, run_id, trace_id, schema_version, max_record_bytes, max_total_bytes}
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

  @spec records(t()) :: {:ok, [map()]} | {:error, :inspection_sink_error}
  @doc "Returns retained records in sequence order while the required sink is healthy."
  def records(%__MODULE__{} = sink), do: call(sink, :records)

  @doc false
  @spec owner?(t()) :: boolean()
  def owner?(sink), do: call(sink, :owner?) == true

  @doc false
  @spec owner(t()) :: {:ok, pid()} | {:error, :inspection_sink_error}
  def owner(sink), do: call(sink, :owner)

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
  def init({token, owner, run_id, trace_id, schema_version, max_record_bytes, max_total_bytes}) do
    {:ok,
     %{
       token: token,
       owner: owner,
       owner_ref: Process.monitor(owner),
       run_id: run_id,
       trace_id: trace_id,
       schema_version: schema_version,
       max_record_bytes: max_record_bytes,
       max_total_bytes: max_total_bytes,
       sequence: 0,
       encoded_bytes: 0,
       records: [],
       failed?: false
     }}
  end

  @impl GenServer
  def handle_call({token, :owner}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.owner}, state}

  def handle_call({token, :owner?}, {caller, _tag}, %{token: token} = state),
    do: {:reply, caller == state.owner, state}

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
    with true <- record_type in record_types(state.schema_version),
         candidate <- record(state, record_type, correlation, payload),
         true <- MCPProtocol.within_inspection_document_depth?(candidate),
         {:ok, correlation} <- normalize(correlation),
         {:ok, payload} <- normalize(payload),
         :ok <- shape(record_type, correlation, payload),
         record <- record(state, record_type, correlation, payload),
         true <- retained_within_limit?(record, state.max_record_bytes),
         {:ok, encoded} <- Jason.encode(record),
         bytes = byte_size(encoded) + 1,
         true <- bytes <= state.max_record_bytes,
         true <- state.encoded_bytes + bytes <= state.max_total_bytes do
      retained_record = RetainedSize.detach_binaries(record)

      {:reply, :ok,
       %{
         state
         | sequence: state.sequence + 1,
           encoded_bytes: state.encoded_bytes + bytes,
           records: [retained_record | state.records]
       }}
    else
      _reason -> {:reply, {:error, :inspection_sink_error}, %{state | failed?: true}}
    end
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

  defp shape("capability-input", %{"capability_id" => id}, payload) do
    valid? =
      exact_payload(payload, ~w(environment name arguments)) and valid_id?(id) and
        valid_capability_payload?(payload, "arguments")

    ok_or_error(valid?)
  end

  defp shape("capability-output", %{"capability_id" => id}, payload) do
    valid? =
      exact_payload(payload, ~w(environment name result)) and valid_id?(id) and
        valid_capability_payload?(payload, "result")

    ok_or_error(valid?)
  end

  defp shape("evaluation-source", %{"evaluation_id" => id}, payload) do
    valid? =
      exact_payload(
        payload,
        ~w(environment program_kind source source_hash source_bytes)
      ) and valid_id?(id) and payload["environment"] == "mission" and
        payload["program_kind"] == "ptc-lisp" and is_binary(payload["source"]) and
        payload["source_hash"] == sha256(payload["source"]) and
        payload["source_bytes"] == byte_size(payload["source"])

    ok_or_error(valid?)
  end

  defp shape("prelude-source", %{"component_id" => id}, payload) do
    valid? =
      exact_payload(payload, ~w(environment source source_hash source_bytes)) and
        valid_id?(id) and payload["environment"] in ["workflow", "mission"] and
        is_binary(payload["source"]) and
        payload["source_hash"] == sha256(payload["source"]) and
        payload["source_bytes"] == byte_size(payload["source"])

    ok_or_error(valid?)
  end

  defp shape(
         "mcp-request",
         %{"capability_id" => capability_id, "request_id" => request_id} = correlation,
         payload
       ) do
    valid? =
      exact_payload(correlation, ~w(capability_id request_id)) and
        exact_payload(payload, ~w(transport body)) and valid_id?(capability_id) and
        valid_request_id?(request_id) and payload["transport"] in ["stdio", "streamable_http"] and
        MCPProtocol.valid_exchange_request?(payload["body"], request_id)

    ok_or_error(valid?)
  end

  defp shape(
         "mcp-response",
         %{"capability_id" => capability_id, "request_id" => request_id} = correlation,
         payload
       ) do
    valid? =
      exact_payload(correlation, ~w(capability_id request_id)) and
        exact_payload(payload, ~w(transport body)) and valid_id?(capability_id) and
        valid_request_id?(request_id) and payload["transport"] in ["stdio", "streamable_http"] and
        MCPProtocol.valid_exchange_response?(payload["body"], request_id)

    ok_or_error(valid?)
  end

  defp shape(_record_type, _correlation, _payload), do: {:error, :invalid_record}

  defp exact_payload(payload, keys) do
    Map.keys(payload) |> Enum.sort() == Enum.sort(keys) and JSONValue.map?(payload)
  end

  defp valid_capability_payload?(payload, value_key) do
    payload["environment"] in ["workflow", "mission"] and
      valid_id?(payload["name"]) and is_map(payload[value_key])
  end

  defp record_types(1), do: @record_types_v1
  defp record_types(2), do: @record_types_v2
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
