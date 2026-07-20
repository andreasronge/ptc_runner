defmodule PtcRunner.Kernel.EventSinkState do
  @moduledoc false

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Lisp.RetainedSize

  @event_type ~r/\A[a-z][a-z0-9-]{0,127}\z/

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
      finalized?: false
    }
  end

  @doc false
  def handle({token, {:emit, type, data}}, %{token: token} = state) do
    case event_with_bytes(state, type, data) do
      {:ok, event, bytes} -> enqueue(state, event, bytes)
      :error -> sink_failure(state, type)
    end
  end

  def handle(
        {token, {:finalize, dropped_data, stopped_data}},
        %{token: token, policy: :normal} = state
      ) do
    case finalize_state(state, dropped_data, stopped_data) do
      {:ok, next} -> {:ok, next}
      :error -> {{:error, :event_sink_error}, state}
    end
  end

  def handle(
        {token, {:finalize_and_events, dropped_data, stopped_data}},
        %{token: token, policy: :normal} = state
      ) do
    case finalize_state(state, dropped_data, stopped_data) do
      {:ok, next} -> {{:ok, Enum.reverse(next.events)}, next}
      :error -> {{:error, :event_sink_error}, state}
    end
  end

  def handle({token, :events}, %{token: token} = state),
    do: {Enum.reverse(state.events), state}

  def handle({token, :dropped}, %{token: token} = state), do: {state.dropped, state}
  def handle({token, :policy}, %{token: token} = state), do: {state.policy, state}

  def handle({token, :identity}, %{token: token} = state),
    do: {%{run_id: state.run_id, trace_id: state.trace_id}, state}

  def handle({token, :session_contract}, %{token: token} = state) do
    contract = %{
      terminal_reserve: state.terminal_reserve,
      ready?: ready?(state),
      event_count: length(state.events),
      event_bytes: state.bytes,
      dropped?: map_size(state.dropped) != 0
    }

    {contract, state}
  end

  def handle({_token, _request}, state), do: {{:error, :event_sink_error}, state}

  @doc false
  def ready?(state), do: not state.finalized?

  defp enqueue(state, event, bytes) do
    reserve = state.terminal_reserve

    full? =
      state.finalized? or
        length(state.events) >= state.limits.normal_event_count - reserve.count or
        state.bytes + bytes > state.limits.normal_event_bytes - reserve.bytes

    if full? do
      sink_failure(state, event.type)
    else
      {:ok,
       %{
         state
         | sequence: state.sequence + 1,
           bytes: state.bytes + bytes,
           events: [event | state.events]
       }}
    end
  end

  defp sink_failure(%{policy: :private} = state, _type),
    do: {{:error, :event_sink_error}, state}

  defp sink_failure(state, type) do
    dropped = Map.update(state.dropped, type, 1, &(&1 + 1))
    {:ok, %{state | dropped: dropped}}
  end

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

  defp finalize_state(%{finalized?: true} = state, _dropped_data, _stopped_data),
    do: {:ok, state}

  defp finalize_state(state, dropped_data, stopped_data) do
    terminal =
      if map_size(state.dropped) == 0 do
        [{"run-stopped", stopped_data}]
      else
        [
          {"events-dropped", Map.put(dropped_data, :counts, state.dropped)},
          {"run-stopped", stopped_data}
        ]
      end

    with true <- length(terminal) <= state.terminal_reserve.count,
         {:ok, next} <- enqueue_terminal_events(%{state | finalized?: true}, terminal) do
      {:ok, next}
    else
      _ -> :error
    end
  end

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
