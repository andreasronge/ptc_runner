defmodule PtcRunner.Kernel.ReplSessionOwner do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState

  @spec start(RunConfig.t(), RunState.t(), pid()) ::
          {:ok, pid(), reference()} | {:error, term()}
  def start(%RunConfig{} = config, %RunState{} = run_state, owner) when is_pid(owner) do
    with true <- owner == self(),
         true <-
           RunState.repl_owner?(
             run_state,
             config.event_sink,
             config.inspection_sink,
             config.limits
           ) do
      token = make_ref()

      case GenServer.start(__MODULE__, {token, owner, config, run_state}) do
        {:ok, pid} -> {:ok, pid, token}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :session_owner_mismatch}
    end
  catch
    :exit, _reason -> {:error, :session_owner_mismatch}
  end

  @spec resources(pid(), reference()) ::
          {:ok, RunConfig.t(), RunState.t()} | {:error, :session_owner_mismatch}
  def resources(pid, token), do: GenServer.call(pid, {token, :resources})

  @spec release(pid(), reference()) :: :ok | {:error, :session_owner_mismatch}
  def release(pid, token) do
    GenServer.call(pid, {token, :release})
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({token, owner, config, run_state}) do
    {:ok,
     %{
       token: token,
       owner: owner,
       owner_ref: Process.monitor(owner),
       config: config,
       run_state: run_state
     }}
  end

  @impl GenServer
  def handle_call({token, :resources}, {caller, _tag}, %{token: token, owner: caller} = state),
    do: {:reply, {:ok, state.config, state.run_state}, state}

  def handle_call({token, :release}, {caller, _tag}, %{token: token, owner: caller} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :session_owner_mismatch}, state}

  @impl GenServer
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
    close_resources(state.config, state.run_state)
  end

  defp close_resources(config, run_state) do
    safely(fn -> RunState.close(run_state) end)
    safely(fn -> RunState.stop(run_state) end)
    RunConfig.close_provider_resources(config)
    if config.inspection_sink, do: safely(fn -> InspectionSink.stop(config.inspection_sink) end)
    safely(fn -> EventSink.stop(config.event_sink) end)
    :ok
  end

  defp safely(fun) do
    fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
