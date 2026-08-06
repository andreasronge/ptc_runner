defmodule PtcRunner.Kernel.ProviderTaskTracker do
  @moduledoc false

  # The one owner of a run's live provider tasks, deliberately external to both
  # lifecycles it serves. It monitors the run state and, once execution binds
  # one, the provider session; either lifecycle disappearing kills and reaps
  # every attached task. Because the tracker is a separate process, that
  # guarantee survives an abnormal end of either owner — including a session
  # terminated at its cleanup deadline, where `terminate/2` never runs. A
  # session drains through this owner before its own provider closers run, so
  # no callback from the run is still live when a connector closes.

  use GenServer

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  @spec start(pid()) :: {:ok, t()} | {:error, term()}
  def start(run_state) when is_pid(run_state) do
    token = make_ref()

    case GenServer.start(__MODULE__, {token, run_state}) do
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

  # Kills and reaps every attached task without ending the tracker, so a
  # session can prove its callbacks are gone before running provider closers
  # and still own tasks attached by a later evaluation. A tracker that has
  # already stopped drained on its way out, so a failed call means there is
  # nothing left to drain rather than an unsettled one.
  @spec drain_provider_tasks(t()) :: :ok
  def drain_provider_tasks(%__MODULE__{} = tracker) do
    _ = safe_call(tracker, :drain)
    :ok
  end

  # A session that was never bound to a tracker never owned a task.
  def drain_provider_tasks(_tracker), do: :ok

  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid} = tracker) do
    ref = Process.monitor(pid)

    try do
      _ = safe_call(tracker, :close)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    after
      Process.demonitor(ref, [:flush])
    end
  end

  @impl GenServer
  def init({token, run_state}) do
    {:ok,
     %{
       token: token,
       lifecycles: %{Process.monitor(run_state) => run_state},
       providers: %{}
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

  def handle_call({token, :drain}, _from, %{token: token} = state),
    do: {:reply, :ok, drain(state)}

  def handle_call({token, :close}, _from, %{token: token} = state),
    do: {:stop, :normal, :ok, drain(state)}

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{lifecycles: lifecycles} = state)
      when is_map_key(lifecycles, ref) do
    {:stop, :normal, drain(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | providers: Map.delete(state.providers, ref)}}

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  # A killed task always yields the `:DOWN` this reaps, so the loop terminates
  # without its own timer. Only provider monitors are consumed; a lifecycle
  # notification that arrives mid-drain stays queued for the clause above.
  defp drain(state) do
    Enum.each(state.providers, fn {_ref, provider} -> Process.exit(provider, :kill) end)
    drain_monitors(state.providers)
    %{state | providers: %{}}
  end

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

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
