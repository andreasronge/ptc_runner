defmodule PtcRunner.Kernel.ManifestReplOpening do
  @moduledoc false

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.ManifestReplPreparation
  alias PtcRunner.Kernel.MCPOAuth.LoopbackListener
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderExecutionResources
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.ReplTerminalization
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.RunState

  @enforce_keys [:pid, :token]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @doc false
  @spec start(ManifestReplPreparation.t(), PublicationAuthority.t(), binary() | nil, pid()) ::
          {:ok, t()} | {:error, term()}
  def start(preparation, authority, trace_path, caller) when is_pid(caller) do
    if ManifestReplPreparation.valid?(preparation) and
         PublicationAuthority.authorized?(authority) and
         PublicationAuthority.matches_prepared?(authority, preparation.prepared_run) and
         (is_nil(trace_path) or is_binary(trace_path)) do
      token = make_ref()

      case GenServer.start(__MODULE__, {token, caller, preparation, authority, trace_path}) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_manifest_repl}
    end
  end

  def start(_preparation, _authority, _trace_path, _caller),
    do: {:error, :invalid_manifest_repl}

  @doc false
  @spec await(t()) :: {:ok, pid(), reference()} | {:error, term()}
  def await(%__MODULE__{pid: pid, token: token}) do
    GenServer.call(pid, {token, :await}, :infinity)
  catch
    :exit, _reason -> {:error, :manifest_repl_unavailable}
  end

  @doc false
  @spec close_provider_session(t()) :: :ok | {:error, :provider_cleanup_failed}
  def close_provider_session(%__MODULE__{pid: pid, token: token}) do
    GenServer.call(pid, {token, :close_provider_session}, :infinity)
  catch
    :exit, _reason -> {:error, :provider_cleanup_failed}
  end

  @doc false
  @spec release(t()) :: :ok
  def release(%__MODULE__{pid: pid, token: token}) do
    GenServer.call(pid, {token, :release}, :infinity)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{pid: pid, token: token}),
    do: is_pid(pid) and is_reference(token) and Process.alive?(pid)

  def valid?(_opening), do: false

  @doc false
  @spec pid(t()) :: pid()
  def pid(%__MODULE__{pid: pid}), do: pid

  @impl GenServer
  def init({token, caller, preparation, authority, trace_path}) do
    state = %{
      token: token,
      caller: caller,
      caller_ref: Process.monitor(caller),
      preparation: preparation,
      authority: authority,
      trace_path: trace_path,
      opened_sinks: nil,
      repl_pid: nil,
      repl_token: nil,
      repl_ref: nil,
      worker_pid: nil,
      worker_ref: nil,
      registry: nil,
      provider_session: nil,
      oauth_memory: nil,
      oauth_listener: nil,
      provider_cleanup: nil,
      result: nil,
      waiter: nil,
      adopted?: false
    }

    case ReplSessionOwner.start_pending(caller) do
      {:ok, repl_pid, repl_token} ->
        state = %{state | repl_pid: repl_pid, repl_token: repl_token}

        case RunBuilder.open_prepared_sinks(preparation.prepared_run, authority, self()) do
          {:ok, opened_sinks} ->
            state = %{state | opened_sinks: opened_sinks}

            if preparation.prepared_run.provider_declarations == [],
              do: open_provider_free(state),
              else: open_provider_backed(state)

          {:error, reason, opened_sinks} ->
            {:ok, %{state | opened_sinks: opened_sinks, result: {:error, reason}}}

          {:error, reason} ->
            {:ok, %{state | result: {:error, reason}}}
        end

      {:error, reason} ->
        {:ok, %{state | result: {:error, reason}}}
    end
  end

  @impl GenServer
  # ex_dna:disable-for-next-line — each owner authenticates its own token and caller in the OTP callback head.
  def handle_call(
        {token, :await},
        {caller, _tag} = from,
        %{token: token, caller: caller, result: nil, waiter: nil} = state
      ),
      do: {:noreply, %{state | waiter: from}}

  # ex_dna:disable-for-next-line — worker authorization stays in each owner's OTP callback boundary.
  def handle_call(
        {token, :await},
        {caller, _tag},
        %{token: token, caller: caller, result: {:ok, repl_pid, repl_token}} = state
      ),
      do: {:reply, {:ok, repl_pid, repl_token}, state}

  def handle_call(
        {token, :await},
        {caller, _tag},
        %{token: token, caller: caller, result: {:error, _reason} = error} = state
      ),
      do: {:stop, :normal, error, state}

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
           :manifest_repl_unavailable
         ) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {token, :close_provider_session},
        {repl_pid, _tag},
        %{token: token, repl_pid: repl_pid, adopted?: true} = state
      ) do
    {result, next} = close_owned_provider_session(state)
    {:reply, result, next}
  end

  def handle_call(
        {token, :release},
        {repl_pid, _tag},
        %{token: token, repl_pid: repl_pid, adopted?: true} = state
      ),
      do: {:stop, :normal, :ok, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :manifest_repl_unavailable}, state}

  @impl GenServer
  def handle_info(
        {token, :opening_result, worker_pid, result},
        %{token: token, worker_pid: worker_pid} = state
      ) do
    Process.demonitor(state.worker_ref, [:flush])

    next =
      state
      |> Map.put(:worker_pid, nil)
      |> Map.put(:worker_ref, nil)
      |> settle_opening_result(result)

    reply_or_wait(next)
  end

  def handle_info(
        {:DOWN, ref, :process, caller, _reason},
        %{caller_ref: ref, caller: caller} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, worker_pid, _reason},
        %{worker_ref: ref, worker_pid: worker_pid} = state
      ) do
    next =
      state
      |> Map.put(:worker_pid, nil)
      |> Map.put(:worker_ref, nil)
      |> Map.put(:result, {:error, :manifest_repl_unavailable})

    reply_or_wait(next)
  end

  def handle_info(
        {:DOWN, ref, :process, repl_pid, _reason},
        %{repl_ref: ref, repl_pid: repl_pid} = state
      ),
      do: {:stop, :normal, %{state | repl_pid: nil, repl_ref: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    state = stop_worker(state)
    {_cleanup, state} = close_owned_provider_session(state)
    if state.oauth_listener, do: LoopbackListener.close(state.oauth_listener)
    if state.registry, do: close_registry(state.registry)
    if state.oauth_memory, do: Memory.close(state.oauth_memory)
    close_preparation(state.preparation)
    if state.authority, do: PublicationAuthority.close(state.authority)

    if not state.adopted? do
      ReplTerminalization.finalize_unadopted(
        state.opened_sinks,
        state.trace_path,
        state.provider_cleanup
      )
    end

    stop_sinks(state.opened_sinks)

    if state.repl_pid && not state.adopted?,
      do: ReplSessionOwner.release(state.repl_pid, state.repl_token)

    :ok
  end

  defp open_provider_free(state) do
    preparation = state.preparation

    result =
      with :ok <-
             RunCoordinator.local_checks(
               preparation.prepared_run,
               preparation.catalog,
               preparation.runtime_services
             ),
           {:ok, registry} <-
             ProviderRegistry.new(%{},
               installed_limits: preparation.catalog.installed_limits
             ) do
        try do
          RunBuilder.build_prepared_owned(
            preparation.prepared_run,
            registry,
            state.authority,
            state.opened_sinks
          )
        after
          ProviderRegistry.close(registry)
        end
      end

    {:ok, settle_opening_result(state, result)}
  end

  defp open_provider_backed(state) do
    owner = self()
    token = state.token

    {worker_pid, worker_ref} =
      spawn_monitor(fn ->
        receive do
          {^token, :start_opening} ->
            tracker = fn action, kind, resource ->
              GenServer.call(owner, {token, {:resource, action, kind, resource}}, :infinity)
            end

            result =
              with {:ok, execution} <-
                     ProviderExecution.new(
                       state.preparation.catalog,
                       state.preparation.runtime_services,
                       []
                     ) do
                ProviderExecution.open_repl(
                  state.preparation.prepared_run,
                  state.authority,
                  state.opened_sinks,
                  execution,
                  tracker,
                  owner
                )
              end

            send(owner, {token, :opening_result, self(), result})
        end
      end)

    case PreparedRun.authorize_executor(state.preparation.prepared_run, worker_pid) do
      :ok ->
        send(worker_pid, {token, :start_opening})
        {:ok, %{state | worker_pid: worker_pid, worker_ref: worker_ref}}

      {:error, reason} ->
        Process.exit(worker_pid, :kill)
        await_down(worker_ref, worker_pid)
        {:ok, %{state | result: {:error, reason}}}
    end
  end

  defp settle_opening_result(state, {:ok, %{config: %RunConfig{} = config}}) do
    case adopt_config(state, config) do
      {:ok, next} -> next
      {:error, reason, next} -> %{next | result: {:error, reason}}
    end
  end

  defp settle_opening_result(state, {:error, reason}),
    do: %{state | result: {:error, reason}}

  defp settle_opening_result(state, _invalid),
    do: %{state | result: {:error, :invalid_manifest_repl}}

  defp adopt_config(state, config) do
    case RunState.start_repl(config.limits, config.event_sink, config.inspection_sink,
           owner: state.repl_pid,
           run_deadline: config.run_deadline
         ) do
      {:ok, run_state} -> adopt_started_config(state, config, run_state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp adopt_started_config(state, config, run_state) do
    opening = %__MODULE__{pid: self(), token: state.token}

    result =
      with :ok <- EventSink.claim(config.event_sink, config.claim_id, config.run_started_metadata),
           {:ok, run_state} <- RunState.use_provider_session(run_state, config.provider_session),
           :ok <-
             RunConfig.bind_provider_session(
               config,
               self(),
               run_state.pid,
               run_state.provider_tracker
             ) do
        ReplSessionOwner.adopt(
          state.repl_pid,
          state.repl_token,
          config,
          run_state,
          opening,
          state.trace_path
        )
      end

    case result do
      :ok ->
        Process.demonitor(state.caller_ref, [:flush])
        PublicationAuthority.close(state.authority)

        {:ok,
         %{
           state
           | caller_ref: nil,
             repl_ref: Process.monitor(state.repl_pid),
             adopted?: true,
             authority: nil,
             result: {:ok, state.repl_pid, state.repl_token}
         }}

      {:error, reason} ->
        safely(fn -> RunState.close(run_state) end)
        safely(fn -> RunState.stop(run_state) end)
        {:error, reason, state}
    end
  end

  defp reply_or_wait(%{waiter: nil} = state), do: {:noreply, state}

  defp reply_or_wait(%{waiter: waiter, result: {:ok, pid, token}} = state) do
    GenServer.reply(waiter, {:ok, pid, token})
    {:noreply, %{state | waiter: nil}}
  end

  defp reply_or_wait(%{waiter: waiter, result: {:error, _reason} = error} = state) do
    GenServer.reply(waiter, error)
    {:stop, :normal, %{state | waiter: nil}}
  end

  defp close_owned_provider_session(%{provider_cleanup: nil, provider_session: nil} = state),
    do: {:ok, %{state | provider_cleanup: :ok}}

  defp close_owned_provider_session(%{provider_cleanup: nil, provider_session: session} = state) do
    result = if ProviderSession.alive?(session), do: ProviderSession.close(session), else: :ok
    {result, %{state | provider_session: nil, provider_cleanup: result}}
  end

  defp close_owned_provider_session(state), do: {state.provider_cleanup, state}

  defp stop_worker(%{worker_pid: nil} = state), do: state

  defp stop_worker(%{worker_pid: pid, worker_ref: ref} = state) do
    Process.exit(pid, :kill)
    await_down(ref, pid)
    %{state | worker_pid: nil, worker_ref: nil}
  end

  defp await_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp stop_sinks(%{event_sink: event_sink} = sinks) do
    if sinks.inspection_sink, do: InspectionSink.stop(sinks.inspection_sink)
    EventSink.stop(event_sink)
  end

  defp stop_sinks(_sinks), do: :ok

  defp close_registry(registry) do
    ProviderRegistry.close(registry)
  catch
    :exit, _reason -> :ok
  end

  defp close_preparation(nil), do: :ok
  defp close_preparation(preparation), do: ManifestReplPreparation.close(preparation)

  defp safely(fun) do
    fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
