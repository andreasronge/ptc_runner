defmodule PtcRunner.Kernel.MCPOAuth.ManagerCleanup do
  @moduledoc """
  Bounded supervisor for token managers left by failed provider acquisition.

  Each adopted manager receives one linked cleanup worker. The worker retries
  bounded close calls with capped exponential backoff. If this supervisor
  restarts, OTP terminates the linked workers, which in turn terminate their
  linked managers rather than leaving unreachable credential owners alive.
  """

  use DynamicSupervisor

  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorker
  alias PtcRunner.Kernel.MCPOAuth.TokenManager

  @max_managers 128

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec adopt(TokenManager.t()) :: :ok | {:error, :cleanup_unavailable}
  def adopt(%TokenManager{pid: pid} = manager) do
    case DynamicSupervisor.start_child(__MODULE__, {ManagerCleanupWorker, manager}) do
      {:ok, _worker} -> :ok
      {:error, {:already_started, _worker}} -> :ok
      :ignore -> :ok
      {:error, _reason} -> if(Process.alive?(pid), do: {:error, :cleanup_unavailable}, else: :ok)
    end
  catch
    :exit, _reason -> {:error, :cleanup_unavailable}
  end

  @impl DynamicSupervisor
  def init(:ok),
    do: DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_managers)
end
