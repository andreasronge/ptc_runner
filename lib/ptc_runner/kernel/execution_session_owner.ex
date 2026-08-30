defmodule PtcRunner.Kernel.ExecutionSessionOwner do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ConnectivityResult
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionSessionResources
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.LLMBudget
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderExecutionResources
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.LiveStatus
  alias PtcRunner.LiveStatus.Target

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
    do: start(prepared, authority, caller, nil, nil, :run, nil)

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
  def start(prepared, authority, caller, provider_execution, notifier, operation \\ :run),
    do: start(prepared, authority, caller, provider_execution, notifier, operation, nil)

  @doc false
  @spec start(
          PreparedRun.t(),
          PublicationAuthority.t(),
          pid(),
          ProviderExecution.t() | nil,
          (binary() -> term()) | nil,
          :run | :connect,
          Target.t() | nil
        ) ::
          {:ok, t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :provider_session_required
             | :invalid_provider_execution}
  def start(prepared, authority, caller, provider_execution, notifier, operation, live_status)
      when is_pid(caller) and operation in [:run, :connect] do
    with :ok <-
           admissible(
             prepared,
             authority,
             provider_execution,
             notifier,
             operation,
             live_status
           ),
         {:ok, lease} <- PublicationAuthority.claim(authority) do
      token = make_ref()

      case GenServer.start(
             __MODULE__,
             {prepared, authority, caller, token, lease, provider_execution, notifier, operation,
              live_status}
           ) do
        {:ok, pid} ->
          {:ok, %__MODULE__{pid: pid, token: token}}

        {:error, _reason} ->
          _ = PublicationAuthority.abort(authority)
          {:error, :invalid_prepared_run}
      end
    end
  end

  def start(
        _prepared,
        _authority,
        _caller,
        _provider_execution,
        _notifier,
        _operation,
        _live_status
      ),
      do: {:error, :invalid_prepared_run}

  # Every refusal here is decided before `init/1` consumes the prepared run, so
  # a rejected start leaves that preparation reusable.
  defp admissible(prepared, authority, provider_execution, notifier, operation, live_status) do
    cond do
      not live_status?(live_status) ->
        {:error, :invalid_prepared_run}

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

  defp live_status?(nil), do: true
  defp live_status?(%Target{} = target), do: Target.valid?(target)
  defp live_status?(_target), do: false

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
  def init(
        {prepared, authority, caller, token, lease, provider_execution, notifier, operation,
         live_status}
      ) do
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
      handoff_waiting?: false,
      live_status: live_status,
      held_resources: ExecutionSessionResources.new([:prepared, :authority])
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
        failure = execution_failure(initial, reason, :not_started)

        next =
          initial
          |> Map.put(:opened_sinks, opened_sinks)
          |> hold_resource(:sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, failure})

        {:ok, next}

      {:error, reason} ->
        failure = execution_failure(initial, reason, :not_started)

        next =
          initial
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, failure})

        {:ok, next}
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
      {:ok, next} -> {:reply, :ok, track_provider_resource(next, action, kind)}
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
    result = seal_execution_result(state, result)

    next =
      state
      |> Map.put(:worker_pid, nil)
      |> Map.put(:worker_ref, nil)
      |> forget_resource(:worker)
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
    failure = execution_failure(state, :execution_session_unavailable, :incomplete)

    next =
      state
      |> Map.put(:worker_pid, nil)
      |> Map.put(:worker_ref, nil)
      |> forget_resource(:worker)
      |> abort()
      |> put_result({:error, failure})

    finish_or_wait(next)
  end

  def handle_info(
        {token, :handoff_ack},
        %{token: token, handoff_waiting?: true} = state
      ) do
    {:stop, :normal,
     state
     |> Map.put(:handoff_waiting?, false)
     |> forget_resource(:authority)}
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
            execution_result =
              LiveStatus.with_target(initial.live_status, fn ->
                complete_operation(built, operation)
              end)

            send(owner, {token, :execution_result, self(), execution_result})
          end)

        next =
          %{
            initial
            | registry: registry,
              built: built,
              opened_sinks: opened_sinks,
              worker_pid: worker_pid,
              worker_ref: worker_ref
          }
          |> hold_resources([:registry, :sinks, :worker])

        {:ok, next}

      {:error, reason, registry} ->
        failure = provider_free_failure(initial, reason)

        next =
          initial
          |> Map.put(:registry, registry)
          |> Map.put(:opened_sinks, opened_sinks)
          |> hold_resources([:registry, :sinks])
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, failure})

        {:ok, next}

      {:error, reason} ->
        failure = provider_free_failure(initial, reason)

        next =
          initial
          |> Map.put(:opened_sinks, opened_sinks)
          |> hold_resource(:sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, failure})

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
              LiveStatus.with_target(initial.live_status, fn ->
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
              end)

            send(owner, {token, :execution_result, self(), execution_result})
        end
      end)

    case PreparedRun.authorize_executor(initial.prepared, worker_pid) do
      :ok ->
        send(worker_pid, {token, :start_execution})

        next =
          %{
            initial
            | opened_sinks: opened_sinks,
              worker_pid: worker_pid,
              worker_ref: worker_ref
          }
          |> hold_resources([:sinks, :worker])

        {:ok, next}

      {:error, _reason} ->
        Process.exit(worker_pid, :kill)

        receive do
          {:DOWN, ^worker_ref, :process, ^worker_pid, _reason} -> :ok
        end

        failure = execution_failure(initial, :invalid_prepared_run, :not_started)

        next =
          initial
          |> Map.put(:opened_sinks, opened_sinks)
          |> hold_resource(:sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> abort_authority()
          |> put_result({:error, failure})

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

  defp abort(state),
    do:
      release(state, [
        :worker,
        :session,
        :listener,
        :registry,
        :memory,
        :sinks,
        :prepared,
        :authority
      ])

  defp release_worker(%{worker_pid: worker_pid, worker_ref: worker_ref} = state) do
    Process.exit(worker_pid, :kill)

    receive do
      {:DOWN, ^worker_ref, :process, ^worker_pid, _reason} -> :ok
    end

    %{state | worker_pid: nil, worker_ref: nil}
  end

  defp release_sinks(%{built: %{config: config}} = state) do
    finalize_and_stop_sinks(config.event_sink, config.inspection_sink, config.limits)
    %{state | opened_sinks: nil}
  end

  defp release_sinks(%{opened_sinks: opened_sinks} = state) do
    limits = state.prepared.request.package.limits
    finalize_and_stop_sinks(opened_sinks.event_sink, opened_sinks.inspection_sink, limits)
    %{state | opened_sinks: nil}
  end

  defp finalize_and_stop_sinks(event_sink, inspection_sink, limits) do
    if Process.alive?(event_sink.pid) do
      _result =
        EventSink.finalize_and_events(event_sink, %{
          outcome: :error,
          reason: :session_owner_failed,
          usage: %{llm_budget: LLMBudget.unavailable_terminal_projection(limits)}
        })
    end

    if inspection_sink, do: InspectionSink.stop(inspection_sink)
    EventSink.stop(event_sink)
  end

  defp finalize_aborted_sinks(state), do: release(state, [:sinks])

  defp close_owned_inputs(state),
    do: release(state, [:session, :listener, :registry, :memory, :prepared])

  defp maybe_abort_authority(state, {:ok, _result}), do: state
  defp maybe_abort_authority(state, _result), do: abort_authority(state)

  defp release_authority(%{authority: authority} = state) do
    _ = PublicationAuthority.abort(authority)
    %{state | authority: nil}
  end

  # A committed session closer may still use the listener, registry, OAuth
  # store, or publication authority. The registry likewise needs its backing
  # store alive while terminal OAuth persistence settles.
  defp release_provider_session(state) do
    cleanup =
      if ProviderSession.alive?(state.provider_session),
        do: ProviderSession.close(state.provider_session),
        else: :ok

    %{state | provider_session: nil, cleanup: merge_cleanup(state.cleanup, cleanup)}
  end

  defp release_listener(state) do
    LoopbackListener.close(state.oauth_listener)
    %{state | oauth_listener: nil}
  end

  defp release_registry(state) do
    close_registry(state.registry)
    %{state | registry: nil}
  end

  defp release_memory(state) do
    Memory.close(state.oauth_memory)
    %{state | oauth_memory: nil}
  end

  defp release_prepared(state) do
    close_prepared(state.prepared)
    %{state | prepared: nil}
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

  defp seal_execution_result(_state, {:ok, _result} = result), do: result

  defp seal_execution_result(_state, {:error, %CommandDiagnostic{}} = result), do: result

  defp seal_execution_result(state, {:error, reason}),
    do: {:error, execution_failure(state, reason, :incomplete)}

  defp execution_failure(state, reason, execution_state),
    do: OwnerFailure.new!(reason, provider_activity(state), execution_state)

  defp provider_free_failure(state, reason) do
    case RunBuilder.environment_failure_diagnostic(reason, state.prepared, false) do
      {:ok, diagnostic} -> diagnostic
      :error -> execution_failure(state, reason, :not_started)
    end
  end

  defp provider_activity(%{prepared: %{provider_activity: activity}}) do
    case ProviderActivity.value(activity) do
      value when is_boolean(value) -> value
      _unknown -> false
    end
  end

  defp provider_activity(_state), do: false

  defp maybe_finalize_failed_execution(state, {:ok, _outcome}),
    do:
      state
      |> Map.put(:opened_sinks, nil)
      |> forget_resource(:sinks)

  defp maybe_finalize_failed_execution(state, {:error, _reason}),
    do: finalize_aborted_sinks(state)

  defp abort_authority(state), do: release(state, [:authority])

  defp release(state, resources) do
    {held_resources, released} =
      ExecutionSessionResources.release(state.held_resources, resources)

    state = %{state | held_resources: held_resources}
    Enum.reduce(released, state, &release_held_resource(&2, &1))
  end

  defp release_held_resource(state, :worker), do: release_worker(state)
  defp release_held_resource(state, :session), do: release_provider_session(state)
  defp release_held_resource(state, :listener), do: release_listener(state)
  defp release_held_resource(state, :registry), do: release_registry(state)
  defp release_held_resource(state, :memory), do: release_memory(state)
  defp release_held_resource(state, :sinks), do: release_sinks(state)
  defp release_held_resource(state, :prepared), do: release_prepared(state)
  defp release_held_resource(state, :authority), do: release_authority(state)

  defp hold_resources(state, resources),
    do: Map.update!(state, :held_resources, &ExecutionSessionResources.hold(&1, resources))

  defp hold_resource(state, resource),
    do: Map.update!(state, :held_resources, &ExecutionSessionResources.hold(&1, resource))

  defp forget_resource(state, resource),
    do: Map.update!(state, :held_resources, &ExecutionSessionResources.forget(&1, resource))

  defp track_provider_resource(state, :put, kind), do: hold_resource(state, kind)
  defp track_provider_resource(state, :drop, kind), do: forget_resource(state, kind)

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
