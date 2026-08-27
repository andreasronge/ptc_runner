defmodule PtcRunner.Kernel.InspectionSink do
  @moduledoc """
  Required owner for bounded streaming private inspection evidence.

  The sink validates and deterministically encodes one record at a time, then
  appends its length-framed bytes to an exclusive missing-destination
  reservation. It retains only incremental digests, identities, counts, and
  limits. `seal/1` appends and synchronizes the terminal footer; it never
  returns or retains a complete record collection.

  A record emitted with digest-results capture has its value replaced by a
  deterministic value identity. The sink computes the identity, so an emitter
  sends the same message in both capture modes and enabling digest capture
  cannot change the emitting process's heap behaviour.
  """

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.InspectionArtifact.Limits
  alias PtcRunner.Kernel.InspectionArtifact.Writer
  alias PtcRunner.Kernel.InspectionValueIdentity
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.OwnerHandoff
  alias PtcRunner.Kernel.PublicationHandle

  @stop_timeout_ms 5_000

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(keyword()) :: {:ok, t()} | {:error, :invalid_inspection_sink}
  def start(opts) when is_list(opts) do
    allowed = [
      :run_id,
      :trace_id,
      :owner,
      :publication_handle,
      :max_record_bytes,
      :max_total_bytes,
      :max_records,
      :writer_hook
    ]

    limit_opts = Keyword.take(opts, [:max_record_bytes, :max_total_bytes, :max_records])

    with true <- Keyword.keys(opts) -- allowed == [],
         run_id when is_binary(run_id) <- Keyword.get(opts, :run_id),
         trace_id when is_binary(trace_id) <- Keyword.get(opts, :trace_id),
         true <- valid_id?(run_id) and valid_id?(trace_id),
         owner when is_pid(owner) <- Keyword.get(opts, :owner, self()),
         %PublicationHandle{kind: :inspection} = handle <-
           Keyword.get(opts, :publication_handle),
         {:ok, limits} <- Limits.merge(limit_opts),
         writer_hook when is_nil(writer_hook) or is_function(writer_hook, 1) <-
           Keyword.get(opts, :writer_hook),
         token <- make_ref(),
         {:ok, pid} <-
           GenServer.start(
             __MODULE__,
             {token, owner, run_id, trace_id, handle, limits, writer_hook}
           ) do
      {:ok, %__MODULE__{pid: pid, token: token}}
    else
      _invalid -> {:error, :invalid_inspection_sink}
    end
  end

  def start(_opts), do: {:error, :invalid_inspection_sink}

  @spec emit(t(), binary(), map(), map(), keyword()) :: :ok | {:error, :inspection_sink_error}
  def emit(sink, record_type, correlation, payload, opts \\ [])

  def emit(%__MODULE__{} = sink, record_type, correlation, payload, opts)
      when is_binary(record_type) and is_map(correlation) and is_map(payload) and
             opts in [[], [capture: :digest_results]],
      do: call(sink, {:emit, record_type, correlation, payload, capture_mode(opts)})

  def emit(%__MODULE__{} = sink, _record_type, _correlation, _payload, _opts),
    do: call(sink, :fail)

  @doc false
  @spec emit_mcp_exchange(t(), map(), map(), map(), map() | nil, keyword()) ::
          :ok | {:error, :inspection_sink_error}
  def emit_mcp_exchange(sink, correlation, request, response, stderr \\ nil, opts \\ [])

  def emit_mcp_exchange(%__MODULE__{} = sink, correlation, request, response, stderr, opts)
      when is_map(correlation) and is_map(request) and is_map(response) and
             (is_nil(stderr) or is_map(stderr)) and
             opts in [[], [response_capture: :digest_results]],
      do:
        call(
          sink,
          {:emit_mcp_exchange, correlation, request, response, stderr, response_mode(opts)}
        )

  def emit_mcp_exchange(%__MODULE__{} = sink, _correlation, _request, _response, _stderr, _opts),
    do: call(sink, :fail)

  defp capture_mode(opts), do: Keyword.get(opts, :capture, :full)
  defp response_mode(opts), do: Keyword.get(opts, :response_capture, :full)

  @spec seal(t()) :: {:ok, map()} | {:error, :inspection_sink_error}
  @doc "Seals and synchronizes the streamed artifact and returns bounded publication metadata."
  def seal(%__MODULE__{} = sink), do: call(sink, :seal)

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
  def init({token, owner, run_id, trace_id, handle, limits, writer_hook}) do
    case Writer.new(handle, run_id, trace_id, limits, writer_hook: writer_hook) do
      {:ok, writer} ->
        {:ok,
         %{
           token: token,
           owner: owner,
           owner_ref: Process.monitor(owner),
           owner_transferable?: true,
           run_id: run_id,
           trace_id: trace_id,
           writer: writer,
           result?: false,
           failed?: false
         }}

      {:error, _reason} ->
        {:stop, :inspection_sink_error}
    end
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
      ) do
    case OwnerHandoff.transfer_once(state, owner) do
      {:ok, next} -> {:reply, :ok, next}
      :error -> {:reply, {:error, :inspection_sink_error}, state}
    end
  end

  def handle_call(
        {token, {:emit, record_type, correlation, payload, capture}},
        _from,
        %{token: token} = state
      ) do
    case digest_payload(record_type, correlation, payload, capture) do
      {:ok, payload} -> append_one(state, record_type, correlation, payload)
      :error -> failed_reply(state)
    end
  end

  def handle_call(
        {token, {:emit_mcp_exchange, correlation, request, response, stderr, capture}},
        _from,
        %{token: token} = state
      ) do
    case digest_payload("mcp-response", correlation, response, capture) do
      {:ok, response} ->
        with {:ok, state} <- append(state, "mcp-request", correlation, request),
             {:ok, state} <- append(state, "mcp-response", correlation, response),
             {:ok, state} <- append_stderr(state, correlation, stderr) do
          {:reply, :ok, state}
        else
          {:error, state} -> failed_reply(state)
        end

      :error ->
        failed_reply(state)
    end
  end

  def handle_call({token, :seal}, _from, %{token: token, failed?: false} = state) do
    case Writer.seal(state.writer) do
      {:ok, seal, writer} -> {:reply, {:ok, seal}, %{state | writer: writer}}
      {:error, _reason} -> failed_reply(state)
    end
  end

  def handle_call({token, :seal}, _from, %{token: token} = state),
    do: {:reply, {:error, :inspection_sink_error}, state}

  def handle_call({token, :fail}, _from, %{token: token} = state), do: failed_reply(state)

  def handle_call({_token, _request}, _from, state),
    do: {:reply, {:error, :inspection_sink_error}, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :inspection_sink_error}, state}

  @impl GenServer
  # ex_dna:disable-for-next-line — OTP no-op cast callback is intentionally local to this owner
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp append_one(%{failed?: true} = state, _type, _correlation, _payload),
    do: {:reply, {:error, :inspection_sink_error}, state}

  defp append_one(%{result?: true} = state, "run-result", _correlation, _payload),
    do: failed_reply(state)

  defp append_one(state, type, correlation, payload) do
    case append(state, type, correlation, payload) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state} -> failed_reply(state)
    end
  end

  defp append(state, type, correlation, payload) do
    case Writer.append(state.writer, type, correlation, payload) do
      {:ok, writer} ->
        {:ok, %{state | writer: writer, result?: state.result? or type == "run-result"}}

      {:error, _reason} ->
        {:error, state}
    end
  end

  defp append_stderr(state, _correlation, nil), do: {:ok, state}

  defp append_stderr(state, correlation, payload) do
    case Map.get(payload, :text, Map.get(payload, "text")) do
      text when is_binary(text) and text != "" ->
        append(state, "mcp-stderr", correlation, payload)

      _empty ->
        {:ok, state}
    end
  end

  # Digest-results capture replaces the record's value with its identity here,
  # after validating the full value exactly as full capture would, because an
  # identity can no longer be checked against its exchange once the value is
  # gone. A digest request for any other record type, a missing value, or a
  # value the identity rejects fails the sink, the same channel an invalid
  # full payload uses.
  defp digest_payload(_record_type, _correlation, payload, :full), do: {:ok, payload}

  defp digest_payload("capability-output", _correlation, payload, :digest_results) do
    case Map.fetch(payload, :result) do
      {:ok, result} when is_map(result) -> swap_value(payload, :result, :result_identity)
      _invalid -> :error
    end
  end

  defp digest_payload("mcp-response", correlation, payload, :digest_results) do
    if MCPProtocol.valid_inspection_exchange?(
         "mcp-response",
         Map.get(payload, :body),
         correlation[:request_id]
       ) do
      swap_value(payload, :body, :body_identity)
    else
      :error
    end
  end

  defp digest_payload(_record_type, _correlation, _payload, _capture), do: :error

  defp swap_value(payload, key, identity_key) do
    with {:ok, value} <- Map.fetch(payload, key),
         {:ok, identity} <- InspectionValueIdentity.identity(value) do
      {:ok, payload |> Map.delete(key) |> Map.put(identity_key, identity)}
    else
      _invalid -> :error
    end
  end

  defp failed_reply(state),
    do: {:reply, {:error, :inspection_sink_error}, %{state | failed?: true}}

  defp valid_id?(id), do: byte_size(id) in 1..256 and String.valid?(id)

  defp await_stop(ref, pid, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> :ok
    end
  end

  defp call(%__MODULE__{pid: pid, token: token}, request) do
    GenServer.call(pid, {token, request})
  catch
    :exit, _reason -> {:error, :inspection_sink_error}
  end
end
