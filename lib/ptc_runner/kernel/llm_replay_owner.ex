defmodule PtcRunner.Kernel.LLMReplayOwner do
  @moduledoc false

  # Holds immutable replay responses and atomic sequence positions. A retained
  # installation gives each run its own cursor, reclaimed when that run exits.
  #
  # This is a GenServer rather than an Agent for two reasons. It monitors the
  # owning process so a run that fails between acquisition and cleanup cannot
  # leave the provider behind, matching how the snapshot owners behave. And
  # taking a response is one `handle_call` — reading the remaining sequence and
  # advancing the cursor happen inside the owner, so two concurrent workflow
  # calls cannot be served the same element.

  use GenServer

  alias PtcRunner.Kernel.ResourceRegistrar

  @spec start(%{binary() => [map()]}, pid(), ResourceRegistrar.t() | nil) ::
          {:ok, pid()} | {:error, term()}
  def start(entries, owner, registrar \\ nil) when is_map(entries) and is_pid(owner) do
    GenServer.start(__MODULE__, {entries, owner, registrar})
  end

  @spec take(pid(), binary(), pid() | nil) ::
          {:ok, map()} | {:error, :exhausted | :unmatched | :unavailable}
  def take(pid, key, scope \\ nil)
      when is_pid(pid) and is_binary(key) and (is_pid(scope) or is_nil(scope)) do
    GenServer.call(pid, {:take, key, scope})
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
  def init({entries, owner, registrar}) do
    owner_ref = Process.monitor(owner)

    case ResourceRegistrar.register_root(registrar) do
      :ok -> {:ok, %{entries: entries, owner_ref: owner_ref, cursors: %{}}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:take, key, scope}, _from, %{entries: entries} = state) do
    case Map.fetch(entries, key) do
      {:ok, responses} ->
        cursor =
          Map.get_lazy(state.cursors, scope, fn ->
            %{monitor: if(is_pid(scope), do: Process.monitor(scope)), positions: %{}}
          end)

        position = Map.get(cursor.positions, key, 0)
        state = %{state | cursors: Map.put(state.cursors, scope, cursor)}

        case Enum.fetch(responses, position) do
          {:ok, response} ->
            cursor = %{cursor | positions: Map.put(cursor.positions, key, position + 1)}
            {:reply, {:ok, response}, %{state | cursors: Map.put(state.cursors, scope, cursor)}}

          :error ->
            {:reply, {:error, :exhausted}, state}
        end

      :error ->
        {:reply, {:error, :unmatched}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, %{owner_ref: owner_ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, scope, _reason}, state) do
    case Map.get(state.cursors, scope) do
      %{monitor: ^ref} -> {:noreply, %{state | cursors: Map.delete(state.cursors, scope)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}
end
