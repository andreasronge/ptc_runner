defmodule PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorker do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.MCPOAuth.TokenManager

  @initial_retry_ms 250
  @maximum_retry_ms 30_000
  @deadline_ms 300_000

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

  @doc """
  Starts a cleanup worker for `manager`.

  `:deadline_ms` bounds total retry time from adoption; it exists so tests can
  drive exhaustion without waiting out the production bound.
  """
  @spec start_link(TokenManager.t(), keyword()) :: GenServer.on_start()
  def start_link(%TokenManager{} = manager, opts \\ []),
    do: GenServer.start_link(__MODULE__, {manager, Keyword.get(opts, :deadline_ms, @deadline_ms)})

  @impl GenServer
  def init({%TokenManager{pid: pid} = manager, deadline_ms}) do
    Process.link(pid)
    send(self(), :close)

    {:ok,
     %{
       manager: manager,
       retry_ms: @initial_retry_ms,
       deadline: System.monotonic_time(:millisecond) + deadline_ms
     }}
  rescue
    ErlangError ->
      # Linking is the atomic ownership handoff. A manager that exited before
      # the link completed is already cleaned up.
      :ignore
  end

  # Retries are bounded by one absolute deadline rather than an attempt count,
  # because the resource being bounded is occupancy of a cleanup slot: the owner
  # holds only `@max_managers` of them for the whole node, so a manager whose
  # close never succeeds would otherwise deny cleanup to every later run.
  #
  # Exhaustion stops **abnormally** on purpose. The `Process.link/1` above is the
  # reclamation mechanism, and links do not propagate normal exits, so a
  # `:normal` stop here would release the slot and leave the credential owner
  # running.
  @impl GenServer
  def handle_info(:close, state) do
    case TokenManager.close(state.manager) do
      :ok ->
        {:stop, :normal, state}

      {:error, _reason} ->
        retry_or_give_up(state)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp retry_or_give_up(state) do
    remaining = state.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:stop, :cleanup_deadline_exceeded, state}
    else
      # Clamping to the remaining budget keeps the last attempt inside the
      # deadline; one in-flight `TokenManager.close/1` can still overrun it by up
      # to its own call timeout, which is not cancellable from here.
      Process.send_after(self(), :close, min(state.retry_ms, remaining))
      {:noreply, %{state | retry_ms: min(state.retry_ms * 2, @maximum_retry_ms)}}
    end
  end

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(_status), do: %{state: :redacted}
  else
    def format_status(_status), do: %{state: :redacted}
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]
end
