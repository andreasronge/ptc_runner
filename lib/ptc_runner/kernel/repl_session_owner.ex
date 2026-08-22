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
    adopt(pid, token, config, run_state, opening, trace_path, :workflow)
  end

  @doc false
  @spec adopt(pid(), reference(), RunConfig.t(), RunState.t(), term(), binary() | nil, term()) ::
          :ok | {:error, :session_owner_mismatch}
  def adopt(pid, token, config, run_state, opening, trace_path, mode) do
    GenServer.call(
      pid,
      {token, {:adopt, config, run_state, opening, trace_path, mode}},
      :infinity
    )
  catch
    :exit, _reason -> {:error, :session_owner_mismatch}
  end

  @spec resources(pid(), reference()) ::
          {:ok, RunConfig.t(), RunState.t()} | {:error, :session_owner_mismatch}
  def resources(pid, token), do: GenServer.call(pid, {token, :resources}, :infinity)

  @doc false
  @spec session_resources(pid(), reference()) ::
          {:ok, RunConfig.t(), RunState.t(), :direct | :workflow | map()}
          | {:error, :session_owner_mismatch}
  def session_resources(pid, token),
    do: GenServer.call(pid, {token, :session_resources}, :infinity)

  @spec release(pid(), reference()) :: :ok | {:error, :session_owner_mismatch}
  def release(pid, token) do
    GenServer.call(pid, {token, :release})
  catch
    :exit, _reason -> :ok
  end

  @spec close_provider_session(pid(), reference()) ::
          {:ok, :ok | {:error, :provider_cleanup_failed},
           nil | %{kind: atom(), reason: atom()} | %{kind: atom(), reason: atom(), details: map()}}
          | {:error, :session_owner_mismatch}
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

    state =
      %{
        token: token,
        owner: owner,
        owner_ref: Process.monitor(owner),
        config: config,
        run_state: run_state,
        opening: nil,
        opening_ref: nil,
        trace_path: trace_path,
        mode: :workflow,
        terminalized?: false,
        terminal_batch: nil,
        terminal_failure: nil,
        provider_cleanup: nil,
        deadline_timer: nil,
        deadline_token: nil
      }

    {:ok, arm_deadline(state)}
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
       mode: :workflow,
       terminalized?: false,
       terminal_batch: nil,
       terminal_failure: nil,
       provider_cleanup: nil,
       deadline_timer: nil,
       deadline_token: nil
     }}
  end

  @impl GenServer
  def handle_call({token, :resources}, {caller, _tag}, %{token: token, owner: caller} = state),
    do: resources_reply(state)

  def handle_call(
        {token, :session_resources},
        {caller, _tag},
        %{token: token, owner: caller} = state
      ),
      do: session_resources_reply(state)

  def handle_call(
        {token,
         {:adopt, %RunConfig{} = config, %RunState{} = run_state, opening, trace_path, mode}},
        {caller, _tag},
        %{token: token, config: nil, run_state: nil} = state
      ) do
    if valid_adoption?(state, caller, config, run_state, opening, trace_path) and
         valid_mode?(mode, config) do
      opening_pid = ManifestReplOpening.pid(opening)
      Process.link(run_state.pid)

      next =
        %{
          state
          | config: config,
            run_state: run_state,
            opening: opening,
            opening_ref: Process.monitor(opening_pid),
            trace_path: trace_path,
            mode: mode
        }

      {:reply, :ok, arm_deadline(next)}
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

      next =
        %{state | config: config, run_state: run_state, trace_path: trace_path, mode: :direct}

      {:reply, :ok, arm_deadline(next)}
    else
      {:reply, {:error, :session_owner_mismatch}, state}
    end
  end

  def handle_call(
        {token, :close_provider_session},
        {caller, _tag},
        %{token: token, owner: caller} = state
      ) do
    state = state |> record_elapsed_deadline() |> disarm_deadline()
    terminal_failure = terminal_failure(state)
    {result, state} = close_provider_session(state)
    {:reply, {:ok, result, terminal_failure}, state}
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

  def handle_info(
        {:repl_deadline_expired, deadline_token},
        %{deadline_token: deadline_token, config: %RunConfig{}, run_state: %RunState{}} = state
      ) do
    state = %{state | deadline_timer: nil, deadline_token: nil}
    state = record_deadline_expiry(state)
    {_cleanup, state} = close_provider_session(state)
    {:noreply, state}
  end

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
    state = disarm_deadline(state)
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
      case {state.provider_cleanup, terminal_failure(state)} do
        {{:error, :provider_cleanup_failed}, _failure} -> :provider_cleanup_failed
        {_cleanup, %{reason: reason}} -> reason
        {_cleanup, nil} -> :session_owner_failed
      end

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

  defp session_resources_reply(
         %{config: %RunConfig{} = config, run_state: %RunState{} = run_state, mode: mode} = state
       ),
       do: {:reply, {:ok, config, run_state, mode}, state}

  defp session_resources_reply(state),
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

  defp valid_mode?(:workflow, %RunConfig{}), do: true

  defp valid_mode?(
         %{
           kind: :mission,
           name: name,
           component_ids: component_ids,
           direct_provider_aliases: direct_provider_aliases
         } = mode,
         %RunConfig{missions: missions}
       )
       when is_binary(name) and is_list(component_ids) and is_list(direct_provider_aliases) do
    Enum.sort(Map.keys(mode)) ==
      [:component_ids, :direct_provider_aliases, :kind, :name] and
      Map.keys(missions) == [name] and Enum.all?(component_ids, &is_binary/1) and
      Enum.all?(direct_provider_aliases, &is_binary/1)
  end

  defp valid_mode?(_mode, _config), do: false

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

  defp arm_deadline(%{run_state: %RunState{} = run_state} = state) do
    deadline_token = make_ref()

    deadline_timer =
      Process.send_after(
        self(),
        {:repl_deadline_expired, deadline_token},
        deadline_remaining_ms(run_state)
      )

    %{state | deadline_timer: deadline_timer, deadline_token: deadline_token}
  end

  defp disarm_deadline(%{deadline_timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | deadline_timer: nil, deadline_token: nil}
  end

  defp disarm_deadline(state), do: state

  defp record_elapsed_deadline(%{deadline_timer: timer, run_state: %RunState{}} = state)
       when is_reference(timer) do
    if deadline_remaining_ms(state.run_state) == 0,
      do: record_deadline_expiry(state),
      else: state
  end

  defp record_elapsed_deadline(state), do: state

  defp record_deadline_expiry(state) do
    case RunState.fail_once(state.run_state, :limit_exceeded, :deadline_expired) do
      {:recorded, failure} ->
        _ =
          EventSink.emit(state.config.event_sink, "limit-exceeded", %{
            reason: :deadline_expired
          })

        %{state | terminal_failure: failure}

      {:existing, failure} ->
        %{state | terminal_failure: failure}
    end
  end

  defp terminal_failure(%{terminal_failure: failure}) when not is_nil(failure), do: failure

  defp terminal_failure(%{run_state: %RunState{} = run_state}) do
    RunState.terminal_failure(run_state)
  catch
    :exit, _reason -> nil
  end

  defp terminal_failure(_state), do: nil

  defp deadline_remaining_ms(run_state) do
    RunState.remaining_ms(run_state)
  catch
    :exit, _reason -> 0
  end

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
