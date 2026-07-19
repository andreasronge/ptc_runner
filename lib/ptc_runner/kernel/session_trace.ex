defmodule PtcRunner.Kernel.SessionTrace do
  @moduledoc """
  Owner of one log-analysis session's canonical event batch and publication.

  The trace owner supervises a combined run-state/event owner, guards
  construction until the builder marks it complete, retains the calling process
  as stable lifecycle owner, monitors the evaluation owner, and retains a
  finalized batch for close retries while that owner remains available.
  Finalization and batch handoff are one owner operation. Publication is atomic
  and no-clobber; retrying never appends or emits another terminal event.
  Unexpected evaluation- or lifecycle-owner death gets one independent
  best-effort publication attempt before this trace owner stops; that path has
  no surviving caller-visible retry authority.
  """
  use GenServer

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @doc false
  def start(%Limits{} = limits, destination, run_id, opts \\ [])
      when is_binary(destination) and is_binary(run_id) and is_list(opts) do
    token = make_ref()
    fault_hook = Keyword.get(opts, :persistence_fault_hook)
    resource_cleanup_hook = Keyword.get(opts, :resource_cleanup_hook)
    owner = Keyword.get(opts, :owner, self())
    run_state = Keyword.get(opts, :run_state)
    sink = Keyword.get(opts, :event_sink)

    if Keyword.keys(opts) --
         [:owner, :persistence_fault_hook, :resource_cleanup_hook, :run_state, :event_sink] == [] and
         is_pid(owner) and match?(%RunState{}, run_state) and match?(%EventSink{}, sink) and
         run_state.pid == sink.pid and (is_nil(fault_hook) or is_function(fault_hook, 1)) and
         (is_nil(resource_cleanup_hook) or is_function(resource_cleanup_hook, 0)) and
         valid_trace_contract?(limits, destination, run_id, run_state, sink) do
      case GenServer.start(
             __MODULE__,
             {limits, destination, run_id, token, fault_hook, resource_cleanup_hook, owner,
              run_state, sink}
           ) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
        {:error, _reason} -> {:error, :session_trace_failed}
      end
    else
      {:error, :session_trace_failed}
    end
  end

  @doc false
  def sink(trace), do: call(trace, :sink)

  @doc false
  def attach(trace, session_pid, run_state, snapshot)
      when is_pid(session_pid),
      do: call(trace, {:attach, session_pid, run_state, snapshot})

  @doc false
  def finalize(trace, outcome, reason, usage),
    do: call(trace, {:finalize, outcome, reason, usage})

  @doc false
  def mark_terminal(trace, reason) when is_atom(reason),
    do: call(trace, {:mark_terminal, reason})

  @doc false
  def valid_binding?(trace, run_state, sink, limits) do
    call(trace, {:valid_binding, run_state, sink, limits}) == true
  catch
    :exit, _reason -> false
  end

  @doc false
  def persist(trace), do: call(trace, :persist, :infinity)

  @doc false
  def info(trace), do: call(trace, :info)

  @doc false
  def resources_closed(trace), do: call(trace, :resources_closed)

  @doc false
  def complete_construction(trace), do: call(trace, :complete_construction)

  @doc false
  def cancel_construction(trace), do: call(trace, :cancel_construction, :infinity)

  @doc false
  def stop(%__MODULE__{pid: pid}) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(
        {limits, destination, run_id, token, fault_hook, resource_cleanup_hook, owner, run_state,
         sink}
      ) do
    {:ok,
     %{
       token: token,
       limits: limits,
       destination: destination,
       run_id: run_id,
       fault_hook: fault_hook,
       resource_cleanup_hook: resource_cleanup_hook,
       sink: sink,
       events: nil,
       persistence: :open,
       terminal: nil,
       pending_terminal_reason: nil,
       lifecycle_owner_ref: Process.monitor(owner),
       lifecycle_owner_pid: owner,
       construction_complete?: false,
       sink_ref: Process.monitor(sink.pid),
       session_ref: nil,
       session_pid: nil,
       run_state: run_state,
       snapshot: nil
     }}
  end

  @impl GenServer
  def handle_call({token, :sink}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.sink}, state}

  def handle_call(
        {token, {:valid_binding, run_state, sink, limits}},
        _from,
        %{token: token} = state
      ) do
    valid? = state.run_state === run_state and state.sink === sink and state.limits === limits
    {:reply, valid?, state}
  end

  def handle_call(
        {token, {:attach, session_pid, run_state, snapshot}},
        _from,
        %{token: token, session_ref: nil, run_state: run_state} = state
      ) do
    {:reply, :ok,
     %{
       state
       | session_ref: Process.monitor(session_pid),
         session_pid: session_pid,
         snapshot: snapshot
     }}
  end

  def handle_call(
        {token, :complete_construction},
        {owner_pid, _tag},
        %{token: token, lifecycle_owner_pid: owner_pid, construction_complete?: false} = state
      ) do
    {:reply, :ok, %{state | construction_complete?: true}}
  end

  def handle_call(
        {token, {:mark_terminal, reason}},
        _from,
        %{token: token, persistence: :open} = state
      ) do
    terminal_reason = state.pending_terminal_reason || reason
    {:reply, :ok, %{state | pending_terminal_reason: terminal_reason}}
  end

  def handle_call({token, {:mark_terminal, _reason}}, _from, %{token: token} = state),
    do: {:reply, :ok, state}

  def handle_call({token, :cancel_construction}, _from, %{token: token} = state) do
    stop_attached_session(state)
    {:stop, :normal, :ok, cleanup_resources(state)}
  end

  def handle_call({token, {:finalize, outcome, reason, usage}}, _from, %{token: token} = state) do
    case finalize_state(state, outcome, reason, usage) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({token, :persist}, _from, %{token: token} = state) do
    case persist_state(state) do
      {:ok, next} -> {:reply, {:ok, safe_info(next)}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({token, :info}, _from, %{token: token} = state),
    do: state |> ensure_recorder_state() |> reply_info()

  def handle_call({token, :resources_closed}, _from, %{token: token} = state) do
    run_resource_cleanup_hook(state.resource_cleanup_hook)
    next = cleanup_resources(state)

    if is_nil(next.run_state) and is_nil(next.snapshot) do
      if is_reference(next.sink_ref), do: Process.demonitor(next.sink_ref, [:flush])
      {:reply, :ok, %{next | sink_ref: nil}}
    else
      {:reply, {:error, :resource_cleanup_failed}, next}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :session_trace_closed}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{lifecycle_owner_ref: ref, construction_complete?: false} = state
      ) do
    stop_attached_session(state)
    {:stop, :normal, cleanup_resources(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{lifecycle_owner_ref: ref, construction_complete?: true} = state
      ) do
    stop_attached_session(state)

    next =
      state
      |> Map.merge(%{
        lifecycle_owner_ref: nil,
        lifecycle_owner_pid: nil,
        session_ref: nil,
        session_pid: nil
      })
      |> finalize_aborted_owner()
      |> cleanup_resources()
      |> persist_aborted_owner()

    {:stop, :normal, next}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{sink_ref: ref} = state),
    do: {:noreply, recorder_failed(state)}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{session_ref: ref, construction_complete?: false} = state
      ) do
    next = %{state | session_ref: nil, session_pid: nil} |> cleanup_resources()
    {:stop, :normal, next}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_ref: ref} = state) do
    owner_reason = if reason == :normal, do: :session_owner_stopped, else: :session_owner_failed
    outcome_reason = state.pending_terminal_reason || owner_reason

    state =
      case finalize_state(state, :error, outcome_reason, %{aborted: true}) do
        {:ok, next} -> next
        {:error, _reason, next} -> next
      end

    state = cleanup_resources(state)

    state =
      case persist_state(state) do
        {:ok, next} -> next
        {:error, _reason, next} -> next
      end

    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  @impl GenServer
  def terminate(_reason, state) do
    _state = cleanup_resources(state)
    :ok
  end

  defp finalize_state(%{persistence: :open} = state, outcome, reason, usage) do
    stopped = %{outcome: outcome, reason: reason, usage: usage}

    case EventSink.finalize_and_events(state.sink, %{}, stopped) do
      {:ok, events} when events != [] ->
        {:ok,
         %{
           state
           | events: events,
             persistence: :terminal_unpersisted,
             terminal: %{outcome: outcome, reason: reason}
         }}

      _error ->
        {:error, :event_sink_error, state}
    end
  end

  defp finalize_state(%{persistence: :backend_failed} = state, _outcome, _reason, _usage),
    do: {:error, :event_sink_error, state}

  defp finalize_state(state, _outcome, _reason, _usage), do: {:ok, state}

  defp valid_trace_contract?(limits, destination, run_id, run_state, sink) do
    expected_reserve = %{count: 2, bytes: limits.event_payload_bytes * 2}

    String.valid?(destination) and String.valid?(run_id) and run_id != "" and
      Path.basename(destination) == run_id <> ".jsonl" and sink.policy == :normal and
      sink.fail_closed? and RunState.limits(run_state) === limits and
      RunState.open?(run_state) and
      EventSink.identity(sink) == {:ok, %{run_id: run_id, trace_id: run_id}} and
      EventSink.session_contract(sink) ==
        {:ok,
         %{
           terminal_reserve: expected_reserve,
           ready?: true,
           event_count: 0,
           event_bytes: 0,
           dropped?: false
         }}
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  defp persist_state(%{persistence: :open} = state),
    do: {:error, :session_trace_open, state}

  defp persist_state(%{persistence: :persisted} = state), do: {:ok, state}

  defp persist_state(state) do
    with true <- valid_terminal_batch?(state.events),
         :ok <-
           TraceLog.publish_jsonl(state.destination, state.events, fault_hook: state.fault_hook) do
      {:ok, %{state | persistence: :persisted}}
    else
      {:error, reason} ->
        {:error, reason, %{state | persistence: {:persistence_failed, reason}}}

      false ->
        {:error, :trace_persistence_failed,
         %{state | persistence: {:persistence_failed, :trace_persistence_failed}}}
    end
  end

  defp valid_terminal_batch?(events) when is_list(events) and events != [] do
    List.first(events).type == "run-started" and List.last(events).type == "run-stopped"
  end

  defp valid_terminal_batch?(_events), do: false

  defp safe_info(state) do
    %{
      persistence: state.persistence,
      terminal: state.terminal,
      event_count: if(is_list(state.events), do: length(state.events), else: 0)
    }
  end

  defp reply_info(state), do: {:reply, safe_info(state), state}

  defp ensure_recorder_state(%{sink_ref: nil} = state), do: state

  defp ensure_recorder_state(state) do
    if Process.alive?(state.sink.pid), do: state, else: recorder_failed(state)
  end

  defp recorder_failed(%{persistence: :open} = state) do
    if is_reference(state.sink_ref), do: Process.demonitor(state.sink_ref, [:flush])

    if match?(%RunState{}, state.run_state) and Process.alive?(state.run_state.pid) do
      RunState.fail(state.run_state, :event_sink_error, :event_sink_error)
    end

    %{
      state
      | persistence: :backend_failed,
        terminal: %{outcome: :error, reason: :event_sink_error},
        sink_ref: nil
    }
  catch
    :exit, _reason ->
      %{
        state
        | persistence: :backend_failed,
          terminal: %{outcome: :error, reason: :event_sink_error},
          sink_ref: nil
      }
  end

  defp recorder_failed(state) do
    if is_reference(state.sink_ref), do: Process.demonitor(state.sink_ref, [:flush])
    %{state | sink_ref: nil}
  end

  defp finalize_aborted_owner(state) do
    reason = state.pending_terminal_reason || :session_owner_failed

    case finalize_state(state, :error, reason, %{aborted: true}) do
      {:ok, next} -> next
      {:error, _reason, next} -> next
    end
  end

  defp persist_aborted_owner(state) do
    case persist_state(state) do
      {:ok, next} -> next
      {:error, _reason, next} -> next
    end
  end

  defp cleanup_resources(state) do
    state
    |> cleanup_run_state()
    |> cleanup_snapshot()
  end

  defp cleanup_run_state(%{run_state: %RunState{} = run_state} = state) do
    close_result =
      try do
        RunState.close(run_state)
      catch
        :exit, _reason -> {:error, :runtime_unavailable}
      end

    state =
      if close_result == :ok or state.persistence != :open,
        do: state,
        else: recorder_failed(state)

    try do
      RunState.stop(run_state)
    catch
      :exit, _reason -> :ok
    end

    if Process.alive?(run_state.pid), do: state, else: %{state | run_state: nil}
  end

  defp cleanup_run_state(state), do: state

  defp cleanup_snapshot(%{snapshot: %TraceSnapshot{} = snapshot} = state) do
    TraceSnapshot.stop(snapshot)
    if Process.alive?(snapshot.pid), do: state, else: %{state | snapshot: nil}
  end

  defp cleanup_snapshot(state), do: state

  defp run_resource_cleanup_hook(nil), do: :ok

  defp run_resource_cleanup_hook(hook) when is_function(hook, 0) do
    hook.()
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp stop_attached_session(%{session_pid: pid, session_ref: ref})
       when is_pid(pid) and is_reference(ref) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp stop_attached_session(_state), do: :ok

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp call(%__MODULE__{pid: pid, token: token}, request, timeout \\ 5_000),
    do: GenServer.call(pid, {token, request}, timeout)
end
