defmodule PtcRunner.Kernel.HostRuntimeOwner do
  @moduledoc false

  use GenServer

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec config() :: {:ok, map()} | {:error, :invalid_host_runtime}
  def config do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :invalid_host_runtime}

      pid ->
        try do
          {:ok, GenServer.call(pid, :config, 5_000)}
        catch
          :exit, _reason -> {:error, :invalid_host_runtime}
        end
    end
  end

  @impl GenServer
  def init(config), do: {:ok, config}

  @impl GenServer
  def handle_call(:config, _from, config), do: {:reply, config, config}
end
