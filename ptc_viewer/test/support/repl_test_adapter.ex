defmodule PtcViewer.TestReplAdapter do
  @behaviour PtcViewer.ReplAdapter

  @impl true
  def connect(%{connect_error: true}), do: {:error, :connection_rejected}

  def connect(%{bad_features: true, test_pid: test_pid} = config) when is_pid(test_pid) do
    {:ok, backend} = Agent.start_link(fn -> initial_state(config) end)
    {:ok, backend, %{"enabled" => true, "profile_id" => "arbitrary"}}
  end

  def connect(%{test_pid: test_pid} = config) when is_pid(test_pid) do
    {:ok, backend} = Agent.start_link(fn -> initial_state(config) end)

    {:ok, backend,
     %{
       "enabled" => true,
       "profile_id" => "run-analysis-v1",
       "namespaces" => ["analysis", "cap"],
       "source_limit_bytes" => 65_536
     }}
  end

  def connect(_config), do: {:error, :invalid_config}

  @impl true
  def prepare_operation(backend, session, kind, operation_id) do
    Agent.get_and_update(backend, fn state ->
      key = {kind, operation_id}
      send(state.test_pid, {:prepare_attempt, key})

      cond do
        state.prepare_error? ->
          {{:error, :prepare_rejected}, state}

        Map.has_key?(state.operations, key) ->
          {:ok, state}

        kind == :start and is_nil(session) ->
          {:ok, put_in(state.operations[key], %{session: nil})}

        session == state.session ->
          {:ok, put_in(state.operations[key], %{session: session})}

        true ->
          {{:error, :invalid_operation}, state}
      end
    end)
  end

  @impl true
  def start(backend, operation_id, public_session_id) do
    Agent.get_and_update(backend, fn state ->
      key = {:start, operation_id}

      case Map.get(state.operations, key) do
        %{result: result} ->
          {result, state}

        %{session: nil} ->
          if state.next_start_error do
            result = {:error, state.next_start_error}

            {result,
             %{state | next_start_error: nil} |> put_in([:operations, key, :result], result)}
          else
            session = {:test_session, make_ref()}
            info = info(public_session_id, :open, 0)
            result = {:ok, session, info}

            {result,
             %{state | session: session, public_session_id: public_session_id}
             |> put_in([:operations, key, :result], result)}
          end

        _missing ->
          {{:error, :operation_not_prepared}, state}
      end
    end)
  end

  @impl true
  def reconcile_start(backend, operation_id), do: operation_result(backend, :start, operation_id)

  @impl true
  def evaluate(backend, session, operation_id, source) do
    maybe_block(backend, source)

    Agent.get_and_update(backend, fn state ->
      key = {:evaluation, operation_id}

      case Map.get(state.operations, key) do
        %{result: result} ->
          {result, state}

        %{session: ^session} ->
          count = state.evaluation_count + 1

          result =
            if source == "malformed-result" do
              {:ok, :not_a_projection}
            else
              usage =
                if source == "large-usage",
                  do: Map.put(usage(count), :padding, String.duplicate("x", 300_000)),
                  else: usage(count)

              {status, outcome, effect, error} = outcome(source)

              {:ok,
               %{
                 evaluation_id: "evaluation-#{count}",
                 status: status,
                 outcome: outcome,
                 continuation_effect: effect,
                 value: count,
                 value_available?: true,
                 formatted: Integer.to_string(count),
                 formatted_truncated?: false,
                 prints: [],
                 prints_truncated?: false,
                 error: error,
                 duration_ms:
                   if(source == "oversized-duration", do: Integer.pow(10, 150_000), else: 1),
                 usage: usage
               }}
            end

          next = %{state | evaluation_count: count} |> put_in([:operations, key, :result], result)
          {result, next}

        _missing ->
          {{:error, :operation_not_prepared}, state}
      end
    end)
  end

  @impl true
  def reconcile_evaluate(backend, _session, operation_id),
    do: operation_result(backend, :evaluation, operation_id)

  @impl true
  def template(_backend, _session, kind, run_id) when kind in [:run, :turns] do
    {operation, suffix} = if kind == :run, do: {"overview", ")"}, else: {"activity", " {})"}
    {:ok, %{source: "(analysis/#{operation} #{inspect(run_id)}#{suffix}"}}
  end

  @impl true
  def info(backend, session) do
    Agent.get(backend, fn state ->
      if state.session == session,
        do: {:ok, info(state.public_session_id, state.lifecycle, state.evaluation_count)},
        else: {:error, :session_closed}
    end)
  end

  @impl true
  def close(backend, session, operation_id) do
    Agent.get_and_update(backend, fn state ->
      key = {:close, operation_id}

      case Map.get(state.operations, key) do
        %{result: result} ->
          {result, state}

        %{session: ^session} ->
          result = {:ok, info(state.public_session_id, :closed, state.evaluation_count)}
          {result, %{state | lifecycle: :closed} |> put_in([:operations, key, :result], result)}

        _missing ->
          {{:error, :operation_not_prepared}, state}
      end
    end)
  end

  @impl true
  def reconcile_close(backend, _session, operation_id),
    do: operation_result(backend, :close, operation_id)

  @impl true
  def acknowledge_operation(backend, kind, operation_id) do
    Agent.get_and_update(backend, fn state ->
      send(state.test_pid, {:ack_attempt, {kind, operation_id}})

      if state.ack_failures_remaining > 0 do
        {{:error, :temporary_ack_failure},
         %{state | ack_failures_remaining: state.ack_failures_remaining - 1}}
      else
        key = {kind, operation_id}
        operation = Map.get(state.operations, key)
        state = %{state | operations: Map.delete(state.operations, key)}

        state =
          if kind == :close and match?(%{result: {:ok, _}}, operation),
            do: %{state | session: nil},
            else: state

        {:ok, state}
      end
    end)
  end

  @impl true
  def abort(backend, _session, _reason) do
    Agent.get_and_update(backend, fn state ->
      {{:ok, info(state.public_session_id, :closed, state.evaluation_count)},
       %{state | session: nil, lifecycle: :closed}}
    end)
  end

  def state(backend), do: Agent.get(backend, & &1)

  def set_ack_failures(backend, count),
    do: Agent.update(backend, &%{&1 | ack_failures_remaining: count})

  def set_prepare_error(backend, enabled),
    do: Agent.update(backend, &%{&1 | prepare_error?: enabled})

  def set_next_start_error(backend, reason),
    do: Agent.update(backend, &%{&1 | next_start_error: reason})

  defp operation_result(backend, kind, operation_id) do
    Agent.get(backend, fn state ->
      case Map.get(state.operations, {kind, operation_id}) do
        %{result: result} -> result
        _missing -> {:error, :not_accepted}
      end
    end)
  end

  defp maybe_block(backend, "block") do
    test_pid = Agent.get(backend, & &1.test_pid)
    send(test_pid, {:evaluation_started, self()})

    receive do
      :release_evaluation -> :ok
    end
  end

  defp maybe_block(_backend, _source), do: :ok

  defp outcome("recoverable-error"),
    do:
      {:error, :evaluation_error, :preserved,
       %{kind: :invalid_form, reason: :unknown_namespace, message: "recoverable"}}

  defp outcome("memory-exceeded"),
    do: {:error, :memory_exceeded, :preserved, %{kind: :memory_exceeded}}

  defp outcome("history-exceeded"),
    do: {:error, :history_exceeded, :preserved, %{kind: :history_exceeded}}

  defp outcome("result-exceeded"),
    do: {:error, :result_exceeded, :committed_with_history, %{kind: :result_exceeded}}

  defp outcome(_source), do: {:ok, :continued, :committed_with_history, nil}

  defp initial_state(config) do
    %{
      test_pid: config.test_pid,
      operations: %{},
      session: nil,
      public_session_id: nil,
      lifecycle: :open,
      evaluation_count: 0,
      ack_failures_remaining: Map.get(config, :ack_failures, 0),
      prepare_error?: false,
      next_start_error: nil
    }
  end

  defp info(session_id, lifecycle, count) do
    %{
      session_id: session_id,
      lifecycle: lifecycle,
      profile_id: "run-analysis-v1",
      profile_digest: String.duplicate("a", 64),
      namespaces: ["analysis", "cap"],
      snapshot: %{
        capture_id: "capture",
        captured_at: DateTime.utc_now(),
        run_count: 1,
        source_bytes: 10,
        retained_bytes: 10
      },
      evaluation_count: count,
      terminal_reason: nil,
      usage: usage(count),
      trace: %{
        persistence: if(lifecycle == :closed, do: :persisted, else: :open),
        event_count: count
      }
    }
  end

  defp usage(count) do
    %{
      remaining_ms: 60_000,
      evaluations: %{used: count, limit: 64, remaining: 64 - count},
      mission_calls: %{used: 0, limit: 512, remaining: 512},
      trace_calls: %{},
      continuation: %{
        defined_count: 0,
        memory_bytes: 0,
        history_count: count,
        history_bytes: count,
        bytes: count
      }
    }
  end
end
