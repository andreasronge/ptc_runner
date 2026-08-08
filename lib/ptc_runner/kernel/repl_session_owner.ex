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

  @spec close_provider_session(pid(), reference()) ::
          :ok | {:error, :provider_cleanup_failed | :session_owner_mismatch}
  def close_provider_session(pid, token) do
    GenServer.call(pid, {token, :close_provider_session}, :infinity)
  catch
    :exit, _reason -> {:error, :session_owner_mismatch}
  end

  @impl GenServer
  def init({token, owner, config, run_state}) do
    # `terminate/2` stops the run state, but it does not run on an untrappable
    # exit, so a brutally killed owner used to orphan its run state and the
    # `ProviderTaskTracker` every run state starts (#1209). Cleanup that only
    # holds when `terminate/2` runs is not cleanup.
    #
    # The link makes the guarantee a VM-level one: the owner's exit signal
    # reaches the run state whatever killed the owner, and the tracker follows
    # because it already monitors the run state as a lifecycle. Trapping exits
    # keeps the link one-directional in effect: a run state that dies on its own
    # arrives as a message this module ignores, rather than taking the owner
    # down and destroying its ability to report why a close failed.
    Process.flag(:trap_exit, true)
    Process.link(run_state.pid)

    {:ok,
     %{
       token: token,
       owner: owner,
       owner_ref: Process.monitor(owner),
       config: config,
       run_state: run_state,
       provider_cleanup: nil
     }}
  end

  @impl GenServer
  def handle_call({token, :resources}, {caller, _tag}, %{token: token, owner: caller} = state),
    do: {:reply, {:ok, state.config, state.run_state}, state}

  def handle_call(
        {token, :close_provider_session},
        {caller, _tag},
        %{token: token, owner: caller} = state
      ) do
    {result, state} = close_provider_session(state)
    {:reply, result, state}
  end

  def handle_call({token, :release}, {caller, _tag}, %{token: token, owner: caller} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :session_owner_mismatch}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  # A run state that dies on its own is *ignored* here, deliberately.
  #
  # The link exists for one direction only: owner dies -> run state dies. In the
  # other direction the owner must stay alive, because a caller closing a
  # session whose run state died still has to be told why — and provider
  # cleanup failures are reported through that close, not through the owner's
  # own exit. Stopping here instead turned
  # `{:error, :provider_cleanup_failed}` into `{:error, :session_closed}` and
  # broke the race that `ProviderLifecycleTest` pins down.
  #
  # Trapping exits is what makes ignoring possible: without it this signal
  # would kill the owner outright. So the trap preserves the pre-#1209
  # behaviour on run-state death while the link adds the missing guarantee on
  # owner death.
  def handle_info({:EXIT, pid, _reason}, %{run_state: %{pid: pid}} = state),
    do: {:noreply, state}

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
    close_resources(state)
  end

  defp close_resources(state) do
    safely(fn -> RunState.close(state.run_state) end)
    safely(fn -> RunState.stop(state.run_state) end)
    {_result, state} = close_provider_session(state)
    config = state.config
    if config.inspection_sink, do: safely(fn -> InspectionSink.stop(config.inspection_sink) end)
    safely(fn -> EventSink.stop(config.event_sink) end)
    :ok
  end

  defp close_provider_session(%{provider_cleanup: nil} = state) do
    result = RunConfig.close_provider_session(state.config)
    config = %{state.config | provider_session: nil}
    {result, %{state | config: config, provider_cleanup: result}}
  end

  defp close_provider_session(state), do: {state.provider_cleanup, state}

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
