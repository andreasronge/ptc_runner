defmodule PtcRunner.Kernel.AnalysisSession do
  @moduledoc """
  Owner of one bounded code-owned analysis mission continuation.

  Sessions are created only from a builder-attested, independently validated
  assembly. One GenServer serializes evaluations, owns the deadline transition,
  monitors its trace owner, and delegates all Lisp execution to
  `PtcRunner.Kernel.Evaluation`. Return and fail are per-form outcomes; only
  lifecycle close, abort, deadline, or terminal Kernel budgets close the session
  against new forms. Close and abort finalize resources and persistence but
  deliberately leave this GenServer alive for idempotent close retry and info;
  every host must eventually call `stop/1`.

  A session whose profile declares a private result class projects its failure
  messages through `PtcRunner.Kernel.PrivateDiagnostic`, which rebuilds
  source-derived names or admits bounded pre-execution diagnostics instead of
  forwarding arbitrary evaluator text. Every error map this module emits
  carries `message_redacted?` so a withheld diagnostic is distinguishable from
  one that was never produced.
  """
  use GenServer

  alias PtcRunner.Kernel.AnalysisAssembly
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.BoundedPrints
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.PrivateDiagnostic
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SessionTrace
  alias PtcRunner.Lisp.ValuePreview
  alias PtcRunner.Utf8

  @formatted_chars 2_048
  @formatted_bytes 8_192
  @prints_bytes 65_536
  @prints_count 128
  @json_projection_timeout_ms 1_000

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @doc false
  def start(assembly), do: start(assembly, [])

  @doc false
  def start(%AnalysisAssembly{} = assembly, opts) when is_list(opts) do
    evaluation_hook = Keyword.get(opts, :evaluation_hook)
    initialization_hook = Keyword.get(opts, :initialization_hook)
    preview_chars = Keyword.get(opts, :preview_chars, @formatted_chars)

    if Keyword.keys(opts) -- [:evaluation_hook, :initialization_hook, :preview_chars] == [] and
         (is_nil(evaluation_hook) or is_function(evaluation_hook, 1)) and
         (is_nil(initialization_hook) or is_function(initialization_hook, 2)) and
         preview_chars in 64..65_536 and
         AnalysisAssembly.valid?(assembly) do
      token = make_ref()

      case GenServer.start(
             __MODULE__,
             {assembly, token, evaluation_hook, initialization_hook, preview_chars}
           ) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, invalid_assembly_error(assembly)}
    end
  end

  def start(_assembly, _opts), do: {:error, :invalid_analysis_assembly}

  @spec evaluate(t(), binary()) :: {:ok, map()} | {:error, atom()}
  def evaluate(session, source) when is_binary(source),
    do: call(session, {:evaluate, source}, :infinity)

  def evaluate(_session, _source), do: {:error, :invalid_source}

  @spec info(t()) :: {:ok, map()} | {:error, atom()}
  def info(session), do: call(session, :info, :infinity)

  @spec close(t()) :: {:ok, map()} | {:error, atom()}
  def close(session), do: call(session, :close, :infinity)

  @spec abort(t(), atom()) :: {:ok, map()} | {:error, atom()}
  def abort(session, reason) when is_atom(reason), do: call(session, {:abort, reason}, :infinity)

  @doc false
  def stop(%__MODULE__{pid: pid}) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({assembly, token, evaluation_hook, initialization_hook, preview_chars}) do
    Process.flag(:trap_exit, true)

    run_state = assembly.run_state

    with true <- Process.alive?(run_state.pid),
         true <- RunState.limits(run_state) === assembly.config.limits,
         :ok <-
           SessionTrace.attach(
             assembly.session_trace,
             self(),
             run_state,
             assembly.resources
           ),
         :ok <-
           EventSink.claim(
             assembly.config.event_sink,
             assembly.config.claim_id,
             assembly.config.run_started_metadata
           ),
         :ok <-
           initialization_hook(
             initialization_hook,
             :after_session_attach,
             %{
               resources: assembly.resources,
               snapshot: AnalysisResources.handle(assembly.resources, :traces),
               inspection_snapshot: AnalysisResources.handle(assembly.resources, :inspection),
               catalog_snapshot: AnalysisResources.handle(assembly.resources, :catalog),
               session_trace: assembly.session_trace,
               run_state: run_state,
               event_sink: assembly.config.event_sink
             },
             assembly.profile.id
           ),
         {:ok, snapshot_info} <- AnalysisResources.info(assembly.resources),
         {:ok, identity} <- EventSink.identity(assembly.config.event_sink) do
      deadline_token = make_ref()

      timer =
        Process.send_after(
          self(),
          {:deadline_expired, deadline_token},
          RunState.remaining_ms(run_state)
        )

      state = %{
        token: token,
        config: assembly.config,
        profile: assembly.profile,
        resources: assembly.resources,
        snapshot: AnalysisResources.handle(assembly.resources, :traces),
        session_trace: assembly.session_trace,
        trace_ref: Process.monitor(assembly.session_trace.pid),
        sink_ref: Process.monitor(assembly.config.event_sink.pid),
        run_state: run_state,
        timer: timer,
        deadline_token: deadline_token,
        evaluation_hook: evaluation_hook,
        preview_chars: preview_chars,
        lifecycle: :open,
        terminal_reason: nil,
        resources_closed?: false,
        evaluation_count: 0,
        session_id: identity.run_id,
        snapshot_info: snapshot_info,
        cached_usage: nil
      }

      {:ok, %{state | cached_usage: usage_projection(state)}}
    else
      {:error, reason} -> {:stop, reason}
      false -> {:stop, :invalid_analysis_assembly}
    end
  end

  @impl GenServer
  def handle_call({token, {:evaluate, source}}, _from, %{token: token} = state) do
    state = expire_if_needed(state)

    if state.lifecycle == :open do
      detailed =
        Evaluation.evaluate_source(
          state.run_state,
          "default",
          state.config.missions["default"].environment,
          source,
          state.config.limits.evaluation_timeout_ms,
          state.config.event_sink,
          state.config.inspection_sink,
          after_started_hook: evaluation_hook(state.evaluation_hook),
          projection_boundary: :public
        )

      projection = project_result(detailed, state, source)
      terminal = terminal_result(detailed, state.run_state)

      next = Map.update!(state, :evaluation_count, &(&1 + 1))

      case terminal do
        :deadline_expired ->
          case close_state(next, :ok, :deadline_expired) do
            {:ok, closed} -> {:reply, {:ok, projection}, closed}
            {:error, _reason, failed} -> {:reply, {:ok, projection}, failed}
          end

        terminal ->
          next = next |> maybe_mark_terminal(terminal) |> cache_usage()
          {:reply, {:ok, projection}, next}
      end
    else
      {:reply, {:error, lifecycle_error(state.lifecycle)}, state}
    end
  end

  def handle_call({token, :info}, _from, %{token: token} = state),
    do: {:reply, {:ok, info_projection(state)}, state}

  def handle_call({token, :close}, _from, %{token: token} = state) do
    {outcome, reason} = terminal_close_outcome(state)

    case close_state(state, outcome, reason) do
      {:ok, next} -> {:reply, {:ok, info_projection(next)}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({token, {:abort, reason}}, _from, %{token: token} = state) do
    {outcome, reason} = effective_close_outcome(state, :error, reason)

    case close_state(state, outcome, reason) do
      {:ok, next} -> {:reply, {:ok, info_projection(next)}, next}
      {:error, failure, next} -> {:reply, {:error, failure}, next}
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, session_closed_error(state.profile.id)}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{trace_ref: ref} = state) do
    next = state |> close_resources() |> Map.put(:lifecycle, :backend_failed)
    {:noreply, %{next | terminal_reason: :event_sink_error, trace_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{sink_ref: ref} = state) do
    next = state |> close_resources() |> Map.put(:lifecycle, :backend_failed)
    {:noreply, %{next | terminal_reason: :event_sink_error, sink_ref: nil}}
  end

  def handle_info(
        {:deadline_expired, deadline_token},
        %{deadline_token: deadline_token} = state
      ) do
    {outcome, reason} = effective_close_outcome(state, :ok, :deadline_expired)

    next =
      case close_state(state, outcome, reason) do
        {:ok, closed} -> closed
        {:error, _reason, failed} -> failed
      end

    {:noreply, next}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp close_state(%{lifecycle: :closed} = state, _outcome, _reason), do: {:ok, state}

  defp close_state(%{lifecycle: :persistence_failed} = state, _outcome, _reason) do
    case SessionTrace.persist(state.session_trace) do
      {:ok, _trace_info} -> {:ok, %{state | lifecycle: :closed}}
      {:error, persistence_reason} -> {:error, persistence_reason, state}
    end
  catch
    :exit, _reason ->
      next = state |> close_resources() |> Map.put(:lifecycle, :backend_failed)
      {:error, :session_closed, next}
  end

  defp close_state(state, outcome, reason) do
    :ok = RunState.close(state.run_state)
    usage = usage_projection(state)
    state = %{state | cached_usage: usage}

    case SessionTrace.finalize(state.session_trace, outcome, reason, usage) do
      :ok ->
        state = close_resources(state)

        case SessionTrace.persist(state.session_trace) do
          {:ok, _trace_info} ->
            {:ok, %{state | lifecycle: :closed}}

          {:error, persistence_reason} ->
            {:error, persistence_reason, %{state | lifecycle: :persistence_failed}}
        end

      {:error, finalization_reason} ->
        {:error, finalization_reason, %{close_resources(state) | lifecycle: :backend_failed}}
    end
  catch
    :exit, _reason ->
      next = state |> close_resources() |> Map.put(:lifecycle, :backend_failed)
      {:error, :session_closed, next}
  end

  defp close_resources(%{resources_closed?: true} = state), do: state

  defp close_resources(state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    if is_reference(state.sink_ref), do: Process.demonitor(state.sink_ref, [:flush])

    case safe_trace_cleanup(state.session_trace) do
      :ok -> :ok
      {:error, _reason} -> cleanup_resource_fallback(state)
    end

    %{state | resources_closed?: true, timer: nil, deadline_token: nil, sink_ref: nil}
  end

  defp safe_trace_cleanup(session_trace) do
    SessionTrace.resources_closed(session_trace)
  catch
    :exit, _reason -> {:error, :session_trace_closed}
  end

  defp cleanup_resource_fallback(state) do
    AnalysisResources.stop(state.resources)

    try do
      RunState.close(state.run_state)
      RunState.stop(state.run_state)
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  defp project_result(detailed, state, source) do
    {prints, prints_truncated?} = bounded_prints(Map.get(detailed, :prints, []))

    projection = %{
      status: result_status(detailed.outcome),
      outcome: detailed.outcome,
      continuation_effect: detailed.continuation_effect,
      value: nil,
      value_available?: false,
      formatted: nil,
      formatted_truncated?: false,
      prints: prints,
      prints_truncated?: prints_truncated?,
      error: error_projection(detailed, state, source),
      evaluation_id: detailed.evaluation_id,
      duration_ms: detailed.duration_ms,
      usage: usage_projection(state)
    }

    projection =
      if Map.has_key?(detailed, :value),
        do: put_value_projection(projection, detailed.value, state),
        else: projection

    enforce_result_limit(
      projection,
      state.config.limits.terminal_result_bytes,
      state.profile.id
    )
  end

  defp put_value_projection(projection, nil, _state) do
    Map.merge(projection, %{
      value: nil,
      value_available?: true,
      formatted: "nil",
      formatted_caps_hit: [],
      formatted_sampled_keys: []
    })
  end

  defp put_value_projection(projection, value, state) do
    limits = state.config.limits
    preview = bounded_format(value, limits, state.preview_chars)

    case bounded_json_value(value, limits) do
      {:ok, normalized} ->
        projection
        |> Map.merge(%{value: normalized, value_available?: true})
        |> put_preview(preview)

      :unavailable ->
        unavailable_value(projection, preview)

      :result_exceeded ->
        projection
        |> result_exceeded_projection(state.profile.id)
        |> put_preview(preview)
    end
  end

  defp bounded_json_value(value, limits) do
    worker_result =
      BoundedWorker.run(
        fn ->
          with {:ok, encoded} <- Jason.encode(value, maps: :strict),
               true <- byte_size(encoded) <= limits.terminal_result_bytes,
               {:ok, normalized} <- Jason.decode(encoded),
               true <- JSONValue.value?(normalized) do
            {:ok, normalized}
          else
            false -> :result_exceeded
            {:error, _reason} -> :unavailable
          end
        end,
        timeout_ms: min(limits.evaluation_timeout_ms, @json_projection_timeout_ms),
        max_heap_words: limits.evaluation_heap_words,
        cancel_with_caller: true
      )

    case worker_result do
      {:ok, {:ok, normalized}} -> {:ok, normalized}
      {:ok, :unavailable} -> :unavailable
      {:ok, :result_exceeded} -> :result_exceeded
      {:error, _reason} -> :result_exceeded
    end
  end

  defp unavailable_value(projection, preview),
    do: projection |> Map.merge(%{value: nil, value_available?: false}) |> put_preview(preview)

  defp put_preview(projection, preview) do
    Map.merge(projection, %{
      formatted: preview.text,
      formatted_truncated?: preview.truncated?,
      formatted_caps_hit: preview.caps_hit,
      formatted_sampled_keys: preview.sampled_keys
    })
  end

  defp bounded_format(value, limits, preview_chars) do
    case BoundedWorker.run(
           fn ->
             ValuePreview.render_with_notice(value,
               max_chars: preview_chars,
               max_bytes: min(preview_chars * 4, max(@formatted_bytes, preview_chars))
             )
           end,
           timeout_ms: min(limits.evaluation_timeout_ms, @json_projection_timeout_ms),
           max_heap_words: limits.evaluation_heap_words,
           cancel_with_caller: true
         ) do
      {:ok, result} -> result
      {:error, reason} -> ValuePreview.fallback(reason)
    end
  end

  defp bounded_prints(prints), do: BoundedPrints.bound(prints, @prints_count, @prints_bytes)

  defp error_projection(%{outcome: outcome}, _state, _source)
       when outcome in [:continued, :returned],
       do: nil

  defp error_projection(result, state, source) do
    details = private_diagnostic_details(result)
    kind = Map.get(result, :kind, result.outcome)
    {message, redacted?} = error_message(kind, details, state, source)

    %{
      kind: kind,
      reason: Map.get(result, :reason),
      message: message,
      message_redacted?: redacted?,
      capability_activity?: Map.get(details, :capability_activity?),
      capability_failure?: Map.get(result, :capability_failure?),
      retryable?: Map.get(result, :retryable?)
    }
  end

  # OR top-level and details flags so either true blocks pre-execution
  # admission. When neither recorded activity, leave the key absent so
  # `PrivateDiagnostic` fails closed rather than inventing an idle measurement.
  defp private_diagnostic_details(result) do
    details =
      case Map.get(result, :details, %{}) do
        map when is_map(map) -> map
        _other -> %{}
      end

    case {Map.fetch(result, :capability_activity?), Map.fetch(details, :capability_activity?)} do
      {:error, :error} ->
        details

      {top, detail} ->
        activity? = match?({:ok, true}, top) or match?({:ok, true}, detail)
        Map.put(details, :capability_activity?, activity?)
    end
  end

  # A private session never forwards arbitrary evaluator text; see
  # `PrivateDiagnostic` for the two admission rules.
  defp error_message(
         kind,
         details,
         %{profile: %{identity: %{"result_data_class" => class}}},
         source
       )
       when class != "normal",
       do: PrivateDiagnostic.project(kind, details, source)

  defp error_message(_kind, details, _state, _source),
    do: {bounded_message(Map.get(details, :message)), false}

  defp bounded_message(message) when is_binary(message), do: Utf8.truncate(message, 4_096)
  defp bounded_message(_message), do: nil

  defp enforce_result_limit(projection, limit, profile_id) do
    case Jason.encode(projection) do
      {:ok, encoded} when byte_size(encoded) <= limit ->
        projection

      _ ->
        result_exceeded_projection(projection, profile_id)
    end
  end

  defp result_exceeded_projection(projection, profile_id) do
    %{
      status: :error,
      outcome: :result_exceeded,
      continuation_effect: projection.continuation_effect,
      value: nil,
      value_available?: false,
      formatted: nil,
      formatted_truncated?: true,
      formatted_caps_hit: [:output],
      formatted_sampled_keys: [],
      prints: [],
      prints_truncated?: projection.prints_truncated? or projection.prints != [],
      error: %{
        kind: :result_exceeded,
        reason: :terminal_result_bytes,
        # A fixed profile literal, so no private text is withheld here.
        message: result_limit_message(profile_id),
        message_redacted?: false,
        capability_activity?: nil,
        capability_failure?: nil,
        retryable?: nil
      },
      evaluation_id: projection.evaluation_id,
      duration_ms: projection.duration_ms,
      usage: projection.usage
    }
  end

  defp result_limit_message(profile_id) do
    {:ok, recipe} = AnalysisProfileRegistry.fetch(profile_id)
    recipe.result_limit_message()
  end

  defp info_projection(state) do
    %{
      session_id: state.session_id,
      lifecycle: state.lifecycle,
      profile_id: state.profile.id,
      profile_digest: state.profile.digest,
      namespaces: state.profile.namespaces,
      snapshot: state.snapshot_info,
      evaluation_count: state.evaluation_count,
      terminal_reason: state.terminal_reason,
      usage: current_usage(state),
      trace: trace_info(state.session_trace)
    }
  end

  defp trace_info(session_trace) do
    SessionTrace.info(session_trace)
  catch
    :exit, _reason -> %{persistence: :backend_failed, terminal: nil, event_count: 0}
  end

  defp current_usage(%{resources_closed?: true} = state), do: state.cached_usage
  defp current_usage(state), do: usage_projection(state)

  defp cache_usage(state), do: %{state | cached_usage: usage_projection(state)}

  defp usage_projection(state) do
    usage = RunState.usage(state.run_state)
    limits = state.config.limits
    calls = usage.capability_calls.mission
    total_used = calls |> Map.values() |> Enum.sum()
    aggregate_remaining = max(limits.mission_capability_calls - total_used, 0)

    capability_calls =
      Map.new(state.profile.identity["explicit_capabilities"], fn name ->
        used = Map.get(calls, name, 0)
        per_name_remaining = max(limits.mission_capability_calls_per_name - used, 0)

        {name,
         %{
           used: used,
           limit: limits.mission_capability_calls_per_name,
           remaining: min(per_name_remaining, aggregate_remaining)
         }}
      end)

    usage_projection = %{
      remaining_ms: usage.remaining_ms,
      evaluations: %{
        used: usage.subordinate_evaluations,
        limit: limits.subordinate_evaluations,
        remaining: max(limits.subordinate_evaluations - usage.subordinate_evaluations, 0)
      },
      source_checks: %{
        used: usage.subordinate_source_checks,
        limit: limits.subordinate_source_checks,
        remaining: max(limits.subordinate_source_checks - usage.subordinate_source_checks, 0)
      },
      mission_calls: %{
        used: total_used,
        limit: limits.mission_capability_calls,
        remaining: aggregate_remaining
      },
      continuation: RunState.evaluation_memory_summary(state.run_state)
    }

    Map.put(usage_projection, usage_capability_key(state.profile.id), capability_calls)
  end

  defp usage_capability_key(profile_id) do
    {:ok, recipe} = AnalysisProfileRegistry.fetch(profile_id)
    recipe.usage_capability_key()
  end

  defp session_failed_error(profile_id) do
    {:ok, recipe} = AnalysisProfileRegistry.fetch(profile_id)
    recipe.session_failed_error()
  end

  defp session_closed_error(profile_id) do
    {:ok, recipe} = AnalysisProfileRegistry.fetch(profile_id)
    recipe.session_closed_error()
  end

  defp maybe_mark_terminal(state, nil), do: state

  defp maybe_mark_terminal(state, %{reason: reason}),
    do: mark_terminal(state, reason)

  defp maybe_mark_terminal(state, reason) when is_atom(reason),
    do: mark_terminal(state, reason)

  defp mark_terminal(state, reason) do
    :ok = SessionTrace.mark_terminal(state.session_trace, reason)
    %{state | lifecycle: :terminal_unpersisted, terminal_reason: reason}
  end

  defp terminal_result(%{reason: :subordinate_evaluations}, _run_state),
    do: :subordinate_evaluations

  defp terminal_result(_detailed, run_state) do
    case RunState.terminal_failure(run_state) do
      nil -> if(RunState.remaining_ms(run_state) == 0, do: :deadline_expired)
      failure -> failure
    end
  end

  defp terminal_close_outcome(%{terminal_reason: nil}), do: {:ok, nil}
  defp terminal_close_outcome(state), do: {:error, state.terminal_reason}

  defp effective_close_outcome(%{terminal_reason: nil}, outcome, reason),
    do: {outcome, reason}

  defp effective_close_outcome(state, _outcome, _reason),
    do: {:error, state.terminal_reason}

  defp expire_if_needed(%{lifecycle: :open} = state) do
    if RunState.remaining_ms(state.run_state) == 0 do
      case close_state(state, :ok, :deadline_expired) do
        {:ok, closed} -> closed
        {:error, _reason, failed} -> failed
      end
    else
      state
    end
  end

  defp expire_if_needed(state), do: state

  defp evaluation_hook(nil), do: nil
  defp evaluation_hook(hook), do: fn -> hook.(:after_evaluation_started) end

  defp initialization_hook(nil, _stage, _resources, _profile_id), do: :ok

  defp initialization_hook(hook, stage, resources, profile_id) do
    case hook.(stage, resources) do
      :ok -> :ok
      _other -> {:error, session_failed_error(profile_id)}
    end
  rescue
    _exception -> {:error, session_failed_error(profile_id)}
  catch
    _kind, _reason -> {:error, session_failed_error(profile_id)}
  end

  defp result_status(outcome) when outcome in [:continued, :returned], do: :ok
  defp result_status(_outcome), do: :error

  defp lifecycle_error(:terminal_unpersisted), do: :session_terminal
  defp lifecycle_error(:persistence_failed), do: :persistence_failed
  defp lifecycle_error(:backend_failed), do: :backend_failed
  defp lifecycle_error(_lifecycle), do: :session_closed

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp call(%__MODULE__{pid: pid, token: token}, request, timeout) do
    GenServer.call(pid, {token, request}, timeout)
  catch
    :exit, _reason -> {:error, :session_closed}
  end

  defp invalid_assembly_error(%AnalysisAssembly{profile: %{id: id}}) do
    case AnalysisProfileRegistry.fetch(id) do
      {:ok, recipe} -> recipe.invalid_assembly_error()
      {:error, _reason} -> :invalid_analysis_assembly
    end
  end

  defp invalid_assembly_error(_assembly), do: :invalid_analysis_assembly
end
