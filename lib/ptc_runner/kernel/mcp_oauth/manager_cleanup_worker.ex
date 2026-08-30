defmodule PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorker do
  @moduledoc false

  use GenServer
  use PtcRunner.Kernel.OwnerStatusRedaction

  alias PtcRunner.Kernel.MCPOAuth.TokenManager

  @initial_retry_ms 250
  @maximum_retry_ms 30_000
  @timeout_deadline_ms 300_000

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

  @spec start_link(TokenManager.t(), keyword()) :: GenServer.on_start()
  def start_link(%TokenManager{} = manager, opts \\ []) do
    timeout_deadline_ms = Keyword.get(opts, :timeout_deadline_ms, @timeout_deadline_ms)
    GenServer.start_link(__MODULE__, {manager, timeout_deadline_ms})
  end

  @impl GenServer
  def init({%TokenManager{pid: pid} = manager, timeout_deadline_ms})
      when is_integer(timeout_deadline_ms) and timeout_deadline_ms > 0 do
    Process.link(pid)
    send(self(), :close)

    {:ok,
     %{
       manager: manager,
       retry_ms: @initial_retry_ms,
       timeout_deadline_ms: timeout_deadline_ms,
       timeout_deadline: nil
     }}
  rescue
    ErlangError ->
      # Linking is the atomic ownership handoff. A manager that exited before
      # the link completed is already cleaned up.
      :ignore
  end

  @impl GenServer
  def handle_info(:close, state) do
    now = System.monotonic_time(:millisecond)
    deadline = state.timeout_deadline || now + state.timeout_deadline_ms
    remaining = deadline - now

    if remaining <= 0 do
      timeout_exhausted(state, deadline)
    else
      case TokenManager.close(state.manager, remaining) do
        :ok ->
          {:stop, :normal, state}

        {:error, :persistence_failed} ->
          retry(%{state | timeout_deadline: nil})

        {:error, :timeout} ->
          retry_timeout(state, deadline)
      end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp retry_timeout(state, deadline) do
    now = System.monotonic_time(:millisecond)
    remaining = deadline - now

    if remaining <= 0 do
      timeout_exhausted(state, deadline)
    else
      retry(%{state | timeout_deadline: deadline}, min(state.retry_ms, remaining))
    end
  end

  defp timeout_exhausted(state, deadline),
    do: {:stop, :cleanup_timeout_exhausted, %{state | timeout_deadline: deadline}}

  defp retry(state, delay_ms \\ nil) do
    Process.send_after(self(), :close, delay_ms || state.retry_ms)
    {:noreply, %{state | retry_ms: min(state.retry_ms * 2, @maximum_retry_ms)}}
  end
end
