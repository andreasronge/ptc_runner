defmodule PtcRunner.Kernel.ReplSession do
  @moduledoc """
  Direct bounded PTC-Lisp continuation used by the Kernel REPL frontend.

  Successful forms commit definitions transactionally and retain up to three
  prior results for `*1`, `*2`, and `*3`. Failed forms preserve the previous
  memory. A session uses the workflow bundle, capabilities, limits, input,
  labels, and event policy from an optional `PtcRunner.Kernel.RunConfig` but
  does not execute the manifest entry function. REPL continuation and history
  require the native result projection, so a supplied configuration sealed for
  JSON command output is rejected before its recorder is claimed.

  A session is process-affine: the process that calls `new/1` is its owner and
  must perform every `eval/2`, `close/1`, and `abort/2` call. Passing the struct
  to another process does not transfer ownership; those calls return
  `{:error, :session_owner_mismatch}` without touching continuation or lifecycle
  state. The public value contains only an opaque ID, one shared
  creator-private lookup table, and bounded attempt counters—not an owner PID or
  token. Closed lookup entries are removed. Continuation values and raw
  run-state, sink, provider, and configuration capabilities remain inside the
  internal owner process. Watchdogs couple compilation and evaluation sandboxes
  to the creator; all owned resources and in-flight work are stopped if it
  exits.

  Call `close/1` for an atomically frozen terminal batch or `abort/2` when the
  frontend terminates early. Both paths use the recorder's reserved terminal
  capacity.
  """

  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.ToolGrant
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Result, as: Native
  alias PtcRunner.Lisp.RetainedSize

  @access_table_key {__MODULE__, :access_table}
  @maximum_counter 4_294_967_295
  @setup_cleanup_timeout_ms 1_000

  @enforce_keys [:access, :id]
  defstruct [:access, :id, attempts: 0, errors: 0]

  @type t :: %__MODULE__{
          access: :ets.tid(),
          id: reference(),
          attempts: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  @doc """
  Starts a session with an optional `:config`.

  Without a config, the session creates empty environments, default limits,
  and a normal in-memory event sink. Exact native history has the fixed language
  depth of three and is owned by RunState with continuation memory.

  A supplied config's event and optional inspection sink owners are frozen when
  the config is constructed and must match the calling process. A mismatch or
  inconclusive live-sink ownership probe returns
  `{:error, :session_owner_mismatch}` before the recorder is claimed or a run
  state is started and leaves the config untouched. A dead owned sink closes
  the config's provider session before setup fails. The config must select
  the native result projection; a JSON-projection config returns
  `{:error, :invalid_repl_session}` untouched.
  """
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:config] == [],
         {:ok, config} <- config(Keyword.get(opts, :config)) do
      start_session(config)
    else
      false -> {:error, :invalid_repl_session}
      {:error, _reason} = error -> error
    end
  end

  def new(_opts), do: {:error, :invalid_repl_session}

  @doc false
  @spec event_policy(t()) :: EventSink.policy() | {:error, atom()}
  def event_policy(%__MODULE__{} = session) do
    with {:ok, owned} <- owned_session(session),
         do: EventSink.policy(owned.config.event_sink)
  catch
    :exit, _reason -> {:error, :session_closed}
  end

  @doc false
  @spec evaluation_memory_summary(t()) :: map() | {:error, atom()}
  def evaluation_memory_summary(%__MODULE__{} = session) do
    with {:ok, owned} <- owned_session(session),
         do: RunState.evaluation_memory_summary(owned.state)
  catch
    :exit, _reason -> {:error, :session_closed}
  end

  @doc false
  @spec usage(t()) :: map() | {:error, atom()}
  def usage(%__MODULE__{} = session) do
    with {:ok, owned} <- owned_session(session),
         do: RunState.usage(owned.state)
  catch
    :exit, _reason -> {:error, :session_closed}
  end

  @spec eval(t(), binary()) ::
          {:ok, Native.t(), t()}
          | {:error, Native.t(), t()}
          | {:error, :session_owner_mismatch}
  @doc """
  Evaluates one bounded source form and returns the updated session.

  The returned result is an observation-only public projection. The exact
  native memory and history used by later forms remain inside the session
  owner; callers must not thread the result's memory back into the session.

  Returns `{:error, :session_owner_mismatch}` without evaluating when called
  outside the process that created the session.
  """
  def eval(%__MODULE__{} = session, source) when is_binary(source) do
    case owned_session(session) do
      {:ok, owned} ->
        result =
          if sink_alive?(owned) and RunState.open?(owned.state) do
            eval_open(owned, source)
          else
            session_closed(owned)
          end

        public_result(result)

      {:error, :session_closed} ->
        session_closed(session)

      {:error, :session_owner_mismatch} = error ->
        error
    end
  catch
    :exit, _reason -> session_closed(session)
  end

  defp eval_open(session, source) do
    case RunState.reserve_evaluation(session.state) do
      {:ok, memory, history, lease} ->
        session = Map.merge(session, %{memory: memory, history: history})
        eval_reserved(session, source, memory, history, lease)

      {:error, reason} ->
        evaluation_reservation_failure(session, reason)
    end
  catch
    :exit, _reason -> session_closed(session)
  end

  defp session_closed(session) do
    step = Native.error(:session_closed, "REPL session is closed", observed_memory(session))
    {:error, step, session}
  end

  @spec close(t()) ::
          {:ok, [map()]}
          | {:error, :provider_cleanup_failed, [map()]}
          | {:error,
             :event_sink_error
             | :provider_cleanup_failed
             | :session_closed
             | :session_owner_mismatch}
  @doc """
  Closes a session normally and returns its atomically frozen canonical events.
  When provider cleanup fails after terminal publication, the error tuple also
  returns the frozen events so a frontend can persist them before reporting the
  cleanup failure.

  Returns `{:error, :session_owner_mismatch}` without closing anything when
  called outside the process that created the session.
  """
  def close(%__MODULE__{} = session) do
    with {:ok, owned} <- owned_session(session) do
      try do
        close_owned(owned)
      after
        ReplSessionOwner.release(owned.owner_pid, owned.owner_token)
        close_access(session)
      end
    end
  catch
    :exit, _reason -> {:error, :session_closed}
  end

  defp close_owned(session) do
    state_result = close_run_state(session.state)
    cleanup = ReplSessionOwner.close_provider_session(session.owner_pid, session.owner_token)

    if state_result == :ok and cleanup_result?(cleanup) and
         Process.alive?(session.config.event_sink.pid) do
      finalize_close(session, cleanup)
    else
      prefer_cleanup_error({:error, :session_closed}, cleanup)
    end
  end

  defp finalize_close(session, cleanup) do
    {outcome, reason} =
      case {cleanup, bounded_counter(session.errors)} do
        {:ok, 0} ->
          {:ok, nil}

        {:ok, _errors} ->
          {:error, :repl_evaluation_error}

        {{:error, :provider_cleanup_failed}, _errors} ->
          {:error, :provider_cleanup_failed}
      end

    case finalize(session, outcome, reason) do
      {:ok, events} when cleanup == :ok -> {:ok, events}
      {:ok, events} -> {:error, :provider_cleanup_failed, events}
      {:error, :event_sink_error} when cleanup == :ok -> {:error, :event_sink_error}
      {:error, :event_sink_error} -> cleanup
    end
  catch
    :exit, _reason -> prefer_cleanup_error({:error, :session_closed}, cleanup)
  end

  @spec abort(t(), atom()) ::
          {:ok, [map()]}
          | :ok
          | {:error, :provider_cleanup_failed, [map()]}
          | {:error, :provider_cleanup_failed | :session_owner_mismatch}
  @doc """
  Closes a session with an error reason and returns retained events when available.
  When provider cleanup fails after terminal publication, the error tuple also
  returns those events.

  Returns `{:error, :session_owner_mismatch}` without closing anything when
  called outside the process that created the session.
  """
  def abort(%__MODULE__{} = session, reason) when is_atom(reason) do
    case owned_session(session) do
      {:ok, owned} ->
        try do
          abort_owned(owned, reason)
        after
          ReplSessionOwner.release(owned.owner_pid, owned.owner_token)
          close_access(session)
        end

      {:error, :session_closed} ->
        :ok

      {:error, :session_owner_mismatch} = error ->
        error
    end
  catch
    :exit, _reason -> :ok
  end

  defp abort_owned(session, reason) do
    state_result = close_run_state(session.state)
    cleanup = ReplSessionOwner.close_provider_session(session.owner_pid, session.owner_token)

    if state_result == :ok and cleanup_result?(cleanup) and
         Process.alive?(session.config.event_sink.pid) do
      finalize_abort(session, reason, cleanup)
    else
      prefer_cleanup_error(:ok, cleanup)
    end
  end

  defp finalize_abort(session, reason, cleanup) do
    terminal_reason =
      if cleanup == :ok,
        do: reason,
        else: :provider_cleanup_failed

    case finalize(session, :error, terminal_reason) do
      {:ok, events} when cleanup == :ok -> {:ok, events}
      {:ok, events} -> {:error, :provider_cleanup_failed, events}
      {:error, :event_sink_error} when cleanup == :ok -> :ok
      {:error, :event_sink_error} -> cleanup
    end
  catch
    :exit, _reason -> prefer_cleanup_error(:ok, cleanup)
  end

  defp prefer_cleanup_error(_result, {:error, :provider_cleanup_failed} = error), do: error
  defp prefer_cleanup_error(result, :ok), do: result
  defp prefer_cleanup_error(result, _owner_failure), do: result

  defp cleanup_result?(:ok), do: true
  defp cleanup_result?({:error, :provider_cleanup_failed}), do: true
  defp cleanup_result?(_result), do: false

  defp close_run_state(state) do
    RunState.close_and_drain(state)
    :ok
  catch
    :exit, _reason -> {:error, :session_closed}
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

  defp config(%RunConfig{} = config) do
    cond do
      config.event_sink_owner != self() or
          config.inspection_sink_owner not in [nil, self()] ->
        {:error, :session_owner_mismatch}

      config.result_projection != :native ->
        {:error, :invalid_repl_session}

      not Process.alive?(config.event_sink.pid) ->
        reject_unstarted_config(config, :event_sink_error)

      not inspection_alive?(config.inspection_sink) ->
        reject_unstarted_config(config, :inspection_sink_error)

      true ->
        {:ok, config}
    end
  end

  defp config(_config), do: {:error, :invalid_repl_session}

  defp inspection_alive?(nil), do: true
  defp inspection_alive?(sink), do: Process.alive?(sink.pid)

  defp emit_run_started(config) do
    EventSink.claim(config.event_sink, config.claim_id, config.run_started_metadata)
  end

  defp start_session(config) do
    case RunState.start_repl(config.limits, config.event_sink, config.inspection_sink) do
      {:ok, state} ->
        start_session_with_state(config, state)

      {:error, reason} ->
        case setup_failure_reason(config, reason) do
          :session_owner_mismatch -> {:error, :session_owner_mismatch}
          failure -> reject_unstarted_config(config, failure)
        end
    end
  end

  defp setup_failure_reason(config, fallback) do
    cond do
      not Process.alive?(config.event_sink.pid) -> :event_sink_error
      not inspection_alive?(config.inspection_sink) -> :inspection_sink_error
      true -> fallback
    end
  end

  defp start_session_with_state(config, state) do
    case emit_run_started(config) do
      :ok ->
        transfer_and_start_session(config, state)

      {:error, :event_sink_already_claimed} ->
        RunState.close(state)
        RunState.stop(state)
        {:error, :event_sink_error}

      {:error, reason}
      when reason in [:event_sink_claimed_by_other, :event_sink_error] ->
        RunState.close(state)
        RunState.stop(state)

        case RunConfig.close_provider_session(config) do
          :ok -> {:error, :event_sink_error}
          {:error, :provider_cleanup_failed} = error -> error
        end
    end
  end

  defp transfer_and_start_session(config, state) do
    case RunState.use_provider_session(state, config.provider_session) do
      {:ok, state} ->
        bind_and_start_session(config, state)

      {:error, reason} ->
        cleanup = stop_owners(%{config: config, state: state})
        prefer_cleanup_error({:error, reason}, cleanup)
    end
  end

  defp bind_and_start_session(config, state) do
    case ReplSessionOwner.start(config, state, self()) do
      {:ok, pid, token} ->
        case RunConfig.bind_provider_session(config, pid, state.pid) do
          :ok ->
            register_access(pid, token)

          {:error, reason} ->
            state_result = close_run_state(state)
            cleanup = ReplSessionOwner.close_provider_session(pid, token)
            ReplSessionOwner.release(pid, token)

            state_result
            |> prefer_cleanup_error(cleanup)
            |> prefer_setup_error(reason)
        end

      {:error, reason} ->
        cleanup = stop_owners(%{config: config, state: state})
        prefer_cleanup_error({:error, reason}, cleanup)
    end
  end

  defp prefer_setup_error({:error, :provider_cleanup_failed} = error, _reason), do: error
  defp prefer_setup_error(_result, reason), do: {:error, reason}

  defp finalize(session, outcome, reason) do
    errors = min(max(bounded_counter(session.errors), observed_errors(session)), @maximum_counter)

    usage =
      session.state
      |> RunState.usage()
      |> Map.put(:errors, errors)

    case EventSink.finalize_and_events(session.config.event_sink, %{
           outcome: outcome,
           reason: reason,
           usage: usage
         }) do
      {:ok, %{events: events}} -> {:ok, events}
      {:error, :event_sink_error} = error -> error
    end
  end

  defp observed_errors(session) do
    session.config.event_sink
    |> EventSink.events()
    |> Enum.count(fn event ->
      event.type == "evaluation-stopped" and event.data.status == :error
    end)
  end

  defp eval_reserved(session, source, memory, history, lease) do
    evaluation_id = Events.id("repl-evaluation")
    started_ms = System.monotonic_time(:millisecond)

    try do
      case EventSink.emit(session.config.event_sink, "evaluation-started", %{
             evaluation_id: evaluation_id,
             environment: :workflow
           }) do
        :ok ->
          result = run_lisp(session, memory, history, source, evaluation_id)
          finish_evaluation(session, result, history, lease, evaluation_id, started_ms)

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

  defp run_lisp(session, memory, history, source, evaluation_id) do
    limits = session.config.limits
    timeout_ms = min(limits.evaluation_timeout_ms, RunState.remaining_ms(session.state))

    Lisp.run_native(source,
      caller: :repl,
      context: session.config.input,
      memory: memory,
      turn_history: history,
      tools: tools(session, evaluation_id),
      prelude: prelude(session.config.workflow_environment),
      timeout: timeout_ms,
      compile_timeout: timeout_ms,
      run_deadline_ms: System.monotonic_time(:millisecond) + timeout_ms,
      max_heap: limits.evaluation_heap_words,
      max_program_bytes: limits.subordinate_source_bytes,
      max_tool_call_result_bytes: limits.capability_result_bytes,
      preserve_runtime_callables: true,
      filter_context: false,
      link: true
    )
  end

  defp tools(session, evaluation_id) do
    environment = session.config.workflow_environment
    timeout_ms = session.config.limits.evaluation_timeout_ms
    state = session.state

    context = %{
      event_sink: session.config.event_sink,
      inspection_sink: session.config.inspection_sink,
      evaluation_id: evaluation_id
    }

    state
    |> ToolGrant.capability_callbacks(:workflow, environment, timeout_ms, context)
    |> Map.put(
      "kernel-eval",
      RuntimeTools.instrument(
        session.state,
        session.config.event_sink,
        :workflow,
        "kernel-eval",
        RuntimeTools.kernel_eval(
          session.state,
          session.config.mission_environment,
          session.config.limits,
          session.config.event_sink,
          session.config.inspection_sink
        ),
        evaluation_id
      )
    )
    |> Map.put(
      "kernel-check-source",
      RuntimeTools.instrument(
        session.state,
        session.config.event_sink,
        :workflow,
        "kernel-check-source",
        RuntimeTools.kernel_check_source(
          session.state,
          session.config.mission_environment,
          session.config.limits,
          session.config.event_sink
        )
      )
    )
    |> Map.put(
      "kernel-mission-inventory",
      RuntimeTools.instrument(
        session.state,
        session.config.event_sink,
        :workflow,
        "kernel-mission-inventory",
        RuntimeTools.mission_inventory(
          session.state,
          session.config.mission_inventory.rendered
        )
      )
    )
    |> Map.put(
      "kernel-mission-model-context",
      RuntimeTools.instrument(
        session.state,
        session.config.event_sink,
        :workflow,
        "kernel-mission-model-context",
        RuntimeTools.mission_model_context(
          session.state,
          session.config.mission_inventory.model_rendered
        )
      )
    )
    |> Map.put(
      "kernel-result-contract",
      RuntimeTools.instrument(
        session.state,
        session.config.event_sink,
        :workflow,
        "kernel-result-contract",
        RuntimeTools.result_contract(session.config.result_contract)
      )
    )
    |> Map.put(
      "kernel-result-contract-description",
      RuntimeTools.instrument(
        session.state,
        session.config.event_sink,
        :workflow,
        "kernel-result-contract-description",
        RuntimeTools.result_contract_description(session.config.result_contract)
      )
    )
    |> RuntimeTools.trusted_tools(session.config.limits)
  end

  defp finish_evaluation(
         session,
         {:ok, %Native{return: {:__ptc_fail__, _value}}},
         _history,
         lease,
         evaluation_id,
         started_ms
       ) do
    _ = RunState.release_evaluation(session.state, lease)
    step = Native.error(:explicit_failure, "REPL evaluation explicitly failed", session.memory)
    next = increment_error(session)

    case emit_evaluation_stopped(
           session,
           session.state,
           evaluation_id,
           started_ms,
           :error,
           :explicit_failure
         ) do
      :ok -> {:error, step, next}
      {:error, :event_sink_error} -> event_sink_failure(session)
    end
  end

  defp finish_evaluation(
         session,
         {:ok, %Native{} = step},
         history,
         lease,
         evaluation_id,
         started_ms
       ) do
    limits = session.config.limits

    if result_within_limit?(step.return, limits.terminal_result_bytes) do
      case Lisp.project_native_result({:ok, step}) do
        {:ok, public_step} ->
          commit_success(
            session,
            step,
            public_step,
            history,
            lease,
            evaluation_id,
            started_ms
          )

        {:error, public_error} ->
          reject_projection(session, public_error, lease, evaluation_id, started_ms)
      end
    else
      reject_success(session, lease, evaluation_id, started_ms, :result_exceeded)
    end
  end

  defp finish_evaluation(
         session,
         {:error, %Native{} = step},
         _history,
         lease,
         evaluation_id,
         started_ms
       ) do
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

  defp commit_success(
         session,
         native_step,
         public_step,
         history,
         lease,
         evaluation_id,
         started_ms
       ) do
    candidate_history = history_after_success(history, native_step.return)

    case RunState.commit_evaluation(
           session.state,
           lease,
           native_step.memory,
           candidate_history
         ) do
      :ok ->
        next = %{
          session
          | memory: native_step.memory,
            history: candidate_history
        }

        case emit_evaluation_stopped(
               session,
               session.state,
               evaluation_id,
               started_ms,
               :ok,
               nil
             ) do
          :ok -> {:ok, public_step, %{next | attempts: increment_counter(next.attempts)}}
          {:error, :event_sink_error} -> event_sink_failure(next)
        end

      {:error, reason} ->
        reject_committed_failure(session, evaluation_id, started_ms, reason)
    end
  end

  defp reject_projection(session, public_error, lease, evaluation_id, started_ms) do
    _ = RunState.release_evaluation(session.state, lease)
    public_error = %{public_error | memory: observed_memory(session)}
    next = increment_error(session)

    case emit_evaluation_stopped(
           session,
           session.state,
           evaluation_id,
           started_ms,
           :error,
           public_error.fail.reason
         ) do
      :ok -> {:error, public_error, next}
      {:error, :event_sink_error} -> event_sink_failure(session)
    end
  end

  defp reject_success(session, lease, evaluation_id, started_ms, reason) do
    _ = RunState.release_evaluation(session.state, lease)
    reject_committed_failure(session, evaluation_id, started_ms, reason)
  end

  defp reject_committed_failure(session, evaluation_id, started_ms, reason) do
    message =
      case reason do
        :memory_exceeded -> "REPL memory exceeded its byte limit"
        :history_exceeded -> "REPL history exceeded its byte limit"
        _reason -> "REPL result exceeded its byte limit"
      end

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
    _ = RunState.fail(session.state, :event_sink_error, :event_sink_error)
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

    step =
      Native.error(:limit_exceeded, "REPL evaluation limit exceeded", observed_memory(session))

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
    do: %{
      session
      | attempts: increment_counter(session.attempts),
        errors: increment_counter(session.errors)
    }

  defp increment_counter(value), do: min(bounded_counter(value) + 1, @maximum_counter)

  defp bounded_counter(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_counter)

  defp bounded_counter(_value), do: 0

  defp history_after_success(history, {:__ptc_return__, _value}), do: history
  defp history_after_success(history, value), do: Enum.take(history ++ [value], -3)

  defp result_within_limit?(value, limit) do
    case RetainedSize.bytes_with_cap(value, limit) do
      bytes when is_integer(bytes) and bytes <= limit -> true
      _ -> false
    end
  end

  defp stop_owners(session) do
    if Process.alive?(session.state.pid), do: RunState.stop(session.state)
    cleanup = RunConfig.close_provider_session(session.config)
    if session.config.inspection_sink, do: InspectionSink.stop(session.config.inspection_sink)

    if Process.alive?(session.config.event_sink.pid),
      do: EventSink.stop(session.config.event_sink)

    cleanup
  end

  defp reject_unstarted_config(config, reason) do
    cleanup = RunConfig.close_provider_session(config)

    if config.inspection_sink,
      do: InspectionSink.stop(config.inspection_sink, @setup_cleanup_timeout_ms)

    EventSink.stop(config.event_sink, @setup_cleanup_timeout_ms)
    prefer_cleanup_error({:error, reason}, cleanup)
  end

  defp sink_alive?(session),
    do: Process.alive?(session.config.event_sink.pid) and Process.alive?(session.state.pid)

  defp owned_session(session) do
    with {:ok, pid, token} <- access_resources(session),
         {:ok, config, state} <- ReplSessionOwner.resources(pid, token) do
      {:ok,
       Map.merge(Map.from_struct(session), %{
         owner_pid: pid,
         owner_token: token,
         config: config,
         state: state,
         memory: %{},
         history: [],
         attempts: bounded_counter(session.attempts),
         errors: bounded_counter(session.errors)
       })}
    end
  end

  defp register_access(pid, token) do
    access = access_table()
    id = make_ref()
    true = :ets.insert(access, {id, {pid, token}})
    {:ok, %__MODULE__{access: access, id: id}}
  rescue
    exception ->
      _ = ReplSessionOwner.release(pid, token)
      {:error, {:session_access_error, Exception.message(exception)}}
  end

  defp access_resources(%__MODULE__{access: access, id: id}) do
    case :ets.lookup(access, id) do
      [{^id, {pid, token}}] when is_pid(pid) and is_reference(token) ->
        {:ok, pid, token}

      [{^id, :closed}] ->
        {:error, :session_closed}

      [] ->
        if :ets.info(access, :owner) == self(),
          do: {:error, :session_closed},
          else: {:error, :session_owner_mismatch}

      _other ->
        {:error, :session_owner_mismatch}
    end
  rescue
    ArgumentError -> {:error, :session_owner_mismatch}
  end

  defp close_access(%__MODULE__{access: access, id: id}) do
    :ets.delete(access, id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp access_table do
    case Process.get(@access_table_key) do
      nil -> new_access_table()
      access -> existing_access_table(access)
    end
  end

  defp existing_access_table(access) do
    if :ets.info(access, :owner) == self(), do: access, else: new_access_table()
  rescue
    ArgumentError -> new_access_table()
  end

  defp new_access_table do
    access = :ets.new(__MODULE__, [:set, :private])
    Process.put(@access_table_key, access)
    access
  end

  defp observed_memory(%{state: state} = session) do
    case RunState.evaluation_memory_observation(state) do
      memory when is_map(memory) -> memory
      {:error, _reason} -> Map.get(session, :memory, %{})
    end
  catch
    :exit, _reason -> Map.get(session, :memory, %{})
  end

  defp observed_memory(session), do: Map.get(session, :memory, %{})

  defp public_result({status, step, session}) when status in [:ok, :error] do
    {public_status, public_step} = Lisp.project_native_result({status, step})
    {public_status, public_step, public_session(session)}
  end

  defp public_session(session) do
    %__MODULE__{
      access: session.access,
      id: session.id,
      attempts: session.attempts,
      errors: session.errors
    }
  end

  defp prelude(%{bundle: nil}), do: nil
  defp prelude(%{bundle: bundle}), do: bundle.prelude
end
