defmodule PtcViewer.LiveStore do
  @moduledoc """
  In-memory store and fan-out hub for live run status frames (#1444).

  Run processes POST frames to the Viewer; this store keeps the latest frame
  per run and broadcasts each accepted frame (pre-encoded JSON) to SSE
  subscribers. Frames are self-contained — the client needs no history from
  the store, only the latest frame per run plus the live stream.

  Started by `PtcViewer.Server` and bound to it by monitor: when the owner
  goes down — any exit path — the store stops itself, so no lifecycle
  threading through the server's cleanup chain is required.

  Also owns the single-flight **launch gate**: at most one Viewer-triggered
  run at a time. The launch function runs in a spawned process (never in the
  store), and its `{exit_code, output_tail}` result is captured from the
  monitor's DOWN reason.
  """

  use GenServer

  @max_runs 12

  @spec start(pid()) :: {:ok, pid()} | {:error, term()}
  def start(owner \\ self()) when is_pid(owner) do
    GenServer.start(__MODULE__, %{owner: owner})
  end

  @spec stop(pid()) :: :ok
  def stop(store) do
    GenServer.stop(store, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  @doc "Accepts one frame for `run_id`; broadcasts it to all subscribers."
  @spec put_frame(pid(), binary(), map()) :: :ok | {:error, :invalid_frame}
  def put_frame(store, run_id, frame) when is_binary(run_id) and is_map(frame) do
    GenServer.call(store, {:put, run_id, frame})
  end

  def put_frame(_store, _run_id, _frame), do: {:error, :invalid_frame}

  @doc "Latest decoded frame per known run, oldest run first."
  @spec snapshot(pid()) :: [map()]
  def snapshot(store), do: GenServer.call(store, :snapshot)

  @doc """
  Subscribes `pid` and returns the encoded snapshot atomically, so no frame
  can fall between the snapshot and the first live delivery. Subscribers
  receive `{:live_frame, json}` messages and are auto-removed on DOWN.
  """
  @spec subscribe(pid(), pid()) :: {:ok, [binary()]}
  def subscribe(store, pid) when is_pid(pid), do: GenServer.call(store, {:subscribe, pid})

  @doc """
  Starts `fun` (arity 0, returning `{exit_code, output_tail}`) in a spawned
  process, refusing while a previous launch is still running.
  """
  @spec begin_launch(pid(), (-> {integer(), binary()})) :: :ok | {:error, :launch_running}
  def begin_launch(store, fun) when is_function(fun, 0),
    do: GenServer.call(store, {:begin_launch, fun})

  @doc ~S(One of `%{status: "idle" | "running" | "ok" | "error"}`, with `output_tail` on error.)
  @spec launch_status(pid()) :: map()
  def launch_status(store), do: GenServer.call(store, :launch_status)

  @impl GenServer
  def init(%{owner: owner}) do
    owner_ref = Process.monitor(owner)

    {:ok,
     %{
       owner_ref: owner_ref,
       runs: %{},
       subscribers: %{},
       launch: nil,
       launch_result: nil
     }}
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

  def handle_call({:begin_launch, _fun}, _from, %{launch: launch} = state) when launch != nil,
    do: {:reply, {:error, :launch_running}, state}

  def handle_call({:begin_launch, fun}, _from, state) do
    # The DOWN reason carries the result; the store never runs the command.
    {pid, ref} = spawn_monitor(fn -> exit({:launch_result, fun.()}) end)
    {:reply, :ok, %{state | launch: %{pid: pid, ref: ref}, launch_result: nil}}
  end

  def handle_call(:launch_status, _from, state) do
    status =
      cond do
        state.launch != nil -> %{status: "running"}
        match?({:ok, _code}, state.launch_result) -> %{status: "ok"}
        match?({:error, _tail}, state.launch_result) -> launch_error(state.launch_result)
        true -> %{status: "idle"}
      end

    {:reply, status, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, {:shutdown, :owner_down}, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{launch: %{ref: ref}} = state) do
    result =
      case reason do
        {:launch_result, {0, _output}} -> {:ok, 0}
        {:launch_result, {code, output}} -> {:error, "exit #{code}: #{output}"}
        other -> {:error, "launcher crashed: #{inspect(other)}"}
      end

    {:noreply, %{state | launch: nil, launch_result: result}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  def handle_info(_message, state), do: {:noreply, state}

  defp launch_error({:error, tail}), do: %{status: "error", output_tail: tail}

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
