defmodule PtcRunner.Kernel.ProviderTaskTracker do
  @moduledoc false

  # The one owner of a run's live provider tasks, deliberately external to both
  # lifecycles it serves. It monitors the run state and, once execution binds
  # one, the provider session; either lifecycle disappearing kills and reaps
  # every attached task. Ordinary provider tasks are killed and reaped;
  # admitted LLM guardians first receive one cooperative cancel-and-drain
  # request under the shared cleanup deadline and are killed only if they miss
  # it. Because the tracker is a separate process, that
  # guarantee survives an abnormal end of either owner — including a session
  # terminated at its cleanup deadline, where `terminate/2` never runs. A
  # session drains through this owner before its own provider closers run, and
  # that drain also ends the owner, so no callback from the run is live when a
  # connector closes and none can be attached behind it.

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(pid(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def start(run_state, cleanup_timeout_ms \\ 5_000)

  def start(run_state, cleanup_timeout_ms)
      when is_pid(run_state) and is_integer(cleanup_timeout_ms) and cleanup_timeout_ms > 0 do
    token = make_ref()

    case GenServer.start(__MODULE__, {token, run_state, cleanup_timeout_ms}) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Monitors a second lifecycle whose death must drain every attached task."
  @spec watch(t(), pid()) :: :ok | {:error, :closed | :lifecycle_down}
  def watch(%__MODULE__{} = tracker, lifecycle) when is_pid(lifecycle),
    do: safe_call(tracker, {:watch, lifecycle})

  def watch(_tracker, _lifecycle), do: {:error, :closed}

  @spec attach(t(), pid()) :: :ok | {:error, :closed | :provider_down}
  def attach(%__MODULE__{} = tracker, provider) when is_pid(provider),
    do: safe_call(tracker, {:attach, provider})

  def attach(_tracker, _provider), do: {:error, :closed}

  @spec attach_guardian(t(), pid()) :: :ok | {:error, :closed | :provider_down}
  def attach_guardian(%__MODULE__{} = tracker, guardian) when is_pid(guardian),
    do: safe_call(tracker, {:attach_guardian, guardian})

  def attach_guardian(_tracker, _guardian), do: {:error, :closed}

  # Kills and reaps every attached task and then ends the tracker, so terminal
  # cleanup can prove the run's callbacks are gone. Sealing is the point:
  # draining without it would let a dispatch that raced the drain attach a live
  # callback behind it while connector closers already run, so an attachment
  # after this finds the owner closed and fails instead. Either lifecycle may
  # call it, and calling it again once it has settled is a no-op.
  @spec drain_provider_tasks(t(), integer() | nil) :: :ok | {:error, :provider_cleanup_failed}
  def drain_provider_tasks(tracker, absolute_deadline_ms \\ nil)

  def drain_provider_tasks(%__MODULE__{pid: pid} = tracker, absolute_deadline_ms) do
    ref = Process.monitor(pid)

    try do
      result = safe_call(tracker, {:drain, absolute_deadline_ms})

      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> normalize_drain_result(result, reason)
      end
    after
      Process.demonitor(ref, [:flush])
    end
  end

  # A session that was never bound to a tracker never owned a task.
  def drain_provider_tasks(_tracker, _deadline), do: :ok

  defp normalize_drain_result(:ok, _reason), do: :ok

  defp normalize_drain_result({:error, :closed}, reason) when reason in [:normal, :noproc],
    do: :ok

  defp normalize_drain_result(_failure, _reason), do: {:error, :provider_cleanup_failed}

  @impl GenServer
  def init({token, run_state, cleanup_timeout_ms}) do
    {:ok,
     %{
       token: token,
       lifecycles: %{Process.monitor(run_state) => run_state},
       providers: %{},
       guardians: %{},
       cleanup_timeout_ms: cleanup_timeout_ms
     }}
  end

  @impl GenServer
  def handle_call({token, {:watch, lifecycle}}, _from, %{token: token} = state) do
    if Process.alive?(lifecycle) do
      {:reply, :ok, put_in(state.lifecycles[Process.monitor(lifecycle)], lifecycle)}
    else
      {:reply, {:error, :lifecycle_down}, state}
    end
  end

  def handle_call({token, {:attach, provider}}, _from, %{token: token} = state) do
    if Process.alive?(provider) do
      {:reply, :ok, put_in(state.providers[Process.monitor(provider)], provider)}
    else
      {:reply, {:error, :provider_down}, state}
    end
  end

  def handle_call({token, {:attach_guardian, guardian}}, _from, %{token: token} = state) do
    if Process.alive?(guardian) do
      {:reply, :ok, put_in(state.guardians[Process.monitor(guardian)], guardian)}
    else
      {:reply, {:error, :provider_down}, state}
    end
  end

  def handle_call({token, {:drain, deadline}}, _from, %{token: token} = state) do
    {result, state} = drain(state, cleanup_deadline(state, deadline))
    {:stop, :normal, result, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{lifecycles: lifecycles} = state)
      when is_map_key(lifecycles, ref) do
    {_result, state} = drain(state, cleanup_deadline(state, nil))
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do:
      {:noreply,
       %{
         state
         | providers: Map.delete(state.providers, ref),
           guardians: Map.delete(state.guardians, ref)
       }}

  def handle_info(_message, state), do: {:noreply, state}

  # A killed task always yields the `:DOWN` this reaps, so the loop terminates
  # without its own timer. Only provider monitors are consumed; a lifecycle
  # notification that arrives mid-drain stays queued for the clause above.
  defp drain(state, deadline) do
    Enum.each(state.providers, fn {_ref, provider} -> Process.exit(provider, :kill) end)
    drain_monitors(state.providers)

    request_ref = make_ref()

    Enum.each(state.guardians, fn {_ref, guardian} ->
      send(guardian, {:cancel_provider_call, self(), request_ref, deadline})
    end)

    {remaining, uncertain?} = drain_guardians(state.guardians, request_ref, deadline, false)
    Enum.each(remaining, fn {_ref, guardian} -> Process.exit(guardian, :kill) end)
    drain_monitors(remaining)

    result =
      if uncertain? or map_size(remaining) > 0, do: {:error, :provider_cleanup_failed}, else: :ok

    {result, %{state | providers: %{}, guardians: %{}}}
  end

  defp drain_guardians(guardians, _request_ref, _deadline, uncertain?)
       when map_size(guardians) == 0,
       do: {guardians, uncertain?}

  defp drain_guardians(guardians, request_ref, deadline, uncertain?) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(guardians, ref) ->
        drain_guardians(Map.delete(guardians, ref), request_ref, deadline, uncertain?)

      {:provider_call_drained, ^request_ref, guardian, status} when is_pid(guardian) ->
        drain_guardians(guardians, request_ref, deadline, uncertain? or status == :uncertain)
    after
      timeout -> {guardians, uncertain?}
    end
  end

  defp cleanup_deadline(_state, deadline) when is_integer(deadline), do: deadline

  defp cleanup_deadline(state, _deadline),
    do: System.monotonic_time(:millisecond) + state.cleanup_timeout_ms

  defp drain_monitors(providers) when map_size(providers) == 0, do: :ok

  defp drain_monitors(providers) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(providers, ref) ->
        drain_monitors(Map.delete(providers, ref))
    end
  end

  defp call(%__MODULE__{pid: pid, token: token}, request),
    do: GenServer.call(pid, {token, request})

  defp safe_call(tracker, request) do
    call(tracker, request)
  catch
    :exit, _reason -> {:error, :closed}
  end
end
