defmodule PtcRunner.Kernel.ExecutionSessionOwner do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderRegistry
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
  def start(prepared, authority, caller) when is_pid(caller) do
    cond do
      not PreparedRun.valid?(prepared) ->
        {:error, :invalid_prepared_run}

      not PublicationAuthority.valid?(authority) ->
        {:error, :invalid_publication_authority}

      prepared.provider_declarations != [] ->
        {:error, :provider_session_required}

      true ->
        token = make_ref()

        case GenServer.start(__MODULE__, {prepared, authority, caller, token}) do
          {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
          {:error, _reason} -> {:error, :invalid_prepared_run}
        end
    end
  end

  def start(_prepared, _authority, _caller), do: {:error, :invalid_prepared_run}

  @doc false
  @spec await(t()) :: {:ok, PtcRunner.Kernel.ExecutionOutcome.t()} | {:error, term()}
  def await(%__MODULE__{pid: pid, token: token}) do
    GenServer.call(pid, {token, :await}, :infinity)
  catch
    :exit, _reason -> {:error, :execution_session_unavailable}
  end

  @doc false
  @spec pid(t()) :: pid()
  def pid(%__MODULE__{pid: pid}), do: pid

  @impl GenServer
  def init({prepared, authority, caller, token}) do
    caller_ref = Process.monitor(caller)

    initial = %{
      token: token,
      caller: caller,
      caller_ref: caller_ref,
      prepared: prepared,
      registry: nil,
      built: nil,
      opened_sinks: nil,
      worker_pid: nil,
      worker_ref: nil,
      waiter: nil,
      result: nil
    }

    case open_provider_free(prepared, authority) do
      {:ok, registry, built} ->
        owner = self()

        {worker_pid, worker_ref} =
          spawn_monitor(fn ->
            result = RunBuilder.execute_built(built)
            send(owner, {token, :execution_result, self(), result})
          end)

        {:ok,
         %{
           initial
           | registry: registry,
             built: built,
             worker_pid: worker_pid,
             worker_ref: worker_ref
         }}

      {:error, reason, registry} ->
        close_registry(registry)
        close_prepared(prepared)
        {:ok, %{initial | result: {:error, reason}}}

      {:error, reason, registry, opened_sinks} ->
        next =
          initial
          |> Map.put(:registry, registry)
          |> Map.put(:opened_sinks, opened_sinks)
          |> finalize_aborted_sinks()
          |> close_owned_inputs()
          |> Map.put(:result, {:error, reason})

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
      do: {:stop, :normal, result, state}

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
      |> close_owned_inputs()
      |> Map.put(:result, result)

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
      |> Map.put(:result, {:error, :execution_session_unavailable})

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

  defp open_provider_free(prepared, authority) do
    opts = PublicationAuthority.options(authority)

    case ProviderRegistry.new(%{},
           installed_limits: prepared.request.package.installed_limits
         ) do
      {:ok, registry} ->
        case RunBuilder.build_prepared_owned(prepared, registry, opts) do
          {:ok, built} ->
            if PublicationAuthority.binding(built.publication_authority) ==
                 PublicationAuthority.binding(authority) do
              {:ok, registry, built}
            else
              RunBuilder.close(built.config)
              {:error, :invalid_publication_authority, registry}
            end

          {:error, reason} ->
            {:error, reason, registry}

          {:error, reason, opened_sinks} ->
            {:error, reason, registry, opened_sinks}
        end

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  defp finish_or_wait(%{waiter: nil} = state), do: {:noreply, state}

  defp finish_or_wait(%{waiter: waiter, result: result} = state) do
    GenServer.reply(waiter, result)
    {:stop, :normal, state}
  end

  defp abort(state) do
    state
    |> stop_worker()
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
    close_registry(state.registry)
    close_prepared(state.prepared)
    %{state | registry: nil, prepared: nil}
  end

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
