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
  capacity and persist an authorized trace inside the session owner before
  releasing its resources.
  """

  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.ReplLimitProfile
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.ToolGrant
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.DataKeys
  alias PtcRunner.Lisp.Eval.Helpers
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
  Starts a session with optional `:config` and `:trace_path` options.

  Without a config, the session creates empty environments, default limits,
  and a normal in-memory event sink. Exact native history has the fixed language
  depth of three and is owned by RunState with continuation memory.

  A supplied config's event and optional inspection sink owners are frozen when
  the config is constructed and must match the calling process. A mismatch or
  inconclusive live-sink ownership probe returns
  `{:error, :session_owner_mismatch}` before the recorder is claimed or a run
  state is started and leaves the config untouched. A trace destination is
  validated against the session's data class before any run state is started.
  A dead owned sink closes
  the config's provider session before setup fails. The config must select
  the native result projection; a JSON-projection config returns
  `{:error, :invalid_repl_session}` untouched.
  """
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    new_session(opts, [:config, :trace_path], fn -> config(Keyword.get(opts, :config)) end)
  end

  def new(_opts), do: {:error, :invalid_repl_session}

  @doc false
  @spec new_interactive(keyword()) :: {:ok, t()} | {:error, term()}
  def new_interactive(opts \\ [])

  def new_interactive(opts) when is_list(opts) do
    new_session(opts, [:trace_path], fn ->
      config_with_limits(ReplLimitProfile.direct_interactive())
    end)
  end

  def new_interactive(_opts), do: {:error, :invalid_repl_session}

  defp new_session(opts, allowed_keys, config_builder) do
    with true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed_keys == [],
         {:ok, config} <- config_builder.(),
         {:ok, trace_path} <- trace_path(config, Keyword.get(opts, :trace_path)) do
      start_session(config, trace_path)
    else
      false -> {:error, :invalid_repl_session}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec attach(pid(), reference()) :: {:ok, t()} | {:error, term()}
  def attach(owner_pid, owner_token) when is_pid(owner_pid) and is_reference(owner_token) do
    case ReplSessionOwner.session_resources(owner_pid, owner_token) do
      {:ok, %RunConfig{}, %RunState{}, mode} when mode == :workflow or is_map(mode) ->
        register_access(owner_pid, owner_token, mode)

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, _reason -> {:error, :session_closed}
  end

  def attach(_owner_pid, _owner_token), do: {:error, :invalid_repl_session}

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

  @doc false
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{} = session) do
    case owned_session(session) do
      {:ok, owned} -> sink_alive?(owned) and RunState.open?(owned.state)
      {:error, _reason} -> false
    end
  catch
    :exit, _reason -> false
  end

  @doc false
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{} = session) do
    case owned_session(session) do
      {:ok, owned} ->
        not sink_alive?(owned) or not is_nil(RunState.terminal_failure(owned.state))

      {:error, _reason} ->
        true
    end
  catch
    :exit, _reason -> true
  end

  @doc false
  @spec terminal_error(t()) :: {:error, Native.t()} | :none
  def terminal_error(%__MODULE__{} = session) do
    case owned_session(session) do
      {:ok, owned} ->
        case read_terminal_failure(owned.state) do
          nil ->
            :none

          failure ->
            {:error, step, _session} =
              failure
              |> terminal_failure_result(owned)
              |> public_result(owned.mode)

            {:error, step}
        end

      {:error, _reason} ->
        :none
    end
  catch
    :exit, _reason -> :none
  end

  @doc false
  @spec mode_info(t()) :: map() | {:error, atom()}
  def mode_info(%__MODULE__{} = session) do
    with {:ok, owned} <- owned_session(session), do: owned_mode_info(owned)
  catch
    :exit, _reason -> {:error, :session_closed}
  end

  @doc false
  @spec mission_context(t()) :: {:ok, map()} | {:error, atom()}
  def mission_context(%__MODULE__{} = session) do
    with {:ok, owned} <- owned_session(session),
         %{kind: :mission, name: name} <- owned.mode,
         %{inventory: inventory} <- Map.fetch!(owned.config.missions, name) do
      {:ok,
       %{
         mission: name,
         model_context: inventory.model_rendered,
         model_context_hash: inventory.model_hash
       }}
    else
      mode when mode in [:direct, :workflow] -> {:error, :not_mission_session}
      {:error, _reason} = error -> error
    end
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
          cond do
            not sink_alive?(owned) ->
              session_closed(owned)

            failure = read_terminal_failure(owned.state) ->
              preexisting_terminal_failure(owned, failure)

            reservable_session?(owned) ->
              eval_open(owned, source)

            true ->
              session_closed(owned)
          end

        public_result(result, owned.mode)

      {:error, :session_closed} ->
        session_closed(session)

      {:error, :session_owner_mismatch} = error ->
        error
    end
  catch
    :exit, _reason -> session_closed(session)
  end

  defp eval_open(%{mode: mode} = session, source) when mode in [:direct, :workflow] do
    case RunState.reserve_workflow_evaluation(session.state) do
      {:ok, memory, history, lease} ->
        session = Map.merge(session, %{memory: memory, history: history})
        eval_reserved(session, source, memory, history, lease)

      {:error, reason} ->
        evaluation_reservation_failure(session, reason)
    end
  catch
    :exit, _reason -> session_closed(session)
  end

  defp eval_open(%{mode: %{kind: :mission, name: name}} = session, source) do
    mission = Map.fetch!(session.config.missions, name)
    limits = session.config.limits
    remaining_ms = RunState.remaining_ms(session.state)

    result =
      Evaluation.evaluate_source(
        session.state,
        name,
        mission.environment,
        source,
        limits.evaluation_timeout_ms,
        session.config.event_sink,
        session.config.inspection_sink,
        result_limit_bytes: limits.terminal_result_bytes
      )

    result =
      result
      |> name_mission_timeout(session, remaining_ms)
      |> name_mission_session_failure(session)

    mission_result(session, result)
  catch
    :exit, _reason -> session_closed(session)
  end

  defp session_closed(session) do
    step = Native.error(:session_closed, "REPL session is closed", observed_memory(session))
    {:error, step, session}
  end

  defp terminal_failure_result(
         %{kind: :limit_exceeded, reason: :deadline_expired},
         session
       ) do
    step = Native.error(:limit_exceeded, run_deadline_message(session), observed_memory(session))
    {:error, step, session}
  end

  defp terminal_failure_result(
         %{kind: :limit_exceeded, reason: :subordinate_evaluations},
         session
       ) do
    step =
      Native.error(
        :limit_exceeded,
        subordinate_evaluations_message(session),
        observed_memory(session)
      )

    {:error, step, session}
  end

  defp terminal_failure_result(%{kind: :session_closed}, session),
    do: session_closed(session)

  defp terminal_failure_result(%{kind: kind, reason: reason}, session) do
    step = Native.error(kind, "REPL session closed: #{reason}", observed_memory(session))
    {:error, step, session}
  end

  defp increment_result_error({:error, step, session}),
    do: {:error, step, increment_error(session)}

  defp preexisting_terminal_failure(
         session,
         %{kind: :limit_exceeded, reason: reason} = failure
       )
       when reason in [:deadline_expired, :subordinate_evaluations] do
    failure
    |> terminal_failure_result(session)
    |> increment_result_error()
  end

  defp preexisting_terminal_failure(session, _failure), do: session_closed(session)

  defp reservable_session?(session) do
    not RunState.closed?(session.state) or is_nil(RunState.terminal_failure(session.state))
  end

  @spec close(t()) ::
          {:ok, [map()]}
          | {:error, :provider_cleanup_failed, [map()]}
          | {:error, :trace_persistence_failed, [map()]}
          | {:error,
             :event_sink_error
             | :provider_cleanup_failed
             | :session_closed
             | :session_owner_mismatch}
  @doc """
  Closes a session normally and returns its atomically frozen canonical events.
  When provider cleanup fails after terminal publication, the error tuple also
  returns the frozen events as evidence; the session owner has already attempted
  any authorized trace persistence without exposing that authority to the
  frontend.

  Returns `{:error, :session_owner_mismatch}` without closing anything when
  called outside the process that created the session.
  """
  def close(%__MODULE__{} = session) do
    with {:ok, owned} <- owned_session(session) do
      try do
        owned
        |> close_owned()
        |> persist_close_result(owned)
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

    case ReplSessionOwner.close_provider_session(session.owner_pid, session.owner_token) do
      {:ok, cleanup, terminal_failure} ->
        if state_result == :ok and cleanup_result?(cleanup) and
             Process.alive?(session.config.event_sink.pid) do
          finalize_close(session, cleanup, terminal_failure)
        else
          prefer_cleanup_error({:error, :session_closed}, cleanup)
        end

      {:error, _reason} ->
        {:error, :session_closed}
    end
  end

  defp read_terminal_failure(state) do
    RunState.terminal_failure(state)
  catch
    :exit, _reason -> nil
  end

  defp finalize_close(session, cleanup, terminal_failure) do
    {outcome, reason} =
      case {cleanup, terminal_failure, bounded_counter(session.errors)} do
        {:ok, %{reason: reason}, _errors} ->
          {:error, reason}

        {:ok, nil, 0} ->
          {:ok, nil}

        {:ok, nil, _errors} ->
          {:error, :repl_evaluation_error}

        {{:error, :provider_cleanup_failed}, _failure, _errors} ->
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

  defp persist_close_result({:ok, events} = result, session) do
    case ReplSessionOwner.persist_trace(session.owner_pid, session.owner_token, events) do
      :ok -> result
      {:error, _reason} -> {:error, :trace_persistence_failed, events}
    end
  end

  defp persist_close_result(
         {:error, :provider_cleanup_failed, events} = result,
         session
       ) do
    _ = ReplSessionOwner.persist_trace(session.owner_pid, session.owner_token, events)
    result
  end

  defp persist_close_result(result, _session), do: result

  @spec abort(t(), atom()) ::
          {:ok, [map()]}
          | :ok
          | {:error, :provider_cleanup_failed, [map()]}
          | {:error, :trace_persistence_failed, [map()]}
          | {:error, :provider_cleanup_failed | :session_owner_mismatch}
  @doc """
  Closes a session with an error reason and returns retained events when available.
  When provider cleanup or trace persistence fails after terminal publication,
  the error tuple also returns those events.

  Returns `{:error, :session_owner_mismatch}` without closing anything when
  called outside the process that created the session.
  """
  def abort(%__MODULE__{} = session, reason) when is_atom(reason) do
    case owned_session(session) do
      {:ok, owned} ->
        try do
          owned
          |> abort_owned(reason)
          |> persist_abort_result(owned)
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

  defp persist_abort_result({:ok, events} = result, session) do
    case ReplSessionOwner.persist_trace(session.owner_pid, session.owner_token, events) do
      :ok -> result
      {:error, _reason} -> {:error, :trace_persistence_failed, events}
    end
  end

  defp persist_abort_result(
         {:error, :provider_cleanup_failed, events} = result,
         session
       ) do
    _ = ReplSessionOwner.persist_trace(session.owner_pid, session.owner_token, events)
    result
  end

  defp persist_abort_result(result, _session), do: result

  defp abort_owned(session, reason) do
    state_result = close_run_state(session.state)

    case ReplSessionOwner.close_provider_session(session.owner_pid, session.owner_token) do
      {:ok, cleanup, terminal_failure} ->
        if state_result == :ok and cleanup_result?(cleanup) and
             Process.alive?(session.config.event_sink.pid) do
          finalize_abort(session, terminal_reason(terminal_failure, reason), cleanup)
        else
          prefer_cleanup_error(:ok, cleanup)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp terminal_reason(%{reason: reason}, _fallback), do: reason
  defp terminal_reason(nil, fallback), do: fallback

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

  defp cleanup_result?(:ok), do: true
  defp cleanup_result?({:error, :provider_cleanup_failed}), do: true

  defp close_run_state(state) do
    RunState.close_and_drain(state)
    :ok
  catch
    :exit, _reason -> {:error, :session_closed}
  end

  defp config(nil), do: config_with_limits(Limits.defaults())

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

  defp config_with_limits(%Limits{} = limits) do
    with {:ok, workflow} <- WorkflowEnvironment.new([]),
         {:ok, mission} <- MissionEnvironment.new([]),
         {:ok, sink} <- EventSink.start(:normal, limits) do
      case RunConfig.new(
             workflow_environment: workflow,
             missions: %{"default" => mission},
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

  defp inspection_alive?(nil), do: true
  defp inspection_alive?(sink), do: Process.alive?(sink.pid)

  defp emit_run_started(config) do
    EventSink.claim(config.event_sink, config.claim_id, config.run_started_metadata)
  end

  defp start_session(config, trace_path) do
    with {:ok, owner, token} <- ReplSessionOwner.start_pending(self()) do
      case emit_run_started(config) do
        :ok ->
          start_claimed_session(config, trace_path, owner, token)

        {:error, :event_sink_already_claimed} ->
          ReplSessionOwner.release(owner, token)
          {:error, :event_sink_error}

        {:error, :event_sink_claimed_by_other} ->
          ReplSessionOwner.release(owner, token)

          prefer_cleanup_error(
            {:error, :event_sink_error},
            RunConfig.close_provider_session(config)
          )

        {:error, :event_sink_error} ->
          ReplSessionOwner.release(owner, token)

          reason =
            if Process.alive?(config.event_sink.pid),
              do: :session_owner_mismatch,
              else: :event_sink_error

          prefer_cleanup_error(
            {:error, reason},
            RunConfig.close_provider_session(config)
          )
      end
    end
  end

  defp start_claimed_session(config, trace_path, owner, token) do
    case RunState.start_repl(config.limits, config.event_sink, config.inspection_sink,
           run_deadline: config.run_deadline
         ) do
      {:ok, state} ->
        start_session_with_state(config, state, trace_path, owner, token)

      {:error, reason} ->
        ReplSessionOwner.release(owner, token)

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

  defp start_session_with_state(config, state, trace_path, owner, token) do
    with :ok <- EventSink.transfer_owner(config.event_sink, owner),
         :ok <- transfer_inspection_owner(config.inspection_sink, owner),
         config <- transferred_config(config, owner),
         {:ok, state} <- RunState.use_provider_session(state, config.provider_session),
         :ok <-
           RunConfig.bind_provider_session(config, owner, state.pid, state.provider_tracker),
         :ok <- ReplSessionOwner.adopt_direct(owner, token, config, state, trace_path) do
      register_access(owner, token, :direct)
    else
      {:error, reason} -> reject_pending_session(config, state, owner, token, reason)
    end
  end

  defp transfer_inspection_owner(nil, _owner), do: :ok
  defp transfer_inspection_owner(sink, owner), do: InspectionSink.transfer_owner(sink, owner)

  defp transferred_config(config, owner) do
    inspection_owner = if config.inspection_sink, do: owner, else: nil
    %{config | event_sink_owner: owner, inspection_sink_owner: inspection_owner}
  end

  defp reject_pending_session(config, state, owner, token, reason) do
    RunState.close(state)
    RunState.stop(state)
    ReplSessionOwner.release(owner, token)
    reject_unstarted_config(config, setup_failure_reason(config, reason))
  end

  defp trace_path(_config, nil), do: {:ok, nil}

  defp trace_path(config, path) when is_binary(path) do
    private? = EventSink.policy(config.event_sink) == :private

    with {:ok, path} <- PrivateDirectory.anchor(path),
         :ok <- TraceLog.preflight_destination(path, private?) do
      {:ok, path}
    else
      {:error, _reason} -> reject_unstarted_config(config, :trace_preflight_failed)
    end
  end

  defp trace_path(config, _path), do: reject_unstarted_config(config, :trace_preflight_failed)

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
          result =
            session
            |> run_lisp(memory, history, source)
            |> rewrite_workflow_subordinate_busy(session)

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

  defp run_lisp(session, memory, history, source) do
    limits = session.config.limits
    remaining_ms = RunState.remaining_ms(session.state)
    timeout_ms = min(limits.evaluation_timeout_ms, remaining_ms)
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    result =
      Lisp.run_native(source,
        caller: :repl,
        context: session.config.input,
        memory: memory,
        turn_history: history,
        tools: tools(session, deadline_ms),
        prelude: prelude(session.config.workflow_environment),
        timeout: timeout_ms,
        compile_timeout: timeout_ms,
        run_deadline_ms: deadline_ms,
        pmap_timeout: limits.parallel_timeout_ms,
        max_heap: limits.evaluation_heap_words,
        max_parallel_workers: limits.live_provider_tasks,
        max_program_bytes: limits.subordinate_source_bytes,
        max_tool_call_result_bytes: limits.capability_result_bytes,
        loop_limit: limits.evaluation_loop_iterations,
        preserve_runtime_callables: true,
        filter_context: false,
        link: true,
        strict_data: true,
        data_grants: DataKeys.source_referenceable_forms(session.config.input),
        shipped_library_ids: Library.component_ids()
      )

    name_timeout_limit(result, session, remaining_ms)
  end

  # The sandbox reports the milliseconds still left when it killed the worker,
  # a number that matches no configured value and cannot be searched for. The
  # binding ceiling is known here, so say which one stopped the form and where
  # to raise it, through the same builder `ptc run` uses.
  defp name_timeout_limit({:error, %Native{fail: fail} = step}, session, remaining) do
    limits = session.config.limits

    case named_timeout_message(fail.reason, Map.get(fail, :message), limits, remaining) do
      {:ok, message} ->
        if run_deadline_bound_timeout?(fail.reason, Map.get(fail, :message), limits, remaining) and
             record_run_deadline(session) do
          deadline = %{fail | reason: :limit_exceeded, message: run_deadline_message(session)}
          {:error, %{step | fail: deadline}}
        else
          {:error, %{step | fail: %{fail | message: message}}}
        end

      :error ->
        {:error, step}
    end
  end

  defp name_timeout_limit(result, _session, _remaining), do: result

  # A mission form is bounded by the same ceiling as a workflow one, and the
  # evaluator hands back only the milliseconds it had left. Name the limit here,
  # before `mission_result/2` copies the message onto the step.
  defp name_mission_timeout(
         %{kind: reason, details: %{message: message} = details} = result,
         session,
         remaining
       ) do
    limits = session.config.limits

    case named_timeout_message(reason, message, limits, remaining) do
      {:ok, named} ->
        if run_deadline_bound_timeout?(reason, message, limits, remaining) and
             record_run_deadline(session) do
          result
          |> Map.merge(%{
            outcome: :limit_exceeded,
            kind: :limit_exceeded,
            reason: :deadline_expired
          })
          |> Map.put(:details, %{details | message: run_deadline_message(session)})
        else
          %{result | details: %{details | message: named}}
        end

      :error ->
        result
    end
  end

  defp name_mission_timeout(result, _session, _remaining), do: result

  defp run_deadline_bound_timeout?(reason, message, limits, remaining) do
    limits.evaluation_timeout_ms > remaining and
      (reason == :compile_timeout or (reason == :timeout and not parallel_timeout?(message)))
  end

  defp record_run_deadline(session) do
    case RunState.fail_once(session.state, :limit_exceeded, :deadline_expired) do
      {:recorded, %{kind: :limit_exceeded, reason: :deadline_expired}} ->
        _ =
          EventSink.emit(session.config.event_sink, "limit-exceeded", %{reason: :deadline_expired})

        true

      {:existing, %{kind: :limit_exceeded, reason: :deadline_expired}} ->
        true

      _other ->
        false
    end
  end

  defp name_mission_session_failure(
         %{outcome: :busy, reason: :evaluation_in_progress} = result,
         _session
       ),
       do:
         result
         |> Map.put(:kind, :evaluation_in_progress)
         |> Map.put(:details, %{message: "REPL evaluation in progress"})

  defp name_mission_session_failure(
         %{outcome: :limit_exceeded, reason: :subordinate_evaluations} = result,
         session
       ) do
    :ok = RunState.fail(session.state, :limit_exceeded, :subordinate_evaluations)

    result
    |> Map.put(:kind, :limit_exceeded)
    |> Map.put(:details, %{message: subordinate_evaluations_message(session)})
  end

  defp name_mission_session_failure(
         %{outcome: :limit_exceeded, reason: :deadline_expired} = result,
         session
       ) do
    :ok = RunState.fail(session.state, :limit_exceeded, :deadline_expired)

    result
    |> Map.put(:kind, :limit_exceeded)
    |> Map.put(:details, %{message: run_deadline_message(session)})
  end

  defp name_mission_session_failure(
         %{outcome: :limit_exceeded, reason: :run_closed} = result,
         session
       ) do
    :ok = RunState.fail(session.state, :session_closed, :run_closed)

    result
    |> Map.put(:kind, :session_closed)
    |> Map.put(:details, %{message: "REPL session is closed"})
  end

  defp name_mission_session_failure(result, _session), do: result

  # Compilation and execution are separated the way `ptc run` separates them, by
  # the reason the evaluator reported rather than by which sandbox stage was
  # running. A parallel deadline also surfaces as `:timeout`, and answering it
  # with the evaluation ceiling would name a limit that never fired.
  defp named_timeout_message(:compile_timeout, _message, limits, remaining),
    do: window_timeout_message(limits, remaining, :compilation)

  defp named_timeout_message(:timeout, message, limits, remaining) do
    if parallel_timeout?(message) do
      RuntimeLimitDiagnostic.live_timeout_message(
        :parallel_timeout_ms,
        limits.parallel_timeout_ms,
        :execution
      )
    else
      window_timeout_message(limits, remaining, :execution)
    end
  end

  defp named_timeout_message(_reason, _message, _limits, _remaining), do: :error

  # A form's window is `min(evaluation_timeout_ms, remaining run duration)`, so
  # whichever produced it is the limit worth naming.
  defp window_timeout_message(limits, remaining, phase) do
    {limit, limit_ms} =
      if limits.evaluation_timeout_ms <= remaining,
        do: {:evaluation_timeout_ms, limits.evaluation_timeout_ms},
        else: {:run_duration_ms, limits.run_duration_ms}

    RuntimeLimitDiagnostic.live_timeout_message(limit, limit_ms, phase)
  end

  defp parallel_timeout?(message) when is_binary(message),
    do: String.ends_with?(message, Helpers.parallel_timeout_message())

  defp parallel_timeout?(_message), do: false

  # A workflow REPL expression already holds the single evaluation lease.
  # Nested kernel/eval-source and check-source therefore fail-fast as :busy —
  # which reads as a transient state worth retrying. Rewrite that self-deadlock
  # into the same class of actionable refusal the unknown-namespace path uses.
  defp rewrite_workflow_subordinate_busy({:ok, %{return: value} = step}, session)
       when is_map(value) do
    if workflow_subordinate_busy?(value) do
      {:error,
       Native.error(
         :mission_session_required,
         subordinate_mission_message(session),
         Map.get(step, :memory, %{}),
         %{}
       )}
    else
      {:ok, step}
    end
  end

  defp rewrite_workflow_subordinate_busy(result, _session), do: result

  defp workflow_subordinate_busy?(%{outcome: :busy, reason: :evaluation_in_progress}), do: true
  defp workflow_subordinate_busy?(_value), do: false

  defp subordinate_mission_message(%{config: %{missions: missions}}) when is_map(missions) do
    declared = missions |> Map.keys() |> Enum.sort()

    case declared do
      [] ->
        "this workflow REPL session holds the evaluation lease and cannot run " <>
          "subordinate evaluations; pass --mission NAME to open a mission session instead"

      names ->
        "this workflow REPL session holds the evaluation lease and cannot run " <>
          "subordinate evaluations; pass --mission NAME to open a mission session instead " <>
          "(declared: #{Enum.join(names, ", ")})"
    end
  end

  defp tools(session, validation_deadline_ms) do
    timeout_ms = session.config.limits.evaluation_timeout_ms

    ToolGrant.capability_callbacks(
      session.state,
      :workflow,
      session.config.workflow_environment,
      %{
        timeout_ms: timeout_ms,
        validation_heap_words: session.config.limits.evaluation_heap_words,
        evaluation_lease: nil,
        validation_deadline_ms: validation_deadline_ms,
        mission_name: nil
      },
      session.config.event_sink,
      session.config.inspection_sink
    )
    |> Map.put(
      "kernel-eval",
      RuntimeTools.instrument(
        session.state,
        session.config.event_sink,
        :workflow,
        "kernel-eval",
        RuntimeTools.kernel_eval(
          session.state,
          Map.new(session.config.missions, fn {name, mission} -> {name, mission.environment} end),
          session.config.limits,
          session.config.event_sink,
          session.config.inspection_sink
        )
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
          Map.new(session.config.missions, fn {name, mission} -> {name, mission.environment} end),
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
          Map.new(session.config.missions, fn {name, mission} ->
            {name, mission.inventory.rendered}
          end),
          session.config.event_sink
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
          Map.new(session.config.missions, fn {name, mission} ->
            {name, mission.inventory.model_rendered}
          end),
          session.config.event_sink
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
        RuntimeTools.result_contract(
          session.config.result_contract,
          session.config.phase_return_contracts
        )
      )
    )
    |> RuntimeTools.maybe_put_result_contract_failure(
      session.state,
      session.config.event_sink,
      session.config.result_contract,
      session.config.result_contract_source,
      session.config.workflow_environment
    )
    |> RuntimeTools.maybe_put_llm_provider_failure(
      session.state,
      session.config.event_sink,
      session.config.workflow_environment
    )
    |> RuntimeTools.maybe_put_runtime_limit_failure(
      session.state,
      session.config.event_sink,
      session.config.limits,
      session.config.workflow_environment
    )
    |> RuntimeTools.maybe_put_agent_loop_tools(
      session.state,
      session.config.event_sink,
      session.config.workflow_environment
    )
    |> RuntimeTools.trusted_tools(
      session.config.limits,
      ToolGrant.capability_contracts(session.config.workflow_environment)
    )
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

  defp evaluation_reservation_failure(session, :busy) do
    step =
      Native.error(
        :evaluation_in_progress,
        "REPL evaluation in progress",
        observed_memory(session)
      )

    {:error, step, increment_error(session)}
  end

  defp evaluation_reservation_failure(session, :limit_exceeded) do
    terminal_reservation_failure(
      session,
      :limit_exceeded,
      :subordinate_evaluations,
      subordinate_evaluations_message(session)
    )
  end

  defp evaluation_reservation_failure(session, :deadline_expired) do
    terminal_reservation_failure(
      session,
      :limit_exceeded,
      :deadline_expired,
      run_deadline_message(session)
    )
  end

  defp evaluation_reservation_failure(session, :run_closed) do
    terminal_reservation_failure(
      session,
      :session_closed,
      :run_closed,
      "REPL session is closed"
    )
  end

  defp terminal_reservation_failure(session, public_reason, closed_reason, message) do
    case EventSink.emit(session.config.event_sink, "limit-exceeded", %{reason: closed_reason}) do
      :ok ->
        :ok = RunState.fail(session.state, public_reason, closed_reason)
        step = Native.error(public_reason, message, observed_memory(session))
        {:error, step, increment_error(session)}

      {:error, :event_sink_error} ->
        event_sink_failure(session)
    end
  end

  defp subordinate_evaluations_message(%{mode: :direct, config: config}) do
    {:ok, message} =
      RuntimeLimitDiagnostic.direct_subordinate_evaluations_message(
        config.limits.subordinate_evaluations
      )

    message
  end

  defp subordinate_evaluations_message(%{config: config}) do
    {:ok, message} =
      RuntimeLimitDiagnostic.subordinate_evaluations_message(
        config.limits.subordinate_evaluations
      )

    message
  end

  defp run_deadline_message(%{mode: :direct, config: config}) do
    {:ok, message} =
      RuntimeLimitDiagnostic.direct_live_timeout_message(
        :run_duration_ms,
        config.limits.run_duration_ms,
        :execution
      )

    message
  end

  defp run_deadline_message(%{config: config}) do
    {:ok, message} =
      RuntimeLimitDiagnostic.live_timeout_message(
        :run_duration_ms,
        config.limits.run_duration_ms,
        :execution
      )

    message
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
    with {:ok, pid, token, mode} <- access_resources(session),
         {:ok, config, state} <- owner_resources(session, pid, token) do
      {:ok,
       Map.merge(Map.from_struct(session), %{
         owner_pid: pid,
         owner_token: token,
         config: config,
         state: state,
         mode: mode,
         memory: %{},
         history: [],
         attempts: bounded_counter(session.attempts),
         errors: bounded_counter(session.errors)
       })}
    end
  end

  defp owner_resources(session, pid, token) do
    ReplSessionOwner.resources(pid, token)
  catch
    :exit, reason ->
      if Process.alive?(pid) do
        exit(reason)
      else
        close_access(session)
        {:error, :session_closed}
      end
  end

  defp register_access(pid, token, mode) do
    access = access_table()
    id = make_ref()
    true = :ets.insert(access, {id, {pid, token}})
    true = :ets.insert(access, {{id, :mode}, mode})
    {:ok, %__MODULE__{access: access, id: id}}
  rescue
    exception ->
      _ = ReplSessionOwner.release(pid, token)
      {:error, {:session_access_error, Exception.message(exception)}}
  end

  defp access_resources(%__MODULE__{access: access, id: id}) do
    case :ets.lookup(access, id) do
      [{^id, {pid, token}}] when is_pid(pid) and is_reference(token) ->
        case :ets.lookup(access, {id, :mode}) do
          [{{^id, :mode}, mode}] -> {:ok, pid, token, mode}
          _missing -> {:error, :session_owner_mismatch}
        end

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
    :ets.delete(access, {id, :mode})
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

  defp public_result({status, step, session}, mode)
       when status in [:ok, :error] and mode in [:direct, :workflow] do
    {public_status, public_step} = Lisp.project_native_result({status, step})
    {public_status, public_step, public_session(session)}
  end

  defp public_result({status, %Native{} = step, session}, %{kind: :mission})
       when status in [:ok, :error],
       do: {status, step, public_session(session)}

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

  # A workflow session reports the missions the manifest declares but this
  # session cannot reach, so a frontend can name the switch that would open one
  # instead of leaving the reader with the language's own namespace list.
  defp owned_mode_info(%{mode: :workflow, config: %{missions: missions}})
       when is_map(missions),
       do: %{kind: :workflow, declared_missions: missions |> Map.keys() |> Enum.sort()}

  defp owned_mode_info(%{mode: :workflow}), do: %{kind: :workflow, declared_missions: []}

  defp owned_mode_info(%{mode: :direct}), do: %{kind: :workflow, declared_missions: []}

  defp owned_mode_info(%{mode: %{kind: :mission, name: name} = mode, config: config}) do
    inventory = Map.fetch!(config.missions, name).inventory

    %{
      kind: :mission,
      mission: name,
      component_ids: mode.component_ids,
      direct_provider_aliases: mode.direct_provider_aliases,
      inventory_hash: inventory.hash,
      model_context_hash: inventory.model_hash
    }
  end

  defp mission_result(session, %{outcome: outcome, value: value} = result)
       when outcome in [:continued, :returned] do
    step = %{Native.ok(value, %{}) | prints: Map.get(result, :prints, [])}
    {:ok, step, %{session | attempts: increment_counter(session.attempts)}}
  end

  defp mission_result(session, %{outcome: :failed, value: value} = result) do
    step =
      Native.error(
        :explicit_failure,
        "REPL evaluation explicitly failed",
        %{},
        %{value: value}
      )
      |> Map.put(:prints, Map.get(result, :prints, []))

    {:error, step, increment_error(session)}
  end

  defp mission_result(session, result) do
    reason = Map.get(result, :kind, Map.get(result, :reason, Map.get(result, :outcome)))
    details = Map.get(result, :details, %{})
    message = Map.get(details, :message, "mission evaluation failed")

    step =
      Native.error(reason || :evaluation_error, message, %{}, details)
      |> Map.put(:prints, Map.get(result, :prints, []))

    {:error, step, increment_error(session)}
  end
end
