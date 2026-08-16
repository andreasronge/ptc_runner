defmodule PtcViewer.LiveStore do
  @moduledoc """
  In-memory store and fan-out hub for live run status frames (#1444 spike).

  Run processes POST frames to the Viewer; this store keeps the latest frame
  per run and broadcasts each accepted frame (pre-encoded JSON) to SSE
  subscribers. Frames are self-contained — the client needs no history from
  the store, only the latest frame per run plus the live stream.

  Started lazily on first use as a locally named singleton (spike
  simplification; lifecycle wiring into `PtcViewer.Server` is refinement).
  """

  use GenServer

  @name __MODULE__
  @max_runs 12

  @spec ensure_started() :: {:ok, pid()} | {:error, term()}
  def ensure_started do
    case Process.whereis(@name) do
      nil ->
        case GenServer.start(__MODULE__, %{}, name: @name) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc "Accepts one frame for `run_id`; broadcasts it to all subscribers."
  @spec put_frame(binary(), map()) :: :ok | {:error, :invalid_frame}
  def put_frame(run_id, frame) when is_binary(run_id) and is_map(frame) do
    GenServer.call(@name, {:put, run_id, frame})
  end

  def put_frame(_run_id, _frame), do: {:error, :invalid_frame}

  @doc "Latest decoded frame per known run, oldest run first."
  @spec snapshot() :: [map()]
  def snapshot, do: GenServer.call(@name, :snapshot)

  @doc """
  Subscribes the caller and returns the encoded snapshot atomically, so no
  frame can fall between the snapshot and the first live delivery.
  Subscribers receive `{:live_frame, json}` messages and are auto-removed
  when they go down.
  """
  @spec subscribe(pid()) :: {:ok, [binary()]}
  def subscribe(pid) when is_pid(pid), do: GenServer.call(@name, {:subscribe, pid})

  @impl GenServer
  def init(_args) do
    {:ok, %{runs: %{}, subscribers: %{}}}
  end

  @impl GenServer
  def handle_call({:put, run_id, frame}, _from, state) do
    frame = Map.put(frame, "run_id", run_id)

    case Jason.encode(frame) do
      {:ok, json} ->
        entry = %{
          frame: frame,
          json: json,
          first_seen: Map.get(state.runs, run_id, %{})[:first_seen] || now_ms()
        }

        runs = state.runs |> Map.put(run_id, entry) |> evict()
        Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:live_frame, json}) end)
        {:reply, :ok, %{state | runs: runs}}

      {:error, _reason} ->
        {:reply, {:error, :invalid_frame}, state}
    end
  end

  def handle_call(:snapshot, _from, state),
    do: {:reply, Enum.map(ordered(state.runs), & &1.frame), state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    subscribers = Map.put(state.subscribers, ref, pid)
    jsons = Enum.map(ordered(state.runs), & &1.json)
    {:reply, {:ok, jsons}, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  def handle_info(_message, state), do: {:noreply, state}

  defp ordered(runs) do
    runs
    |> Map.values()
    |> Enum.sort_by(& &1.first_seen)
  end

  defp evict(runs) when map_size(runs) <= @max_runs, do: runs

  defp evict(runs) do
    # Drop the oldest ended run first; never evict a run that is still live.
    {ended, live} =
      runs
      |> Enum.sort_by(fn {_id, entry} -> entry.first_seen end)
      |> Enum.split_with(fn {_id, entry} -> entry.frame["phase"] != "running" end)

    case ended do
      [{oldest_id, _entry} | _rest] -> Map.delete(runs, oldest_id)
      [] -> Map.delete(runs, elem(hd(live), 0))
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
