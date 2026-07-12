defmodule PtcRunner.Kernel.ReplSession do
  @moduledoc "Direct bounded PTC-Lisp session for the Kernel REPL frontend."

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Result, as: Native
  alias PtcRunner.Lisp.RetainedSize

  @default_history_depth 3

  @enforce_keys [:config, :state, :memory, :history, :history_depth]
  defstruct [:config, :state, :memory, :history, :history_depth, attempts: 0, errors: 0]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:config, :history_depth] == [],
         {:ok, config} <- config(Keyword.get(opts, :config)) do
      history_depth = Keyword.get(opts, :history_depth, @default_history_depth)

      if history_depth in 1..3 do
        start_session(config, history_depth)
      else
        EventSink.stop(config.event_sink)
        {:error, :invalid_repl_session}
      end
    else
      false -> {:error, :invalid_repl_session}
      {:error, _reason} = error -> error
    end
  end

  def new(_opts), do: {:error, :invalid_repl_session}

  @spec eval(t(), binary()) :: {:ok, Native.t(), t()} | {:error, Native.t(), t()}
  def eval(%__MODULE__{} = session, source) when is_binary(source) do
    if sink_alive?(session) do
      eval_open(session, source)
    else
      session_closed(session)
    end
  end

  defp eval_open(session, source) do
    case RunState.reserve_evaluation(session.state) do
      {:ok, memory, lease} -> eval_reserved(session, source, memory, lease)
      {:error, reason} -> evaluation_reservation_failure(session, reason)
    end
  catch
    :exit, _reason -> session_closed(session)
  end

  defp session_closed(session) do
    step = Native.error(:session_closed, "REPL session is closed", session.memory)
    {:error, step, session}
  end

  @spec close(t()) :: {:ok, [map()]} | {:error, :event_sink_error | :session_closed}
  def close(%__MODULE__{} = session) do
    if sink_alive?(session) do
      try do
        :ok = RunState.close(session.state)
        _ = emit_dropped_summary(session)

        result =
          emit_run_stopped(
            session,
            if(session.errors == 0, do: :ok, else: :error),
            if(session.errors == 0, do: nil, else: :repl_evaluation_error)
          )

        events = if result == :ok, do: EventSink.events(session.config.event_sink), else: []

        case result do
          :ok -> {:ok, events}
          {:error, :event_sink_error} -> {:error, :event_sink_error}
        end
      catch
        :exit, _reason -> {:error, :session_closed}
      after
        stop_owners(session)
      end
    else
      {:error, :session_closed}
    end
  end

  @spec abort(t(), atom()) :: {:ok, [map()]} | :ok
  def abort(%__MODULE__{} = session, reason) when is_atom(reason) do
    if sink_alive?(session) do
      try do
        :ok = RunState.close(session.state)
        _ = emit_dropped_summary(session)
        _ = emit_run_stopped(session, :error, reason)
        {:ok, EventSink.events(session.config.event_sink)}
      after
        stop_owners(session)
      end
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp config(nil) do
    with {:ok, workflow} <- WorkflowEnvironment.new([]),
         {:ok, mission} <- MissionEnvironment.new([]),
         {:ok, limits} <- Limits.new(),
         {:ok, sink} <- EventSink.start(:normal, limits) do
      case RunConfig.new(
             workflow_environment: workflow,
             mission_environment: mission,
             input: %{},
             limits: limits,
             event_sink: sink,
             labels: %{"name" => "ptc.repl"}
           ) do
        {:ok, _config} = success ->
          success

        {:error, _reason} = error ->
          EventSink.stop(sink)
          error
      end
    end
  end

  defp config(%RunConfig{} = config), do: {:ok, config}
  defp config(_config), do: {:error, :invalid_repl_session}

  defp emit_run_started(config) do
    EventSink.emit(config.event_sink, "run-started", %{
      labels: config.labels,
      workflow_prelude: trace_bundle(config.workflow_environment.bundle),
      mission_prelude: trace_bundle(config.mission_environment.bundle)
    })
  end

  defp start_session(config, history_depth) do
    with {:ok, state} <- RunState.start(config.limits) do
      case emit_run_started(config) do
        :ok ->
          {:ok,
           %__MODULE__{
             config: config,
             state: state,
             memory: %{},
             history: [],
             history_depth: history_depth
           }}

        {:error, :event_sink_error} = error ->
          RunState.close(state)
          RunState.stop(state)
          EventSink.stop(config.event_sink)
          error
      end
    end
  end

  defp emit_run_stopped(session, outcome, reason) do
    errors = max(session.errors, observed_errors(session))

    usage =
      session.state
      |> RunState.usage()
      |> Map.put(:errors, errors)
      |> Map.put(:events_dropped, EventSink.dropped(session.config.event_sink))

    EventSink.emit(session.config.event_sink, "run-stopped", %{
      outcome: outcome,
      reason: reason,
      usage: usage
    })
  end

  defp observed_errors(session) do
    session.config.event_sink
    |> EventSink.events()
    |> Enum.count(fn event ->
      event.type == "evaluation-stopped" and event.data.status == :error
    end)
  end

  defp eval_reserved(session, source, memory, lease) do
    evaluation_id = Events.id("repl-evaluation")
    started_ms = System.monotonic_time(:millisecond)

    try do
      case EventSink.emit(session.config.event_sink, "evaluation-started", %{
             evaluation_id: evaluation_id,
             environment: :workflow
           }) do
        :ok ->
          result = run_lisp(session, memory, source)
          finish_evaluation(session, result, lease, evaluation_id, started_ms)

        {:error, :event_sink_error} ->
          RunState.release_evaluation(session.state, lease)
          event_sink_failure(session)
      end
    catch
      :exit, _reason ->
        _ = RunState.release_evaluation(session.state, lease)
        session_closed(session)
    end
  end

  defp run_lisp(session, memory, source) do
    limits = session.config.limits
    timeout_ms = min(limits.evaluation_timeout_ms, RunState.remaining_ms(session.state))

    Lisp.run_native(source,
      caller: :in_process_v1,
      context: session.config.input,
      memory: memory,
      turn_history: session.history,
      tools: tools(session),
      prelude: prelude(session.config.workflow_environment),
      timeout: timeout_ms,
      compile_timeout: timeout_ms,
      run_deadline_ms: System.monotonic_time(:millisecond) + timeout_ms,
      max_heap: limits.evaluation_heap_words,
      max_program_bytes: limits.subordinate_source_bytes,
      max_tool_call_result_bytes: limits.capability_result_bytes,
      preserve_runtime_callables: true,
      filter_context: false
    )
  end

  defp tools(session) do
    environment = session.config.workflow_environment
    timeout_ms = session.config.limits.evaluation_timeout_ms

    Map.new(environment.capabilities, fn {name, _capability} ->
      callback = fn arguments ->
        Dispatcher.dispatch(
          session.state,
          :workflow,
          environment,
          name,
          arguments,
          timeout_ms,
          session.config.event_sink
        )
      end

      {name, callback}
    end)
  end

  defp finish_evaluation(session, {:ok, %Native{} = step}, lease, evaluation_id, started_ms) do
    limits = session.config.limits

    if result_within_limit?(step.return, limits.terminal_result_bytes),
      do: commit_success(session, step, lease, evaluation_id, started_ms),
      else: reject_success(session, lease, evaluation_id, started_ms, :result_exceeded)
  end

  defp finish_evaluation(session, {:error, %Native{} = step}, lease, evaluation_id, started_ms) do
    _ = RunState.release_evaluation(session.state, lease)
    next = increment_error(session)

    case emit_evaluation_stopped(
           session,
           session.state,
           evaluation_id,
           started_ms,
           :error,
           step.fail.reason
         ) do
      :ok -> {:error, step, next}
      {:error, :event_sink_error} -> event_sink_failure(session)
    end
  end

  defp commit_success(session, step, lease, evaluation_id, started_ms) do
    case RunState.commit_evaluation(session.state, lease, step.memory) do
      :ok ->
        next = %{
          session
          | memory: step.memory,
            history: append_history(session.history, step.return, session.history_depth),
            attempts: session.attempts + 1
        }

        case emit_evaluation_stopped(
               session,
               session.state,
               evaluation_id,
               started_ms,
               :ok,
               nil
             ) do
          :ok -> {:ok, step, next}
          {:error, :event_sink_error} -> event_sink_failure(session)
        end

      {:error, reason} ->
        reject_committed_failure(session, evaluation_id, started_ms, reason)
    end
  end

  defp reject_success(session, lease, evaluation_id, started_ms, reason) do
    _ = RunState.release_evaluation(session.state, lease)
    reject_committed_failure(session, evaluation_id, started_ms, reason)
  end

  defp reject_committed_failure(session, evaluation_id, started_ms, reason) do
    message =
      if reason == :memory_exceeded,
        do: "REPL memory exceeded its byte limit",
        else: "REPL result exceeded its byte limit"

    failure = Native.error(reason, message, session.memory)

    case emit_evaluation_stopped(
           session,
           session.state,
           evaluation_id,
           started_ms,
           :error,
           reason
         ) do
      :ok -> {:error, failure, increment_error(session)}
      {:error, :event_sink_error} -> event_sink_failure(session)
    end
  end

  defp event_sink_failure(session) do
    step = Native.error(:event_sink_error, "canonical event sink failed", session.memory)
    {:error, step, increment_error(session)}
  end

  defp evaluation_reservation_failure(session, reason) do
    normalized =
      case reason do
        :limit_exceeded -> :subordinate_evaluations
        :run_closed -> :run_deadline
        other -> other
      end

    _ = EventSink.emit(session.config.event_sink, "limit-exceeded", %{reason: normalized})
    step = Native.error(:limit_exceeded, "REPL evaluation limit exceeded", session.memory)
    {:error, step, increment_error(session)}
  end

  defp emit_evaluation_stopped(session, state, evaluation_id, started_ms, status, reason) do
    EventSink.emit(session.config.event_sink, "evaluation-stopped", %{
      evaluation_id: evaluation_id,
      environment: :workflow,
      status: status,
      reason: reason,
      duration_ms: Events.duration_ms(started_ms),
      usage: RunState.usage(state)
    })
  end

  defp increment_error(session),
    do: %{session | attempts: session.attempts + 1, errors: session.errors + 1}

  defp append_history(history, value, depth), do: Enum.take(history ++ [value], -depth)

  defp result_within_limit?(value, limit) do
    case RetainedSize.bytes_with_cap(value, limit) do
      bytes when is_integer(bytes) and bytes <= limit -> true
      _ -> false
    end
  end

  defp emit_dropped_summary(session) do
    case EventSink.dropped(session.config.event_sink) do
      dropped when map_size(dropped) == 0 -> :ok
      dropped -> EventSink.emit(session.config.event_sink, "events-dropped", %{counts: dropped})
    end
  end

  defp stop_owners(session) do
    if Process.alive?(session.config.event_sink.pid),
      do: EventSink.stop(session.config.event_sink)

    if Process.alive?(session.state.pid), do: RunState.stop(session.state)
  end

  defp sink_alive?(session),
    do: Process.alive?(session.config.event_sink.pid) and Process.alive?(session.state.pid)

  defp prelude(%{bundle: nil}), do: nil
  defp prelude(%{bundle: bundle}), do: bundle.prelude
  defp trace_bundle(nil), do: %{component_ids: [], hash: nil}

  defp trace_bundle(%{component_ids: component_ids, hash: hash}),
    do: %{component_ids: component_ids, hash: hash}
end
