defmodule PtcRunner.Kernel.ExecutionSessionOwner do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderExecution
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
          :run | :check
        ) ::
          {:ok, t()}
          | {:error,
             :invalid_prepared_run
             | :invalid_publication_authority
             | :provider_session_required
             | :invalid_provider_execution}
  def start(prepared, authority, caller, provider_execution, notifier, operation \\ :run)

  def start(prepared, authority, caller, provider_execution, notifier, operation)
      when is_pid(caller) and operation in [:run, :check] do
    cond do
      not PreparedRun.valid?(prepared) ->
        {:error, :invalid_prepared_run}

      not PublicationAuthority.valid?(authority) ->
        {:error, :invalid_publication_authority}

      prepared.provider_declarations != [] and
          not (ProviderExecution.valid?(provider_execution) and is_function(notifier, 1)) ->
        {:error, :provider_session_required}

      prepared.provider_declarations == [] and not is_nil(provider_execution) ->
        {:error, :invalid_provider_execution}

      # Decided before `init/1` consumes the prepared run, so an execution from
      # another catalog leaves that preparation reusable.
      prepared.provider_declarations != [] and
          not ProviderExecution.bound_to_prepared?(provider_execution, prepared) ->
        {:error, :invalid_provider_execution}

      true ->
        token = make_ref()

        case GenServer.start(
               __MODULE__,
               {prepared, authority, caller, token, provider_execution, notifier, operation}
             ) do
          {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
          {:error, _reason} -> {:error, :invalid_prepared_run}
        end
    end
  end

  def start(_prepared, _authority, _caller, _provider_execution, _notifier, _operation),
    do: {:error, :invalid_prepared_run}

  # A check completes with the acquisition's safe connector snapshots where a
  # run completes with a sealed execution outcome.
  @doc false
  @spec await(t()) ::
          {:ok, PtcRunner.Kernel.ExecutionOutcome.t() | [map()]} | {:error, term()}
  def await(%__MODULE__{pid: pid, token: token}) do
    GenServer.call(pid, {token, :await}, :infinity)
  catch
    :exit, _reason -> {:error, :execution_session_unavailable}
  end

  @doc false
  @spec pid(t()) :: pid()
  def pid(%__MODULE__{pid: pid}), do: pid

  @impl GenServer
  def init({prepared, authority, caller, token, provider_execution, notifier, operation}) do
    caller_ref = Process.monitor(caller)

    initial = %{
      token: token,
      caller: caller,
      caller_ref: caller_ref,
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
      result: nil
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
          |> put_result({:error, reason})

        {:ok, next}

      {:error, reason} ->
        close_prepared(prepared)
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
      do: {:stop, :normal, result, state}

  def handle_call(
        {token, {:resource, action, kind, resource}},
        {worker_pid, _tag},
        %{token: token, worker_pid: worker_pid} = state
      )
      when action in [:put, :drop] and kind in [:session, :registry, :memory, :listener] do
    case update_resource(state, action, kind, resource) do
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
          {:ok, built} -> {:ok, registry, built}
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
          |> put_result({:error, reason})

        {:ok, next}

      {:error, reason} ->
        next =
          initial
          |> Map.put(:opened_sinks, opened_sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
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
                authority,
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
          |> put_result({:error, :invalid_prepared_run})

        {:ok, next}
    end
  end

  defp complete_operation(built, :run), do: RunBuilder.execute_built(built)
  defp complete_operation(built, :check), do: RunBuilder.check_built(built)

  defp finish_or_wait(%{waiter: nil} = state), do: {:noreply, state}

  defp finish_or_wait(%{waiter: waiter, result: result} = state) do
    GenServer.reply(waiter, result)
    {:stop, :normal, state}
  end

  defp abort(state) do
    state
    |> stop_worker()
    |> close_runtime_resources()
    |> finalize_aborted_sinks()
    |> close_owned_inputs()
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

  defp update_resource(state, :put, kind, resource) do
    field = resource_field(kind)

    if is_nil(Map.fetch!(state, field)) and valid_resource?(kind, resource) do
      {:ok, Map.put(state, field, resource)}
    else
      {:error, :execution_session_unavailable}
    end
  end

  defp update_resource(state, :drop, kind, resource) do
    field = resource_field(kind)

    if Map.fetch!(state, field) === resource do
      {:ok, Map.put(state, field, nil)}
    else
      {:error, :execution_session_unavailable}
    end
  end

  defp resource_field(:session), do: :provider_session
  defp resource_field(:registry), do: :registry
  defp resource_field(:memory), do: :oauth_memory
  defp resource_field(:listener), do: :oauth_listener

  defp valid_resource?(:session, session),
    do: ProviderSession.valid?(session) and ProviderSession.lifecycle_owner(session) == self()

  defp valid_resource?(:registry, registry), do: ProviderRegistry.valid?(registry)
  defp valid_resource?(:memory, %Memory{pid: pid}), do: is_pid(pid) and Process.alive?(pid)
  defp valid_resource?(:listener, %LoopbackListener{}), do: true
  defp valid_resource?(_kind, _resource), do: false

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
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
