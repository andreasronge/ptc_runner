defmodule PtcRunner.Upstream.Collector do
  @moduledoc false

  use GenServer

  defstruct [:pid, :ref]

  @spec start_link(keyword()) :: {:ok, struct()} | {:error, term()}
  def start_link(_opts \\ []) do
    ref = make_ref()

    case GenServer.start_link(__MODULE__, ref) do
      {:ok, pid} ->
        {:ok, %__MODULE__{pid: pid, ref: ref}}

      other ->
        other
    end
  end

  @impl GenServer
  def init(ref) do
    {:ok, %{ref: ref, records: []}}
  end

  @spec record(struct(), map()) :: :ok
  def record(%__MODULE__{pid: pid, ref: ref}, entry) when is_map(entry) do
    send(pid, {:upstream_call_recorded, ref, entry})
    :ok
  end

  @spec drain(struct()) :: [map()]
  def drain(%__MODULE__{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :drain)
  catch
    :exit, _ -> []
  end

  @spec stop(struct()) :: :ok
  def stop(%__MODULE__{pid: pid}) when is_pid(pid) do
    GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def handle_info({:upstream_call_recorded, ref, entry}, %{ref: ref, records: records} = state) do
    {:noreply, %{state | records: [entry | records]}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:drain, _from, state) do
    {:reply, Enum.reverse(state.records), %{state | records: []}}
  end
end
