defmodule PtcRunner.Kernel.ProviderTaskTracker do
  @moduledoc false

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

  @spec attach(t(), pid()) :: :ok | {:error, :closed | :provider_down}
  def attach(tracker, provider) when is_pid(provider),
    do: safe_call(tracker, {:attach, provider})

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
       run_state_ref: Process.monitor(run_state),
       providers: %{}
     }}
  end

  @impl GenServer
  def handle_call({token, {:attach, provider}}, _from, %{token: token} = state) do
    if Process.alive?(provider) do
      ref = Process.monitor(provider)
      {:reply, :ok, put_in(state.providers[ref], provider)}
    else
      {:reply, {:error, :provider_down}, state}
    end
  end

  def handle_call({token, :close}, _from, %{token: token} = state) do
    state = drain(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{run_state_ref: ref} = state) do
    state = drain(state)
    {:stop, :normal, state}
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

  defp drain(state) do
    Enum.each(state.providers, fn {_ref, provider} -> Process.exit(provider, :kill) end)
    drain_monitors(state.providers)
    %{state | providers: %{}}
  end

  defp drain_monitors(providers) when map_size(providers) == 0, do: :ok

  defp drain_monitors(providers) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
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
