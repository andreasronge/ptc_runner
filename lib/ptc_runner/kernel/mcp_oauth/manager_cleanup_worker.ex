defmodule PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorker do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.MCPOAuth.TokenManager

  @initial_retry_ms 250
  @maximum_retry_ms 30_000

  @spec child_spec(TokenManager.t()) :: Supervisor.child_spec()
  def child_spec(%TokenManager{pid: pid} = manager) do
    %{
      id: {__MODULE__, pid},
      start: {__MODULE__, :start_link, [manager]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec start_link(TokenManager.t()) :: GenServer.on_start()
  def start_link(%TokenManager{} = manager),
    do: GenServer.start_link(__MODULE__, manager)

  @impl GenServer
  def init(%TokenManager{pid: pid} = manager) do
    Process.link(pid)
    send(self(), :close)
    {:ok, %{manager: manager, retry_ms: @initial_retry_ms}}
  rescue
    ErlangError ->
      # Linking is the atomic ownership handoff. A manager that exited before
      # the link completed is already cleaned up.
      :ignore
  end

  @impl GenServer
  def handle_info(:close, state) do
    case TokenManager.close(state.manager) do
      :ok ->
        {:stop, :normal, state}

      {:error, _reason} ->
        Process.send_after(self(), :close, state.retry_ms)
        {:noreply, %{state | retry_ms: min(state.retry_ms * 2, @maximum_retry_ms)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(_status), do: %{state: :redacted}
  else
    def format_status(_status), do: %{state: :redacted}
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]
end
