defmodule PtcRunner.Kernel.ExecutionSessionOwner do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderExecutionResources
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder

  @enforce_keys [:pid, :token]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @doc false
  @spec start(PreparedRun.t(), PublicationAuthority.t(), pid()) ::
          {:ok, t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :provider_session_required}
  def start(prepared, authority, caller),
    do: start(prepared, authority, caller, nil, nil, :run)

  @doc false
  @spec start(
          PreparedRun.t(),
          PublicationAuthority.t(),
          pid(),
          ProviderExecution.t() | nil,
          (binary() -> term()) | nil,
          :run | :connect
        ) ::
          {:ok, t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :provider_session_required
             | :invalid_provider_execution}
  def start(prepared, authority, caller, provider_execution, notifier, operation \\ :run)

  def start(prepared, authority, caller, provider_execution, notifier, operation)
      when is_pid(caller) and operation in [:run, :connect] do
    with :ok <- admissible(prepared, authority, provider_execution, notifier, operation),
         {:ok, lease} <- PublicationAuthority.claim(authority) do
      token = make_ref()

      case GenServer.start(
             __MODULE__,
             {prepared, authority, caller, token, lease, provider_execution, notifier, operation}
           ) do
        {:ok, pid} ->
          {:ok, %__MODULE__{pid: pid, token: token}}

        {:error, _reason} ->
          _ = PublicationAuthority.abort(authority)
          {:error, :invalid_prepared_run}
      end
    end
  end

  def start(_prepared, _authority, _caller, _provider_execution, _notifier, _operation),
    do: {:error, :invalid_prepared_run}

  # Every refusal here is decided before `init/1` consumes the prepared run, so
  # a rejected start leaves that preparation reusable.
  defp admissible(prepared, authority, provider_execution, notifier, operation) do
    cond do
      not PreparedRun.valid?(prepared) ->
        {:error, :invalid_prepared_run}

      not PublicationAuthority.authorized?(authority) ->
        {:error, :invalid_publication_authority}

      not PublicationAuthority.matches_prepared?(authority, prepared) ->
        {:error, :invalid_publication_authority}

      prepared.provider_declarations == [] ->
        provider_free_admissible(provider_execution, operation)

      not (ProviderExecution.valid?(provider_execution) and
               notifier_matches_operation?(notifier, operation)) ->
        {:error, :provider_session_required}

      not ProviderExecution.bound_to_prepared?(provider_execution, prepared) ->
        {:error, :invalid_provider_execution}

      # Decided here, before `init/1` consumes the preparation, so a connect
      # that asked for authorization leaves its preparation reusable rather
      # than being spent on a connectivity check that would have skipped it.
      operation == :connect and not ProviderExecution.non_interactive?(provider_execution) ->
        {:error, :invalid_provider_execution}

      true ->
        :ok
    end
  end

  # Connectivity never notifies or opens an interaction, so it carries no
  # authorization notifier at all.
  defp notifier_matches_operation?(notifier, :connect), do: is_nil(notifier)

  defp notifier_matches_operation?(notifier, _operation),
    do: is_nil(notifier) or is_function(notifier, 1)

  # Connectivity answers for selected occurrences, so it has nothing to do
  # without any. Refusing keeps `:connect` off the provider-free completion,
  # which builds the run config connectivity never wants.
  defp provider_free_admissible(_provider_execution, :connect),
    do: {:error, :provider_session_required}

  defp provider_free_admissible(nil, _operation), do: :ok

  defp provider_free_admissible(_provider_execution, _operation),
    do: {:error, :invalid_provider_execution}

  # Each operation completes with its own evidence: a run with a sealed
  # execution outcome and connectivity with the sealed per-occurrence result.
  @doc false
  @spec await(t()) ::
          {:ok, PtcRunner.Kernel.ExecutionOutcome.t() | ConnectivityResult.t()}
          | {:error, term()}
  def await(%__MODULE__{pid: pid, token: token}) do
    result = GenServer.call(pid, {token, :await}, :infinity)
    send(pid, {token, :handoff_ack})
    result
  catch
    :exit, _reason -> {:error, :execution_session_unavailable}
  end

  @doc false
  @spec pid(t()) :: pid()
  def pid(%__MODULE__{pid: pid}), do: pid

  @impl GenServer
  def init({prepared, authority, caller, token, lease, provider_execution, notifier, operation}) do
    caller_ref = Process.monitor(caller)

    initial = %{
      token: token,
      caller: caller,
      caller_ref: caller_ref,
      authority: authority,
      lease: lease,
      prepared: prepared,
      registry: nil,
      provider_session: nil,
      oauth_memory: nil,
      oauth_listener: nil,
      built: nil,
      cleanup: :ok,
      opened_sinks: nil,
      worker_pid: nil,
      worker_ref: nil,
      waiter: nil,
      result: nil,
      authority_handed_off?: false,
      handoff_waiting?: false
    }

    case RunBuilder.open_prepared_sinks(prepared, authority, self()) do
      {:ok, opened_sinks} ->
        if prepared.provider_declarations == [] do
          open_provider_free(initial, authority, opened_sinks, operation)
        else
          open_provider_execution(
            initial,
            authority,
            opened_sinks,
            provider_execution,
            notifier,
            operation
          )
        end

      {:error, reason, opened_sinks} ->
        next =
          initial
          |> Map.put(:opened_sinks, opened_sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, reason})

        {:ok, next}

      {:error, reason} ->
        close_prepared(prepared)
        _ = PublicationAuthority.abort(authority)
        {:ok, %{initial | prepared: nil, result: {:error, reason}}}
    end
  end

  @impl GenServer
  def handle_call(
        {token, :await},
        {caller, _tag} = from,
        %{token: token, caller: caller, result: nil, waiter: nil} = state
      ),
      do: {:noreply, %{state | waiter: from}}

  def handle_call(
        {token, :await},
        {caller, _tag},
        %{token: token, caller: caller, result: result} = state
      )
      when not is_nil(result),
      do: finish_result(state, result)

  def handle_call(
        {token, {:resource, action, kind, resource}},
        {worker_pid, _tag},
        %{token: token, worker_pid: worker_pid} = state
      )
      when action in [:put, :drop] and kind in [:session, :registry, :memory, :listener] do
    case ProviderExecutionResources.update(
           state,
           action,
           kind,
           resource,
           self(),
           :execution_session_unavailable
         ) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({_token, :await}, _from, state),
    do: {:reply, {:error, :execution_session_unavailable}, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :execution_session_unavailable}, state}

  @impl GenServer
  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(
        {token, :execution_result, worker_pid, result},
        %{token: token, worker_pid: worker_pid} = state
      ) do
    Process.demonitor(state.worker_ref, [:flush])

    next =
      state
      |> Map.put(:worker_pid, nil)
      |> Map.put(:worker_ref, nil)
      |> maybe_finalize_failed_execution(result)
      |> close_owned_inputs()
      |> maybe_abort_authority(result)
      |> put_result(result)

    finish_or_wait(next)
  end

  def handle_info(
        {:DOWN, ref, :process, caller, _reason},
        %{caller_ref: ref, caller: caller} = state
      ) do
    {:stop, :normal, abort(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, worker_pid, _reason},
        %{worker_ref: ref, worker_pid: worker_pid} = state
      ) do
    next =
      state
      |> Map.put(:worker_pid, nil)
      |> Map.put(:worker_ref, nil)
      |> abort()
      |> put_result({:error, :execution_session_unavailable})

    finish_or_wait(next)
  end

  def handle_info(
        {token, :handoff_ack},
        %{token: token, handoff_waiting?: true} = state
      ) do
    {:stop, :normal, %{state | authority_handed_off?: true, handoff_waiting?: false}}
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
    _state = abort(state)
    :ok
  end

  defp open_provider_free(initial, authority, opened_sinks, operation) do
    prepared = initial.prepared

    result =
      with {:ok, registry} <-
             ProviderRegistry.new(%{},
               installed_limits: prepared.request.package.installed_limits
             ) do
        case RunBuilder.build_prepared_owned(prepared, registry, authority, opened_sinks) do
          {:ok, built} -> {:ok, registry, Map.put(built, :publication_lease, initial.lease)}
          {:error, reason} -> {:error, reason, registry}
        end
      end

    case result do
      {:ok, registry, built} ->
        owner = self()
        token = initial.token

        {worker_pid, worker_ref} =
          spawn_monitor(fn ->
            execution_result = complete_operation(built, operation)
            send(owner, {token, :execution_result, self(), execution_result})
          end)

        {:ok,
         %{
           initial
           | registry: registry,
             built: built,
             opened_sinks: opened_sinks,
             worker_pid: worker_pid,
             worker_ref: worker_ref
         }}

      {:error, reason, registry} ->
        next =
          initial
          |> Map.put(:registry, registry)
          |> Map.put(:opened_sinks, opened_sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, reason})

        {:ok, next}

      {:error, reason} ->
        next =
          initial
          |> Map.put(:opened_sinks, opened_sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, reason})

        {:ok, next}
    end
  end

  defp open_provider_execution(
         initial,
         authority,
         opened_sinks,
         provider_execution,
         notifier,
         operation
       ) do
    owner = self()
    token = initial.token

    {worker_pid, worker_ref} =
      spawn_monitor(fn ->
        receive do
          {^token, :start_execution} ->
            tracker = fn action, kind, resource ->
              GenServer.call(
                owner,
                {token, {:resource, action, kind, resource}},
                :infinity
              )
            end

            execution_result =
              ProviderExecution.execute(
                initial.prepared,
                {authority, initial.lease},
                opened_sinks,
                provider_execution,
                notifier,
                tracker,
                owner,
                operation
              )

            send(owner, {token, :execution_result, self(), execution_result})
        end
      end)

    case PreparedRun.authorize_executor(initial.prepared, worker_pid) do
      :ok ->
        send(worker_pid, {token, :start_execution})

        {:ok,
         %{
           initial
           | opened_sinks: opened_sinks,
             worker_pid: worker_pid,
             worker_ref: worker_ref
         }}

      {:error, _reason} ->
        Process.exit(worker_pid, :kill)

        receive do
          {:DOWN, ^worker_ref, :process, ^worker_pid, _reason} -> :ok
        end

        next =
          initial
          |> Map.put(:opened_sinks, opened_sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, :invalid_prepared_run})

        {:ok, next}
    end
  end

  defp complete_operation(%{publication_lease: lease} = built, :run),
    do: RunBuilder.execute_built_claimed(built, lease)

  defp finish_or_wait(%{waiter: nil} = state), do: {:noreply, state}

  defp finish_or_wait(%{waiter: waiter, result: result} = state) do
    GenServer.reply(waiter, result)
    {:noreply, %{state | waiter: nil, handoff_waiting?: true}}
  end

  defp finish_result(state, result) do
    {:reply, result, %{state | handoff_waiting?: true}}
  end

  defp abort(state) do
    state
    |> stop_worker()
    |> close_runtime_resources()
    |> finalize_aborted_sinks()
    |> close_owned_inputs()
    |> abort_authority()
  end

  defp stop_worker(%{worker_pid: nil} = state), do: state

  defp stop_worker(%{worker_pid: worker_pid, worker_ref: worker_ref} = state) do
    Process.exit(worker_pid, :kill)

    receive do
      {:DOWN, ^worker_ref, :process, ^worker_pid, _reason} -> :ok
    end

    %{state | worker_pid: nil, worker_ref: nil}
  end

  defp finalize_aborted_sinks(%{built: %{config: config}} = state) do
    finalize_and_stop_sinks(config.event_sink, config.inspection_sink)
    state
  end

  defp finalize_aborted_sinks(%{opened_sinks: opened_sinks} = state)
       when is_map(opened_sinks) do
    finalize_and_stop_sinks(opened_sinks.event_sink, opened_sinks.inspection_sink)
    %{state | opened_sinks: nil}
  end

  defp finalize_aborted_sinks(state), do: state

  defp finalize_and_stop_sinks(event_sink, inspection_sink) do
    if Process.alive?(event_sink.pid) do
      _result =
        EventSink.finalize_and_events(event_sink, %{
          outcome: :error,
          reason: :session_owner_failed,
          usage: %{}
        })
    end

    if inspection_sink, do: InspectionSink.stop(inspection_sink)
    EventSink.stop(event_sink)
  end

  defp close_owned_inputs(state) do
    state = close_runtime_resources(state)
    close_prepared(state.prepared)
    %{state | prepared: nil}
  end

  defp maybe_abort_authority(state, {:ok, _result}), do: state
  defp maybe_abort_authority(state, _result), do: abort_authority(state)

  defp abort_authority(%{authority_handed_off?: true, result: {:ok, _result}} = state),
    do: state

  defp abort_authority(%{authority: authority} = state) do
    _ = PublicationAuthority.abort(authority)
    state
  end

  # The session closes first because its committed closers belong to the
  # runtime that acquired them: one may still release an admission, persist a
  # token response, or reach the authority the registry holds. Only once that
  # cleanup has settled do the resources it depended on unwind, in the reverse
  # of the order the worker opened them: listener, registry, then the OAuth
  # store. Closing the registry before its backing store keeps terminal OAuth
  # persistence available for that last step.
  defp close_runtime_resources(state) do
    cleanup =
      if state.provider_session && ProviderSession.alive?(state.provider_session),
        do: ProviderSession.close(state.provider_session),
        else: :ok

    if state.oauth_listener, do: LoopbackListener.close(state.oauth_listener)
    close_registry(state.registry)
    if state.oauth_memory, do: Memory.close(state.oauth_memory)

    %{
      state
      | provider_session: nil,
        registry: nil,
        oauth_memory: nil,
        oauth_listener: nil,
        cleanup: merge_cleanup(state.cleanup, cleanup)
    }
  end

  # A run whose provider session could not be closed is not a clean run, so the
  # cleanup failure outranks whatever the worker reported. A run that reaches
  # normal Runner teardown closes the session there, so this covers the paths
  # that never get that far and leave the session owner-held.
  defp merge_cleanup({:error, _reason} = existing, _cleanup), do: existing
  defp merge_cleanup(_existing, cleanup), do: cleanup

  defp put_result(%{cleanup: {:error, _reason}} = state, _result),
    do: %{state | result: {:error, cleanup_diagnostic()}}

  defp put_result(state, result), do: %{state | result: result}

  defp cleanup_diagnostic,
    do: CommandDiagnostic.new!(:result_cleanup, :provider_cleanup_failed, provider_activity: true)

  defp maybe_finalize_failed_execution(state, {:ok, _outcome}),
    do: %{state | opened_sinks: nil}

  defp maybe_finalize_failed_execution(state, {:error, _reason}),
    do: finalize_aborted_sinks(state)

  defp close_registry(nil), do: :ok

  defp close_registry(registry) do
    ProviderRegistry.close(registry)
  catch
    :exit, _reason -> :ok
  end

  defp close_prepared(nil), do: :ok

  defp close_prepared(prepared) do
    PreparedRun.close(prepared)
  catch
    :exit, _reason -> :ok
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:authority, :state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
