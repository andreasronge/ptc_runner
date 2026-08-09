defmodule PtcRunner.Kernel.ReplSessionOwner do
  @moduledoc false

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.ManifestReplOpening
  alias PtcRunner.Kernel.ReplTerminalization
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState

  @spec start(RunConfig.t(), RunState.t(), pid(), binary() | nil) ::
          {:ok, pid(), reference()} | {:error, term()}
  def start(%RunConfig{} = config, %RunState{} = run_state, owner, trace_path)
      when is_pid(owner) and (is_nil(trace_path) or is_binary(trace_path)) do
    with true <- owner == self(),
         true <-
           RunState.repl_owner?(
             run_state,
             config.event_sink,
             config.inspection_sink,
             config.limits
           ) do
      token = make_ref()

      case GenServer.start(__MODULE__, {token, owner, config, run_state, trace_path}) do
        {:ok, pid} -> {:ok, pid, token}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :session_owner_mismatch}
    end
  catch
    :exit, _reason -> {:error, :session_owner_mismatch}
  end

  @doc false
  @spec start_pending(pid()) :: {:ok, pid(), reference()} | {:error, term()}
  def start_pending(owner) when is_pid(owner) do
    token = make_ref()

    case GenServer.start(__MODULE__, {:pending, token, owner}) do
      {:ok, pid} -> {:ok, pid, token}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_pending(_owner), do: {:error, :session_owner_mismatch}

  @doc false
  @spec adopt_direct(pid(), reference(), RunConfig.t(), RunState.t(), binary() | nil) ::
          :ok | {:error, :session_owner_mismatch}
  def adopt_direct(pid, token, config, run_state, trace_path) do
    GenServer.call(pid, {token, {:adopt_direct, config, run_state, trace_path}}, :infinity)
  catch
    :exit, _reason -> {:error, :session_owner_mismatch}
  end

  @doc false
  @spec adopt(pid(), reference(), RunConfig.t(), RunState.t(), term(), binary() | nil) ::
          :ok | {:error, :session_owner_mismatch}
  def adopt(pid, token, config, run_state, opening, trace_path) do
    GenServer.call(pid, {token, {:adopt, config, run_state, opening, trace_path}}, :infinity)
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

  @doc false
  @spec persist_trace(pid(), reference(), [map()]) ::
          :ok | {:error, :session_owner_mismatch | :trace_persistence_failed}
  def persist_trace(pid, token, events) when is_list(events) do
    GenServer.call(pid, {token, {:persist_trace, events}}, :infinity)
  catch
    :exit, _reason -> {:error, :session_owner_mismatch}
  end

  @impl GenServer
  def init({token, owner, config, run_state, trace_path}) do
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
       opening: nil,
       opening_ref: nil,
       trace_path: trace_path,
       terminalized?: false,
       terminal_batch: nil,
       provider_cleanup: nil
     }}
  end

  def init({:pending, token, owner}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       token: token,
       owner: owner,
       owner_ref: Process.monitor(owner),
       config: nil,
       run_state: nil,
       opening: nil,
       opening_ref: nil,
       trace_path: nil,
       terminalized?: false,
       terminal_batch: nil,
       provider_cleanup: nil
     }}
  end

  @impl GenServer
  def handle_call({token, :resources}, {caller, _tag}, %{token: token, owner: caller} = state),
    do: resources_reply(state)

  def handle_call(
        {token, {:adopt, %RunConfig{} = config, %RunState{} = run_state, opening, trace_path}},
        {caller, _tag},
        %{token: token, config: nil, run_state: nil} = state
      ) do
    if valid_adoption?(state, caller, config, run_state, opening, trace_path) do
      opening_pid = ManifestReplOpening.pid(opening)
      Process.link(run_state.pid)

      {:reply, :ok,
       %{
         state
         | config: config,
           run_state: run_state,
           opening: opening,
           opening_ref: Process.monitor(opening_pid),
           trace_path: trace_path
       }}
    else
      {:reply, {:error, :session_owner_mismatch}, state}
    end
  end

  def handle_call(
        {token, {:adopt_direct, %RunConfig{} = config, %RunState{} = run_state, trace_path}},
        {caller, _tag},
        %{token: token, owner: caller, config: nil, run_state: nil} = state
      ) do
    if direct_adoption?(config, run_state, trace_path) do
      Process.link(run_state.pid)
      {:reply, :ok, %{state | config: config, run_state: run_state, trace_path: trace_path}}
    else
      {:reply, {:error, :session_owner_mismatch}, state}
    end
  end

  def handle_call(
        {token, :close_provider_session},
        {caller, _tag},
        %{token: token, owner: caller} = state
      ) do
    {result, state} = close_provider_session(state)
    {:reply, result, state}
  end

  def handle_call(
        {token, {:persist_trace, events}},
        {caller, _tag},
        %{token: token, owner: caller, config: %RunConfig{}} = state
      ) do
    {:reply, persist_trace(state, events), %{state | terminalized?: true}}
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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{opening_ref: ref} = state) do
    safely(fn -> RunState.close(state.run_state) end)
    state = state |> Map.put(:opening, nil) |> Map.put(:opening_ref, nil)
    state = finalize_abandoned_session(state)
    _ = persist_terminal_batch(state)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    close_resources(state)
  end

  defp close_resources(state) do
    _state = close_owned_resources(state)
    :ok
  end

  defp close_owned_resources(%{config: nil} = state), do: state

  defp close_owned_resources(%{config: %RunConfig{} = config} = state) do
    safely(fn -> RunState.close(state.run_state) end)
    {_cleanup, state} = close_provider_session(state)
    state = finalize_abandoned_session(state)
    _ = persist_terminal_batch(state)
    safely(fn -> RunState.stop(state.run_state) end)

    if state.opening do
      safely(fn -> ManifestReplOpening.release(state.opening) end)
    else
      if config.inspection_sink,
        do: safely(fn -> InspectionSink.stop(config.inspection_sink) end)

      safely(fn -> EventSink.stop(config.event_sink) end)
    end

    state
  end

  defp finalize_abandoned_session(%{terminalized?: true} = state), do: state

  defp finalize_abandoned_session(%{config: %RunConfig{} = config} = state) do
    reason =
      if state.provider_cleanup == {:error, :provider_cleanup_failed},
        do: :provider_cleanup_failed,
        else: :session_owner_failed

    usage =
      try do
        RunState.usage(state.run_state)
      catch
        :exit, _reason -> %{}
      end

    terminal_batch =
      EventSink.finalize_and_events(config.event_sink, %{
        outcome: :error,
        reason: reason,
        usage: usage
      })

    %{state | terminalized?: true, terminal_batch: terminal_batch}
  end

  defp finalize_abandoned_session(state), do: state

  defp persist_terminal_batch(%{terminal_batch: {:ok, %{events: events}}} = state),
    do: persist_trace(state, events)

  defp persist_terminal_batch(_state), do: :ok

  defp resources_reply(
         %{config: %RunConfig{} = config, run_state: %RunState{} = run_state} = state
       ),
       do: {:reply, {:ok, config, run_state}, state}

  defp resources_reply(state),
    do: {:reply, {:error, :session_owner_mismatch}, state}

  defp valid_adoption?(state, caller, config, run_state, opening, trace_path) do
    ManifestReplOpening.valid?(opening) and ManifestReplOpening.pid(opening) == caller and
      RunState.repl_owner?(
        run_state,
        config.event_sink,
        config.inspection_sink,
        config.limits
      ) and (is_nil(trace_path) or is_binary(trace_path)) and state.owner != caller
  catch
    :exit, _reason -> false
  end

  defp direct_adoption?(config, run_state, trace_path) do
    RunState.repl_resources?(
      run_state,
      config.event_sink,
      config.inspection_sink,
      config.limits
    ) and (is_nil(trace_path) or is_binary(trace_path))
  catch
    :exit, _reason -> false
  end

  defp close_provider_session(%{provider_cleanup: nil, config: nil} = state),
    do: {:ok, %{state | provider_cleanup: :ok}}

  defp close_provider_session(%{provider_cleanup: nil} = state) do
    result =
      if state.opening,
        do: ManifestReplOpening.close_provider_session(state.opening),
        else: RunConfig.close_provider_session(state.config)

    config = %{state.config | provider_session: nil}
    {result, %{state | config: config, provider_cleanup: result}}
  end

  defp close_provider_session(state), do: {state.provider_cleanup, state}

  defp persist_trace(%{trace_path: nil}, _events), do: :ok

  defp persist_trace(%{trace_path: path, config: config}, events),
    do: ReplTerminalization.persist(path, config.event_sink, events)

  defp safely(fun) do
    fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
