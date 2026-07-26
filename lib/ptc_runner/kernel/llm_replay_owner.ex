defmodule PtcRunner.Kernel.LLMReplayOwner do
  @moduledoc false

  # Holds the remaining replay responses for one installed `llm_replay`
  # provider and dies with the run that opened it.
  #
  # This is a GenServer rather than an Agent for two reasons. It monitors the
  # owning process so a run that fails between acquisition and cleanup cannot
  # leave the provider behind, matching how the snapshot owners behave. And
  # taking a response is one `handle_call` — reading the remaining sequence and
  # advancing the cursor happen inside the owner, so two concurrent workflow
  # calls cannot be served the same element.

  use GenServer

  @spec start(%{binary() => [map()]}, pid()) :: {:ok, pid()} | {:error, term()}
  def start(entries, owner) when is_map(entries) and is_pid(owner) do
    GenServer.start(__MODULE__, {entries, owner})
  end

  @spec take(pid(), binary()) ::
          {:ok, map()} | {:error, :exhausted | :unmatched | :unavailable}
  def take(pid, key) when is_pid(pid) and is_binary(key) do
    GenServer.call(pid, {:take, key})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({entries, owner}) do
    {:ok, %{entries: entries, owner_ref: Process.monitor(owner)}}
  end

  @impl GenServer
  def handle_call({:take, key}, _from, %{entries: entries} = state) do
    case Map.get(entries, key) do
      [response | rest] ->
        {:reply, {:ok, response}, %{state | entries: Map.put(entries, key, rest)}}

      [] ->
        {:reply, {:error, :exhausted}, state}

      nil ->
        {:reply, {:error, :unmatched}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, %{owner_ref: owner_ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
