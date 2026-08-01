defmodule PtcViewer.ReplStore do
  @moduledoc """
  Responsive presentation owner for one server-selected Viewer REPL session.

  Adapter callbacks always run below the Viewer task supervisor. This process
  owns only opaque handles, public projections, operation bookkeeping, and a
  bounded transcript; continuation state and trace resources remain backend
  owned. Evaluation timeouts are projected by Core as `:evaluation_error`;
  deadline expiry is a session lifecycle transition, not an evaluation outcome.
  """

  use GenServer

  @operation_timeout_ms 25_000
  @short_timeout_ms 2_000
  @recovery_retry_ms 1_000
  @transcript_entries 64
  @transcript_bytes 262_144
  @transcript_entry_bytes 131_072
  @source_preview_bytes 16_384

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def bootstrap(store), do: call(store, :bootstrap)
  def evaluate(store, session_id, source), do: call(store, {:evaluate, session_id, source})

  def template(store, session_id, kind, run_id),
    do: call(store, {:template, session_id, kind, run_id})

  def reset(store, session_id), do: call(store, {:reset, session_id})
  def close(store, session_id), do: call(store, {:close, session_id})
  def authorize_mutation(store, nonce), do: call(store, {:authorize_mutation, nonce})
  def authorize_bootstrap(store, nonce), do: call(store, {:authorize_bootstrap, nonce})
  def page_bootstrap_nonce(store), do: call(store, :page_bootstrap_nonce)
  def shutdown(store, timeout \\ 30_000), do: GenServer.call(store, :shutdown, timeout)

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    {:ok,
     %{
       owner_ref: Process.monitor(owner),
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       adapter: Keyword.fetch!(opts, :adapter),
       backend: Keyword.fetch!(opts, :backend),
       features: Keyword.fetch!(opts, :features),
       mutation_nonce: random_id(),
       page_bootstrap_nonce: Keyword.get_lazy(opts, :page_bootstrap_nonce, &random_id/0),
       server_instance_id: random_id(),
       lifecycle: :never_started,
       session: nil,
       session_id: nil,
       info: nil,
       transcript: [],
       transcript_omitted: 0,
       generation_sequence: 0,
       projection_revision: 0,
       state_revision: 0,
       foreground: nil,
       recovery: nil,
       info_task: nil,
       shutdown_from: nil
     }}
  end

  @impl GenServer
  def handle_call(:page_bootstrap_nonce, _from, state),
    do: {:reply, {:ok, state.page_bootstrap_nonce}, state}

  def handle_call({:authorize_bootstrap, nonce}, _from, state),
    do: {:reply, authorize_nonce(nonce, state.page_bootstrap_nonce), state}

  def handle_call({:authorize_mutation, nonce}, _from, state) do
    {:reply, authorize_nonce(nonce, state.mutation_nonce), state}
  end

  def handle_call(:bootstrap, _from, %{foreground: foreground} = state)
      when not is_nil(foreground) do
    {:reply, {:error, :operation_active}, state}
  end

  def handle_call(:bootstrap, from, %{lifecycle: :never_started} = state) do
    {:noreply, start_operation(state, :start, from, %{context: :bootstrap})}
  end

  def handle_call(:bootstrap, _from, state) do
    {body, state} = take_projection(state)
    {:reply, {:ok, body}, maybe_start_info(state)}
  end

  def handle_call({:evaluate, session_id, source}, from, state) do
    with :ok <- available(state),
         :ok <- session_matches(state, session_id),
         :ok <- evaluable(state),
         :ok <- valid_source(source, state.features["source_limit_bytes"]) do
      meta = source_metadata(source)
      {:noreply, start_operation(state, :evaluation, from, %{source: source, source_meta: meta})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:template, session_id, kind, run_id}, from, state) do
    with :ok <- available(state),
         :ok <- session_matches(state, session_id),
         :ok <- evaluable(state),
         true <- kind in [:run, :turns] and valid_run_id?(run_id) do
      task =
        launch_task(state, @short_timeout_ms, fn ->
          safe_apply(state.adapter, :template, [state.backend, state.session, kind, run_id])
        end)

      foreground = %{
        task: task,
        from: from,
        kind: :template,
        phase: :executing,
        predecessor_lifecycle: state.lifecycle
      }

      {:noreply, semantic(%{state | foreground: foreground, lifecycle: :templating})}
    else
      false -> {:reply, {:error, :invalid_request}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reset, session_id}, from, state) do
    with :ok <- available(state),
         :ok <- session_matches(state, session_id),
         :ok <- resettable(state) do
      if is_nil(state.session) do
        {:noreply, start_operation(state, :start, from, %{context: :reset})}
      else
        {:noreply, start_operation(state, :close, from, %{context: :reset})}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close, session_id}, from, state) do
    with :ok <- available_for_close(state),
         :ok <- session_matches(state, session_id) do
      if is_nil(state.session) or state.lifecycle == :closed do
        {body, state} = take_projection(state)
        {:reply, {:ok, body}, state}
      else
        {:noreply, start_operation(state, :close, from, %{context: :close})}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:shutdown, _from, %{shutdown_from: nil, recovery: recovery} = state)
      when not is_nil(recovery) do
    {:reply, {:error, :adapter_failure}, %{state | shutdown_from: :replied}}
  end

  def handle_call(:shutdown, from, %{shutdown_from: nil} = state) do
    state = %{state | shutdown_from: from}

    cond do
      not is_nil(state.foreground) ->
        {:noreply, state}

      not is_nil(state.session) ->
        {:noreply, start_operation(state, :close, nil, %{context: :shutdown})}

      true ->
        GenServer.reply(from, :ok)
        {:noreply, %{state | shutdown_from: :replied}}
    end
  end

  def handle_call(:shutdown, _from, state), do: {:reply, {:error, :operation_active}, state}
  def handle_call(_request, _from, state), do: {:reply, {:error, :adapter_failure}, state}

  @impl GenServer
  def handle_info(
        {ref, result},
        %{foreground: %{task: %{task: %{ref: ref}}} = foreground} = state
      ) do
    observe_task_down(foreground.task)
    state = %{state | foreground: nil}
    {:noreply, finish_foreground(state, foreground, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{foreground: %{task: %{task: %{ref: ref}}}} = state
      ) do
    if reason == :normal do
      {:noreply, state}
    else
      {:noreply, recover_or_fail_foreground(state, :task_exit)}
    end
  end

  def handle_info(
        {:foreground_timeout, ref},
        %{foreground: %{task: %{task: %{ref: ref}}}} = state
      ) do
    terminate_task(state.foreground.task)
    {:noreply, recover_or_fail_foreground(state, :timeout)}
  end

  def handle_info(
        {:recovery_retry, operation_id},
        %{recovery: %{operation_id: operation_id, task: nil} = recovery} = state
      ) do
    task = launch_recovery_task(state, recovery)
    {:noreply, %{state | recovery: %{recovery | task: task, retry_timer: nil}}}
  end

  def handle_info(
        {ref, result},
        %{recovery: %{task: %{task: %{ref: ref}}} = recovery} = state
      ) do
    observe_task_down(recovery.task)

    foreground =
      recovery
      |> Map.put(:task, nil)
      |> Map.put(:retry_timer, nil)
      |> Map.put(:from, nil)
      |> Map.put(:recovered?, true)

    {:noreply, finish_foreground(%{state | recovery: nil}, foreground, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{recovery: %{task: %{task: %{ref: ref}}} = recovery} = state
      ) do
    if reason == :normal do
      {:noreply, state}
    else
      {:noreply, schedule_recovery(%{state | recovery: %{recovery | task: nil}})}
    end
  end

  def handle_info(
        {:recovery_timeout, ref},
        %{recovery: %{task: %{task: %{ref: ref}}} = recovery} = state
      ) do
    terminate_task(recovery.task)
    {:noreply, schedule_recovery(%{state | recovery: %{recovery | task: nil}})}
  end

  def handle_info(
        {ref, result},
        %{info_task: %{task: %{task: %{ref: ref}}} = info_task} = state
      ) do
    observe_task_down(info_task.task)
    state = %{state | info_task: nil}

    state =
      if info_task.session_id == state.session_id and info_task.revision == state.state_revision do
        install_info_result(state, result)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{info_task: %{task: %{task: %{ref: ref}}}} = state
      ),
      do: {:noreply, %{state | info_task: nil}}

  def handle_info(
        {:info_timeout, ref},
        %{info_task: %{task: %{task: %{ref: ref}}}} = state
      ) do
    terminate_task(state.info_task.task)
    {:noreply, %{state | info_task: nil}}
  end

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

  @impl GenServer
  def terminate(_reason, state) do
    if state.foreground, do: terminate_task(state.foreground.task)
    if state.recovery && state.recovery.task, do: terminate_task(state.recovery.task)
    if state.recovery, do: cancel_timer(state.recovery.retry_timer)
    if state.info_task, do: terminate_task(state.info_task.task)
    :ok
  end

  defp start_operation(state, kind, from, context) do
    operation_id = random_id()
    public_session_id = if kind == :start, do: random_id(), else: state.session_id
    session = if kind == :start, do: nil, else: state.session
    source = Map.get(context, :source)

    task =
      launch_task(state, @operation_timeout_ms, fn ->
        perform_operation(
          state.adapter,
          state.backend,
          session,
          kind,
          operation_id,
          public_session_id,
          source
        )
      end)

    foreground =
      context
      |> Map.drop([:source])
      |> Map.merge(%{
        task: task,
        from: from,
        kind: kind,
        phase: :executing,
        context: Map.get(context, :context, kind),
        operation_id: operation_id,
        public_session_id: public_session_id,
        predecessor_lifecycle: state.lifecycle
      })

    lifecycle = operation_lifecycle(kind, Map.get(context, :context))
    semantic(%{state | foreground: foreground, lifecycle: lifecycle})
  end

  defp perform_operation(adapter, backend, session, kind, operation_id, public_id, source) do
    with :ok <- safe_apply(adapter, :prepare_operation, [backend, session, kind, operation_id]) do
      result = invoke_operation(adapter, backend, session, kind, operation_id, public_id, source)
      result = normalize_operation_result(kind, result)

      info =
        if kind == :evaluation and match?({:ok, _}, result),
          do: safe_apply(adapter, :info, [backend, session]),
          else: nil

      {:operation, result, info}
    end
  end

  defp invoke_operation(adapter, backend, _session, :start, operation_id, public_id, _source),
    do: safe_apply(adapter, :start, [backend, operation_id, public_id])

  defp invoke_operation(adapter, backend, session, :evaluation, operation_id, _public_id, source),
    do: safe_apply(adapter, :evaluate, [backend, session, operation_id, source])

  defp invoke_operation(adapter, backend, session, :close, operation_id, _public_id, _source),
    do: safe_apply(adapter, :close, [backend, session, operation_id])

  defp recover_foreground(%{foreground: %{kind: :template} = foreground} = state, _reason) do
    reply(foreground.from, {:error, :adapter_failure})

    finish_and_maybe_shutdown(%{
      state
      | foreground: nil,
        lifecycle: foreground.predecessor_lifecycle
    })
  end

  defp recover_foreground(%{foreground: foreground} = state, _reason) do
    task = launch_reconciliation_task(state, foreground)

    next = %{foreground | task: task, phase: :reconciling}
    %{state | foreground: next, lifecycle: reconcile_lifecycle(foreground.kind)}
  end

  defp recover_or_fail_foreground(
         %{foreground: %{phase: :acknowledging, ack_attempt: attempt} = foreground} = state,
         _reason
       )
       when attempt < 2 do
    retry_acknowledgement(state, foreground)
  end

  defp recover_or_fail_foreground(
         %{foreground: %{phase: :acknowledging} = foreground} = state,
         _reason
       ) do
    reply(foreground.from, {:error, :adapter_failure})
    retain_recovery(state, foreground)
  end

  defp recover_or_fail_foreground(
         %{foreground: %{phase: :reconciling} = foreground} = state,
         _reason
       ) do
    reply(foreground.from, {:error, :adapter_failure})
    retain_recovery(state, foreground)
  end

  defp recover_or_fail_foreground(state, reason), do: recover_foreground(state, reason)

  defp reconcile(adapter, backend, _session, %{kind: :start, operation_id: operation_id}),
    do: safe_apply(adapter, :reconcile_start, [backend, operation_id])

  defp reconcile(adapter, backend, session, %{kind: :evaluation, operation_id: operation_id}),
    do: safe_apply(adapter, :reconcile_evaluate, [backend, session, operation_id])

  defp reconcile(adapter, backend, session, %{kind: :close, operation_id: operation_id}),
    do: safe_apply(adapter, :reconcile_close, [backend, session, operation_id])

  defp finish_foreground(state, %{kind: :template} = foreground, result) do
    next = %{state | lifecycle: foreground.predecessor_lifecycle}

    case valid_template_result(result) do
      {:ok, source} ->
        {body, next} = take_projection(next, %{"template" => %{"source" => source}})
        reply(foreground.from, {:ok, body})
        finish_and_maybe_shutdown(next)

      {:error, reason} ->
        reply(foreground.from, {:error, reason})
        finish_and_maybe_shutdown(next)
    end
  end

  defp finish_foreground(state, %{phase: :acknowledging} = foreground, :ok),
    do: finish_acknowledgement(state, foreground)

  defp finish_foreground(state, %{phase: :acknowledging} = foreground, _failure),
    do: recover_or_fail_foreground(%{state | foreground: foreground}, :acknowledgement_failed)

  defp finish_foreground(state, foreground, {:operation, result, info_result}) do
    state = install_operation_result(state, foreground, result, info_result)
    {public_result, state} = public_operation_result(state, foreground, result)
    state = preserve_recovery_failure_state(state, foreground)
    start_acknowledgement(state, foreground, result, public_result)
  end

  defp finish_foreground(state, foreground, _invalid) do
    reply(foreground.from, {:error, :adapter_failure})
    state = %{semantic(state) | lifecycle: :backend_failed}

    if foreground.context == :shutdown,
      do: finish_shutdown(state, {:error, :adapter_failure}),
      else: finish_and_maybe_shutdown(state)
  end

  defp start_acknowledgement(state, foreground, operation_result, public_result) do
    task = acknowledgement_task(state, foreground)

    next =
      foreground
      |> Map.put(:task, task)
      |> Map.put(:phase, :acknowledging)
      |> Map.put(:ack_attempt, 1)
      |> Map.put(:operation_result, operation_result)
      |> Map.put(:public_result, public_result)
      |> Map.put(:installed_lifecycle, state.lifecycle)

    %{state | foreground: next}
  end

  defp retry_acknowledgement(state, foreground) do
    task = acknowledgement_task(state, foreground)

    next =
      foreground
      |> Map.put(:task, task)
      |> Map.update!(:ack_attempt, &(&1 + 1))

    %{state | foreground: next}
  end

  defp acknowledgement_task(state, foreground) do
    launch_task(state, @short_timeout_ms, fn ->
      safe_apply(state.adapter, :acknowledge_operation, [
        state.backend,
        foreground.kind,
        foreground.operation_id
      ])
    end)
  end

  defp finish_acknowledgement(state, foreground) do
    result = foreground.operation_result
    state = %{state | lifecycle: foreground.installed_lifecycle}

    cond do
      foreground.context == :shutdown ->
        shutdown_result = if match?({:ok, _}, result), do: :ok, else: {:error, :adapter_failure}

        finish_shutdown(state, shutdown_result)

      foreground.context == :reset and foreground.kind == :close and
        match?({:ok, _}, result) and is_nil(state.shutdown_from) ->
        start_operation(state, :start, foreground.from, %{context: :reset})

      foreground.context == :reset and foreground.kind == :close and
          match?({:ok, _}, result) ->
        reply(foreground.from, {:error, :adapter_failure})
        finish_and_maybe_shutdown(state)

      true ->
        reply(foreground.from, foreground.public_result)
        finish_and_maybe_shutdown(state)
    end
  end

  defp install_operation_result(state, %{kind: :start} = foreground, {:ok, session, info}, _info) do
    case safe_info(info, foreground.public_session_id) do
      {:ok, safe_info} ->
        reset? = foreground.context == :reset

        semantic(%{
          state
          | session: session,
            session_id: foreground.public_session_id,
            info: safe_info,
            lifecycle: lifecycle_from_info(safe_info),
            generation_sequence: state.generation_sequence + 1,
            projection_revision: 0,
            transcript: if(reset?, do: [], else: state.transcript),
            transcript_omitted: if(reset?, do: 0, else: state.transcript_omitted)
        })

      {:error, _reason} ->
        %{semantic(state) | lifecycle: :backend_failed}
    end
  end

  defp install_operation_result(state, %{kind: :start} = foreground, {:error, _reason}, _info) do
    lifecycle = if foreground.context == :bootstrap, do: :never_started, else: :closed
    %{semantic(state) | lifecycle: lifecycle}
  end

  defp install_operation_result(
         state,
         %{kind: :evaluation} = foreground,
         {:ok, result},
         info_result
       ) do
    state = append_transcript(state, foreground.source_meta, result)

    case info_result do
      {:ok, info} ->
        case safe_info(info, state.session_id) do
          {:ok, safe_info} ->
            semantic(%{state | info: safe_info, lifecycle: lifecycle_from_info(safe_info)})

          {:error, _reason} ->
            %{semantic(state) | lifecycle: :backend_failed}
        end

      _other ->
        semantic(%{state | lifecycle: lifecycle_from_result(result, state.lifecycle)})
    end
  end

  defp install_operation_result(
         state,
         %{kind: :evaluation} = foreground,
         {:error, _reason},
         _info
       ),
       do: %{semantic(state) | lifecycle: foreground.predecessor_lifecycle}

  defp install_operation_result(state, %{kind: :close}, {:ok, info}, _info_result) do
    case safe_info(info, state.session_id) do
      {:ok, safe_info} ->
        semantic(%{
          state
          | session: nil,
            info: safe_info,
            lifecycle: lifecycle_from_info(safe_info)
        })

      {:error, _reason} ->
        %{semantic(state) | lifecycle: :backend_failed}
    end
  end

  defp install_operation_result(state, %{kind: :close}, {:error, reason}, _info_result) do
    lifecycle = if persistence_reason?(reason), do: :persistence_failed, else: :backend_failed
    %{semantic(state) | lifecycle: lifecycle}
  end

  defp install_operation_result(state, _foreground, _result, _info_result),
    do: %{semantic(state) | lifecycle: :backend_failed}

  defp public_operation_result(state, foreground, {:ok, result})
       when foreground.kind == :evaluation do
    {body, state} = take_projection(state, %{"evaluation" => result})
    {{:ok, body}, state}
  end

  defp public_operation_result(state, %{kind: :start}, {:ok, _session, _info}) do
    {body, state} = take_projection(state)
    {{:ok, body}, state}
  end

  defp public_operation_result(state, foreground, {:ok, _result})
       when foreground.kind == :close do
    {body, state} = take_projection(state)
    {{:ok, body}, state}
  end

  defp public_operation_result(state, %{kind: :start}, {:error, reason}),
    do: {{:error, start_error(reason)}, state}

  defp public_operation_result(state, %{kind: :evaluation}, {:error, reason}),
    do: {{:error, evaluation_error(reason)}, state}

  defp public_operation_result(state, %{kind: :close}, {:error, reason}),
    do: {{:error, close_error(reason)}, state}

  defp public_operation_result(state, _foreground, _result),
    do: {{:error, :adapter_failure}, state}

  defp finish_shutdown(%{shutdown_from: from} = state, result) when is_tuple(from) do
    GenServer.reply(from, result)
    %{state | shutdown_from: :replied}
  end

  defp finish_shutdown(state, _result), do: state

  defp finish_and_maybe_shutdown(%{shutdown_from: from, foreground: nil} = state)
       when is_tuple(from) do
    if is_nil(state.session) do
      GenServer.reply(from, :ok)
      %{state | shutdown_from: :replied}
    else
      start_operation(state, :close, nil, %{context: :shutdown})
    end
  end

  defp finish_and_maybe_shutdown(state), do: state

  defp maybe_start_info(%{foreground: nil, info_task: nil, session: session} = state)
       when not is_nil(session) and is_nil(state.recovery) do
    task =
      launch_info_task(state, fn ->
        safe_apply(state.adapter, :info, [state.backend, state.session])
      end)

    %{
      state
      | info_task: %{task: task, session_id: state.session_id, revision: state.state_revision}
    }
  end

  defp maybe_start_info(state), do: state

  defp install_info_result(state, {:ok, info}) do
    case safe_info(info, state.session_id) do
      {:ok, safe_info} ->
        semantic(%{state | info: safe_info, lifecycle: lifecycle_from_info(safe_info)})

      {:error, _reason} ->
        %{semantic(state) | lifecycle: :backend_failed}
    end
  end

  defp install_info_result(state, _result), do: state

  defp append_transcript(state, source_meta, result) do
    entry = transcript_entry(source_meta, result)
    entries = Enum.take(state.transcript ++ [entry], -@transcript_entries)
    count_evicted = max(length(state.transcript) + 1 - length(entries), 0)
    {entries, bytes_evicted} = evict_encoded(entries, 0)

    semantic(%{
      state
      | transcript: entries,
        transcript_omitted: state.transcript_omitted + count_evicted + bytes_evicted
    })
  end

  defp transcript_entry(source_meta, result) do
    projected =
      Map.take(result, [
        :evaluation_id,
        :status,
        :outcome,
        :continuation_effect,
        :duration_ms,
        :usage,
        :value,
        :value_available?,
        :formatted,
        :formatted_truncated?,
        :prints,
        :prints_truncated?,
        :error
      ])

    entry = Map.merge(source_meta, %{result: projected})

    if encoded_size(entry) <= @transcript_entry_bytes do
      entry
    else
      %{
        source_bytes: source_meta.source_bytes,
        source_preview: source_meta.source_preview,
        source_truncated?: source_meta.source_truncated?,
        result:
          Map.merge(
            Map.take(projected, [
              :evaluation_id,
              :status,
              :outcome,
              :continuation_effect,
              :duration_ms
            ]),
            %{optional_fields_omitted?: true}
          )
      }
    end
  end

  defp evict_encoded(entries, evicted) do
    if encoded_size(entries) <= @transcript_bytes or length(entries) <= 1 do
      {entries, evicted}
    else
      evict_encoded(tl(entries), evicted + 1)
    end
  end

  defp source_metadata(source) do
    preview = clip_utf8(source, @source_preview_bytes)

    %{
      source_bytes: byte_size(source),
      source_preview: preview,
      source_truncated?: byte_size(preview) < byte_size(source)
    }
  end

  defp take_projection(state, extra \\ %{}) do
    revision = state.projection_revision + 1

    body =
      %{
        "session_id" => state.session_id,
        "server_instance_id" => state.server_instance_id,
        "generation_sequence" => max(state.generation_sequence, 1),
        "projection_revision" => revision,
        "mutation_nonce" => state.mutation_nonce,
        "lifecycle" => Atom.to_string(state.lifecycle),
        "session" => state.info,
        "transcript" => state.transcript,
        "transcript_omitted_count" => state.transcript_omitted
      }
      |> Map.merge(extra)

    {body, %{state | projection_revision: revision}}
  end

  defp safe_info(info, public_session_id) when is_map(info) and is_binary(public_session_id) do
    allowed = [
      :lifecycle,
      :profile_id,
      :profile_digest,
      :namespaces,
      :snapshot,
      :evaluation_count,
      :terminal_reason,
      :usage,
      :trace
    ]

    projected = info |> Map.take(allowed) |> Map.put(:session_id, public_session_id)

    with "log-analysis-v2" <- Map.get(projected, :profile_id),
         ["cap", "log", "log.analysis"] <- Map.get(projected, :namespaces),
         {:ok, encoded} <- Jason.encode(projected),
         true <- byte_size(encoded) <= 524_288 do
      {:ok, projected}
    else
      _invalid -> {:error, :adapter_failure}
    end
  end

  defp safe_info(_info, _public_session_id), do: {:error, :adapter_failure}

  defp valid_template_result({:ok, %{source: source}})
       when is_binary(source) and byte_size(source) <= 65_536 do
    if String.valid?(source), do: {:ok, source}, else: {:error, :adapter_failure}
  end

  defp valid_template_result({:error, _reason}), do: {:error, :adapter_failure}
  defp valid_template_result(_result), do: {:error, :adapter_failure}

  defp available(%{foreground: nil, recovery: nil, shutdown_from: nil}), do: :ok
  defp available(%{foreground: nil, shutdown_from: :replied}), do: {:error, :adapter_failure}
  defp available(_state), do: {:error, :operation_active}

  defp available_for_close(%{foreground: nil, recovery: nil}), do: :ok
  defp available_for_close(_state), do: {:error, :operation_active}

  defp session_matches(%{session_id: session_id}, session_id) when is_binary(session_id), do: :ok
  defp session_matches(_state, _session_id), do: {:error, :session_changed}

  defp evaluable(%{lifecycle: :open}), do: :ok
  defp evaluable(%{lifecycle: :terminal}), do: {:error, :session_terminal}

  defp evaluable(%{lifecycle: lifecycle}) when lifecycle in [:closed, :persistence_failed],
    do: {:error, :session_closed}

  defp evaluable(%{lifecycle: :backend_failed}), do: {:error, :adapter_failure}
  defp evaluable(_state), do: {:error, :operation_active}

  defp resettable(%{lifecycle: lifecycle})
       when lifecycle in [:open, :terminal, :closed, :persistence_failed], do: :ok

  defp resettable(%{lifecycle: :backend_failed}), do: {:error, :adapter_failure}
  defp resettable(_state), do: {:error, :operation_active}

  defp valid_source(source, limit) when is_binary(source) and byte_size(source) <= limit do
    if String.valid?(source), do: :ok, else: {:error, :invalid_request}
  end

  defp valid_source(source, limit) when is_binary(source) and byte_size(source) > limit,
    do: {:error, :source_too_large}

  defp valid_source(_source, _limit), do: {:error, :invalid_request}

  defp valid_run_id?(run_id),
    do: is_binary(run_id) and String.valid?(run_id) and byte_size(run_id) in 1..512

  defp operation_lifecycle(:start, _context), do: :starting
  defp operation_lifecycle(:evaluation, _context), do: :evaluating
  defp operation_lifecycle(:close, :reset), do: :resetting
  defp operation_lifecycle(:close, _context), do: :closing

  defp reconcile_lifecycle(:start), do: :reconciling_start
  defp reconcile_lifecycle(:evaluation), do: :evaluating
  defp reconcile_lifecycle(:close), do: :closing

  defp lifecycle_from_info(%{lifecycle: :open}), do: :open
  defp lifecycle_from_info(%{lifecycle: :terminal_unpersisted}), do: :terminal
  defp lifecycle_from_info(%{lifecycle: :closed}), do: :closed
  defp lifecycle_from_info(%{lifecycle: :persistence_failed}), do: :persistence_failed
  defp lifecycle_from_info(%{lifecycle: :backend_failed}), do: :backend_failed
  defp lifecycle_from_info(_info), do: :backend_failed

  defp lifecycle_from_result(%{outcome: outcome}, _current)
       when outcome in [:limit_exceeded],
       do: :terminal

  defp lifecycle_from_result(_result, _current), do: :open

  defp start_error(reason) when reason in [:source_changed], do: :trace_changed

  defp start_error(reason)
       when reason in [:source_limit_exceeded, :source_retained_limit_exceeded],
       do: :trace_source_too_large

  defp start_error(reason) when reason in [:malformed_source, :unsupported_version],
    do: :unsupported_trace

  defp start_error(reason) when reason in [:source_unavailable], do: :trace_unavailable

  defp start_error(reason) when reason in [:not_started, :repl_start_failed],
    do: :repl_start_failed

  defp start_error(_reason), do: :adapter_failure

  defp evaluation_error(:source_too_large), do: :source_too_large
  defp evaluation_error(:session_terminal), do: :session_terminal
  defp evaluation_error(:session_closed), do: :session_closed
  defp evaluation_error(_reason), do: :adapter_failure

  defp close_error(reason),
    do: if(persistence_reason?(reason), do: :persistence_failed, else: :adapter_failure)

  defp persistence_reason?(reason),
    do:
      reason in [
        :persistence_failed,
        :trace_persistence_failed,
        :trace_publication_failed,
        :trace_collision
      ]

  defp launch_task(state, timeout_ms, function) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, function)
    timer = Process.send_after(self(), {:foreground_timeout, task.ref}, timeout_ms)
    %{task: task, timer: timer}
  end

  defp launch_info_task(state, function) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, function)
    timer = Process.send_after(self(), {:info_timeout, task.ref}, @short_timeout_ms)
    %{task: task, timer: timer}
  end

  defp launch_reconciliation_task(state, foreground) do
    launch_task(state, @operation_timeout_ms, fn -> reconciliation_result(state, foreground) end)
  end

  defp launch_recovery_task(state, %{phase: :acknowledging} = recovery) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        safe_apply(state.adapter, :acknowledge_operation, [
          state.backend,
          recovery.kind,
          recovery.operation_id
        ])
      end)

    timer = Process.send_after(self(), {:recovery_timeout, task.ref}, @short_timeout_ms)
    %{task: task, timer: timer}
  end

  defp launch_recovery_task(state, recovery) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        reconciliation_result(state, recovery)
      end)

    timer = Process.send_after(self(), {:recovery_timeout, task.ref}, @operation_timeout_ms)
    %{task: task, timer: timer}
  end

  defp reconciliation_result(state, foreground) do
    result = reconcile(state.adapter, state.backend, state.session, foreground)
    result = normalize_operation_result(foreground.kind, result)

    info =
      if foreground.kind == :evaluation and match?({:ok, _}, result),
        do: safe_apply(state.adapter, :info, [state.backend, state.session]),
        else: nil

    {:operation, result, info}
  end

  defp retain_recovery(state, foreground) do
    recovery =
      foreground
      |> Map.put(:task, nil)
      |> Map.put(:from, nil)
      |> Map.put(:retry_timer, nil)

    state
    |> then(
      &%{semantic(%{&1 | foreground: nil, recovery: recovery}) | lifecycle: :backend_failed}
    )
    |> schedule_recovery()
    |> finish_shutdown({:error, :adapter_failure})
  end

  defp schedule_recovery(%{recovery: %{retry_timer: nil} = recovery} = state) do
    timer =
      Process.send_after(self(), {:recovery_retry, recovery.operation_id}, @recovery_retry_ms)

    %{state | recovery: %{recovery | retry_timer: timer}}
  end

  defp schedule_recovery(state), do: state

  defp preserve_recovery_failure_state(state, %{recovered?: true, kind: :evaluation}),
    do: %{semantic(state) | lifecycle: :backend_failed}

  defp preserve_recovery_failure_state(state, _foreground), do: state

  defp terminate_task(%{task: task, timer: timer}) do
    cancel_timer(timer)
    Task.shutdown(task, :brutal_kill)
  end

  defp observe_task_down(%{task: %{pid: pid, ref: ref}, timer: timer}) do
    cancel_timer(timer)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
    end
  end

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: false

  defp safe_apply(adapter, function, arguments) do
    case apply(adapter, function, arguments) do
      :ok -> :ok
      {:ok, _value} = success -> success
      {:ok, _session, _info} = success -> success
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :adapter_failure}
    end
  rescue
    _exception -> {:error, :adapter_failure}
  catch
    _kind, _reason -> {:error, :adapter_failure}
  end

  defp normalize_operation_result(:evaluation, {:ok, result}) when is_map(result) do
    allowed = [
      :evaluation_id,
      :status,
      :outcome,
      :continuation_effect,
      :duration_ms,
      :usage,
      :value,
      :value_available?,
      :formatted,
      :formatted_truncated?,
      :prints,
      :prints_truncated?,
      :error
    ]

    projected = Map.take(result, allowed)

    with id when is_binary(id) and byte_size(id) <= 512 <- Map.get(projected, :evaluation_id),
         true <- String.valid?(id),
         status when status in [:ok, :error] <- Map.get(projected, :status),
         outcome
         when outcome in [
                :continued,
                :returned,
                :failed,
                :evaluation_error,
                :memory_exceeded,
                :history_exceeded,
                :result_exceeded,
                :limit_exceeded
              ] <-
           Map.get(projected, :outcome),
         effect when effect in [:committed_with_history, :committed_without_history, :preserved] <-
           Map.get(projected, :continuation_effect),
         duration when is_integer(duration) and duration in 0..1_800_000 <-
           Map.get(projected, :duration_ms),
         usage when is_map(usage) <- Map.get(projected, :usage),
         prints when is_list(prints) <- Map.get(projected, :prints),
         true <- Enum.all?(prints, &is_binary/1),
         true <- is_boolean(Map.get(projected, :value_available?)),
         true <- is_boolean(Map.get(projected, :formatted_truncated?)),
         true <- is_boolean(Map.get(projected, :prints_truncated?)),
         true <-
           is_nil(Map.get(projected, :formatted)) or is_binary(Map.get(projected, :formatted)),
         true <- is_nil(Map.get(projected, :error)) or is_map(Map.get(projected, :error)),
         {:ok, encoded} <- Jason.encode(projected),
         true <- byte_size(encoded) <= 1_000_000 do
      {:ok, projected}
    else
      _invalid -> {:error, :adapter_failure}
    end
  end

  defp normalize_operation_result(:evaluation, {:error, reason}) when is_atom(reason),
    do: {:error, reason}

  defp normalize_operation_result(:evaluation, _invalid), do: {:error, :adapter_failure}
  defp normalize_operation_result(_kind, result), do: result

  defp reply(nil, _reply), do: :ok
  defp reply(from, reply), do: GenServer.reply(from, reply)

  defp semantic(state), do: Map.update!(state, :state_revision, &(&1 + 1))
  defp encoded_size(value), do: value |> Jason.encode!() |> byte_size()

  defp clip_utf8(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp clip_utf8(value, max_bytes) do
    value
    |> binary_part(0, max_bytes)
    |> trim_invalid_suffix()
  end

  defp trim_invalid_suffix(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(0, byte_size(value) - 1) |> trim_invalid_suffix()
  end

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp authorize_nonce(actual, expected)
       when is_binary(actual) and byte_size(actual) == byte_size(expected) do
    if Plug.Crypto.secure_compare(actual, expected),
      do: :ok,
      else: {:error, :forbidden_request}
  end

  defp authorize_nonce(_actual, _expected), do: {:error, :forbidden_request}

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp call(store, request) do
    GenServer.call(store, request, :infinity)
  catch
    :exit, _reason -> {:error, :adapter_failure}
  end
end
