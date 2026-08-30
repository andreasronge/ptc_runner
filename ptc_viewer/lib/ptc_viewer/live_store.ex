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

  @max_ended_runs 12
  @max_runs 64

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

  @doc """
  Latest decoded frame per known run, newest run first.

  Each frame carries a store-owned `first_seen_at` stamp (UTC ISO-8601). It is
  assigned on the first accepted frame for that run and kept on later updates,
  so two cards with different ceilings are visibly from different launches.
  """
  @spec snapshot(pid()) :: [map()]
  def snapshot(store), do: GenServer.call(store, :snapshot)

  @doc """
  Forgets `run_id`. Closing a card is a viewer-side decision, so a run that is
  still posting frames can be deleted too — it simply reappears on its next
  frame, which is the honest behaviour for a self-contained frame stream.
  """
  @spec delete_run(pid(), binary()) :: :ok | {:error, :unknown_run}
  def delete_run(store, run_id) when is_binary(run_id),
    do: GenServer.call(store, {:delete, run_id})

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

  @doc ~S(One of `%{status: "idle" | "running" | "ok" | "error"}`, with bounded `output_tail` after completion.)
  @spec launch_status(pid()) :: map()
  def launch_status(store), do: GenServer.call(store, :launch_status)

  @impl GenServer
  def init(%{owner: owner}) do
    owner_ref = Process.monitor(owner)

    {:ok,
     %{
       owner_ref: owner_ref,
       runs: %{},
       next_sequence: 0,
       subscribers: %{},
       launch: nil,
       launch_result: nil
     }}
  end

  @impl GenServer
  def handle_call({:put, run_id, frame}, _from, state) do
    existing = Map.get(state.runs, run_id)
    first_seen = if existing, do: existing.first_seen, else: state.next_sequence
    first_seen_at = if existing, do: existing.first_seen_at, else: DateTime.utc_now()
    next_sequence = if existing, do: state.next_sequence, else: state.next_sequence + 1

    frame =
      frame
      |> Map.put("run_id", run_id)
      |> Map.put("first_seen_at", DateTime.to_iso8601(first_seen_at))

    case Jason.encode(frame) do
      {:ok, json} ->
        entry = %{
          frame: frame,
          json: json,
          first_seen: first_seen,
          first_seen_at: first_seen_at
        }

        runs = state.runs |> Map.put(run_id, entry) |> evict(run_id)
        Enum.each(state.subscribers, fn {_ref, pid} -> send(pid, {:live_frame, json}) end)
        {:reply, :ok, %{state | runs: runs, next_sequence: next_sequence}}

      {:error, _reason} ->
        {:reply, {:error, :invalid_frame}, state}
    end
  end

  def handle_call(:snapshot, _from, state),
    do: {:reply, Enum.map(ordered(state.runs), & &1.frame), state}

  def handle_call({:delete, run_id}, _from, state) do
    if Map.has_key?(state.runs, run_id) do
      {:reply, :ok, %{state | runs: Map.delete(state.runs, run_id)}}
    else
      {:reply, {:error, :unknown_run}, state}
    end
  end

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
        match?({:ok, _tail}, state.launch_result) -> launch_success(state.launch_result)
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
        {:launch_result, {0, output}} -> {:ok, output}
        {:launch_result, {code, output}} -> {:error, "exit #{code}: #{output}"}
        other -> {:error, "launcher crashed: #{inspect(other)}"}
      end

    {:noreply, %{state | launch: nil, launch_result: result}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{launch: %{pid: pid}}) do
    Process.exit(pid, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp launch_success({:ok, tail}), do: %{status: "ok", output_tail: tail}
  defp launch_error({:error, tail}), do: %{status: "error", output_tail: tail}

  defp ordered(runs) do
    runs
    |> Map.values()
    |> Enum.sort_by(& &1.first_seen, :desc)
  end

  defp evict(runs, protected_run_id) do
    # Keep the incoming frame so a first terminal update cannot evict itself.
    # Ended cards have the tighter cap; the total cap also bounds orphaned
    # "running" cards whose owners disappeared before publishing a final frame.
    ended =
      runs
      |> Enum.sort_by(fn {_id, entry} -> entry.first_seen end)
      |> Enum.filter(fn {_id, entry} -> entry.frame["phase"] != "running" end)

    runs = maybe_drop(runs, ended, @max_ended_runs, protected_run_id)
    maybe_drop(runs, ordered_entries(runs), @max_runs, protected_run_id)
  end

  defp maybe_drop(runs, entries, cap, protected_run_id) do
    if length(entries) > cap do
      {oldest_id, _entry} =
        Enum.find(entries, fn {run_id, _entry} -> run_id != protected_run_id end)

      Map.delete(runs, oldest_id)
    else
      runs
    end
  end

  defp ordered_entries(runs), do: Enum.sort_by(runs, fn {_id, entry} -> entry.first_seen end)
end
