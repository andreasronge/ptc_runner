defmodule PtcRunner.Kernel.EventSinkState do
  @moduledoc false

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Lisp.RetainedSize

  @event_type ~r/\A[a-z][a-z0-9-]{0,127}\z/
  @drop_type_buckets 16
  @drop_overflow "$overflow"
  @drop_count_limit 4_294_967_295

  @doc false
  def new(policy, limits, token, run_id, trace_id, terminal_reserve) do
    %{
      policy: policy,
      limits: limits,
      token: token,
      run_id: run_id,
      trace_id: trace_id,
      sequence: 0,
      bytes: 0,
      events: [],
      dropped: %{},
      terminal_reserve: terminal_reserve,
      claimed_by: nil,
      begun?: false,
      finalized?: false
    }
  end

  @doc false
  def handle(
        {token, {:begin, claim_id, data}},
        %{token: token, begun?: false, finalized?: false} = state
      )
      when is_reference(claim_id) do
    with {:ok, event, bytes} <- event_with_bytes(state, "run-started", data),
         true <- ordinary_capacity?(state, bytes) do
      next = retain_event(%{state | begun?: true, claimed_by: claim_id}, event, bytes)
      {:ok, next}
    else
      _error -> {{:error, :event_sink_error}, state}
    end
  end

  def handle(
        {token, {:begin, claim_id, _data}},
        %{token: token, begun?: true, claimed_by: claim_id} = state
      ),
      do: {{:error, :event_sink_already_claimed}, state}

  def handle(
        {token, {:begin, claim_id, _data}},
        %{token: token, begun?: true} = state
      )
      when is_reference(claim_id),
      do: {{:error, :event_sink_claimed_by_other}, state}

  def handle(
        {token, {:emit, _type, _data}},
        %{token: token, finalized?: true} = state
      ),
      do: {{:error, :event_sink_error}, state}

  def handle({token, {:emit, type, data}}, %{token: token} = state) do
    case event_with_bytes(state, type, data) do
      {:ok, event, bytes} -> enqueue(state, event, bytes)
      :error -> sink_failure(state, type)
    end
  end

  def handle(
        {token, {:finalize_and_events, stopped_data}},
        %{token: token} = state
      ) do
    case finalize_state(state, stopped_data) do
      {:ok, next} ->
        batch = %{events: Enum.reverse(next.events), dropped: next.dropped}
        {{:ok, batch}, next}

      :error ->
        {{:error, :event_sink_error}, state}
    end
  end

  def handle({token, :events}, %{token: token} = state),
    do: {Enum.reverse(state.events), state}

  def handle({token, :dropped}, %{token: token} = state), do: {state.dropped, state}
  def handle({token, :policy}, %{token: token} = state), do: {state.policy, state}

  def handle({token, :identity}, %{token: token} = state),
    do: {%{run_id: state.run_id, trace_id: state.trace_id}, state}

  def handle({token, {:begin_capacity?, data}}, %{token: token} = state) do
    fits? =
      match?({:ok, _event, _bytes}, event_with_ordinary_capacity(state, "run-started", data))

    {fits?, state}
  end

  def handle({token, :session_contract}, %{token: token} = state) do
    contract = %{
      terminal_reserve: state.terminal_reserve,
      limits: state.limits,
      ready?: ready?(state),
      event_count: length(state.events),
      event_bytes: state.bytes,
      begun?: state.begun?,
      dropped?: map_size(state.dropped) != 0
    }

    {contract, state}
  end

  def handle({_token, _request}, state), do: {{:error, :event_sink_error}, state}

  @doc false
  def ready?(state), do: not state.finalized?

  @doc false
  def payload_within_limit?(data, limit) when is_map(data) and is_integer(limit) and limit > 0 do
    with {:ok, normalized_data} <- normalize_json(data),
         true <- JSONValue.map?(normalized_data),
         bytes when is_integer(bytes) <- RetainedSize.bytes_with_cap(normalized_data, limit),
         do: bytes <= limit
  end

  def payload_within_limit?(_data, _limit), do: false

  defp enqueue(state, event, bytes) do
    if ordinary_capacity?(state, bytes) do
      {:ok, retain_event(state, event, bytes)}
    else
      sink_failure(state, event.type)
    end
  end

  defp event_with_ordinary_capacity(state, type, data) do
    with {:ok, event, bytes} <- event_with_bytes(state, type, data),
         true <- ordinary_capacity?(state, bytes) do
      {:ok, event, bytes}
    else
      _ -> :error
    end
  end

  defp ordinary_capacity?(state, bytes) do
    reserve = state.terminal_reserve

    not state.finalized? and
      length(state.events) < state.limits.normal_event_count - reserve.count and
      state.bytes + bytes <= state.limits.normal_event_bytes - reserve.bytes
  end

  defp retain_event(state, event, bytes) do
    %{
      state
      | sequence: state.sequence + 1,
        bytes: state.bytes + bytes,
        events: [event | state.events]
    }
  end

  defp sink_failure(%{policy: :private} = state, _type),
    do: {{:error, :event_sink_error}, state}

  defp sink_failure(state, type) do
    bucket = drop_bucket(state.dropped, type)
    dropped = Map.update(state.dropped, bucket, 1, &increment_drop_count/1)
    {:ok, %{state | dropped: dropped}}
  end

  defp drop_bucket(dropped, type) do
    cond do
      Map.has_key?(dropped, type) -> type
      valid_drop_type?(type) and drop_type_bucket_count(dropped) < @drop_type_buckets -> type
      true -> @drop_overflow
    end
  end

  defp valid_drop_type?(type), do: is_binary(type) and type =~ @event_type

  defp drop_type_bucket_count(dropped) do
    map_size(dropped) - if(Map.has_key?(dropped, @drop_overflow), do: 1, else: 0)
  end

  defp increment_drop_count(count) when count < @drop_count_limit, do: count + 1
  defp increment_drop_count(_count), do: @drop_count_limit

  defp event_with_bytes(state, type, data) do
    payload_cap = state.limits.event_payload_bytes
    event_cap = state.limits.normal_event_bytes

    with true <- is_binary(type) and type =~ @event_type,
         {:ok, normalized_data} <- normalize_json(data),
         true <- JSONValue.map?(normalized_data),
         payload_bytes when is_integer(payload_bytes) <-
           RetainedSize.bytes_with_cap(normalized_data, payload_cap),
         true <- payload_bytes <= payload_cap,
         event = event(state, type, data),
         accounted_event = event(state, type, normalized_data),
         event_bytes when is_integer(event_bytes) <-
           RetainedSize.bytes_with_cap(accounted_event, event_cap),
         true <- event_bytes <= event_cap do
      {:ok, event, event_bytes}
    else
      _ -> :error
    end
  end

  defp finalize_state(%{finalized?: true} = state, _stopped_data),
    do: {:ok, state}

  defp finalize_state(state, stopped_data) do
    with {:ok, stopped_data} <- put_dropped_usage(stopped_data, state.dropped),
         terminal = terminal_events(stopped_data, state.dropped),
         true <- terminal_capacity?(state, terminal),
         {:ok, next} <- enqueue_terminal_events(%{state | finalized?: true}, terminal) do
      {:ok, next}
    else
      _ -> :error
    end
  end

  defp put_dropped_usage(stopped_data, dropped) do
    case Map.get(stopped_data, :usage, %{}) do
      usage when is_map(usage) and not is_struct(usage) ->
        {:ok, Map.put(stopped_data, :usage, Map.put(usage, :events_dropped, dropped))}

      _invalid ->
        :error
    end
  end

  defp terminal_events(stopped_data, dropped) when map_size(dropped) == 0,
    do: [{"run-stopped", stopped_data}]

  defp terminal_events(stopped_data, dropped),
    do: [{"events-dropped", %{counts: dropped}}, {"run-stopped", stopped_data}]

  defp terminal_capacity?(%{policy: :normal} = state, terminal),
    do: length(terminal) <= state.terminal_reserve.count

  defp terminal_capacity?(%{policy: :private}, _terminal), do: true

  defp enqueue_terminal_events(state, []), do: {:ok, state}

  defp enqueue_terminal_events(state, [{type, data} | rest]) do
    with {:ok, event, bytes} <- event_with_bytes(state, type, data),
         true <- length(state.events) < state.limits.normal_event_count,
         true <- state.bytes + bytes <= state.limits.normal_event_bytes do
      next = %{
        state
        | sequence: state.sequence + 1,
          bytes: state.bytes + bytes,
          events: [event | state.events]
      }

      enqueue_terminal_events(next, rest)
    else
      _ -> :error
    end
  end

  defp event(state, type, data) do
    %{
      schema_version: 1,
      run_id: state.run_id,
      trace_id: state.trace_id,
      sequence: state.sequence + 1,
      timestamp: DateTime.utc_now(),
      type: type,
      data: data
    }
  end

  defp normalize_json(nil), do: {:ok, nil}
  defp normalize_json(value) when is_boolean(value) or is_number(value), do: {:ok, value}
  defp normalize_json(value) when is_binary(value), do: {:ok, value}
  defp normalize_json(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_json(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, normalized} ->
      case normalize_json(item) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp normalize_json(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key),
           {:ok, item} <- normalize_json(item) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp normalize_json(_value), do: :error
  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: :error
end
